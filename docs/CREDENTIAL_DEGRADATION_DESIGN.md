# 凭证降级机制设计

> 适用范围：`store/SessionGuard.ets`、`store/AppStore.ets`、`store/AuthStore.ets`、
> `service/NgaClient.ets`、`common/components/CredentialBanner.ets`、`pages/Index.ets`、
> `pages/MainPage.ets`。
>
> 本文替代原「会话确认失效 → 清登录态 + 跳登录页」的处置契约。改动前请先读完本文。

## 1. 要解决的问题

NGA 服务端偶发异常时会认为用户登录态失效。改造前的处置链是：

```
网络层识别未登录信号 → SessionGuard（60s 去抖 + iflogin 复核）→ 确认失效
  → AppStore.clearAuth()（reset 15 个数据域）
  → 强制 replaceUrl 到登录页
```

三个后果：

1. **用户什么都没做错却被踢出应用**，需要重新输入密码，而这份凭证往往几秒后就能用；
2. **清掉的不只是登录态**：浏览历史、阅读进度、收藏、跟踪、AI 会话、`routerStore`
   （当前帖子页与列表位置）、`floatingLayerStore` 一并清空；
3. **误判的来源是「用最严格接口的结论否定最宽松接口的能力」**。

## 2. 实测事实（2026-10）

| 观测 | 结论 |
|---|---|
| 无 Cookie 请求 `home/category`、`subject/hot` | 仍返回数据 |
| 无 Cookie 请求 `subject/list`、`read.php`、`thread.php` | 403 / `code=12 未登录`；真实浏览器匿名访问首页显示「访客不能直接访问」 |
| 服务端异常期间，用户在其他 NGA 客户端仍能读帖 | **各接口会话校验强度不一致**：`read.php` 弱于 `nuke.php` / `iflogin` |

第三条是本次设计的直接依据：`iflogin` 报 `SESSION TIMEOUT` 完全可能与「帖子能读」同时成立。
因此**不能用一次判定清空一切**。

> 注意：本客户端**没有游客态**，也不打算引入。降级只服务"已本地登录、服务端暂时不认"的用户。

## 3. 状态模型

`AuthState` 上现在有两个正交字段：

| 字段 | 语义 | 谁在读 |
|---|---|---|
| `isAuthenticated` | **本地是否持有完整凭证**（与 `uid`/`token` 一起表达） | 全工程 30+ 处门禁：轮询启停 `shouldEnablePolling`、`BaseStore.runGuardedRefresh`、收藏/关注/通知/AI 工具/阅读历史 |
| `credentialState` | **服务端最近一次认不认这份凭证**（`VALID` / `DEGRADED`） | 写操作门禁、顶部横幅 |

**红线：不得把 `isAuthenticated` 改成「服务端已确认」。** 服务端一抖动，轮询、受控刷新、
收藏、AI 工具会集体停摆，故障面反而被放大。降级只关闭"需要强确认"的能力。

`credentialState` 是**纯内存态，不落盘**：每次启动重新校验，避免陈旧结论挡住"服务端已恢复"。

## 4. 四条入口

```
                     ┌──────────────────────────────┐
网络层未登录信号 ────▶│ onUnauthorizedSignal         │ 60s 去抖 → iflogin → 2s 静默复验
                     │                              │ → 仍 INVALID → 降级
启动页 verify() ─────▶│ verify()                     │ 只返回结论，不自行降级
主页面 verifyIfStale ▶│ verifyOnForeground()         │ 正常 10min / 降级 1min 节流
横幅「重试」/3s 自动 ▶│ reverify()                   │ 强制复验，不走单飞
                     └──────────────────────────────┘
```

降级后的自愈路径，用户都不需要操作：

1. **后台自动探针**（`AppStore.scheduleCredentialRecheck`）：3s → 15s → 30s → 60s 有界退避，
   **只在前台跑**，恢复即取消。恢复后回到前台由 `setForegroundActive` 重新拉起。
2. **前台恢复探针**：降级态间隔从 10 分钟缩短到 1 分钟。
3. **用户点横幅「重试」**：强制复验。

> **不要把 1 改成"只探一次"**。用户一直在前台读帖时，读请求成功不产生"未登录"信号，
> 写操作被本地门禁拦下更不产生（门禁直接返回、不经过网络层）。只探一次意味着服务端
> 第 4 秒恢复也没有任何触发点，横幅会一直挂到用户手动点重试或切后台再回来。

