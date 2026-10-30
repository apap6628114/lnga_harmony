# 持久化数据域盘点（重构设计依据）

> 范围：`entry/src/main/ets` 全部持久化读写点（Preferences / 文件系统 / ArkWeb Cookie / AppStorage 内存信号）。
> 方法：逐文件通读 + 全仓 grep（`getJSON(` / `putJSON(` / `putString(` / `getString(`、`filesDir` / `cacheDir` /
> `database` / `relationalStore`、`preferences.getPreferences`、`PersistentStorage`、`AppStorage.setOrCreate`）。
> 结论均标注【文件:行号】或方法名；无法从代码确认的标 **待确认**。
> 约束：本阶段未修改 `entry/src` 下任何 `.ets`。
> **行号口径**：行号基于基线提交 `24aa9775`（= 本次盘点读取时的仓库快照）。调查期间
> `entry/src/main/ets/common/infra/PreferencesStore.ets` 存在他人的未提交改动（新增 `deleteKey` / `hasKey` / `getAll`），
> 该文件 `scheduleFlush` 的行号会下移约 55 行（`getJSON` / `putJSON` 等前半部分不受影响）；
> 同目录 `entry/src/main/ets/common/persistence/` 为**改造中的新代码**，不属于本盘点范围（本盘点只描述改造前现状）。

**全仓结论摘要（先行结论）**

1. **只有 1 个 Preferences 实例**：`AppStore` 持有唯一 `PreferencesStore`，文件名 `nga_app_store`【AppStore.ets:106,181】；
   全工程**没有** `PersistentStorage`、**没有** `relationalStore` / `database`（grep 0 命中）；除 Preferences 与文件系统外，
   唯一的第三方持久化面是 **ArkWeb Cookie**（应用级、不在 App 可控存储内）。
2. **只有 1 条写队列 + 1 个刷盘定时器**：`SerialQueue` 与 `PreferencesStore.flushTimer` 都是全局单例【AppStore.ets:107】。
3. **账号隔离有 4 种物理形态**：`<prefix>_<uid>` 分键、信封内 `uid` 字段校验、键内嵌 uid（短哈希 / bucket 片段）、完全全局。
   没有一个统一的"当前账号"存储入口——每个 Store 自己 `auth.uid` 拼键或自己校验信封。
4. **没有任何"旧数据迁移框架"**：现有迁移都是散落的字段级补全（`normalizeXxx`）+ 一次性回写标记
   （`AiSettings.consumeSearchMigration` / `consumePresetMigration`【AiSettings.ets:382-397】），且**只有 AI 设置域有**。
5. **只有 2 个域可导出导入**：离线存档 `saved_threads`（明文 JSON，`SAVED_THREAD_SCHEMA_VERSION=2`）与登录凭证
   （加密 `.ngacred`，`FORMAT_VERSION=2`）。设置 / 历史 / 通知 / 草稿等**全部无导出能力**。
6. **登出从不清盘**：`AppStore.clearAuth`【AppStore.ets:535-562】只做内存 reset + 写空 `auth`；
   `settings_<uid>` / `history_<uid>` / `notifications` / 草稿 / 存档全部原样留在磁盘，且**没有任何"清理旧账号键"的代码**。

---

## 1. 总览表

