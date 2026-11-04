# 帖子两层递进树（Thread Tree）设计契约

本文是「帖子详情新增类树形阅读方式」的实现契约与验收依据。文中「必须 / 不得」是并行实现者不能自行改变的约束；
「当前实现」是已定选择，替换时须继续满足不变量。设计调研依据：
`docs/research/THREAD_TREE_CODE_MAP.md`（本工程接入点）、`docs/research/THREAD_TREE_QUOTE_RESEARCH.md`（引用数据形态）、
`docs/research/THREAD_TREE_BILIBILI_REF.md`（B 站两层树交互参考）。

## 0. 一句话定义

帖子原本是自然楼层列表；本功能一次性抓取全帖所有页 → 解析楼层间的回复引用关系 → 以「两层有限树」展示：
第一层是顶层发言（没有有效引用目标、或只回复主楼的楼层），第二层平铺其全部后代（任意深度），
子节点默认只露 2 条（总数 > 3 时），用「回复 @作者 →」表达具体指向，点 `→` 跳到被回复楼层。

## 1. 产品定义与决策

### 1.1 两种阅读样式 = 两个互斥的独立页面

| 样式 | 页面组件 | 数据来源 | 列表结构 | 页面栈 |
| --- | --- | --- | --- | --- |
| 列表（LIST） | `pages/ThreadPanel.ets`（现有，不改动窗口语义） | 连续分页窗口（`ThreadPaginationManager`） | 自然楼层顺序，`PostItem` | `Screen.thread`（`threadForceList=true` 时强制列表） |
| 递进树（TREE） | `pages/ThreadTreePanel.ets`（新增） | 一次性全帖抓取（`ThreadTreeFetchService`，独立数据） | 两层扁平树（根行 + 子行 + 折叠行） | `Screen.threadTree` / 默认样式下的 `Screen.thread`（两种样式互斥，同一栈条目） |

**页面隔离原则（本次设计的核心）**：

1. 两个页面**不共享任何可变状态**：树页不读也不写 `ThreadPaginationManager` 的窗口、不碰 `PostInfoDataSource`、
   不复用列表页的滚动/定位/阅读进度事务；列表页也不感知树页的模型与数据源。
2. 树页自己负责「加载 → 进度 → 渲染 → 刷新」全生命周期；列表页只提供一个入口（更多菜单）。
3. 两页之间的交互是路由，且**两种阅读样式互斥**：切换一律 `navigateActivity(screen, true)`
   **原地替换**当前栈条目，被替换的页面实例随条目移除而销毁；栈里始终只有该帖子的一个
   阅读样式，返回直接回上一层（主题列表等），不会退回另一种样式。
   「切换阅读方式」只携带只看楼主、楼主身份与路由来源，**不携带楼层位置**：
   两种样式各记各的阅读进度、各自恢复，切过去不会把一种样式的位置写进另一种的进度。
4. 树页拥有自己的阅读进度（独立域 `tree_reading_progress`）与阅读记录（写入浏览历史）；
   树页内回复/编辑成功后重新抓取全帖（页面内刷新），不改列表页数据。

### 1.2 入口

1. **设置页**：阅读设置新增「帖子阅读样式」项（列表 / 递进树），持久化为 `threadRenderMode`；
   它决定**打开帖子时挂载哪个页面**（`ActivityRouter` 按它分流 `Screen.thread` 条目的渲染组件）。
2. **列表页更多菜单**：「切换为递进树阅读」→
   `routerStore.navigateActivity(Screen.threadTree(tid, '', 只看楼主, 来源, 楼主 uid, 楼主 authorKey), true)`
   **原地替换**当前列表页条目（列表页实例销毁）；**不携带当前楼层**，树页恢复它自己的
   `tree_reading_progress`（没有记录则从顶部开始），只看楼主、楼主身份与来源随路由透传
   （抓取结果返回前也能维持过滤，加载中切回列表不丢状态）。
3. **树页更多菜单**：「切换为列表阅读」→
   `routerStore.navigateActivity(Screen.threadList(tid, 只看楼主, 楼主 uid, 楼主 authorKey, 来源), true)`
   **原地替换**当前树页条目（树页实例销毁；从列表页切换而来与默认样式直接打开两条路径一致）；
   **不携带树内楼层**，列表页恢复它自己的 `reading_progress`。加载中的「以常规列表打开」
   走同一出口，但先终止在途抓取（见 D11）。
4. **首次打开帖子的一次性引导**：第一次以**列表样式打开在线帖子**、首屏内容加载完成后，弹出一次
   新功能说明弹窗（标题「新增阅读方式：递进树」，内容为"树是什么 + 从哪里进"）。主按钮「试试递进树」
   直接替换为树页（与更多菜单同一路由语义），次按钮「知道了」仅关闭。
   弹窗打开**之前**先把 meta 里的 `treeGuideAcknowledged` 置 true 并异步持久化——**全局只提示一次**，跨启动有效。
   离线存档来源（无树入口）不弹也**不置位**，用户下次在线打开时仍会看到唯一一次引导；
   默认样式已是递进树的用户打开帖子直接进树页，由树页侧静默置位，不再打扰。

### 1.3 决策表（实现必须遵守）

