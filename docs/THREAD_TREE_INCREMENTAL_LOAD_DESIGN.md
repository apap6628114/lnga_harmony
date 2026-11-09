# 递进树增量加载与加载期交互 — 设计方案

> 状态：**已实施（P0 + P1）**（2026-11-07）
> 关联契约：`docs/THREAD_TREE_DESIGN.md`（现有 D1–D14 与 §3.5 加载态）、`docs/THREAD_DESIGN.md` §4.5（前插锚点事务）
> 本文定位：在现有契约之上**替换「一次性抓完再建树」的加载模型**，并补齐由此派生、原方案未定义的体验细节。
> 修订：v2（2026-11-07）——按评审结论收敛：停止即终止（不提供继续）、恢复进度改为「等到位再提示、不自动跳」、刷新保持现状（§3.11 说明「后台刷新」含义）、进度提示采用标题栏下缘胶囊（v8 已迁到页面底部 HDS 材质胶囊，见 §3.3 / §10.8）。
> 修订：v3（2026-11-07）——定位统一为一套「待定位目标」模型（恢复/路由/用户点击同机制），补全等待期感知设计（目标刻度、未就绪不给动作、卡页解释），进度记录门禁改为「目标存在 + 用户移动」（目标刻度已在 v8 移除）。
> 修订：v4（2026-11-07）——实施完成，落地差异见 §10。

---

## 0. 一句话

把「进入 → 全屏等待 → 一次性建树」改成「进入 → **第 1 页到达即可阅读** → 后续页按顺序增量长出来 → **底部进度胶囊可随时停止**」，并用「顺序水位提交 + LazyForEach 增量通知 + 锚点事务」三层机制，保证任意时刻视口与焦点都不跳。

同一句话的第二半：**在树里，"跳转"不是动作，而是"等"**——无论恢复上次进度还是从引用跳到某层，目标都必须先被加载出来；页面要把「在等什么、还差多少、现在能不能去」持续讲清楚，就绪后由用户决定去不去。

---

## 0.1 两个页面必须分清（本文只动递进树）

| 维度 | `pages/ThreadPanel.ets`（**普通列表**） | `pages/ThreadTreePanel.ets`（**递进树**，本文对象） |
| --- | --- | --- |
| 阅读形态 | 自然楼层顺序，一页 20 楼 | 两层扁平树（根行 + 子行 + 折叠行） |
| 数据来源 | 连续分页窗口 `ThreadPaginationManager`（按页请求，双向追加/前插） | 在线：全帖抓取 `ThreadTreeFetchService`；离线存档：本地 `rawPages`（`getSavedThreadTreeResult`，同形状结果 + 同一 `onCommit` 管线）+ `buildThreadTree` |
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
| `ENTERING` | 空（居中 LoadingProgress；**400ms 延迟淡入**，与列表页同节奏） | 无胶囊 | 无页内出口（退出走返回键；切换列表走更多菜单「切换为列表阅读」） |
| `STREAMING` | **第 1 页起的树**，持续增长 | **底部进度胶囊**（`n/N` + 停止） | 停止、读、回复、切列表、切只看楼主；定位由 **Toast** 提示（不是胶囊） |
| `COMPLETE` | 全帖树 | 胶囊转**常驻** `29/29`（无动作） | 全部 |
| `STOPPED` | 已提交部分的树 | 胶囊转**常驻** `12/29`，尾部标注 | 刷新（整帖重抓）、切列表 |
| `FAILED`（有内容） | 已提交部分的树 | **错误态胶囊**（底部常驻：`加载失败` + 重试） | 重试、刷新、切列表 |
| `FAILED`（无内容） | 空 | 全屏错误态 | 重试、取消 |

> 页面状态（`STREAMING` / `COMPLETE` …）与胶囊状态（`LOADING` / `LOADING_WAIT` / `LOADED` / `STOPPING` / `ERROR`）是**正交**的两组：胶囊只表示「还在加载 / 已加载范围 / 正在停止 / 失败重试」，加载结束转 `LOADED` 常驻、不消失；定位目标是否就绪由 Toast 提示，与胶囊无关。

> 与现有 D14 的冲突：D14 规定「自动失败的部分结果**不自动展示**」。增量模型下内容已经在屏幕上，**不可能**再退回全屏错误态；该条须修订为「**内容已在视口时保留内容 + 显式错误条**；无内容时才用全屏错误态」。

### 3.2 首屏（进入 → 第一屏内容）

1. **缓存命中（90 秒内）**：同步 `peekCache(uid, tid)` → 直接 `COMPLETE` 建树渲染，**不出现任何加载 UI**（0 帧 loading）。这是当前 F12 的直接修复。
2. **未命中**：`ENTERING` 立即渲染容器，400ms 后才淡入 loading（沿用普通列表页验证过的 400ms 节奏，但计时器与状态在树页自己实现）；第 1 页若在 400ms 内返回，用户看到的是**直接出现的内容**，没有 loading 闪屏。
3. **第 1 页内容**：主楼 + 前 20 楼（约 20 行）——足够开始阅读，也足够判断要不要继续等。
4. `ENTERING → STREAMING` 用 200ms 交叉淡入，不做高度动画（避免整页 reflow）。
5. **进入即登记定位目标**（§3.6.1）：路由 pid 优先，其次本地进度；两者都没有则不登记。登记发生在首屏提交之前，后续每次水位推进都重算「目标是否就绪」。

### 3.3 进度提示（形态 / 位置 / 文案 / 停止 / 隐藏）

> **已拍板**：胶囊**只承载加载进度与「停止」**，不承载定位动作；「前往查看」（以及"查看全部"）由 Toast 承担。
> 胶囊没有「已就绪 / 被过滤 / 未加载」这些目标态；**加载结束（完成/停止）转为常驻的 `LOADED`**，
> 只显示 `29/29` / `12/29`，无图标、无动作。

**位置**：**底部悬浮栏内、回复按钮左侧**——与列表页 `ThreadPanel.BottomBar` 的页码指示器同一位置：
`Row({ space: 8 })` 并排、`padding({ left: 16, right: 16, bottom: 16 + navBarHeight })`、右手握持靠右 /
左手握持靠左。**右手握持时回复按钮固定贴右，胶囊只在它左侧展开/收起，回复按钮不位移**；左手握持整排从左排起，
胶囊宽度变化时回复按钮会随之微移。

**材质**：**HDS 沉浸光感材质**（`HdsMaterialHost`，见 `docs/IMMERSIVE_LIGHT_DESIGN.md` §12.9），与页码指示器、
回复按钮同款：材质块高 40、与回复按钮等高且底边对齐。**不再有自绘背景色 / 圆角 / 阴影**，前景一律走
材质前景色（`UIMaterialManager.adaptiveForeground`）。

**形态**：材质块内是「图标 + 数字 + 动作」单行，**间距全部显式**（`Row({ space: 6 })`）；
**没有进度条、也没有目标刻度**：

| 状态 | 左侧 | 文案 | 右侧 | 交互 |
| --- | --- | --- | --- | --- |
| `LOADING` | ⟳ | `12/29` | 停止图标（16×16，热区 32×40） | 停止 |
| `LOADING_WAIT` | ⟳ | `12/40` | 停止图标 | 停止（停止即放弃等待目标） |
| `LOADED` | — | `29/29` / `12/29` | — | 无（纯信息） |
| `STOPPING` | ⟳ | 正在停止… | — | — |
| `ERROR` | ! | 加载失败 | 重试（文字，38×40） | 重试 |