| 域 ID | 存储介质 | 实际键名 / 路径模板 | 数据类 | 量级 / 条目上限 | 写入方（文件#方法） | 读取方 | 账号隔离方式 | schema 版本 | TTL / LRU | 清空入口 | 导出 / 导入 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `auth` | Preferences | `auth`、`sessions` | `PersistedAuth`【AuthStore.ets:56-74】；`Session`【SessionRegistry.ets:4-15】 | 2 键；sessions 通常 1 条/账号 | `AuthStore#persistAuth`【:139-152】`#persistSessions`【:279-293】 | `AuthStore#loadAuth`【:165-181】`#loadSessions`【:251-277】 | 全局（`sessions` 以 token 为索引，记录 uid/cid） | 无（`cid?` 为可选字段兼容） | 无 | 登出写空 `auth` + 删当前 token 会话【:114-131】 | 有：uid+cid → 加密 `.ngacred` |
| `theme` | Preferences | `nga_theme` | `ThemePersist{theme}`【ThemeSettings.ets:14-16】 | 1 条 | `ThemeSettings#persistGlobal`【:129-139】 | `#loadGlobal`【:48-54】 | **全局**（刻意不带 uid） | 无（值白名单校验【:57-59】） | 无 | 无（登出不重置，`repersist` 重放【:73-75】） | 无 |
| `settings` | Preferences | `settings_<uid>`【SettingsStore.ets:120-122】 | `SettingsState`（35 字段，含黑名单/收藏版面/便签/屏蔽词/AI 全量配置）【SettingsState.ets:19-96】 | 无硬上限；单条 JSON 全量重写 | `SettingsStore#persistSettings`【:124-130】+ 9 个域子 store 的 setter | `#loadUserSettings`【:132-165】；UI 经 `appStore.settings` | **物理分键** | **无**（字段级 `!== undefined` 兼容） | 无（`ensureFavorites` 有 10s 延迟刷新【SocialListSettings.ets:146-148】） | 登出 `reset()` 重建内存（不清盘）【SettingsStore.ets:98-116】 | 无 |
| `history` | Preferences | `history_<uid>`【HistoryStore.ets:79-81】 | `BrowseHistoryEntry[]`【:12-33】 | **500 条**（`HISTORY_MAX_COUNT`【:41】），LRU 淘汰 | `HistoryStore#persistBrowseHistory`【:293-300】 | `getBrowseHistory`【:83-105】；主题列表已读台账 `getReadReplies`【:131-137】 | **物理分键** | 无 | 条目级 LRU（超 500 截断【:218-222】）；无 TTL | 登出 `reset` 只清内存【:69-77】；页内"清空历史"→ `persistBrowseHistory` 写空数组【:287-291】 | 无（AI 工具只读【NgaMyLibraryTools.ets:202】） |
| `reading_progress` | Preferences | `reading_progress_<uid>`【ReadingProgressStore.ets:42-44】 | `ReadingProgressEntry[]`【:6-15】 | **200 条**（`PROGRESS_MAX_COUNT`【:18】），按 ts 淘汰最早 | `#persistProgress`【:117-127】 | `ThreadPanel#restoreReadingProgress`（`appStore.getReadingProgress`【ThreadPanel.ets:630】） | **物理分键** | 无 | 条目级 LRU（按 `ts` 最小淘汰【:101-113】） | 登出 `reset`【:36-40】；无用户可见清空入口 | 无 |
| `votes` | Preferences | `votes_<uid>`【VoteStore.ets:42-44】 | `Record<tid, VoteRecord{upPids,downPids,ts}>`【:7-11】 | **200 帖**（`VOTE_MAX_ENTRIES`【:13】），按 ts 淘汰 | `saveVoteRecord`【:79-107】/`removeVoteRecord`【:109-135】/`clearVoteRecords`【:137-145】 | `loadVoteRecord`【:50-77】← `ThreadPanel`【:761】 | **物理分键** | 无 | 条目级 LRU【:147-172】 | 登出 `reset`【:34-40】；`clearVoteRecords` 可由调用方触发 | 无 |
| `poll_voted` | Preferences | `pollVoted_<uid>`【VoteStore.ets:46-48】 | `Record<tid, timestamp>` | **200 帖**（同常量【:13】） | `markPollVoted`【:209-235】 | `loadPollVoted`【:193-201】← `PostPoll`【PostPoll.ets:64】 | **物理分键** | 无 | 条目级 LRU【:237-255】 | 登出 `reset`【:34-40】 | 无 |
| `notifications` | Preferences（信封） | `cached_notifications_<uid>`（前缀 `cached_notifications` + `CacheEnvelopeStore#key`）【NotificationStore.ets:74-78】 | 信封 `{schemaVersion,uid,items,updatedAt}` + `NgaNotification[]`【Notification.ets:4-66】 | **200 条**（`MAX_CACHED_NOTIFICATIONS`【:33】） | `#persistCachedNotifications`【:305-307】← `performRefresh`/`markSeen*` | `MessagePanel`→`appStore.getCachedNotifications`【NotificationPanel.ets:257,273】；未读红点 `AppStorage` | **信封内 uid + 物理分键（双保险）** | **3**（`NOTIFICATION_CACHE_SCHEMA_VERSION`【:30】） | 合并保留 200 条（`mergeNotifications`）；无 TTL | 登出 `reset` 只清内存【:103-112】；缓存非法时**写空覆盖**【:275-286】 | 无 |
| `activities` | Preferences（信封） | `cached_activities_<uid>`【FollowActivityStore.ets:93-97】 | 信封 + `FollowedActivity[]`【Follow.ets:39-66】 | 落盘窗口 **200 条**（`MAX_CACHED_ACTIVITIES`【:33】）；内存真源 **10000** 条【:36】 | `#persistCachedActivities`【:406-408】 | `NotificationPanel` 动态 Tab【:412】；AI 工具【NgaMySocialTools.ets:233】 | 信封内 uid + 物理分键 | **2**（`ACTIVITY_CACHE_SCHEMA_VERSION`【:25】） | 内存上限 10000；落盘窗口 200；无 TTL | 登出 `reset`【:126-137】；非法信封写空覆盖【:367-384】 | 无 |
| `tracked_threads` | Preferences（信封） | `tracked_threads_<uid>`【TrackedThreadStore.ets:128-132】 | 信封 + `TrackedThread[]`【TrackedThread.ets:46-89】 | **50 帖**（`TRACK_MAX_COUNT`【TrackedThread.ets:19】） | `#persist`【TrackedThreadStore.ets:668-670】 | `FavoriteSavedPanel`/`NotificationPanel`【FavoriteSavedPanel.ets:609；NotificationPanel.ets:310】；AI 工具【NgaMyLibraryTools.ets:590】 | 信封内 uid + 物理分键 | **2**（`TRACKED_THREAD_SCHEMA_VERSION`【:50】） | 无 TTL；10 分钟前台轮询检查【TrackedThread.ets:22】 | 登出 `reset`【:159-168】；用户"全部移除"`untrackAll`【:344-351】 | 无 |
| `favorites_membership` | Preferences | `favorite_topic_membership_v1_<uid>`（前缀 + 直接拼 uid）【FavoriteStore.ets:40,875-877】 | 自定义信封 `{schemaVersion,uid,favoredFolderIds,knownFolderIds}`【:45-62】 | 无上限（按 topic 累积） | `#persistMembershipCache`【:912-944】 | `#loadMembershipCache`【:884-907】；详情页收藏按钮 | 信封内 uid + 物理分键（**不经** `CacheEnvelopeStore`） | **1**【:35】 | 无 TTL；`reconcileMembershipFolders` 回收失效 folder【:750-794】 | 登出 `reset` 只清内存【:145-150】 | 无 |
| `profiles` | Preferences | `cached_profiles_v2_<uid>`【ProfileStore.ets:41-43】 | `Record<uid, ProfileData>` | 内存 LRU **200** 条 / **5 分钟** TTL【:21】；落盘为内存快照 | `#persistProfiles`【:60-74】 | `getCachedProfile` / `loadProfileForTool`【:76-85,122-132】 | **物理分键** | 键名带 `_v2_`，但**无代码内版本字段**、无 v1 清理 | LRU 200 + 5min 内存 TTL（落盘无 TTL） | 登出 `reset` 只清内存【:33-37】 | 无 |
| `categories` | Preferences | `cached_categories`（**全局**）【CategoryStore.ets:42,56】 | `Category[]`【model/Forum】 | 全量板块分类（数百条） | `#persistCategories`【:54-59】（内容变化才写） | `appStore.cachedCategories` | **全局** | 无 | 无（每次启动 10s 后刷新比对） | 登出 `reset` 只清内存【:31-37】 | 无 |
| `ai_sessions` | Preferences（信封） | `ai_sessions_<uid>`【AiSessionStore.ets:36,59-63】 | 信封 + `AiSession[]`【AiSession.ets:65-97】 | **20 会话/账号**（`MAX_AI_SESSIONS`【AiSession.ets:18】）× **200 消息/会话**【:26】 | `#persist`【AiSessionStore.ets:289-296】← `saveSession`/`deleteSession`/`clearAllSessions` | `AiChatPage` 历史列表【AiChatPage.ets:529,549】 | 信封内 uid + 物理分键 + **条目级 `ownerUid`**【AiSession.ets:73；AiSessionStore.ets:163-173】 | **1**（`AI_SESSION_SCHEMA_VERSION`【AiSession.ets:15】） | 会话 20 / 消息 200 / 标题 28 / toolNotes 6 | 登出 `reset` 只清内存（磁盘保留）【:100-104】；`clearAllSessions` 写空【:241-247】 | 无 |
| `ai_tool_cache` | Preferences（信封） | `ai_tool_cache_<uid>`【AiToolCacheStore.ets:39,60-65】 | 信封 + `ToolCacheSnapshot[]`（key/expiresAt/result）【ToolResultCache.ets:331-338】 | 落盘 **80 条 / 1.2M 字符**【AiToolCacheStore.ets:42,45】；内存 LRU 200 条 / 8M 字符【ToolResultCache.ets:54,384】 | `#save`（800ms 合并写）【:159-200】 | 工具执行 `ToolRegistry` 查缓存【:336】 | 信封内 uid + 物理分键 + **条目 key 内嵌 uid bucket**（`tool\|uid\|指纹\|参数`）【ToolResultCache.ets:134-141】 | **1**【:36】 | 条目级 `expiresAt`（TTL 长 600s / 短 45s【AiToolConfig.ets:32,35】）+ LRU + 体积裁剪 | 登出 `reset` 只清内存【:112-118】 | 无 |
| `saved_threads` | 文件目录 | `filesDir/saved_threads/<tid>.json`【SavedThreadStore.ets:27,80-82】 | `SavedThread`（含 `rawPages` 原始 JSON 每页一项）【SavedThread.ets:21-49】 | 无硬上限；单帖 = 已存页数 × 页 JSON | `#save`（tmp+rename 原子写）【:205-258】 | `SavedThreadService` 离线读【SavedThreadService.ets:233,244,279】；列表【FavoriteSavedPanel.ets:768】 | **全局**（不按账号） | **2**（`SAVED_THREAD_SCHEMA_VERSION`【SavedThread.ets:16】，仅导出文件带版本；单文件靠 `rawPages` 存在性判活） | 无 TTL；坏文件跳过不删 | "清空存档"`clear`【:294-313】；清缓存**不含**该目录 | **有**：`serializeForExport` / `importContent`【:321-390】明文 JSON |
| `drafts` | 文件目录 | `filesDir/drafts/<草稿键>.json`【DraftStore.ets:39,255-257】 | `EditorDraft{key,content,subject,media[],updatedAt}`【:154-169】 | 无硬上限；**保留 7 天**（`DRAFT_RETENTION_DAYS`【:50】） | `#saveDraft`（tmp+rename）【:338-376】 | `loadDraft`【:270-313】（编辑器 `aboutToAppear`） | **键内嵌 uid 短哈希**（`draft_<tid>_p<pid>_<uidHash>`）【ReplyManager.ets:1093-1105；NewTopicManager.ets:538-544】 | 无（字段级补全【:299-306】） | 按 mtime 7 天淘汰（`cleanupStale`【:517-578】） | 提交成功 / 放弃 / 清缓存整目录删除【SettingsPanel.ets:267,285】 | 无 |
| `draft_media` | 文件目录 | `filesDir/draft_media/<草稿键>/<ts>_<seq>_<文件名>`【DraftMediaStore.ets:59,291-292】 | 二进制副本（图 / 动态照片两半） | **128MB 软上限**（`DRAFT_MEDIA_MAX_BYTES`【:69】） | `#saveCopy`【:280-297】 | 懒重传（`ReplyManager`/`NewTopicManager`） | 目录名即草稿键（含 uid 哈希） | 无 | 孤儿即时回收 + 容量淘汰仅动孤儿，有主豁免【文件头 18-33】 | 清缓存整目录删除；随草稿键删除 | 无 |
| `mphoto` | 文件目录 | `filesDir/mphoto/<urlHash>.<ext>`【MovingPhotoCache.ets:26,54-56,107-109】 | 动态照片封面 / 视频缓存 | **80 文件 / 256MB**（软上限，超限降到一半）【:29,37,340-341】 | `ensureMovingPhotoFiles`【:374-402】 | 播放器 / 图片查看器（`MovingPhotoPlayer`） | 全局（按 URL 哈希，与账号无关） | 无 | 文件数 + 体积双上限淘汰（跳过在用/下载中） | "清除缓存"整目录删除【SettingsPanel.ets:263】 | 无 |
| `mphoto_upload` | 文件目录（cacheDir） | `cacheDir/mphoto_upload/<ts>/{upload.jpg,video.mp4}`【MovingPhotoExport.ets:55-61,283】 | 动态照片导出临时产物 | 每轮 1 目录；异常残留 **>600s** 视为陈旧【:72】 | `exportMovingPhoto`【:281-347】←`pickImage`【:349-381】 | `readExportedFile`【:393-406】 | 全局（无账号字段） | 无 | 上传结束即删；每次入口最多清 8 个残留【:75】 | 清缓存（cacheDir）；`pruneStaleExports` | 无 |
| `tts_wav` | 文件目录（cacheDir） | `cacheDir/tts-<ts>-<gen>-<seq>.wav`【TtsWavFileWriter.ets:291-293】 | TTS 合成 WAV | 单文件 1 段音频 | `begin`/`append` | TTS 播放器 | 全局 | 无 | 启动异步清理陈旧文件【:484-498】 | 清缓存（cacheDir） | 无 |
| `image_temp` | 文件目录（filesDir） | `filesDir/temp_<ts>.<ext>`、`filesDir/share_<ts>.<ext>`【ImageViewer.ets:297,341】 | 图片保存到相册 / 分享的临时下载 | 单文件 | `saveStillToAlbum` / `shareCurrentImage` | 相册/分享 | 全局 | 无 | **无清理**（残留） | 无（清缓存不扫 `filesDir` 根目录） | 无 |
| `webview_cookies` | ArkWeb Cookie（应用级持久化） | 不透明（`ngaPassportUid` / `ngaPassportCid` 等）【AGENTS.md §WebViewCookie】 | Cookie 键值 | 若干 | WebView 登录层 / 浏览网页版 | `LoginPage` / `WebViewPanel` | **全局（危险：会跨账号保持登录态）** | 无 | 无 | 登出 `clearWebViewAuthCookies()`【WebViewCookieUtils.ets:61-66】 | 无 |
| `app_storage` | 无（AppStorage 内存） | `AppStorageKeys.ets` 全部 38 键【AppStorageKeys.ets:14-148】 | 版本号 / 未读数 / 主题名 / 列占比 / 降级标记 | 38 键 | 各 Store `AppStorage.setOrCreate` | `@StorageProp` / `AppStorage.get` | 全局（进程内） | 无 | 随进程销毁 | 进程结束 | 无（**非持久化**，仅内存信号） |