| # | 决策 | 说明 |
| --- | --- | --- |
| D1 | 主楼（`lou === 0`）单独显示为第一行，**不与任何楼层形成回复关系** | 引用主楼的楼层（`[tid=…]Topic[/tid]` / `[pid=0,…]` 头）视为顶层根；主楼没有子节点 |
| D2 | 第一层 = 无有效引用目标的楼层（含引用主楼、引用目标被删/不在帖内、异常自引用/环） | 按楼层号升序 |
| D3 | 第二层 = 根的任意深度后代，**平铺**在根下，按楼层号升序 | 每条子节点显示它**直接回复的那一层**（可能不是根） |
| D4 | 折叠：某根的后代总数 > 3 时，默认显示前 2 条，其余折叠为一行「共 N 条回复，点击查看」；≤ 3 时全部显示 | 展开后显示全部，不再二次折叠；展开状态在当前树页会话内保留 |
| D5 | 树页提供「只看楼主」，按楼主楼层**重建树**而不是列表级隐藏 | 过滤后非楼主楼层不参与父子关系，引用它们的楼主楼层按「目标不在树内」提升为根（`buildThreadTree` 既有语义）；主楼恒保留；被过滤父楼层的根行保留原始正文（含引用块）以维持“回复了谁”的上下文。列表页与树页的只看楼主状态、楼主身份随「切换阅读方式」路由透传（抓取结果返回前用路由身份，返回后以 `threadInfo` 为准） |
| D6 | 离线存档来源不提供树入口 | 列表页菜单不出现「切换为递进树阅读」（离线存档没有网络来源可供全帖抓取） |
| D7 | 树页**独立记录/恢复**自己的阅读进度 | 记录树内锚点行（pid / 所属根 / 页码；不记录会漂移的扁平行下标），存于独立域 `tree_reading_progress`，不与列表页的 `reading_progress` 互相覆盖；恢复交互与列表页一致（Toast「前往查看」后定位） |
| D8 | 全帖抓取不应用黑名单/关键词过滤 | 保证引用图完整；黑名单遮蔽仍由 `PostItem`/`ThreadTreeChildItem` 渲染层判断 |
| D9 | 跳转 `→` 在树内定位 | 目标被折叠时展开其所属根再定位；目标为被删楼层/不存在 → Toast；目标为主楼 → 定位第一行 |
| D10 | 树页内回复/编辑成功后重新抓取全帖并重建树 | Toast 成功提示 + 页面回到加载态；不做增量合并（简单可靠） |
| D11 | 树页加载态 = 全屏加载视图 + 「正在加载全部楼层 n/N 页」 + 进度条 + 「取消」+「以常规列表打开」 | 加载期间不显示旧内容；「取消」停在错误态（可重试、可退出）；「以常规列表打开」先终止在途抓取并让在途回调失效，再把当前递进树栈条目**原地替换**为列表页——树条目移除、页面实例销毁，列表页恢复它自己的阅读进度 |
| D12 | 树模型只在树页生命周期内持有 | 返回/销毁即释放；列表页完全不受影响 |
| D13 | 「递进树」新功能引导**只提示一次** | 标记是 meta 域的一次性字段 `treeGuideAcknowledged`（不随登出/切号重置，也不被「清空本地数据」清除，与 `migrationNoticeAcknowledged` 同一口径），判定走纯函数 `ThreadTreeGuidePolicy.shouldShow`：已提示 / 离线存档 / 默认树样式三种情况都不弹。列表页在弹窗前先置位，多列多实例不会叠窗；树页则静默置位 |

## 2. 数据与算法（纯逻辑，已单测）

### 2.1 引用关系提取

**数据源事实（调研已验证）**：客户端帖子数据走 `read.php?__output=17` APP HTML → `html-thread` 解析器
（`ThreadApi.buildThreadHtmlRequest`），产出的 `content` 与 JSON 主通道（`__output=8`）**逐字一致**（quote 头无差异）。
但 HTML 通道的**普通楼层没有 `reply_to` 结构化字段**（只有贴条行由解析器补；JSON 主通道才有）。
因此引用关系**必须从 `content` 文本提取**，不得依赖 `reply_to`（也不能为此改镜像解析器）。

NGA 楼层 `content` 中表达「回复了哪一层」的头有四种真实形态（样本见 `docs/research/THREAD_TREE_QUOTE_RESEARCH.md`）：

1. 引用块头：`[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]…[/quote]`
   → 目标 pid = A（A 是被引用楼层 pid；B 是**被引用楼层所属主题 tid**；C 是被引用楼层页码）。
2. 回复头：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b]<br/><br/>正文`
   → 目标 pid = A。
3. 回复主楼头：`[b]Reply to [tid=T]Topic[/tid] Post by [uid=U]name[/uid] (date)[/b]`
   → 目标 = 主楼（`isTopicRef = true`）。真实样本存在（回复楼主时由客户端生成），不能只认 pid 形态。
4. 主楼引用头：`[quote][tid=T]Topic[/tid] [b]Post by …[/b]` 或 `[quote][pid=0,T,1]Reply[/pid] …`
   → 目标 = 主楼（`isTopicRef = true`）。

真实变体（已覆盖）：

- 匿名作者引用：`[uid]#anony_<32hex>[/uid][color=gray](224楼)[/color]`（uid 属性无等号；作者段可能是「N楼」提示而非时间）。
- 跨帖引用：`[pid=A,43936925,11]` 的 B 段是**别的主题 tid** → `external = true`，建树时按根处理；
  `[tid=T]` 头且 `T ≠` 当前 tid 同样 `external = true`。
- 网页端（`from_client = 0 /`）生成的 C 段可能恒为 1，**C 段不得用于定位**（页码一律以抓取时 `pageByPid` 为准）。
- 主楼 `pid` 在 HTML 通道恒为 0；主楼靠 `lou === 0` 识别。

提取规则（`extractPrimaryQuoteRef(content, tid)`）：**只从正文开头提取**；一条楼层只取最外层第一个有效头，
不递归嵌套引用。`[uid=…]` 用宽松匹配；作者段不强制以 `(date):` 结尾；多引用取第一个；结果记录
`targetPid/targetPage/targetUid/targetAuthor/rawHeader/isTopicRef/external`。

**引用区的位置与结构约束（精准识别与区分的核心）**：

服务端只把回复/引用头生成在**正文最前面**，因此「是不是回复关系」由两个条件共同判定：

1. **位置**：引用区必须在正文开头，前面只允许空白、`<br>`/`<br/>`、`&nbsp;`。前面出现任何正文文字、
   图片或格式标签，就不再是服务端引用头。
