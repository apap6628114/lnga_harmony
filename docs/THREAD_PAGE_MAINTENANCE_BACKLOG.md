# 帖子页（自然列表 / 递进树）可维护性观察清单

> **用途**：记录 `ThreadPanel.ets`（自然列表）与 `ThreadTreePanel.ets`（递进树）在结构、
> 整合、实现方式、文件摆放上的**观察项**。本文件只做「抄录」，不代表已经决定要改；
> 每条都留待后续会话结合当时代码再判断。
>
> **定位方式**：条目一律以**方法名 / 字段名**定位，不写行号——两页都在持续变动，
> 行号快照没有维护价值。两页当前规模：`ThreadPanel` 3107 行，`ThreadTreePanel` 3709 行
> （重构前 3320 / 3946）。

## 一、已完成

### 第 1 段：共享语义层

两页对「同一个问题」各自实现了一份答案，已收敛到单一真源，**未改变任何分支与阈值**：

| 内容 | 落点 |
|---|---|
| 楼主标识判定、楼主判定、楼主昵称、收藏菜单文案、离线来源、进度恢复来源白名单、标题栏标题、朗读元数据、网页地址 | `common/utils/ThreadPostUtils.ets` |
| 应用内帖子链接（`#/thread?tid=&pid=&page=`）解析 | `common/utils/LinkUtils.ets` 的 `InAppThreadLink` + `parseInAppThreadLink()` |
| HDS 悬浮栏几何（40 / 10 / -4） | `common/constants/Constants.ets` 的 `HDS_BAR_SIZE` / `HDS_BAR_PADDING` / `HDS_BAR_CONTENT_OFFSET_Y` |
| 列表页 `build()` 内联的十余行朗读逻辑 | 收为 `ThreadPanel.readAloud()`，元数据走共享构造 |

同时删除两页 10 个逐字复制的私有方法（5 对）、3 段站内链接解析（两页各一段 +
`LinkUtils.handleForumLink` 内联一段），并把两页 3 处 `read.php?tid=` 拼接收敛到
`threadWebUrl`（`ShareUtils` 里还有第 4 处，见 D4，未动）。

### 第 2 段：更多菜单装配

- 新增 `common/components/thread-menu/ThreadMenuItems.ets`：`ThreadMenuHost`（数据 + 回调）+
  `buildThreadMenuItems()`，统一「订阅三项 → 阅读视图两项 → 外部动作两项」的顺序与离线裁剪。
- 两页 `moreMenuItems()` 只保留 `ThreadMenuHost` 的赋值（约 45 行代码），删除各自的
  `openFavoriteFolders()`。
- **下沉到装配器的行为**只有三种**纯路由**动作（两页逐字相同）：收藏入口（含空 tid 守卫）、
  「从网页打开」、「在线模式打开」（参数化 `replaceEntryOnOpenOnline`）。
- **没有合并**的行为：只看楼主的前置检查/重载（列表页）与树重建（树页）、分享的 UIContext 取值、
  切换阅读的目标页面、保存/跟踪对话框 —— 全部以回调注入，留在页面。

### 第 3 段：帖子动作与对话框内容

- AI 任务选择列表抽为 `common/dialogs/AiTaskPickerContent.ets`；两页 `aiTaskContent()` 与
  `ProfileCardPopup.aiTaskContent()` 都只保留 `tasks` 与 `onPick`（关闭对话框、启动任务仍由
  调用方做）。**三处副本已收敛为一处**。
- 保存 / 跟踪的提交流程下沉到 `common/utils/ThreadPageActions.ets`：
  `saveThreadWithToast()` / `submitThreadTrack()`。**占位标题判断留在页面**（A1 观察项，
  没有顺手改）。
- 资料卡定位（两页 19 行逐字相同的几何计算）下沉到 `LinkUtils.openProfileCardAt()`。
- **未做**：对话框壳（`CustomDialogController` 构造）仍在页面——`contentBuilder` 必须是
  页面自己的 `@Builder`；保存页范围的 3 个 `@State` 仍分开（刷新语义需单独评估）。
- **记录**：`AiTaskPickerContent.tasks` 是 `@Prop`（深拷贝快照）。当前调用方都在打开对话框
  前一次性赋值、打开期间列表不变，所以与旧的 `ForEach(this.aiTasks)` 等价；若将来允许
  「对话框打开期间配置变化」，需要改回页面内 `ForEach` 或加 `@Watch`。
