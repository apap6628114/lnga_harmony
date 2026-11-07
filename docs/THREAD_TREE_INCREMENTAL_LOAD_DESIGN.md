# 递进树增量加载与加载期交互 — 设计方案

> 状态：**已实施（P0 + P1）**（2026-11-07）
> 关联契约：`docs/THREAD_TREE_DESIGN.md`（现有 D1–D14 与 §3.5 加载态）、`docs/THREAD_DESIGN.md` §4.5（前插锚点事务）
> 本文定位：在现有契约之上**替换「一次性抓完再建树」的加载模型**，并补齐由此派生、原方案未定义的体验细节。
> 修订：v2（2026-11-07）——按评审结论收敛：停止即终止（不提供继续）、恢复进度改为「等到位再提示、不自动跳」、刷新保持现状（§3.11 说明「后台刷新」含义）、进度提示采用标题栏下缘胶囊。
> 修订：v3（2026-11-07）——定位统一为一套「待定位目标」模型（恢复/路由/用户点击同机制），补全等待期感知设计（目标刻度、未就绪不给动作、卡页解释），进度记录门禁改为「目标存在 + 用户移动」。
> 修订：v4（2026-11-07）——实施完成，落地差异见 §10。

---

## 0. 一句话

把「进入 → 全屏等待 → 一次性建树」改成「进入 → **第 1 页到达即可阅读** → 后续页按顺序增量长出来 → **顶部进度胶囊可随时停止**」，并用「顺序水位提交 + LazyForEach 增量通知 + 锚点事务」三层机制，保证任意时刻视口与焦点都不跳。

同一句话的第二半：**在树里，"跳转"不是动作，而是"等"**——无论恢复上次进度还是从引用跳到某层，目标都必须先被加载出来；页面要把「在等什么、还差多少、现在能不能去」持续讲清楚，就绪后由用户决定去不去。

---

## 0.1 两个页面必须分清（本文只动递进树）

| 维度 | `pages/ThreadPanel.ets`（**普通列表**） | `pages/ThreadTreePanel.ets`（**递进树**，本文对象） |
| --- | --- | --- |
| 阅读形态 | 自然楼层顺序，一页 20 楼 | 两层扁平树（根行 + 子行 + 折叠行） |
| 数据来源 | 连续分页窗口 `ThreadPaginationManager`（按页请求，双向追加/前插） | 全帖抓取 `ThreadTreeFetchService` + `buildThreadTree` |
| 列表数据源 | `PostInfoDataSource`（`PostInfo[]`） | `ThreadTreeDataSource`（`ThreadTreeRow[]`） |
| 阅读进度域 | `reading_progress`（页码 + 楼层锚点） | `tree_reading_progress`（pid / rootPid / page） |
| 加载态 | 首屏 `LoadingState`（400ms 延迟淡入）+ 底部「加载更多」 | 全屏 `LoadingState`（三出口）→ **本文要改成增量** |
| 本文角色 | **只作机制参考**：前插锚点公式、400ms 延迟淡入节奏 | **本文全部改动的落点** |

**边界约定**（与 `THREAD_TREE_DESIGN.md` §1.1 的页面隔离原则一致）：

- 两页**不共享任何可变状态**。本文的改动不得让树页读写 `ThreadPaginationManager` / `PostInfoDataSource` / `reading_progress`，也不得让列表页感知树页的模型与数据源。
- 文中出现 `ThreadPanel.ets` 的地方只有两类：①现状对照；②借用已被验证的**公式/节奏**——**不复制代码、不调用其方法、不共享字段**。
- 本次改动**不修改** `ThreadPanel.ets`（若将来做 §3.11 的刷新优化，也与它无关）。

---

## 1. 现状调查（代码级，2026-11）

### 1.1 现在的时序（以下全部指**递进树页** `ThreadTreePanel.ets`）

```
aboutToAppear
  └─ loadTree(false)                                  ThreadTreePanel.ets:440
       ├─ isLoading = true / treeReady = false        （页面进入全屏加载态）
       ├─ threadTreeFetchService.fetchAll(...)        FetchService.ets:396
       │    ├─ 第 1 页（串行，15s 超时，失败重试 1 次）
       │    ├─ 第 2..N 页：4 路并发 + 250ms 派发间隔 + 180 次/分钟窗口
       │    └─ onProgress(done, total) 每页一次 → 仅更新两个 @State
       └─ .then(result) → commitFetchResult(...)      ThreadTreePanel.ets:565
            ├─ applyThreadInfo / 黑名单 / totalPages / pageByPid
            ├─ rebuildTree() → buildThreadTree() 全量建树 + flattenThreadTree
            ├─ treeDataSource.replaceAll(model.rows) → onDataReloaded（整体重载）
            ├─ treeReady = true / isLoading = false
            ├─ 写浏览历史 / 推进跟踪已读 / 缺页 Toast / partial 状态
            ├─ resolveNavigationPid + scheduleNavigation（一次定位）
            └─ tryRestoreTreeProgress（进度恢复）
```

关键事实：

| # | 事实 | 证据 |
| --- | --- | --- |
| F1 | 全帖抓完前**不渲染任何楼层**：`build()` 里 `isLoading ? LoadingState() : hasError ? ErrorState() : treeReady ? TreeList()` | `ThreadTreePanel.ets:2239-2249` |
| F2 | 长帖抓取耗时：29 页约 8~10 秒、100 页约 33~40 秒 | `THREAD_TREE_DESIGN.md` §2.5 |
| F3 | 进度只有 `n/N 页` 文本 + 线性进度条，出口是「查看已加载 / 取消 / 以常规列表打开」；**「取消」的语义是退出页面**，不是停止加载 | `ThreadTreePanel.ets:1348-1367`、`:2284-2349` |
| F4 | 抓取服务只回调 `(done, total)`，**不回调已抓到的楼层**；页面必须等 `fetchAll` 的最终 Promise 才能拿到数据 | `FetchService.ets:396-455` |
| F5 | 结果提交是**一次性**的：写历史、推跟踪、弹缺页 Toast、写 partial、定位都在同一方法里，没有幂等设计 | `ThreadTreePanel.ets:565-604` |
| F6 | 数据源刷新走 `replaceAll` → `notifyReload` → `onDataReloaded`（整体重载） | `BaseLazyDataSource.ets:58-64` |
| F7 | `maintainVisibleContentPosition(true)` 对 `onDataReloaded` **不生效** | 官方 List 文档：「使用 LazyForEach **重新加载数据**时，即使属性设置为 true，可见区内容位置也会跟随变化」；只有「LazyForEach **在显示区域上方插入/删除数据**」才生效 |
| F8 | 现有注释「折叠行展开（整体 replaceAll）时保持可见内容位置」建立在 F7 的错误假设上 | `ThreadTreePanel.ets:2541-2542` |
| F9 | `buildThreadTree` 每次 run 都 `new` 全部 `ThreadTreeRoot`（`expanded=false`、`rev=0`），**展开状态不保留** | `ThreadTreeBuilder.ets:1026-1056`、`:1116-1165` |
| F10 | 刷新（菜单/回复后）把 `treeReady` 置 false → List 卸载 → 已读内容整屏消失，完成后按 `refreshAnchorPid` 重定位（有一次可见跳变） | `ThreadTreePanel.ets:440-470`、`:460` |
| F11 | `cancel` 只置标记，worker 在 `await fetchPage` 返回后才退出（最坏等单页超时 15s），期间页面显示「正在中断加载…」 | `FetchService.ets:357-365`、`:684-730` |
| F12 | 命中 90 秒缓存时仍先 `isLoading=true` 再提交（异步 Promise），存在一帧 loading 闪烁 | `FetchService.ets:425-434` |

### 1.2 现有状态与数据

- 页面独占 `allPosts` / `treeModel` / `treeDataSource` / `pageByPid` / `totalPages`（`ThreadTreePanel.ets:207-216`）。
- `buildThreadTree` 是**纯函数 + 全量**：`posts → 排序 → 扫描引用区 → 建两层树 → flatten`，无增量入口。
- 引用关系由 `scanLeadingQuoteArea` 从正文头部识别；**快速路径**（开头不是 `[quote`/`[b]` 直接返回）让绝大多数楼层近乎零成本（`ThreadTreeBuilder.ets:790-794`）。
- 父边只指向 **lou 更小**的楼层：`resolveParentPid` 在 `target.lou >= post.lou` 时返回 0（根）（`ThreadTreeBuilder.ets:902-904`）。

### 1.3 现有 UI

- `Stack { Column(内容) ; PanelNavBar(标题栏) ; BottomBar(回复 FAB) }`（`ThreadTreePanel.ets:2239-2266`）。
- 标题栏固定高 `statusBarHeight + NAV_BAR_H`（`NAV_BAR_H = 44`），无副标题槽位（`PanelNavBar.ets:425`）。
- List 使用 `LazyForEach` + `cachedCount(6)` + `contentStartOffset = statusBarHeight + NAV_BAR_H` + `maintainVisibleContentPosition(true)`（`:2537-2542`）。
- 尾部 `LoadEndFooter` 是 LazyForEach 之后的一个固定 `ListItem`，文案由 `loadEndText()` 决定（`:2590-2624`）。

### 1.4 现有可借鉴资产（仅机制/节奏，不共享代码）

| 资产 | 归属 | 位置 | 借鉴点 |
| --- | --- | --- | --- |
| **前插锚点事务**（记录锚点 pid + `getItemRect().y`，插入后 `scrollToIndex(index, START, extraOffset = H - anchorOffset)` 恢复） | 普通列表（`ThreadPanel`） | `ThreadPanel.ets:1001-1107`、`THREAD_DESIGN.md` §4.5 | 增量插入到视口上方时的显式补偿**公式**；树页自己实现一套字段与方法 |
| 底部胶囊进度指示器（全屏透明定位层 + `alignContent(Bottom)` + `HitTestMode.Transparent`，「取消」用 `Block`） | 全局组件 | `SavedThreadProgressIndicator.ets:57-109` | 胶囊的视觉与命中范式 |
| 加载态 400ms 延迟淡入（避免快速加载闪烁） | 普通列表（`ThreadPanel`） | `ThreadPanel.ets:1362-1370` | `ENTERING` 阶段防闪的**节奏** |
| `BaseLazyDataSource.notifyAdd` | 公共基类 | `BaseLazyDataSource.ets:71-77` | 增量通知基座（树页改走 `onDatasetChange`，见 §4.3） |