任何一次校验通过都会触发 `notifyRecovered` → `AppStore.clearCredentialDegraded` → 横幅消失。

### 结论落地前的两道竞态防护

`SessionGuard.verifyNow` 对每个校验请求记 `seq`（单调递增）并在落地前做两项检查：

- **序号过期**：本次请求发出后已有更新的结论落地 → 归一为 `UNKNOWN`，不处置；
- **会话已变**：请求发出时的 `uid|cid` 与当前不一致（换号/退出）→ 同样归一为 `UNKNOWN`。

没有这两项就会出现"用户点重试成功、横幅消失，随后一条更早发出的 INVALID 迟到返回、
横幅闪回来"以及"新账号被旧账号的结论降级"。

## 5. 降级态做什么、不做什么

**做**：
- `AuthState.credentialState = DEGRADED`，写 AppStorage 键 `credentialDegraded`
- **底部**非阻塞浮动条（`CredentialBanner`）：「重试」「重新登录」「收起」
- Toast 一次「登录状态异常，发帖回复等操作已暂停」
- 写操作本地门禁：`NgaClient.setWriteGuard` 拦下所有写接口，请求**不发出**

**横幅必须在底部，不要挪回标题栏下方**：本工程左栏（`SidebarComponent`）与 sm 断点下的
社区列（`CommunityPanel`）都**没有标题栏**，头像块从 `statusBarHeight + 14` 就开始，
而板块列/活动列的标题栏确实在 `statusBarHeight + NAV_BAR_H` —— 同一个 y 必然遮挡其中一种。
底部只可能盖住列表末尾，用户滚动即可避开。外层全屏容器必须 `HitTestMode.Transparent`，
否则那块不可见的容器会吞掉列表的滚动与点击。

**不做**：
- 不 `clearAuth()`（会 reset 15 个 Store）
- 不清 `replyManager`（编辑器临时凭证）
- 不清 WebView Cookie（`clearWebViewAuthCookies` 只在用户主动退出时调）
- 不导航

这三件"不"只在用户**主动**退出登录（`LogoutOrchestrator`）或点横幅「重新登录」时发生。

## 6. 写操作门禁

作用点：`NgaClient.postSigned` 入口，按 `NgaThrottleSignals.isWritableOperation(lib, act)`
判定（**默认「不在只读清单里的一律按写处理」**）。选这里而不是各个 UI 入口，是因为写操作
散落在多个面板与三个编辑器管理器里，逐个加检查必然漏改。

被拦时返回合成响应 `buildBlockedResponse(message)`，形状必须**同时**覆盖三类调用方：

| 调用方判读方式 | 需要的字段 | 缺了会怎样 |
|---|---|---|
| `Number(raw['code'] ?? 0) === 0` 即成功（签到、私信、赞踩、投票…） | 非 0 的 `code` | **误报成功**（"签到成功" / 私信当作已发出） |
| `readAppError` 在 code 非 0 时读 `msg` | `msg` | 退化成通用兜底文案 |
| `parseNgaError` 读 `error['0']` | `error['0']` | 同上 |

另带 `__localBlocked: true`，让 `classifyAuthFailure` 忽略它 —— 否则降级态会被自己的拦截
反复"确认"，形成信号回环。

**附件上传是独立 multipart 通道**（`NgaUploader`），不经过 `postSigned`。它的调用方
（`ThreadWriteApi.uploadAttachment` / `uploadVideoAttachment`）必须用
`getWriteBlockReason()` 补同一层判断 —— 否则编辑器早先缓存的 `post/check` auth
（`ReplyManager.cachedAuth`）会让降级后的上传真的发出去。

## 7. 用户出口：横幅上的「重新登录」

走 `LogoutOrchestrator.logout`，即**用户主动退出语义**：服务端登出（尽力而为，失败不阻塞）
+ 清内存态 + 清 WebView Cookie + `replaceUrl` 到登录页。

为什么不做成「push 到登录页、可返回」：`LoginPage` 是全程 `replaceUrl` 的独立页，
没有返回路径，硬做只会给用户留一条回不去的死路。磁盘上的浏览历史/收藏/离线存档不受影响，
重新登录同一账号后都还在。