> 表注：
> - "信封"= `CacheEnvelopeStore` 的 `{schemaVersion, uid, items, updatedAt}` 结构【CacheEnvelopeStore.ets:7-12】。
> - 所有 `_<uid>` 键的 uid 一律为**明文 uid 字符串**；只有草稿键用 FNV-1a 短哈希（`draftUidPart`【DraftStore.ets:100-117】）。
> - 量级中的"无硬上限"指代码中**没有任何条数/字节裁剪**，是本次重构需要补的治理项（见 §6 问题 10）。

---

## 2. 逐域细节

### 2.0 公共骨架（所有 Preferences 域共用，重构时最先被替换的部分）

| 组件 | 位置 | 行为与约束 |
|---|---|---|
| `PreferencesStore` | `common/infra/PreferencesStore.ets` | 包装 `preferences.getPreferences(context, name)`【:11-18】；`getJSON` 解析失败**吞异常返回 null**（仅 info 日志）【:42-53】；`putJSON/putString` 失败**吞异常**（仅 error 日志，调用方无法感知写失败）【:30-40,55-65】；`scheduleFlush(500ms)` 合并刷盘【:76-81】 |
| `SerialQueue` | `common/infra/SerialQueue.ets` | 全局单链 Promise：`enqueue` 串行执行、失败继续【:9-17】；`cancel()` 置标志【:19-22】；`reset()` **会清掉 cancelled 标志**并重置链【:24-28】 |
| `CacheEnvelopeStore<T>` | `common/infra/CacheEnvelopeStore.ets` | `key(uid) = <prefix>_<uid>`【:53-55】；严格 `isValidEnvelope`（版本+uid+逐条）【:64-86】；宽容 `loadTolerant`（跳过坏条目）【:99-123】；`load` 严格【:144-150】；`persist` = 快照 + `putString(flush=false)` + `scheduleFlush`【:160-175】 |
| `BaseStore<T>` | `store/BaseStore.ets` | `GenerationGuard` 代际 + `uidGuard()`【:148-150】+ `runGuardedRefresh`（认证门禁/并发复用/30s 级节流）【:83-116】+ `isRequestCurrent`（gen+uid+token+isAuthenticated 四重）【:126-131】 |
| `AuthScope` | `store/AuthScope.ets` | await 前 `capture(auth, gen)`、await 后 `isCurrent` 校验【:47-52,62-70】；settings 域子 store 传 `generation=0` 退化为纯身份校验 |
| 初始化编排 | `store/AppStore.ets:174-221` | 顺序：`store.init('nga_app_store')` → `savedThreadStore.init` → `draftStore/draftMediaStore.init` → 草稿清理（延后 800ms）→ vote/history/readingProgress（**注入 auth 为空**）→ authStore → categoryStore → `settingsStore.initTheme` → `loadUserData` |
| 刷盘时机 | `AppStore#flushAll`【:508-513】，`EntryAbility#onBackground`【EntryAbility.ets:266-270】 | 工具缓存 flush → 等写队列 barrier → `store.flush()` |
| 登出编排 | `AppStore#clearAuth`【:535-562】+ `LogoutOrchestrator#logout`【LogoutOrchestrator.ets:18-47】 | `writeQueue.cancel()` → `writeQueue.reset()` → `authStore.clearAuth()` → 12 个 Store `reset()` → `replyManager.reset()` → `clearWebViewAuthCookies()` → 跳登录页 |

**关键事实（影响全部域）**

- **写失败不可观测**：`putJSON` 内 `catch` 只记日志，重构若引入统一写入层必须补返回值/重试。
- **`uidGuard()` 对 3 个 Store 是空操作**：`HistoryStore#init`【HistoryStore.ets:64-66】、`VoteStore#init`【VoteStore.ets:29-31】、
  `ReadingProgressStore#init`【ReadingProgressStore.ets:31-33】都只调 `setDeps(store, queue)`，`auth` 保持 `undefined`，
  故 `uidGuard()` 恒返回 true（`BaseStore#uidGuard`【BaseStore.ets:148-150】）。
  这些域的"防串号"实际只靠 **uid 参数 + generationGuard**，而非 uidGuard。
- **单文件承载全量 Preferences**：`settings_<uid>` 是一个整 JSON，每次 setter 都全量序列化重写（`persistSettings`），
  黑名单/收藏/AI 配置越多，单次写放大越明显（估算：AI 配置含密钥，几十 KB 级；**待确认**是否有实测值）。
- **登出写队列语义存疑（待确认）**：`clearAuth` 先 `cancel()` 立刻 `reset()`【AppStore.ets:540-541】，
  而 `reset()` 会把 `cancelled` 置回 false【SerialQueue.ets:24-28】；cancel 前已入队但未执行的任务
  （如 `history_<oldUid>` 的落盘闭包）在 reset 之后执行时读到 `cancelled=false`，会**照常执行**。
  闭包读取的是**执行时**的实时字段（如 `this.historyItems`，此时已被后续 `historyStore.reset()` 清空），
  可能把空数组写回旧 uid 键（等效清空历史）。**待确认**：是否已在真机/单测验证；这条决定"登出即删数据"能否实现。

### 2.1 `auth`（凭证与会话）

- 结构：`PersistedAuth{token, uid, nickName, avatarUrl, cid?}`【AuthStore.ets:56-74】；
  `sessions` = `Array<[token, Session]>`（二维数组，非对象）【:279-293】，`Session{uid,cid,nickName,avatarUrl,createdAt}`【SessionRegistry.ets:4-15】。
- 写入：登录 `setAuth` → `persistAuth(immediate=true)` 并 **await 队列 barrier** 保证落盘【:107-111】；
  登出 `clearAuth` → 写空 `auth`（immediate=true）【:114-131】；会话表在 `createSession/destroySession/updateSession` 后写。
- 自愈：`recoverSession` 在 `sessions` 缺失时用 `auth.cid` 冗余副本或同 uid 残留会话重建【:195-246】。
- 损坏兜底：`loadSessions` **逐条 try/catch 跳过坏条目**【:251-277】（不整表判死）；`loadAuth` 无字段校验，直接赋值。
- 并发：`persistAuth` 走全局写队列；`sessionsDirty` 标志防止重复写【:279-282】。
- **取消隔离影响**：`uid` 是隔离源本身，不能去；需要明确的是"同一设备保留几份凭证"（当前 `sessions` 理论可存多账号，
  但 `createSession` 会顺手删除同 uid 旧 token【:298-306】，所以实际 1 账号 1 token）。