- **待真机确认**：`AiTaskPickerContent` 的根是 `Column().width('100%')`，组件本体不声明宽度，
  内容宽度依赖 `CustomContentDialog` 的内容槽约束。同目录 `Dialogs.ets` 的 `NoteEditorContent`
  是同构先例（同样的组件根 `Column` + `100%`），判断风险低，但未实测。

### 第 4 段：页面私有类型归位

- `ThreadPanel` 顶部 5 个类型 → `model/ThreadPageLoad.ets`：`ThreadPageFetch`、
  `FetchPageResult`、`EditSnapshot`、`ThreadLoadMode`、`PageNavigationSource`。
- `ThreadTreePanel` 顶部 4 个类型 → `model/ThreadTreePageState.ets`：`RootState`、
  `RowAnchor`、`TreeSubmitKind`、`TreeSubmitContext`。
- 纯移动，不改类型语义（`TreeSubmitKind` 仍用类静态常量，见 C4）。

### 第 5 段：`PostItem` 接线

- `ThreadPanel.build()` 里内联构造的 `PostItem({ ... })`（16 个参数、约 55 行）提为
  `@Builder postItem(post: PostInfo)`，与树页 `postCell` 同构；`ListItem` 的直接子节点仍是
  `PostItem`（@Builder 展开），没有多包布局容器。
- 响应式边界：`post` 是 @Builder 按值参数，项内容变化由 `LazyForEach` 的
  `pid_uiRev` 键驱动重建；投票态 / 握持态 / 楼主身份仍在 @Builder 内经 `this` 读取，
  依赖关系不变。
- **未合并**：树页 `TreeList` 的 `ThreadTreeChildItem` 分支是另一套参数
  （`targetLou` / `showReplyTo` / `highlight` / `onJumpToPid`），不与 `PostItem` 共用。
- **未做**：加载态 / 错误态外壳（B4）——外层容器涉及 `layoutWeight` 的父级归属，
  需要真机确认视觉后再单独处理。

## 二、观察项（未处理）

### A. 行为一致性 / 潜在缺陷

**A1. 占位标题靠字符串比较**

- 位置：`ThreadPanel.startTrackThread()`、`ThreadTreePanel.saveThreadContent()` / `startTrackThread()`。
- 现象：`threadSubject` 的初始值被当作「标题未知」哨兵，靠与占位文案（`'帖子'` / `'递进树'`）
  比较来识别。帖子标题真的叫「帖子」或「递进树」时会被误判成未知标题（保存/跟踪时丢标题）。
- 方向候选：独立 `threadSubjectLoaded` 布尔，或 `threadSubject` 初值空串 + 展示层兜底。
- 风险：改初值会影响标题栏首屏显示与分享文案，**需先确认真机行为**。

**A2. `handleVote` 中的恒真三元**

- 位置：两页 `handleVote()`。
  - 列表页：`const effectiveState = result.ok ? expectedState : result.state`，随后 `if (result.ok)`；
  - 树页：先 `if (!result.ok) { toast; return }` 早退，之后同样写这个三元再做 Set 迁移。
- 现象：两条路径都只会在 `result.ok === true` 时使用 `effectiveState`，`result.state` 分支
  不可达。树页是「早退后仍写三元」的遗留，列表页是「三元 + if」的遗留。
- 方向候选：直接 `const effectiveState = expectedState`；或把失败分支也并入逻辑（需产品确认）。
- 风险：低，但属于**逻辑语义**，留待分析。

**A3. 两页 `handleVote` 是两套实现**

- 位置：`ThreadPanel.handleVote()`（走 `mgr.updateVoteScore`）与 `ThreadTreePanel.handleVote()`
  （直接改 `post.score` + 按 pid 回写 `allPosts` 真源）。
- 现象：同一投票语义、同一分数增量规则，两份实现；树页注释里明确写着「与列表页同一增量规则」。
- 方向候选：把「状态迁移 + 分数增量」抽成纯函数（输入旧 up/down、value、旧分数，输出新集合与增量），
  页面各自负责写回自己的模型。**不能**把写回也合并——两页的模型不同（分页窗口 vs 全帖数组）。
- 风险：中（触碰 `Set` 状态与分数回写），需单测。

**A4. `@State mgr: ThreadPaginationManager` 的刷新语义**

- 位置：`ThreadPanel` 的 `mgr` 字段。
- 现象：`mgr` 从不整体替换（仅 `mgr.reset()` / 内部方法调用），`@State` 声明会让人以为
  manager 变化能驱动刷新；实际刷新靠 `PostInfoDataSource` 的通知。
