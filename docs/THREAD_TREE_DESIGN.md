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

### 1.1 两种阅读样式 = 两个独立页面

| 样式 | 页面组件 | 数据来源 | 列表结构 | 页面栈 |
| --- | --- | --- | --- | --- |
| 列表（LIST） | `pages/ThreadPanel.ets`（现有，不改动窗口语义） | 连续分页窗口（`ThreadPaginationManager`） | 自然楼层顺序，`PostItem` | `Screen.thread`（现有） |
| 递进树（TREE） | `pages/ThreadTreePanel.ets`（新增） | 一次性全帖抓取（`ThreadTreeFetchService`，独立数据） | 两层扁平树（根行 + 子行 + 折叠行） | `Screen.threadTree`（新增） |

**页面隔离原则（本次设计的核心）**：

1. 两个页面**不共享任何可变状态**：树页不读也不写 `ThreadPaginationManager` 的窗口、不碰 `PostInfoDataSource`、
   不复用列表页的滚动/定位/阅读进度事务；列表页也不感知树页的模型与数据源。
2. 树页自己负责「加载 → 进度 → 渲染 → 刷新」全生命周期；列表页只提供一个入口（更多菜单）。
3. 两页之间的唯一交互是路由：从列表页进入树页 = push 新栈条目；返回 = `back()`，列表页原样保留
   （滚动位置、分页窗口、只看楼主状态都不受影响）。因此**不需要**任何「切回列表后按 pid 重新定位」
   「树内位置映射回列表」的补偿逻辑。
4. 树页不参与阅读进度记录/恢复；树页内回复/编辑成功后重新抓取全帖（页面内刷新），不改列表页数据。

### 1.2 入口

1. **设置页**：阅读设置新增「帖子阅读样式」项（列表 / 递进树），持久化为 `threadRenderMode`；
   它决定**打开帖子时挂载哪个页面**（`ActivityRouter` 按它分流 `Screen.thread` 条目的渲染组件）。
2. **列表页更多菜单**：新增「递进树阅读」→ `routerStore.navigateActivity(Screen.threadTree(tid, true, 当前中心楼层 pid))`
   push 独立树页；初始定位到列表当前中心楼层。
3. **树页更多菜单**：「列表阅读」→ 若是从列表页 push 进来的则 `back()`（回列表页）；
   若是默认样式直接打开（下方不是列表页）则 `routerStore.navigateActivity(Screen.thread(tid), true)` 替换当前页。

### 1.3 决策表（实现必须遵守）

| # | 决策 | 说明 |
| --- | --- | --- |
| D1 | 主楼（`lou === 0`）单独显示为第一行，**不与任何楼层形成回复关系** | 引用主楼的楼层（`[tid=…]Topic[/tid]` / `[pid=0,…]` 头）视为顶层根；主楼没有子节点 |
| D2 | 第一层 = 无有效引用目标的楼层（含引用主楼、引用目标被删/不在帖内、异常自引用/环） | 按楼层号升序 |
| D3 | 第二层 = 根的任意深度后代，**平铺**在根下，按楼层号升序 | 每条子节点显示它**直接回复的那一层**（可能不是根） |
| D4 | 折叠：某根的后代总数 > 3 时，默认显示前 2 条，其余折叠为一行「共 N 条回复，点击查看」；≤ 3 时全部显示 | 展开后显示全部，不再二次折叠；展开状态在当前树页会话内保留 |
| D5 | 树页不提供「只看楼主」 | 树页抓取全量、不应用任何作者过滤；列表页的只看楼主状态留在列表页，互不影响 |
| D6 | 离线存档来源不提供树入口 | 列表页菜单项对 `ThreadSource.SAVED` 提示「离线存档不支持递进树」 |
| D7 | 树页不记录/恢复阅读进度 | 阅读进度仍只由列表页负责；push 返回后列表页原位置不受影响 |
| D8 | 全帖抓取不应用黑名单/关键词过滤 | 保证引用图完整；黑名单遮蔽仍由 `PostItem`/`ThreadTreeChildItem` 渲染层判断 |
| D9 | 跳转 `→` 在树内定位 | 目标被折叠时展开其所属根再定位；目标为被删楼层/不存在 → Toast；目标为主楼 → 定位第一行 |
| D10 | 树页内回复/编辑成功后重新抓取全帖并重建树 | Toast 成功提示 + 页面回到加载态；不做增量合并（简单可靠） |
| D11 | 树页加载态 = 全屏加载视图 + 「正在加载全部楼层 n/N 页」 + 进度条 + 取消 | 加载期间不显示旧内容；取消后：从列表页进入的 `back()`，默认样式进入的显示错误态（可重试） |
| D12 | 树模型只在树页生命周期内持有 | 返回/销毁即释放；列表页完全不受影响 |

## 2. 数据与算法（纯逻辑，已单测）

