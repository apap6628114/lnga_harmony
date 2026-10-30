# 应用内调度器（Scheduler）调研报告

> 项目：NGA 鸿蒙客户端（ArkTS/ArkUI，Stage 模型，`targetSdkVersion` / `compatibleSdkVersion` = `26.0.0`，见 `build-profile.json5:22-23`）
> 调研方式：**只读**代码 + 本机 SDK 声明（`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api`）+ 官方文档镜像（`.dsh/skills/harmonyos-docs`，API 23 版本）
> 约束：本阶段未修改 `entry/src` 下任何 `.ets` 文件；本文档是唯一产出。
> 整理日期：2026-10-30

## 0. 结论速览（TL;DR）

1. **现有"定时/时机驱动"工作高度集中在少数几个入口**：`EntryAbility` 四个生命周期回调、`AppStore` 的三个自主定时器（凭证退避探针、草稿启动清理、三路前台轮询注册表）以及各页面 `aboutToAppear` 的一次性拉取。业务 Store 与"何时跑"的耦合点很少，具备抽成统一调度器的现实条件。
2. **系统级后台能力对本应用基本"不值得用"**，不要为调度器引入 `workScheduler` / 代理提醒 / 长时任务：
   - `workScheduler` 最小执行间隔按应用活跃分组为 **2h / 4h / 24h / 48h**，单次回调 **2 分钟** 超时即杀 Extension 进程，且回调在**独立 Extension 进程**里（拿不到 `appStore` 的内存态与已注入依赖）→ 不适合社交轮询；用于低频维护任务收益 < 成本。
   - `reminderAgentManager` **只负责弹通知、不执行代码、不能发网络请求**；手机/平板有华为管控与"应用类型 + 场景"审批，本应用"签到提醒"价值低 → 不适用。
   - `backgroundTaskManager` 长时任务的业务类型必须与声明/实际行为一致（系统一致性校验，不符会被挂起），且必须常驻通知；本应用 `KEEP_BACKGROUND_RUNNING` + `audioPlayback` 已被 TTS 占用，**不得挪用**给数据刷新/签到（合规与上架审核风险）。
   - `commonEvent`（动态订阅）要求进程存活——应用退后台几秒后即被挂起，收不到事件也跑不了任务；静态订阅在本机 SDK 26 声明中**找不到对应 ExtensionAbility 导出（待确认）** → 不用于调度。
   - `appRecovery` 是崩溃恢复/重启能力，**不是调度器**，与本次目标无关。
3. **建议的调度器是"纯应用内、前台为主"的调度器**：触发源 = 进程启动完成 / 回前台 / 回后台 / 网络恢复 / 登录态变化 / 空闲 / 前台定时 tick（可选低电量·省电模式）；**后台一律不跑网络任务，回前台做幂等 catch-up（补跑）**。
4. **公共契约应该是现有语义的收敛，而不是新造一套**：单飞（single-flight）、去重键、最小间隔节流、有界退避、超时、`generation/uid/token` 回写校验——这些已在 `PollingController`、`BaseStore.runGuardedRefresh`、`SessionGuard`、`AppStore.scheduleCredentialRecheck` 里分别实现过，调度器只做统一编排。
5. **调度器第一个要解决的问题是"回前台请求风暴"**：当前 `onForeground` 会同时触发自动签到 + 会话校验 + 三路轮询的"立即执行一次"，其中跟踪帖子一轮最多 50 帖 × 400ms 间隔可跑约 20 秒。这需要在调度器里做**优先级 / 错峰 / 全局请求预算**。

### 0.1 引用格式约定