2. **结构**：`[quote]` 块内第一个有效元素必须是 `[pid=A,B,C]Reply[/pid]` 或 `[tid=T]Topic[/tid]`
   链接头；`[b]Reply to …` 头必须紧贴正文开头，支持 `[pid=…]` 与 `[tid=…]Topic[/tid]` 两种内嵌头。

**未闭合/异常头的降级规则**（宁可漏剥，不可吞正文）：

- `[quote]` 块未闭合：仍提取引用关系，但**不剥离**（无法确定块结束位置）；
- `[b]Reply to` 头缺 `[/b]`，或 400 字符窗口内的 `[/b]` 实际属于正文的 `[b]…[/b]`：仍提取关系，
  但**不剥离**（`isSafeReplyHeaderClose` 要求 `[/b]` 之前不出现 `<br` 或第二个 `[b]`）；
- 作者只从头部窗口（到 `[/b]` 或第一处 `<br`）解析，被引正文里的 `[uid=…]` 提及不会顶替作者。

由此区分三类容易混淆的形态：

| 形态 | 位置 | 是否回复关系 | 是否从显示正文剥离 |
| --- | --- | --- | --- |
| 服务端引用/回复头 | 正文开头 + 块首链接头 | 是 | 是 |
| 用户把 `[quote]` 当排版容器（无 pid/tid 头） | 任意位置 | 否 | 否（文字不被吞） |
| 用户复制/手打的引用样式（头在正文中部、或 `[quote]` 块中部才出现链接头） | 正文中部 | 否 | 否 |

`stripQuoteArea` 与 `extractPrimaryQuoteRef` 共用同一次「头部引用区扫描」（`scanLeadingQuoteArea`），
保证「建了边的引用块一定会被剥离」「没建边的用户引用样式一定不会被吞」。

**硬约束**：不得修改 `entry/src/main/ets/common/utils/QuoteInjectionCore.ets`（TS 镜像真源），
新解析器写在独立新文件里（不在 `tools/bbcode-ts/src` 镜像清单内）。

### 2.2 建树算法（`buildThreadTree`）

输入：全帖 `PostInfo[]`（已按 `lou` 升序去重）、`totalPages`。输出：`ThreadTreeModel`。

1. 建立 `postByPid`；主楼 = 第一个 `lou === 0` 的楼层（`mainPid` 可能为 0）。
2. 非主楼楼层的父 pid（0 表示根）：无引用 / 引用主楼 / 跨帖 / 目标不存在 / 目标 `lou >=` 本楼（防自引用与环）→ 0；其余 → 被引用 pid。
3. 根的任意深度后代统一平铺（父链记忆化，O(n)）。
4. 环防御：父链无法回溯到根的楼层提升为根，保证不丢楼。
5. `rootPidOfPid` 记录每个楼层归属根（根自身→自身），供折叠状态下定位。

### 2.3 折叠与扁平化（`flattenThreadTree`）

- `root.expanded === false && children.length > 3`：可见子行 = 前 2 条；追加 `MORE` 行（`totalCount`=后代总数、`hiddenCount`=总数-2）。
- 已展开或 ≤ 3：全部可见，无 `MORE` 行。主楼根无子行。
- 扁平顺序：`[主楼根行] [根1 行, 根1 子行…, 根1 MORE?] [根2 行, …] …`。
- 行键：`kind + '_' + pid（MORE 用 rootPid）+ '_' + rev + 高亮后缀`；展开时递增根 `rev` 后整体 `replaceAll`。

### 2.4 模型类与符号冻结

`entry/src/main/ets/model/ThreadTree.ets`：`ThreadTreeRowKind`、`ThreadTreeQuoteRef`、`ThreadTreeChild`、
`ThreadTreeRoot`、`ThreadTreeRow`、`ThreadTreeModel`（字段语义见文件内注释，不得随意改）。

### 2.5 抓取服务（`service/ThreadTreeFetchService.ets`）

流程（参照 `SavedThreadService.saveThread`，但不落盘）：

1. 取第 1 页 `getThread(…, 空黑名单, 空关键词, 空备注)` → 拿 `totalPages`、主楼、主题信息。
2. 第 2..N 页**并发抓取**（{@link TREE_PAGE_CONCURRENCY} = 4 路并发）；单页 **15s 超时**、失败重试 1 次
   （退避 400ms）后整体失败；命中风控不重试直接失败，其余在途页停止派发。
3. 合并按 pid 去重、按 `lou` 升序，逐页记录 `pageByPid`（含主楼 `0 → 1`）。
4. 每页完成回调 `onProgress(done, total)`；支持 `cancel(owner)`；每次 `fetchAll` 递增代际。
5. 完成后**后台**预热首屏楼层（前 min(60,n) 条，不阻塞结果提交）。
6. 不写 `savedThreadProgress`，不碰 `ThreadPaginationManager`。

**限流与风控（速度/节流平衡）**：

- 全站默认限流器 `ngaThrottler` 是 6 并发 / 150ms 间隔 / **60 次每 60 秒**，适合日常浏览，但会把 100 页
  长帖压到 100 秒以上。
- 树页是用户显式触发的一次性批量读取，使用独立的 `treeBatchThrottler`：**4 并发 / 250ms 最小派发间隔 /
  180 次每 60 秒**（平均 3 次/秒，瞬时上限 4 次/秒）。100 页约 33~40 秒，29 页约 8~10 秒；
  仍低于网页版一次打开页面的静态资源 + 接口请求量。
- 独立限流桶**不绕开风控**：命中 429 / 风控文案时 `ngaThrottler.enterCooldown` 全局拉闸，之后所有请求
  （含树页）都会在 `NgaClient.ngaRequest` 的冷却前置检查处被拒绝。
- 网络层通过可选 `throttle` 参数把限流器从 `ThreadTreeFetchService` 透传到 `postSignedPath`，
  其余调用方不传时保持全站默认行为。