### 2.1 引用关系提取

**数据源事实（调研已验证）**：客户端帖子数据走 `read.php?__output=17` APP HTML → `html-thread` 解析器
（`ThreadApi.buildThreadHtmlRequest`），产出的 `content` 与 JSON 主通道（`__output=8`）**逐字一致**（quote 头无差异）。
但 HTML 通道的**普通楼层没有 `reply_to` 结构化字段**（只有贴条行由解析器补；JSON 主通道才有）。
因此引用关系**必须从 `content` 文本提取**，不得依赖 `reply_to`（也不能为此改镜像解析器）。

NGA 楼层 `content` 中表达「回复了哪一层」的头有三种真实形态（样本见 `docs/research/THREAD_TREE_QUOTE_RESEARCH.md`）：

1. 引用块头：`[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]…[/quote]`
   → 目标 pid = A（A 是被引用楼层 pid；B 是**被引用楼层所属主题 tid**；C 是被引用楼层页码）。
2. 回复头：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b]<br/><br/>正文`
   → 目标 pid = A。
3. 主楼引用头：`[quote][tid=T]Topic[/tid] [b]Post by …[/b]` 或 `[quote][pid=0,T,1]Reply[/pid] …`
   → 目标 = 主楼（`isTopicRef = true`）。

真实变体（已覆盖）：

- 匿名作者引用：`[uid]#anony_<32hex>[/uid][color=gray](224楼)[/color]`（uid 属性无等号；作者段可能是「N楼」提示而非时间）。
- 跨帖引用：`[pid=A,43936925,11]` 的 B 段是**别的主题 tid** → `external = true`，建树时按根处理；
  `[tid=T]` 头且 `T ≠` 当前 tid 同样 `external = true`。
- 网页端（`from_client = 0 /`）生成的 C 段可能恒为 1，**C 段不得用于定位**（页码一律以抓取时 `pageByPid` 为准）。
- 主楼 `pid` 在 HTML 通道恒为 0；主楼靠 `lou === 0` 识别。

提取规则（`extractPrimaryQuoteRef(content, tid)`）：取最靠前匹配；`[uid=…]` 用 `[^\]]+`；作者段不强制以 `(date):` 结尾；
多引用取第一个；结果记录 `targetPid/targetPage/targetUid/targetAuthor/rawHeader/isTopicRef/external`。

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
2. 顺序抓 2..N：页间 **300ms**、单页 **15s 超时**、失败重试 1 次后整体失败；命中风控不重试直接失败。
3. 合并按 pid 去重、按 `lou` 升序，逐页记录 `pageByPid`（含主楼 `0 → 1`）。
4. 每页完成回调 `onProgress(done, total)`；支持 `cancel(owner)`；每次 `fetchAll` 递增代际。
5. 完成前 `await preWarmPosts(前 min(60,n) 个, false, HIGH)`。
6. 不写 `savedThreadProgress`，不碰 `ThreadPaginationManager`。

**并发与取消语义（页面级隔离的关键，review 后补强）**：

- 树页是独立栈页面，「快速切帖」「列表→树→返回→再进树」会出现**新旧两个页面实例重叠**的时序。
- `fetchAll(owner, tid)`：若上一个任务的 Promise 仍在途，先置取消并 `await` 它退场（旧任务最多再等当前页请求），
  再启动新任务——不会以「已有任务进行中」把新页面直接拒掉。
- `cancel(owner)`：只有当前任务正属于该 owner 才生效；旧页面销毁回调晚于新页面启动时不会误杀新任务。
- 调用方（`ThreadTreePanel`）为每个页面实例生成唯一 `treeOwner`（时间戳 + 随机数），所有 `cancel`/`fetchAll` 都带它。

## 3. 树页 UI（`pages/ThreadTreePanel.ets`）

### 3.1 页面结构

```
Stack
├─ Column：isLoading → LoadingState；hasError → ErrorState；ready → TreeList
├─ PanelNavBar（标题=帖子标题，更多菜单，滚动联动渐变模糊）
└─ BottomBar（右下角回复主题按钮，HdsMaterialHost；仅树就绪时显示）
```

### 3.2 根节点行

直接复用 `PostItem`（完整楼层卡片：头像、楼主标记、正文、附件、签名、投票栏、贴条、热回复）。
与列表模式的区别只在「行序」与「所在页面」；不做额外视觉标记，靠子节点缩进与折叠行表达树形态。

### 3.3 子节点行（`common/components/thread-tree/ThreadTreeChildItem.ets`）

自上而下：

```text
头像 24  用户名 [楼主] [备注]                         #当前楼层号
时间 [编辑时间]
回复 @被回复者 #被回复楼层号  →
正文（已剥离引用区）
附件 / 动作栏
```

