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
| D11 | 树页加载态 = 全屏加载视图 + 「正在加载全部楼层 n/N 页」 + 进度条 + **三种出口**：「查看已加载 n/N 页」/「取消」/「以常规列表打开」 | 加载期间不显示旧内容；**「查看已加载」中断抓取并把已抓楼层送进树**（服务端取消不再丢弃已抓数据，见 D14）；「取消」终止抓取并退出递进树（返回上一层，栈里没有「原视图」可退）；「以常规列表打开」先终止在途抓取并让在途回调失效，再把当前递进树栈条目**原地替换**为列表页——树条目移除、页面实例销毁，列表页恢复它自己的阅读进度。第 1 页返回前「查看已加载」禁用（无数据），另两个出口始终可用 **（已被增量加载取代：见 `THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.1 / §10；「查看已加载」出口先被移除；`ENTERING` 剩余的两个页内出口「取消」「以常规列表打开」随后也一并移除——加载屏与列表页 `ThreadPanel.LoadingState` 完全同构：居中加载圈 + 400ms 延迟淡入，退出走返回键、切换列表走更多菜单）** |
| D12 | 树模型只在树页生命周期内持有 | 返回/销毁即释放；列表页完全不受影响 |
| D13 | 「递进树」新功能引导**只提示一次** | 标记是 meta 域的一次性字段 `treeGuideAcknowledged`（不随登出/切号重置，也不被「清空本地数据」清除，与 `migrationNoticeAcknowledged` 同一口径），判定走纯函数 `ThreadTreeGuidePolicy.shouldShow`：已提示 / 离线存档 / 默认树样式三种情况都不弹。列表页在弹窗前先置位，多列多实例不会叠窗；树页则静默置位 |
| D14 | 抓取「取消」不再丢弃已抓楼层；部分数据**不做断点续传、不做常驻提醒** | 服务端在取消/单页失败时返回 `ok = true && partial = true` 的结果（`loadedPages` / `partial`），取消只表示「没抓完」；**部分结果不写短时缓存**。页面提交部分数据后**不弹 Toast、不挂横幅**——中断是用户自己的决定，不需要再被告知一次；只在列表尾部把「已加载全部回复」换成中性的「已加载 n/N 页」（内容边界，不是警告），树内跳转/进度恢复找不到楼层时才改述为「不在已加载页内」。**不提供「继续加载/补齐剩余页」**：想拿全内容用「刷新递进树」整帖重抓。**自动失败**（非用户取消）的部分结果不自动展示，挂在错误态「查看已加载的 n/N 页」由用户选择——残缺树静默展示会让人误以为帖子就这些 **（增量加载下修订：内容已可见时失败保留内容 + 错误条，不再退回全屏错误态；部分数据由尾部文案承载，见新文档 §3.8）** |

## 2. 数据与算法（纯逻辑，已单测）

### 2.1 引用关系提取

**数据源事实（2026-11 复查）**：

| 通道 | 用途 | 楼层 `reply_to` |
| --- | --- | --- |
| `read.php?__output=8`（JSON 主通道） | 工具/样本基准 | **有**：`reply_to` = 被回复楼层 pid |
| `read.php?__output=17`（APP HTML，客户端唯一通道） | 客户端渲染 | **无**：`postArg.proc` 参数与页面里都没有该字段 |

客户端 `ThreadApi.getThread` → `fetchThreadRaw` → `fetchAppArticleHtmlRaw` 只走 `__output=17`，
所以**客户端拿不到 `reply_to`**，引用关系必须从 `content` 文本提取（这是当前唯一可行路径）。
JSON 通道实测（6 页 / 114 个非主楼层）：19 个带服务端引用头，其中 17 个 `reply_to` 与头部
pid **完全一致、0 反例**；2 个跨页 quote 形态缺失 `reply_to`。两个通道的 `content` 逐字一致。
`PostInfo.replyTo` 已保留为**兜底来源**：正文头缺失时用它补边（`resolveParentPid`），
接入 JSON 通道或 HTML 解析器补齐该字段后即自动生效，不改变剥离逻辑。

NGA 楼层 `content` 中表达「回复了哪一层」的头有四种真实形态（样本见 `docs/research/THREAD_TREE_QUOTE_RESEARCH.md`）：

1. 引用块头：`[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]…[/quote]`
   → 目标 pid = A（A 是被引用楼层 pid；B 是**被引用楼层所属主题 tid**；C 是被引用楼层页码）。
2. 回复头（两种形态，头都结束于**作者段 + 日期括号**，不是 `[/b]`）：
   - 标准：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b]<br/><br/>正文`
   - **粘连**：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)正文[/b]`
     （正文与头共用同一个 `[b]` 块，中间没有 `<br/>`；真实样本 tid 47855036 的 16 楼，
     以 `[/b]` 为界会把正文整段吃进引用区，表现为**整层看不见正文**）
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

**头部结束边界与降级规则**（宁可漏剥，不可吞正文）：

- Reply to 头的结束点 = **作者段（`[/uid]`）+ 日期/楼号括号**（`findReplyHeaderEnd` 精确定位）；
  `[/b]` 只是常见收尾，不再是判定依据——粘连形态下 `[/b]` 在正文末尾。
- 粘连形态（`…[/uid] (date)正文[/b]`）：只剥头，正文完整保留；正文末尾那个属于头的 `[/b]`
  一并去掉（要求该 `[/b]` 位于全文末尾、且 `[/b]` 数量恰比 `[b]` 多一个），正文自带的
  `[b]…[/b]` 原样保留。
- Reply to 头**缺 `[/b]`**（或 `[/b]` 之后还有内容、不在末尾）：仍提取引用关系，但**不剥离**，
  保留原文——无法确认头部边界时宁可不剥。
- `[quote]` 块未闭合：仍提取引用关系，但**不剥离**（无法确定块结束位置）。
- 作者只从头部窗口（到 `[/b]` 或第一处 `<br`）解析，被引正文里的 `[uid=…]` 提及不会顶替作者。

由此区分三类容易混淆的形态：

| 形态 | 位置 | 是否回复关系 | 是否从显示正文剥离 |
| --- | --- | --- | --- |
| 服务端引用/回复头 | 正文开头 + 块首链接头 | 是 | 剥离后仍有正文时是；无正文时按楼层标题兜底 / 回退原文 |
| 用户把 `[quote]` 当排版容器（无 pid/tid 头） | 任意位置 | 否 | 否（文字不被吞） |
| 用户复制/手打的引用样式（头在正文中部、或 `[quote]` 块中部才出现链接头） | 正文中部 | 否 | 否 |

`stripQuoteArea` 与 `extractPrimaryQuoteRef` 共用同一次「头部引用区扫描」（`scanLeadingQuoteArea`），
保证「建了边的引用块一定进入剥离判定」「没建边的用户引用样式一定不会被吞」；
剥离后没有正文时不会吞掉该层唯一的文字（按楼层标题兜底或回退原文，见 §3.3.1 第 6 条）。

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
   **例外：单页「空页」跳过**——服务端返回合法帖子页、但整页没有任何可见楼层时
   （`ThreadResult.emptyPage`）不重试、也不整体失败，只记入 `skippedPages` 继续抓其余页；
   缺页提示见 §3.5。第 1 页不适用免重试：它没有「跳过」这条退路（没有主楼就没有
   可渲染内容），仍重试 1 次后再判失败。其余失败（网络 / 超时 / 风控 / 锁定或待审核错误页）
   仍整体失败。有跳过页的结果**不写短时缓存**（下次进入或刷新重抓，有机会补齐）。
   **跳过页数闸门**：跳过页数 ≥ `max(2, ⌈总页数 / 2⌉)` 时不算「局部异常」，按整体失败处理
   （`isSkippedPagesOverwhelming`）——半页以上都空说明帖子状态或抓取链整体异常，
   展示残缺的树只会误导用户。
3. 合并按 pid 去重、按 `lou` 升序，逐页记录 `pageByPid`（含主楼 `0 → 1`）；`covered` 记录已覆盖页
   （成功页 + 跳过空页），由它派生 `loadedPages` / `partial`（`derivePartial` 纯函数：
   `loadedPages < totalPages`）。
4. 每页完成回调 `onProgress(done, total)`；支持 `cancel(owner)`；每次 `fetchAll` 递增代际。
   **取消/单页失败不再丢弃已抓楼层**：已有楼层时装成 `ok = true && partial = true`（取消时另置
   `cancelled`），由页面决定提交还是丢弃（页面销毁时按自身代际丢弃）。没有楼层时 `ok = false`
   （错误态，此时 `partial` 统一归 false）。
   **取消时在途页的成功结果仍会合并**：worker 在 `await fetchPage` 返回后先 merge / 计覆盖、
   再判取消——用户点「查看已加载」时正在途的 4 页若恰好成功返回，都属于「已到手的数据」，
   不能白等。「全部页恰好已覆盖」时取消结果是完整结果（`partial = false`），页面直接建树。
   **不做断点续传**：部分数据之后补齐内容一律走页面的「刷新递进树」整帖重抓。
5. 完成后**后台**预热首屏楼层（前 min(60,n) 条，不阻塞结果提交）。
6. 不写 `savedThreadProgress`，不碰 `ThreadPaginationManager`。

**空页的成因（实测，tid=44191387 / `__output=8` 与 `__output=17` 一致）**：

- 分页按**楼位**（`__ROWS`）计数，删除楼层只在页内留下 lou 空洞、总页数不变：末页 29 的
  lou 560..577 缺 562，仍是 17 楼；`__ROWS=578`、`ceil(578/20)=29` 与真实页数一致。
- 请求页码超过末页时服务端**夹取到末页**（page=30 → `__PAGE=29`，内容与第 29 页逐字节相同），
  所以「翻过头」不会产生空页，`totalPages` 算大也不会。
- HTML 降级解析器**恒输出 `__R`**（正常页与错误页都是空/非空对象，不会缺失），因此空页的
  数据形态只有一种：`__R` 存在但没有任何可用楼层行。它对应两种现实成因：
  1. **这一页的楼位全部不可见**（批量删除 / 审核中 / 被屏蔽）——页面状态，不是请求故障；
  2. 解析器一个楼层锚点都没识别到（结构回归；正常页不会出现）。
  两者都只影响这一页，逐页判死整帖会让局部问题直接锁死整帖，故改为跳过。
- 「空页」判定必须是**整页视图且无服务端过滤**（`isEmptyWholePage`）：单帖视图 0 楼层是
  「目标楼层已删除」，只看楼主（带 `authorid`）某页为空是过滤结果，都不能当成空页跳过。

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
单帖楼层数超过 3000 时不写缓存（超大帖全量常驻内存会显著抬高峰值）；含跳过页的结果也不写缓存。
**部分结果（取消/失败）绝不写缓存**——否则 90 秒内重进会直接读到残缺树。
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
- **取消的三种消费方**（服务端不区分取消发起方，由页面按「谁触发的取消」决定去向）：
  1. **用户点「查看已加载」**：页面 `interrupting = true` 快照下收到 `cancelled = true` 的结果，
     直接提交（完整则建完整树，部分则建部分树）；
  2. **页面销毁**：`cancelWork()` 已推进代际，结果按 `generation` 丢弃；
  3. **被其他页面/任务抢占**（平板多列下本页被路由覆盖但仍存活、代际不变）：页面在结果回调里
     先快照 `interrupting`，发现 `cancelled && !interrupting` 时不自动提交部分树、不写历史、
     不弹提示；已抓完则正常建树，只抓了一部分则暂存到错误态的「查看已加载」入口，由用户决定。
     文档旧版说的「被抢占即按代际丢弃」对多列覆盖场景不成立，**以本条为准**。
- 调用方（`ThreadTreePanel`）为每个页面实例生成唯一 `treeOwner`（时间戳 + 随机数），所有 `cancel`/`fetchAll` 都带它。

## 3. 树页 UI（`pages/ThreadTreePanel.ets`）

### 3.1 页面结构

```
Stack
├─ Column：isLoading → LoadingState；hasError → ErrorState；ready → TreeList
│   └─ TreeList（List + LazyForEach + 末尾 LoadEndFooter：完整时「已加载全部回复」，
│       部分数据时「已加载 n/N 页」）
├─ PanelNavBar（标题=帖子标题（楼主被屏蔽时显示占位），更多菜单，滚动联动渐变模糊）
└─ BottomBar（回复主题按钮，HdsMaterialHost；仅树就绪时显示；按握姿贴左/贴右）
```

**没有部分数据横幅**：主动中断是用户自己的操作，页面不挂常驻提醒、不弹 Toast；
`contentStartOffset`、`getProgress`、`getBlurStops` 仍统一按标题栏高度计算。

### 3.2 根节点行

直接复用 `PostItem`（完整楼层卡片：头像、楼主标记、**楼层标题**、正文、附件、签名、投票栏、贴条、热回复）。
与列表模式的区别只在「行序」与「所在页面」；不做额外视觉标记，靠子节点缩进与折叠行表达树形态。
楼层标题（`subject`）非空时显示在时间行与正文之间（对齐官方网页 `h3#postsubject{lou}`），
列表模式与树页根行走同一个 `PostItem`，行为一致。**主楼（`lou === 0`）除外**：它的 `subject`
是主题标题、页面标题栏已经展示，卡片内不重复；判定统一走 `ThreadTreeBuilder.resolveFloorSubject`
（主楼排除 + HTML 实体解码后判空）。