- **停止用 SVG 图标**（`app.media.icon_stop`，圆角方块）：不再用「停止」文字，胶囊更短，且图标与数字的间距恒定。
- **数字宽度实测**：`MeasureUtils.measureText` 按 14fp 测**当前文本**（`committed/total`）的宽度，
  材质块宽 = `padding×2 + 图标 + gap + 数字 + [gap + 动作]`，内容正好铺满、右侧不留空白。
  数字进位（9→10 等）时胶囊随内容变宽、动作右移，属正常排版。
  **不要按 `total/total` 预留**：长帖（如 5138 页）早期 `8/5138` 会在数字右侧空出一大段（真机已复现）。
- **间距常量**：两端 `PAD = 10`、段间 `GAP = 6`、加载图标 14、停止图标 16、重试文字 28；
  停止/重试的 40×40 热区用 `responseRegion` 外扩，不占布局。
- `barWidth` 必须是**显式数值**（HDS 悬浮栏不能由内容撑开，§12.9）。
- 动作元素自己 `onClick`、**不传宿主 `onTap`**：宿主 `onTap` 是整块命中，点数字也会触发「停止」，容易误触。
- 内容用**显式宽度 = `barWidth`** 铺满 + 两端 `padding`；写 `'100%'` 会跟随 HDS 页签项偏移（§12.9 真机现象）。
- `ERROR` 用 `AppColors.destructive` 前景与 `!` 前缀；其余用材质前景色。
- 无障碍：`accessibilityText` 用**完整句子**补回视觉看不到的语义，如「已加载 12/29 页，双击停止」
  「载入到上次阅读位置 12/40 页，双击停止」「第 7 页加载失败，双击重试」「已加载 29/29 页」。

**文案口径**：**只报「已提交页」**，不报「已抓取页」。理由：用户看到的内容就是已提交前缀，两个数字分叉会让人怀疑内容缺失。

**何时不显示**：

- `totalPages <= 0`（第 1 页未回、总页数未知）不显示。
- `ENTERING`（树未上屏、底部栏整体不存在）不显示。
- 其余**常驻**：加载中显示进度 + 停止，结束后显示已加载范围（`LOADED`），不消失。
- **单页帖也显示 `1/1`**（用户明确要求）。
- 旧版的「300ms 延迟淡入 + 短帖抑制」已删除：胶囊不再消失，「闪一下」问题不存在，延迟反而制造「先无后有」的闪动。

**停止**：

- 点击后**立即**冻结 UI：水位提交停止、胶囊文案变「正在停止…」≤300ms，随后进入常驻 `LOADED`（`12/29`）；**不等待网络**。
- 服务层任务转入收尾（在途请求自然返回后丢弃），不占用后续 UI 状态。
- 停止后的内容 = 点击瞬间已提交的页（确定、可预期）。
- 「停止」同时放弃待定位目标：没有独立的「取消等待」入口。

**完成**：胶囊转常驻 `LOADED`（`29/29`，无动作），尾部变「已加载全部回复」；目标是否就绪由 Toast 决定（§3.6.5）。

**失败**：胶囊原地变错误态（`destructive` 前景 + `!` + 「加载失败」+「重试」），**常驻**直到用户操作；
具体哪一页失败写进 `accessibilityText` 与尾部文案（视觉不放大段原因，失败仍必须被看见）。

**滚动时**：胶囊固定在底部悬浮栏内，不随列表滚走；不因用户滚动而隐藏（用户随时可能想看还剩多少）。

### 3.4 增量节奏与「已加载」口径

- **提交单位 = 页**，水位推进可一次跨多页（某页慢、后续页已缓冲）。
- **合并提交**：同一宏任务内推进多页 → 合并为一次重建 + 一次数据源通知（`setTimeout(0)` 让出当前帧）。
- **每页到达即预热该页 BBCode**（`preWarmBatch`，不 await）——当前只在全部完成后预热前 60 楼（`FetchService.ets:843-857`），增量下必须改为「提交哪页预热哪页」，否则新增行的正文解析会同步落在渲染帧里。
- **水位等待的用户表达**（未实现，且与极简胶囊冲突）：当 `已抓取页数 > 已提交页数` 且差值 ≥ 2 时，胶囊文案追加「（正在等待第 k 页）」；不额外加 UI。
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
  page: number         // 目标页码（可 -1；只用于读屏文案，视觉不展示）
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
2. **就绪按 pid 判，不按页码**：页码只驱动读屏文案（视觉不画刻度；`page` 可能为 -1，见 §3.6.3）。
3. **目标若是被折叠的子行**：模型里有它就算 READY；点「前往」时先展开所属根再居中（`ensureRowVisible`）。
4. **`rootPid` 可能失效**（帖子结构变化）：先按 `rootPid` 展开，失败再按当前模型 `findRootPidByPid` 重查（现有 `applyTreeResume` 已有这条兜底，保留）。
5. **`pid = 0` 是合法值**：HTML 通道的主楼 pid 为 0，判定与定位都要按「主楼 / 第一行」处理，不能把 0 当"无目标"（现有 `treeJumpToPid` 里 `pid <= 0` 直接滚顶部的写法要改为 `pid < 0`）。
6. **MISSING 只能在「目标页已提交」之后判定**：加载中找不到只能说「还没加载」，不能说「不存在」（沿用 `missingFloorHint` 的三态口径）。
7. **加载结束时目标仍未到**：
   - `COMPLETE` + 目标页已提交 → 楼层确实不在（删楼/屏蔽）→ **静默清除**；
   - `COMPLETE` + 目标页未提交（该页被跳过/失败）→ **静默清除**（胶囊转常驻 `LOADED`，不再给刷新入口）；
   - `STOPPED` / `FAILED` → **静默清除**（用户已决定不等）。
8. **用户点了未加载楼层的 `→`**：分两种时机——
   - 仍在 `STREAMING`：立即登记 `user` 目标（替换当前），胶囊切 `LOADING_WAIT`，并 Toast 说明「第 40 楼在第 12 页之外，已加载到 9 页」——**让"点不动"变成一个明确的等待态**，而不是无响应；
   - 已 `STOPPED` / `FAILED` / `COMPLETE`：不会再加载了，直接按 `missingFloorHint` 给结论（已停止→「不在已加载的 n/N 页内」；完成→「不存在/已删除」），**不要登记一个永远等不到的目标**。

#### 3.6.3 判定表（就绪 / 过滤 / 缺失）

每次提交后按此表判定 `pendingTarget`，**顺序不能换**：

| # | 条件 | 结果 | 提示 |
| --- | --- | --- | --- |
| 1 | `allPosts` 中不存在该 pid，且目标页**未**提交 | `WAITING` | 胶囊 `LOADING_WAIT`（只有 `12/29` + 停止图标） |
| 2 | `allPosts` 中不存在该 pid，且目标页**已**提交 | `MISSING` | **静默清除**（不弹"楼层已删除"） |
| 3 | `allPosts` 中有、当前模型 `postByPid` 中**没有** | `FILTERED`（被只看楼主过滤） | Toast「上次阅读位置不在只看楼主视图内 · 查看全部」 |
| 4 | 当前模型 `postByPid` 中有 | `READY` | Toast「检测到上次阅读进度 · 前往查看」 |