- 用户信息区只有一行（头像 + 用户名 + 楼主标记 + 备注 + 行尾当前楼层号，`楼主/沙发/#N`）。
- **「回复 @被回复者」位于时间行与正文之间**（不是用户信息区）：它是阅读正文前的上下文提示；
  字号 **13vp，与用户名一致**（回复关系是阅读主线，不能弱化成小字备注）。
  `@名字` 可点 → 资料卡（匿名 uid 只提示）；`→` 可点 → 树内定位；`#N`/`楼主` 为被回复楼层号（11vp 辅助）。
- 时间行 → 回复关系行 → 正文（`BBCodeContentView`）→ 附件（`PostAttachments`）→ 操作栏（`PostVoteBar`）。
- 正文使用父组件传入的 `displayContent`（已剥离引用区）：树的两层关系已表达「回复了谁」，
  正文不再重复显示 `[quote]` 块 / `Reply to` 头；剥离后无正文时不渲染正文块。
- 不渲染签名/投票/贴条/热回复。黑名单作者 → 保留头部、正文区替换为「该用户已被屏蔽」。
- 视觉：左侧 `padding 40`、左侧 2vp 竖线、**无卡片底色**（透明；层级只靠缩进与竖线表达）、
  高亮 `selectionTint`（2 秒自动清除）。

### 3.3.1 引用区剥离（`stripQuoteArea`）

树模式所有节点（含根行）正文统一经 `stripQuoteArea(content)` 处理：

1. 剥离正文开头（允许前导空白）的 `[b]Reply to …[/b]` 回复头；
2. 剥离开头的 `[quote]…[/quote]` 引用块（标签深度平衡扫描，支持嵌套，不用非贪婪正则以免截断）；
3. 两者可连续出现，循环剥离（上限 8 轮防御异常数据）；
4. 清理剥离后开头的空白与 `<br/>`；
5. **只处理正文开头**：正文中部出现的 `[quote]` 字样视为用户内容，不删除（文字不被吞原则）。

剥离结果缓存在 `ThreadTreeRoot/ThreadTreeChild.displayContent`，由 `flattenThreadTree` 复制到行上；
`PostItem` / `ThreadTreeChildItem` 通过 `displayContent` + `showContent` 渲染（默认不传时行为与自然列表完全一致）。

### 3.4 折叠行（`ThreadTreeMoreItem.ets`）

文案 `共 N 条回复，点击查看`（13vp `textTertiary`）+ 下箭头，高 40、同缩进、整行点击展开全部子节点。

### 3.5 加载态 / 错误态

- 加载态：`LoadingStateView` + 「正在加载全部楼层 n/N 页」+ 线性进度条 + 「取消」；
  总页数未知（第 1 页尚未返回）时显示「正在加载帖子…」，**取消按钮同样可用**（首屏请求也可能卡满超时）。
- 错误态：`ErrorStateView(msg, onRetry)`（重试重新抓取）。

### 3.6 菜单

- 刷新递进树（重抓全帖并重建）
- 列表阅读（从列表页进入 → `back()`；默认样式进入 → 替换当前页为列表页）
- 从网页打开、分享帖子

## 4. 页面接入（路由层）

### 4.1 路由

`store/RouterStore.ets`：

- `ScreenType` 增加 `'threadTree'`；
- `Screen.threadTree(tid, fromList, pid)` 工厂 + `threadTreeFromList` 字段；
- `getTitle()` 增加 `'递进树'`。
- `navigateActivity` 现有行为：`'thread'` 类型在栈顶也是 thread 时替换，其余 push；`'threadTree'` 走普通 push（独立栈条目）。

### 4.2 ActivityRouter

`pages/ActivityRouter.ets`：

- `'thread'` 条目：`appStore.settings.threadRenderMode === ThreadRenderMode.TREE` → 挂载 `ThreadTreePanel(fromListEntry=false)`，
  否则挂载 `ThreadPanel`（现有行为完全不变）；
- `'threadTree'` 条目：挂载 `ThreadTreePanel(fromListEntry=entry.screen.threadTreeFromList)`；
- TTS 停止判定把 `threadTree` 也视为帖子类页面。

### 4.3 列表页入口（`ThreadPanel.ets` 唯一改动）

`moreMenuItems()` 在**在线来源**分支（收藏/保存/跟踪之后）增加一项「递进树阅读」→
push `Screen.threadTree(this.threadTid, true, 当前中心楼层 pid)`；离线存档来源不显示该项。
**其余逻辑一行不改**（不新增状态、不加分支、不改分页/定位/进度）。

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

`entry/src/test/ThreadTreeBuilderUnit.test.ets`（28 例，在 `List.test.ets` 注册）覆盖：