- 方向候选：改为普通 `private`（**风险高，可能改变刷新时机**），或至少在字段注释里写明
  「刷新不依赖此 @State」。优先做后者。
- 风险：高（V1 状态管理），仅记录。

**A5. 楼主标识双状态（`threadAuthorKey` + `hasThreadAuthorKey`）**

- 位置：两页各有 `threadAuthorKey` 与 `hasThreadAuthorKey`，并在 `aboutToAppear` /
  `onThreadChanged` / 抓取回填三处成对赋值。
  - 列表页：`@State threadAuthorKey` + 普通 `private hasThreadAuthorKey`；
  - 树页：**两个都是普通 `private` 字段**（`ThreadTreePanel` 的 `threadAuthorKey` 并非 @State）。
- 现象：两个字段必须手动保持同步，存在「key 已换、usable 未换」的窗口。
- **刷新边界（review 发现，非重构引入）**：
  - 列表页 `hasThreadAuthorKey` 非 `@State`：首次从主楼页补齐楼主身份时（`loadPosts` 内联段，
    约 `ThreadPanel.ets:1355` 一带，不是树页的 `applyThreadInfo`），若只把
    `hasThreadAuthorKey` 从 false 改成 true、而 `threadAuthorKey` 值不变，**不会触发重绘**，
    当前已渲染楼层的「楼主」标记可能停在旧值。
  - 树页两个字段都非 `@State`，刷新实际依靠同批更新的 `@State allPosts` 带动重绘，边界更大。
  - 旧内联写法同样如此。
- 方向候选：把 `hasThreadAuthorKey`（树页再加上 `threadAuthorKey`）`@State` 化；或改为派生
  `isAuthorKeyUsable(threadAuthorKey)`（少一个可失同步的字段），但都要评估刷新语义。
- 风险：中（影响「只看楼主」判定与楼主标记），留待分析。

### B. 重复与结构

**B2. 收藏/保存/跟踪/AI 对话框套件**（第 3 段已处理 AI 内容与提交动作）

- 已做：AI 任务选择列表抽为组件；保存/跟踪提交流程下沉到 `ThreadPageActions`。
- 剩余：`openSaveThreadDialog` / `openTrackDialog` 的 `CustomDialogController` 壳（两页逐字相同，
  但无法搬走）；保存页范围的 3 个 `@State`；controller 字段命名/顺序对齐。
- **硬限制**：对话框壳受 `contentBuilder` 必须是本组件 `@Builder` 的限制，不能整体搬到
  普通函数；`CustomDialogControllerOptions` 也不能用对象展开合并（ArkTS 不支持对象展开）。
  因此 `backgroundColor` / `systemMaterial` / `maskColor` / `autoCancel` 四行只能在每处保留。
- 风险：中（对话框模板契约与 `@BuilderParam`）。

**B3. `PostItem` 接线**（第 5 段已完成列表页部分）

- 已做：`ThreadPanel` 的 `@Builder postItem(post)`，与树页 `postCell` 同构。
- 剩余：树页 `ThreadTreeChildItem` 分支（参数不同，不合并）。
- 风险：中低（@Builder 按值传参的刷新边界已在代码注释中写明）。

**B4. 加载态 / 错误态外壳**

- 位置：两页 `LoadingState()` / `ErrorState()` 的**外层容器**（内部才是各自的
  `LoadingStateView` / `ErrorStateView`）。
- 现象：`Column` + `layoutWeight(1)` + `padding(top: NAV_BAR_H + statusBarHeight)` +
  `transition` 完全同构。
- 方向候选：抽 `PageStateContainer`（组件），由调用方设置 `layoutWeight`。
- 风险：低-中（布局属性归属）。

**B5. 握持状态三件套**（资料卡定位已在第 3 段完成）

- 已完成：`showProfileCard` → `LinkUtils.openProfileCardAt()`。
- 剩余：`onHoldingChanged` / `startHoldingHandMonitoring` / `stopHoldingHandMonitoring`
  两页逐字相同，但依赖 `this.holdingDetected` / `this.holdingStatus`（页面 `@State`）。
- 结论：**不建议**抽 `HoldingHandBinding` 小类——它要写 `@State`，抽走后刷新语义会变。
  若只是想去重，可以让 `HoldingHandMonitor` 直接暴露一个「回调 + 动画」辅助，但收益很小。

### C. 实现方式

**C1. HDS 材质块宽度计算各写一套**