- 第 1/2 条的「目标页」在 `target.page <= 0`（未知，典型是路由 pid）时**不可判定**：只能等 `COMPLETE` 时按「全帖已到仍不在 `allPosts`」判 `MISSING`，在此之前一直 `WAITING`。
- `target.page` 未知时读屏描述退化为「载入到第 812 楼 12/29 页」；视觉本来就没有刻度，不受影响。
- 第 3 条是审查补上的**真实缺陷点**：只看楼主下模型不含非楼主楼层，若只看模型会把用户"上次读到的非楼主楼层"永久判成不存在。
- 第 2/3/4 条都使用同一个定位目标状态机，只是提示通道不同（§3.6.5）。

#### 3.6.4 等待期怎么让用户感知（本次体验的核心）

目标可能在第 40 页，加载要几十秒。这段时间用户必须能回答三个问题：**我在等什么、还差多少、现在能不能去**。

| 问题 | 载体 | 表现 |
| --- | --- | --- |
| 我在等什么 | 读屏描述（视觉无载体） | 视觉不写「在等什么」；读屏听到「载入到上次阅读位置 12/40 页」 |
| 还差多少 | 胶囊数字 `12/40` | 只表达「已到多少页」；**不再画目标刻度**，目标在第几页没有可视化表达（极简取舍，见下） |
| 现在能不能去 | **不在这条胶囊里** | 就绪前没有任何「前往」动作；就绪时由 Toast 给出（§3.6.5） |

> **取舍说明**：进度条与目标刻度已随「极简胶囊」移除（2026-11-08，v8）。若之后发现"看不到目标还有多远"是真实痛点，
> 优先把「前往」收进胶囊（§3.6.5 的拍板需修订），而不是把刻度加回来——加刻度会让胶囊重新变成第二条进度条。

补充规则：

- **胶囊不摆一个点不动的「前往」**：它本来就不是定位入口；灰度/禁用按钮会诱导用户反复点。
- **水位卡住时给解释**（未实现）：`已抓取页 > 已提交页` 持续 ≥ 2 秒时，文案追加「（等待第 13 页）」。**与极简胶囊的宽度约束冲突**：胶囊宽度按内容各段显式相加（v12 起数字宽度实测），要做需重新评估。
- **目标页正在抓取**（未实现）：文案可显示「正在加载第 40 页」，依据服务层当前在途页集合（`activePages`，最多 4 个页码）。同上，与极简胶囊冲突。
- **放弃等待**：点胶囊的「停止」——它既停止加载也清掉待定位目标（没有独立的 `×`；已拍板，不提供菜单入口找回，重新进入帖子会再判一次）。
- **不打断阅读**：就绪瞬间若用户正在滚动，**不弹 Toast**；等 `onScrollStop` 后由 `evaluatePendingTarget` 的后续调用补一次（胶囊不再变化）。

#### 3.6.5 就绪时怎么提示（Toast 承担，胶囊不参与）

> **已拍板**：定位入口只由 Toast 承担，胶囊只做进度。

- **主通道**：目标进入树（`READY`）时弹一次「检测到上次阅读进度 · 前往查看」（路由/用户目标则为「目标楼层已加载」）；`FILTERED` 时弹「上次阅读位置不在只看楼主视图内 · 查看全部」。
- **登记即就绪时补发一次**（2026-11-08 修复）：抓取服务命中 90 秒缓存时，第 1 页在 `loadTree` 的**同步阶段**就交付，树会**先于**阅读进度读盘（Preferences）建好；读盘返回并登记目标时它已经在树里，状态直接是 `READY` / `FILTERED`，再也不会出现 `WAITING → READY` 的状态变化。提示不能只挂在「状态变化」上——登记后若目标已可操作，必须补发一次（`ThreadTreePanel.promptTargetReady()`），否则缓存命中的进入永远看不到「前往查看 / 查看全部」，用户没有任何入口回到上次阅读位置。
- **次通道（可选）**：若用户正在滚动，等 `onScrollStop` 再弹；不震动、不抢焦点。
- **不自动跳**：无论等多久都不改变当前视口。用户点「前往查看」→ 展开所属根 → 居中 → 高亮 2s → Toast「已恢复上次阅读位置」；点「查看全部」→ 关闭只看楼主后立即定位。
- **过期**：Toast 是单条替换、4.3 秒消失；用户忽略后不再重复提示（本次目标保留到加载结束，期间若再次满足条件仍只弹一次）。
- **不再有 30 秒自动收起**：Toast 自身 4.3 秒消失；胶囊转为常驻的已加载态，不参与目标生命周期。

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
| **回复 / 编辑成功后刷新** | 只抓 1 页 + 局部合并 | 见 §3.11.4：不重建整帖、不清空列表、不丢阅读位置；前提不满足时退回整帖重抓 |

### 3.8 失败、缺页、部分数据

- **有内容时失败**：保留内容（不 `clear()` 数据源），胶囊原地变错误态（`加载失败` + 重试，具体原因见读屏与尾部）；尾部「已加载 12/29 页（第 7 页加载失败）」；提供「重试」（从第 1 页整帖重抓，不做断点续传）。
- **无内容时失败**：沿用现有全屏 `ErrorStateView` + 重试。
- **空页跳过**（服务端合法空页）：语义不变；提示时机从「提交时」改为「加载结束（完成/停止/失败）时」统一发一次 Toast + 尾部常驻文案——加载中弹 Toast 会被后续提示顶掉，且此时用户还没读到那里。
- **部分数据**：`partialData` 的语义收敛为「**加载已结束**且 `committed < total`」；`STREAMING` 期间不叫部分数据（尾部显示「正在加载 n/N 页…」）。
- **被其他页面抢占**（平板多列）：保留现有语义（不自动提交、不写历史），但增量下内容已经可见 → 只把胶囊换成错误态（`加载失败` + 重试；「被其他操作中断」的细节进读屏与日志），不再切全屏错误态。

### 3.9 折叠与只看楼主

- **折叠规则不变**（>3 折叠显示前 2 + MORE）。加载中某根从 3 条长到 4 条时，第 3 条被 MORE 取代——语义正确（本来 4 条就该折叠），接受这次形态变化。
- **展开状态必须跨提交保留**：每次重建后按 `rootPid` 从旧模型回填 `expanded` / `rev`（现状 F9 会丢；只看楼主切换同样丢，属现存缺陷，一并修）。
- **高亮状态**保留：`highlightPid` 在 `rebuildTreePreservingState` 末尾把新行的 `highlighted` 回填（行键含 `_h` 后缀，不回填会让 diff 认不出旧行、退化成整表 RELOAD）。
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

点菜单「刷新递进树」时，`loadTree(true)` 会（回复/编辑后的刷新已改为单页合并，见 §3.11.4）：

1. `treeReady = false` + `isLoading = true` → **List 被卸载**，已读内容整屏消失；
2. 回到全屏「正在加载全部楼层 n/N 页」；
3. 等 8~40 秒（长帖）；
4. 树重建、按刷新前的中心楼层 pid 重新定位（有一次可见跳变）；
5. 若刷新失败 → 停在**全屏错误态**，之前的树已经没了。

#### 3.11.2 「后台刷新」是什么

不卸载旧树，把新数据在后台抓完，**全部到齐后一次性替换**：

| | 现状（整页重来） | 后台刷新 |
| --- | --- | --- |
| 刷新期间 | 全屏 loading，不能读 | **旧树照常可读**，底部胶囊继续显示 `12/29` |
| 刷新完成 | 新树 + 重定位 | 新树替换旧树 + 锚点保持中心行 |
| 刷新失败 | 旧树已丢，进错误态 | **旧树还在**，只弹一次失败提示 |
| 用户看到的 | 一直是空白 | 替换前是**旧内容**，替换后是新内容 |
| 内存 | 一份数据 | 新旧两份（PostInfo 常驻，长帖约几 MB） |
| 实现 | 现有 | 需要「双份数据 + 替换时锚点事务 + 替换粒度」 |