- 两个桶各自计数、互不可见：树页抓取期间普通浏览仍走 `ngaThrottler`，同一域名下瞬时总并发
  最坏为 6 + 4。这是「不改变全站日常浏览节奏」的代价；批量桶的 250ms 间隔保证自身不突发。

**短时缓存**：成功结果按「账号 uid + tid」缓存 **90 秒**、最多 2 个帖子（按写入时间淘汰）；
单帖楼层数超过 3000 时不写缓存（超大帖全量常驻内存会显著抬高峰值）。
列表 ↔ 树切换后再进入在缓存期内秒开；菜单「刷新递进树」、回复/编辑后刷新、错误态重试传
`forceRefresh = true` 跳过缓存。

**跨页写操作必须失效缓存**：缓存只服务「返回再进入」，用户在列表页回复/编辑/贴条成功后再进树，
若不失效会命中 90 秒内的旧全帖。`ReplyManager.send` 成功（回复/编辑/贴条的共同出口）调用
`threadTreeFetchService.invalidateCache(tid)`；树页自己的刷新入口本来就带 `forceRefresh`，不受影响。

**并发与取消语义（页面级隔离的关键，review 后补强）**：

- 树页是与列表页互斥的独立页面组件，「快速切帖」「列表 ↔ 树反复切换」会出现**新旧两个页面实例重叠**的时序。
- `fetchAll(owner, tid)`：若上一个任务的 Promise 仍在途，先置取消并 `await` 它退场（旧任务最多再等当前批次请求），
  再启动新任务——不会以「已有任务进行中」把新页面直接拒掉。
- `cancel(owner)`：只有当前任务正属于该 owner 才生效；旧页面销毁回调晚于新页面启动时不会误杀新任务。
- 调用方（`ThreadTreePanel`）为每个页面实例生成唯一 `treeOwner`（时间戳 + 随机数），所有 `cancel`/`fetchAll` 都带它。

## 3. 树页 UI（`pages/ThreadTreePanel.ets`）

### 3.1 页面结构

```
Stack
├─ Column：isLoading → LoadingState；hasError → ErrorState；ready → TreeList
│   └─ TreeList（List + LazyForEach + 末尾 LoadEndFooter「已加载全部回复」）
├─ PanelNavBar（标题=帖子标题（楼主被屏蔽时显示占位），更多菜单，滚动联动渐变模糊）
└─ BottomBar（回复主题按钮，HdsMaterialHost；仅树就绪时显示；按握姿贴左/贴右）
```

### 3.2 根节点行

直接复用 `PostItem`（完整楼层卡片：头像、楼主标记、正文、附件、签名、投票栏、贴条、热回复）。
与列表模式的区别只在「行序」与「所在页面」；不做额外视觉标记，靠子节点缩进与折叠行表达树形态。

### 3.3 子节点行（`common/components/thread-tree/ThreadTreeChildItem.ets`）

自上而下：

```text
头像 24  用户名 [楼主] [备注]                         #当前楼层号
时间 [编辑时间]
回复 @被回复者 #被回复楼层号  →（仅回复更深祖先时显示）
正文（已剥离引用区）
附件 / 动作栏
```

- 用户信息区只有一行（头像 + 用户名 + 楼主标记 + 备注 + 行尾当前楼层号，`楼主/沙发/#N`）。
- **「回复 @被回复者」位于时间行与正文之间**（不是用户信息区）：它是阅读正文前的上下文提示；
  字号 **13vp，与用户名一致**（回复关系是阅读主线，不能弱化成小字备注）。
  `@名字` 可点 → 资料卡（匿名 uid 只提示）；`→` 可点 → 树内定位；`#N`/`楼主` 为被回复楼层号（11vp 辅助）。
- **直接回复所属根的子行不显示关系行**（`row.showReplyTo=false`）：缩进已经表达「它是这条根的
  一级回复」，再写「回复楼主 / 回复根作者」是冗余噪音；只有跳过中间楼层、回复更深祖先的楼层
  才显示。例：`#3 回复 #2`（#2 是根）→ #3 不显示；`#4 回复 #3` → #4 显示「回复 @#3 作者」。
  该标志由 `flattenThreadTree` 按 `child.parentPid !== rootPid` 计算，随行数据下发。
- 时间行 → 回复关系行（可选）→ 正文（`BBCodeContentView`）→ 附件（`PostAttachments`）→ 操作栏（`PostVoteBar`）。
- 正文使用父组件传入的 `displayContent`（已剥离引用区）：树的两层关系已表达「回复了谁」，
  正文不再重复显示 `[quote]` 块 / `Reply to` 头；剥离后无正文时不渲染正文块。
- 不渲染签名/投票/贴条/热回复。黑名单作者 → 保留头部、正文区替换为「该用户已被屏蔽」。
- 视觉：左侧 `padding 40`、左侧 2vp 竖线、**无卡片底色**（透明；层级只靠缩进与竖线表达）、
  高亮 `selectionTint`（2 秒自动清除）。

### 3.3.1 引用区剥离（`stripQuoteArea`）

树模式所有节点（含根行）正文统一经**头部引用区扫描**（`scanLeadingQuoteArea`，`stripQuoteArea` 的同一套判定）处理：

1. 只剥离**服务端引用区**：正文开头（允许前导空白 / `<br/>` / `&nbsp;`）的
   `[b]Reply to …[/b]` 回复头（pid 与 `[tid]Topic[/tid]` 两种），或块首就是 `[pid=…]`/`[tid=…]`
   链接头的 `[quote]…[/quote]` 块；
2. 与 `extractPrimaryQuoteRef` 共用同一次扫描（`scanLeadingQuoteArea`），判定完全一致；
3. 最多剥离一个引用区（`Reply to` 头 + 紧跟的一个引用块，或一个引用块）；连续第二个服务端引用块
   也保留（属于用户拼接的正文）；