### 2.2 `theme`（全局主题）

- 结构：`{theme: 'system'|'light'|'dark'}`，键 `nga_theme`【ThemeSettings.ets:30,133-136】。
- 为什么全局：未登录也要跨冷启动生效（`AppStore#initTheme` 在 `loadUserData` 之前无条件调用【AppStore.ets:204】）。
- 损坏兜底：`isValidTheme` 白名单，非法值忽略保持默认 `'light'`【:57-59】。
- 登出：`SettingsStore#reset` 里 `restoreGlobal()`（对齐 AppStorage）+ `repersist()`（重放落盘）【SettingsStore.ets:101-106】。
- **取消隔离影响**：已经是全局，无需改；它是"设置里哪些字段允许全局"的**唯一既有先例**（可复用到 categories/profiles）。

### 2.3 `settings`（账号设置总集，`settings_<uid>`）

JSON 形状（**示意**：省略了部分字段与数组元素，`...` / `[...]` 非严格 JSON；完整 35 字段见 `SettingsState`【SettingsState.ets:19-96】）：

```json
{
  "blacklist": [{"userId":"123456","nickName":"某人"}],
  "filterKeywords": [{"keyword":"剧透","enabled":true}],
  "favorites": [{"fid":-7,"stid":0,"name":"网事杂谈"}],
  "fontSize":15,"topicFontSize":15,"domainIndex":0,
  "autoCheckin":false,"lastCheckinDate":"2026-10-30",
  "notes":[{"userId":"123456","nickName":"某人","note":"备注"}],
  "ttsPerson":13,"ttsSpeed":1.0,"ttsVolume":1.0,"ttsPitch":1.0,
  "imageLoadStrategy":"always","showTopicPreview":true,"threadNavMode":"seamless",
  "prefetchPageCount":1,"recordReadingProgress":true,"videoMuted":false,
  "useInternalWebView":true,"debugMode":false,
  "aiProfiles":[{"id":"ai_...","name":"DeepSeek 官方","presetId":"deepseek",
                 "endpoint":"https://...","apiKey":"sk-...","modelName":"deepseek-chat",
                 "protocol":"responses","temperature":0.7,"contextWindow":0,
                 "toolsEnabled":true,"enableWebSearch":true,"maxAgentSteps":30}],
  "activeAiProfileId":"ai_...","aiSearchProfiles":[...],"activeAiSearchProfileId":"ais_...",
  "scenarioSystemPrompts":{"thread":"..."},"aiToolSettings":{"enabled":{},"maxAgentSteps":30},
  "aiMemorySettings":{"mode":"long","tokenCalibration":1},"aiPresets":[...],
  "columnSidebarMd":180,"columnSidebarLg":180,"columnBoardRatioLg":0.4
}
```

- **无 schemaVersion**：这是全仓唯一"带 35 个字段却无版本号"的域。兼容策略是各子 store `load(saved)` 内逐字段判空：
  `DisplaySettings#load` 用 `!== undefined` 与 `> 0`【DisplaySettings.ets:115-128】、`MediaSettings#load`【:72-84】、
  `ReadingSettings#load`【:35-43】、`SocialListSettings#load`【:277-288】、`NoteSettings#load`【:56-61】、
  `CheckinSettings#load`【:53-56】、`AiSettings#load`【AiSettings.ets:255-281】。
- **损坏兜底**：`getJSON` 解析失败 → `saved=null` → 直接跳过 `loadUserSettings` 的加载分支【SettingsStore.ets:132-151】，
  即**整份设置静默回默认值**，且坏 json 会一直留到下一次 `persistSettings` 被覆盖。
- **迁移**：仅 AI 域有两次一次性迁移（搜索配置从对话配置迁移、补齐工具/内置任务），由
  `consumeSearchMigration()/consumePresetMigration()` 取出标记后在 `loadUserSettings` 末尾回写【SettingsStore.ets:162-164；AiSettings.ets:382-397】。
- 并发：所有 setter → `ctx.persist()` → `SettingsStore#persistSettings` 入全局写队列并全量 `putJSON`；
  **无合并/去抖**（连续拖拽列宽会连续入队 N 次全量 JSON 写）。
- 子域账号相关性差异极大（这是取消隔离时最需要拆分的域）：

| 子域 | 字段 | 账号相关？ | 依据 |
|---|---|---|---|
| 显示 / 媒体 / 阅读 / 列布局 | fontSize、imageLoadStrategy、threadNavMode、column* | 弱（可全局） | 纯偏好 |
| 黑名单 | `blacklist[]` | **是**（本地+请求头） | `addBlacklist` 拒绝把自己加入【SocialListSettings.ets:54-58】；`getBlacklistHeaderString` 作为请求头【:134-136】 |
| 收藏版面 | `favorites[]` | **是（服务端真源）** | `doRefreshFavorites` **无条件覆盖本地**（含空表）【:166-181】 |
| 便签 | `notes[]` | **是（针对其他用户的私密备注）** | `NoteSettings` |
| 屏蔽词 | `filterKeywords[]` | 弱 | 纯本地列表 |
| 自动签到 | `autoCheckin`、`lastCheckinDate` | **是**（按天去重 + token） | `autoCheckinIfNeeded` 用 uid 无关的今日去重【CheckinSettings.ets:25-50】 |
| AI 配置 | `aiProfiles[].apiKey` 等 | **是（含密钥）** | `AiSettings` |
| AI 任务 / 提示词 / 工具 | `aiPresets`、`scenarioSystemPrompts`、`aiToolSettings` | 弱（可全局） | 客户端能力配置 |

- **取消 uid 隔离后受影响的行为点**：
  1. 黑名单/便签/AI 密钥直接串号（隐私 + 安全）；
  2. 收藏版面会被"最后登录的账号的服务端快照"覆盖，且 `syncFavoritesOnce` 会上传错整表到服务端；
  3. `lastCheckinDate` 共享 → 第二个账号当天不会自动签到（少一次签到）；
  4. 列占比/字号等"看似全局"的字段被多账号互相覆盖（用户会抱怨"设置自己变了"）。

### 2.4 `history`（浏览历史 + 已读台账）

- 结构：`BrowseHistoryEntry{tid,subject,author,authorid,replies,postDate,board,ts}`【HistoryStore.ets:12-33】；
  落盘为**裸数组**（非信封、无版本、无 uid 字段）【:293-300】。
- 双职责：列表展示 + **已读基线索引** `readBaselines: Map<tid, number>`（列表行构建期同步查询）【:55-62】。
  基线载体是条目的 `replies`，哨兵 `READ_BASELINE_UNKNOWN=-2`【TopicReadPolicy.ets:31】，「没看过」用 `-1` 表示【:22】。
- 损坏兜底：加载后 `rebuildReadBaselines` 对每条做 `String()`/`normalizeBaseline` 防御（负数/非数按未知）【:151-177】，
  目的是不让坏 JSON 把 `AppStore.init` 打挂（注释明确写了这条）。
- 并发：`generationGuard` + `historyLoadedUid` 双校验（加载期间登出/换号则丢弃）【:83-105,194-203】；
  写入走全局队列。
- **取消 uid 隔离影响**：已读台账是"账号私有阅读状态"，A 看过的帖子在 B 会显示"已读/无更新"，
  主题列表的降权与"+N 新回复"标记全部失真；`HISTORY_MAX_COUNT=500` 会被多账号挤占（各账号实际保留变少）。
  另：`getBrowseHistory(uid)` 是**参数化接口**，`AppStore` 门面 5 个方法（`getBrowseHistory` / `addBrowseHistory` /
  `addBrowseHistoryFromThread` / `removeBrowseHistory` / `clearBrowseHistory`）都要带 uid 参数【AppStore.ets:800-808】，
  `BrowseHistoryPanel` 直接传 `appStore.auth.uid`【BrowseHistoryPanel.ets:93】——取消隔离必须改这些签名。

### 2.5 `reading_progress`（阅读进度）