#### 3.11.3 为什么不建议本次做

1. **语义容易误导**：刷新期间列表显示的是旧内容，用户可能以为已经刷新完成（或以为帖子没更新）。要避免只能加显著标识，成本又上去了。
2. **替换瞬间仍是一次大重排**：新旧两份数据的行结构通常差异很大（楼层增删、引用关系变化），`RELOAD` + 锚点恢复只能保证"位置对"，不能保证"画面不动"。
3. **它不是本次体验问题的必要条件**：本次要解决的是「进入 → 首屏 → 增量 → 停止」，刷新是独立场景（用户主动触发、频率低）。
4. **回复后刷新的诉求是另一个问题**：已按「抓 1 页 + 服务端数据局部合并」落地（§3.11.4）；不采用本地乐观插入——树页乐观要新增行并估楼号，会破坏 `allPosts` 的连续前缀与行 diff 的超序列前提。

**结论**：手动刷新保持现状（刷新 = 整页重来），但要把现状明确写进契约，避免后续误以为是增量加载的遗漏。若后续要做，建议单独立项（§8 P2 保留占位）。

#### 3.11.4 回复 / 编辑后的局部刷新（已落地）

回复/编辑成功不再整帖重抓，改为**只抓一页服务端数据 + 本地增量合并**（`ThreadTreeLocalMerge.mergeTreePage`）：

| 场景 | 抓取页 | 本地动作 | 视口 |
| --- | --- | --- | --- |
| 楼层 / 主题回复 | `page=e`（末页，由服务端动态解析） | 该页楼层按 pid 合并：新增追加、同 pid 替换 | 展开所属根 → 居中 → 高亮 |
| 编辑 | `pageByPid.get(pid)` | 同 pid 替换正文（带旧缓存保护） | **不动**，原地生效 |

四条硬约束：

1. **只在 `COMPLETE && committedPages >= totalPages` 时合并**：部分加载（`STOPPED`）下合并末页会在 `allPosts` 里留下页码空洞，破坏「连续前缀」不变量，定位判定与进度胶囊会随之失真。
2. **页号必须过校验**（`resolveMergePage`）：回复的末页页码只能等于 `committedPages`（帖没涨页）或 `committedPages + 1`（刚好翻页），跨更多页说明中间页从未加载；编辑的服务端自报页码必须等于请求页（`__PAGE` 缺失时 `fillThreadResult` 会回退成 1，不校验就会把整页楼层写进错误的 `pageByPid`）。
3. **只新增 / 同位替换，不删除不移动**：行 diff 只支持「新序列是旧序列的超序列」，任何删除、改序、改键都会退化成整表 RELOAD。
4. **合并后保持 `committedPages == totalPages`**：不采纳「服务端说还有更多页」，多出来的页留给下一次补页或重新进入。

兜底：上述任一前提不满足、补页失败、编辑目标不在返回页、合并抛错 → `loadTree(true)` 整帖重抓。

失败提示：末页里没有自己那一楼（审核 / CDN 延迟）→「内容已提交，稍后刷新可见」，**不构造本地楼层**；只看楼主把新楼过滤掉 →「已回复，当前只看楼主视图不显示你的回复」。

**为什么不做本地乐观插入**：树页乐观要新增行、定父节点、估 `lou`，会破坏 `allPosts` 的连续前缀与行 diff 的超序列前提；服务端审核/延迟还会留下幽灵楼，撤销又只能靠整表 RELOAD。抓一页只有一次请求、数据全部权威，是本场景性价比最高的解法。

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
- **判定之外还有「登记时机」**：缓存命中时第 1 页在 `loadTree` 的同步阶段就交付（`fetchAll` 缓存分支直接回调 `onCommit`），树会先于进度读盘就绪，进度返回并登记目标时就已经是 `READY` / `FILTERED`。这种「登记即就绪」不会产生状态变化，`evaluatePendingTarget` 的 changed 分支不会触发——必须由登记侧补发一次就绪提示（见 §3.6.5）。
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
| T5 | **用户拖拽/惯性滚动中不提交**：中途提交在 `scrolling` 时挂起，`onScrollStop` 立即 flush；**收尾提交是唯一例外**（`finishFetch` 必须同步上屏，否则紧随的 `frozen` 会吞掉最后一批），但滚动中跳过锚点补偿，不发起 `scrollToIndex` | 在用户手指下插入行，滚动被打断或猛跳；`scrollToIndex` 也会抢走手势 |

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
3. 纯追加/插入 → `ADD`（`index` = 旧数组中的插入位置，`count` = 连续插入条数）。ADD **不带 key**：由 LazyForEach 在插入时调用 keyGenerator 生成（与官方样例一致；`DataAddOperation` 本身也没有必填 key）。
4. 位置不变但内容变（MORE 计数、正文、高亮、`post.uiRev`） → `CHANGE`，并携带**新键** `key = buildRowKey(newRow)`。省略 key 会让框架沿用旧键、按「键没变」复用旧组件，这次更新等于没发。
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

页面内 `@Builder` + `HdsMaterialHost`（不引入全局单例）：位于 `BottomBar()` 的 `Row({ space: 8 })` 内、回复按钮左侧，与列表页页码指示器同构。视觉参数见 §3.3；材质由 `HdsMaterialHost` 提供，**不再自绘 `toastBg` / `toastAccent`**。

状态：`bannerMode`（`LOADING` / `LOADING_WAIT` / `LOADED` / `STOPPING` / `ERROR`）、`bannerVisible`、`bannerErrorText`、`bannerTextW`（`measureText` 实测的数字宽度）。出现/消失用 `TransitionEffect.OPACITY.animation({ duration: 200 })`，**不做高度动画**。

### 4.7 预热与解析

- 服务层在 `tryCommit` 成功时对该页楼层调用 `preWarmBatch(contents, taskpool.Priority.HIGH)`（不 await）。
- **节流**：一次水位推进里最多预热 2 页（`TREE_WARMUP_PAGES_PER_COMMIT`）；长帖 100 页会产生 100 次 taskpool 任务，不节流会与主线程争抢。
- 预热异常一律吞掉：缓存未命中时渲染层会同步解析，只退化为该路径，不能影响抓取流程。
- 保留完成后对首屏 60 楼的既有预热（重复命中缓存，无副作用）。

### 4.8 停止的即时性

- 页面：`stopping = true` → 立刻停止渲染新页、胶囊变「正在停止…」→ 转入常驻 `LOADED`（`12/29`）→ `STOPPED`。
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
| E4 | 胶囊 | 数字宽度用 `MeasureUtils.measureText` 按**当前文本**实测，材质块宽度由各段显式相加；文案 `maxLines(1) + TextOverflow.Ellipsis`；系统字号放大时数字可省略，但不能顶掉「停止图标/重试」 |
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