- 位置：`ThreadPanel.pageBarWidth()`（按页码格数分档）与
  `ThreadTreePanel.bannerBarWidth()`（按图标/文字/动作段相加）。
- 现象：两个不同的宽度模型，共用的是「必须显式宽度」这条 HDS 约束。
- 结论：**不建议合并**——一个是固定格宽分档，一个是文字实测累加，强行统一会引入条件分支。

**C2. `syncTrackedOnOpen` 的调用点不同**

- 位置：`ThreadPanel.loadPosts()` 成功后（外层已判 `!isSavedSource()`）、
  `ThreadTreePanel.finishFetch()`（内部判 `isSavedSource()`）。
- 现象：同一职责、两处调用时机；列表页的离线判断在外层，树页在内层。语义当前一致，
  但改一处容易漏另一处。是否统一，留待分析。

**C3. 树页 banner 文字测量链**

- 位置：`ThreadTreePanel.bannerTextWidth()` → `estimateTextWidth()` / `bannerMeasureText()` /
  `updateBannerTextWidth()` / `measureTextVp()`。
- 现象：测量 + 估算兜底 + 缓存失效，四个方法；看起来像迭代产物，但都在用。
- 方向候选：先用真机确认「测量失败」路径是否还会发生，再决定是否收成一个方法。

**C4. `TreeSubmitKind` 用 `static readonly number` 模拟枚举**

- 位置：`model/ThreadTreePageState.ets` 的 `TreeSubmitKind`（重构前在 `ThreadTreePanel` 文件顶部）。
- 现象：项目其它地方用 `enum`；这里用类静态常量 + `number` 字段。ArkTS 支持 enum，
  但迁移会改变 `TreeSubmitContext.kind` 的类型标注。
- 方向候选：迁 `enum`（低风险，但纯风格问题）。

**C5. `getVisibleThreadSubject` 的 `version >= 0` 假读**

- 位置：两页 `getVisibleThreadSubject()`。
- 现象：`blacklistVersion >= 0` 恒真，只为建立 @StorageProp 响应式依赖（ArkUI V1 的常用手法）。
- 方向候选：抽一个 `touchVersion(v: number)` 并注明用途；或维持现状（注释已写清）。

### D. 文件摆放 / 命名 / 文档

**D1. 页面私有类型**（第 4 段已完成）

- `ThreadPanel` 的 `ThreadPageFetch` / `FetchPageResult` / `EditSnapshot` / `ThreadLoadMode` /
  `PageNavigationSource` → `model/ThreadPageLoad.ets`。
- `ThreadTreePanel` 的 `RootState` / `RowAnchor` / `TreeSubmitKind` / `TreeSubmitContext` →
  `model/ThreadTreePageState.ets`。
- 剩余：`TreeSubmitKind` 仍是类静态常量（C4），是否迁 `enum` 留待单独评估。

**D2. `*Dialogs.ets` 命名与内容不符**

- 位置：`common/dialogs/SaveThreadDialogs.ets`（复数名，只有一个 `SaveThreadContent`）、
  `common/dialogs/ThreadTrackDialogs.ets`（同上）。
- 现象：文件名暗示「一组对话框」，实际是「对话框内容构件」；文件头注释仍写
  「ThreadPanel 更多菜单」，但树页也在用。

**D3. 两页体量**

- 现状：`ThreadPanel` 3107 行 / 120+ 字段；`ThreadTreePanel` 3709 行 / 150+ 字段。
- 方向候选（风险从低到高）：私有类型迁出（已做）→ 对话框/菜单装配抽离（菜单已做）→
  UI 块组件化（页码气泡、底栏、进度胶囊、加载/错误外壳）。

**D4. `ShareUtils` 里还有第三份帖子 URL 拼接**

- 位置：`common/utils/ShareUtils.ets` 的 `shareThread()`：
  `builder += getActiveDomain() + '/read.php?tid=' + tid`。
- 现象：第 1 段已把两个页面的拼接收敛到 `threadWebUrl`，分享文案这一处未动
  （避免 ShareUtils 依赖 store 层）。
- 方向候选：把 `threadWebUrl` 移到更底层的模块（如 `NgaDomains` 或独立 `ThreadUrls.ets`），
  再让 ShareUtils 复用。

**D5. research 文档已过期**

- 位置：`docs/research/THREAD_TREE_CODE_MAP.md`（约 1000 行）。
- 现象：文件头自述「ThreadPanel.ets 共 3090 行」，其中的方法名与行号（如页面私有
  `isAuthorKeyUsable` / `isTopicAuthorPost`）在重构后已不存在。