## 7.1 特例：凭证与账号**错配**必须硬清态

`verdictFromIfloginResponse` 在 `code=0` 但返回的 uid 与本地不一致时给出
`SessionVerdict.INVALID` + `SessionCheckResult.mismatched = true`。

这不是"服务端暂时不认这份凭证"，而是"服务端认为这个 cid 属于另一个账号"。若按普通降级
保留凭证，读接口会以别人的身份返回数据（私信、通知、收藏），显示在当前账号下 —— 隐私问题。
因此 `AppStore.markCredentialDegraded` 一进来就查 `SessionGuard.isCredentialMismatched()`，
命中则**直接 `clearAuthAndFlush()` + 提示**，不进入降级；启动页/主页面据
`appStore.auth.isAuthenticated` 变为 false 决定跳登录页。

## 8. 与既有不变量的一致性

| 不变量 | 本机制如何遵守 |
|---|---|
| `clearAuth()` 的顺序依赖（先 `writeQueue.cancel/reset` 再 `authStore.clearAuth()`） | 降级路径完全不碰它 |
| WebView Cookie 只能在主动退出时清 | 降级不清；横幅「重新登录」走 `LogoutOrchestrator` |
| `login/iflogin` 必须放行 | 它在 `READ_ONLY_OPERATIONS` 里，不被写门禁拦 |
| `@Observed` 嵌套属性不驱动 V1 刷新 | 横幅用 `@StorageProp('credentialDegraded')`，不观察 `AuthState` |
| `verify()` 的 INVALID 是二义的（无会话 / 服务端不认） | `SessionGuard.hasSession()` 区分：无会话不降级，交给登录流程 |

## 9. 已知边界（后续可做）

1. **读接口的失效信号仍会上升为全局确认**：靠 2 秒静默复验兜着，但未在归因层面切断。
   第 2 期可给 `postSigned` 的调用点标注能力等级，让读失败只影响该功能。
2. **写白名单是"默认写"语义**：`READ_ONLY_OPERATIONS` 同时服务于"是否可安全重试"与
   "是否写操作"。新增只读接口时若忘记登记 `lib/act`，会被门禁**静默误拦**。
   已登记 `post/check`（读、幂等）。新增调用点时必须同步核对。
3. **降级态下写操作入口没有视觉禁用态**：目前是点击后被网络层拦下并提示，入口仍显示可用。
4. **横幅只存在于 MainPage 页面树**：`pushUrl` 到 `AiChatPage` 后横幅不可见，但写门禁仍在生效。
   用户在该页撞到"登录状态异常"提示时没有可见出口。
5. **降级态跨启动无上界**：凭证长期失效的用户会一直停在"能读、不能写、有横幅"，
   永远不会被强制要求重新登录。这与"必须登录才能使用、没有游客态"有张力，
   可考虑持久化连续降级计数（N 次冷启动仍失败即强制回登录页）。
6. **WebView 网页版是门禁外的旁路**：`WebViewPanel` 注入自己的 Cookie，网页内的发帖不受
   `setWriteGuard` 约束。不在本期范围，但"写请求不会发出"只对原生 API 通道成立。
7. 附件上传之外的其它独立通道（如有新增）需同样检查是否绕过了 `postSigned`。

## 10. 回归保护

`entry/src/test/SessionUnit.test.ets` 的 `sessionAuth` / `sessionRecovery` 套件固化了
以下契约，改动时不要删：

- 确认失效 → **降级**（`degradedHandler` 一次），不导航、不清态
- 静默复验能过滤瞬时抖动（首次 INVALID、复验 VALID → 不降级）
- 复验 UNKNOWN 不降级（证据不足）
- 2 秒等待期间用户退出登录 → 放弃本次判定
- `reverify` 成功 → 恢复回调一次
- `verify()` 不自行降级（INVALID 的处置归调用方）
- 无会话永不降级
- `resetForNewSession` 清降级标志并复位信号去抖窗口
- 外部 `markDegraded()` 之后的下一次 VALID 仍要触发恢复（横幅才能消失）
- **迟到的旧校验结论不得覆盖更新的结论**（序号防护）
- `buildBlockedResponse` 同时满足 code / msg / error 三类判读，且不被识别成服务端信号
- iflogin 的 uid 错配被单独标为 `mismatched`（与普通失效区分）