1. 进入 → 第 1 页即可读；进度胶囊随第 1 页出现；抓完转常驻 `29/29`（不消失）。
2. 加载中停在主楼 → 后续页不断追加，主楼位置纹丝不动。
3. 加载中向下滚到第 200 行 → 新子行插入到上方某根下，屏幕内容不跳。
4. 展开某根（>3 子）后再来新页 → 该根保持展开，新子行追加在其末尾。
5. 点停止 → 立即冻结、胶囊转常驻 `12/29`、尾部「已加载 n/N 页」；继续滚动可正常记录进度；**刷新菜单可整帖重抓**（没有"继续加载"入口）。
6. **等待期感知**：上次进度在第 40 页 → 底部 HDS 胶囊显示 `12/40`（无进度条与刻度，读屏描述为「载入到上次阅读位置 12/40 页」）；未就绪时**没有「前往」**；卡在某一页时文案出现「（等待第 13 页）」（该项未实现）。
7. **就绪提示**：到第 40 页 → 弹一次 Toast「检测到上次阅读进度 · 前往查看」（胶囊不变化）；**不自动跳**；点「前往查看」才居中高亮；忽略后不再重复提示。
8. **跳跃定位同机制**：从引用点进入（目标第 40 页）→ 同一套等待/就绪；加载中再点另一个未加载楼层的 `→` → 目标被替换，胶囊立刻反映新目标。
9. 某页失败 → 内容保留 + 错误条 + 重试。
10. 90 秒内重进 → 秒开，无 loading 闪烁。
11. 平板多列覆盖/返回 → 内容与水位不丢。
12. 加载中切列表 → 无损，返回后重新加载。
13. 等待期（目标第 40 页未到）进来瞄一眼就退出 → **原进度不被覆盖**；目标清除后用户滚动过再退出 → 进度更新为实际位置。
14. 停止/失败时目标未到 → 胶囊转常驻已加载态、不再提示；用户点未加载楼层的 `→` → 提示「已加载到 n/N 页」。`COMPLETE` 但目标页被跳过 → 静默清除目标。

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
| R7 首屏抖动 | 胶囊出现/消失、loading 切换 | 无 300ms 延迟（胶囊随第 1 页出现、加载结束转常驻）；数字区按实测宽度固定，`6/10 → 10/10` 不伸缩；右手握持时回复按钮固定贴右、胶囊在左侧展开/收起 |
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
6. 进度胶囊状态与文案：`totalPages > 0` 显示（含单页 `1/1`）、无 300ms 延迟、`n` 用已提交页、五种状态（`LOADING` / `LOADING_WAIT` / `LOADED` / `STOPPING` / `ERROR`）的文案与动作集合；加载结束转 `LOADED` 常驻。
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
| D-C | 进度提示位置/形态 | 按 §3.3（v8/v12 修订）：**页面底部、回复按钮左侧的 HDS 沉浸光感材质胶囊**（与列表页页码条同款，高 40），加载中 `N/X` + 停止 SVG 图标，完成后常驻 `N/X`（无图标、无动作），无进度条/刻度；不承载「前往」 |
| D-E | 进度记录保护 | 用「目标存在即不记 + 用户移动过才记」替代 4300ms 计时窗口（§3.6.6） |

**已收敛（默认不做，写入契约）**：

| # | 事项 | 结论 |
| --- | --- | --- |
| D-D | 刷新是否「后台刷新」 | **本次不做**，保持「整页重来」。理由与取舍见 §3.11；若后续要做单独立项 |

**已同步到旧契约**：

1. **D14 修订**：自动失败的部分结果，在「内容已可见」时保留内容 + 顶部错误条（`THREAD_TREE_DESIGN.md` 已加说明）。
2. **D11 修订**：`ENTERING` 的页内出口已全部移除，加载屏与列表页 `ThreadPanel.LoadingState` 同构（居中加载圈 + 400ms 延迟淡入）；退出走返回键，切换列表走更多菜单（`THREAD_TREE_DESIGN.md` D11 / §3.5 已加说明）。

---

## 10. 实施记录（v4，2026-11-07）

### 10.1 落地文件

| 文件 | 内容 |
| --- | --- |
| `model/ThreadTreeLocate.ets`（新） | `LocateTarget` / `LocateSource` / `LocateState` / `TreePagePhase` / `TreeBannerMode` |
| `common/utils/ThreadTreeLocatePolicy.ets`（新） | 目标判定、覆盖优先级、胶囊状态/文案/门禁、`formatCompactProgress`（纯函数；`targetPageRatio` 保留但已无视觉调用点） |
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
- **30 秒自动收起移除**（Toast 自身 4.3 秒消失；胶囊随加载结束消失——**v9 已改为常驻，见 §10.9**）。
- **保留 LOADING_WAIT 与目标刻度**：它只表达「还差多少」，属于等待期感知，不构成定位动作；目标到达后刻度消失、文案回到纯进度（**v8 已移除刻度，见 §10.8**）。
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
7. **收尾提交不推迟**：`finishFetch` 必须同步应用最终结果（否则排程会被紧随的 `frozen` 吞掉，见 §10.15）；滚动中只跳过锚点补偿，不发起 `scrollToIndex`。原「收尾在 scrolling 时只更新 pending 并 `commitDeferred`」的表述已被本次实现取代。
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
    > 该条件已被 §10.15 取代：`onCommit` 会同步更新 `committedPages`，增量路径下条件恒假；现行实现是收尾无条件应用 `result.posts`（有楼层时）。
16. **行 diff 同 index 冲突**：折叠行前插入子行时会产生 `ADD@j` 与 `CHANGE@j`，而官方规定同 index 只有第一条生效，CHANGE 会被静默丢弃。修法：diff 记录本批 ADD 的 index，CHANGE 撞同 index 即整体退 `RELOAD`（新增回归用例 `addAndChangeOnSameIndex_fallsBackToReload`）。
17. **缓存读取前移**：`readCache` 原排在「等待上一个任务退场」之后，缓存命中要等别的页面抓完（最坏 15s+）。改为先行读取，命中即返回。
18. **提交载荷传快照**：`ThreadTreeCommit.posts` 改为 `slice()`，避免后续页继续 push 让旧 commit 对象悄悄变长。
19. **过半空页不再清空已提交内容**：该分支只置 `ok=false` 与错误文案，不再把 `posts`/`pageByPid`/`loadedPages` 清零（那些楼层已经渲染在屏幕上）。
20. **缺页提示只报已提交范围**：`fillSkippedPages` 过滤 `page <= commitUpTo`，避免「提示第 10 页缺楼层，但只加载到第 7 页」。
21. **失败后丢弃在途页**：worker 在 `await` 返回后同样判 `scheduler.stopped`，不再入缓冲/推进水位。
22. **`updateAt`/`CHANGE` 带键**：树页 `rowKey` 含 `rev`、内容版本 `uiRev` 与高亮后缀；`updateAt` 与 diff 产出的 `CHANGE` 都必须带新键，否则框架沿用旧键并按「键没变」复用旧组件。基类 `updateAt` 增加可选 `key` 参数保持签名兼容。
23. `targetPageRatio` 在页码越界时返回 `-1`（记录过期，不画在 100%）。

**未修（已知限制，留待真机判断）**

- 展开会改变 `rev`（整组换键），下一次提交时 diff 退化为 RELOAD 并清掉高亮；单纯高亮走 `_h` 后缀的 CHANGE，不再触发 RELOAD（高亮本就在 2s 后消失，影响有限）；
- 胶囊动作触摸区约 25vp（设计目标 ≥40），需要真机手感确认后再决定是否加 `responseRegion`；
- 「（等待第 k 页）」文案与进度条 `animateTo` 平滑未实现；
- 多列覆盖时的 Toast 可见性判断未做（只在滚动中挂起）；
- 水位推进（乱序只提交连续前缀）仍内嵌在服务层，未抽成纯函数做单测；`buildRowId` / `buildRowKey` / `stampRowContentRev` 已抽公共纯函数并补测，但页面接线（`applyRowsToDataSource` 的调用顺序、数据源 CHANGE 透传）仍只能靠真机验证。