- 结构：`ReadingProgressEntry{tid,page,pid,ts}`【ReadingProgressStore.ets:6-15】，裸数组落盘。
- 语义：`page` 为服务端页（从 1 起），`pid<0` 表示无有效锚点；用于楼层级定位恢复（`ThreadPanel` 写【ThreadPanel.ets:586】、读【:630】）。
- LRU：超 200 条按 `ts` 最小淘汰【:101-113】。
- 损坏兜底：逐条直接 `progressMap.set`，**无字段校验**（脏对象会带进 UI；待确认实际表现）。
- **取消隔离影响**：跨账号共用会让 B 打开同一帖跳到 A 的楼层；200 条上限被分摊；与 `recordReadingProgress` 设置项耦合（见 2.3）。

### 2.6 `votes` / 2.7 `poll_voted`

- 结构：`votes_<uid>` = `Record<tid, {upPids[], downPids[], ts}>`【VoteStore.ets:7-11】；`pollVoted_<uid>` = `Record<tid, ts>`。
- 语义：点赞/踩是**本地乐观状态**（pids 集合）；`pollVoted` 是"已投过票"标记，提交成功后写入【:209-235】。
- LRU：两者共用 `VOTE_MAX_ENTRIES=200`，按 ts 淘汰【:147-172,237-255】。
- 并发：`voteLoadedUid` + 代际校验；`markPollVoted` 写入时**捕获快照**避免写入已被替换的缓存【:222-234】。
- 损坏兜底：`Record` 直接赋值，无版本；`Object.keys` 遍历对脏值（非对象）会抛（**待确认**）。
- **取消隔离影响**：A 的点赞会在 B 显示为"已赞"（错误的操作态）；B 对 A 投过的投票帖会显示"已投"而**无法投票**。

### 2.8 `notifications`（通知缓存）

- 信封：`{schemaVersion:3, uid, items:[NgaNotification], updatedAt}`，键 `cached_notifications_<uid>`【NotificationStore.ets:74-78】。
- 单条校验按类型分支：通用 8 字段 + 按 `type` 校验 mid/tid/pid/replyPid/page【:316-349】。
- **严格载荷**：`load()` 失败 → `cachedNotifications=[]` 并**立即 `persist` 空**（磁盘旧缓存被覆盖）【:275-286】；
  这是 schema 升级/单条脏数据的**数据丢失点**（与 `AiSessionStore` 的 `loadTolerant` 形成对照）。
- 合并：`mergeNotifications(..., 200)`【:183-187】；已读态承载在条目 `seen` 上；未读数写 AppStorage【:294-300】。
- 请求侧：`runGuardedRefresh` 30s 节流 + 300s 轮询；回写前 `isRequestCurrent` 四重校验【:157-195】。
- **取消隔离影响**：`seen` 串号（A 读过 → B 无红点）、`serverUnreadHint` 串号；信封 uid 校验移除后必须保证 items 逐条带 ownerUid。

### 2.9 `activities`（关注动态缓存）

- 信封 `schemaVersion:2`，`cached_activities_<uid>`；落盘只存 `displayActivities` 前 200 条窗口【FollowActivityStore.ets:216-219】。
- 内存真源 `displayActivities` 上限 10000（分页追加）【:36】，`loadedPages/totalPages` 是**账号级运行态**（登出即清）。
- 严格载荷：非法信封 → 写空覆盖【:367-384】。
- 与通知的差别：**已读不 bump 列表版本**（避免整表重建打断滚动）【FollowActivityStore.ets 文件头 59-67】。
- **取消隔离影响**：动态本身是"我关注的人"的内容（账号相关），串号会直接显示别人的关注流；`seen` 串号同理。

### 2.10 `tracked_threads`（跟踪帖子）

- 信封 `schemaVersion:2`（v2 增加了 `seenLastPostTs`）【TrackedThreadStore.ets:50】；
  条目 `TrackedThread` 17 字段【TrackedThread.ets:46-89】，含 `totalReplies/seenReplies/seenLastPostTs/lastPostTs/lastCheckAt/failCount`。
- 强账号绑定：检查需要**该账号 token**（`fetchThreadTrackStatus`），且 `refresh` 走 `runGuardedRefresh` 认证门禁【:447-451】。
- 停止出口 3 个（失效 / 满 `keepDays` 天无回复 / 用户移除）【TrackedThread.ets:36-43】；网络失败**绝不停止**（只累计 failCount）。
- 严格载荷：非法信封 → 写空覆盖【:653-663】。
- **取消隔离影响（高风险）**：跟踪任务跨账号合并会被**另一个账号的 token** 检查（读到别人关心的帖子），
  红点基准 `seenReplies` 串味；`TRACK_MAX_COUNT=50` 被分摊；`keepDays` 生命周期混乱。
  这是少数**必须保留条目级 ownerUid** 的域，且 `refresh/refreshOne` 必须只处理"当前账号"的任务。

### 2.11 `favorites_membership`（收藏成员关系提示缓存）

- 自定义信封：`{schemaVersion:1, uid, favoredFolderIds: Record<tid, folderId[]>, knownFolderIds: Record<tid, folderId[]>}`
  【FavoriteStore.ets:45-62】，键 `favorite_topic_membership_v1_<uid>`【:40,875-877】。
- **不经 `CacheEnvelopeStore`**：校验逻辑手写在 `loadMembershipCache`（版本 + uid 两项）【:884-891】。
- 语义：缓存"某主题在哪些收藏夹"的**本地可信状态**；服务端收藏夹列表是唯一真源，
  `reconcileMembershipFolders` 会用最新 folders 修正默认夹别名 `'1'` 并清理失效 folder【:750-794】。
- **取消隔离影响（高风险）**：收藏夹 ID 是**账号级服务端命名空间**，folder id 在不同账号下含义不同；
  合并会让主题错误显示"已收藏"或误删收藏。必须 ownerUid 或干脆丢弃重建（它只是提示缓存）。

### 2.12 `profiles`（用户资料 LRU 缓存）

- `cached_profiles_v2_<uid>` = `Record<uid, ProfileData>`，落盘为内存 LRU 快照【ProfileStore.ets:60-74】；
  内存 `LruCache(200, 5min)`【:21】。
- 语义：被查看**对象**的资料，与"查看者账号"无关（除关注状态字段 `follow` 外），因此**理论上可全局化**。
- 脏数据/旧键：键名带 `_v2_`，但代码里**没有 v1 清理**，旧键会永久驻留 Preferences（**待确认**是否为历史遗留）。
- **取消隔离影响（低）**：主要风险是 `follow` 等"我与他关系"字段串号；建议条目级区分或直接丢弃该字段。

### 2.13 `categories`（板块分类缓存）

- 全局键 `cached_categories`【CategoryStore.ets:42,56】，无版本、无 uid；内容变化才写（JSON 字符串比对【:93-98】）。
- 该数据是**论坛全局分类**（客户端仅用当前 token 拉取，代码中未见任何按账号差异的分支），是"取消隔离"最安全的域。
- 注意 `ensureCategories` 用 `generationGuard.bump()` 而非 `current()` 作为 gen 来源【:64】，属特例。

### 2.14 `ai_sessions`（AI 会话记忆）

- 信封 `schemaVersion:1`，键 `ai_sessions_<uid>`；**宽容加载** `loadTolerant`（一条坏会话不牵连其余）【AiSessionStore.ets:254-286】。
- **三重归属校验**：信封 uid【CacheEnvelopeStore.ets:72-74】+ `ownerUid` 字段【AiSession.ets:73】+ Store 内 `ownerUid`【AiSessionStore.ets:56】；
  `saveSession` 在 3 处拒绝写入（无 uid / ownerUid 不符 / 会话 ownerUid 是他号）【:163-173】。
- 上限：20 会话/账号、200 消息/会话、28 字标题、6 条 toolNotes【AiSession.ets:18,26,29,32】；
  消息裁剪与 `digestCoveredCount` 游标联动【AiSessionStore.ets:174-193】。
- 登出：只清内存，**磁盘保留**（重新登录同账号还能看到历史）【:95-104】。
- **取消隔离影响**：`ownerUid` 已是条目级字段（天然支持统一集合），但信封级 uid 校验会**整封判非法丢弃**——
  统一集合必须移除信封 uid 或改为"逐条过滤"，否则数据丢失。

### 2.15 `ai_tool_cache`（工具结果缓存）

- 信封 `schemaVersion:1`，键 `ai_tool_cache_<uid>`；条目 `ToolCacheSnapshot{key, expiresAt, result}`。
- **key 内含 uid bucket**：`toolName|uid|contextFingerprint|normalizedArgs`【ToolResultCache.ets:134-141】；
  Store 落盘与加载都用 `|uid|` 标记过滤【AiToolCacheStore.ets:140,144,187-193】。