> 上表只有「`BaseLazyDataSource`」是真正被复用的代码；其余三项都是**公式/参数/视觉范式**，实现落在树页自己的文件里。

### 1.5 现状为什么满足不了新诉求

1. **等待期没有内容**：F1/F2 —— 用户要等 8~40 秒才能看到第一行，且这段时间无法判断帖值不值得读。
2. **进度不可中断**：F3/F11 —— 「取消」是退出，「查看已加载」是一次性的全屏决策；没有「边读边等、随时停」的形态。
3. **没有增量通道**：F4/F5/F6 —— 服务不吐页数据、提交不幂等、刷新只能整体重载。
4. **视口保护缺失**：F7/F8 —— 现有「保持位置」的注释是错的；真正需要保护时（插入到视口上方）框架不会兜底。
5. **状态会被增量破坏**：F9 —— 每次重建都丢展开状态；多次提交若直接复用 `commitFetchResult`，会重复写历史、重复弹 Toast、重复定位。

---

## 2. 三个不变量（方案成立的前提）

增量方案能否既「随时可读」又「最终与全量一致、视口不跳」，取决于三个可证明的性质。

### I1：顺序水位提交 ⇒ 父边单调 ⇒ 不需要「收敛重建」

- 父边只指向 **lou 更小**的楼层（`resolveParentPid`）。
- 楼层在服务端按 lou 升序分页；页内也是升序。
- 因此只要**按页号连续**提交（水位 = 已覆盖页的连续前缀），任一楼层到达时它引用的父楼层**必然已在已提交数据里**。
- 推论：不存在「先被当作根、后来发现父楼层」的改挂；**任意时刻的树 = 用已提交前缀全量构建的树**。
- 因此不需要「加载完成后做一次收敛重建」，也就没有结束瞬间的重排。

> 前提必须严格：**按页号顺序**提交，不是按到达顺序。4 路并发会乱序完成，后续页要先缓冲。
> 代价：最慢一页会卡住水位（典型 1~2 页差，最坏等单页超时）。缓解见 §3.4。

### I2：插入位置只有两类，永远不会「移动行」

在 I1 下，新楼层只会产生两种行变化：

1. **新根**：lou 最大 ⇒ 根序列按 lou 升序 ⇒ 新根只能追加到**根序列末尾**（主楼根恒在首位）⇒ 行位置在**列表末尾**。
2. **新子行**：挂到某个已提交的根下，插入点是**该根子行区的末尾**（可能在该根的第 2/3 条子行之后，或 MORE 行之前）。

不存在「某行从 A 根下移到 B 根下」，也不存在「行在列表里整体搬家」。

### I3：折叠天然抑制插入规模

未展开且子数 > 3 的根只显示前 2 条 + MORE 行（`flattenThreadTree`）。因此每页 20 楼中，只有落到「某个根当前可见子行区」的楼才会真正新增可见行——多数楼层只改变 MORE 行的计数（`totalCount`）。

**唯一的「非纯追加」形态**：某根子数从 3 → 4 时，第 3 条子行被 MORE 行取代（行数不变、该位置内容变化）。这是一次 `CHANGE`（或 DELETE+ADD 同位置），**不改变该位置之前的行数**，因此不影响视口。

---

## 3. 目标体验（原方案未定义、必须补的细节）

### 3.1 状态机

```
ENTERING ──第1页到达──▶ STREAMING ──全部页覆盖──▶ COMPLETE
   │                        │
   │                        ├──用户停止──▶ STOPPED（冻结，可重试/刷新）
   │                        └──某页失败──▶ FAILED（保留内容 + 错误条）
   └──第1页失败──▶ FAILED（全屏错误态，无内容可留）
```

| 状态 | 内容 | 进度提示 | 可做的操作 |
| --- | --- | --- | --- |
| `ENTERING` | 空（居中 LoadingProgress + 「正在加载第 1 页…」；300ms 延迟淡入） | 无胶囊 | 取消（退出）、以常规列表打开 |
| `STREAMING` | **第 1 页起的树**，持续增长 | **顶部胶囊**（n/N + 停止；目标未到时可带等待文案） | 停止、读、回复、切列表、切只看楼主；定位由 **Toast** 提示（不是胶囊） |
| `COMPLETE` | 全帖树 | **胶囊淡出**（加载结束即消失） | 全部 |
| `STOPPED` | 已提交部分的树 | 胶囊淡出，尾部标注 | 刷新（整帖重抓）、切列表 |
| `FAILED`（有内容） | 已提交部分的树 | **错误条**（常驻，含重试） | 重试、刷新、切列表 |
| `FAILED`（无内容） | 空 | 全屏错误态 | 重试、取消 |

> 页面状态（`STREAMING` / `COMPLETE` …）与胶囊状态（`LOADING` / `LOADING_WAIT` / `STOPPING` / `ERROR`）是**正交**的两组：胶囊只表示「还在加载 / 正在停止 / 失败重试」，加载一结束就消失；定位目标是否就绪由 Toast 提示，与胶囊无关。

> 与现有 D14 的冲突：D14 规定「自动失败的部分结果**不自动展示**」。增量模型下内容已经在屏幕上，**不可能**再退回全屏错误态；该条须修订为「**内容已在视口时保留内容 + 显式错误条**；无内容时才用全屏错误态」。

### 3.2 首屏（进入 → 第一屏内容）

1. **缓存命中（90 秒内）**：同步 `peekCache(uid, tid)` → 直接 `COMPLETE` 建树渲染，**不出现任何加载 UI**（0 帧 loading）。这是当前 F12 的直接修复。
2. **未命中**：`ENTERING` 立即渲染容器，400ms 后才淡入 loading（沿用普通列表页验证过的 400ms 节奏，但计时器与状态在树页自己实现）；第 1 页若在 400ms 内返回，用户看到的是**直接出现的内容**，没有 loading 闪屏。
3. **第 1 页内容**：主楼 + 前 20 楼（约 20 行）——足够开始阅读，也足够判断要不要继续等。
4. `ENTERING → STREAMING` 用 200ms 交叉淡入，不做高度动画（避免整页 reflow）。
5. **进入即登记定位目标**（§3.6.1）：路由 pid 优先，其次本地进度；两者都没有则不登记。登记发生在首屏提交之前，后续每次水位推进都重算「目标是否就绪」。

### 3.3 进度提示（形态 / 位置 / 文案 / 停止 / 隐藏）

> **已拍板**：胶囊**只承载加载进度与「停止」**，不承载定位动作；「前往查看」（以及"查看全部"）由 Toast 承担。
> 因此胶囊没有「已就绪 / 被过滤 / 未加载」这些目标态，**加载一结束（完成/停止）就消失**。

**位置**：标题栏下缘，`y = statusBarHeight + NAV_BAR_H + 8`，左对齐 `x = 12`；**overlay 绝对定位，不占布局**（`contentStartOffset` 不变，出现/消失都不会推挤列表）。

**形态**：`Row` 高 32、圆角 16、`AppColors.toastBg` 半透明底、白字。胶囊是**单一载体**，按状态换内容，不堆第二条：

| 状态 | 左侧 | 文案 | 右侧 | 交互 |
| --- | --- | --- | --- | --- |
| `LOADING` | ⟳ | 已加载 12/29 页 | 进度条 · 停止 | 停止 |
| `LOADING_WAIT` | ⟳ | 载入到上次阅读位置 12/40 页 | 进度条（带目标刻度）· 停止 · × | 停止 / 取消等待 |
| `STOPPING` | ⟳ | 正在停止… | — | — |
| `ERROR` | ! | 第 7 页加载失败 | 重试 | 重试 |

- 细进度条 60×4：`value = committedPages`、`total = totalPages`，值变化用 `animateTo(200ms)` 平滑。
- **有定位目标且尚未到达时，进度条上按 `target.page / totalPages` 打一枚 2vp 刻度**——它直观表达「还差多少才到你要的位置」，是等待期最主要的感知来源（见 §3.6.4）。目标到达后刻度消失、文案回到纯进度。
- `ERROR` 用 `AppColors.destructive` 前景与 `!` 前缀；其余用中性白。
- 每个动作 ≥ 40×40 触摸区；「停止」「重试」用 `hitTestBehavior(Block)` 防穿透，胶囊本体 `Transparent`。
- 无障碍：`accessibilityText` 随状态生成，如「正在加载，已加载 12/29 页，双击停止」。

**文案口径**：**只报「已提交页」**，不报「已抓取页」。理由：用户看到的内容就是已提交前缀，两个数字分叉会让人怀疑内容缺失。

**何时不显示**（防闪烁）：

- `totalPages <= 2` 且**没有待处理目标**：整帖 1~2 页，抓取在一秒内结束，胶囊只会闪一下 → 不显示。
- 第 1 页返回时就已全部覆盖 → 直接 `COMPLETE`（胶囊从不出现）。
- 其余：`STREAMING` 进入后 **300ms** 再淡入（若 300ms 内已完成则从不出现）。
- **`COMPLETE` / `STOPPED` / `ENTERING` 一律隐藏**：加载结束即消失。

**停止**：

- 点击后**立即**冻结 UI：水位提交停止、胶囊文案变「正在停止…」≤300ms，然后淡出；**不等待网络**。
- 服务层任务转入收尾（在途请求自然返回后丢弃），不占用后续 UI 状态。
- 停止后的内容 = 点击瞬间已提交的页（确定、可预期）。

**完成**：胶囊 200ms 淡出，尾部变「已加载全部回复」；目标是否就绪由 Toast 决定（§3.6.5）。

**失败**：胶囊替换为错误条（`destructive` 前景 + 文案「加载失败：第 X 页…」+「重试」），**常驻**直到用户操作；不自动消失（失败必须被看见）。

**滚动时**：胶囊固定不动，不随列表滚走；不因用户滚动而隐藏（用户随时可能想看还剩多少）。

### 3.4 增量节奏与「已加载」口径

- **提交单位 = 页**，水位推进可一次跨多页（某页慢、后续页已缓冲）。
- **合并提交**：同一宏任务内推进多页 → 合并为一次重建 + 一次数据源通知（`setTimeout(0)` 让出当前帧）。
- **每页到达即预热该页 BBCode**（`preWarmBatch`，不 await）——当前只在全部完成后预热前 60 楼（`FetchService.ets:843-857`），增量下必须改为「提交哪页预热哪页」，否则新增行的正文解析会同步落在渲染帧里。
- **水位等待的用户表达**：当 `已抓取页数 > 已提交页数` 且差值 ≥ 2 时，胶囊文案追加「（正在等待第 k 页）」；不额外加 UI。
- **已加载 n/N 的口径**：`n = committedPages`（已提交），`N = totalPages`。尾部、胶囊、部分数据提示共用这一个口径。