### 10.7 v6 调整：进入加载态收敛到列表页同款（2026-11-08）

- 用户反馈：增量模型下第 1 页通常不到一秒就到，`ENTERING` 屏仍摆着「取消」「以常规列表打开」
  两个文字按钮、外加「正在加载第 1 页…」，像一次决策页；与列表页的极简加载不一致。
- `LoadingState()` 改为与 `ThreadPanel.LoadingState` **完全同构**：只有居中 `LoadingStateView`，
  外层 `opacity` 走新增的 `enteringLoadingOpacity`；进入时置 0，400ms 后仍在 `ENTERING` 才
  `animateTo(150ms)` 淡入（`ENTERING_LOADING_DELAY_MS`），与列表页 `loadPosts` 的 400ms 节奏一致。
  这条同时补上了 §3.2 第 2 点本来就要求、但 v4 实现时漏做的「400ms 后才淡入 loading」。
- 出口：`cancelLoadingAndExit()` 删除（唯一调用点就是那个按钮）；退出走标题栏返回 / 系统返回手势
  （`aboutToDisappear` 里的 `cancelWork()` 保证在途抓取不泄漏），切换列表走更多菜单
  「切换为列表阅读」（`ENTERING` 阶段菜单即可用，见 `moreMenuItems()`）。
- 残渣清理：`isLoading` / `hasError` / `progressDone` 三个 UI 不再读取的状态删除（加载态语义
  统一由 `phase` 承担，即 §4.11 E2 的要求）；`threadTid` 为空时直接落 `FAILED`，不再停在
  `ENTERING` 加载屏。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 22s 611ms**；
  `node scripts/check-eol.mjs` 全 LF；`tools/bbcode-ts` 镜像 `--dry` 0 修改（本次未触碰镜像文件）。
  未跑 Hypium：本次只有页面 UI/状态整理，没有纯逻辑或测试用例变更。
- 未做真机验收：400ms 门禁的实际观感（长帖首屏卡住时是否仍需要页内出口）留待体验后决定。

### 10.8 v7+v8 调整：进度胶囊迁到页面底部 + HDS 沉浸光感材质 + 极简（2026-11-08）

- 用户反馈（v7）：胶囊的「已加载 12/29 页」「载入到上次阅读位置 12/40 页」太长，希望像列表页页码条、
  保存进度指示器那样**只给数字 + 一个动作**。
- 用户反馈（v8）：位置也要和列表页页码指示器一致（**页面底部、回复按钮左侧**），并且要用
  **HDS 沉浸光感材质**；同时取消进度条——`N/X + 停止`，极简。
- 结果：
  - 胶囊从「标题栏下缘的绝对定位 overlay」搬到 `BottomBar()` 的 `Row({ space: 8 })` 里、回复按钮左侧，
    与 `ThreadPanel.BottomBar` 完全同构：材质块高 40、与回复按钮底边对齐、右手握持靠右 / 左手靠左；
    右手握持时回复按钮固定贴右、胶囊在左侧展开/收起（回复按钮不位移），左手握持整排从左排起。
  - 背板改用 `HdsMaterialHost`（§12.9 通路），**删掉自绘的 `toastBg` 背景、圆角与投影**；前景改用
    `UIMaterialManager.adaptiveForeground` / `adaptiveSecondaryForeground`（错误态仍用 `destructive`）。
  - **删掉 60×4 细进度条与目标刻度**：连同 `bannerShowsProgressBar` / `bannerFillWidth` /
    `bannerTargetRatio`、`TREE_BANNER_BAR_W`、`@State targetPage` 与页面里的 `targetPageRatio` import
    一并移除；只留「图标 + `12/29` + 停止」。宽度按状态分档，同一状态内数字变化不改宽度，
    避免材质块随每页提交重排（v9 加过常驻态宽度并删掉 ×；v10 起改为按内容计算，v12 改为实测数字宽度，
    见 §10.10 / §10.12）。
  - 错误态简化为「! 加载失败 + 重试」，具体哪一页失败进 `accessibilityText` 与尾部文案。
  - 完整语义仍走读屏：`formatLoadingText` / `formatWaitTargetText` 由 `bannerA11yText()` 使用。
- **原注意力问题的变化**：胶囊与就绪 Toast 现在都在**屏幕底部**（胶囊靠右、Toast 居中），原来
  「左上 → 下方」的第二次视线迁移已消失；剩下的只是「胶囊说进度 + Toast 说就绪」的重复提示，
  若要合并仍可做 Step 2（把「前往」收进胶囊，修订 §3.6.5 的拍板）。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 25s 271ms**；
  Hypium Local Test **Tests run: 889, Failure: 0, Error: 0, Pass: 889**；`node scripts/check-eol.mjs`
  全 LF；`tools/bbcode-ts` 镜像 `--dry` 0 修改（未触碰镜像文件）。
- 未做真机核对：HDS 材质块在底部栏与回复按钮并排时的光效溢出、`SpaceBetween` 两端分布的实际观感、
  加载态 ↔ 停止中/失败之间宽度切换的观感，均需真机确认（v12 起恢复常驻，见 §10.12）。

### 10.9 v9 调整：胶囊加载完成常驻、删除「×」（2026-11-08；v11 回退、v12 恢复，见 §10.11 / §10.12）

- 用户反馈：① 加载完成后胶囊不该消失；② 已经有「停止」按钮，后面的「×」是多余动作。
- **加载完成常驻**：`TreeBannerMode` 新增 `LOADED`，`resolveBannerMode` 在 `COMPLETE` / `STOPPED`
  返回它（不再 `HIDDEN`）——胶囊变成纯信息的 `29/29`（完成）或 `12/29`（用户停止），无动作、无图标。
  `ENTERING`（树未上屏、底部栏整体不存在）仍然是唯一的 `HIDDEN`。
- **删除「×」**：等待定位目标不再有独立取消入口——「停止」本身就是退出等待（`stopLoading` 会
  `clearPendingTarget`）。删掉 `bannerSecondaryAction` / `onBannerSecondaryAction` / `dismissPendingTarget`，
  `LOADING_WAIT` 与 `LOADING` 视觉完全一致。
- **删除 300ms 延迟门禁**：胶囊不再消失，「闪一下」问题不存在；`shouldShowBanner` 简化为纯函数
  `(mode, totalPages)`——`HIDDEN` 不显示、`ERROR` 必显示、其余总页数已知才显示。
  `TREE_BANNER_DELAY_MS`、`bannerDelayElapsed`、`bannerDelayTimer` 与三处清理代码全部删除。
- 单测：`resolveBannerMode_completeKeepsLoadedBanner`、`shouldShowBanner_visibleWheneverTotalKnown`
  替换旧的「完成即隐藏」「300ms 门禁」用例。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 25s 887ms**；
  Hypium Local Test **Tests run: 888, Failure: 0, Error: 0, Pass: 888**（889 → 888 是旧用例合并：
  「完成即隐藏」与「300ms 门禁」两组一并替换）；`node scripts/check-eol.mjs` 全 LF；
  `tools/bbcode-ts` 镜像 `--dry` 0 修改。

### 10.10 v10 调整：胶囊宽度贴合内容 + 单页帖也显示（2026-11-08）