- TTL：条目级 `expiresAt`（长 600s / 短 45s【AiToolConfig.ets:32,35】）；落盘裁剪 80 条 / 1.2M 字符【AiToolCacheStore.ets:42-45】；
  写盘节流 800ms【:48,159-165】；后台/退出前 `flush()`【:123-126；AppStore.ets:510】。
- 未登录：`anon` 桶**只活内存、不落盘**【文件头 18；:181-184】。
- **取消隔离影响（高风险）**：键里带 uid 是"缓存命中隔离"的唯一防线；去掉后 A 读过的帖子正文/私信类资料会在 B 命中
  （静默错误答案）。统一集合必须保留条目级 uid（可独立成字段，但**不能**只靠外部键）。

### 2.16 `saved_threads`（离线存档，全局）

- 目录 `filesDir/saved_threads/`，每帖 `<tid>.json`；`reload` 扫描目录重建内存并按 `savedAt` 降序【SavedThreadStore.ets:87-117】。
- **原子写**：`<tid>.json.tmp` → `renameSync` 覆盖；失败清理 tmp，旧档不破坏【:218-244】。
- **tid 白名单**：纯数字 1~16 位，防路径穿越【:38-49】。
- **无单文件 schemaVersion**：`reload` 用 `isValidTid(tid) && rawPages.length>0` 判活，旧格式/损坏文件被**跳过但不删除**
  【:102-111】——旧存档会永久占目录（每次启动扫一遍）。
- `normalizeArchive`：`savedPages` 与实际页数不一致时以实际为准；`lastLou` 缺失补 0【:126-134】。
- 导出导入：`SavedThreadExportFile{schemaVersion:2, exportedAt, threads[]}`【SavedThread.ets:54-61】；
  导入按 tid 覆盖、逐条跳过非法、批量结束后统一 bump 版本【SavedThreadStore.ets:334-390】。
- **取消隔离影响（低）**：本就全局；统一治理时注意"tid 级唯一键 + 导入覆盖"语义要保留，且导入是外部可控输入（校验不可松）。

### 2.17 `drafts` + 2.18 `draft_media`（草稿，键内嵌 uid 哈希）

- 目录 `filesDir/drafts/`、`filesDir/draft_media/`；草稿键形态（**全仓唯一用哈希做隔离**）：
  - 回复/贴条：`draft_<tid>_p<pid>_<uidHash>`；主题级：`draft_<tid>_<uidHash>`；编辑（仅回收用）：`draft_<tid>_edit_<pid>_<uidHash>`
    【ReplyManager.ets:1093-1105】；
  - 发新主题：`draft_newtopic_<fid>[_stid<stid>]_<uidHash>`【NewTopicManager.ets:538-544】；
  - `uidHash = shortHash36(uid)`（FNV-1a 32 位转 36 进制，未登录 `anon`）【DraftStore.ets:100-117】。
- **键的合法性是唯一隔离判据**：文件头明确"键是唯一的隔离维度"，并警告 `Math.abs` 陷阱会导致两 uid 撞键【DraftStore.ets:86-99】。
- 原子写 tmp+rename【:338-364】；同步 IO（编辑器构建期要同步读）【文件头 25-29】。
- 清理：`cleanupStale(7天, 每批8个, 最多4轮)`，游标跨批前进【:517-578】；`.json.tmp` 残渣单独扫【:587-604】；
  损坏草稿（media 非数组）**直接删除文件**避免每次重读【:324-327】。
- 媒体副本：`<草稿键>/<ts>_<seq>_<清洗后文件名>`【DraftMediaStore.ets:291-292】；
  **寿命绑定草稿**：孤儿即时删、有主一律豁免容量淘汰【DraftMediaStore 文件头 18-33】；上限 128MB 软限。
- **取消隔离影响（高风险）**：键去掉 uid 哈希 → 同帖/同版块的跨账号草稿直接互相覆盖（且媒体目录同名互相删）；
  改为"目录不按账号 + 条目 ownerUid"必须同时迁移**既有磁盘文件名**（否则旧草稿全部成孤儿被清理）。

### 2.19 `mphoto` / 2.20 `mphoto_upload` / 2.21 `tts_wav` / 2.22 `image_temp`（文件缓存）

- `mphoto`：`filesDir/mphoto/<urlHash>.<ext>`（hash 含 URL 长度前缀防撞【MovingPhotoCache.ets:68-78】）；
  80 文件 / 256MB 双上限，超限淘汰到一半；在用/下载中豁免【:132-142,334-341】。
- `mphoto_upload`：`cacheDir/mphoto_upload/<ts>/`，上传结束整目录删；异常残留 >600s 清、每次最多 8 个【MovingPhotoExport.ets:55-75】。
- `tts_wav`：`cacheDir/tts-<ts>-<gen>-<seq>.wav`【TtsWavFileWriter.ets:291-293】，启动异步清陈旧文件【:484-498】。
- `image_temp`：`filesDir/temp_*.{ext}` / `filesDir/share_*.{ext}`【ImageViewer.ets:297,341】，**无清理逻辑**（残留，低风险）。
- **取消隔离影响**：全部与账号无关（按 URL 哈希或时间戳），可保持现状；`image_temp` 建议纳入统一清理。

### 2.23 `webview_cookies`（ArkWeb 应用级 Cookie）

- 不是 Preferences / 文件 API 可枚举的存储，但**是持久化登录态**：`ngaPassportUid` / `ngaPassportCid` 残留会让
  "网页登录层一打开就自动登录成功"（见 `AGENTS.md` §WebViewCookie 与 `WebViewCookieUtils` 文件头）。
- 唯一清理点：`clearWebViewAuthCookies()`【WebViewCookieUtils.ets:61-66】（登出编排调用【LogoutOrchestrator.ets:40】）。
- **取消隔离影响**：它是"全局单份"登录态，与 App 内 uid 隔离**不同步**；统一账号治理时必须把它纳入"登出/切号"事务。

---

## 3. 文件系统持久化清单

| 目录 / 文件 | 绝对路径模板 | 命名规则 | 原子写 | 清理策略 | 与 Preferences 的引用关系 |
|---|---|---|---|---|---|
| 离线存档 | `filesDir/saved_threads/<tid>.json`【SavedThreadStore.ets:69,80-82】 | 纯数字 tid + `.json` | ✅ tmp + `renameSync`【:218-223】 | 用户手动删除/清空；**无 TTL、无容量上限**；坏文件跳过不删【:102-111】 | 无直接引用；`savedThreadVersion` 只是 UI 信号 |
| 草稿正文 | `filesDir/drafts/<草稿键>.json`【DraftStore.ets:231,255-257】 | `draft_[newtopic_]<数字>` +（`_p<pid>` 或 `_edit_<pid>` 或 `_stid<..>`，可无）+ `_<uidHash>` | ✅ tmp + `renameSync`【:346-353】 | mtime 7 天；`.json.tmp` 残渣回收【:587-604】；坏草稿删除【:324-327】 | 键与草稿媒体目录**同名**；键内含 uid 哈希 |
| 草稿媒体 | `filesDir/draft_media/<草稿键>/<ts>_<seq>_<清洗名>`【DraftMediaStore.ets:211,257,291-292】 | 目录=草稿键；文件=时间戳_序号_清洗名 | 单文件写（`writeBuffer`，无 tmp） | 孤儿即时删；容量超限只在孤儿里淘汰；有主豁免 | **目录名必须与草稿键一致**，否则成孤儿被回收 |
| 动态照片缓存 | `filesDir/mphoto/<urlHash>.<ext>`【MovingPhotoCache.ets:54-56,107-109】 | FNV-1a 长度前缀哈希 + 扩展名 | tmp + `renameSync`【:263】 | 80 文件 / 256MB，淘汰到一半；在用/下载中豁免 | 无 |
| 动态照片导出 | `cacheDir/mphoto_upload/<ts>/{upload.jpg,video.mp4}`【MovingPhotoExport.ets:55-61,283】 | 时间戳目录 + 固定文件名 | 直接写 | 上传后整目录删；>600s 残留清（每次 ≤8）【:72-75】 | 无 |
| TTS WAV | `cacheDir/tts-<ts>-<gen>-<seq>.wav`【TtsWavFileWriter.ets:291-293】 | 时间戳+代次+序号 | 顺序写 + 头回填 | 播放结束删；启动异步清陈旧【:484-498】 | 无 |
| 图片临时 | `filesDir/temp_<ts>.<ext>`、`filesDir/share_<ts>.<ext>`【ImageViewer.ets:297,341】 | 时间戳 | 直接写 | **无**（残留） | 无 |
| （清理集合） | `cacheDir`(EL1/EL2) + `mphoto` + `drafts` + `draft_media` + appContext `cacheDir`【SettingsPanel.ets:253-275】 | — | `removeDirRecursively`（`rmdirSync` 只删空目录，已踩坑）【:277-281；FileUtils.ets:14-16】 | "清除缓存"一键；**不覆盖** `filesDir` 根下的 `saved_threads`（离线存档） | 删后 `draftStore.reloadAfterClear()` + `draftMediaStore.reloadAfterClear()` 同步内存【:285-286】 |