### 3.5 视口与焦点（三层防线）

这是本方案的技术核心。目标：**加载过程中，用户正在看的行在屏幕上的位置不变；用户没有在看的区域可以自由长出来。**

**第一层：让框架知道「这是插入」**

- 数据源通知从 `onDataReloaded` 改为 **`onDatasetChange` 的 ADD/CHANGE 操作**（官方明确：只有 LazyForEach 增量插入/删除时 `maintainVisibleContentPosition` 才生效）。
- 开启中的 `.maintainVisibleContentPosition(true)` 由此才真正起作用：在显示区域**上方**插入时，框架自动保持可见内容位置。

**第二层：显式锚点事务（不把正确性押在框架上）**

本工程已有先例：`THREAD_DESIGN.md` §4.5 明确「不能只依赖框架的自动保持」，**普通列表页**（`ThreadPanel`）因此实现了 pid 锚点事务。**递进树页**（`ThreadTreePanel`）借用同一公式、但独立实现（字段与方法都在树页内，不引用列表页的 `mgr` / `postsDataSource`）：

```
提交前：anchorPid = rows[lastScrollStart].post.pid
        anchorOffset = scroller.getItemRect(lastScrollStart).y
提交后（下一帧）：newIndex = newRows.findIndexByPid(anchorPid)
        if (newIndex !== oldIndex) {
          H = statusBarHeight + NAV_BAR_H
          restoreOffset = H - anchorOffset
          scrollToIndex(newIndex, ScrollAlign.START, extraOffset = restoreOffset)
        }
```

判据：`newIndex > oldIndex`（前面插入了行）才补偿；`newIndex === oldIndex` 不动（插入在视口内/下方，内容自然向下延伸，不需要滚）。

**第三层：补偿期间抑制副作用**

- 补偿触发的 `onScrollIndex` / `onDidScroll` 不得当作「用户滚动」：置 `compensating = true`，下一帧结束；期间不记录阅读进度、不更新「用户已滚动」标记、可选地跳过 `dismissAnalyzerSessions()`。
- `maintainVisibleContentPosition` 本身也会触发 `onDidScroll`/`onScrollIndex`（官方文档明确），同一标记一并覆盖。
- 进度记录（`scheduleProgressRecord`）在补偿结束后恢复正常——补偿后 `lastScrollStart/Center` 已由新布局更新，记录的是正确位置。

**不做的事**：不使用 `replaceAll`（RELOAD）参与增量；RELOAD 仅用于「折叠展开 / 只看楼主切换 / 刷新替换」这类用户显式动作，且这些动作的插入点都在用户点击位置的下方，视口上方不受影响。

### 3.6 定位（恢复进度 / 跳跃定位）：等数据 → 给就绪信号 → 由用户决定

> **设计前提**：递进树的语义是「从头到尾的全帖分析」——引用关系要先把那一段数据抓到手才成立。所以「跳到第 N 层」在树里不是瞬时动作，而是**等目标长出来**。
> **已拍板**：
> - 恢复进度与跳跃定位**共用同一套机制**，不设双标准；
> - **都不自动跳**，数据到了给「可前往」信号，由用户点；
> - 体验重点不在「跳」，而在**等待期的感知**，以及**未就绪时绝不给出无效的跳转入口**。

#### 3.6.1 一个「待定位目标」模型，三种来源

```ts
class LocateTarget {
  pid: number          // 目标楼层 pid
  page: number         // 目标页码（可 -1；只用于文案与进度刻度）
  rootPid: number      // 已知的所属根（恢复进度时有；其余为 -1，就绪后再查）
  source: string       // 'resume' | 'route' | 'user'
  label: string        // 「上次阅读位置」/「第 812 楼」
}
```

| 来源 | 何时登记 | 覆盖规则 | 说明 |
| --- | --- | --- | --- |
| `resume` | 进入时读到 `tree_reading_progress` | **不能覆盖任何已有目标** | 路由带 pid 时不登记 |
| `route` | 路由 `threadPid` 非空（引用 `→` / 同帖链接 / 深链） | 覆盖 resume | 进入时的明确意图 |
| `user` | 加载中点了未加载楼层的 `→` / 同帖链接 | **总是覆盖**（含 route） | 用户当下意图优先级最高；同一时刻只保留一个 |

**同一时刻只有一个目标**（`pendingTarget`）。三种来源共享同一套「等待 → 就绪 → 用户决定」流程，只有文案不同。
`canOverrideTarget` 的规则即上表：`resume` 只在无目标时生效，`route`/`user` 都可覆盖当前目标。

#### 3.6.2 目标生命周期

```
(none) ──登记──▶ WAITING ──目标 pid 进入模型──▶ READY ──Toast「前往查看」──▶ ACTIVATED（跳转 + 清除）
                    │                              └─用户忽略 Toast ──▶ 保留到加载结束（不阻塞进度）
                    ├─目标页已提交但 pid 不在──▶ MISSING（静默清除）
                    └─加载结束（停止/失败）──▶ 静默清除
```

判定规则：

1. **就绪判定必须同时看「全量」与「当前模型」**，不能只看 `treeModel.postByPid`：
   - `treeModel` 的 `postByPid` 只含**过滤后**参与建树的楼层（只看楼主时非楼主楼层不在里面）；
   - 只看 pid 会把「被只看楼主过滤掉的目标」误判成「楼层不存在」；
   - 正确顺序见 §3.6.3 的判定表。
2. **就绪按 pid 判，不按页码**：页码只驱动文案与刻度（`page` 可能为 -1，见 §3.6.3）。
3. **目标若是被折叠的子行**：模型里有它就算 READY；点「前往」时先展开所属根再居中（`ensureRowVisible`）。
4. **`rootPid` 可能失效**（帖子结构变化）：先按 `rootPid` 展开，失败再按当前模型 `findRootPidByPid` 重查（现有 `applyTreeResume` 已有这条兜底，保留）。
5. **`pid = 0` 是合法值**：HTML 通道的主楼 pid 为 0，判定与定位都要按「主楼 / 第一行」处理，不能把 0 当"无目标"（现有 `treeJumpToPid` 里 `pid <= 0` 直接滚顶部的写法要改为 `pid < 0`）。
6. **MISSING 只能在「目标页已提交」之后判定**：加载中找不到只能说「还没加载」，不能说「不存在」（沿用 `missingFloorHint` 的三态口径）。
7. **加载结束时目标仍未到**：
   - `COMPLETE` + 目标页已提交 → 楼层确实不在（删楼/屏蔽）→ **静默清除**；
   - `COMPLETE` + 目标页未提交（该页被跳过/失败）→ **静默清除**（胶囊已消失，不再给刷新入口）；
   - `STOPPED` / `FAILED` → **静默清除**（用户已决定不等）。
8. **用户点了未加载楼层的 `→`**：分两种时机——
   - 仍在 `STREAMING`：立即登记 `user` 目标（替换当前），胶囊切 `LOADING_WAIT`，并 Toast 说明「第 40 楼在第 12 页之外，已加载到 9 页」——**让"点不动"变成一个明确的等待态**，而不是无响应；
   - 已 `STOPPED` / `FAILED` / `COMPLETE`：不会再加载了，直接按 `missingFloorHint` 给结论（已停止→「不在已加载的 n/N 页内」；完成→「不存在/已删除」），**不要登记一个永远等不到的目标**。

#### 3.6.3 判定表（就绪 / 过滤 / 缺失）

每次提交后按此表判定 `pendingTarget`，**顺序不能换**：

| # | 条件 | 结果 | 提示 |
| --- | --- | --- | --- |
| 1 | `allPosts` 中不存在该 pid，且目标页**未**提交 | `WAITING` | 胶囊 `LOADING_WAIT`（只有进度文案与刻度） |
| 2 | `allPosts` 中不存在该 pid，且目标页**已**提交 | `MISSING` | **静默清除**（不弹"楼层已删除"） |
| 3 | `allPosts` 中有、当前模型 `postByPid` 中**没有** | `FILTERED`（被只看楼主过滤） | Toast「上次阅读位置不在只看楼主视图内 · 查看全部」 |
| 4 | 当前模型 `postByPid` 中有 | `READY` | Toast「检测到上次阅读进度 · 前往查看」 |

- 第 1/2 条的「目标页」在 `target.page <= 0`（未知，典型是路由 pid）时**不可判定**：只能等 `COMPLETE` 时按「全帖已到仍不在 `allPosts`」判 `MISSING`，在此之前一直 `WAITING`。
- `target.page` 未知时进度条**不画刻度**，文案退化为「载入到第 812 楼（12/29 页）」。
- 第 3 条是审查补上的**真实缺陷点**：只看楼主下模型不含非楼主楼层，若只看模型会把用户"上次读到的非楼主楼层"永久判成不存在。
- 第 2/3/4 条都使用同一个定位目标状态机，只是提示通道不同（§3.6.5）。

#### 3.6.4 等待期怎么让用户感知（本次体验的核心）

目标可能在第 40 页，加载要几十秒。这段时间用户必须能回答三个问题：**我在等什么、还差多少、现在能不能去**。

| 问题 | 载体 | 表现 |
| --- | --- | --- |
| 我在等什么 | 胶囊文案 | `⟳ 载入到上次阅读位置 12/40 页` / `⟳ 载入到第 812 楼 12/40 页` |
| 还差多少 | **进度条上的目标刻度** | 60vp 细条：填充 = 已加载，刻度 = 目标页；两者逐渐靠近，一眼看出快到了 |
| 现在能不能去 | **不在这条胶囊里** | 就绪前没有任何「前往」动作；就绪时由 Toast 给出（§3.6.5） |

补充规则：

- **胶囊不摆一个点不动的「前往」**：它本来就不是定位入口；灰度/禁用按钮会诱导用户反复点。
- **水位卡住时给解释**：`已抓取页 > 已提交页` 持续 ≥ 2 秒时，文案追加「（等待第 13 页）」——用户知道不是卡死。
- **目标页正在抓取**：文案可显示「正在加载第 40 页」，依据服务层当前在途页集合（`activePages`，最多 4 个页码）。
- **用户主动忽略**：胶囊上的 `×` 清除目标，回到 `LOADING`，本次不再提示（**不提供菜单入口找回**，已拍板；重新进入帖子会再判一次）。
- **不打断阅读**：就绪瞬间若用户正在滚动，**不弹 Toast**；等 `onScrollStop` 后由 `evaluatePendingTarget` 的后续调用补一次（胶囊不再变化）。