- 用户反馈（真机截图）：① 加载时「停止」离数字太远；② 加载完成时右侧空出一段；③ `1/1` 不显示。
- 原因：v8/v9 用**固定宽度分档 + `SpaceBetween`**——数字与动作被推到两端，而宽度是拍脑袋给的
  （加载 128、常驻 84），内容撑不满时中间/右侧就空一截；`1/1` 不显示则是照搬了列表页页码条
  `totalPages > 1` 的规则。
- 修法：
  - 布局改 `Row({ space: 6 })` **紧凑排布**，不再用 `SpaceBetween`。
  - 宽度改为**按内容精确计算**：`padding×2 + 图标(14) + 间距(6) + 数字区 + [间距(6) + 动作(38)]`；
    数字区宽 = `(总页数位数 × 2 + 1) × 8.2`，**同一帖子内固定**（`6/10 → 10/10` 动作不跳动）。
    10 页帖：加载 125vp；1 页帖：加载 108vp（常驻态 61 / 45 在 v11 删除、v12 恢复，见 §10.11 / §10.12）。
  - `shouldShowBanner` 改为 `totalPages > 0`：**单页帖也显示 `1/1`**，只有总页数未知（第 1 页未回）才隐藏。
    这是对「与列表页页码条一致」的有意偏离——用户要求加载完成后始终能看到已加载范围。
- 已知取舍：数字区按 `8.2vp/字符` 估算，系统字号放大很多时数字会被省略（动作不受影响）；
  若常见字号下就出现省略，把 `TREE_BANNER_DIGIT_W` 调大即可。**v12 已改为 `MeasureUtils.measureText`
  实测（删除 `TREE_BANNER_DIGIT_W`），见 §10.12。**
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 28s 164ms**；
  Hypium Local Test **Tests run: 888, Failure: 0, Error: 0, Pass: 888**；`node scripts/check-eol.mjs`
  全 LF；`tools/bbcode-ts` 镜像 `--dry` 0 修改。
- 未做真机核对：数字区 8.2vp/字符的估算在真机上是否造成省略、10 页帖加载态 125vp 与停止中 124vp /
  失败 140vp 的宽度切换观感。

### 10.11 v11 回退：加载结束（完成/停止）仍隐藏胶囊（2026-11-08；v12 已恢复常驻，见 §10.12）

- 用户决定：**加载完成后隐藏，停止后也隐藏**——胶囊只回答「还在加载吗」。
- 回退：删除 `TreeBannerMode.LOADED`，`resolveBannerMode` 在 `COMPLETE` / `STOPPED` 返回 `HIDDEN`；
  `bannerBarWidth` / `bannerNumberWidth` / `bannerA11yText` 删除 LOADED 分支，图标回到
  「错误 `!` / 其余 `LoadingProgress`」。
- **保留 v10 的成果**：紧凑排布（`Row({ space: 6 })`）、按内容计算的宽度、`totalPages > 0` 时的
  单页帖 `1/1` 显示、无 300ms 延迟门禁。
- 单测：`resolveBannerMode_completeHidden` 取代 `resolveBannerMode_completeKeepsLoadedBanner`。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 28s 743ms**；Hypium Local Test
  **Tests run: 888, Failure: 0, Error: 0, Pass: 888**；`node scripts/check-eol.mjs` 全 LF；
  `tools/bbcode-ts` 镜像 `--dry` 0 修改。

### 10.12 v12 定稿：加载结束常驻 + 停止改 SVG 图标 + 实测间距（2026-11-08）

- 用户最终决定：**加载完成不隐藏**（常驻 `N/X`），但样式与间距要优化：
  - 加载中：`⟳ N/X` + **停止 SVG 图标**（不再用「停止」文字）；
  - 加载完成：只显示 `N/X`（无图标、无动作）；
  - 间距要精准。
- 实现：
  - `TreeBannerMode.LOADED` 恢复（`resolveBannerMode` 在 `COMPLETE` / `STOPPED` 返回它）；
    `LOADED` 只渲染数字 `Text`，无图标、无动作，宽度 = 实测数字宽 + 两端 padding。
  - 新增 `app.media.icon_stop`（24 viewBox 圆角方块，`Image.fillColor` 走材质前景色），
    布局宽 = 图标宽 16（视觉间距精确等于 GAP），40×40 热区用 `responseRegion` 外扩；
    错误态仍用「重试」文字（布局宽 28，热区同样外扩到 40×40）。
  - **数字宽度不再估算**：用 `MeasureUtils.measureText`（`UIContext`，since 12）按 14fp 实测
    **当前文本**的宽度（px → vp 向上取整），缓存进 `@State bannerTextW`；材质块宽度 =
    `padding×2 + 图标 + gap + 数字 + [gap + 动作]`。测量失败（UI 上下文未就绪）按字符类型兜底，
    不会出现 0 宽胶囊。（v14 修正：v12 曾按 `total/total` 预留，长帖早期会空出一段，见 §10.14。）
  - 间距常量：两端 `PAD = 10`、段间 `GAP = 6`、图标 14、停止图标 16、重试文字 28。
- 单测：`resolveBannerMode_completeKeepsLoadedBanner` 恢复；`shouldShowBanner` 增加 `LOADED` 断言。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 27s 315ms**；Hypium Local Test
  **Tests run: 888, Failure: 0, Error: 0, Pass: 888**；`node scripts/check-eol.mjs` 全 LF；
  `tools/bbcode-ts` 镜像 `--dry` 0 修改。
- 未做真机核对：`measureText` 结果与 `Text` 实际渲染宽度是否逐像素一致、`fillColor` 着的停止图标在
  HDS 材质上的观感、停止图标 16×16 的视觉大小与 40×40 热区的手感。

### 10.13 独立 review 修复（2026-11-08）

三个只读 Agent（代码/HDS、状态机、文档一致性）审查后修复：

**行为**

- **`STOPPING` 不再是死状态**：此前 `stopping` 只被赋 `false`，`stopLoading` 同步落定，
  「正在停止…」永远不可达（文档与单测却都断言可达）。现在 `stopLoading` 先置 `stopping = true`
  并 `refreshBanner()`，`TREE_STOP_SETTLE_MS = 300` 后由 `settleStopped()` 落定 `STOPPED`
  （胶囊转 `LOADED` `12/29`）。过渡期 `frozen` 已阻止提交；新增 `stopSettleTimer`，在
  `aboutToDisappear` / `cancelWork` / `loadTree` / 切帖时清理。
- **`onProgress` 补一次刷新**：总页数尚未随提交落地时（第 1 页未回），用 `progressTotal` 兜底
  刷新胶囊，避免它要等到首次提交才出现。
- **`bannerTextW` 在 `loadTree` 重置**（连同 `bannerMeasuredText`），切帖不残留旧宽度。

**布局 / 间距**

- 动作容器高度全部改 `'100%'`：写死 40 会被 HDS 内容区顶偏（§12.9 记录过的坑）。
- 停止按钮**布局宽 = 图标宽 16**、「重试」布局宽 = 文字宽 28，视觉间距精确等于 `GAP = 6`；
  40×40 热区用 `responseRegion` 外扩，不占布局（此前 32/38 的容器让视觉间距变成 14/11）。
- 失败前缀 `!` 加 `textAlign(Center)`，与 `LoadingProgress` 的视觉间距更接近。

**健壮性**

- 测量失败兜底由「统一 8vp/字」改为按字符类型（CJK 14 / 其余 8）：旧写法把「加载失败」估成 32vp
  （实际约 56），会导致文字被省略。