4. 剥离后清理开头的空白与 `<br/>`，其余正文格式原样保留；
5. **不剥离**：正文中部出现的 `[quote]` 块、开头没有链接头的 `[quote]`（用户把 `[quote]` 当排版容器）、
   未闭合的 `[quote]` 块、`[/b]` 缺失或 `[/b]` 实际属于正文的 Reply to 头——这些要么是用户正文，
   要么无法确定边界，删掉会造成「文字被吞」的意外表现；
6. 平衡扫描与标签比较按**原串下标**逐字符进行（不做整串 `toLowerCase`），避免 `İ` 等字符小写化
   变长导致剥离位置切在字符中间；单遍 O(n)，长引用块不会退化成 O(n²)。

剥离结果缓存在 `ThreadTreeRoot/ThreadTreeChild.displayContent`，由 `flattenThreadTree` 复制到行上；
`PostItem` / `ThreadTreeChildItem` 通过 `displayContent` + `showContent` 渲染（默认不传时行为与自然列表完全一致）。

### 3.4 折叠行（`ThreadTreeMoreItem.ets`）

文案 `共 N 条回复，点击查看`（13vp `textTertiary`）+ 下箭头，高 40、同缩进、整行点击展开全部子节点。

### 3.5 加载态 / 错误态

- 加载态：`LoadingStateView` + 「正在加载全部楼层 n/N 页」+ 线性进度条 + 「取消」+「以常规列表打开」；
  总页数未知（第 1 页尚未返回）时显示「正在加载帖子…」，**两个按钮同样可用**（首屏请求也可能卡满超时）。
- 「以常规列表打开」是加载期逃生舱：不必等全帖抓完、也不必先退出帖子——点击后终止在途抓取
  （在途回调失效）并把当前递进树栈条目原地替换为列表页，树条目移除、页面实例销毁；
  「取消」则只终止抓取并停在错误态，可重试或退出。
- 错误态：`ErrorStateView(msg, onRetry)`（重试重新抓取）。

### 3.6 菜单（与列表页同构）

树页与列表页共用同一套多功能下拉结构，只有「刷新」与「切换阅读方式」两项按样式命名：

| 序 | 列表页 | 树页 | 说明 |
| --- | --- | --- | --- |
| 1 | 收藏到… / 管理收藏 | 同左 | 打开收藏夹多选页 |
| 2 | 离线保存帖子 | 同左 | 保存页范围弹窗 |
| 3 | 跟踪帖子更新（激活态） | 同左 | 跟踪设置弹窗 |
| 4 | 刷新帖子 | 刷新递进树 | 按当前阅读位置重载 |
| 5 | 只看楼主（激活态） | 同左 | 列表页请求过滤；树页按楼主重建树 |
| 6 | 切换为递进树阅读 | 切换为列表阅读 | 阅读方式切换（ListCell）：只携带只看楼主、楼主身份与路由来源，**不携带位置**；两种样式各自恢复自己的阅读进度；**原地替换**当前栈条目，另一种样式的页面实例随替换销毁 |

> 树页「只看楼主」下，被过滤掉父楼层的根行会保留原始正文（含引用块），
> 让卡片继续表达“回复了谁”；否则根行只剩一张没有回复上下文的卡片。
> 两种阅读样式互斥：切换一律原地替换当前栈条目（`navigateActivity(screen, true)`），
> 被替换的页面实例销毁，返回直接回上一层，不会退回另一种阅读样式。
| 7 | 从网页打开 | 同左 | WebView |
| 8 | 分享帖子 | 同左 | 分享链接 |

离线存档来源的列表页不出现 1/2/3/6（存档无网络来源），保留 4/5/7/8。

### 3.7 阅读进度（树内锚点，独立域）

树页不套用列表页的 `reading_progress`（页码 + 楼层锚点），因为树没有分页窗口，
定位依据是**扁平可见行**。树页自己记录 `ThreadTreeProgressEntry`：

| 字段 | 含义 |
| --- | --- |
| `tid` | 主题 ID |
| `pid` | 锚点楼层 pid（主楼在 HTML 通道为 0） |
| `rootPid` | 锚点所属根楼层 pid（恢复时先展开该根，避免锚点被折叠隐藏） |
| `page` | 锚点楼层所属服务端页码（诊断快照；切换阅读方式不携带位置） |
| `ts` | 最近更新时间（LRU 淘汰依据，上限 200 帖） |

**刻意不记录扁平行下标**：下标会随折叠/展开与只看楼主过滤漂移，按下标兜底会把用户
静默带到无关楼层；pid 找不到时宁可提示「原阅读位置已不可用」。

- 记录时机：`onScrollIndex` 取**视口中心行**，滚动停顿 800ms 节流落盘；离开页面/切帖时立即补记；
  首轮定位完成前、导航事务中、进度读取窗口内不记录；
- 恢复门禁与列表页一致：路由未携带 pid、`threadPage <= 1`、来源属于
  `DEFAULT / TOPIC_LIST / BROWSE_HISTORY`、非列表页入口时才读取；读取后弹
  「检测到上次阅读进度 / 前往查看」，点击后按 pid 找行（折叠则展开所属根）→ 居中定位；
- 「前往查看」提示有 4300ms 保护窗口（略长于动作型 Toast 的 4000ms）：窗口内不落盘，
  避免首屏自动定位把顶部落成新进度；窗口结束自动解除，用户忽略提示继续阅读时仍会记录；
- 与列表页进度**互不覆盖**：存于 `v2.tree_reading_progress` 独立域，迁移/导入/清空/导出按
  `PersistenceCatalog` 统一治理。

### 3.8 阅读记录与跟踪已读

- 全帖抓取成功后按 `ThreadResult` 同形状组装，调 `appStore.addBrowseHistoryFromThread`：
  树页打开同一帖子同样进入浏览历史，并推进主题列表的「已读 / 有新回复」基线；
- 被跟踪的帖子打开即调 `syncTrackedOnOpen`（与列表页同一语义，受最小检查间隔节流）。

### 3.9 其它与列表页同步的细节