#### 3.6.5 就绪时怎么提示（Toast 承担，胶囊不参与）

> **已拍板**：定位入口只由 Toast 承担，胶囊只做进度。

- **主通道**：目标进入树（`READY`）时弹一次「检测到上次阅读进度 · 前往查看」（路由/用户目标则为「目标楼层已加载」）；`FILTERED` 时弹「上次阅读位置不在只看楼主视图内 · 查看全部」。
- **次通道（可选）**：若用户正在滚动，等 `onScrollStop` 再弹；不震动、不抢焦点。
- **不自动跳**：无论等多久都不改变当前视口。用户点「前往查看」→ 展开所属根 → 居中 → 高亮 2s → Toast「已恢复上次阅读位置」；点「查看全部」→ 关闭只看楼主后立即定位。
- **过期**：Toast 是单条替换、4.3 秒消失；用户忽略后不再重复提示（本次目标保留到加载结束，期间若再次满足条件仍只弹一次）。
- **不再有 30 秒自动收起**：收起逻辑随胶囊一起移除。

#### 3.6.6 进度记录：用「目标存在 + 用户是否移动」取代计时窗口

现有 `PROGRESS_PROMPT_PROTECT_MS`（4300ms 保护窗口）是为「首屏自动定位会把顶部落成新进度」设计的；增量模型下不再自动定位，改用更可靠的事实判定：

```
canRecord = 设置开启 && treeReady && !navigationPending && !compensating
          && targetState != WAITING          // 目标还在等数据时不记
          && viewportMoved                 // 用户真的动过视口（手势滚动，或点了「前往」）
```

- `pendingTarget !== null` 期间一律不记录：用户在等待期往下翻只是「先看看」，不能因此把上次进度覆盖成第 3 页。
- `viewportMoved` 由用户手势置位（`onScrollIndex` 且非补偿、非程序化）；点「前往」也算一次用户动作。
- 目标被清除（ACTIVATED / DISMISSED / MISSING）后规则立即生效：动过 → 记录当前位置；没动过 → 不记录（保住原进度）。
- **离开页面时**（`aboutToDisappear`）同样走这个门禁：等待期「进来瞄一眼就走」不会把原进度覆盖成顶部。
- 因此可以删除 `PROGRESS_PROMPT_PROTECT_MS` 计时器与 `readingResumePending` 的窗口语义，只保留 `pendingTarget` + `viewportMoved` 两个事实。

#### 3.6.7 与其他提示的次序

同一时刻可能竞争：定位就绪提示、缺页提示、加载完成提示。优先级 **定位就绪 > 缺页 > 完成**；缺页信息并进定位文案（「检测到上次阅读进度（第 X 页缺少楼层）」），避免被后续 Toast 顶掉。

### 3.7 停止 / 退出 / 切换阅读样式

| 动作 | 语义 | 实现 |
| --- | --- | --- |
| **停止**（胶囊） | 冻结水位、停止派发、**留在本页继续读**；**终止后不再提供继续**（已拍板） | 页面置 `stopping` → 服务层 `cancel`；UI 立即反应，不等网络 |
| **系统返回 / 取消**（仅 `ENTERING`） | 放弃这次阅读并退出 | `cancelWork()` + `routerStore.back()`（现状） |
| **切换为列表阅读**（菜单，全状态可用） | 原地替换栈条目 | 现状 `replaceWithListReading()`；`ENTERING` 阶段的「以常规列表打开」按钮在 `STREAMING` 后从加载态移除（菜单已覆盖） |
| **刷新递进树**（菜单） | 整帖重抓 | `STREAMING` 中置灰（提示「正在加载」）；其他状态走 `loadTree(true)`（刷新方式见 §3.11） |
| **回复 / 编辑成功后刷新** | 整帖重抓 | 本次与现状一致（会清空重来，见 §3.11 的取舍） |

### 3.8 失败、缺页、部分数据

- **有内容时失败**：保留内容（不 `clear()` 数据源），胶囊 → 错误条；尾部「已加载 12/29 页（第 7 页加载失败）」；提供「重试」（从第 1 页整帖重抓，不做断点续传）。
- **无内容时失败**：沿用现有全屏 `ErrorStateView` + 重试。
- **空页跳过**（服务端合法空页）：语义不变；提示时机从「提交时」改为「加载结束（完成/停止/失败）时」统一发一次 Toast + 尾部常驻文案——加载中弹 Toast 会被后续提示顶掉，且此时用户还没读到那里。
- **部分数据**：`partialData` 的语义收敛为「**加载已结束**且 `committed < total`」；`STREAMING` 期间不叫部分数据（尾部显示「正在加载 n/N 页…」）。
- **被其他页面抢占**（平板多列）：保留现有语义（不自动提交、不写历史），但增量下内容已经可见 → 只把胶囊换成「加载被其他操作中断 · 重试」，不再切全屏错误态。

### 3.9 折叠与只看楼主

- **折叠规则不变**（>3 折叠显示前 2 + MORE）。加载中某根从 3 条长到 4 条时，第 3 条被 MORE 取代——语义正确（本来 4 条就该折叠），接受这次形态变化。
- **展开状态必须跨提交保留**：每次重建后按 `rootPid` 从旧模型回填 `expanded` / `rev`（现状 F9 会丢；只看楼主切换同样丢，属现存缺陷，一并修）。
- **高亮状态**保留（`highlightPid`）。
- **加载中切换只看楼主**：用已提交数据立即重建（过滤在页面侧），水位不变，后续页继续按过滤后的数据增量追加；不重新抓取。
- **加载中「→」跳转到未加载页**：登记为 `user` 目标（§3.6.1），胶囊切 `LOADING_WAIT` 并说明页码；不再走「不存在 / 不在已加载页内」的即时提示。
- **只看楼主过滤掉目标楼层**：目标在模型里但被过滤 → 视为就绪但「看不到了」。点「前往」前先判断：若开启只看楼主且目标非楼主，提示「该楼层不在只看楼主视图内」并给出关闭入口（或直接切回全部楼层后定位）。

### 3.10 尾部与菜单

尾部 `LoadEndFooter` 四态：

| 状态 | 文案 |
| --- | --- |
| `STREAMING` | 「正在加载 n/N 页…」+ 16vp LoadingProgress |
| `COMPLETE` | 「已加载全部回复」（有缺页时附「第 X 页缺少楼层」） |
| `STOPPED` | 「已加载 n/N 页」（中性，不警告） |
| `FAILED` | 「已加载 n/N 页（第 X 页加载失败）」 |

- **不新增任何菜单项**（已拍板：不加「前往上次阅读位置」）。`STREAMING` 时「刷新递进树」置灰（提示「正在加载」）。
- 忽略定位目标后本次不再提示；重新进入帖子会重新判定一次，因此不需要菜单找回入口。

### 3.11 刷新：什么是「后台刷新」，以及为什么本次不做

#### 3.11.1 现状（刷新 = 整页重来）

点菜单「刷新递进树」（或回复/编辑成功后自动刷新）时，`loadTree(true)` 会：

1. `treeReady = false` + `isLoading = true` → **List 被卸载**，已读内容整屏消失；
2. 回到全屏「正在加载全部楼层 n/N 页」；
3. 等 8~40 秒（长帖）；
4. 树重建、按刷新前的中心楼层 pid 重新定位（有一次可见跳变）；
5. 若刷新失败 → 停在**全屏错误态**，之前的树已经没了。

#### 3.11.2 「后台刷新」是什么

不卸载旧树，把新数据在后台抓完，**全部到齐后一次性替换**：

| | 现状（整页重来） | 后台刷新 |
| --- | --- | --- |
| 刷新期间 | 全屏 loading，不能读 | **旧树照常可读**，顶部胶囊「正在刷新 12/29 页」 |
| 刷新完成 | 新树 + 重定位 | 新树替换旧树 + 锚点保持中心行 |
| 刷新失败 | 旧树已丢，进错误态 | **旧树还在**，只弹一次失败提示 |
| 用户看到的 | 一直是空白 | 替换前是**旧内容**，替换后是新内容 |
| 内存 | 一份数据 | 新旧两份（PostInfo 常驻，长帖约几 MB） |
| 实现 | 现有 | 需要「双份数据 + 替换时锚点事务 + 替换粒度」 |

#### 3.11.3 为什么不建议本次做

1. **语义容易误导**：刷新期间列表显示的是旧内容，用户可能以为已经刷新完成（或以为帖子没更新）。要避免只能加显著标识，成本又上去了。
2. **替换瞬间仍是一次大重排**：新旧两份数据的行结构通常差异很大（楼层增删、引用关系变化），`RELOAD` + 锚点恢复只能保证"位置对"，不能保证"画面不动"。
3. **它不是本次体验问题的必要条件**：本次要解决的是「进入 → 首屏 → 增量 → 停止」，刷新是独立场景（用户主动触发、频率低）。
4. **回复后刷新的诉求是另一个问题**：用户想尽快看到自己刚发的楼层，正确的解法是「本地乐观插入 + 静默合并单页」，不是后台刷新整帖。

**结论**：本次保持现状（刷新 = 整页重来），但要把现状明确写进契约，避免后续误以为是增量加载的遗漏。若后续要做，建议单独立项（§8 P2 保留占位）。

### 3.12 边界

- **多列/平板**：页面被路由覆盖但仍存活时，抓取继续、UI 不提交（现有 owner/generation 机制保留）；重新可见时按当前水位一次性补渲染。
- **多列下的定位目标**：目标状态随页面实例保留，重新可见时若已 `READY` 则补一次 Toast；不在前台时不弹 Toast（避免抢别的页面）。
- **加载中切帖**：`onThreadChanged` 现有重置逻辑保留，追加「取消增量事务、清空锚点状态、清空 `pendingTarget`」。
- **超大帖**：>3000 楼不写缓存（现状）；增量内存峰值与现状相同（全帖 `PostInfo` 常驻）。
- **页面销毁晚于新页面启动**：`treeOwner` 机制保留（`FetchService.ets:396-423`）。

---

## 4. 技术方案

### 4.1 服务层：顺序水位提交

`ThreadTreeFetchService` 内部改造（对外保持 `fetchAll` 签名兼容，新增可选回调）：