- 结论：它是**历史研究快照**，不应逐行维护；阅读时以当前代码为准。若要复用其中的结论，
  先核对方法是否仍存在。

**D6. 资料卡几何在其它面板还有 4 份副本**

- 位置：`SearchPanel`、`BlacklistPanel`、`FollowListPanel`、`NotesPanel` 各自的 `showProfileCard`
  一带（280/400/8 + `px2vp` + 收敛式 + catch 兜底完全同形）。
- 现象：第 3 段只收敛了两个帖子页；这 4 处未动（不在本任务范围）。
- 方向候选：统一改调 `LinkUtils.openProfileCardAt()`。
- 风险：低（纯几何），但需逐页确认坐标参数与 `uiContext` 获取方式。

**D7. `openProfileCardAt` 把 `getUIContext()` 求值移出了 try**

- 旧实现 `const context = this.getUIContext()` 在 `try` 内第一行；新实现由调用方在实参位置求值。
- 结论：`getUIContext()` 理论上不抛，风险≈0；仅作为「逐字等价」的一处偏差记录。

**D8. 菜单 action 改读 `ThreadMenuHost` 快照**

- `ThreadMenuItems` 的动作闭包读 `host.threadTid` / `host.favoriteLabel` 等构造时快照，而不是
  点击时的 `this.*`。
- 结论：菜单打开期间 tid / 收藏态 / 阅读样式的入口不会变化，等价；若将来支持「菜单内切帖」，
  需要回看这里。

**D9. `ThreadPostUtils` 的「纯语义」表述偏宽**

- 文件头写「只收纳无状态判定与文案」，但 `threadWebUrl` 依赖 service 层的 `getActiveDomain()`。
- 结论：`common/utils → service` 在本仓有先例（`LinkUtils` / `ShareUtils`），不算越层；
  只是文件头措辞可以更准确（「无 UI 依赖」而非「无任何外部依赖」）。

## 三、评估过但**不建议合并**的部分

这些是「看起来重复、实际不该合并」的，记录在此避免后续会话误判：

| 位置 | 为什么不能合并 |
|---|---|
| `readAloud`（两页） | 列表页读原始 `content`（含引用区），树页读已剥离引用区的 `displayContent`，且树页有「标题-only 楼层」分支。合并会改变朗读内容。 |
| `shouldRecordProgress`（两页） | 列表页判 `singlePostFallback`，树页判 `targetState === WAITING`、`viewportMoved`、`navigationPending`、`compensating`。两套状态模型，语义不同。 |
| `handleLinkClick` 的定位分支 | 已共享解析；但列表页是「窗口内命中才页内跳，否则整页重开」，树页是「登记为等待目标」。定位能力不同。 |
| `pageBarWidth` / `bannerBarWidth` | 两套宽度模型（见 C1）。 |
| `aboutToAppear` / `aboutToDisappear` / `onThreadChanged` | 清理与重置的字段集合完全不同（分页窗口 vs 抓取代际/树模型），共享只能得到空壳。 |
| 保存/跟踪对话框的 `CustomDialogController` 构造 | `contentBuilder` 必须是**本组件**的 `@Builder`，搬到普通函数会丢 `this`（工程已有踩坑记录）；选项对象也不能展开合并。 |
| 两页的 `toggleAuthorOnly` | 列表页重载分页窗口，树页重建树并保持中心楼层，前置判据与 toast 文案都不同。 |
| 菜单里的「只看楼主」「分享」「切换阅读」回调 | 判据/文案/目标页面/UIContext 时机不同，只共享菜单项装配（见第 2 段）。 |

## 四、建议的后续段落

1. ~~第 1 段：共享语义层~~ —— 已完成。
2. ~~第 2 段：更多菜单装配~~ —— 已完成。
3. ~~第 3 段：帖子动作与对话框内容~~ —— 已完成（AI 内容、保存/跟踪提交、资料卡定位）。
4. ~~第 4 段：页面私有类型归位~~ —— 已完成。
5. ~~第 5 段：`PostItem` 接线~~ —— 已完成（列表页；树页 `postCell` 原本就是 @Builder）。
6. **第 6 段**：投票纯函数（A3）+ 命名（D2）。
7. **第 7 段**：UI 块组件化（D3）+ 加载/错误外壳（B4）—— 风险最高，需真机视觉确认。

每段完成后：`assembleHap` 编译门禁 + 行尾自检 + 独立 review。