- 列表末尾 `LoadEndFooter` 显示「已加载全部回复」（与列表页 `LoadMoreFooter` 完成态同文案）；
- 黑名单版本变化时刷新全帖楼层的遮蔽标记（行组件订阅同一版本号，自行重绘）；
- 滚动时同步标题渐变并 `dismissAnalyzerSessions()`（与列表页一致，图片识图选取态不跨滚动存活）；
- 底部回复按钮按握姿（`HoldingHandStatus`）贴左/贴右，`PostItem` / `ThreadTreeChildItem` 同步传入握姿。

## 4. 页面接入（路由层）

### 4.1 路由

`store/RouterStore.ets`：

- `ScreenType` 增加 `'threadTree'`；
- `Screen.threadTree(tid, pid, authorOnly, source, authorId, authorKey)` 工厂（树页路由；`pid` 只用于显式定位入口，
  阅读方式切换固定传空串；楼主身份用于抓取结果返回前维持只看楼主）；
- `Screen.threadList(tid, authorOnly, authorId, authorKey, source)` 工厂（强制列表样式 + 过滤/楼主身份/来源透传，**不携带位置**）；
- `Screen.threadAuthorOnly` 字段（两种阅读样式共用）；
- `getTitle()` 增加 `'递进树'`。
- `navigateActivity` 现有行为：`'thread'` 类型在栈顶也是 thread 时替换，其余 push；
  **列表 / 递进树切换必须显式传 `replace = true`**——原地替换栈顶条目，两种阅读样式互斥，
  被替换的页面实例随条目移除而销毁。

### 4.2 ActivityRouter

`pages/ActivityRouter.ets`：

- `'thread'` 条目：`appStore.settings.threadRenderMode === ThreadRenderMode.TREE` → 挂载 `ThreadTreePanel(authorOnlyInit=screen.threadAuthorOnly, authorIdInit=screen.threadAuthorId, authorKeyInit=screen.threadAuthorKey, threadSource=screen.threadSource, threadPage=screen.threadPage)`，
  否则挂载 `ThreadPanel`（分页/定位语义不变，仅新增 `authorOnlyInit / authorIdInit / authorKeyInit` 三项路由透传）；
- `'threadTree'` 条目：挂载 `ThreadTreePanel(authorOnlyInit=screen.threadAuthorOnly, authorIdInit=screen.threadAuthorId, authorKeyInit=screen.threadAuthorKey, threadSource=screen.threadSource, threadPage=screen.threadPage)`
  （由列表页切换时**原地替换**而来，与列表页互斥：列表页实例已在替换时销毁）；
- TTS 停止判定把 `threadTree` 也视为帖子类页面（替换条目会改变条目 id，因此切换阅读样式即停止朗读）。

### 4.3 列表页入口（`ThreadPanel.ets`）

`moreMenuItems()` 与树页**同序同构**（§3.6）：在线来源依次为 收藏 / 离线保存 / 跟踪 /
刷新帖子 / 只看楼主 / 切换为递进树阅读 / 从网页打开 / 分享；离线存档来源去掉网络相关项。
「切换为递进树阅读」以
`routerStore.navigateActivity(Screen.threadTree(this.threadTid, '', this.authorOnly, this.threadSource, this.threadAuthorId, this.threadAuthorKey), true)`
**原地替换**当前列表页条目（列表页实例销毁）：
不把列表当前楼层带进树页，树页按自己的进度恢复（无记录则顶部）。
列表页只新增了「刷新帖子」与本项，不改分页/定位/进度逻辑。

## 5. 设置链路（单一 owner）

| 环节 | 文件 | 改动 |
| --- | --- | --- |
| 常量枚举 | `common/constants/Constants.ets` | `ThreadRenderMode { LIST='0', TREE='1' }`；`SettingsIconColors.threadRender` |
| 状态字段 | `store/settings/SettingsState.ets` | `threadRenderMode: string = ThreadRenderMode.LIST` |
| 域 store | `store/settings/domain/ReadingSettings.ets` | `setThreadRenderMode(v)` + `load()` 判空赋值 |
| 门面 | `store/SettingsStore.ets` | `setThreadRenderMode(v)` 一行转发 |
| 设置页 | `pages/SettingsPanel.ets` | badge + `threadRenderLabel/Options/showThreadRenderPicker` + PickerRow「帖子阅读样式」 |
| 图标 | `resources/base/media/settings_thread_tree.svg` | 树形图标 |

选项文案：`列表（自然楼层）`、`递进树（引用关系）`；弹窗标题 `帖子阅读样式`；badge `列表` / `递进树`。
不使用 AppStorage 键（不需要已打开页面即时响应）；不改 `reset()`。

## 6. 测试与门禁

`entry/src/test/ThreadTreeBuilderUnit.test.ets`（50 例，在 `List.test.ets` 注册）覆盖：

1. 引用头提取：quote 头 / Reply to 头（pid 与 `[tid]Topic[/tid]` 两种）/ 主楼 Topic 头 / `[pid=0]`
   主楼哨兵 / 匿名 uid / 跨帖 / 多引用取第一 / 无引用 / 头部前空白 / 未闭合 Reply to 头
   （提取但不剥离）/ 缺 `[/b]` 且正文含 `[b]`（不剥离）；
2. **引用区位置与结构边界**（本次补强）：正文前缀后不提取、正文中部引用样式不提取、无链接头的 `[quote]`
   不提取、块中部才出现链接头不提取、块首前噪音（`<br/>`）仍提取、作者只从头部窗口解析；
3. 建树：引用主楼 → 根；引用不存在 pid → 根；自引用 / 环 → 提升为根不丢楼；深层引用平铺；主楼无子节点；
   用户排版引用样式保留在正文且楼层为根；