```ts
/**
 * @param onCommit 水位推进回调：posts 为「按页序连续前缀」的可读快照，
 *                 committedPages 为已提交页数（= 页面能展示的页数）
 */
fetchAll(owner, tid, onProgress?, forceRefresh?, onCommit?: (posts: PostInfo[],
  committedPages: number, totalPages: number) => void)
```

内部状态（扩展 `FetchPageScheduler`）：

| 字段 | 含义 |
| --- | --- |
| `pagePosts: Map<number, PostInfo[]>` | worker 完成后暂存该页楼层（乱序） |
| `commitUpTo: number` | 已提交到的页号（连续前缀，从 1 开始） |
| `covered: Set<number>` | 已覆盖页（含空页），现有字段 |

提交循环：

```ts
// worker 每完成一页：pagePosts.set(page, posts) → tryCommit()
private tryCommit(...): boolean {
  let advanced = false
  while (true) {
    const next = scheduler.commitUpTo + 1
    if (next > scheduler.totalPages) break
    if (next !== 1 && !scheduler.pagePosts.has(next) && !scheduler.covered.has(next)) break
    const posts = scheduler.pagePosts.get(next)
    if (posts !== undefined) {
      this.mergePosts(posts, next, seenPids, collected, pageByPid)   // 去重 + 记录 pageByPid
      scheduler.pagePosts.delete(next)
    }
    scheduler.commitUpTo = next
    scheduler.covered.add(next)      // 空页也推进水位（无楼层贡献）
    advanced = true
  }
  if (advanced) onCommit?.(collected, scheduler.commitUpTo, scheduler.totalPages)
  return advanced
}
```

- `collected` **始终是连续前缀**（不再乱序追加），因此 `buildThreadTree(collected)` 在任意时刻都等价于「当前可见数据的全量构建」。
- `onCommit` 必须**单独 try/catch**（与现有 `notifyProgress` 同口径）：页面重建抛异常不能中断抓取。
- **取消后不再回调**：`cancelled` 置位后的 `tryCommit` 只更新内部数据、不触发 `onCommit`，页面不会再收到"停止之后又长出一页"。
- 失败/取消时：`result.posts = collected`、`result.loadedPages = commitUpTo`（与用户所见一致）；`covered.size` 另存 `fetchedPages` 供诊断。
- `ThreadTreeFetchResult` 新增 `totalRows`（第 1 页 `ThreadResult.pagination.totalRows`）：页面首次提交写浏览历史要用服务端总楼数，不能用已加载楼层数（§4.9）。
- `onProgress(done, total)` 保留，但**不再驱动渲染**，只服务两件事：诊断日志，以及"水位卡住"的解释文案（`done > committedPages` 持续 ≥2s → 胶囊显示「等待第 k 页」）。
- **停止 = 取消，不提供继续**（已拍板）：沿用现有 `cancel(owner)`，worker 在 `await` 返回后退出；**不新增 `pause/resume`，不保留可恢复的任务**。服务层不需要"断点"，页面也不保存"可续抓"状态。
- 停止的**即时性**由页面负责（不等待 Promise）：页面点击停止后立即冻结渲染，服务层在后台收尾，迟到的结果按代际丢弃。

### 4.2 页面层：增量提交管线

```
onCommit(posts, committed, total)
  └─ scheduleIncrementalCommit()        // 合并同一宏任务内的多次回调
       └─ setTimeout(0) →
            ├─ firstCommit ? applyFirstCommit() : applyIncremental()
            └─ applyRowsToDataSource()
```

**首次提交**（只做一次）：`applyThreadInfo`、楼主身份、`applyBlacklistStateToPosts`、写浏览历史、`syncTrackedOnOpen`。
**后续提交**：只更新 `allPosts` + 新楼层黑名单标记 + 重建 + 行通知。**不得**重复写历史/弹 Toast/重置定位。

**每次提交后统一执行「目标就绪判定」**（首次与后续都要，含缓存命中路径）。判定顺序必须与 §3.6.3 的表格一致：

```ts
/** allPids：全量未过滤楼层的 pid 集合（每次提交后 O(n) 重建，或由服务层透传） */
private evaluatePendingTarget(): void {
  const t = this.pendingTarget
  if (t === null || this.treeModel === null) return
  if (this.treeModel.postByPid.has(t.pid)) {
    this.pendingTargetState = TargetState.READY          // 在树里（含被折叠的子行）
    return
  }
  if (this.allPids.has(t.pid)) {
    this.pendingTargetState = TargetState.FILTERED       // 在帖里但被只看楼主过滤
    return
  }
  if (t.page > 0 && this.isPageCommitted(t.page)) {
    this.clearPendingTarget(TargetState.MISSING)         // 页已到、pid 不在 → 确实没有
    return
  }
  if (t.page <= 0 && this.phase === PagePhase.COMPLETE) {
    this.clearPendingTarget(TargetState.MISSING)         // 页码未知：只能等全帖到齐再判
  }
}
```

- 判定不能只看 `treeModel.postByPid`：只看楼主模式下它只含过滤后的楼层（见 §3.6.3 第 3 条）。
- `isPageCommitted(page)` 的实现：`page > 0 && page <= committedPages`（水位是连续前缀，不需要额外的页集合）。
- **调用点不止「提交后」**：只看楼主切换重建、黑名单刷新重建、展开/收起重建之后也要跑一次 `evaluatePendingTarget()`——否则目标可能已经满足条件却一直显示等待。
- 不在这里滚动；滚动只发生在用户点「前往」（`activatePendingTarget()`）时。
- `activatePendingTarget()`：`ensureRowVisible(pid)`（必要时展开所属根）→ `scrollToIndex(CENTER)` → 高亮 2s → `viewportMoved = true` → 清除目标。
- `FILTERED` 的「查看全部」是**破坏性动作**：关闭只看楼主会触发整树重建（行数变多，插入点遍布全表），需要走 RELOAD + 锚点事务（§4.5），并在动作前记录锚点；重建后若目标就绪再定位，否则退回 `WAITING`。`FILTERED` 状态下动作换成「查看全部」：关闭只看楼主 → 重建 → 再走一次定位。

**重建时保留状态**：

```ts
// 快照必须在真正重建的那一刻抓（不能在被 setTimeout 排程时抓），
// 否则用户在排程与执行之间展开/收起的根会被旧快照覆盖。
const keep: Map<number, RootState> = new Map()   // rootPid → { expanded, rev }
const highlights: Set<number> = ...               // 当前高亮 pid
const model = buildThreadTree(filteredPosts(), totalPages)
restoreRootState(model, keep)
restoreHighlights(model, highlights)
```

**提交管线必须守住的四个时序约束**（审查补充，遗漏任一条都会出可见缺陷）：

| # | 约束 | 违反后果 |
| --- | --- | --- |
| T1 | **定位事务期间不发数据源通知**：`navigationPending` / `activationPending` 为真时，提交只更新模型与 `allPosts`，把行通知挂起；事务结束后再一次性 `applyRowsToDataSource()` + 锚点补偿 | `scrollToIndex(index)` 用的 index 会被插入行挤偏，跳错层 |
| T2 | **展开状态快照取在执行时刻**（见上） | 用户刚展开的根被折叠回去 |
| T3 | **缓存 peek 命中后不启动 `fetchAll`** | 两次提交（peek 一次、缓存命中一次），列表闪一下、浏览历史写两次 |
| T4 | **停止后 `frozen = true`**：迟到的 `fetchAll` 结果只记日志，不提交、不写缓存、不改状态 | 用户点了停止，几秒后内容又长出一截 |
| T5 | **用户拖拽/惯性滚动中不提交**：`onScrollState === Scrolling` 时把提交挂起，`onScrollStop` 立即 flush | 在用户手指下插入行，滚动被打断或猛跳；`scrollToIndex` 也会抢走手势 |

### 4.3 数据源：`onDatasetChange` 单一通路

**官方约束**：同一个 LazyForEach 上，`onDatasetChange` 不能与 `onDataAdd` / `onDataChange` / `onDataReloaded` 混用；含 RELOAD 操作时其他操作不生效；多个操作指向同一 index 只有第一个生效；**每个操作的 index 都相对「修改前的原数组」**。

因此树页数据源整体切换：

```ts
// BaseLazyDataSource 新增（仅新增，不影响现有子类）
protected notifyDatasetChange(operations: DataOperation[]): void {
  for (let i = 0; i < this.listeners.length; i++) {
    this.listeners[i].onDatasetChange(operations)
  }
}

// ThreadTreeDataSource
replaceAll(list: ThreadTreeRow[]): void {   // 折叠/过滤/刷新：整表替换
  this.dataList = list.slice()
  this.notifyDatasetChange([{ type: DataOperationType.RELOAD }])
}

applyIncremental(next: ThreadTreeRow[], ops: DataOperation[]): void {
  this.dataList = next
  this.notifyDatasetChange(ops)
}
```

**行 diff（生成 ops）**，利用 I1/I2 的单调性：

1. 建旧序列 `oldKeys: Map<key, index>`。
2. 顺序遍历新 rows，得到「相对旧序列的插入点」。
3. 纯追加/插入 → `ADD`（`index` = 旧数组中的插入位置，`count` = 连续插入条数，`key` = 新行的 `rowKey`）。
4. 位置不变但内容变（MORE 计数、正文/高亮） → `CHANGE`。
5. 出现删除/移动（理论上只有「3 条 → 2 + MORE」这一种同位置形态变化）→ 用 `DELETE + ADD` 同位置表达；若 diff 判定为复杂重排（防御性兜底），整表 `RELOAD` 并走锚点事务。

> 实现上建议先做**保守版本**：能纯追加就 `ADD/CHANGE`，否则 `RELOAD`，并统计 RELOAD 占比（日志）。跑真实帖后若 RELOAD 频繁，再补 DELETE/MOVE。

### 4.4 建树与行对象复用

- **v1（本期）**：仍用 `buildThreadTree` 全量重建，但**按 `rowKey` 复用旧 `ThreadTreeRow` 实例**（内容变了才 new）。理由：LazyForEach 以 key 复用组件，但 `getData()` 返回新对象会让 `@Prop` 全部重新赋值；复用对象能让未变化行「零变更」。
- 成本估算：2000 楼全量重建 ≈ 5~20ms（`scanLeadingQuoteArea` 有快速路径，主成本是 sort + Map + 对象分配），每页一次、限流下限 250ms，主线程占用 <10%。
- **v2（实测不足再做）**：`ThreadTreeIncrementalBuilder` —— 只处理新增楼层（`scan → parentPid → push child / new root`），行数组 `splice` 插入。用「同一数据集：全量 vs 分页增量」的对拍单测锁定结果一致。