1. 引用头提取：quote 头 / Reply to 头 / 主楼 Topic 头 / `[pid=0]` 主楼哨兵 / 匿名 uid / 跨帖 / 多引用取第一 / 无引用 / 头部前空白；
2. 建树：引用主楼 → 根；引用不存在 pid → 根；自引用 / 环 → 提升为根不丢楼；深层引用平铺；主楼无子节点；
3. 折叠：3 条全显、4 条显 2 + MORE(hidden=2)、展开后全显、未知根不可展开；
4. 排序与查找：根/子行按楼号升序、`findRootPidByPid` 语义、`findRowIndexByPid`。

门禁：`hvigorw assembleHap` 编译通过 + `hvigorw test` 通过 + `node scripts/check-eol.mjs` 通过；
镜像 `sync-to-ets.mjs --dry` 0 修改。

## 7. 文件清单与写入归属

| 文件 | 归属 |
| --- | --- |
| `model/ThreadTree.ets` | Lead（先行冻结） |
| `common/utils/ThreadTreeBuilder.ets` + `entry/src/test/ThreadTreeBuilderUnit.test.ets` + `List.test.ets` 注册 | 数据层成员 |
| `service/ThreadTreeFetchService.ets` | 数据层成员 |
| `common/datasource/ThreadTreeDataSource.ets` | 数据层成员 |
| `common/components/thread-tree/ThreadTreeChildItem.ets` / `ThreadTreeMoreItem.ets` | UI 层成员 |
| `pages/ThreadTreePanel.ets`（独立树阅读页面） | Lead |
| `pages/ActivityRouter.ets` / `store/RouterStore.ets`（路由类型与分流） | Lead |
| `pages/ThreadPanel.ets`（仅更多菜单一项） | Lead |
| 设置链路 6 文件 + 图标 | 设置成员 |
| `docs/THREAD_TREE_DESIGN.md`、`docs/research/*` | Lead/调研成员 |

## 8. 风险与已知限制

1. 引用头格式覆盖率以真实样本统计为准；解析器对未知格式静默降级（不崩溃、不误判）。
2. 长帖抓取耗时与风控：100 页约 1–2 分钟，必须可取消；失败即停。
3. 树页回复/编辑成功后整树重抓（D10）：长帖会再次等待，这是「简单隔离」的代价；用户也可用菜单手动刷新。
4. 树页与列表页不共享位置：从树页返回列表页回到原位置（push 语义）；默认树样式打开时「列表阅读」是替换页，列表从第 1 页开始。
5. 主楼 pid 在 HTML 通道可能为 0：引用主楼一律按 `isTopicRef` 判定，不依赖 pid 匹配。
6. 树页不参与阅读进度记录（D7）。

## 9. 实现落地差异（交付时校准）

1. 匿名引用真实形态 `[uid]#anony_<32hex>[/uid][color=gray](224楼)[/color]`（uid 无等号），另有裸 `(31楼)` 变体；已覆盖。
2. 引用载体两种共 741 条（quote 块 547 + Reply to 头 194），两者同优先级取最靠前。
3. 跨帖引用 14 条 → `external=true` 归根；主楼引用两种形态共 11 条 → `isTopicRef=true`。
4. C 段不可靠（Web 端 7.4% 错写 1），不用于定位；切回列表/定位一律用 `pageByPid`。
5. `buildThreadTree` 不填 `pageByPid`，由树页把 `ThreadTreeFetchResult.pageByPid` 合入。
6. `__R` 中楼中楼评论行（`comment_to_id` + 无 `content`）由 `parseThreadData` 过滤，`posts` 不含。
7. 门禁结果：`assembleHap` BUILD SUCCESSFUL；Hypium 全量用例通过；EOL 通过；镜像 `--dry` 0 修改。
8. UI 运行时行为（滚动、展开、高亮、加载进度）需在设备上实际体验确认；本工程不做 UI 自动化。
9. **交付前 review 修复**：
   - 抓取服务并发竞态：新增 `owner` 标识 + 「新任务先等待旧任务退场」，快速切帖 / 列表→树→返回→再进树
     不再误报「已有任务进行中」，旧页面销毁也不会误取消新页面的任务（见 §2.5）；
   - `PostItem.displayContent/showContent` 改为 `@Prop`：树页刷新后行键值可能不变（pid + rev 相同），
     只有 @Prop 会随新参数更新，普通字段会保留旧值导致正文不刷新；
   - 树 List 启用 `maintainVisibleContentPosition(true)`：展开折叠行（整体 replaceAll）时视口不跳动；
   - 加载态取消按钮在总页数未知（第 1 页未返回）时也可用；
   - 「递进树阅读」菜单项只在在线来源显示（离线存档不出现该入口）。
10. 调研临时产物（`docs/research/samples/` 抓取样本与分析脚本、B 站现场截图，约 4.6MB）已在交付前清理；
    三份调研报告（引用格式统计、B 站交互规则、工程接入地图）保留，作为解析规则与参数的依据。