4. 折叠：3 条全显、4 条显 2 + MORE(hidden=2)、展开后全显、未知根不可展开；
5. 排序与查找：根/子行按楼号升序、`findRootPidByPid` 语义、`findRowIndexByPid`；
6. 剥离：服务端引用块 / 回复头剥离、嵌套服务端块按深度平衡剥离、主楼引用块剥离、用户排版引用
   （含嵌套）保留、服务端块后的用户引用样式保留、连续两个服务端块只剥第一个、正文中部引用不动、
   未闭合块提取但不剥离、约 8K 字符长引用块线性完成、仅引用时返回空串。

门禁：`hvigorw assembleHap` 编译通过 + `hvigorw test` 通过 + `node scripts/check-eol.mjs` 通过；
镜像 `sync-to-ets.mjs --dry` 0 修改。

一次性引导另有 `entry/src/test/ThreadTreeGuideUnit.test.ets`（在 `List.test.ets` 注册）：覆盖触发策略的
三条排除规则（已提示 / 离线存档 / 默认树样式），以及 meta 标记的磁盘兼容读取（字段存在 / 旧数据缺字段 /
坏字段三种输入的归一化结果）。

## 7. 文件清单与写入归属

| 文件 | 归属 |
| --- | --- |
| `model/ThreadTree.ets` | Lead（先行冻结） |
| `common/utils/ThreadTreeBuilder.ets` + `entry/src/test/ThreadTreeBuilderUnit.test.ets` + `List.test.ets` 注册 | 数据层成员 |
| `service/ThreadTreeFetchService.ets` | 数据层成员 |
| `common/datasource/ThreadTreeDataSource.ets` | 数据层成员 |
| `store/ThreadTreeProgressStore.ets` + `PersistenceCatalog` 注册 + `DomainMergers` / 数据管理页 / 单测接线 | 数据层成员 |
| `common/components/thread-tree/ThreadTreeChildItem.ets` / `ThreadTreeMoreItem.ets` | UI 层成员 |
| `common/utils/ThreadTreeGuidePolicy.ets` + `entry/src/test/ThreadTreeGuideUnit.test.ets`（一次性引导触发策略与单测） | Lead |
| `pages/ThreadTreePanel.ets`（独立树阅读页面） | Lead |
| `pages/ActivityRouter.ets` / `store/RouterStore.ets`（路由类型与分流） | Lead |
| `pages/ThreadPanel.ets`（更多菜单同构 + 刷新项） | Lead |
| 设置链路 6 文件 + 图标 | 设置成员 |
| `docs/THREAD_TREE_DESIGN.md`、`docs/research/*` | Lead/调研成员 |

## 8. 风险与已知限制

1. 引用头格式覆盖率以真实样本统计为准；解析器对未知格式静默降级（不崩溃、不误判）。
   **只认正文开头的服务端引用区**，正文中部/无链接头的引用样式一律视为用户正文（宁可少判，不可错判）。
2. 长帖抓取耗时与风控：4 路并发 + 批量读窗口 180 次/分钟，100 页约 33~40 秒；必须可取消；失败即停。
   若线上日志频繁出现 `[NGA][THROTTLE]` 冷却，应下调 `TREE_BATCH_MAX_IN_WINDOW`。
3. 树页回复/编辑成功后整树重抓（D10）：长帖会再次等待，这是「简单隔离」的代价；用户也可用菜单手动刷新。
   短时缓存（90 秒）只服务「返回再进入」，刷新动作一律 `forceRefresh`。
4. 树页与列表页不共享分页窗口，且两种阅读样式互斥：切换是**原地替换**当前栈条目，
   被替换的页面实例销毁，返回直接回上一层；切换后目标页恢复**它自己的**阅读进度
   （列表 `reading_progress` / 树 `tree_reading_progress`，没有记录则从第 1 页 / 顶部开始）。
5. 主楼 pid 在 HTML 通道可能为 0：引用主楼一律按 `isTopicRef` 判定，不依赖 pid 匹配。
6. 树页的阅读进度与列表页**分开存储**（`tree_reading_progress` / `reading_progress`）：
   两种视图形状不同、锚点语义不同，互不覆盖；切换阅读方式**不携带位置**，
   因此切换动作本身也不会把一边的楼层写进另一边的进度记录。
7. 缓存共享 `PostInfo` 对象：树页投票等写操作会回写缓存对象，下一次缓存命中看到的是最新分数（符合预期）；
   黑名单状态由页面订阅 `blacklistVersion` 重新应用，不依赖缓存写入时的快照。

## 9. 实现落地差异（交付时校准）

1. 匿名引用真实形态 `[uid]#anony_<32hex>[/uid][color=gray](224楼)[/color]`（uid 无等号），另有裸 `(31楼)` 变体；已覆盖。
2. 引用载体两种共 741 条（quote 块 547 + Reply to 头 194），两者同优先级取最靠前。
3. 跨帖引用 14 条 → `external=true` 归根；主楼引用两种形态共 11 条 → `isTopicRef=true`。
4. C 段不可靠（Web 端 7.4% 错写 1），不用于定位；树内定位一律用 `pageByPid`。
5. `buildThreadTree` 不填 `pageByPid`，由树页把 `ThreadTreeFetchResult.pageByPid` 合入。
6. `__R` 中楼中楼评论行（`comment_to_id` + 无 `content`）由 `parseThreadData` 过滤，`posts` 不含。
7. 门禁结果：`assembleHap` BUILD SUCCESSFUL；Hypium 全量用例通过；EOL 通过；镜像 `--dry` 0 修改。
8. UI 运行时行为（滚动、展开、高亮、加载进度）需在设备上实际体验确认；本工程不做 UI 自动化。
9. **交付前 review 修复**：
   - 抓取服务并发竞态：新增 `owner` 标识 + 「新任务先等待旧任务退场」，快速切帖 / 列表 ↔ 树反复切换
     不再误报「已有任务进行中」，旧页面销毁也不会误取消新页面的任务（见 §2.5）；
   - `PostItem.displayContent/showContent` 改为 `@Prop`：树页刷新后行键值可能不变（pid + rev 相同），
     只有 @Prop 会随新参数更新，普通字段会保留旧值导致正文不刷新；
   - 树 List 启用 `maintainVisibleContentPosition(true)`：展开折叠行（整体 replaceAll）时视口不跳动；
   - 加载态「取消」与「以常规列表打开」在总页数未知（第 1 页未返回）时都可用；
   - 「切换为递进树阅读」菜单项只在在线来源显示（离线存档不出现该入口）。