> 注意：`saved_threads`（离线存档）与 `draft_media` 一样在 `filesDir` 持久区，但 **`clearCache` 不清 `saved_threads`**——
> 这是有意的（存档是用户主动保存的数据），重构统一治理时应显式写入契约文档。

---

## 4. 账号隔离现状矩阵

### 4.1 物理分键（`<prefix>_<uid>`，共 12 个键族）

| 键模板 | 前缀来源 | 是否内嵌 uid 字段 | 生成处 |
|---|---|---|---|
| `settings_<uid>` | 字面量 | 否 | SettingsStore.ets:120-122 |
| `history_<uid>` | 字面量 | 否（裸数组） | HistoryStore.ets:79-81 |
| `reading_progress_<uid>` | 字面量 | 否（裸数组） | ReadingProgressStore.ets:42-44 |
| `votes_<uid>` | 字面量 | 否（Record 键为 tid） | VoteStore.ets:42-44 |
| `pollVoted_<uid>` | 字面量 | 否 | VoteStore.ets:46-48 |
| `cached_notifications_<uid>` | `'cached_notifications'` + 信封拼接 | ✅ `uid` | NotificationStore.ets:74-78；CacheEnvelopeStore.ets:53-55 |
| `cached_activities_<uid>` | `'cached_activities'` | ✅ `uid` | FollowActivityStore.ets:93-97 |
| `tracked_threads_<uid>` | `'tracked_threads'` | ✅ `uid` | TrackedThreadStore.ets:128-132 |
| `ai_sessions_<uid>` | `'ai_sessions'` | ✅ `uid`（信封）+ 条目 `ownerUid` | AiSessionStore.ets:36,59-63 |
| `ai_tool_cache_<uid>` | `'ai_tool_cache'` | ✅ `uid`（信封）+ 条目 key 内 `\|uid\|` | AiToolCacheStore.ets:39,60-65 |
| `cached_profiles_v2_<uid>` | 字面量模板 | 否 | ProfileStore.ets:41-43 |
| `favorite_topic_membership_v1_<uid>` | `'favorite_topic_membership_v1_'` | ✅ `uid`（自定义信封） | FavoriteStore.ets:40,875-877 |

### 4.2 键内嵌 uid 的其他形态

| 形态 | 载体 | 生成处 | 说明 |
|---|---|---|---|
| FNV-1a 短哈希（36 进制） | **草稿文件名** `<草稿键>`，如 `draft_44191387_p123_1a2b3c` | ReplyManager.ets:1093-1105；NewTopicManager.ets:538-544；DraftStore.ets:100-117 | 唯一"不明文出现 uid"的隔离；`anon` 代表未登录 |
| uid bucket 片段 | **AI 工具缓存 key** `tool\|uid\|指纹\|参数` | ToolResultCache.ets:134-141 | 落盘/加载用 `'\|'+uid+'\|'` 过滤【AiToolCacheStore.ets:140,187-193】 |
| `ownerUid` 字段 | **AI 会话条目** | AiSession.ets:73；AiSessionStore.ets:163-173 | 条目级归属，防"页面生命周期长于认证切换" |
| 服务端命名空间 | **收藏夹 folder id** | FavoriteStore 全流程 | folder id 属账号级命名空间，跨账号不可复用 |

### 4.3 全局（无 uid）键

| 键 / 目录 | 位置 | 语义 |
|---|---|---|
| `auth`、`sessions` | AuthStore.ets:147,291 | 登录态（uid 在值内） |
| `nga_theme` | ThemeSettings.ets:30,136 | 主题（刻意全局） |
| `cached_categories` | CategoryStore.ets:42,56 | 板块分类（账号无关） |
| `filesDir/saved_threads/` | SavedThreadStore.ets:69 | 离线存档（账号无关，注释明确【SavedThread.ets:4】） |
| `filesDir/drafts/`、`draft_media/` | DraftStore.ets:231；DraftMediaStore.ets:211 | 目录全局、**键内**带 uid 哈希 |
| `filesDir/mphoto/`、`cacheDir/mphoto_upload/`、`cacheDir/tts-*.wav` | 见 §3 | 纯内容缓存（账号无关） |
| ArkWeb Cookie | WebViewCookieUtils.ets:61-66 | 全局单份登录态（**与 uid 隔离不同步**） |

### 4.4 一组需要特别注意的"看似隔离、实际未生效"

- `HistoryStore` / `VoteStore` / `ReadingProgressStore` 的 `persist*` 里都写了 `if (!this.uidGuard()) return`
  【HistoryStore.ets:295；VoteStore.ets:103,131,141,229；ReadingProgressStore.ets:119】，
  但三者 `init` **未注入 auth**，`uidGuard()` 恒 true【BaseStore.ets:148-150】→ 该守卫是**死代码**。
  真正的防线是"uid 由调用方作为参数传入 + generationGuard"。统一存储若改为"内部取当前 auth"，这些调用点会集体失去防线。

---

## 5. 迁移风险清单

| # | 域 / 机制 | 风险点 | 依据 | 等级 |
|---|---|---|---|---|
| R1 | `settings` 拆分 | 黑名单 / 便签 / AI API Key / 收藏版面 / `lastCheckinDate` 混在同一 JSON，全局化即串号 + 密钥泄露 | SettingsState.ets:19-96；SocialListSettings.ets:54-58,166-181 | **高** |
| R2 | `history` 已读台账 | 已读基线跨账号共享 → 主题列表"已读/有新回复"全错；500 条上限被分摊 | HistoryStore.ets:41,131-137,218-222 | **高** |
| R3 | `tracked_threads` | 跟踪任务必须用**所属账号 token** 检查；合并后 A 的任务被 B 检查，红点/基准串味 | TrackedThreadStore.ets:447-451,516-587 | **高** |
| R4 | `favorites_membership` | folder id 是账号级服务端命名空间，跨账号复用会误判"已收藏" | FavoriteStore.ets:750-794,884-907 | **高** |
| R5 | `ai_tool_cache` | 命中隔离**只依赖 key 内 `\|uid\|`**；去掉即 A 的帖子/资料正文在 B 命中（静默错误答案） | ToolResultCache.ets:125-142；AiToolCacheStore.ets:187-193 | **高** |
| R6 | `drafts` + `draft_media` | 隔离靠**文件名里的 uid 哈希**；键规则一改，旧文件全部成孤儿（媒体目录被回收、正文成无主文件） | DraftStore.ets:86-117；DraftMediaStore 文件头 18-33 | **高** |
| R7 | `auth` / 登出事务 | 登出只写空 `auth`，旧账号数据全部留在磁盘；且 `writeQueue.cancel→reset` 使"取消在途写"失效（**待确认**），可能把空数组写回旧 uid 键 | AppStore.ets:535-562；SerialQueue.ets:19-28 | **高** |
| R8 | `notifications` 严格信封 | schema 升级或单条脏数据 → 整封判非法 → **立即写空覆盖**（不可恢复） | NotificationStore.ets:275-286 | **中** |
| R9 | `activities` 严格信封 | 同上（写空覆盖） | FollowActivityStore.ets:367-384 | **中** |
| R10 | `tracked_threads` 严格信封 | 同上（写空覆盖）。三处应统一改成 `loadTolerant` 语义（`AiSessionStore` 已有先例） | TrackedThreadStore.ets:653-663 | **中** |
| R11 | `ai_sessions` 信封 uid 校验 | 条目已有 `ownerUid`，但信封级 uid 会让"混装集合"**整封判非法并丢弃**；统一集合必须改校验层级 | AiSessionStore.ets:254-265；CacheEnvelopeStore.ets:72-74 | **中** |
| R12 | `votes` / `poll_voted` | 点赞态与"已投票"跨账号共享 → 错误操作态、B 无法投票 | VoteStore.ets:50-77,193-235 | **中** |
| R13 | `reading_progress` | 跨账号跳错楼层；脏条目无字段校验（可能带进 UI） | ReadingProgressStore.ets:51-67,76-81 | **中** |
| R14 | `profiles` | `follow` 等"我与他关系"字段串号；旧 `_v1_` 键无人清理 | ProfileStore.ets:21,41-43 | **低** |
| R15 | `saved_threads` | 全局（无隔离需求）；但**无单文件版本字段 + 坏档永不删除**，统一迁移时若改格式会留下永久垃圾 | SavedThreadStore.ets:87-117 | **中** |
| R16 | `categories` / `theme` | 已全局，无需改；注意 `ensureCategories` 的 `generationGuard.bump()` 特例 | CategoryStore.ets:61-70；ThemeSettings.ets:30 | **低** |
| R17 | ArkWeb Cookie | 不在 App 存储内、与 uid 隔离不同步；切号/登出必须显式清，否则"网页登录层自动登录" | WebViewCookieUtils.ets:61-66；AGENTS.md | **中** |
| R18 | Preferences 写入失败不可观测 | `putJSON/putString` 吞异常；统一写入层若沿用此实现，迁移失败会静默 | PreferencesStore.ets:30-65 | **中** |
| R19 | 单 Preferences 文件 | 所有域共用一个 `nga_app_store` 文件；`settings_<uid>` 全量重写放大，且 Preferences 总大小无治理 | AppStore.ets:181；SettingsStore.ets:124-130 | **中** |
| R20 | 旧账号键无回收 | 登出/删号都不删 `settings_<uid>` 等 12 个键族 → Preferences 随账号数线性增长 | AppStore.ets:535-562（无任何 remove 调用） | **中** |
| R21 | `uidGuard` 死代码 | 3 个 Store 的 uidGuard 恒 true；迁移时若以为有保护会漏掉校验 | §4.4 | **中** |
| R22 | `app_storage` 内存键 | 38 个 AppStorage 键是 UI 信号，**不落盘**；统一治理时不要把"版本号键"误当持久数据迁移 | AppStorageKeys.ets:14-148 | **低** |