- 同一文本不重复测量（`bannerMeasuredText` 缓存）；测量失败不缓存，下次刷新重试。

**单测**

- `resolveBannerMode_completeKeepsLoadedBanner`：覆盖 COMPLETE × NONE/READY/WAITING/FILTERED/MISSING
  与 STOPPED，并断言 `stopping` 优先于阶段判定。
- `shouldShowBanner_visibleWheneverTotalKnown`：补 `LOADED,1`、`STOPPING,29`、`ERROR,0`、`LOADED,0`。

**文档**

- 修掉 §3.6.3 的「与 ×」、§4.6 的旧自绘胶囊描述（position/toastBg/bannerProgress）、§4.8 的
  「300ms 后淡出」、§7 测试计划的旧门禁描述、§9 D-C、§3.4/§3.6.4 的「固定宽度」，并给
  §10.8–§10.11 的历史记录补上「v12 恢复常驻」的链条注记。

**已知未修（记录在案）**

- `measureText` 与 `Text` 渲染可能存在 ≤1vp 差异（`Math.ceil` 方向安全，只会多留极细空白）。
- 系统字体缩放变化不会触发重测，极端字号下数字可能被省略（动作不受影响）。
- 左手握持下 `LOADING → LOADED` 宽度收缩会让回复按钮左移（与列表页页码条同行为，接受）。
- `LocateState.DISMISSED` 已无入口（保留常量，未删）。

**门禁**

- `assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 25s 679ms**；
- Hypium Local Test **Tests run: 888, Failure: 0, Error: 0, Pass: 888**；
- `node scripts/check-eol.mjs` 全 LF；`tools/bbcode-ts` 镜像 `--dry` 0 修改。

### 10.14 v14 修正：胶囊数字宽度按当前文本实测（2026-11-08）

- 真机反馈（5138 页的长帖）：**停止加载后胶囊显示 `8/5138`，右侧却空出一大段**。
- 原因：v12 为了让停止图标位置稳定，按**最大可能文本** `total/total`（`5138/5138`，9 字符）
  测量并固定数字区宽度；实际显示 `8/5138`（6 字符），差值变成数字右侧的空白。
- 修正：`bannerMeasureText` 改为按**当前文本**（`committed/total`）测量——数字与停止图标之间
  始终只隔 `GAP = 6`，材质块宽度贴合内容，LOADED 态同理。
  代价：数字进位（9→10、99→100）时胶囊随内容变宽、动作右移，属正常排版；
  不再牺牲早期页面的紧凑度去换动作位置稳定。
- 单测无变化（测量与布局不在 Local Test 覆盖范围）。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 27s 004ms**；
  Hypium Local Test **Tests run: 888, Failure: 0, Error: 0, Pass: 888**；
  `node scripts/check-eol.mjs` 全 LF；`tools/bbcode-ts` 镜像 `--dry` 0 修改。

### 10.15 缺陷修复：首屏最后一次水位提交丢失 + 折叠计数不刷新（2026-11-09）

- 用户反馈（6 页帖）：无缓存首次进入，加载完成后「回复 1 楼的楼层」不显示、3 楼折叠行
  「共 N 条回复」偏少；退出再进（命中 90s 缓存）正常，杀进程重进（无缓存）复现。
- 根因 1（**数据未上屏，不是 ArkTS 响应式观测失效**）：最后一次 `onCommit` 与
  `finishFetch` 位于同一条微任务链（`commitReadyPages` 同步回调 → worker 返回 →
  `Promise.all` → `fetchAll` → `.then`），它排的 `setTimeout(0)` 要等当前宏任务结束才执行；
  而 `onFetchCommit` 已把 `committedPages` 同步更新到最终页数，使 `finishFetch` 原有的
  `loadedPages > committedPages` 补提交条件恒假，紧接着的 `frozen = true` 又把排程提交拦掉
  → 最后一次水位推进（通常就是末页）的楼层永远不上屏。缓存命中不受影响，是因为那次
  `!treeReady` 成立、走的是全量 `applyCommit`（§10.6 第 15 条只修了这条缓存路径）。
  修法：`finishFetch` 在**所有有内容的出口**（成功 / 部分失败 / 过半空页）统一取消排程并
  应用 `result.posts`；与已上屏内容一致时 diff 为空，不会重复通知。滚动中立即应用数据，
  但跳过锚点补偿（`applyCommit(..., skipAnchor = true)`），不在手指下发起 `scrollToIndex`。
- 根因 2（**行键不含内容版本**）：`rowKey` 只有 `kind_pid_rev(+_h)`，增量合并改变折叠计数
  （或正文、`PostInfo` 字段）时键不变，LazyForEach 按「键没变」复用旧组件，`CHANGE` 被
  静默丢弃 → 3 楼折叠行「共 N 条回复」停在旧值。修法：
  - 身份键 `buildRowId`（`kind_pid_rev`，diff 匹配）与展示键 `buildRowKey`
    （身份 + `uiRev` + 高亮）拆成公共纯函数；
  - `ThreadTreeRow.uiRev` 由 `stampRowContentRev(previous, next)` 结算：内容一致继承、
    变化 +1；行从不可见状态重现时用 `post.uiRev` 兜底，避免版本回退到旧键；
  - `isSameRowContent` 增加 `post.uiRev` 比较；`mergeTreePage` 同 pid 替换时克隆并递增
    楼层版本（评论数 / 标题 / 附件等不在正文里的字段也能刷新）；
  - `RowOp` 增加 `key`，`CHANGE` 携带新键（`keyOf` 改为**必填**，杜绝省略后静默丢键），
    `ThreadTreeDataSource.applyRowOps` 透传；零 op 时 `lastRows` 对齐数据源当前行对象。
- 单测：新增 `moreRowCountChange_carriesContentKey`、`identityKeyIgnoresContentVersion`、
  `contentEqual_producesNoChange`、`buildRowKey_includesContentVersion`、
  `stampRowContentRev_bumpsChangedRow`、`stampRowContentRev_inheritsUnchangedRow`、
  `stampRowContentRev_restoresFloorVersionWhenRowReappears`、
  `postVersionChange_producesChange`、`mergedEditBumpsFloorVersionWithoutMutatingInput`。
- 真机验收：**已由用户确认**——无缓存重进 6 页帖，末页楼层与 3 楼折叠计数均恢复正常。
- 门禁：`assembleHap`（DevEco，`--no-daemon`，debug）**BUILD SUCCESSFUL in 22 s 662 ms**；
  Hypium Local Test **Tests run: 935, Failure: 0, Error: 0, Pass: 935, Ignore: 0**；
  `node scripts/check-eol.mjs` 全 LF；`git diff --check` 0 输出；`tools/bbcode-ts` 镜像 `--dry` 0 修改。
- 已知未修（非本次引入）：
  - 用户点「停止」时，已到达但尚未上屏的 pending 提交仍会被丢弃（`stopLoading` 清排程 +
    `stoppedByUser` 直接 return），语义上等价于「冻结在点击那一刻」；
  - 完成后才登记的超范围进度目标（`targetPage > committedPages` 且 `phase = COMPLETE`）
    会永久停在 `WAITING`，导致阅读进度整场不落盘（`decideTargetState` 的既有边界）；
  - `BBCodeUnit.test.ets` 有 16 个 `it` 位于 `describe` 之外，Hypium 汇总不计入
    （`class=null`），与本次改动无关。