10. 调研临时产物（`docs/research/samples/` 抓取样本与分析脚本、B 站现场截图，约 4.6MB）已在交付前清理；
    三份调研报告（引用格式统计、B 站交互规则、工程接入地图）保留，作为解析规则与参数的依据。
11. **细节调整（与列表页对齐）**：
    - 树页更多菜单与列表页同构（收藏 / 离线保存 / 跟踪 / 刷新 / 只看楼主 / 切换阅读方式 /
      从网页打开 / 分享），新增「只看楼主」按楼主楼层重建树；被过滤父楼层的根行保留原始
      正文（含引用块），维持“回复了谁”的上下文；
    - 阅读方式切换只透传「只看楼主 + 楼主身份」，**不携带位置**：树→列表用
      `Screen.threadList` 打开列表页自己的进度，列表→树用 `Screen.threadTree` 让树页恢复
      自己的进度，避免切换动作把一种样式的位置写成另一种样式的进度；
    - 新增独立域 `tree_reading_progress`（`ThreadTreeProgressEntry`：pid / rootPid / page），
      树页按视口中心行记录、按 pid（必要时展开根）恢复；不记录会漂移的扁平行下标；
    - 恢复门禁与列表页对齐（来源白名单 + `threadPage`），提示有 4300ms 保护窗口，
      忽略提示继续阅读仍会记录；刷新中点「前往查看」会延迟到新树就绪后定位；
    - 树页成功加载后写浏览历史、推进跟踪已读；
    - 投票成功后分数回写全帖楼层真源对象，避免行复用后分数回退；
    - 末尾提示「已加载全部回复」、握姿对齐、黑名单刷新、滚动静默收起识图会话等细节与列表页一致。
12. **抓取速度与引用识别优化（2026-11）**：
    - 抓取从「顺序 + 每页 300ms 固定间隔」改为「第 1 页后 4 路并发」；页间节奏交给专用限流器
      `treeBatchThrottler`（4 并发 / 250ms / 180 次每 60 秒），不再由业务层 sleep 硬编码；
      单页失败重试前退避 400ms；在途请求全部完成/取消后才返回，取消语义不变；
    - 成功结果按「账号 uid + tid」缓存 90 秒（最多 2 帖、单帖 > 3000 楼不缓存），
      列表 ↔ 树切换后再进入秒开；菜单刷新 / 回复后刷新 / 错误态重试传 `forceRefresh` 强制重抓；
    - 首屏 BBCode 预热改为后台执行（`preWarmBatch` 不 await），不再阻塞「加载完成 → 首屏渲染」；
    - 引用关系提取与引用区剥离统一为「头部引用区扫描」（`scanLeadingQuoteArea`）：只认正文开头、
      只认 `[quote]` 块首链接头；正文中部/无链接头的引用样式不建边、不剥离，
      修复「树里挂错父楼层」与「用户正文被吞」两类意外表现；
    - 单测从 28 例扩展到 50 例（新增引用区位置/结构边界、用户排版保留、建树保留、回复主楼
      `[tid]` 头、缺 `[/b]` 安全判定、未闭合块、连续引用块、长引用块用例）。
13. **独立 review 修复（提交前）**：
    - 平衡扫描从「逐字符 `indexOf`」改为 `matchTagAt` 逐字符比较（ASCII 大小写不敏感、无分配），
      恢复 O(n)：修复长引用块（10KB+）在 UI 线程退化为 O(n²) 造成的秒级~十秒级阻塞；
    - 回复头补 `[b]Reply to [tid=T]Topic[/tid]` 主楼形态（真实数据存在，旧实现漏判且不剥离）；
    - `[/b]` 闭合判定增加结构校验（前段不得出现 `<br` 或第二个 `[b]`）：修复「头缺 `[/b]` 时把正文
      加粗的 `[/b]` 当头部结束」导致吞正文；
    - 引用块未闭合时仍提取关系但不剥离；作者解析窗口截断到 `[/b]`/`<br`，避免被引正文里的 `[uid]`
      顶替作者；
    - 不再整串 `toLowerCase`（避免 `İ` 等字符变长导致下标错位）；
    - `ReplyManager.send` 成功后失效树页缓存（列表页回复后 90 秒内进树不再看到旧楼层）；
    - 网络层风控响应（`error_code=15`）在 `extractAppArticleHtml` 翻译回可读原因，树页能识别风控、
      不再多打一次重试；域名重试前复查全局冷却，独立限流桶也不会绕过闸门。
14. **阅读样式栈互斥与加载期切换（2026-11）**：
    - 列表 / 递进树不再以 push + back 共存：切换一律 `navigateActivity(screen, true)` **原地替换**
      当前栈条目，另一种样式的页面实例随条目移除销毁；返回直接回上一层，不会退回另一种样式；
    - 删除 `Screen.threadTree` 的 `fromList` 参数、`Screen.threadTreeFromList` 字段与
      `ThreadTreePanel.fromListEntry`（从列表页切换与默认树样式打开统一为替换语义）；
    - 树页加载态新增「以常规列表打开」：先 `cancelWork()`（终止抓取、在途回调失效），
      再把树条目替换为 `Screen.threadList`（强制列表样式）——加载期间不必等全帖抓完即可切换；
    - 切换时透传路由来源 `threadSource` 与楼主身份（`authorId / authorKey`，由两个工厂分别接收），
      替换页面后阅读进度恢复白名单、只看楼主过滤与标题屏蔽等语义不丢失；
    - 「取消」保留为终止抓取并停在错误态（可重试、可退出）。