---

## 6. 需要设计决策的问题清单

1. **域分组**：是否把现有 `settings_<uid>` 拆成「全局设备设置」+「账号设置」两组？
   （既有先例：`theme` 全局、`categories` 全局；账号相关：黑名单、便签、收藏版面、签到日期、AI 密钥。）
2. **必须保留条目级 `ownerUid` 的域**（建议下限）：`history`、`reading_progress`、`votes`、`poll_voted`、
   `notifications`、`activities`、`tracked_threads`、`favorites_membership`、`ai_sessions`、`ai_tool_cache`。
   其中哪些可以"直接丢弃重建"（缓存类）而不迁移？（候选：`ai_tool_cache`、`activities`、`notifications`、`profiles`、`favorites_membership`）
3. **草稿与草稿媒体**：是否改为「目录不按账号 + 草稿 JSON 内 `ownerUid`」？若改，既有 `draft_*_<uidHash>.json`
   与 `draft_media/<key>/` 的迁移/兼容期如何设计（建议：保留旧键只读 + 首次打开时重写为新键 + 旧媒体目录随旧键删除）？
4. **信封 schema 版本策略**：保留"每域独立版本号"，还是统一一个全局数据版本？升级策略是
   "严格丢整封"还是"宽容跳过坏条目"（建议统一为 `loadTolerant`，并给严格的域加一次性迁移而非清空）？
5. **登出语义**：登出是否删除该账号的本地数据？现状是**从不删除**（多账号物理分键天然共存）。
   统一集合后"多账号共存"必须靠 `ownerUid` 过滤，那么"删除账号数据"是否需要一个显式入口（设置页）？
6. **切号写保护**：统一存储层是否内置"当前 uid 快照 + 写入前后校验"（替代现在每个 Store 各写一遍
   `generationGuard` / `ownerUid` / `AuthScope` 的现象）？`HistoryStore/VoteStore/ReadingProgressStore` 的
   `uidGuard` 死代码要在这一层修掉。
7. **`uidGuard` 的正确语义**：应该是"写入前 auth.uid 必须等于数据的 ownerUid"（当前 `uidGuard()` 只判"有 uid"，
   无法防"写旧 uid 键"）。是否统一成 `guardWrite(ownerUid)`？
8. **AI 工具缓存 key**：`tool|uid|指纹|参数` 是否改为"集合 + 条目字段"？（注意 key 还被 `invalidateUser`
   用 `|uid|` 标记做局部失效【ToolResultCache.ets:535-556】。）
9. **离线存档格式**：是否给单文件加 `schemaVersion`（当前只有导出文件有）？旧格式（无 `rawPages`）文件
   是删除还是保留只读？
10. **容量治理**：目前只有 history(500)/reading_progress(200)/votes(200)/notifications(200)/activities(200)/
    tracked(50)/ai_sessions(20)/tool_cache(80) 有硬上限；`settings`（黑名单/便签/收藏/AI 配置）、
    `saved_threads`、`drafts` 完全无上限。统一治理是否引入"每域条数 + 总字节"双上限与统一淘汰策略？
11. **导出导入范围**：是否把"设置 + 历史 + 收藏 + 草稿"纳入统一导出包？导出格式是否复用
    `SavedThreadExportFile` 的 `{schemaVersion, exportedAt, ...}` 风格？是否加密（凭证已有 AES-GCM 先例）？
12. **迁移框架**：是否引入"旧键读取 → 归一化 → 写新键 → 删旧键（延迟/幂等）"的统一迁移器？
    现有 AI 域的一次性回写标记（`consumeSearchMigration`）可作为模板。
13. **存储介质**：继续单 Preferences（`nga_app_store`）还是按域拆多个 Preferences 文件、或引入 `relationalStore`
    （当前 0 使用）？注意 Preferences 单键全量重写 + 无常驻事务。
14. **ArkWeb Cookie 纳入账号生命周期**：切号（非登出）是否也要清 Cookie？现状只有 `logout` 清
    【LogoutOrchestrator.ets:40】，而 `appStore.setAuth`（切号）不清——**待确认**是否构成串号。
15. **文件与键的一致性契约**：草稿键 ↔ 媒体目录、tid ↔ 存档文件、`settings` ↔ 草稿账号哈希
    这三组"命名即引用"的关系是否收敛到同一个 `StorageKeyBuilder`，避免两处各自拼串导致孤儿？

---

## 附录 A：待确认清单（代码未给出确定答案）

| # | 事项 | 现状依据 | 需要确认的问题 |
|---|---|---|---|
| A1 | 登出写队列 cancel 是否真的生效 | AppStore.ets:540-541；SerialQueue.ets:19-28 | cancel 后立即 reset 会把 `cancelled` 置回 false，已入队任务照常执行；是否已实测/是否有隐藏防护 |
| A2 | `HistoryStore/VoteStore/ReadingProgressStore` 的 uidGuard 是否有意留空 | 三者 `init` 未传 auth | 是否计划在统一层修正，还是接受现状 |
| A3 | `settings_<uid>` 无 schemaVersion 是否刻意 | SettingsStore/SettingsState 无版本字段 | 后续加版本号时如何区分"无版本=旧数据" |
| A4 | `notification/activities/tracked` 严格信封"写空覆盖"是否为预期 | 三处 `load` 失败即 `persist` 空 | 是否应改为宽容加载 + 一次性迁移 |
| A5 | `cached_profiles_v2_` 的 v1 键是否有历史包袱 | ProfileStore.ets:41-43 | 是否需要一次性清理旧键 |
| A6 | `image_temp`（`filesDir/temp_*`、`share_*`）残留是否被其它路径清理 | ImageViewer.ets:297,341 | 是否属于已接受的低风险 |
| A7 | 切号（`setAuth`）不清 ArkWeb Cookie | LogoutOrchestrator 只在 logout 清；AppStore.ets:521-533 | 是否存在"网页登录态跨账号"的真实串号案例 |
| A8 | Preferences 实际体积 / 写入耗时 | 无实测常量 | 单文件承载 12 个键族 + AI 配置时的体量（设计容量上限需要） |
| A9 | `getBrowseHistory('')` 在未登录时读 `history_` 键 | HistoryStore.ets:83-92 | 是否存在未登录进入浏览历史页的路径（当前面板仅在已登录入口可达？） |