- `[SDK:文件:L行号]`：本机 SDK 声明，根目录 `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\`。例：`[SDK:@ohos.resourceschedule.workScheduler.d.ts:L210]`。
- `[DOC:路径末尾:章节/行号]`：官方文档镜像（**API 23**），根目录 `C:\Users\ll\Desktop\nga_oh\.dsh\skills\harmonyos-docs\`。声明文件与文档冲突时**一律以本机 SDK 26 声明为准**；文档只用于补充"d.ts 注释里没有的约束"（配额、频率、审核规则），此类事实会显式标注 API 23 来源。
- `[CODE:entry/src/main/ets/...#方法名(L行号)]`：仓库代码；行号来自 read/grep 工具（与 ripgrep 行号一致）。

---

## 1. 现有触发点全表

### 1.1 全表（按触发源分组）

> "网络"列 = 该触发是否直接发起 NGA 网络请求；"可迁移性"= 迁入统一调度器的价值/难度评估（高 = 语义清晰、收益大；低 = 属于 UI 局部行为，不应进调度器）。

#### A. Ability 生命周期 / 进程级

| 编号 | 触发源 | 任务 | 代码位置 | 频率 / 节流 / 去重 | 前台/后台约束 | 网络 | 失败处理 | 可迁移性 |
|---|---|---|---|---|---|---|---|---|
| A-01 | Ability `onCreate`（进程冷启动） | 初始化 TTS、读写系统颜色模式缓存、注册系统配置订阅、`appStore.init`、启动网络监听 | `EntryAbility.ets#onCreate`（L92-131）：`TtsPlayer.initialize` L93、`appStore.init` L120、`startNetworkMonitor` L128 | 每进程一次；`appStore.init` 自身可重入但不重复初始化 | 仅冷启动 | 否（init 内部按登录态加载本地缓存，不发请求） | `appStore.init` 失败只记日志并 `throw`，由启动页轮询 `isInitializationFinished` 兜底 | **高**（"启动完成"触发源） |
| A-02 | 页面加载完成（`loadContent` 回调） | 标记页面就绪、注入 Toast 的 UIContext、开启图片解码缓存、窗口/安全区/断点初始化、补放主题 | `EntryAbility.ets#onWindowStageCreate`（L159-220），`markPageLoaded` L170 | 每次窗口创建一次 | 前台 | 否 | 各分支 try/catch 只记日志 | 中（"窗口/上下文就绪"触发源，调度器需要它来保证能力可用） |
| A-03 | Ability `onForeground`（回前台） | ①`setForegroundActive(true)` + 协调三路轮询（立即各刷一次）②自动签到 ③前台会话校验 | `EntryAbility.ets#onForeground`（L252-263）→ `AppStore.setForegroundActive` L643 / `autoCheckinIfNeeded` L587 / `sessionGuard.verifyOnForeground` L258 | 每次回前台；签到按 CST 日去重；会话校验 10min 节流（降级 1min） | 仅前台 | **是**（签到 + iflogin + 通知/动态/跟踪） | 签到静默；校验失败只 warn、UNKNOWN 不清态 | **高**（最核心的触发源） |
| A-04 | Ability `onBackground`（回后台） | `setForegroundActive(false)`（停全部轮询）、`flushAll`（工具缓存补刷 + 写队列排空 + preferences flush） | `EntryAbility.ets#onBackground`（L266-270）→ `AppStore.flushAll` L508-513 | 每次回后台 | 后台（但不发请求） | 否 | `flushAll` 无 catch（`EntryAbility` 不等待），失败仅在 `PreferencesStore.flush` 内记日志 | **高**（"回后台"触发源 + 收尾契约） |
| A-05 | Ability `onDestroy` | 标记前台失活、关闭 TTS、注销系统配置订阅 | `EntryAbility.ets#onDestroy`（L147-156） | 每次销毁 | — | 否 | try/catch 记日志 | 中（调度器"关停"入口） |
| A-06 | 系统配置变化（`systemConfiguration` 订阅） | 同步系统深浅色到 AppStorage；主题为"跟随系统"时刷新状态栏 | `EntryAbility.ets#sysConfigUpdatedCallback` L79-89（注册 L115、注销 L151） | 系统切换时 | 无 | 否 | 无 | 低（主题域，不属调度） |
| A-07 | 窗口事件（`window.on`） | 窗口尺寸变化 → 断点 + 安全区；避让区变化 → 安全区 | `EntryAbility.ets#onWindowStageCreate` 内 `mainWindow.on('windowSizeChange')` L207 / `'avoidAreaChange'` L211 | 拖拽/旋转时高频（写 AppStorage 前做了取整 + 变化判断 L301） | 前台 | 否 | try/catch | 低（UI 布局域） |
| A-08 | 应用前后台状态订阅（**当前未使用**） | —（替代 A-03 的更底层信号） | 系统能力：`ApplicationContext.on('applicationStateChange')` `[SDK:application/ApplicationContext.d.ts:L194]` | — | — | 否 | — | **高**（可作为调度器"应用级"触发源，避免依赖单一 UIAbility 回调） |
| A-09 | `onNewWant` / 二次拉起（**当前未实现**） | 无（`EntryAbility` 未覆写 `onNewWant`；`module.json5` 未声明 `launchType`） | `[SDK:@ohos.app.ability.UIAbility.d.ts:L578]` | — | — | — | — | **待确认**（见 §4.2） |

#### B. 页面 / 组件生命周期（进入页面即可触发的数据动作）

| 编号 | 触发源 | 任务 | 代码位置 | 频率 / 节流 / 去重 | 前台/后台 | 网络 | 失败处理 | 可迁移性 |
|---|---|---|---|---|---|---|---|---|
| B-01 | 启动页 `aboutToAppear` | 轮询等 `init` 结束 → 按登录态路由；有凭证则 `sessionGuard.verify()`（5s 超时三态）→ INVALID 只降级不清态 | `Index.ets#aboutToAppear` L25 / `waitAndRoute` L31-72（50ms 轮询 L33；`verify` L43；`markCredentialDegraded` L49） | 50ms 轮询直到 `isInitializationFinished`；正常态只一次 verify | 前台 | **是**（iflogin） | 路由/初始化失败写 `initializationFailed` 或跳登录页 | **高**（"启动完成 + 首屏校验"应纳入调度器的启动计划） |
| B-02 | 主页面 `aboutToAppear` | 屏幕常亮；`checkAuth`：`verifyIfStale(30s)` 复用启动页结论 → INVALID 降级 → 拉资料 / 收藏夹 / 自动签到 | `MainPage.ets#aboutToAppear` L131-137（`enableKeepScreenOn` L133）；`checkAuth` L658-690（`verifyIfStale` L667、`autoCheckinIfNeeded` L689） | 30s 内复用启动页的校验结论；签到按日去重 | 前台 | **是**（可能 iflogin + profile + 签到） | UNKNOWN 保留登录态；INVALID 降级 | **高**（回前台 catch-up 的代表） |
| B-03 | 主页面 `aboutToDisappear` | 关闭屏幕常亮、清理读数标尺定时器 | `MainPage.ets#aboutToDisappear` L139-142 | — | — | 否 | — | 低（UI 资源） |
| B-04 | 社区面板 `aboutToAppear` | 同步板块/收藏缓存，`ensureCategories()`（有缓存延迟刷新、无缓存 0ms） | `CommunityPanel.ets#aboutToAppear` L31-36；`CategoryStore.ensureCategories` L61-70（`REFRESH_DELAY` 分流 L69） | 进行中标志去重（L62）；gen 校验回写（L86） | 前台 | **是**（getForumCategories） | 失败写 `categoriesError`，有缓存则不吼 | 中（缓存优先的按需刷新，适合"页面进入"触发源，不适合全局调度） |
| B-05 | 版块列表 `aboutToAppear` | 加载主题列表第一页、刷新未读数、确保收藏夹、注册握持监测 | `TopicListPanel.ets#aboutToAppear` L363-374（`loadTopics(1)` L370、`refreshUnreadCount` L371、`ensureFavorites` L372） | 进入面板一次；`refreshNotifications(false)` 受 30s 最小成功间隔节流 | 前台 | **是** | 面板内错误态 | 中 |
| B-06 | 通知面板 `aboutToAppear` | 按 Tab 拉数据：通知 / 关注动态 / 私信 | `NotificationPanel.ets#aboutToAppear` L186-216（分支 L204-215） | 进入面板一次；普通刷新受 30s 节流 | 前台 | **是** | 面板内错误态 | 中 |
| B-07 | 帖子页 `aboutToAppear` | 加载楼层、收藏状态/收藏夹、投票记录、握持监测、恢复阅读进度 | `ThreadPanel.ets#aboutToAppear` L446-470 | 进入帖子一次；`trackThread`/`seenOnOpen` 受 1min 最小检查间隔节流 | 前台 | **是** | 面板内错误态 | 低（强用户语义，不建议迁） |
| B-08 | 资料页 / 收藏面板 / 搜索面板等 `aboutToAppear` | 按需拉资料、刷新收藏、搜索 | `ProfilePanel.ets#aboutToAppear` L165（`ensureProfile` L177）；`FavoriteSavedPanel.ets#aboutToAppear` L148；`SearchPanel.ets#aboutToAppear` L113 | 各自 store 内有去重/节流 | 前台 | **是** | 面板内错误态 | 低 |

#### C. 定时器驱动的"调度型"工作（迁移重点）

| 编号 | 触发源 | 任务 | 代码位置 | 频率 / 节流 / 去重 | 前台/后台约束 | 网络 | 失败处理 | 可迁移性 |
|---|---|---|---|---|---|---|---|---|
| C-01 | `PollingController` 前台轮询（通知） | 立即刷一次 + 每 300s 刷一次通知/未读 | `NotificationStore.ets`：`NOTIFICATION_POLL_INTERVAL` L39、`new PollingController` L71、`startPolling` L117、`refreshNotifications` L144；`PollingController.ets#start` L57 / `scheduleNext` L83 | 300s；普通刷新另有 30s 最小成功间隔（L36）+ 单飞（`BaseStore.runGuardedRefresh` L83-116） | **仅前台**（`AppStore.reconcilePolling` L653 统一启停） | **是** | 刷新返回 false 只记 warn（L191-194），轮询继续 | **高** |
| C-02 | 同上（关注动态） | 立即刷一次 + 每 300s 刷一次关注动态 | `FollowActivityStore.ets`：`ACTIVITY_POLL_INTERVAL` L42、`new PollingController` L90、`startPolling` L142 | 300s；30s 最小成功间隔（L39） | 仅前台 | **是** | 同上 | **高** |
| C-03 | 同上（跟踪帖子） | 立即查一次 + 每 10min 逐帖串行检查（帖间 400ms） | `TrackedThreadStore.ets`：`new PollingController` L123、`startPolling` L173；`model/TrackedThread.ets`：`TRACK_POLL_INTERVAL` L22（10min）、`TRACK_CHECK_GAP` L33（400ms）、`TRACK_MAX_COUNT` L19（50）、`TRACK_MIN_CHECK_INTERVAL` L30（60s） | 10min；一轮最多 50 帖 × 400ms ≈ 20s 请求窗口；30s 最小学间隔（`TRACK_REFRESH_DELAY` L53） | 仅前台 | **是**（每帖一次只读请求，约 20KB） | 单帖失败只累计 `failCount`，不停止跟踪（文件头 L14-15） | **高**（且最需要"错峰/预算"） |
| C-04 | `AppStore` 凭证降级退避探针 | 降级态下按 3s→15s→30s→60s 退避复验 iflogin；成功即恢复 | `AppStore.ets#scheduleCredentialRecheck` L427-453；退避序列 `CREDENTIAL_RECHECK_DELAYS_MS` L97 | 有界退避，第 4 档起 60s 封顶；已有定时器时幂等返回（L428） | 定时器可被后台挂起；**回调内再判前台**，后台不发（L438-441）；回前台由 `setForegroundActive` 重拉（L646-648） | **是** | 失败继续排下一档（L447-451） | **高**（退避 + 前后台门禁的现成样本） |
| C-05 | `AppStore` 草稿启动清理 | 延迟 800ms 后分批清超期草稿（每批 8 个），最后清媒体孤儿/超容量；`setTimeout(0)` 让出主线程 | `AppStore.ets#initDraftCleanup` L245-273（`DRAFT_CLEANUP_DELAY_MS` L72、`DRAFT_CLEANUP_BATCH` L75、`DRAFT_CLEANUP_MAX_ROUNDS` L84、调用点 L191）；`cleanupDraftMedia` L282-292；`DraftStore.ets#cleanupStale` L517；`DraftMediaStore.ets#cleanupStale` L348 | 每次 `init` 一次；重入守卫 `draftCleanupRunning` L246 | 纯本地 IO，无前台要求，但只在 init 后跑 | 否 | 批次失败只 warn（L263-264），守卫在 finally 释放（L267-269） | **高**（"空闲/启动后维护任务"样本） |
| C-06 | AI 工具缓存节流写盘 | 每次工具执行只标脏，800ms 合并写一次；回后台/退出前 `flush()` 补刷 | `AiToolCacheStore.ets`：`SAVE_DELAY_MS` L48、`scheduleSave` L159-165、`cancelScheduledSave` L170-175、`flush` L123-126；监听注册 L85-87；`AppStore.flushAll` L510 | 800ms 合并；`flush` 立即 | 纯本地 | 否 | 写失败只 warn（L196-199） | **高**（"节流合并 + 回后台补刷"样本） |
| C-07 | Preferences 节流 flush | 缓存信封/写队列落盘后延迟 500ms flush 一次 | `PreferencesStore.ets#scheduleFlush`；调用方如 `CacheEnvelopeStore.ets` L173 | 500ms 合并；`clearTimeout` 重置窗口 | 本地 | 否 | `flush` 失败记日志 | 中（已足够薄，可保留；调度器只需保证回后台排空） |
| C-08 | 网页登录 Cookie 轮询 | 每 1.5s 在 WebView 里读 `document.cookie`，拿到 uid/cid 即登录 | `LoginPage.ets#scheduleCookieCheck` L577-618（1500ms L606-615）、`stopCookiePolling` L621-627 | 1.5s；`authTriggered` 单次成功即停（L599-601）；离开页面停 | 仅登录页存活期间 | 否（只读 WebView） | 异常分支也续排（L611-616） | 低（页面局部，不建议迁） |

#### D. 网络 / 系统事件订阅

| 编号 | 触发源 | 任务 | 代码位置 | 频率 / 节流 / 去重 | 前台/后台 | 网络 | 失败处理 | 可迁移性 |
|---|---|---|---|---|---|---|---|---|
| D-01 | 网络变化（`connection`） | 仅 `bumpAppStorageVersion(KEY_NETWORK_CHANGE_VERSION)`，供图片/头像/列表等组件感知重试 | `NetworkMonitor.ets#startNetworkMonitor` L12-41：`netAvailable` L19、`netCapabilitiesChange` L23、`netLost` L27、`register` L31 | 每次系统事件；**无去抖、无业务动作** | 进程存活即注册（进程挂起后收不到） | 否 | 注册失败只 warn | **高**（"网络恢复"触发源目前是空壳，正好由调度器接管） |
| D-02 | 系统配置订阅（`onSystemConfigurationUpdated`） | 同 A-06 | `EntryAbility.ets` L115 | 系统切换时 | — | 否 | try/catch | 低 |
| D-03 | 传感器（握持状态） | `motion.on('holdingHandChanged')` → 更新 UI + 持久化设置 | `HoldingHandMonitor.ets#start` L41-56（`motion.on` L52）、`stop` L61-72；使用方 `TopicListPanel` L373 / `ThreadPanel` L468 / `WebViewPanel` L71 | 状态变化时；`smartGrip` 关闭则不注册 | 仅页面存活期间 | 否 | 注册失败记日志 | 低（UI 域） |
| D-04 | 键盘高度 / 窗口事件 | 面板避让键盘 | `FloatingLayerComponent.ets` L107、`ComposeMessageSheet.ets` L106 | 键盘弹出时 | 前台 | 否 | warn | 低 |

#### E. 用户操作触发（点按 / 下拉刷新 / 滚动 / 重试）

| 编号 | 触发源 | 任务 | 代码位置 | 备注 |
|---|---|---|---|---|
| E-01 | 下拉刷新 / 全部已读 | 强制刷新通知/动态（`force=true` 跳过 30s 节流） | `NotificationPanel.ets` L466 / L496 / L568 | 用户显式动作，**必须保持即时响应**，调度器只应"插队"而非延迟 |
| E-02 | 横幅「重试」 | 强制复验凭证 `sessionGuard.reverify()` | `CredentialBanner.ets` L206-217 → `AppStore.retryCredential` L403-405 | 与 C-04 共用同一语义 |
| E-03 | 点开跟帖 | 即时检查该帖（1min 最小间隔）、推进已读基准 | `ThreadPanel.ets` L2363 / L2386；`TrackedThreadStore` 单帖检查 | 受 `TRACK_MIN_CHECK_INTERVAL` L30 节流 |
| E-04 | 滚动停稳 | 800ms 后记录阅读进度（离开页面立即补记） | `ThreadPanel.ets#scheduleProgressRecord` L559-566；`aboutToDisappear` L474 | 纯本地节流写盘 |
| E-05 | 网络层重试 / 风控 | 首次请求失败后按域名轮换 + 指数退避重试；命中风控信号拉全局冷却闸门 | `NgaClient.ets#executeWithRetry`（acquire L219、退避重试 L241-252）、`throttledByMessage` L310-311、`ngaThrottler` `[CODE:.../Throttler.ets:L358]`、`retryDelayMs` `[CODE:.../NgaThrottleSignals.ets:L142]` | 调度器必须复用，**不得绕过** |

#### F. UI 局部定时器（**明确不迁**，仅登记以免被误判为"调度"）

| 类别 | 位置（grep 全量） | 用途 |
|---|---|---|
| 进度轮询 150ms | `TtsProgressIndicator.ets` L12/L29、`SavedThreadProgressIndicator.ets` L19、`PidLocateIndicator.ets` L13 | 页面内进度胶囊显示 |
| AI 流式刷新 30–200ms 自适应 | `AiChatPage.ets` L52-59、L996、L1034；看门狗 `OpenAiChatClient.ets` L499、`ResponsesApiClient.ets` L584 | 流式文本渲染节奏 |
| Toast / 浮层 / 长按 / 焦点 / 滚动回顶 | `ToastManager.ets` L283/L353/L360、`ToastOverlay.ets` L126、`BBCodeContentView.ets` L472/L557、`ReplyDialog.ets` L279-280/L406、`NewTopicDialog.ets` L217-218/L309、`ImageViewer.ets`、`MessageDetailPanel.ets` L117/L182、`FavoriteSavedPanel.ets` L222、`TopicListPanel.ets` L818、`ThreadPanel.ets` L892/L1038/L1061/L1137/L1333、`SearchPanel.ets` L136（300ms 防抖）、`ProfilePanel.ets` L579、`NotificationPanel.ets` L890、`MovingPhotoPlayer.ets` L379/L410、`TtsAvPlayerRenderer.ets` L517、`VideoSizeUtil.ets` L32、`TimeoutUtils.ets` L14、`FloatingLayerStore.ets` L88 | 纯 UI 行为 |
| 保存帖子分页节流 300ms | `SavedThreadService.ets` L26/L105-107、L202 | 本地归档写盘 |
| 服务端读刷新延迟（无缓存 0ms / 有缓存延迟） | `CategoryStore.ensureCategories` L66-69、`ProfileStore.ensureProfile` L106-109、`SocialListSettings.ets` L146 | 已有缓存时让出首帧 |

### 1.2 现状的结构性问题（调度器要解决的）

1. **触发源分散且各自为政**：Ability 生命周期 + 3 个 Store 内部定时器 + 页面生命周期 + 网络事件，没有任何一处能回答"当前应用有哪些定时工作在跑/下次什么时候跑"。
2. **回前台请求风暴**：`onForeground` → `setForegroundActive(true)` → `reconcilePolling` 对 3 个 participant 调 `start()`，而 `PollingController.start()` **先立即 `onPoll()` 再排下一次**（`PollingController.ets` L57-67）→ 通知 + 动态 + 跟踪（最多 50 帖）同时开跑；同一回调里还并行发起签到与 iflogin 校验。三者都走 `ngaThrottler`（按 domain 限流），会被排队，用户侧表现为"切回来一片转圈"。
3. **后台语义靠"每个定时器自己判断"**：`scheduleCredentialRecheck` 回调里显式判 `foregroundActive`（`AppStore.ets` L438-441），`PollingController` 则靠外层 `stop()`。没有统一的"后台=不跑网络"的守则，新增任务容易漏判。
4. **生命周期/账号切换的收尾不对称**：`setAuth`（L521-533）、`clearAuth`（L535-562）、`init`（L174-221）各自 `stopAllPolling`/`reconcilePolling`；`flushAll` 只在 `onBackground` 和 `clearAuthAndFlush` 调用。调度器需要提供单一 "账号代际 + 生命周期" 收尾入口。
5. **网络恢复信号是空壳**：`NetworkMonitor` 只 bump 一个版本号给 UI 组件，没有任何"恢复后补一次同步"的动作（D-01）。这是调度器**低成本高收益**的第一个新增能力。
6. **进度类轮询用 150ms 定时器**（F 类）——不影响调度器设计，但说明"定时器"在本项目里承担了大量非调度职责，迁移时必须**只挑长周期/业务型**的，不能一刀切。

---

## 2. 系统调度能力评估（API 26 / HarmonyOS 26）

> 全部签名与 `@since` 以本机 SDK 声明为准；配额/频率/审核类约束 d.ts 注释里没有，标注为 **DOC（API 23 镜像）**。
> 文档镜像根：`.dsh/skills/harmonyos-docs/guides/应用框架/Background Tasks Kit（后台任务开发服务）/`

### 2.0 能力总表

| 能力 | API 26 可用性 | 应用被杀/挂起后能否跑 | 能否访问网络 | 需要权限 / 配置 | 本应用适配度 | 结论 |
|---|---|---|---|---|---|---|
| `workScheduler` 延迟任务 | 可用（`@since 9`，API 22 新增 `earliestStartTime`） | **能**（系统拉起独立 Extension 进程） | 声明里未禁止网络（受限清单不含 net），**回调内能否用 http 待真机确认** | `extensionAbilities` 增加 `workScheduler` 类型；网络需 `INTERNET`（已有） | 低（间隔 ≥2h、2min 杀进程、拿不到 App 内存态） | **不引入** |
| `reminderAgentManager` 代理提醒 | 可用（`@since 9`） | **能**（系统代发通知） | **不能**（不执行应用代码） | `PUBLISH_AGENT_REMINDER` + 用户通知授权 + 华为开放能力审批 | 极低 | **不引入** |
| `backgroundTaskManager` 长时任务 | 可用（多类型） | **保持进程不被挂起** | 能 | `KEEP_BACKGROUND_RUNNING`（已有）+ `backgroundModes`（已声明 `audioPlayback`） | 已被 TTS 占用；挪作他用违规 | **仅保留 TTS，不扩展** |
| `backgroundTaskManager` 短时任务 | 可用（`@since 9`） | 仅延长数分钟 | 能 | 无需额外权限 | 中（仅适合"退后台前收尾"） | **暂不引入**（flushAll 已够快） |
| `commonEventManager` 动态订阅 | 可用 | **不能**（进程挂起收不到） | 能（但进程已挂起则不能） | 无 | 低 | **不用于调度** |
| `commonEventManager` 静态订阅 | **待确认**：本机 SDK 无 `StaticSubscriberExtensionAbility` 声明，仅 `ExtensionAbilityType.STATIC_SUBSCRIBER=7` | 待确认 | 待确认 | 待确认 | 低 | **不引入** |
| `appRecovery` | 可用（`@since 9`） | 崩溃/重启场景 | — | 无（`enableAppRecovery`） | 与调度无关 | **不引入** |

### 2.1 `workScheduler`（延迟任务）

**可用性与入口**
- 模块注释：面向实时性要求不高、由系统在"存储/功耗等条件合适时"统一调度的延迟任务；`@syscap SystemCapability.ResourceSchedule.WorkScheduler`、`@stagemodelonly`、`@since 9`。`[SDK:@ohos.resourceschedule.workScheduler.d.ts:L20-29]`
- 申请：`function startWork(work: WorkInfo): void`（L210）；取消：`stopWork(work, needCancel?)`（L228）；查询：`getWorkStatus`（L245 回调 / L262 Promise）、`obtainAllWorks`（L298 / L313）、`stopAndClearWorks`（L327）、`isLastWorkTimeOut`（L365 / L382）。
- 触发条件字段（`WorkInfo`）：`networkType` L81、`isCharging` L92、`chargerType` L100、`batteryLevel` L110、`batteryStatus` L118、`storageRequest` L126、`repeatCycleTime` L134、`isRepeat` L145、`repeatCount` L153、`isDeepIdle` L165、`idleWaitTime` L173、`isPersisted` L73（重启后恢复）、`parameters` L181（`Record<string, number|string|boolean>`）、`earliestStartTime` L191（`@since 22`，初始执行与申请时刻的间隔，默认 0）。枚举：`NetworkType` L391-440、`ChargingType` L449-482、`BatteryStatus` L491-516、`StorageRequest` L525-550。

**回调形式**
- `WorkSchedulerExtensionAbility`：`context: WorkSchedulerExtensionContext`（L51）、`onWorkStart(work: workScheduler.WorkInfo): void`（L60）、`onWorkStop(work: workScheduler.WorkInfo): void`（L71）。`[SDK:@ohos.WorkSchedulerExtensionAbility.d.ts]`
- `onWorkStop` 的触发条件（**关键**）："deferred task times out for **2 minutes** or `stopWork` is called"。`[SDK:@ohos.WorkSchedulerExtensionAbility.d.ts:L62-63]`
- **独立进程**：系统为 `WorkSchedulerExtensionAbility` 单独创建 Extension 进程承载回调。`[DOC:延迟任务(ArkTS):L23]`

**约束（d.ts 未写，来自文档）**
- 数量：同一时刻最多 **10 个**延迟任务。`[DOC:延迟任务(ArkTS):L28]`
- 频率（按应用活跃分组）：活跃 **2h**、经常使用 **4h**、常用 **24h**、极少使用 **48h**；受限使用/从未使用分组 **禁止**。`[DOC:延迟任务(ArkTS):L30-41]`
- 超时：单次回调最长 **2 分钟**，超时不取消则系统终止对应 Extension 进程。`[DOC:延迟任务(ArkTS):L44]`
- 调度时机：受内存、功耗、设备温度、用户使用习惯影响，资源不足时会被推迟。`[DOC:延迟任务(ArkTS):L46]`
- **回调内接口限制**：禁止调用 `backgroundTaskManager`、`backgroundManager`（旧 `@ohos.backgroundTaskManager`）、camera、audio、media。`[DOC:延迟任务(ArkTS):L48-58]`
- 权限：`startWork` 声明处**无 `@permission` 标注**（L198-210），即申请本身不要运行时权限；但需要在 `module.json5` 的 `extensionAbilities` 里声明 `type: "workScheduler"` 的扩展（`ExtensionAbilityType.WORK_SCHEDULER = 1` `[SDK:@ohos.bundle.bundleManager.d.ts:L296]`）。网络请求需要 `ohos.permission.INTERNET`（已声明 `[CODE:entry/src/main/module.json5:L17]`）。
- 应用被杀的语义：`isPersisted: true` 时任务可跨系统重启恢复（`[SDK:...workScheduler.d.ts:L64-73]`）；进程被杀后系统在条件满足时**重新拉起 Extension 进程**执行回调（`[DOC:延迟任务(ArkTS):L23]`）。

**对本应用的判断：不适合。**
1. 间隔下限 2 小时，而通知/动态轮询的业务价值本来就是"前台 5 分钟级"；放到 2h 以上等于没有。
2. 单次只有 2 分钟，且**不在主进程**：`appStore`、`SessionGuard`、`ngaThrottler`、`WriteGuard` 这些内存态与已注入依赖全部不可用，得在 Extension 里重新读 Preferences、重建鉴权与限流，等于维护第二套启动路径。
3. 回调内禁用 `backgroundTaskManager`（会影响 TTS 相关调用）与多媒体能力，排障/复用成本高。
4. 唯一可考虑的用途是"极低频维护"（草稿清理、缓存裁剪、`ToolResultCache` 落盘）——但这些全部是**本地同步 IO 毫秒级**动作，放在 `init` 后的空闲回调（现状 C-05）已足够，**为它新增一个 ExtensionAbility + 上架说明不值得**。
5. 结论：**不引入系统级延迟任务**。可作为未来"离线归档/统计上报"的候选，但需要单独立项评估。

### 2.2 `reminderAgentManager`（后台代理提醒）

**可用性/语义**
- 模块注释：应用被冻结或退出后，其"定时通知"能力由后台系统服务接管；支持倒计时、日历、闹钟三类提醒。`[SDK:@ohos.reminderAgentManager.d.ts:L24-27]`
- 关键：**它只是"代理发通知"，不执行应用代码**——到达时间点后用 Notification Kit 发一条通知（`[DOC:代理提醒(ArkTS):L61]`），因此**无法在后台完成签到**（签到必须发网络请求）。

**API**
- `publishReminder(reminderReq): Promise<number>`（L77；回调版 L56）、`cancelReminder(id)`（L109 / L94）、`cancelAllReminders`（L172）、`getValidReminders`（L150）、`updateReminder`（L192，`@since 20`）、`addNotificationSlot`（L214）。
- 请求类型：`ReminderRequest`（L571-788，公共字段 `reminderType` L578、`title` L661、`content` L675、`notificationId` L720、`slotType` L735、`wantAgent` L601、`ringDuration` L631、`snoozeTimes` L645、`timeInterval` L654）；`ReminderRequestCalendar` L797、`ReminderRequestAlarm` L845（`hour` L852 / `minute` L859 / `daysOfWeek` L867）、`ReminderRequestTimer` L877（`triggerTimeInSeconds` L886；`repeatInterval` L897 —— **最小 86400 秒（1 天）**，`@since 26`；`repeatCount` L908）。
- 权限/前置：`@permission ohos.permission.PUBLISH_AGENT_REMINDER`（L43 / L67）；必须先获得 `notificationManager.requestEnableNotification` 的通知授权（L36-40）；错误码 `1700001`（通知未开启）/`1700002`（提醒数量超限）L51-52。

**约束（文档）**
- 设备：手机/平板/PC/智慧屏/穿戴；**手机、平板、PC 有华为管控**，管控后需改用 Calendar Kit 或向华为申请"代理提醒开放能力"。`[DOC:代理提醒(ArkTS):L16-23]`
- 应用类型限制：仅工具/商务/效率/金融理财/教育/生活服务/旅游/医疗/运动健康/游戏类可申请；**场景限制**：营销类不支持，开放场景示例为生活提醒、健康提醒、学习提醒、办公提醒、游戏内任务提醒。`[DOC:代理提醒(ArkTS):L26-42]`
- 数量：单应用有效/未过期提醒 ≤ **30** 个（L48）；全系统 ≤ 12000（L49）。
- 跳转：点击通知必须跳回本应用（L56）。

**判断：不适用。** NGA 是论坛客户端，签到属"工具/生活服务"边缘场景，需要额外华为审批 + 用户通知授权，而且**它不能替我们签到**，最多提醒用户手动打开 App。收益极低、合规成本高，**不引入**。

### 2.3 `backgroundTaskManager`（长时任务 / 短时任务）

#### 2.3.1 长时任务

**API**
- 申请（4 个重载）：`startBackgroundRunning(context, bgMode: BackgroundMode, wantAgent, callback)` L699；`(context, bgMode, wantAgent): Promise<void>` L734；`(context, bgModes: string[], wantAgent): Promise<ContinuousTaskNotification>` L771（`@since 12`，返回 `continuousTaskId`）；`(context, request: ContinuousTaskRequest): Promise<ContinuousTaskNotification>` L807（`@since 21`，支持同 Ability 多任务/通知合并）。
- 取消：`stopBackgroundRunning(context)` L940；`stopBackgroundRunning(context, continuousTaskId)` L970（`@since 21`）；更新：`updateBackgroundRunning` L850 / L885；查询：`getAllContinuousTasks` L990 / L1012。
- 权限：`@permission ohos.permission.KEEP_BACKGROUND_RUNNING`（L672 / L708 / L743 / L787）。
- 监听：`on('continuousTaskCancel', cb)` L1027（`@since 15`）、`on('continuousTaskSuspend', cb)` L1063（`@since 20`）、`on('continuousTaskActive', cb)` L1093（`@since 20`）；`off` L1043 / L1078 / L1108。取消原因枚举 `ContinuousTaskCancelReason` L1488（`USER_CANCEL=1` L1495、`SYSTEM_CANCEL=2` L1502 …），暂停原因 `ContinuousTaskSuspendReason` L1716（含 `SYSTEM_SUSPEND_SYSTEM_LOAD_WARNING=12` L1782、`SYSTEM_SUSPEND_AUDIO_PLAYBACK_MUTE=16` L1815 等，多个 `@since 26.0.0`）。`ContinuousTaskNotification` L314（`notificationId` L340、`continuousTaskId?` L348）。

**类型（`BackgroundMode` L1116 / `BackgroundTaskMode` L1236）**
| 类型 | 值 | 关键约束（声明注释） |
|---|---|---|
| `DATA_TRANSFER` / `MODE_DATA_TRANSFER` | 1 / 1 | 需持续更新进度，**超过 10 分钟不更新即取消**；进度通知必须是实况窗（L1123-1128 / L1245-1249） |
| `AUDIO_PLAYBACK` / `MODE_AUDIO_PLAYBACK` | 2 / 2 | 自 API 20 起未接 AVSession 会显示通知；接 AVSession 后由 AVSession 发通知（L1139-1146 / L1260-1263）；后台无有效音频播放可能被冻结（DOC 长时任务 L80） |
| `AUDIO_RECORDING` | 3 | 系统应用不显示通知（L1158） |
| `LOCATION` / `MODE_LOCATION` | 4 | — |
| `BLUETOOTH_INTERACTION` | 5 | 蓝牙断连会被取消/暂停（DOC 长时任务 L85-90） |
| `MULTI_DEVICE_CONNECTION` | 6 | — |
| `VOIP` | 8 | — |
| `TASK_KEEPING` / `MODE_TASK_KEEPING` | 9 | 仅 PC/2in1，或非 PC 已获 ACL `KEEP_BACKGROUND_RUNNING_SYSTEM`（L1208-1216 / L1325-1332） |
| `MODE_AV_PLAYBACK_AND_RECORD` | 12 | `@since 22`（L1346） |
| `MODE_SPECIAL_SCENARIO_PROCESSING` | 13 | 仅手机/平板/PC；**必须独立使用、通知不可合并**；API 24 起需 ACL `KEEP_BACKGROUND_RUNNING_SPECIAL_SCENARIO`，API 23 及以前需 `KEEP_BACKGROUND_RUNNING_SYSTEM`（L1348-1373） |
| `MODE_NEARLINK` | 14 | `@since 26.0.0`（L1383） |

**约束（文档）**
- 仅 `UIAbility` 可申请（Stage 模型）。`[DOC:长时任务(ArkTS):L94]`
- 数量：一个 UIAbility 最多同时 **10 个**（API 21+；20 及之前只能 1 个，需多 UIAbility）。`[DOC:长时任务(ArkTS):L96-101]`
- 运行限制：**未执行业务 / 业务类型与申请不一致 / 业务已结束 / 后台负载持续过高** → 系统管控，退后台被挂起或终止；任务结束必须主动取消。`[DOC:长时任务(ArkTS):L102-118]`
- 通知栏常驻：申请成功后通知栏显示消息，**用户删除通知即自动停止长时任务**。`[DOC:长时任务(ArkTS):L13]`
- 需要 `KEEP_BACKGROUND_RUNNING` 权限 + `module.json5` 的 `backgroundModes` 声明。`[DOC:长时任务(ArkTS):L147-158]`
- 上架/功耗要求：仅允许原定用途、用户可主动开始/停止、执行期间用户可感知，且**原定用途需在应用市场"应用功能介绍"中说明**。`[DOC:guides/应用体验建议/应用功耗体验建议/后台场景/后台任务使用:13-20]`

**本应用现状**
- 已声明 `ohos.permission.KEEP_BACKGROUND_RUNNING`（`[CODE:entry/src/main/module.json5:L26]`）与 `backgroundModes: ["audioPlayback"]`（L51-53）。
- 已实现：`TtsBackgroundTaskController`（`initialize` L101 注册 3 个监听 L113-115；`activate` L190-225 调 `startBackgroundRunning(context, ['audioPlayback'], agent)` L213-214；`deactivate` L230-256；`shutdown` L144-158），由 `TtsPlayer.initialize` L184 注入、播报开始时 `start()`（`TtsPlayer.ets` L759）、多处停止（L731/L855/L969/L986/L1026/L1031/L1104/L1254）。
- **结论：长时任务只应为 TTS 音频播放保留，不得挪用**。把 `audioPlayback` 用于数据刷新会被系统一致性校验判定"业务类型不符"并挂起（`[DOC:长时任务(ArkTS):L105-111]`），同时违反上架"原定用途"要求。

#### 2.3.2 短时任务

- `requestSuspendDelay(reason, callback): DelaySuspendInfo` L650；系统会在超时前**约 6 秒**回调通知（L635-636）；`cancelSuspendDelay(requestId)` L586；`getRemainingDelayTime` L606 / L625；`getTransientTaskInfo()` L663（`@since 20`，返回 `remainingQuota` L298）。
- `DelaySuspendInfo.actualDelayTime`：正常情况下单次上限 **3 分钟**，低电量（`BatteryCapacityLevel=LEVEL_LOW`）降为 **1 分钟**。`[SDK:@ohos.resourceschedule.backgroundTaskManager.d.ts:L275-282]`
- 约束（文档）：必须在前台或 `onBackground` 回调内申请，否则失败（L16）；同一时刻最多 3 个（L18）；单日配额默认 10 分钟、低电单次 1 分钟（L20）；仅后台时段计时（L22）；任务完成必须主动取消，否则影响当日剩余配额（L28）；超时不取消 → 挂起/终止（L30）。`[DOC:短时任务(ArkTS)]`
- **判断：暂不需要。** 它适合"退后台后必须在几秒内完成的一次性收尾"（如保存状态、发送最后一条消息）。本应用 `onBackground` 的收尾是 `flushAll()`（本地队列排空 + preferences flush），秒级完成，没有必要申请短时任务。若未来出现"退出前必须上传草稿/保存帖子"的需求，可把它作为 onBackground 内的兜底手段。

### 2.4 `commonEventManager`（公共事件）

- API：`publish` L94/L112、`createSubscriber` L128/L141、`createSubscriberSync` L153、`subscribe` L170、`subscribeToEvent` L187、`unsubscribe` L205。`[SDK:@ohos.commonEventManager.d.ts]`
- 订阅信息：`CommonEventSubscribeInfo.events` L47、`publisherPermission` L58、`userId` L81、`priority` L92、`publisherBundleName` L103。`[SDK:commonEvent/commonEventSubscribeInfo.d.ts]`
- 可用事件：`Support` 枚举（L214 起）包含 `COMMON_EVENT_BOOT_COMPLETED` L227、`BATTERY_LOW` L270、`POWER_CONNECTED` L290、`SCREEN_ON` L320、`USER_PRESENT` L379、`TIME_TICK` L389、`TIMEZONE_CHANGED` L414 等。
- 语义限制：系统公共事件**当前仅支持系统应用和系统服务发布**（`[DOC:公共事件简介:L16]`）；动态订阅要求进程存活，**进程被挂起后无法使用公共事件、定时器等软件资源**（`[DOC:Background Tasks Kit简介:L11]`）；进程内动态订阅者建议不超过 200 个（`[DOC:动态订阅公共事件:L17]`）。
- 静态订阅：`ExtensionAbilityType.STATIC_SUBSCRIBER = 7` 存在（`[SDK:@ohos.bundle.bundleManager.d.ts:L345]`），但本机 SDK 的 `ets/api` 全目录 grep 不到 `StaticSubscriberExtensionAbility` 声明 → **待确认**（见 §4.2）。
- **判断：不适合做调度。** 若需要"应用前后台"信号，优先用 `ApplicationContext.on('applicationStateChange')`（`[SDK:application/ApplicationContext.d.ts:L194]`，回调 `onApplicationForeground` L48 / `onApplicationBackground` L60，注意 `onApplicationForeground` 是"即将进入前台"，此时不能执行依赖前台状态的操作 L37-40）；需要"网络恢复"信号则用已接入的 `connection` 事件（`NetworkMonitor.ets` L19-27）。

### 2.5 `appRecovery`（应用恢复）

- 模块定位：故障应用恢复（`@syscap SystemCapability.Ability.AbilityRuntime.Core`，`@since 9`）。`[SDK:@ohos.app.ability.appRecovery.d.ts:L21-28]`
- API：`enableAppRecovery(restart?, saveOccasion?, saveMode?)` L148；`restartApp()` L173（两次重启间隔须 **> 1 分钟**，L164-166）；`setRestartWant(want)` L184；`saveAppState()` L195 / `saveAppState(context)` L207。
- 枚举：`RestartFlag` L37（`ALWAYS_RESTART=0` L45、`RESTART_WHEN_JS_CRASH=0x0001` L53、`RESTART_WHEN_APP_FREEZE=0x0002` L61、`NO_RESTART=0xFFFF` L69、`RESTART_WHEN_CPP_CRASH=0x0004` L78 `@since 24`）；`SaveOccasionFlag` L88（`SAVE_WHEN_ERROR` / `SAVE_WHEN_BACKGROUND`）；`SaveModeFlag` L114（`SAVE_WITH_FILE` / `SAVE_WITH_SHARED_MEMORY`）。
- **判断：与调度器无关**（是崩溃恢复，不是"按时/按条件执行任务"）。可作为独立议题：若未来希望进程崩溃后恢复页面栈/状态，再评估 `enableAppRecovery` + `onSaveState`（`[SDK:@ohos.app.ability.UIAbility.d.ts:L616/L635]`）。

### 2.6 可观测性 API（调度器触发源可用的"条件信号"）

| 信号 | API（本机 SDK 26） | 说明 |
|---|---|---|
| 应用前后台 | `ApplicationContext.on('applicationStateChange')` L194 / `off` L214；`ApplicationStateChangeCallback.onApplicationForeground` L48 / `onApplicationBackground` L60 | 比 UIAbility 回调更贴近"进程级"；`@since 10` |
| 屏幕/电源 | `power.isActive()` L72、`power.getPowerMode()` L80、`power.isStandby()` L90；`DevicePowerMode` L97（`MODE_NORMAL=600` L104、`MODE_POWER_SAVE` L111、`MODE_PERFORMANCE` L118、`MODE_EXTREME_POWER_SAVE` L125、`MODE_CUSTOM_POWER_SAVE=650` L132）`[SDK:@ohos.power.d.ts]` | 省电模式/待机可做"降频"条件 |
| 电池 | `batteryInfo.batterySOC` L35、`chargingStatus` L43、`batteryCapacityLevel` L95；`BatteryChargeState` L146（NONE/ENABLE/DISABLE/FULL）、`BatteryCapacityLevel` L236 `[SDK:@ohos.batteryInfo.d.ts]` | 低电量可暂停轮询；`BatteryCapacityLevel.LEVEL_LOW` 也是短时任务配额的判据 |
| 网络 | `connection.createNetConnection()` + `on('netAvailable'/'netCapabilitiesChange'/'netLost')`（`[CODE:NetworkMonitor.ets:L18-30]`） | 已有实现，只需接业务动作 |
| 设备待机 / 使用统计 | `deviceStandby`（空 namespace，注释明确"这些接口是系统 API" L25-33）、`usageStatistics`（空 namespace L19-32） | **第三方不可用**，不要规划依赖它们 |

### 2.7 明确不作为调度能力的东西

- 后台定时器本身：应用退后台几秒后进程被挂起，**定时器随之停摆**（`[DOC:Background Tasks Kit简介:L11]`；`[DOC:应用后台运行:L44-52]` 表格"无后台/短时任务/长时任务/延迟任务/代理提醒"的后台状态）。
- `backgroundProcessManager`、`bundleState` 等：面向系统/受限能力，本阶段不评估。
- 推送：本应用无 Push 通道（业务事实），因此"后台被动唤醒拉数据"这条常见路径不存在。

---

## 3. 调度器设计输入

### 3.1 触发源枚举与语义（建议）

| 触发源 | 来源 API | 语义与要求 | 备注 |
|---|---|---|---|
| `APP_START` | `EntryAbility.onCreate` → `AppStore.init` 完成 | **每次进程生命周期仅一次**；必须晚于 init 完成（`initializationFinished`） | 现有 A-01 + B-01 的启动校验/签到要挂这里 |
| `APP_FOREGROUND` | `EntryAbility.onForeground` 或 `ApplicationContext.on('applicationStateChange')` | 每次回前台；需附带 `awayDurationMs`（本次离开时长），供任务自行决定是否 catch-up | 可从 `onBackground` 记录时间戳计算；替代 `verifyOnForeground` 的"时间差判断" |
| `APP_BACKGROUND` | `EntryAbility.onBackground` | 只做"收尾"（flush/停定时器/记录时间），**禁止发网络** | 与 `ApplicationContext.onApplicationBackground`（已完全在后台）二选一或都接，需去重 |
| `NETWORK_RESTORED` | `connection.on('netAvailable')` | 去抖（建议 ≥ 1s，聚合 netAvailable + netCapabilitiesChange）后触发；仅当前台时执行 | 当前 D-01 是空壳，**收益最大** |
| `AUTH_CHANGED` | `AppStore.setAuth` L521 / `clearAuth` L535 | 参数含 `generation`；所有在途任务必须按 generation 作废 | 现有 `clearRefreshState`/`generationGuard` 已具备 |
| `PAGE_ENTER` / `PAGE_EXIT` | 页面 `aboutToAppear` / `aboutToDisappear` | **可选**：只承载"页面相关的按需刷新"，不强求统一 | 不建议把页面刷新迁进全局调度器 |
| `IDLE` | 启动后延迟（如 800ms）、或下一次 tick 空档 | 低优先级维护任务（草稿清理、缓存裁剪、写盘合并） | 现有 C-05/C-06 的天然归类 |
| `TIMER_TICK` | 调度器内部单一定时器 | 前台每 N 秒 tick，驱动所有"间隔到期"的任务；**后台不 tick** | 取代各 Store 自持 `setTimeout` 链 |
| `POWER_STATE_CHANGED`（可选） | `power.getPowerMode()` / `batteryInfo.chargingStatus` 轮询（前台低频） | 省电/低电量时降低轮询频率或暂停非必要任务 | 需评估是否值得，**P2** |

**不建议的触发源**：屏幕亮灭（`power.isActive` 轮询成本高于收益）、`TIME_TICK` 公共事件（进程挂起后无效）、系统启动完成（静态订阅不可用/待确认）。

### 3.2 公共契约（建议固化）

1. **任务标识**：`key: string`（如 `poll.notification`、`auth.verify.foreground`、`maintenance.draftCleanup`），全局唯一；同一 key 在途时新触发 **复用**（single-flight）。
2. **触发声明**：`triggers: TriggerSource[]`（任务可响应哪些触发源）、`minIntervalMs`（最小成功间隔）、`timeoutMs`、`requiresNetwork: boolean`、`requiresForeground: boolean`、`priority: number`。
3. **单飞（single-flight）**：同 key 在途复用同一 Promise（现成样本：`SessionGuard.verifyDetailed` L385-398、`BaseStore.runGuardedRefresh` L91-93）。
4. **去重 / 节流**：成功后才更新"上次成功时间"（现成样本 `runGuardedRefresh` L106-109 只在 `ok` 时更新 L107-108）；`force` 语义只给用户显式动作（下拉刷新、横幅重试）。
5. **退避**：有界、档位化（现成样本 `CREDENTIAL_RECHECK_DELAYS_MS = [3s,15s,30s,60s]` L97），成功即重置档位；**失败不得清零重排**（`scheduleCredentialRecheck` 的幂等早退 L428 正是为此）。
6. **超时**：每个异步校验必须带超时且超时归为"未知/不改变状态"（现成样本 `SessionGuard.withTimeout` L501-533，`VERIFY_TIMEOUT_MS = 5000` L45）。
7. **结果有效性**：任务回写前校验 `generation + uid + token`（现成样本 `BaseStore.isRequestCurrent` L126-131；`AppStore` 的 `AuthScope` 用法见 `CheckinSettings.autoCheckinIfNeeded` L34-40）。
8. **网络冷却联动**：执行任何 NGA 请求前检查 `ngaThrottler.isCoolingDown()`，冷却中直接跳过（现成样本 `ToolRegistry.ets` L349-353、`NgaClient.ets` L648-664）；调度器不得绕过 `ngaThrottler`/`executeWithRetry`。
9. **后台门禁**：`requiresNetwork && !foregroundActive` → 任务不执行，标记 dirty，回前台补跑（catch-up）。
10. **幂等**：所有任务必须可安全重放（同一数据被刷新两次不出错）；写类任务必须显式标注，且默认**不从调度器主动发起**。

### 3.3 任务与 Store 的解耦方式

建议分三层，**不要让调度器 import 任何具体 Store**：

```
Scheduler（纯编排）
  ├─ TriggerBus：把系统信号归一化为 Trigger 事件（Ability/页面/网络/电源…）
  ├─ Registry：ScheduledTask 声明表（key/triggers/minInterval/timeout/priority/executor）
  └─ Clock + Logger + NetworkGate（注入，便于测试）
        │
        ▼
TaskExecutors（每类工作一个薄封装）
  · PollNotificationTask  → 只调用 refreshNotifications(false)（现有 store 方法）
  · PollFollowActivityTask
  · PollTrackedThreadTask （自带轮次间隔与上限）
  · VerifySessionTask    → sessionGuard.verifyOnForeground()
  · CheckinTask          → settingsStore.autoCheckinIfNeeded()
  · CredentialRecheckTask→ 可由任务自身决定是否再排（或调度器统一"失败退避"）
  · MaintenanceTask      → draftStore/media 清理、aiToolCacheStore.flush
```

- **注册点在 `AppStore`**：`AppStore` 已持有全部 store 引用并负责账号生命周期（`init` L174、`setAuth` L521、`clearAuth` L535），把 `pollingParticipants`（L115-138）扩展为 `ScheduledTask[]` 是改动最小的落点。
- **Store 不感知调度器**：Store 只暴露 `refresh / flush / cleanup` 这类幂等方法；"何时跑"完全由 Registry 决定。现有 `startPolling/stopPolling` 这类启停方法可以保留为兼容层，内部转为注册/注销任务。
- **页面触发保持现状**：页面 `aboutToAppear` 直接调 store（如 `TopicListPanel` L371）属于"用户语义"，迁进调度器只会让行为更难推理。

### 3.4 失败与重试策略

| 失败类型 | 处理 | 依据 |
|---|---|---|
| 网络异常 / 超时 | 有界退避（3s/15s/30s/60s 档位）；UNKNOWN 不改变业务状态 | `SessionGuard.onUnauthorizedSignal` L312-356、`AppStore.scheduleCredentialRecheck` L427-453 |
| 会话 INVALID | 只标记降级，不清态；写操作由 `setWriteGuard` 拦（`AppStore.bindSessionGuard` L313-331） | 现有设计 |
| 风控 / 限流 | 全局冷却闸门，冷却期内所有 NGA 请求快速失败；调度器跳过并在冷却结束后补一次 | `NgaClient.ets` L310-311/L648-664；`Throttler.enterCooldown` |
| 解析失败 / 数据异常 | 记录 count、保持旧缓存（如 `NotificationStore.performRefresh` L172-178） | 现有 store |
| 本地 IO 失败 | 只 warn，不阻断后续调度（`initDraftCleanup` L263-269） | 现有实现 |
| 定时器被挂起 | **不做"重启定时器"假设**：回前台重新评估"上次成功时间 + 间隔"决定是否补跑 | 依赖 `lastSuccessAt` 而非 `setTimeout` 存活 |

### 3.5 防止后台耗电的守则（建议写成 code review 检查项）

1. **后台不发网络、不跑业务定时器**：回后台只做 flush + 停 tick；唯一的后台动作是本地收尾。
2. **不申请**长时任务/延迟任务/代理提醒/短时任务来承载数据刷新（TTS 音频播放除外）。
3. **前台轮询间隔只增不减**：现网 300s（通知/动态）/600s（跟踪）是"被服务端风控逼出来的"结果（见 `NotificationStore.ets` L38-39 注释、`FollowActivityStore.ets` L41-42），调度器必须保持或更保守。
4. **单 tick 预算**：一次 `TIMER_TICK` 内最多执行 K 个任务（如 1~2 个），其余顺延；避免回前台/网络恢复时多任务齐发。
5. **全局请求速率**：任何新触发源都不得绕过 `ngaThrottler`（token-bucket：并发、最小间隔、滑动窗口三重约束，`Throttler.ets` L2-20）。
6. **跟踪任务特别处理**：50 帖 × 400ms 的一轮本身就是 20 秒窗口，回前台不应"立刻"跑整轮；建议按"上次检查时间"分片，或与通知/动态错峰。
7. **省电模式/低电量降频**（可选）：`power.getPowerMode()==MODE_POWER_SAVE/EXTREME_POWER_SAVE` 或 `batteryCapacityLevel==LEVEL_LOW` 时暂停非关键轮询；仅在**前台低频采样**，不注册后台监听（无相应能力）。
8. **可观测性**：调度器应能导出"当前任务表 + 下次计划时间 + 最近失败原因"，供日志/调试面板使用（现网排障靠 grep `Logger`，成本高）。

### 3.6 可测试性（纯逻辑 + 注入时钟）

- **注入 Clock**：`interface Clock { now(): number; setTimeout(fn, ms): number; clearTimeout(id): void }`，生产实现走全局 `setTimeout`，测试实现可手动推进（现有 `SessionGuard.bindTimeoutMs` L183-187 / `bindConfirmDelayMs` L194-198 已是"注入可调参数"的先例，见 `SessionGuard` 注释"仅供单元测试注入"）。
- **注入网络层**：`CheckFn`（`SessionGuard` L80/L174-176）式的函数注入，比 mock 模块更贴合 ArkTS 限制。
- **Decider / Executor 分离**：`decide(now, trigger, taskState) -> Action`（纯函数，可穷举测试）+ `execute(action)`（副作用）。这样"回前台是否补跑""退避档位""去重窗口"都能脱离定时器测试。
- **测试入口**：`entry/src/test`（Hypium Local Test，见项目 `harmonyos-test` skill）。注意 ArkTS 子集限制：不支持函数表达式/解构/`any`，接口 + 类实现，时间参数显式传入。

### 3.7 迁移优先级（建议）

| 阶段 | 内容 | 风险 | 收益 |
|---|---|---|---|
| **P0** | 把 `AppStore.pollingParticipants`（L115-138）与 `PollingController` 收编为调度器任务表；**保持间隔/节流语义完全不变**，仅换编排层 | 低 | 获得统一任务视图；后续改动有落点 |
| **P1** | 回前台计划化：签到 / 会话校验 / 三路轮询按优先级与错峰执行，消除"回前台请求风暴" | 中（行为变化可见） | 首屏/切回体验、风控风险下降 |
| **P2** | 凭证退避探针、草稿启动清理、AI 缓存节流写盘注册为任务；统一 flush 收尾契约 | 低 | 删除三处自持定时器，语义不丢 |
| **P3** | 网络恢复触发第一次"补同步"（去抖 + 仅前台） | 低 | 断网恢复后红点/列表自动更新 |
| **P4**（可选） | 低电量/省电模式降频 | 低 | 功耗口碑 |
| 不做 | 页面级 `aboutToAppear` 拉取、150ms 进度轮询、Toast/动画/防抖定时器 | — | 避免过度抽象 |

---

## 4. 风险与未决问题

### 4.1 风险清单

| 编号 | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R-1 | **后台定时器被系统挂起的语义被误用**：进程退后台几秒后挂起，定时器停摆（`[DOC:Background Tasks Kit简介:L11]`、`[DOC:应用后台运行:L44-52]`） | 若把"周期性同步"放在 `setTimeout` 链上并假设后台也会跑，会出现"回来发现数据是旧的/定时器早已丢失" | 调度器以"上次成功时间 + 间隔"为准做 catch-up，不依赖定时器存活；后台显式停 tick |
| R-2 | **误用长时任务承载数据刷新** | 系统一致性校验失败 → 后台被挂起；上架审核风险（原定用途需申报） | 长时任务白名单只允许 TTS `audioPlayback`；code review 检查 `startBackgroundRunning` 调用点 |
| R-3 | **`KEEP_BACKGROUND_RUNNING` 已声明但被误以为"可后台任意跑"** | 声明了权限 ≠ 可长期后台运行；仍受业务类型校验 | 在 `TtsBackgroundTaskController` 文件头补一句"仅 TTS 使用，勿挪用"（P2 可做） |
| R-4 | **workScheduler 若引入会带来第二套进程/鉴权路径** | Extension 进程无 `appStore`/`SessionGuard`/`ngaThrottler`；重复实现易出安全问题（token 落盘、并发写） | 结论是不引入；若将来必须引入，先在 Extension 内做最小只读动作（如清理本地文件） |
| R-5 | **回前台/网络恢复时的请求突发** | 触发风控冷却（`NgaClient` 已识别），用户侧表现为大面积失败 | 调度器全局预算 + 错峰 + 冷却联动 |
| R-6 | **账号切换/退出与在途任务竞争** | 旧账号数据回写到新账号（安全问题） | 统一 `generation/uid/token` 校验；`AuthScope` 现成模式（`CheckinSettings` L34-40、`BaseStore.isRequestCurrent`） |
| R-7 | **`onNewWant` 未处理 / `launchType` 未声明** | 二次拉起（如从通知/桌面再次进入）时"启动完成"触发源语义不清（`init` 不会重跑） | 明确调度器的 `APP_START` 只对应进程冷启动；二次拉起走 `APP_FOREGROUND`；`launchType` 需确认（见 §4.2） |
| R-8 | **页面轮询与全局调度双份数据源** | 同一 store 被页面和调度器同时刷新，节流能兜住但语义混乱 | 调度器只管"业务型长周期"任务；页面触发保持直连 store |
| R-9 | **150ms 进度轮询被误迁** | 迁移后延迟增大、进度条卡顿 | 明确 F 类不进调度器 |
| R-10 | **测试可覆盖性不足** | 定时逻辑只能靠真机手测 | 时钟/网络注入 + Decider 纯函数化（§3.6） |

### 4.2 待确认问题（需真机/文档/华为侧确认）

1. **`workScheduler` 在 WorkSchedulerExtensionAbility 内能否发 HTTPS 请求**：文档给的"接口调用限制"清单只列了 `backgroundTaskManager`/camera/audio/media（`[DOC:延迟任务(ArkTS):L48-58]`），未列网络；但"能否在 Extension 进程内使用 `@ohos.net.http`、是否需要额外权限、是否受后台流量限制"**声明与文档均未明确** → **待真机确认**。即使可用，频率下限 2h 已决定其不适合本应用。
2. **HarmonyOS 26（API 26）上 `workScheduler` 的频率分组档位**是否仍为文档（API 23）中的 2h/4h/24h/48h，是否新增配额 → **待确认**（本机 d.ts 未写）。
3. **静态订阅公共事件是否仍对三方开放**：本机 SDK 26 的 `ets/api` 全目录找不到 `StaticSubscriberExtensionAbility` 声明（只有 `ExtensionAbilityType.STATIC_SUBSCRIBER=7`）→ **待确认**该能力是否已从 ArkTS 声明面移除/改名。
4. **`onNewWant` 与 `launchType`**：`module.json5` 未声明 `launchType`（默认值需查 SDK 配置 schema），`EntryAbility` 未覆写 `onNewWant` → 二次拉起时 `onCreate`/`init` 不会重跑，调度器的"启动完成"语义必须明确。
5. **`verifyOnForeground` 的 10 分钟节流与"离开时长"配合**：现在用 `lastVerifyAt` 绝对时间判断（`SessionGuard.ets` L364-367）。若改为"回前台 + 离开时长 ≥ N 分钟才校验"，需要产品/风控侧确认阈值（当前 10min 是经验值）。
6. **应用市场对"后台任务类型/原定用途"的具体审核口径**：长时任务需在应用介绍中说明原定用途（`[DOC:后台任务使用:L20]`）；TTS 播报是否已在应用介绍中申报，**待运营确认**。
7. **`deviceStandby` / `usageStatistics` 是否有三方可用替代**：本机 SDK 为空 namespace（系统 API），第三方无可用的"设备待机/应用分组"查询入口 → 调度器不能依赖"省电模式"以外的系统信号；`power.getPowerMode()` 是否在模拟器/真机都可用，**待真机验证**。
8. **`PollingController` 的"启动即执行"是否需要保留**：现状 `start()` 立即 `onPoll()`（L57-67）。若调度器统一为"回前台时按计划延迟执行"，会改变用户可感知的行为（切回来立刻有数据 vs 稍后刷新），需产品确认。

---

## 附录 A：SDK 事实索引（本机 SDK，API 26）

> 根目录：`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\`

| 事实 | 位置 |
|---|---|
| `startWork(work: WorkInfo): void`（无 @permission；@since 9；@stagemodelonly） | `api/@ohos.resourceschedule.workScheduler.d.ts:L198-210` |
| `WorkInfo` 触发条件字段（networkType/battery/charging/storage/repeat/idle/parameters/earliestStartTime） | 同上 L38-192 |
| `stopWork` / `getWorkStatus` / `obtainAllWorks` / `stopAndClearWorks` / `isLastWorkTimeOut` | 同上 L228 / L245,L262 / L298,L313 / L327 / L365,L382 |
| `NetworkType` / `ChargingType` / `BatteryStatus` / `StorageRequest` 枚举 | 同上 L391-440 / L449-482 / L491-516 / L525-550 |
| `WorkSchedulerExtensionAbility.onWorkStart` / `onWorkStop`；onWorkStop 由 2 分钟超时或 stopWork 触发 | `api/@ohos.WorkSchedulerExtensionAbility.d.ts:L60` / `L71`；超时语义 L62-63 |
| `publishReminder`（@permission PUBLISH_AGENT_REMINDER） | `api/@ohos.reminderAgentManager.d.ts:L43,L56` / L67,L77 |
| `ReminderRequestTimer.triggerTimeInSeconds`；`repeatInterval` ≥ 86400s（@since 26） | 同上 L886 / L897 |
| `ReminderRequestAlarm.hour/minute/daysOfWeek`；`ReminderRequestCalendar` | 同上 L845-868 / L797 |
| 代理提醒模块语义：应用冻结/退出后由系统服务接管"定时通知" | 同上 L24-27 |
| `startBackgroundRunning` 四个重载（均需 KEEP_BACKGROUND_RUNNING） | `api/@ohos.resourceschedule.backgroundTaskManager.d.ts:L699` / `L734` / `L771` / `L807`；权限标注 L672/L708/L743/L787 |
| `BackgroundMode` 枚举（DATA_TRANSFER..TASK_KEEPING）与注释约束 | 同上 L1116-1217 |
| `BackgroundTaskMode` 枚举（MODE_*，含 SPECIAL_SCENARIO / NEARLINK） | 同上 L1236-1384 |
| `on('continuousTaskCancel'/'continuousTaskSuspend'/'continuousTaskActive')` | 同上 L1027 / L1063 / L1093 |
| `ContinuousTaskCancelReason` / `ContinuousTaskSuspendReason` | 同上 L1488-1574 / L1716-1840 |
| `requestSuspendDelay`（超时前约 6s 回调）/ `cancelSuspendDelay` / `getRemainingDelayTime` / `getTransientTaskInfo` | 同上 L650 / L586 / L606,L625 / L663 |
| 短时任务单次上限 3 分钟、低电 1 分钟 | 同上 L275-282（`DelaySuspendInfo.actualDelayTime`） |
| `commonEventManager.publish/subscribe/createSubscriber/unsubscribe` | `api/@ohos.commonEventManager.d.ts:L94,L112 / L170 / L128,L141,L153 / L205` |
| `CommonEventSubscribeInfo` 字段 | `api/commonEvent/commonEventSubscribeInfo.d.ts:L38-104` |
| `ExtensionAbilityType.WORK_SCHEDULER=1` / `STATIC_SUBSCRIBER=7` | `api/@ohos.bundle.bundleManager.d.ts:L296 / L345` |
| `appRecovery.enableAppRecovery/restartApp/setRestartWant/saveAppState` | `api/@ohos.app.ability.appRecovery.d.ts:L148 / L173 / L184 / L195,L207` |
| `UIAbility` 生命周期（onCreate/onWindowStageCreate/onForeground/onBackground/onDestroy/onNewWant/onSaveState） | `api/@ohos.app.ability.UIAbility.d.ts:L372 / L384 / L465 / L508 / L451 / L578 / L616` |
| `ApplicationContext.on('applicationStateChange')` 及回调 | `api/application/ApplicationContext.d.ts:L194,L214`；`api/@ohos.app.ability.ApplicationStateChangeCallback.d.ts:L48,L60` |
| `power.isActive/getPowerMode/isStandby`；`DevicePowerMode` | `api/@ohos.power.d.ts:L72 / L80 / L90 / L97-133` |
| `batteryInfo.batterySOC/chargingStatus/batteryCapacityLevel` | `api/@ohos.batteryInfo.d.ts:L35 / L43 / L95`；枚举 L146/L236 |
| `deviceStandby` / `usageStatistics` 为空 namespace（系统 API，三方不可用） | `api/@ohos.resourceschedule.deviceStandby.d.ts:L25-33`；`api/@ohos.resourceschedule.usageStatistics.d.ts:L19-32` |
| `BackgroundTasksKit` 导出面（workScheduler/WorkSchedulerExtensionAbility/backgroundTaskManager/reminderAgentManager/deviceStandby/usageStatistics…） | `kits/@kit.BackgroundTasksKit.d.ts:L19-28` |

## 附录 B：文档镜像索引（API 23）

> 根目录：`C:\Users\ll\Desktop\nga_oh\.dsh\skills\harmonyos-docs\`

| 事实 | 位置 |
|---|---|
| 延迟任务：最多 10 个、活跃分组 2h/4h/24h/48h、单次回调 2min、回调内接口限制、独立 Extension 进程 | `guides/应用框架/Background Tasks Kit（后台任务开发服务）/延迟任务(ArkTS)/延迟任务(ArkTS).md` L23-58 |
| 短时任务：前台或 onBackground 申请、最多 3 个、日配额 10min、低电 1min、超时管控 | `.../短时任务(ArkTS)/短时任务(ArkTS).md` L16-30 |
| 长时任务：仅 UIAbility、最多 10 个、业务一致性校验、及时取消、通知常驻 | `.../长时任务(ArkTS)/长时任务(ArkTS).md` L13 / L92-118 / L147-158 |
| 代理提醒：设备/管控/应用类型/场景限制、30 个上限、跳转限制、通知授权 | `.../代理提醒(ArkTS)/代理提醒(ArkTS).md` L13-56 / L113-117 |
| 后台进程挂起后"无法使用公共事件、定时器等软件资源" | `guides/应用框架/Background Tasks Kit（后台任务开发服务）/Background Tasks Kit简介/Background Tasks Kit简介.md` L11 |
| 各类后台任务的"退至后台状态"对比（无后台=几秒后挂起） | `best/功耗/应用功耗优化/后台任务低功耗/应用后台运行/应用后台运行.md` L30-98 |
| 功耗/上架体验要求（长时任务原定用途需申报、定时类任务应用代理提醒、延迟任务<2min） | `guides/应用体验建议/应用功耗体验建议/后台场景/后台任务使用/后台任务使用.md` L9-102 |
| 系统公共事件仅系统应用/系统服务发布；粘性事件仅系统应用 | `guides/系统/基础功能/Basic Services Kit（基础服务）/进程线程通信/使用公共事件进行进程间通信/公共事件简介/公共事件简介.md` L11-24 |
| 动态订阅者建议 ≤200 | `.../动态订阅公共事件/动态订阅公共事件.md` L17 |

## 附录 C：代码索引（现有触发点）

> 路径相对 `entry/src/main/ets/`。行号为本次采样快照（read/grep 行号一致）；仓库存在并行改动时以**方法名**为准，`PreferencesStore.ets` 已知正在被其他改造修改。

- Ability：`entryability/EntryAbility.ets#onCreate` L92、`#onWindowStageCreate` L159、`#onForeground` L252、`#onBackground` L266、`#onDestroy` L147、`#sysConfigUpdatedCallback` L79。
- 编排：`store/AppStore.ets#init` L174、`#initDraftCleanup` L245、`#scheduleCredentialRecheck` L427、`#resetCredentialState` L464、`#flushAll` L508、`#setAuth` L521、`#clearAuth` L535、`#autoCheckinIfNeeded` L587、`#setForegroundActive` L643、`#reconcilePolling` L653、`#startAllPolling` L666、`#stopAllPolling` L673；`PollingParticipant` L55；常量 `DRAFT_CLEANUP_DELAY_MS` L72 / `CREDENTIAL_RECHECK_DELAYS_MS` L97。
- 轮询骨架：`common/concurrency/PollingController.ets#shouldEnablePolling` L22、`#start` L57、`#stop` L72、`#scheduleNext` L83。
- 三路轮询：`store/NotificationStore.ets` L36/L39/L71/L117/L144；`store/FollowActivityStore.ets` L39/L42/L90/L142；`store/TrackedThreadStore.ets` L53/L123/L173；`model/TrackedThread.ets` L19/L22/L30/L33。
- 会话：`store/SessionGuard.ets` 常量 L42/L45/L48/L56/L64，`#verify` L262、`#verifyIfStale` L278、`#reverify` L295、`#onUnauthorizedSignal` L312、`#verifyOnForeground` L364、`#verifyDetailed` L385、`#verifyNow` L409、`#withTimeout` L501、`#resetForNewSession` L243。
- 签到：`store/settings/domain/CheckinSettings.ets#autoCheckinIfNeeded` L25-50；`store/SettingsStore.ets#autoCheckinIfNeeded` L291。
- 网络：`common/managers/NetworkMonitor.ets#startNetworkMonitor` L12-41；`common/concurrency/Throttler.ets` L2-20/L358；`service/NgaClient.ets` L142-263/L310-311/L648-664；`service/api/NgaThrottleSignals.ets#retryDelayMs` L142。
- 缓存/写盘：`store/AiToolCacheStore.ets` L48/L85/L123/L159/L170；`store/BaseStore.ets#runGuardedRefresh` L83-116、`#isRequestCurrent` L126-131；`common/infra/PreferencesStore.ets#scheduleFlush`（行号以当前工作区为准：该文件正由并行的"持久化统一"改造修改）；`service/ai/tools/ToolResultCache.ets#toolCacheTtlMs` L68-91。
- 草稿：`common/managers/DraftStore.ets` L50/L517；`common/media/DraftMediaStore.ets` L69/L348。
- 后台任务：`common/media/TtsBackgroundTaskController.ets#initialize` L101-120、`#start` L127、`#activate` L190-225、`#deactivate` L230-256、`#shutdown` L144-158；`common/media/TtsPlayer.ets#initialize` L181-185、后台任务 start L759、stop 调用 L731/L855/L969/L986/L1026/L1031/L1104/L1254。
- 页面：`pages/Index.ets#aboutToAppear` L25、`#waitAndRoute` L31-72；`pages/MainPage.ets#aboutToAppear` L131、`#checkAuth` L658-690、`#aboutToDisappear` L139；`pages/TopicListPanel.ets#aboutToAppear` L363；`pages/NotificationPanel.ets#aboutToAppear` L186；`pages/ThreadPanel.ets#aboutToAppear` L446、`#scheduleProgressRecord` L559；`pages/CommunityPanel.ets#aboutToAppear` L31；`pages/LoginPage.ets#scheduleCookieCheck` L577-618。
- 其它：`common/managers/ScreenOnManager.ets#enableKeepScreenOn` L31；`common/managers/HoldingHandMonitor.ets#start` L41；`common/infra/PageLifecycle.ets`（页面就绪标志）；`common/feedback/ToastManager.ets` L283/L353/L360。