### 4.5 锚点事务（树页自实现，只共享公式）

**树页自己实现一套字段**（命名对照 `ThreadPanel` 的 `prependAnchor*` 便于阅读，但两页字段、方法、实例完全独立，互不引用）：

```ts
// ThreadTreePanel 内新增（不是 ThreadPanel 的字段）
private appendAnchorPending: boolean = false
private appendAnchorPid: number = -1
private appendAnchorOffset: number = 0
private appendAnchorScheduled: boolean = false
```

流程与列表页的 `preparePrependAnchor` / `schedulePrependAnchorRestore`（`ThreadPanel.ets:1001-1107`）**只共享公式**，实现上不同：

| | 普通列表（参考） | 递进树（本方案） |
| --- | --- | --- |
| 锚点数据 | 帖子索引 + `PostInfo.pid` | 扁平行下标 + `ThreadTreeRow.post.pid`（MORE 行取邻近楼层行） |
| 查找新位置 | `mgr.findPostIndex(pid)` | `treeDataSource.findIndexByPid(pid)` |
| 触发时机 | 提交上一页（前插） | 每次增量提交（插入可能落在视口上方） |
| 是否执行滚动 | 总是恢复 | **只在 `newIndex > oldIndex` 时**执行（插入在视口内/下方不滚） |

差异外的不变量完全一致：事务期间 `compensating = true`，抑制进度记录与「用户已滚动」标记；`extraOffset = H - anchorOffset`，`H = statusBarHeight + NAV_BAR_H`。
> 注意：`ThreadPanel` 的 `mgr`（`ThreadPaginationManager`）与 `postsDataSource`（`PostInfoDataSource`）**不在树页的可访问范围内**，树页也不得引入它们。

### 4.6 进度提示组件

页面内 `@Builder`（不引入全局单例）：`Stack` 顶层 overlay，`position({ x: 12, y: statusBarHeight + NAV_BAR_H + 8 })`，`hitTestBehavior(Transparent)`，内部「停止」按钮 `Block`。视觉参数见 §3.3；`toastBg` / `toastAccent` 已有深浅色资源，无需新增。

新增状态：`bannerVisible`、`bannerProgress`、`bannerLabel`、`bannerMode`（loading / stopping / error）。淡入淡出用 `TransitionEffect.OPACITY.animation({ duration: 200 })`，**不做高度动画**。

### 4.7 预热与解析

- 服务层在 `tryCommit` 成功时对该页楼层调用 `preWarmBatch(contents, taskpool.Priority.HIGH)`（不 await）。
- **节流**：一次水位推进里最多预热 2 页（`TREE_WARMUP_PAGES_PER_COMMIT`）；长帖 100 页会产生 100 次 taskpool 任务，不节流会与主线程争抢。
- 预热异常一律吞掉：缓存未命中时渲染层会同步解析，只退化为该路径，不能影响抓取流程。
- 保留完成后对首屏 60 楼的既有预热（重复命中缓存，无副作用）。

### 4.8 停止的即时性

- 页面：`stopping = true` → 立刻停止渲染新页、胶囊变「正在停止…」→ 300ms 后淡出 → `STOPPED`。
- 服务层：`cancel(owner)` 置标记；worker 在 `await` 返回后退出；结果 Promise 迟到时页面按代际丢弃。
- 用户感知：点击即停；不需要等 15s 超时。

### 4.9 缓存 / 历史 / 跟踪 / 进度

| 项 | 增量下做法 |
| --- | --- |
| 短时缓存 | 仍只在**完整成功**时写（服务层现状）；`STOPPED/FAILED` 不写 |
| 浏览历史 | **首次提交**时写一次，完成时不再写；避免「加载中被中断 → 完全没记录」。**`pagination.totalRows` 必须用服务端总数**（`ThreadResult.pagination.totalRows`，需由 `ThreadTreeFetchResult` 透传），不能用已加载楼层数——否则浏览历史里这个帖子只剩 20 楼 |
| 跟踪已读 | 首次提交后调用一次 `syncTrackedOnOpen` |
| 阅读进度 | 按 §3.6.6：`pendingTarget !== null` 期间不落盘；目标清除后仍需 `viewportMoved`（手势滚动或点「前往」）才记录；增量提交不重置 `lastScrollStart/Center`；补偿事务期间不记录；等待期离开且从未移动时不补记 |
| 缺页提示 | 只在 `COMPLETE` 时弹一次 Toast（并进尾部常驻文案）；`STOPPED` / `FAILED` 不再弹，只在尾部标注——用户已经放弃等待，Toast 是噪音 |
| 数据管理/导出 | 无变化 |

### 4.10 改动清单

| 文件 | 改动 |
| --- | --- |
| `service/ThreadTreeFetchService.ets` | 水位提交（`pagePosts` / `commitUpTo` / `tryCommit`）、`onCommit` 回调、每页预热、`loadedPages` 口径（不新增 pause/resume） |
| `pages/ThreadTreePanel.ets` | 状态机、首屏缓存快路径、增量提交管线、`pendingTarget` 生命周期与胶囊状态、重建保留展开状态、锚点事务、尾部四态、错误条、`missingFloorHint` 三态 |
| `common/utils/ThreadTreeLocatePolicy.ets`（新） | 纯函数：目标登记优先级（route > user > resume）、就绪判定、MISSING 判定、胶囊文案与状态（可单测） |
| `common/model` 或 `model/ThreadTree.ets` | 新增 `LocateTarget` / `TargetState`（数据结构，先行冻结） |
| `common/datasource/BaseLazyDataSource.ets` | 新增 `notifyDatasetChange` |
| `common/datasource/ThreadTreeDataSource.ets` | `replaceAll` 改 RELOAD 操作；新增 `applyRowOps`；覆盖 `appendAll`/`prependAll` 避免混用 `onDataAdd` |
| `common/utils/ThreadTreeRowDiff.ets`（新） | 纯函数：old rows → new rows ⇒ `DataOperation[]` + 锚点位移量（可单测） |
| `common/utils/ThreadTreeBuilder.ets` | 新增 `restoreRootState`（或放页面侧）；建树逻辑不变 |
| `entry/src/test/ThreadTreeIncrementalUnit.test.ets`（新） | 水位/diff/状态合并/文案/对拍；`ThreadTreeLocatePolicy` 的状态迁移与文案 |
| `docs/THREAD_TREE_DESIGN.md` | 修订 D11 / D14 / §3.1 / §3.5，新增「增量加载」章节指向本文 |

**不在改动范围**：`pages/ThreadPanel.ets`（普通列表页）、`ThreadPaginationManager`、`PostInfoDataSource`、`reading_progress`。本文任何实现都不得触碰它们；若发现需要"顺手改一下列表页"，说明方案越界了，应先回到 §0.1 的边界约定复核。

### 4.11 易漏点清单（审查补充）

这些不是架构决策，但漏掉任何一条都会在真机上表现成"偶发 bug"：

| # | 位置 | 要做的事 |
| --- | --- | --- |
| E1 | `ThreadTreePanel.aboutToDisappear` | 清理新增的所有定时器：就绪 Toast 延时、锚点 `scheduled`、首屏延迟；`pendingTarget` 置空 |
| E2 | 全页 | 用 `phase` 取代 `isLoading` 的加载态语义；`BottomBar` 条件从 `treeReady && !isLoading` 改为 `phase !== ENTERING`；保留 `treeReady` 作为"至少有一页数据" |
| E3 | `loadTree(true)`（刷新） | 保留 `pendingTarget`（重置为 WAITING 重新判定）、保留 `refreshAnchorPid`、重置 `viewportMoved`；刷新期间不记录进度 |
| E4 | 胶囊 | 文案 `maxLines(1) + TextOverflow.Ellipsis`，宽度上限 `min(88%, 360vp)`；系统字号放大时不能顶掉「停止/重试」 |
| E5 | Toast | 只在页面处于前台栈顶时弹（多列覆盖时属于后台，不抢当前页面的 Toast）；没有可靠的可见性信号时降级为「不弹」 |
| E6 | 日志 | 新增 `tree-commit page=.. rows=.. ops=add:3/change:1/reload:0 anchor=..`、`tree-target state=.. pid=.. page=..`、`tree-anchor restore from=.. to=..`——线上问题只能靠这三类日志定位 |
| E7 | `missingFloorHint` | 从三态扩为四态：加载中（还没到）/ 被只看楼主过滤 / 已停止且不在已加载页内 / 确实不存在 |
| E8 | `treeJumpToPid` | `pid <= 0` 改为 `pid < 0`：主楼 pid 在 HTML 通道是 0，当前写法会把"跳到主楼"当成"滚到顶部"（结果相同但语义错，且与 `LocateTarget` 的 0 值冲突） |
| E9 | `onThreadChanged` | 增加：清除 `pendingTarget` / 胶囊状态 / 新增定时器 / `frozen = false` |
| E10 | `aboutToDisappear` 的补记 | `recordTreeProgress()` 必须先过 §3.6.6 的门禁，否则等待期退出会把原进度覆盖成顶部 |

---

## 5. 性能预算与验收口径

| 指标 | 预算 | 测量方式 |
| --- | --- | --- |
| 第 1 页到首屏可见 | ≤ 1 帧渲染 + 网络耗时 | 真机日志打点 |
| 单次增量提交主线程耗时（2000 楼） | ≤ 20ms | `Date.now()` 打点日志 |
| 滚动帧率（加载中持续滚动） | ≥ 55fps | DevEco Profiler |
| 视口跳变 | 加载中用户正在看的行位移 ≤ 0 | 手动 + 录屏 |
| 停止响应 | 点击到 UI 冻结 ≤ 1 帧 | 手动 |
| `RELOAD` 占提交次数 | < 10%（纯追加应占多数） | 日志统计 |

**验收场景**（真机，长帖 29 页 + 100 页各一）：