### 3.3 子节点行（`common/components/thread-tree/ThreadTreeChildItem.ets`）

自上而下：

```text
头像 24  用户名 [楼主] [备注]                         #当前楼层号
时间 [编辑时间]
回复 @被回复者 #被回复楼层号  →（仅回复更深祖先时显示）
楼层标题（subject 非空时，纯文本）
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
- 时间行 → 回复关系行（可选）→ **楼层标题**（`subject` 非空时）→ 正文（`BBCodeContentView`）→
  附件（`PostAttachments`）→ 操作栏（`PostVoteBar`）。楼层标题对应官方网页
  `<h3 id='postsubject{lou}'>`（15vp、Medium、`textPrimary`），纯文本渲染（HTML 实体解码，不解析 BBCode）。
- 正文使用父组件传入的 `displayContent`（已剥离引用区）：树的两层关系已表达「回复了谁」，
  正文不再重复显示 `[quote]` 块 / `Reply to` 头。**整层只有引用区时按标题兜底**（§3.3.1 第 6 条）：
  - 有楼层标题 → `displayContent` 置空，正文块不渲染，标题作为该层唯一文字（头像/时间/附件/动作栏照常）；
  - 没有标题 → `displayContent` 回退原文，至少保留引用头，不让整层空白。
- 不渲染签名/投票/贴条/热回复。黑名单作者 → 保留头部、正文区替换为「该用户已被屏蔽」
  （标题与正文一起被占位替换，不单独显示标题）。
- 视觉：左侧 `padding 40`、左侧 2vp 竖线、**无卡片底色**（透明；层级只靠缩进与竖线表达）、
  高亮 `selectionTint`（2 秒自动清除）。

### 3.3.1 引用区剥离（`resolveTreeDisplayContent` / `stripQuoteArea`）

树模式所有节点（含根行）正文统一经**头部引用区扫描**（`scanLeadingQuoteArea`）处理，
再由 `resolveTreeDisplayContent` 决定显示内容；`stripQuoteArea` 是同一套判定的通用剥离入口
（测试/诊断用，树模式不直接调用）。

1. 只剥离**服务端引用区**：正文开头（允许前导空白 / `<br/>` / `&nbsp;`）的
   `[b]Reply to …[/b]` 回复头（pid 与 `[tid]Topic[/tid]` 两种），或块首就是 `[pid=…]`/`[tid=…]`
   链接头的 `[quote]…[/quote]` 块；
2. 与 `extractPrimaryQuoteRef` 共用同一次扫描（`scanLeadingQuoteArea`），判定完全一致；
3. 最多剥离一个引用区（`Reply to` 头 + 紧跟的一个引用块，或一个引用块）；连续第二个服务端引用块
   也保留（属于用户拼接的正文）；
4. Reply to 头按「作者段 + 日期/楼号括号」定位结束点，**不以 `[/b]` 为界**：标准形态
   `…(date)[/b]<br/>正文` 与粘连形态 `…(date)正文[/b]` 都只剥头、正文完整保留——后者是
   真实数据形态（tid 47855036 的 16 楼），以 `[/b]` 为界会把正文整段吞掉、整层看不见内容；
5. 剥离后清理开头的空白与 `<br/>`，其余正文格式原样保留；粘连形态下正文末尾残留的头部 `[/b]`
   一并去掉（正文自带的 `[b]…[/b]` 保留）；
6. **保守剥离（剥离后必须有正文）**：引用区之后没有任何可见正文的楼层——`content` 只有
   `[b]Reply to …[/b]` 头、只有一个 `[quote]` 块，或只剩空白/`<br/>`/`&nbsp;`（真实数据如
   tid 47864458 的 4 楼：整层只有一行 Reply to 头）——按**楼层标题**兜底（`resolveTreeDisplayContent`）：
   - 楼层标题非空（`resolveFloorSubject`：主楼排除、HTML 实体解码后判空）→ 正文置空，
     标题作为该层唯一文字（标题与引用头同时显示会重复）；
   - 标题也为空 → 回退原文，保留引用头/引用块，不让整层空白。
   `stripQuoteArea`（通用剥离，无楼层上下文）同样在剥离后为空时返回原文。
   「剥离后为空」只在**确实识别并剥离了引用区**（`scan.ref !== null`）时成立：正文本身只有
   空白噪音时不属于引用区，displayContent 保持空串（不渲染空正文块）。
   这是「宁可漏剥，不可吞正文」原则的延伸；
7. **不剥离**：正文中部出现的 `[quote]` 块、开头没有链接头的 `[quote]`（用户把 `[quote]` 当排版容器）、
   未闭合的 `[quote]` 块、缺 `[/b]` 闭合或 `[/b]` 不在末尾的 Reply to 头——这些要么是用户正文，
   要么无法确定边界，删掉会造成「文字被吞」的意外表现；
8. 平衡扫描与标签比较按**原串下标**逐字符进行（不做整串 `toLowerCase`），避免 `İ` 等字符小写化
   变长导致剥离位置切在字符中间；单遍 O(n)，长引用块不会退化成 O(n²)。

剥离结果缓存在 `ThreadTreeRoot/ThreadTreeChild.displayContent`，由 `flattenThreadTree` 复制到行上；
`PostItem` / `ThreadTreeChildItem` 通过 `displayContent` + `showContent` 渲染（默认不传时行为与自然列表完全一致）。

### 3.4 折叠行（`ThreadTreeMoreItem.ets`）

文案 `共 N 条回复，点击查看`（13vp `textTertiary`）+ 下箭头，高 40、同缩进、整行点击展开全部子节点。

### 3.5 加载态 / 错误态 / 部分数据

> **本节的「全屏加载态 + 三种出口」已被增量加载取代**（2026-11-07）：进入后第 1 页到达即渲染，
> 后续页按水位增量追加，底部进度胶囊显示进度并可随时停止；失败时保留已渲染内容 + 错误条（v8：胶囊已从标题栏下缘迁到页面底部、改用 HDS 材质，见 `THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.3 / §10.8）。
> 现行行为见 `docs/THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.1 / §3.3 / §3.8 / §10。
> **页内出口已全部移除**（2026-11-08）：`ENTERING` 只剩居中加载圈（400ms 延迟淡入），
> 与列表页 `ThreadPanel.LoadingState` 同构；退出走返回键，切换列表走更多菜单。
> 下文保留为历史契约，不再作为实现依据。

- 加载态：`LoadingStateView` + 「正在加载全部楼层 n/N 页」+ 线性进度条 + **三种出口**：
  - **「查看已加载 n/N 页」**（主按钮）：中断抓取，把已抓楼层送进树（见 §3.5.1）。第 1 页尚未返回时
    按钮禁用（没有可展示数据），但仍占位、不跳动；
  - **「取消」**：终止抓取并退出递进树（`routerStore.back()`）——递进树条目替代了列表页，
    页面栈里没有「原来的视图」可退，取消就是放弃这次阅读；
  - **「以常规列表打开」**：不必等全帖抓完、也不必先退出帖子——终止在途抓取（在途回调失效）
    并把当前递进树栈条目原地替换为列表页，树条目移除、页面实例销毁。
  点击「查看已加载」后收起三个按钮、显示「正在中断加载…」：在途请求没有真正的中止手段，
  服务要等当前批次收尾（通常 1~3 秒，最坏为单页超时的 15 秒），重复点击无意义。
- 错误态：`ErrorStateView(msg, onRetry)`（重试重新抓取）。**失败前已抓到楼层**时追加
  「查看已加载的 n/N 页」：失败的部分结果不自动展示（残缺树会让人误以为帖子就这些），
  但也不丢弃，由用户主动选择先读已抓部分。暂存结果同时带上失败时的**定位锚点与标题策略**
  （`failedPartialAnchorPid` / `failedPartialKeepSubject`）——刷新失败后再看部分数据仍旧停在
  刷新前的阅读位置，不会跳回顶部。
  另一种进入错误态的路径是**被其他页面/任务抢占**（平板多列下本页被路由覆盖但它仍存活，
  另一个页面启动的 `fetchAll` 会取消本页任务）：错误文案为「加载被其他操作中断」，
  若任务被取消时已抓完则直接建树，只抓了一部分同样挂在「查看已加载」入口上，不替用户自动提交。
- **部分页被跳过**（服务端返回合法空页）：树照常展示。缺页信息不能只靠一次性 Toast——
  Toast 是单条替换语义，紧随其后的「检测到上次阅读进度」会把它顶掉，因此提供三条出口：
  1. 加载完成后 Toast「第 X 页缺少楼层，已跳过」（超过 3 页时报总数 + 前 3 个页码示例）；
  2. 列表尾部常驻「已加载全部回复（第 X 页缺少楼层）」；
  3. 有上次阅读进度时，恢复提示合并为「检测到上次阅读进度（第 X 页缺少楼层）」。
  用户刷新即可重抓补页，缺页结果不进短时缓存。

#### 3.5.1 部分数据（人工中断 / 失败后查看已加载）

部分数据是**一等状态**，不是错误态的变体。提交后树正常渲染，但**不做任何常驻提醒**：

- **不弹 Toast、不挂横幅**。主动中断是用户自己的决定，「已加载 n/N 页」不需要再被
  告知一次；页面也不因此变色或加警告条。
- 唯一的中性表达在**列表尾部**：把「已加载全部回复」换成「已加载 n/N 页」
  （缺页时附「第 X 页缺少楼层」）。它是内容边界标识，不是提醒。
- 树内跳转（`→` / 同帖链接）与阅读进度恢复找不到楼层时，部分数据下改述为
  「不在已加载的 n/N 页内，可刷新」，不谎报「不存在/已删除」。

**不做断点续传**：页面不提供「继续加载/补齐剩余页」，更多菜单也不新增补齐项。
理由：续抓要引入「中断 → 再开始」的第二套状态（进度起点、代际、已覆盖页、跳过页合并、
与刷新的语义分叉），复杂度远高于收益；想拿全内容直接用「刷新递进树」整帖重抓（重抓期间
回到整页加载态，行为单一、可预期）。部分数据提交后页面的 `partialData` /
`partialLoadedPages` / `partialTotalPages` 只服务尾部文案与「未加载页」的提示口径，
不参与任何后续抓取。

### 3.6 菜单（与列表页同构）

树页与列表页共用同一套多功能下拉结构，只有「刷新」与「切换阅读方式」两项按样式命名：

| 序 | 列表页 | 树页 | 说明 |
| --- | --- | --- | --- |
| 1 | 收藏到… / 管理收藏 | 同左 | 打开收藏夹多选页 |
| 2 | 离线保存帖子 | 同左 | 保存页范围弹窗 |
| 3 | 跟踪帖子更新（激活态） | 同左 | 跟踪设置弹窗 |
| 4 | 只看楼主（激活态） | 同左 | 列表页请求过滤；树页按楼主重建树 |
| 5 | 切换为递进树阅读 | 切换为列表阅读 | 阅读方式切换（ListCell）：只携带只看楼主、楼主身份与路由来源，**不携带位置**；两种样式各自恢复自己的阅读进度；**原地替换**当前栈条目，另一种样式的页面实例随替换销毁 |
| 6 | 刷新帖子 | 刷新递进树 | 按当前阅读位置重载；部分数据时这也是拿到全内容的唯一入口（整帖重抓，不做断点续传） |
| 7 | 从网页打开 | 同左 | WebView |
| 8 | 分享帖子 | 同左 | 分享链接 |

排序按「保存订阅（1–3）→ 阅读视图（4–6）→ 外部动作（7–8）」三段；视图组内部为
「只看楼主 → 切换阅读方式 → 刷新」，刷新固定在本组末尾：它既是唯一的整页重载动作，
树页更是重抓全帖（4 路并发 + 限流，长帖可达数十秒、期间整页为加载态），
不能紧跟在高频的「跟踪」下方。

> 树页「只看楼主」下，被过滤掉父楼层的根行会保留原始正文（含引用块），
> 让卡片继续表达“回复了谁”；否则根行只剩一张没有回复上下文的卡片。
> 两种阅读样式互斥：切换一律原地替换当前栈条目（`navigateActivity(screen, true)`），
> 被替换的页面实例销毁，返回直接回上一层，不会退回另一种阅读样式。

离线存档来源的列表页不出现 1/2/3/5（存档无网络来源），保留 4/6/7/8；裁剪后的顺序为
「在线模式打开 / 只看楼主 / 刷新帖子 / 从网页打开 / 分享」，「刷新」仍留在视图组末尾。

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
静默带到无关楼层；pid 找不到时宁可提示「原阅读位置已不可用」。**部分数据下区分口径**：
锚点不在已加载页里时提示「上次阅读位置不在已加载的 n/N 页内，可刷新后恢复」，
不能谎报楼层已不可用（与 `missingFloorHint` 对「→」跳转/同帖链接的处理一致）。

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
只看楼主 / 切换为递进树阅读 / 刷新帖子 / 从网页打开 / 分享；离线存档来源去掉网络相关项
（在线模式打开 / 只看楼主 / 刷新帖子 / 从网页打开 / 分享）。
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

`entry/src/test/ThreadTreeBuilderUnit.test.ets`（80 例，在 `List.test.ets` 注册）覆盖：

1. 引用头提取：quote 头 / Reply to 头（pid 与 `[tid]Topic[/tid]` 两种，标准形态与**粘连形态**）/
   主楼 Topic 头 / `[pid=0]` 主楼哨兵 / 匿名 uid / 跨帖 / 多引用取第一 / 无引用 / 头部前空白 /
   未闭合 Reply to 头（提取但不剥离）/ 缺 `[/b]` 且正文含 `[b]`（不剥离）/ 头结构不可定位时只提取不剥离；
2. **引用区位置与结构边界**（本次补强）：正文前缀后不提取、正文中部引用样式不提取、无链接头的 `[quote]`
   不提取、块中部才出现链接头不提取、块首前噪音（`<br/>`）仍提取、作者只从头部窗口解析；
3. 建树：引用主楼 → 根；引用不存在 pid → 根；自引用 / 环 → 提升为根不丢楼；深层引用平铺；主楼无子节点；
   用户排版引用样式保留在正文且楼层为根；**`reply_to` 兜底建边**（正文头缺失时补边、正文头优先于
   `reply_to`、`reply_to` 指向主楼/不存在 → 根）；
4. 折叠：3 条全显、4 条显 2 + MORE(hidden=2)、展开后全显、未知根不可展开；
5. 排序与查找：根/子行按楼号升序、`findRootPidByPid` 语义、`findRowIndexByPid`；
6. 剥离：服务端引用块 / 回复头剥离、**粘连回复头只剥头保留正文**（单行 / 多行 / 正文含 `[b]…[/b]` /
   正文以 `[color=…]` 开头 / 正文以普通括号开头 / `[/B]` 大写闭合）、
   `[/b]` 后直接正文、嵌套服务端块按深度平衡剥离、主楼引用块剥离、用户排版引用（含嵌套）保留、
   服务端块后的用户引用样式保留、连续两个服务端块只剥第一个、正文中部引用不动、未闭合块提取但不剥离、
   约 8K 字符长引用块线性完成；**仅引用 / 仅回复头 / 引用块后只剩 `<br/>` 时回退原文**；
7. **楼层标题兜底**（本次新增）：只有标题 → 正文置空（只有引用头 / 只有 `[quote]` 块两种形态）；
   有标题且有正文 → 正文照常保留；无标题 → 回退原文；主楼 `subject`（主题标题）不当楼层标题；
   空白噪音正文（`'   '` / `<br/>`）保持空串不回退；
8. **楼层标题判定**：`resolveFloorSubject` 主楼排除、空/纯空白/`&nbsp;` 判空、HTML 实体解码；
9. **只看楼主根行上下文**：`needsRootQuoteContext` 过滤后普通根行需补、只有标题的根行不补、无引用根行不补。

门禁：`hvigorw assembleHap` 编译通过 + `hvigorw test` 通过 + `node scripts/check-eol.mjs` 通过；
镜像 `sync-to-ets.mjs --dry` 0 修改。

一次性引导另有 `entry/src/test/ThreadTreeGuideUnit.test.ets`（在 `List.test.ets` 注册）：覆盖触发策略的
三条排除规则（已提示 / 离线存档 / 默认树样式），以及 meta 标记的磁盘兼容读取（字段存在 / 旧数据缺字段 /
坏字段三种输入的归一化结果）。

「异常页跳过」与「部分数据」策略由 `entry/src/test/ThreadTreeFetchUnit.test.ets`（在 `List.test.ets` 注册）覆盖纯判定：
空页判定（整页空 / 单帖视图 / 服务端 `authorid` 过滤 / 有原始楼层行 / `__R` 缺失）、
可跳过失败（空页跳过；网络错误、错误页、风控、成功页都不跳过）、跳过页数闸门
（2 页缺 1 页保留、3 页缺 2 页与 29 页缺 15 页整体失败、29 页缺 14 页保留）、
以及第 1 页空页与普通失败的用户文案。
部分数据侧覆盖 `derivePartial` 的三种口径（未覆盖完 → 部分、全部覆盖 → 完整、
总页数未知 → 不判部分），以及 `ThreadTreeFetchResult` 默认值为「完整」口径
（`partial=false`、`loadedPages=0`，防止漏填被误判部分数据）。

## 7. 文件清单与写入归属

| 文件 | 归属 |
| --- | --- |
| `model/ThreadTree.ets` | Lead（先行冻结） |
| `common/utils/ThreadTreeBuilder.ets` + `entry/src/test/ThreadTreeBuilderUnit.test.ets` + `List.test.ets` 注册 | 数据层成员 |
| `service/ThreadTreeFetchService.ets` | 数据层成员 |
| `entry/src/test/ThreadTreeFetchUnit.test.ets`（异常页跳过 + 部分数据覆盖单测） | 数据层成员 |
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
8. **同一空页在「离线保存」路径仍硬失败（未覆盖）**：`SavedThreadService.saveThread` 对某页 0 楼层
   保持「缺页即失败」（存档语义要求完整，不能静默丢页），而保存弹窗默认结束页 = 服务端总页数。
   因此遇到「某页整页不可见」时，同一页面里的树阅读可以跳过该页，但离线保存会失败并提示
   「第 X 页没有楼层，帖子可能已失效」。若线上高频出现，应在保存对话框先探测空页并排除该页范围。

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
    - 树页更多菜单与列表页同构（收藏 / 离线保存 / 跟踪 / 只看楼主 / 切换阅读方式 / 刷新 /
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
      **后续已被第 16 条/D14 取代**：取消改为终止并退出，且已抓楼层不再丢弃（见 §3.5）。
14. **引用区剥离边界修复与 `reply_to` 兜底（2026-11，线上缺陷 tid 47855036 #16）**：
    - 现象：#16 回复 #5，树页该层**看不见任何正文**；列表页同样中招（引用注入后正文消失）；
    - 根因：该层 `content` 是粘连形态
      `[b]Reply to [pid=…#5]Reply[/pid] Post by [uid=…] (date)正文[/b]`——正文与头共用同一个
      `[b]` 块。两处实现都以 `[/b]` 为头部结束：树构建器把整段正文当作引用区剥掉
      （`displayContent` 为空、`showContent=false`）；引用注入（`buildReplyQuoteContent`）
      取 `[/b]` 之后的文本当本层正文，得到空串，正文整段丢失；
    - 修复（树构建器）：Reply to 头改为按「作者段 + 日期/楼号括号」精确定位（`findReplyHeaderEnd`）；
      粘连形态只剥头、保留正文，并去掉正文末尾属于头部的 `[/b]`；缺 `[/b]` 或 `[/b]` 不在末尾时
      仍不剥离（沿用「宁可漏剥，不可吞正文」）；
    - 修复（列表引用注入，`tools/bbcode-ts/src/common/utils/QuoteInjectionCore.ts` 镜像真源，
      已 `npm run sync` 回写）：`splitReplyHeader` 用同一套边界切分「头 / 本层正文」；
      `cleanReferencedContent` 同步支持去掉被引用楼自身的粘连 Reply to 头；
    - 修复（评论区）：`PostComments` 的 `stripPostByHeader` 也是按 `[/b]` 截断（`^\[b\]Reply to[\s\S]*?\[\/b\]`），
      粘连形态下会把评论正文整段吃掉；改为 `QuoteInjection.stripCommentReplyHeader`
      （作者段 + 日期/楼号括号定位、支持匿名头，剥离后为空时回退原文）；
    - 数据源复查：JSON 主通道（`__output=8`）的楼层带 `reply_to`（与头部 pid 17/17 一致、0 反例），
      但客户端唯一通道 APP HTML（`__output=17`）**没有**该字段，故引用关系仍以文本解析为主，
      `PostInfo.replyTo` 作为正文头缺失时的兜底（`resolveParentPid`）；
    - 单测：树构建器从 52 例扩展到 61 例（新增粘连形态提取/剥离、多行正文、正文含粗体、
      `[/b]` 后直接正文、`reply_to` 兜底建边、正文头优先、`reply_to` 指向主楼/不存在）；
      Node 侧引用注入从 6 例扩展到 8 例、Hypium 引用注入从 4 例扩展到 6 例
      （粘连头保留本层正文、被引用楼自身是粘连头时只注入正文）。
15. **独立 review 补修（2026-11，同一缺陷的残余边界）**：
    - H1：`findReplyHeaderEnd` 的头部尾部原为「循环消费任意 `(…)` 与任意 `[color=…]…[/color]`」，
      粘连形态 + 正文首元素是短颜色块（或普通括号短语）时仍会被当头部吞掉；改为**每类至多一个**
      且括号必须是日期/楼号模式（`(YYYY-MM-DD HH:MM)` / `(N楼)`、可被一个 `[color=…]` 包裹）；
    - M1：`ReplyManager.buildQuotePrefix` 仍按 `[/b]` 清洗被回复楼正文（回复该楼时引用预览看不到
      对方正文），改用 `QuoteInjectionCore.stripReplyToHeader`；
    - M2：评论区宽松正则（`[b]Reply to …[/b] …[uid=…]…（…）`）会把非服务端头误当回复头吞掉前缀，
      改为要求 `[pid=…]/[tid=…]` + `Post by` 结构；
    - M3：`matchReplyToHeader` 的回退路径（头结构不可定位）原按 `[/b]` 猜测边界，粘连 + 结构异常
      （如作者名超长）会吞正文；改为**只提取关系、不剥离**（`isSafeReplyHeaderClose` 随之移除）；
    - L1/L2：评论头 `…(日期): [/b]` 与 `[color=gray](224楼)[/color] (日期)` 形态的识别补齐
      （标准形态允许 `[/b]` 前有空白/冒号；颜色包裹的楼号可出现在日期括号前）；
    - L3：注入路径粘连 + 正文自带 `[b]…[/b]` 时残留末尾 `[/b]`，`splitReplyHeader` 改为
      「末尾闭合 + `[/b]` 比 `[b]` 多一个」判定；
    - L4：`trimTrailingQuoteBold` 改用大小写不敏感的 `[/b]` 查找；
    - 单测：树构建器 61 → 65 例；Node 引用注入 8 → 11 例；Hypium 引用注入 6 → 7 例
      （新增评论头剥离与不误吞用例）。
16. **加载中人工中断与部分数据（2026-11）**：
    - 原逻辑：全帖抓取必须抓完才能建树，取消只终止抓取并停在错误态——长帖抓几十秒时，
      用户点「取消」等于把已经抓到的大部分楼层一起丢掉；
    - 服务层：`ThreadTreeFetchResult` 新增 `partial` / `loadedPages`；
      `cancel` 不再丢弃已抓楼层，取消/单页失败时返回 `ok = true && partial = true` 的结果
      （`buildInterruptedResult` / `buildFailedResult`，与完整结果共用 `fillMergedResult`，
      覆盖口径完全一致）；部分结果不写短时缓存；
    - 页面：加载态「查看已加载 n/N 页 / 取消 / 以常规列表打开」三出口；取消 = 终止并退出；
      错误态在失败前有楼层时追加「查看已加载的 n/N 页」（不自动展示残缺树）；
      部分数据**不做常驻提醒**：只在列表尾部把完成文案换成中性的「已加载 n/N 页」；
    - **明确不做断点续传**（交付后按用户要求砍掉）：第一版曾实现 `ThreadTreeResumeSeed` +
      `fetchAll(seed)`（复用已抓楼层、只补缺失页）与横幅/尾部/菜单三处「补齐」入口，但续抓会引入
      「中断 → 再开始」的第二套状态与刷新语义分叉，收益不足，已整体移除；部分数据后想拿全内容
      走「刷新递进树」整帖重抓；
    - 单测：`ThreadTreeFetchUnit` 保留部分结果默认形态用例（`fetchResultDefaultsToCompleteShape`）。
17. **独立双 Agent review 修复（2026-11）**：
    - **跨页面抢占不再冒认用户中断**：平板多列下本页被路由覆盖但仍存活时，另一个页面启动的
      `fetchAll` 会取消本页任务；页面先快照 `interrupting`，`cancelled && !interrupting` 时不自动
      提交部分树、不写历史、不弹提示；已抓完则正常建树，只抓了一部分则暂存到错误态
      「加载被其他操作中断」+「查看已加载」入口（数据不丢）；
    - **取消时在途成功页不再丢弃**：worker 先 merge / 计覆盖再判取消，用户点中断时正在途的
      页若成功返回也计入 `loadedPages`（原来最多白丢 4 页≈80 楼）；「全部页恰好已覆盖」时
      取消结果是完整结果，直接建树；
    - **部分数据下的文案不再谎报删除**：`→` 跳转、正文同帖链接、阅读进度恢复三处统一
      `missingFloorHint` 口径——部分树里找不到时提示「不在已加载的 n/N 页内，可刷新」，
      完整树仍提示「不存在/已删除」「原阅读位置已不可用」；
    - **错误态「查看已加载」保留刷新锚点**：`failedPartialAnchorPid` / `failedPartialKeepSubject`
      暂存失败时的定位与标题策略，刷新失败后再看部分数据不会跳回顶部；
    - **口径修正**：`derivePartial` 纯函数统一 `partial` 判定；`ok=false` 时 `partial` 归 false；
      中断结果保留中断前的页失败原因；`buildInterruptedResult` / `buildFailedResult` 共用口径；
    - **UI 细节**：加载态动作区固定 68vp（中断提示不再造成约 20vp 跳动）、禁用态主按钮
      改用 `bgSecondary + textSecondary`（原 `bgTertiary + textTertiary` 对比度约 1.6:1）、
      部分数据尾部附缺页提示；
    - 单测：`ThreadTreeFetchUnit` 新增 `threadTreePartialResult` 的 `derivePartial` 三例
      （未覆盖完 / 全部覆盖 / 总页数未知）。
18. **按用户反馈收掉「部分数据」的噪音表达（2026-11）**：
    - 用户指出：主动中断是自己点的，页面再常驻一条「已加载 n/N 页 / 内容不完整」是重复告知；
    - 删除标题栏下方的部分数据横幅（含 46vp 固定高度、`contentStartOffset` 让位、
      `getBlurStops` / `getProgress` 的避让换算），页面结构恢复为「列表 + 标题栏 + 底部回复」；
    - 删除部分数据的 Toast；删除横幅相关的 `partialReason` 状态与 `partialBanner*` 方法；
    - 保留：列表尾部中性文案「已加载 n/N 页（缺页时附说明）」、错误态「查看已加载」入口、
      `missingFloorHint`（部分数据下不谎报楼层已删除）；
    - 文档 D14/§3.1/§3.5.1 同步改为「不做常驻提醒」。
19. **楼层标题展示 + 保守剥离（2026-11，线上反馈 tid 47864458 的 4 楼）**：
    - 现象：4 楼回复 2 楼但只点了回复、没有写正文，`content` 只有一行
      `[b]Reply to [pid=…]Reply[/pid] Post by [uid=…]…[/uid] (日期)[/b]`。树页构建模型时
      剥离引用区得到空串，子行 `showContent=false`，整层只剩头像/时间，用户描述为
      「非标准的回复结构导致剔除了全部文本」；
    - 数据核对（JSON `__output=8` / HTML 降级双通道一致）：4 楼 **`subject` = 「这还没反转？你也是6」**，
      `content` 只有引用头（NGA 的 `content_length` 字段是纯文本长度 36，与 BBCode 原文长度不同，
      不作为判据）。官方网页该层渲染为
      `<h3 id='postsubject4'>这还没反转？你也是6</h3>` + `<span id='postcontent4'>[b]Reply to …[/b]</span>`
      —— 用户看到的「正文」实际是楼层标题；客户端历史上**从不渲染楼层 `subject`**，
      列表/树两种模式都看不到它，树模式再叠加「剥离后空正文」，于是整层空白；
    - 修复 1（楼层标题）：`PostItem` 与 `ThreadTreeChildItem` 在时间行之后、正文之前显示
      `subject`（纯文本 + HTML 实体解码，15vp Medium，对齐官方 `h3#postsubject{lou}`）；
      列表模式、树页根行、树子行统一生效。判定收敛到 `ThreadTreeBuilder.resolveFloorSubject`：
      **主楼（`lou === 0`）排除**（其 `subject` 是主题标题，页面标题栏已展示），实体解码后判空
      （`&nbsp;` 不算标题）；
    - 修复 2（保守剥离）：树构建改用 `resolveTreeDisplayContent`——引用区之后没有可见正文时，
      有楼层标题 → 正文置空（只显示标题，避免与引用头重复）；标题也为空 → 回退原文
      （保留引用头，不让整层空白）。`stripQuoteArea` 通用剥离在为空时同样回退原文；
      「为空」只在确实识别并剥离了引用区（`scan.ref !== null`）时成立，正文本身只有空白噪音时不回退；
      空白判定复用 `QuoteInjectionCore.isBlankBodyText`（空白/`<br>`/`&nbsp;`）；
      只看楼主的根行上下文判定抽成 `ThreadTreeBuilder.needsRootQuoteContext`（纯函数），
      「只有标题」的根行不再补回引用上下文；
    - 普通列表模式（`ThreadPanel`）自始至终不调用引用区剥离，`PostItem.displayContent` 只在树页传入、
      缺省为空串即回退 `post.content`；列表页看不到 4 楼那句是「标题未渲染」，不是被剔除影响；
      列表页对 Reply to 头走的是引用注入（展开成 `[quote]` 块并填入被引用楼正文）；
    - 修复 3（评论区同策略）：`QuoteInjectionCore.stripCommentReplyHeader`（已从 adapter 下沉到
      TS 镜像真源，Node 侧有回归）在剥离后没有可见正文（`isBlankBodyText`）时返回原文；
      `PostComments.commentNodes` 改为按「过滤后是否还有可渲染节点」回退——只有回复头（保留
      `POST_BY`）或只剩 `[quote]` 块时不再留下空气泡；`injectQuoteContent` **不再处理 `comments`**
      （评论气泡始终过滤 `[quote]`，注入只会把 Reply-to 头改写成隐藏块、让保守兜底失效）；
    - 朗读 / AI 总结：楼层标题非空时前置（标题-only 楼层只读标题，不再把 Reply-to 头当正文念）；
    - 文档：§2.1 剥离约束、§3.2 / §3.3 / §3.3.1 第 6 条、§6 测试清单同步更新；
    - 单测：树构建器 80 例（新增 `keepsBodyWhenFloorHasSubjectAndBody`、
      `clearsDisplayContentForQuoteOnlyFloorWithSubject`、`keepsEmptyDisplayContentForBlankNoiseContent`、
      `threadTreeFloorSubject` 3 例、`threadTreeRootQuoteContext` 3 例；剥离侧
      `keepsOriginalWhenOnlyQuoteRemains` / `keepsOriginalWhenOnlyReplyToHeaderRemains` /
      `keepsOriginalWhenOnlyQuoteWithTrailingBreaks`）；评论侧新增
      `keepsCommentReplyHeaderWhenNoBodyRemains`（只有头 / 头+空行 / 头+`&nbsp;` 回退原文，
      有正文仍正常剥头）与 `leavesCommentsOutOfQuoteInjection`（评论不被注入改写、楼层仍注入）；
      Node 侧 `quote-injection.test.ts` 新增 `stripCommentReplyHeader` 与 `isBlankBodyText` 用例；
    - TS 镜像样本：`samples/tid47864458-lou4-replyto-only.txt`（真实 `content`）已登记
      `samples.lst` 并生成快照，`npm test` 249 通过——快照证明该 `content` 解析结果只有一个
      `POST_BY` 节点、没有任何正文文本（`subject` 不属于 BBCode 正文，UI 层由上述修复覆盖）。
20. **进入加载态收敛到列表页同款（2026-11-08）**：
    - 用户反馈：增量加载下第 1 页通常不到一秒就到，`ENTERING` 屏仍摆着「取消」「以常规列表打开」
      两个文字按钮，像一次决策页，与列表页的极简加载不一致；
    - 页面：`LoadingState()` 改为与 `ThreadPanel.LoadingState` 完全同构——只有居中
      `LoadingStateView`，外层 `opacity` 走新增的 `enteringLoadingOpacity`；进入时置 0，
      400ms 后仍在 `ENTERING` 才 `animateTo(150ms)` 淡入（与列表页 `loadPosts` 的 400ms 节奏一致），
      缓存命中 / 快路径完全不闪 loading；
    - 出口：删掉「取消」（`cancelWork()` + `routerStore.back()`）与「以常规列表打开」
      （`replaceWithListReading()`）两个按钮，`cancelLoadingAndExit()` 一并删除；退出改走标题栏返回 /
      系统返回手势（`aboutToDisappear` 会 `cancelWork()`，在途抓取不泄漏），切换列表改走更多菜单
      「切换为列表阅读」（`ENTERING` 阶段菜单即可用）；
    - 旧模型残渣清理：`isLoading` / `hasError` / `progressDone` 三个不再被 UI 读取的状态已删除
      （加载态语义统一由 `phase` 承担，对应 `THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §4.11 E2）；
      `threadTid` 为空时直接落 `FAILED`，不再停在 `ENTERING` 加载屏；
    - 文档：D11 括号说明、§3.5 提示，以及 `THREAD_TREE_INCREMENTAL_LOAD_DESIGN.md` §3.1 / §9 / §10 同步。