1. 进入 → 第 1 页即可读；进度胶囊 300ms 后出现；抓完淡出。
2. 加载中停在主楼 → 后续页不断追加，主楼位置纹丝不动。
3. 加载中向下滚到第 200 行 → 新子行插入到上方某根下，屏幕内容不跳。
4. 展开某根（>3 子）后再来新页 → 该根保持展开，新子行追加在其末尾。
5. 点停止 → 立即冻结、胶囊淡出、尾部「已加载 n/N 页」；继续滚动可正常记录进度；**刷新菜单可整帖重抓**（没有"继续加载"入口）。
6. **等待期感知**：上次进度在第 40 页 → 胶囊显示「载入到上次阅读位置 12/40 页」+ 进度条目标刻度；未就绪时**没有「前往」**；刻度与填充逐渐靠近；卡在某一页时文案出现「（等待第 13 页）」。
7. **就绪提示**：到第 40 页 → 弹一次 Toast「检测到上次阅读进度 · 前往查看」（胶囊不变化）；**不自动跳**；点「前往查看」才居中高亮；忽略后不再重复提示。
8. **跳跃定位同机制**：从引用点进入（目标第 40 页）→ 同一套等待/就绪；加载中再点另一个未加载楼层的 `→` → 目标被替换，胶囊立刻反映新目标。
9. 某页失败 → 内容保留 + 错误条 + 重试。
10. 90 秒内重进 → 秒开，无 loading 闪烁。
11. 平板多列覆盖/返回 → 内容与水位不丢。
12. 加载中切列表 → 无损，返回后重新加载。
13. 等待期（目标第 40 页未到）进来瞄一眼就退出 → **原进度不被覆盖**；目标清除后用户滚动过再退出 → 进度更新为实际位置。
14. 停止/失败时目标未到 → 胶囊淡出、不再提示；用户点未加载楼层的 `→` → 提示「已加载到 n/N 页」。`COMPLETE` 但目标页被跳过 → 静默清除目标。

---

## 6. 风险与回退

| 风险 | 说明 | 处置 |
| --- | --- | --- |
| R1 `onDatasetChange` 的 ArkTS 字面量构造 | `DataOperation` 是 union 类型，ArkTS 对对象字面量类型推断严格 | 先写最小验证页编译；不行则按 `DataAddOperation` 等具体类型分别构造后 `as DataOperation` |
| R2 框架锚定的真实行为 | 官方文档保证，但本工程经验是「不能只依赖」 | 三层防线；显式事务兜底；真机录屏验收 |
| R3 diff 生成错误的 ops | 错一条就会错位 | 保守策略（不能纯追加就 RELOAD）+ 单测覆盖 + 日志统计 |
| R4 展开状态丢失 | 用户刚展开的根被折叠回去 | 重建后按 pid 回填，单测覆盖 |
| R5 重复副作用 | 多次提交重复写历史/Toast/定位 | `firstCommit` 门禁 + 代码审查 |
| R6 停止后后台任务泄漏 | `fetchAll` 的 Promise 迟到 | 代际丢弃（现有机制）；页面销毁 `cancelWork`；页面侧 `frozen` 双保险 |
| R7 首屏抖动 | 胶囊出现/消失、loading 切换 | overlay 不占布局 + 延迟显示 + 纯 opacity 过渡 |
| R8 单次提交插入行数过多 | 一页 20 楼可能全部挂到同一个根下（+20 行）或产生 20 个新根；`onDatasetChange` 的批量 ADD 是否仍能稳住视口，官方只保证"显示区域上方插入/删除"，没有给批量规模上限 | 真机用"引用密集"的长帖验证；必要时把一次提交拆成 ≤5 行的多次通知（同一帧内） |
| R9 拖拽中提交 | 见 T5：提交会与手势抢滚动 | 挂起到 `onScrollStop`；验收时专门测"手指按住时后台到页" |
| R10 多列覆盖时弹 Toast | Toast 是全局的，后台页面弹会打扰前台 | 见 E5；最坏情况接受一次多余 Toast |
| R11 `allPids` 索引成本 | 每次提交 O(n) 重建全量 pid 集合，2000 楼约 2000 次 Set 插入 | 与重建同量级，可接受；若并入 `buildThreadTree` 顺带产出更好 |

**回退**：本次改动集中在树页与抓取服务，保留 `THREAD_TREE_DESIGN.md` 的旧加载态代码路径作为开关（页面常量 `INCREMENTAL_LOAD = true`）成本不高，首版建议保留一个构建期开关，验证通过后删除。

---

## 7. 测试计划

**纯函数单测**（`ThreadTreeIncrementalUnit.test.ets`）：

1. 水位推进：乱序到达只提交连续前缀；空页推进水位但不贡献楼层；重复 pid 去重；第 1 页未到不提交。
2. `loadedPages` 口径：部分结果 = 已提交页；`partial` 判定不变（`derivePartial`）。
3. 行 diff：纯末尾追加、根内子行插入、MORE 行计数变化、3→4 条形态变化、无变化空 ops。
4. 锚点位移量：插入在锚点前 → 位移 = 插入行数；插入在锚点后 → 位移 0。
5. 展开状态合并：旧 `expanded/rev` 按 pid 回填；新根默认收起。
6. 进度胶囊状态与文案：`totalPages<=2` 且无目标不显示、300ms 阈值、`n` 用已提交页、四种状态（`LOADING` / `LOADING_WAIT` / `STOPPING` / `ERROR`）的文案与动作集合；加载结束一律 `HIDDEN`。
7. 尾部四态文案。
8. **定位目标状态机**（`ThreadTreeLocatePolicy`）：
   - 登记优先级 route > user > resume；后到替换；
   - 就绪判定按 pid（折叠子行也算就绪）；
   - **判定表四条顺序**：未提交→WAITING、已提交且不在→MISSING、在 `allPosts` 不在模型→FILTERED、在模型→READY；
   - **只看楼主过滤目标**：模型里没有但全量里有 → `FILTERED`，不是 `MISSING`（防误判为"楼层已删除"）；
   - `target.page <= 0`（路由 pid）时不做页判定，只在 `COMPLETE` 时判 `MISSING`；
   - `pid = 0`（主楼）是合法目标，不能被当成"无目标"；
   - 未就绪时动作集合不含「前往」；
   - 目标就绪/不可用只影响 Toast，不影响胶囊状态；
   - 目标存在期间 `canRecord = false`；清除后由 `viewportMoved` 决定。
9. **时序约束**（§4.2 T1–T5，纯状态机可测的部分）：
   - 定位事务期间提交只更新数据、不发通知；事务结束 flush 一次；
   - 停止后 `frozen` 使迟到结果不提交；
   - 拖拽中提交挂起、`onScrollStop` flush。
10. **对拍**：同一数据集，全量 `buildThreadTree` vs 按页增量提交后的模型（roots / rows 顺序与 pid 序列 / `rootPidOfPid`）完全一致。

**门禁**：`assembleHap` + `hvigorw test` + `node scripts/check-eol.mjs` + 镜像 `--dry` 0 修改。

**人工验收**：§5 的 14 个场景 + 深色/浅色 + 平板多列。

---

## 8. 分阶段实施

| 阶段 | 内容 | 产出 |
| --- | --- | --- |
| **P0** | 服务层水位 + `onCommit` + 每页预热（含节流）；页面 `phase` 状态机 + 缓存快路径 + 增量提交管线 + T1–T5 时序约束；胶囊（`LOADING`/`LOADING_WAIT`/`STOPPING`/`ERROR`）；停止即时落定；尾部四态；浏览历史 `totalRows` 口径 | 核心体验可用 |
| **P1** | 数据源 `onDatasetChange` + 行 diff + 锚点事务；展开状态保留；失败/错误条；`pendingTarget` 全状态（含 `FILTERED`/`MISSING`）与判定表；进度记录新门禁；`missingFloorHint` 四态 | 视口稳定 + 定位正确 |
| **P2** | 贴底跟随；增量建树器（若实测不足）；刷新方式（单独立项，见 §3.11） | 体验打磨 |

P0 与 P1 必须一起上线：只有 P0 时增量提交仍走 `replaceAll`，会看到明显跳动（现状 F7 的问题被放大）。

P0 内部建议按这个顺序落地，便于中途验证：

1. 服务层水位 + `onCommit`（先用日志打点验证"乱序到达只提交连续前缀"）；
2. 页面接 `onCommit`，仍用 `replaceAll` 渲染（先验证数据正确，视觉会跳）；
3. 加胶囊 + 停止 + 缓存快路径（此时"进入即可读"已成立）；
4. 再进 P1 换 `onDatasetChange` + 锚点（解决跳动）。

---

## 9. 决策状态

**已拍板（写入方案）**：

| # | 决策 | 结论 |
| --- | --- | --- |
| D-A | 停止后能否继续加载 | **不提供继续**。停止 = 终止，保留已提交内容，后续不再派发；要全内容走「刷新递进树」 |
| D-B | 定位（恢复进度 / 跳跃定位）的交互 | **统一为一套「待定位目标」机制**：都等数据、都不自动跳；就绪后由 **Toast** 给出「前往查看 / 查看全部」，未就绪时不提供任何跳转动作（§3.6） |
| D-C | 进度提示位置/形态 | 按 §3.3：标题栏下缘 32vp 胶囊（overlay 不占布局），**只承载加载进度与「停止」**；完成后消失，不承载「前往」 |
| D-E | 进度记录保护 | 用「目标存在即不记 + 用户移动过才记」替代 4300ms 计时窗口（§3.6.6） |

**已收敛（默认不做，写入契约）**：

| # | 事项 | 结论 |
| --- | --- | --- |
| D-D | 刷新是否「后台刷新」 | **本次不做**，保持「整页重来」。理由与取舍见 §3.11；若后续要做单独立项 |

**已同步到旧契约**：

1. **D14 修订**：自动失败的部分结果，在「内容已可见」时保留内容 + 顶部错误条（`THREAD_TREE_DESIGN.md` 已加说明）。
2. **D11 修订**：`ENTERING` 只保留「取消」与「以常规列表打开」（`THREAD_TREE_DESIGN.md` 已加说明）。

---

## 10. 实施记录（v4，2026-11-07）

### 10.1 落地文件

| 文件 | 内容 |
| --- | --- |
| `model/ThreadTreeLocate.ets`（新） | `LocateTarget` / `LocateSource` / `LocateState` / `TreePagePhase` / `TreeBannerMode` |
| `common/utils/ThreadTreeLocatePolicy.ets`（新） | 目标判定、覆盖优先级、胶囊状态/文案/门禁、刻度比例（纯函数） |
| `common/utils/ThreadTreeRowDiff.ets`（新） | 行序列 diff：纯插入 → ADD、内容变化 → CHANGE、无法增量 → RELOAD |
| `common/datasource/BaseLazyDataSource.ets` | 新增 `notifyDatasetChange` |
| `common/datasource/ThreadTreeDataSource.ets` | 全量走 `onDatasetChange`（`replaceAll`/`clear`/`updateAt`/`applyRowOps`） |
| `service/ThreadTreeFetchService.ets` | 水位提交（`pagePosts`/`commitUpTo`/`commitReadyPages`）、`ThreadTreeCommit` 载荷、每页预热、`loadedPages` 改已提交页、取消丢弃在途页 |
| `pages/ThreadTreePanel.ets` | 状态机、缓存快路径、增量提交管线、`pendingTarget` 生命周期、胶囊 4 态（只做进度）、尾部四态、锚点事务、展开状态保留、进度门禁、`missingFloorHint` 四态；删除旧的一次性定位路径 |
| `entry/src/test/ThreadTreeIncrementalUnit.test.ets`（新） | 24 个用例（policy 16 + diff 8），已在 `List.test.ets` 注册 |

### 10.2 与方案的差异（实施时校准）

1. **提交载荷用对象**：`ThreadTreeCommit { posts, committedPages, totalPages, threadInfo, totalRows, forumName, pageByPid }`，不是三元组——首次提交需要 `threadInfo`/`totalRows`（写浏览历史）与 `pageByPid`（进度记录），分开传会多一轮状态。
2. **停止时服务层直接丢弃在途页**（`worker` 在 `await` 返回后先判 `cancelled` 再决定是否入缓冲）：增量模型下「停止即冻结」，不再沿用旧的「取消时仍合并在途页」语义。
3. **页面 `frozen` 双保险**：`stopLoading()` 立刻置位，迟到的 `onCommit`/`finishFetch` 不再改内容。
4. **删除旧路径**：`scheduleNavigation` / `applyNavigation` / `resolveNavigationPid` / `tryRestoreTreeProgress` / `resumeTreeProgress` / `goToResumedPosition` / `applyTreeResume` / `beginViewLoaded` / `commitFailedPartial` / `recordBrowseHistory` 及相关字段已移除（无开关，避免死代码）；`rebuildTree()` 亦已删除。
5. **胶囊图标不用图片资源**：错误用文本 `!`、加载/停止中均用 `LoadingProgress`，避免新增未存在的 `$r` 资源导致编译失败（v5 已去掉 `READY` 态，不再有 `↓`）。
6. **多列覆盖时不弹 Toast 的判定未实现**（§4.11 E5 降级）：当前只在 `scrolling` 时不弹；没有可靠的页面可见性信号，接受多列下可能多弹一次。
7. **刷新仍整页重来**（§3.11 既定结论），刷新前的中心楼层登记为 `RESUME` 目标，等数据到达后由 Toast「前往查看」承担定位。
8. **`pageByPid` 随每次提交下发**（新增字段）：否则增量期间的进度记录只能用第 1 页的映射，恢复时目标页码会错。

### 10.3 门禁结果

| 项 | 结果 |
| --- | --- |
| `assembleHap`（DevEco，`--no-daemon`） | **BUILD SUCCESSFUL**（review 修复后复跑） |
| Hypium Local Test | **Tests run: 887, Failure: 0, Error: 0, Pass: 887**（含新增 24 例；review 修复后复跑） |
| `node scripts/check-eol.mjs` | **OK（全 LF）** |
| `tools/bbcode-ts` 镜像 `sync-to-ets.mjs --dry` | **0 修改** |

### 10.4 未覆盖 / 需真机验收

- 滚动锚定的真实观感（批量插入时 `maintainVisibleContentPosition` 的表现）、拖拽中提交的挂起时机；
- 折叠根增长、只看楼主过滤目标、Toast 时序等交互；
- 多列/平板覆盖下的 Toast 与目标状态；
- 长帖（29 页 / 100 页）的实际启动耗时与帧率。

### 10.5 v5 调整（2026-11-07，按评审意见收敛）

- **进度胶囊只承载加载进度与「停止」**，加载一结束（完成/停止）立即消失；TreeBannerMode 从 8 态减到 4 态（LOADING / LOADING_WAIT / STOPPING / ERROR），不再有「已就绪 / 被过滤 / 未加载」目标态，也不提供「前往 / 查看全部 / 刷新」动作。
- **定位入口回到 Toast**：READY → 「检测到上次阅读进度（或目标楼层已加载）· 前往查看」；FILTERED → 「上次阅读位置不在只看楼主视图内 · 查看全部」（点击后关闭只看楼主并立即定位）；MISSING → 静默清除。
- **30 秒自动收起移除**（Toast 自身 4.3 秒消失；胶囊随加载结束消失）。
- **保留 LOADING_WAIT 与目标刻度**：它只表达「还差多少」，属于等待期感知，不构成定位动作；目标到达后刻度消失、文案回到纯进度。
- 代码同步：resolveBannerMode 在 COMPLETE / STOPPED / ENTERING 一律返回 HIDDEN；页面删除 scheduleBannerDismiss 与 bannerDismissTimer；showTargetReadyToast 改为 showTargetToast(filtered) 同时承担「前往查看」与「查看全部」。

### 10.6 独立 Agent review 修复（2026-11-07）

三个独立审查（数据层 / 页面层 / 契约与规范）后修复：

**页面状态机**

1. **滚动中不丢 Toast**：`showTargetToast` 在 `scrolling` 时置 `targetToastPending`，`onScrollStop` 补发（就绪只判定一次，丢掉就再没机会）。
2. **结束态清理目标**：`STOPPED` / `FAILED` 静默清除 `pendingTarget`；`COMPLETE` 只保留 `READY`（供 Toast 点击），其余清除。
3. **进度记录门禁收紧**：从「有目标就不记」改为「只在 `WAITING` 不记」——否则用户不点 Toast 就整场不落盘，`aboutToDisappear` 的补记也失效。
4. **停止即时落定**：`stopLoading` 立即写 `phase` / 清目标 / 清排程，`finishFetch` 见 `stoppedByUser` 只记日志（不再卡在「正在停止…」等 15s 超时）。
5. **有内容的页失败/被抢占 → `FAILED`**：`partial` 不再伪装成用户停止，错误条与「重试」可达（符合 §3.8 与 D14 修订）。
6. **排程提交可取消、带代际**：新增 `commitTimer`，`loadTree` / `cancelWork` / `onThreadChanged` 清理；回调校验 generation，`flushCommit` 拒绝空前缀（避免刷新/切帖后用空前缀提交、串写旧帖历史）。
7. **收尾提交遵守拖拽互斥**：`finishFetch` 在 `scrolling` 时只更新 pending 并 `commitDeferred`，等 `onScrollStop` 再补。
8. **正文同帖链接与 `→` 同入口**：未加载时登记 `user` 目标并提示「在第 X 页，已加载到 Y 页」。
9. **锚点只在 `newIndex > oldIndex` 补偿**；只看楼主切换跳过锚点事务（避免「补偿 + 居中」双跳）。
10. **边界**：`ensureRowVisible` 允许 `pid = 0`（主楼）；`recordTreeProgress` 页码未知写 `-1`；`onDisAppear` 复位 `scrolling`；`targetPage` 在刷新保留目标时不被清成 `-1`。

**规范 / 契约**

11. 测试文件 6 处 `//` 注释改为块注释；删除死方法 `rebuildTree()` 与未使用的 `RowOp` / `RowOpKind` import。
12. `ThreadTreeDataSource` 覆盖 `appendAll` / `prependAll`（基类走 `onDataAdd`，与 `onDatasetChange` 混用会违反官方约束）；修正「调用方负责换 dataList」的错误注释。
13. 文件头与残留注释按增量模型重写（去掉「三种出口」「查看已加载」「首轮定位」）。
14. 胶囊宽度上限改 `88%`；尾部 `STREAMING` 增加 16vp `LoadingProgress`。

**数据层（独立 Agent 第二轮）**

15. **缓存命中空白页（P0）**：服务层在 `fetchAll` 内同步调 `onCommit` 再返回结果，而页面的 `.then(finishFetch)` 是微任务、先于 `setTimeout(0)` 的排程执行；`finishFetch` 看到 `loadedPages > committedPages` 为假就跳过 `applyCommit` 并置 `frozen`，排程随后被冻结 → `treeReady` 永远 false。修法：`finishFetch` 的补提交条件改为 `!treeReady || loadedPages > committedPages`。
16. **行 diff 同 index 冲突**：折叠行前插入子行时会产生 `ADD@j` 与 `CHANGE@j`，而官方规定同 index 只有第一条生效，CHANGE 会被静默丢弃。修法：diff 记录本批 ADD 的 index，CHANGE 撞同 index 即整体退 `RELOAD`（新增回归用例 `addAndChangeOnSameIndex_fallsBackToReload`）。
17. **缓存读取前移**：`readCache` 原排在「等待上一个任务退场」之后，缓存命中要等别的页面抓完（最坏 15s+）。改为先行读取，命中即返回。
18. **提交载荷传快照**：`ThreadTreeCommit.posts` 改为 `slice()`，避免后续页继续 push 让旧 commit 对象悄悄变长。
19. **过半空页不再清空已提交内容**：该分支只置 `ok=false` 与错误文案，不再把 `posts`/`pageByPid`/`loadedPages` 清零（那些楼层已经渲染在屏幕上）。
20. **缺页提示只报已提交范围**：`fillSkippedPages` 过滤 `page <= commitUpTo`，避免「提示第 10 页缺楼层，但只加载到第 7 页」。
21. **失败后丢弃在途页**：worker 在 `await` 返回后同样判 `scheduler.stopped`，不再入缓冲/推进水位。
22. **`updateAt` 带键**：`CHANGE` 操作补 `key`（树页 `rowKey` 含 `rev`/高亮后缀），否则框架缓存键与 keyGenerator 分叉；基类 `updateAt` 增加可选 `key` 参数保持签名兼容。
23. `targetPageRatio` 在页码越界时返回 `-1`（记录过期，不画在 100%）。

**未修（已知限制，留待真机判断）**

- 高亮/展开会改变 `rowKey`，下一次提交时 diff 退化为 RELOAD 并清掉高亮（高亮本就在 2s 后消失，影响有限）；
- 胶囊动作触摸区约 25vp（设计目标 ≥40），需要真机手感确认后再决定是否加 `responseRegion`；
- 「（等待第 k 页）」文案与进度条 `animateTo` 平滑未实现；
- 多列覆盖时的 Toast 可见性判断未做（只在滚动中挂起）；
- 水位推进（乱序只提交连续前缀）仍内嵌在服务层，未抽成纯函数做单测；`rowKey` 也未抽公共纯函数，测试用的是简化键。
