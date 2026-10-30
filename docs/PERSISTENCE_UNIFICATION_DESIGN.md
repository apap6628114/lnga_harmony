# 持久化数据统一治理设计（Persistence Unification）

> 状态：设计定稿（阶段 1 实施中）
> 适用范围：`entry/src/main/ets` 全部本地持久化数据（Preferences / 文件系统）
> 关联文档：[`PERSISTENCE_INVENTORY.md`](research/PERSISTENCE_INVENTORY.md)（数据域精确盘点）、
> [`SCHEDULER_RESEARCH.md`](research/SCHEDULER_RESEARCH.md)（调度能力调研）、
> [`EXPORT_IMPORT_RESEARCH.md`](research/EXPORT_IMPORT_RESEARCH.md)（导出导入链路审查）、
> [`THEME_DESIGN.md`](THEME_DESIGN.md)（主题全局化的先行案例）、
> [`DRAFT_MEDIA_PLAN.md`](research/DRAFT_MEDIA_PLAN.md)（草稿与媒体副本的存储契约）

## 0. 背景与目标

### 0.1 现状：七个存储位置、四种生命周期、零统一治理

本工程的持久化数据在过去两年里随功能自然生长，形成如下现状（精确清点见盘点文档，此处为决策相关的摘要）：

| 数据 | 存储位置 | 账号处理 | 生命周期 |
| --- | --- | --- | --- |
| 登录凭证 / 多会话表 | Preferences 键 `auth`、`sessions` | 全局（当前账号态） | 登录/退出 |
| 设置（含黑名单、屏蔽词、备注、AI 配置、AI 任务、布局、签到） | Preferences 键 `settings_<uid>` | **每账号一份** | 登出即丢内存、磁盘保留 |
| 主题 | Preferences 键 `nga_theme` | 全局 | 跨账号 |
| 板块分类缓存 | Preferences 键 `cached_categories` | 全局 | 可重建 |
| 用户资料缓存 | Preferences 键 `cached_profiles_v2_<uid>` | **每账号一份** | 可重建 |
| 通知缓存 | Preferences 键 `cached_notifications_<uid>`（信封 v3） | **每账号一份** | 服务端镜像 |
| 关注动态缓存 | Preferences 键 `cached_activities_<uid>`（信封 v2） | **每账号一份** | 服务端镜像 |
| 收藏夹成员关系 | Preferences 键 `favorite_topic_membership_v1_<uid>` | **每账号一份** | 服务端镜像 |
| 浏览历史 / 已读台账 | Preferences 键 `history_<uid>` | **每账号一份** | 用户数据 |
| 阅读进度 | Preferences 键 `reading_progress_<uid>` | **每账号一份** | 用户数据 |
| 点赞/踩、投票已投 | Preferences 键 `votes_<uid>`、`pollVoted_<uid>` | **每账号一份** | 用户数据 |
| 跟踪帖子 | Preferences 键 `tracked_threads_<uid>`（信封 v2） | **每账号一份** | 用户数据 |
| AI 会话 | Preferences 键 `ai_sessions_<uid>`（信封 v1） | **每账号一份** | 用户数据 |
| AI 工具结果缓存 | Preferences 键 `ai_tool_cache_<uid>`（信封 v1） | **每账号一份** | TTL 缓存 |
| 编辑器草稿 | 文件 `filesDir/drafts/<key>.json`（键内 uid 短哈希） | 键内哈希 | 7 天保留 |
| 草稿媒体副本 | 文件 `filesDir/draft_media/<键>/` | 随草稿键 | 随草稿 |
| 离线保存的帖子 | 文件 `filesDir/saved_threads/<tid>.json` | **全局** | 用户数据 |
| 动态照片缓存 | 文件 `filesDir/mphoto/` | 全局 | 容量上限 |
| 系统云备份 | `EntryBackupAbility` + `allowToBackupRestore: true` | 整目录 | 由系统触发 |

由此产生的具体问题：

1. **账号隔离不一致**：11 个域按 uid 分键，3 个域全局，1 个域键内哈希。用户换账号/登出再登录后，
   一部分数据消失（如浏览历史被 `reset` 清空）、一部分保留（离线存档）、一部分串味风险（草稿键内哈希）。
   「哪些数据跟着账号走」没有任何一处可以回答。
2. **键命名无命名空间、无版本**：`cached_profiles_v2_<uid>`、`favorite_topic_membership_v1_<uid>` 这类
   手工版本后缀与 `history_<uid>` 混排；schema 版本分散在各 Store 的私有常量里，没有全局真相。
3. **没有统一的启动迁移**：已有零散的"读取时兼容"（`PersistedAuth.cid` 的 `?? ''`、`SAVED_THREAD_SCHEMA_VERSION`
   的导入校验、`AiSession.normalize`、`CacheEnvelope.isValidEnvelope` 的版本拒绝），但没有任何机制回答
   「旧版本留在磁盘上的数据，这次升级后还在不在、要不要转换、用户知不知道」。
4. **导出导入各自为政**：账号凭证有加密导出（`.ngacred`）、离线存档有明文 JSON 导出，其余 15 个域没有任何
   导出能力；两者格式、版本、错误处理、UI 模式互不复用。
5. **时机驱动任务散落**：自动签到、会话前台校验、三个轮询、降级退避复验、草稿清理、工具缓存刷盘分别挂在
   `EntryAbility.onForeground`、`AppStore` 私有定时器、`PollingController`、各 Store 构造函数与 `setTimeout`
   里；没有统一的任务表、触发源、节流/退避/去重契约，也无法回答"回到前台到底跑了哪些活"。
6. **系统云备份是隐形通道**：应用已开启系统备份恢复，但 `EntryBackupAbility` 是空实现。系统恢复会把
   **旧版本**的 Preferences 与文件整目录倒回新安装的应用——这是迁移机制必须覆盖的第二条触发路径
   （第三条是用户导入）。

### 0.1.1 盘点阶段新增确认的三个隐患（`PERSISTENCE_INVENTORY.md` §5）

1. **登出从不清盘**：`clearAuth` 只写空 `auth`，旧账号的 12 个键族（`settings_<uid>` 等）永久留在
   Preferences 里，没有任何删除路径。本次改造后旧键在 30 天清理期结束时被统一清理（§5.7）。
2. **`writeQueue.cancel()` 后立即 `reset()` 使"取消在途写"疑似失效**（`SerialQueue.cancel` 置
   `cancelled=true`，`reset()` 又置回 false）：cancel 前已入队的闭包仍会执行。本次改造**不修
   SerialQueue 本身**（影响面大、现有行为未观察到数据事故），而是通过"登出后设备级域不再 reset"
   把风险面从"写空数据到旧 uid 键"缩小到只剩凭证与镜像域（见 §8.2）。
3. **三处严格信封"load 失败即写空覆盖"是潜在数据丢失点**（notifications/activities/tracked_threads）：
   已改为"读失败不写空、只清内存"（NotificationStore / FollowActivityStore；下一次成功刷新覆盖）。
   另发现 `uidGuard()` 在 history/vote/reading_progress 中是**死代码**（init 未注入 auth → 恒 true）：
   本次**保留**在 `BaseStore` 中（无调用点，未删除，避免动公共基类），文档在此标注其真实语义。

### 0.2 需求（用户提出 + 补充）

**用户提出：**

1. 取消账号隔离——本地数据不再按账号独立保存。
2. 旧数据迁移到新格式，启动时主动做一次转换检查，且**必须提醒用户**。
3. 新集合数据可导出、可导入。
4. 评估并落地"调度处理机制"，收编越来越多的"回前台等时机"任务。
5. 补全未考虑到的方案细化与优化。

**本设计补充（第 5 点的回答，逐条在后文展开）：**

- **数据域为准的治理模型**（而非"一个巨型 JSON"）：域是治理、迁移、导出、清理的最小单位。
- **账号隔离不是简单删除，而是"物理取消 + 语义分层"**：不再有 `_<uid>` 键，但对"服务端账号镜像"类数据
  用条目/信封级 `ownerUid` 保留语义正确性（详见 ADR-001），避免 A 账号的已读/已赞状态显示给 B。
- **迁移的三条触发路径**：版本升级、系统备份恢复、用户导入文件，共用同一套域级升级器。
- **迁移的用户提醒分级**：成功（安静提示）/ 部分失败（明确告警 + 可重试）/ 阻断性失败（不阻塞启动，
  退化到旧数据只读并记录）。
- **导出必须可选加密且默认建议加密**：AI 会话、浏览历史、备注属于高隐私数据；凭证域永久排除。
- **导入是"合并"而非"覆盖"**：按域声明合并策略，保证幂等与可重复导入；导入前自动生成回滚快照。
- **调度器只做应用内调度，不引入系统级后台任务**（结论见第 7.5 节，含 SDK 依据）：本应用无推送通道，
  社交数据变更在后台的价值低于耗电/审核风险；系统级能力预留扩展点而不在阶段 1 启用。
- **持久化健康的可观测性**：域版本表、体积统计、最后写入时间、迁移报告、导出/导入历史全部集中在
  数据管理页，且可通过日志域 `DOMAIN_STORE` 追踪。
- **单测策略**：调度器（注入时钟）、迁移器（内存 Preferences 假实现）、导出导入（往返一致性）、
  域合并器（幂等/冲突）全部可在 Hypium Local Test 覆盖，不依赖真机。

### 0.3 设计目标与非目标

**目标：**

- G1 任一持久化数据都能回答四个问题：存在哪、什么版本、属于谁、怎么清。
- G2 取消账号物理隔离后，所有设备级数据跨账号共享、跨启动一致。
- G3 任何格式演进都有唯一入口的迁移器，且用户可见。
- G4 任意数据域可选择性导出/导入，格式向后兼容。
- G5 时机驱动任务统一注册、统一触发、统一节流，前台行为可解释。
- G6 全部改动可通过 DevEco 编译 + Hypium Local Test 验证。

**非目标：**

- N1 不引入关系型数据库（`relationalStore`）：当前数据量级（单域 ≤ 数 MB）与访问模式（整包读写、
  无复杂查询）不值得引入 RDB 的迁移与并发成本；域清单里若未来出现"需要按条件查询"的域再评估。
- N2 不做跨设备同步/云同步：导出文件与系统备份已覆盖换机场景。
- N3 不改动网络层缓存策略、AI 上下文预算等与本主题无关的逻辑。
- N4 不引入系统级后台任务（阶段 1）；不改变 TTS 长时任务的既有实现。

## 1. 术语与总体架构

### 1.1 术语

| 术语 | 定义 |
| --- | --- |
| **数据域（DataDomain）** | 一个逻辑上不可分割的持久化数据单元。有唯一 ID、独立 schema 版本、独立存储后端、独立迁移器与合并策略。例如 `settings`、`history`、`ai_sessions`。 |
| **域信封（DomainEnvelope）** | 统一落盘结构：`{ schemaVersion, domain, updatedAt, payload }`。旧版信封（`CacheEnvelopeStore` 的 `{schemaVersion, uid, items, updatedAt}`）在迁移期被转换为新结构。 |
| **域注册表（PersistenceCatalog）** | 全部域元数据的唯一真相（静态表）。启动自检、迁移枚举、导出勾选、清空入口、体积统计都从它派生。 |
| **持久化中心（PersistenceHub）** | 编排层：持有 `PreferencesStore`、`SerialQueue`、域注册表，负责启动加载、迁移、flush、导出导入、清空。各 Store 通过它读写自己的域。 |
| **迁移（Migration）** | 把磁盘上的旧格式/旧键数据转换为当前域格式的一次幂等操作。由 `MigrationEngine` 编排、`DomainMigrator` 实现。 |
| **存储后端（StorageBackend）** | 域的物理载体：`PreferencesBackend`（键值）或 `JsonFileBackend`（目录+文件）。 |
| **scope（作用域）** | 域的账号语义：`DEVICE`（设备级，与账号无关）、`ACCOUNT_MIRROR`（服务端账号状态的本地镜像，保留 owner 语义）、`SECRET`（凭证，不导出）。 |
| **owner（归属）** | `ACCOUNT_MIRROR` 域条目上的账号标识；用于切号后按当前账号过滤，不用于物理分键。 |

### 1.2 分层架构

```
┌────────────────────────────────────────────────────────────────────┐
│ UI 层                                                               │
│  SettingsPanel（数据管理入口）  DataManagementPanel（新）            │
│  MigrationNoticeDialog（启动提醒）  FavoriteSavedPanel（沿用存档导入） │
└───────────────┬────────────────────────────────────────────────────┘
                │ 方法调用 / AppStorage 版本键
┌───────────────▼────────────────────────────────────────────────────┐
│ AppStore（Facade + 生命周期编排）                                    │
│  init / loadUserData(→loadDeviceData) / setAuth / clearAuth         │
│  setForegroundActive / flushAll / 迁移结果发布                      │
└───────┬───────────────────────────────────┬────────────────────────┘
        │                                   │
┌───────▼──────────────────────┐   ┌────────▼───────────────────────┐
│ PersistenceHub（统一治理中心） │   │ AppScheduler（统一调度器）       │
│  ├ PersistenceCatalog        │   │  ├ 任务注册表（静态）            │
│  ├ StorageBackend 路由        │   │  ├ 触发源分发                    │
│  ├ DomainRegistry 实例表      │   │  ├ 节流/退避/单飞/优先级         │
│  ├ MigrationEngine            │   │  └ 生命周期接入（EntryAbility）  │
│  ├ DataTransferService        │   └────────────────────────────────┘
│  └ DomainHealth（体积/时间）  │
└───────┬──────────────────────┘
        │ load/persist/clear/export/import（DomainAdapter 契约）
┌───────▼────────────────────────────────────────────────────────────┐
│ 各领域 Store（15 个）                                               │
│  SettingsStore / HistoryStore / ReadingProgressStore / VoteStore     │
│  NotificationStore / FollowActivityStore / FavoriteStore             │
│  TrackedThreadStore / AiSessionStore / AiToolCacheStore             │
│  CategoryStore / ProfileStore / SavedThreadStore / DraftStore        │
└────────────────────────────────────────────────────────────────────┘
```

### 1.3 设计原则

1. **单一真相**：域清单只有 `PersistenceCatalog` 一份；任何"新增持久化"必须先在注册表登记，
   否则 CI 审查不通过（评审清单第 1 条）。
2. **读写分离的容错等级**：读一律宽容（坏条目跳过、版本不匹配整体降级但不崩溃）；写一律严格
   （原子替换、失败不改旧值）。
3. **迁移单向且幂等**：只向前升级，每一步可重复执行且结果一致；不写"降级"逻辑（回滚靠导出文件）。
4. **账号语义在数据里，不在键里**：键只表达"是什么"，归属由 payload 内的 owner 字段表达。
5. **派生缓存可丢弃**：凡能从服务端重建的域（通知/动态/资料/分类/收藏成员关系/工具缓存），
   迁移与导入策略一律"允许丢弃、不允许阻塞"。
6. **UI 只消费快照**：页面不直接读 Preferences/文件；所有数据经 Store 方法或 AppStorage 版本键。
7. **可观测**：每次迁移/导入/导出/调度执行都产出一条结构化日志 + 一条可查询状态，禁止静默失败。
8. **不改语义的改造优先**：Phase 1/2 的 store 改造保持 public 方法签名（`uid` 参数保留但语义弱化），
   避免波及 30+ 页面的调用点，把风险收敛在存储层。

## 2. 数据域模型

### 2.1 域元数据

`PersistenceCatalog` 以静态数组登记全部域，每项为 `DomainSpec` 的实例（ArkTS 不支持对象字面量类型，
统一用类）：

```ts
/** 存储介质。 */
export enum StorageKind { PREFERENCES = 0, JSON_FILES = 1 }

/** 账号语义。 */
export enum DomainScope {
  /** 设备级：与账号无关，登出/切号不重置。 */
  DEVICE = 0,
  /** 服务端账号状态的本地镜像：物理唯一，条目带 ownerUid，切号后按当前账号过滤/重建。 */
  ACCOUNT_MIRROR = 1,
  /** 凭证：不导出、不参与统一导入、单独加密处理。 */
  SECRET = 2,
}

/** 导出策略。 */
export enum ExportPolicy {
  /** 默认参与导出（可被用户取消勾选）。 */
  INCLUDE = 0,
  /** 默认不导出（缓存类，可被用户手动勾选）。 */
  OPTIONAL = 1,
  /** 永久排除（凭证）。 */
  NEVER = 2,
}

/** 导入策略。 */（实际枚举有 6 个值）
export enum ImportPolicy {
  MERGE_FIELDS = 0,   // 字段级合并（theme 等）
  MERGE_BY_KEY = 1,   // 按业务键去重合并，冲突取较新
  REPLACE_BY_KEY = 2, // 按业务键覆盖（草稿/存档）
  SKIP = 3,           // 跳过（缓存/镜像，导入无意义）
  SPECIAL = 4,        // 由域自行实现（settings 数组并集等）
  NEVER = 5,          // 硬拒绝（凭证/meta）
}

/** 域元数据（注册表项，实际定义见 PersistenceTypes.ets）。 */
export class DomainSpec {
  id: string = ''
  label: string = ''
  storage: StorageKind = StorageKind.PREFERENCES
  /** Preferences 键（不含 `v2.` 命名空间前缀；`fullKey()` 拼接）；文件域为空串。 */
  key: string = ''
  /** 文件域目录名：正常以 `/` 结尾落在 `filesDir/v2/<dirName>`；`!` 前缀表示沿用旧路径。 */
  dirName: string = ''
  schemaVersion: number = 1
  scope: DomainScope = DomainScope.DEVICE
  exportPolicy: ExportPolicy = ExportPolicy.INCLUDE
  importPolicy: ImportPolicy = ImportPolicy.MERGE_BY_KEY
  clearable: boolean = true       // 是否参与「清空本地数据」
  rebuildable: boolean = false    // 是否可从服务端重建（缓存类）
  avgItemBytes: number = 512      // 体积估算用
  note: string = ''               // 说明（导出清单/数据管理页）
  rawPayload: boolean = false     // true=RAW 裸载荷；false=统一信封（见 §4.1）
}
```

### 2.2 存储后端选择

| 后端 | 适用 | 现有 API | 约束 |
| --- | --- | --- | --- |
| `PreferencesBackend` | 结构化、单包 ≤ 数 MB、需频繁小写 | `preferences.Preferences`（单值上限 **16MB**，键上限 1024B，SDK 声明 `@ohos.data.preferences.d.ts` L64/L73） | 整包 JSON 读写；无事务 |
| `JsonFileBackend` | 大块数据、天然按条分文件（存档、草稿）、需要目录浏览/容量统计 | `fileIo`（原子写：临时文件+rename） | 同步 API 会阻塞主线程，须分批/延后 |

**决策 Q1：为什么不用关系型数据库？** 见非目标 N1。补充理由：Preferences 单值 16MB 对本项目最大域
（AI 会话全量约 1–3MB、工具缓存限 1.2M 字符）有足够余量；RDB 引入后每个域都要写 SQL 与迁移脚本，
与"降低维护成本"的目标相反。

**决策 Q2：统一后是否把所有域塞进一个键？** 不。Preferences 的整包写入会随总量增长放大写放大
（改一个设置要重写全部数据），且单键 16MB 上限会成为全局炸弹。统一治理的是**元数据与生命周期**，
不是物理合并。

### 2.3 全量域清单

> 精确的字段结构、写入方、上限见盘点文档；此表是治理口径的唯一真相，实现以
> `entry/src/main/ets/common/persistence/PersistenceCatalog.ets` 为准。

| # | 域 ID | 新版键 / 目录 | 介质 | scope | schema | 导出 | 导入策略 | 登出行为 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `auth` | `v2.auth` | Pref | SECRET | 1 | 永不 | 拒绝 | 清空（当前态） |
| 2 | `sessions` | `v2.sessions` | Pref | SECRET | 1 | 永不 | 拒绝 | 保留（多会话表） |
| 3 | `settings` | `v2.settings` | Pref | DEVICE | 1 | 默认 | 字段合并 | 保留并重载 |
| 4 | `theme` | `v2.theme` | Pref | DEVICE | 1 | 默认 | 覆盖 | 保留 |
| 5 | `categories` | `v2.categories` | Pref | DEVICE | 1 | 可选 | 跳过 | 保留 |
| 6 | `profiles` | `v2.profiles` | Pref | DEVICE | 1 | 可选 | 跳过 | 保留 |
| 7 | `notifications` | `v2.notifications` | Pref | ACCOUNT_MIRROR | 1 | 可选 | 跳过 | 清内存、重载镜像 |
| 8 | `activities` | `v2.activities` | Pref | ACCOUNT_MIRROR | 1 | 可选 | 跳过 | 清内存、重载镜像 |
| 9 | `favorite_membership` | `v2.favorite_membership` | Pref | ACCOUNT_MIRROR | 1 | 可选 | 跳过 | 清内存、重载镜像 |
| 10 | `history` | `v2.history` | Pref | DEVICE | 1 | 默认 | 按键去重合并 | 保留并重载 |
| 11 | `reading_progress` | `v2.reading_progress` | Pref | DEVICE | 1 | 默认 | 按键去重合并 | 保留并重载 |
| 12 | `votes` | `v2.votes` | Pref | DEVICE | 1 | 默认 | 按键去重合并 | 保留并重载 |
| 13 | `poll_voted` | `v2.poll_voted` | Pref | DEVICE | 1 | 默认 | 按键去重合并 | 保留并重载 |
| 14 | `tracked_threads` | `v2.tracked_threads` | Pref | DEVICE | 1 | 默认 | 按键去重合并 | 保留并重载 |
| 15 | `ai_sessions` | `v2.ai_sessions` | Pref | DEVICE | 1 | 可选（隐私） | 按键去重合并 | 保留并重载 |
| 16 | `ai_tool_cache` | `v2.ai_tool_cache` | Pref | DEVICE | 1 | 可选 | 跳过 | 保留（TTL 自净） |
| 17 | `drafts` | `v2/drafts/` | Files | DEVICE | 1 | 默认 | 按键覆盖 | 保留 |
| 18 | `draft_media` | `draft_media/`（沿用） | Files | DEVICE | — | 永不（不可移植） | 跳过 | 保留 |
| 19 | `saved_threads` | `v2/saved_threads/` | Files | DEVICE | 1 | 默认 | 按 tid 覆盖 | 保留 |
| 20 | `moving_photo_cache` | `mphoto/`（沿用） | Files | DEVICE | — | 永不（可重建） | 跳过 | 保留 |
| 21 | `meta` | `v2.meta` | Pref | DEVICE | 1 | 永不 | 拒绝 | 保留 |

**域数：21。** scope 实际分布：**DEVICE 15**（settings/theme/categories/profiles/history/
reading_progress/votes/poll_voted/tracked_threads/ai_sessions/ai_tool_cache/drafts/draft_media/
saved_threads/moving_photo_cache/meta 中的可清空业务域 + meta 自身，见 Catalog 为准）、
**ACCOUNT_MIRROR 3**（notifications/activities/favorite_membership）、**SECRET 2**（auth/sessions）。
早期草案的"物理隔离 14 + 全局 3"分类已被"取消 uid 物理隔离"取代（全部设备级域不再按 uid 分键）。

**治理边界（未纳入 Catalog 的持久化面，独立复核要求说明）**：
- `cacheDir` 下的临时产物（`mphoto_upload`、`tts_wav`、`image_temp` 等）：可重建缓存，由各功能自己清理，
  不参与迁移/导出/「清空本地数据」（由设置页「清除缓存」入口覆盖）；
- **ArkWeb 应用级 Cookie**（`webview_cookies` 等）：由 `WebViewCookieUtils` 的登录/登出契约管理，
  属系统 Cookie 存储而非本应用的 Preferences 数据域，**刻意不纳入「清空本地数据」**——否则会静默退出
  网页登录态（与 app token 是两套凭证）；
- **系统云备份**（`EntryBackupAbility` + `allowToBackupRestore: true`）：整目录快照通道，不在任何域的
  治理口径内；迁移检测把它当作"旧版本数据来源"处理（§5.2 P2 路径）。

### 2.4 域的职责边界

域只负责"我这份数据的序列化形态"，不负责：

- 什么时候加载（由 AppStore/Hub 编排）；
- 迁移前是什么样（由 `DomainMigrator` 描述）；
- 导出的文件格式（由 `DataTransferService` 封装）；
- 跨域一致性（例如收藏成员关系与收藏列表的关联，仍由 FavoriteStore 自己维护）。

实现上，每个域对应一个 `DomainAdapter`（可以是 Store 自己实现接口，也可以是 Hub 侧适配器）：

```ts
/** 域适配器：由各 Store 实现或由 Hub 侧包装。全部方法必须容错。 */
export interface DomainAdapter {
  /** 域 ID（与 DomainSpec.id 一致）。 */
  readonly domainId: string
  /** 从后端读出当前值并装入内存（幂等；已加载时可返回缓存）。 */
  load(): Promise<void>
  /** 把内存快照落到后端（经 Hub 的写队列；失败只记日志）。 */
  persist(): Promise<void>
  /** 导出当前内存快照（返回 JSON 可序列化对象）。 */
  exportPayload(): Object
  /** 导入一个 payload（实现按 ImportPolicy 合并）。返回实际变更条数。 */
  importPayload(payload: Object): Promise<number>
  /** 清空该域（内存 + 磁盘）。 */
  clear(): Promise<void>
}
```

> 设计说明：把适配器做成接口而不是改造所有 Store 继承统一基类，是为了让 **Phase 1 可以零风险接入**
> （Hub 侧写薄适配器，Store 不改），Phase 2 再逐步把 Store 的方法改成官方实现。ArkTS 无结构化类型，
> 接口实现需显式 `implements`，因此"薄适配器"是独立类。

## 3. 取消账号隔离（ADR-001）

### 3.1 决策

**ADR-001：取消持久化数据的物理账号隔离。** 具体含义：

1. 不再存在以 `_<uid>` 结尾的 Preferences 键；所有域使用 §3.2 的全局键。
2. 设备级域（`DEVICE`）：与账号完全解耦——登出不清空、切号不重载、未登录可读写。
3. 账号镜像域（`ACCOUNT_MIRROR`）：物理上仍单份，但信封内保存 `ownerUid`；当前账号与 owner 不一致时，
   该域在内存中视为空并重新从服务端拉取（磁盘上允许保留最后一份快照，不串号展示）。
4. 凭证域（`SECRET`）：不参与本决策（仍按当前会话保存）。
5. 导出文件不带 uid 依赖：同一份导出可在任意账号/未登录状态导入。

### 3.2 键命名规范

```
v2.<domainId>            Preferences 键（例：v2.settings、v2.history）
filesDir/v2/<dirName>/   JSON 文件域（例：filesDir/v2/drafts/、filesDir/v2/saved_threads/）
```

规则：

- 前缀 `v2.` 是**命名空间 + 数据版本锚点**，与 `dataVersion=2` 对齐；未来跨代升级用 `v3.`（不原地改格式，
  保证旧版本 App 回滚时读不到新键也不会误解析）。
- 点号分隔而非下划线：现有键大量使用下划线拼接 uid，点号在视觉上把"命名空间"与"域 ID"分开。
- 域 ID 使用小写下划线（与代码常量、导出 JSON 字段一致）。
- **禁止**任何键再包含 uid、token、时间戳（时间戳属于 payload，不属于键）。
- 键总长必须 < 1024B（SDK 约束），当前最长 `v2.favorite_membership` = 21B，余量充足。

### 3.3 账号语义域的软隔离

为什么不能"全部设备级"：`ACCOUNT_MIRROR` 三域的数据含义是"某个账号在服务端的状态"。
以通知缓存为例，A 账号的未读通知若在 B 账号下展示，点进去会以 B 的身份跳转——这不是隐私问题而是
**事实性错误**。它们的共同特征是：**能从服务端重建**，因此"切号即丢"是可接受的代价。

| 域 | 软隔离实现 | 切号后的行为 |
| --- | --- | --- |
| `notifications` | 信封内 `ownerUid`；加载时 owner≠当前 uid 判非法 → 内存置空 → 下一次轮询重建 | 旧快照保留在磁盘但不展示；新账号轮询成功后覆盖 |
| `activities` | 同上 | 同上 |
| `favorite_membership` | 同上 | 同上 |

而"用户数据"类域（历史/进度/投票/跟踪/AI 会话/草稿/存档）**不分账号**：同一设备同一人的数据，
用户明确要求取消隔离。风险与取舍见 §3.5。

三个待决点的裁决（写进 ADR，避免后续反复）：

- **投票记录**（`votes`、`poll_voted`）：属于"用户数据"而非"服务端镜像"，但点赞状态是**账号行为**。
  裁决：**设备级共享**（按用户要求取消隔离），接受"换号后看到自己另一账号的点赞高亮"的语义偏差——
  NGA 帖子详情接口在打开帖子时会返回当前账号的真实点赞态并覆盖本地记录，偏差只存在于首帧。
  **已知风险（独立复核提出，未改代码）**：若投票帖入口依据 `poll_voted` 判定"已投"并隐藏/禁用投票，
  B 账号可能无法投票；该交互依赖 `ThreadPanel` 的投票 UI 行为，需真机验证（列在 §13.3 遗留）。
- **AI 会话**：设备级共享。会话内容可能含账号隐私（私信内容被引用进对话），但用户明确要求取消隔离，
  且数据仅本机可见。措施：导出默认不勾选（`ExportPolicy.OPTIONAL`）；迁移时清空每条 `ownerUid`
  字段，避免导入后因归属校验被丢弃。
- **草稿**：设备级共享。**这是本决策中风险最高的一处**（马甲场景下可能把 A 的草稿发到 B 的账号），
  措施：草稿键保留 `draftUidPart(uid)` 生成的哈希段（形态不变，只是不再改变文件位置）。
  **跨账号一次性提示未实现**（§3.3 原计划的"编辑器顶部提示"未落地，见 §13.3 遗留）。

### 3.4 生命周期语义变化

| 动作 | 改造前 | 改造后 |
| --- | --- | --- |
| 冷启动（有凭证） | 加载当前 uid 的 15 个域 | 加载全部 21 个域（设备级 + 当前账号镜像） |
| 冷启动（无凭证） | 只加载主题/分类/存档/草稿 | 加载全部设备级域；镜像域为空 |
| 登录成功 | `loadUserData()` 加载 11 个 uid 域 | 只重载镜像域（3 个）；设备级域数据已在内存 |
| 退出登录 | `clearAuth()` 里 reset 15 个 Store | 只清凭证 + 镜像域 + AI/社交运行态；**设备级域保留并保持可用** |
| 切换账号（A→B） | 全部 uid 域重新加载 | 只重载镜像域；设备级域不重载（同一份数据） |
| 未登录使用 | 历史/进度/投票/AI 全局不可用（uid 为空直接返回） | 全部设备级域可用（含浏览历史、阅读进度、AI 会话、草稿） |

**这条改造的最大用户可见收益**：未登录状态下的浏览历史、阅读进度、AI 对话、草稿不再"读写静默失败"。

### 3.5 风险与例外

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 多账号用户数据合并（历史/进度/投票/会话） | 换号后看到"另一个号"的记录 | 产品决策（用户确认接受）；导出文件可用于拆分备份；文档明确"本地数据 = 设备数据" |
| 草稿跨账号 | 马甲误发 | §3.3 的一次性提示（Phase 3） |
| 通知镜像串号 | 展示错误账号的通知 | `ownerUid` 校验 + 切号清内存 |
| 收藏成员关系串号 | 收藏按钮状态错误 | `ownerUid` 校验 + 切号重载 |
| 旧数据归属丢失 | 迁移时无法判断多个 `_<uid>` 键属于哪个账号 | 迁移规则见 §5.4：优先当前登录 uid；未登录时按 `updatedAt` 最新；全部合并（不是丢弃） |
| 回滚到旧版本 App | 旧 App 读不到 `v2.` 键，表现为"数据全丢" | 迁移完成后**保留旧键 30 天**（不立即删除），旧版本回滚仍可读；30 天后由维护任务清理（§5.7） |

## 4. 统一存储层

### 4.1 域载荷格式（RAW / ENVELOPE 双模式）

`DomainSpec.rawPayload` 决定键下写什么：

**ENVELOPE（`rawPayload=false`）**——通知 / 动态 / 收藏关系 / 跟踪 / AI 会话 / AI 工具缓存：

```json
{
  "schemaVersion": 1,
  "domain": "notifications",
  "updatedAt": 1730000000000,
  "ownerUid": "12345",
  "payload": { "items": [] }
}
```

- `schemaVersion`：域格式版本，由 `DomainSpec.schemaVersion` 提供；读取时**高于当前一律拒绝**，
  旧版本由迁移器升级（不在读路径做升级）；
- `domain`：域 ID，用于**键/内容错配自检**；
- `updatedAt`：最后一次成功写入时间；
- `ownerUid`：仅 `ACCOUNT_MIRROR` 域使用（Store 层负责归属校验），其余为空串；
- `payload`：域自定义结构（目前信封域统一为 `{items: T[]}` / `{favoredFolderIds, knownFolderIds}`）。

**RAW（`rawPayload=true`，存量域默认）**——settings/theme/categories/profiles/history/reading_progress/
votes/poll_voted/auth/sessions：

```json
{ "fontSize": 15, "blacklist": [], "...": "业务对象原样" }
```

无信封、无版本字段。这样 15 个既有 Store **只换键、不动载荷结构**即可接入；格式演进由启动迁移器
统一完成（§5），读取路径不做版本协商。

文件域不套信封（保持"一文件一条"的可浏览性）；版本由目录（`v2/<dir>/`）与逐文件结构校验保证
（`SavedThread` 无版本字段，靠 `tid`/`rawPages` 校验；`EditorDraft` 靠 `key` 校验）。

### 4.2 读路径（宽容优先）

```
Hub.readPayload(spec)          // 仅 Preferences 域；文件域由 JsonFileBackend 逐文件读
  ├ 无键 → null（空域，不写盘）
  ├ JSON.parse 失败 → null + DomainHealth 记录（不抛错）
  ├ RAW 域 → 原样返回解析结果（版本由迁移器负责）
  └ ENVELOPE 域 → 校验 domain 一致、schemaVersion <= 当前、取 payload
                 （ownerUid 归属校验在 Store 层，见 CacheEnvelopeStore）
```

三条硬规则：

1. **启动关键路径不得因单个域读取失败而抛错**。`AppStore.init` 的异常会让 Index 停在"应用初始化失败"，
   历史上 `HistoryStore.rebuildReadBaselines` 的防御性读取就是为此而写；Hub 将把这条纪律固化为框架行为。
2. **`schemaVersion > 当前` 一律不解析**：跨版本降级（用户装了内测版又回退）时宁可空域，不可误读。
3. **坏条目跳过而非整包丢弃**：`AI 会话`、`草稿` 等"丢失代价高"的域必须逐条校验；
   `通知`/`动态` 等可重建域允许整包丢弃（现网已有该行为，保持）。

### 4.3 写路径（分两条，互不双写）

**日常写入（Store → Preferences）**——沿用既有机制，不经 Hub：

```
Store.persist()
  → writeQueue.enqueue(() => store.putJSON(key, snapshot))   // 快照在入队前生成
  → store.scheduleFlush()                                    // 500ms 合并刷盘
镜像域：CacheEnvelopeStore/FavoriteStore 写统一信封（ownerUid）
```

**治理写入（Hub → Preferences/文件）**——仅迁移、导入、撤销、清空：

```
Hub.writePayload(spec, payload, ownerUid, flush)
  → PreferencesBackend.writeRaw：先写 <key>.pending 并刷盘 → 再写正式键 → 删 pending
  →（文件域）JsonFileBackend.writeFileAtomic：临时文件 + rename
```

契约：

- **不双写**：日常路径只由 Store 负责，治理路径只由 Hub 负责；两者不交叉（§8.4 的取舍）。
- **快照在入队前生成**（现有 `VoteStore.markPollVoted`、`CacheEnvelopeStore.persist` 已如此，固化为纪律）。
- **flush 分级**：凭证/迁移完成/导入结果立即 flush；普通写入 500ms 合并。
- **后台必 flush**：`EntryAbility.onBackground` → `AppStore.flushAll()`（含 `persistenceHub.flush()`）。
- **写失败不抛业务异常**：记录日志 + 域健康状态置 `writeFailed`，下次成功写入时清除。

### 4.4 容量与限额

| 约束 | 值 | 来源 / 依据 |
| --- | --- | --- |
| Preferences 单键长度 | 1024 B | SDK `MAX_KEY_LENGTH`（`@ohos.data.preferences.d.ts` L64） |
| Preferences 单值长度 | 16 MB | SDK `MAX_VALUE_LENGTH`（同文件 L73） |
| 单域体积告警阈值 | 4 MB | 本设计（Hub 健康检查）；超过则日志 warn + 数据管理页红字 |
| 通知缓存条数 | 200 | 现有 `MAX_CACHED_NOTIFICATIONS` |
| 关注动态缓存条数 | 200 | 现有 `MAX_CACHED_ACTIVITIES` |
| 跟踪任务条数 | 见 `TRACK_MAX_COUNT` | 现有 |
| AI 会话个数/条数 | 20 / 见 `MAX_AI_SESSION_MESSAGES` | 现有 |
| AI 工具缓存 | 80 条 / 1.2M 字符 | 现有 |
| 浏览历史 | 500 条 | 现有 `HISTORY_MAX_COUNT` |
| 阅读进度 | 200 条 | 现有 `PROGRESS_MAX_COUNT` |
| 投票记录 | 200 条 | 现有 `VOTE_MAX_ENTRIES` |
| 草稿保留 | 7 天 | 现有 `DRAFT_RETENTION_DAYS` |
| 导出文件体积上限 | 64 MB | 本设计（导入时校验，防超大/恶意文件） |

### 4.5 损坏与自愈

- 每次读失败/跳条数记入 `DomainHealth`（内存态）：`lastError`、`droppedItems`、`lastWriteFailed`。
  **注**：日常读写路径（各 Store 直写 Preferences）只有治理路径（迁移/导入/导出）经过 Hub，
  因此该健康数据主要反映治理路径；文档早期"所有 Store 读写都经 Hub 上报健康"的设计未采用（§8.4）。
- 数据管理页展示"数据健康"区块：异常域高亮（「修复」按钮未实现，见 §13.3 遗留）。
- 迁移器与导入器在写盘前**先写临时键**（`v2.<domain>.pending`）→ 校验写成功 → `put` 正式键 → `delete` 临时键；
  进程在中间被杀时，下次启动检测到 pending 键则清理（丢弃半截数据，正式键仍是旧值）。
- **写后读回校验**：`PreferencesStore.putString` 内部吞掉异常、永不抛错，因此治理写入在写完后必须
  `getString` 读回比对，不一致即判定失败（否则导入/撤销会出现"报成功但没写盘"）。

> 为什么不用"临时文件 + rename"：Preferences 没有 rename 原语，只能靠双键 + 时序保证；
> 双键方案的最坏结果是"新数据未生效"，而不会出现"旧数据被截断"。

## 5. 迁移（Migration）

### 5.1 版本模型

两个版本号，职责严格分开：

| 版本 | 字段 | 位置 | 语义 |
| --- | --- | --- | --- |
| **数据版本** `dataVersion` | `v2.meta` 的 `dataVersion` | Preferences | 整套本地数据的代际（当前 = 2）。只在**跨代**升级时递增（如未来 `v3`），由迁移器整体编排。 |
| **域 schema 版本** `schemaVersion` | 各域信封 | 域内 | 单域格式演进。由域自己的升级函数处理，与全局迁移解耦。 |

```json
// v2.meta（实际结构，由 PersistenceMetaStore 反序列化）
{
  "dataVersion": 2,
  "createdAt": 1730000000000,
  "migratedAt": 1730000000000,
  "appVersionName": "1.2.0",
  "appVersionCode": 1020000,
  "migration": {
    "status": "completed",                    // completed | partial | failed | not-required | unknown
    "fromDataVersion": 1,
    "startedAt": 1730000000000,
    "finishedAt": 1730000000000,
    "domains": [                              // 逐域结果（取代草案的 finishedDomains/failedDomains）
      { "domain": "settings", "status": "migrated", "items": 1, "reason": "" },
      { "domain": "notifications", "status": "skipped", "items": 0, "reason": "未登录：..." }
    ],
    "legacyKeys": ["settings_12345", "history_12345"],
    "legacyCleanupAt": 1740000000000          // 注意是 At 不是 After
  }
}
```

> `dataVersion` 与 `formatVersion`（导出文件）不是一回事：前者描述"磁盘上的数据"，后者描述"导出容器"。
> 两者都在 `PersistenceCatalog` 里有唯一常量。

### 5.2 三条触发路径

迁移不是"升级才需要"的一次性动作，而是**数据来源不可信时的一致性检查**：

| 触发路径 | 场景 | 检测信号 | 处理 |
| --- | --- | --- | --- |
| **P1 版本升级** | 用户从旧版本 App 升级 | `v2.meta` 缺失，但存在旧键/旧目录 | 全量迁移（枚举旧键 + 文件目录） |
| **P2 系统备份恢复** | 用户换机/恢复出厂后从系统云备份恢复 | 同 P1（备份内容是旧版本数据目录）；额外信号：`v2.meta.migratedAt` 早于 `createdAt` 或 appVersionCode 倒退 | 同 P1；额外校验文件目录（存档/草稿）的版本 |
| **P3 用户导入** | 导入旧格式导出文件（`.ngabackup` v1 或旧存档 JSON） | 文件头 `formatVersion` / `dataVersion` 低于当前 | 导入器内逐域升级（复用 P1 的域升级器），失败回滚 |

P2 的补充说明：应用已开启 `allowToBackupRestore: true` 且 `EntryBackupAbility` 为空实现，系统会按
"整目录快照"恢复。因此恢复后的磁盘状态等价于"旧版本 App 的数据目录"，P1 的迁移器天然覆盖。
**不需要在 `onRestore` 里写逻辑**——但要在文档与发布说明中明确：恢复后首次启动会触发迁移提醒。

### 5.3 启动时序（关键路径）

```
EntryAbility.onCreate
  └ appStore.init(context)
      ├ 1. hub.init(context)                  ← 打开 Preferences（nga_app_store）
      │     └ 检测半截写入：清理 v2.<domain>.pending
      ├ 2. migration.check()                   ← 只读检测（不写）
      │     ├ 读 v2.meta
      │     ├ 无 meta && 无旧数据 → dataVersion 直接写 2（首次安装），跳过迁移
      │     ├ 无 meta && 有旧数据 → plan = 全量迁移清单
      │     └ 有 meta 且 migration.status != completed → plan = 剩余域
      ├ 3. migration.run(plan)                 ← 有界预算 3s；逐域 try/catch
      │     ├ 每域：读旧键 → 转换 → 写新键 → 校验读回 → 标记完成
      │     ├ 全部完成 → 写 meta（status=completed + legacyCleanupAfter）
      │     ├ 有失败 → 写 meta（status=partial）+ 记录失败域
      │     └ 发布 migrationReport（AppStorage）
      ├ 4. hub.loadAll()                       ← 各域读新键装入内存
      │     └ 域加载失败 → 空域 + DomainHealth 记录（不抛）
      ├ 5. authStore.init / 视登录态加载镜像域
      └ 6. initialized = true → publish + scheduler.notify(STARTUP)
依赖：EntryAbility.onWindowStageCreate 之后页面渲染；Index 已按 isInitializationFinished 轮询等待，
     迁移耗时被现有 loading 态自然吸收，无需新增启动阻塞逻辑。
```

**预算与降级**：迁移只有**总预算 3000ms**（`MIGRATION_BUDGET_MS`），没有"每域 800ms"（该常量已移除）；
文件域在逐文件循环中检查同一 deadline。超时未完成的域标记 `DEFERRED`，下次启动继续（不打扰用户）。

### 5.4 每域迁移映射（以 `DomainMigrators` 实际实现为准）

迁移器以"**旧键模式 → 新域**"表格驱动（`LEGACY_RULES` 数组，精确键在前、前缀键在后）：

| 旧键模式 | 新域 | 实际转换规则 |
| --- | --- | --- |
| `auth` | `auth`（SECRET） | 原样搬迁（RAW，不套信封） |
| `sessions` | `sessions`（SECRET） | 原样搬迁（旧格式 `Array<[token, session]>` 保留） |
| `settings_<uid>` ×N | `settings` | **取当前登录 uid 那一份**；无匹配时：仅一份则用之，**多份则跳过迁移**（不能把别人的设置含 AI Key/备注/黑名单迁给之后登录的账号）。不做字段级合并 |
| `nga_theme` | `theme` | 原样复制（RAW，无信封、无 `updatedAt` 包装） |
| `cached_categories` | `categories` | 原样复制数组（RAW） |
| `cached_profiles_v2_<uid>` ×N | `profiles` | 多份 `Record<uid, ProfileData>` 合并（同名键后者覆盖） |
| `cached_notifications_<uid>`（旧信封 v3） | `notifications` | **只合并当前账号 uid 的旧键**（其它 uid 跳过）→ 按 `notificationId` 去重、上限 200；Hub 写统一信封 `ownerUid = 当前会话 uid`；未登录或无匹配 → SKIPPED（不写新键，旧键保留待登录后重试，杜绝跨账号串号） |
| `cached_activities_<uid>`（旧信封 v2） | `activities` | 同上（key=`id`，上限 200） |
| `favorite_topic_membership_v1_<uid>` | `favorite_membership` | 只取当前 uid 那份；无匹配 → SKIPPED（账号镜像，不 fallback 到他人缓存）；`{favoredFolderIds, knownFolderIds}` 作为信封 payload |
| `history_<uid>` ×N | `history` | 多份合并：按 `tid` 去重取 `ts` 较新，按 ts 降序截断 500 |
| `reading_progress_<uid>` ×N | `reading_progress` | 按 `tid` 去重取 `ts` 较新，截断 200 |
| `votes_<uid>` ×N | `votes` | `Record<tid, VoteRecord>` 合并，冲突取 `ts` 较新，截断 200 |
| `pollVoted_<uid>` ×N | `poll_voted` | `Record<tid, ts>` 合并取较大，截断 200 |
| `tracked_threads_<uid>`（旧信封 v2） | `tracked_threads` | items 合并：按 `tid` 去重取 `lastCheckAt`/`updatedAt`/`createdAt` 较新，上限 50（`TRACK_MAX_COUNT`） |
| `ai_sessions_<uid>`（旧信封 v1） | `ai_sessions` | items 合并：按 `id` 去重取 `updatedAt`/`createdAt` 较新、上限 20（`MAX_AI_SESSIONS`）；**清空每条 `ownerUid`**（设备级共享） |
| `ai_tool_cache_<uid>`（旧信封 v1） | `ai_tool_cache` | **不迁移**（TTL 缓存可重建，旧条目 key 内含旧 uid bucket）；旧键保留 30 天后清理 |
| `filesDir/drafts/*.json` | `filesDir/v2/drafts/` | 逐文件读取校验（`key` 非空）→ 原子写新目录；**不补版本字段**（`EditorDraft` 无 schemaVersion）；旧文件保留至清理；**逐文件检查启动预算，超时 DEFERRED 续跑**；全部文件无效按 SKIPPED 处理（不反复弹失败） |
| `filesDir/draft_media/*` | 不变 | 原位保留（草稿键未变，媒体目录名与键绑定） |
| `filesDir/saved_threads/*.json` | `filesDir/v2/saved_threads/` | 逐文件读取校验（tid 纯数字 + `rawPages` 非空）→ 原子写新目录；坏文件跳过计数；规则同 drafts |
| `filesDir/mphoto/*` | 不变 | 缓存目录原位保留 |

**"多份旧键选谁"的实际裁决**：
1. 单值域（settings）：当前登录 uid 匹配优先；无匹配时仅一份可用、多份跳过（旧键保留，登录后重试）；
2. 账号镜像域（notifications/activities/favorite_membership）：**只取当前 uid 的旧键**；未登录或无匹配 → SKIPPED（旧键保留，登录后重试）；
3. 集合域（history/reading_progress/votes/poll_voted/profiles/信封域）：**全部旧键合并**，按业务键去重、时间取新、按域上限截断；
4. **只有本次真正迁移成功（MIGRATED）的域，旧键才进入 30 天清理清单**；SKIPPED/FAILED/DEFERRED 的旧键永久保留直至迁移成功（防"延迟/失败域旧数据被清"）。

### 5.5 用户提醒设计

三条原则：**不打断使用、必须可见、可追溯**。

| 时机 | 形式 | 文案（资源字符串） |
| --- | --- | --- |
| 迁移成功（有实际转换） | MainPage 首次 `aboutToAppear` 后 Toast，3s | 「本地数据已升级为统一格式（N 项）」 |
| 迁移成功（无转换，仅锚点） | 静默（只写日志） | — |
| 部分失败 | 对话框（单按钮「知道了」+「查看详情」跳数据管理页） | 「有 N 项本地数据升级失败，旧数据已保留。可稍后在「设置 → 数据管理」重试。」 |
| 阻断性失败（所有域失败） | Toast 警告 + 数据管理页红字常驻 | 「本地数据升级未完成，部分旧数据暂不可用」 |
| 数据管理页 | 状态卡：数据版本、上次迁移时间、成功/失败域、旧数据清理日期、重试按钮 | — |

**真实源**：`AppStorage` 只发布一个键 `migrationStatus`（字符串），刷新信号用
`dataManagementVersion`；报告正文由 `appStore.migrationReport` 直接读取（MainPage 在
`aboutToAppear` 中读）。**阻断性全失败未做专门降级**：迁移异常时报告 `status=failed`、`domains=[]`，
MainPage 不弹窗，只有设置页徽标 '!' 与数据管理页红字提示（列为 §13.5 未实现项）。

**为什么不弹在 Index 页**：Index 处于冷启动 loading 态，任何弹窗都会与"跳转后立即销毁"竞争；
MainPage 才是用户停留的稳定上下文。

**旧数据清理提示**：`legacyCleanupAfter` 到期时在数据管理页显示「旧格式数据（N MB）将于 M 天后自动清理」
并给「立即清理」按钮——清理是不可逆动作，必须让用户知情（呼应"清除缓存"的既有文案纪律）。

### 5.6 幂等、失败与重试

- **幂等**：每域迁移先检查新键是否已存在：
  - 新键不存在 → 全量迁移该域；
  - 新键已存在 → 跳过（`SKIPPED`，不覆盖）；实现中**不做**"较旧则合并"（该能力未实现，见 §13.3）；
  - 仅 **MIGRATED**（写入并读回校验通过）的域，其旧键才进入 30 天清理清单；`SKIPPED/FAILED/DEFERRED`
    的旧键全部保留，下次启动继续尝试（防"延迟/失败域旧数据 30 天后被清且从未合并"）。
- **断点**：逐域落盘迁移报告（每完成一域就更新 `v2.meta`），进程被杀后下次从断点续跑；文件域逐文件
  检查启动预算，超时标记 `DEFERRED`，已复制文件在下次启动按"新目录已有同名"跳过。
- **文件域检测以 meta 为准**：迁移报告里该文件域已 `MIGRATED` 后不再检测旧目录，避免"升级后用户删除的
  草稿/存档被旧目录文件复活"；旧目录中全部文件无效时记 `SKIPPED`（不产生失败提醒）。
- **失败重试**：数据管理页「重试升级」按钮 → `migration.run(pending plan)`，不清除已完成域。
- **回滚**：不提供自动回滚（旧数据保留期即人工回滚窗口）。文档与 UI 明确：担心升级结果可先导出数据。
  **凭证旧键例外**：`auth`/`sessions` 迁移成功且新键读回通过后**立即删除**（明文 token/cid 不应随系统
  云备份长期驻留），回滚旧版本需重新登录或用 `.ngacred` 导入。

### 5.7 旧数据清理

- `legacyCleanupAt = migratedAt + 30 天`（清理任务注册到调度器 `migration.legacyCleanup`，启动 + 每日一次）。
- 清理范围：**仅 meta 中登记为已成功迁移（MIGRATED）域的旧键** + 旧目录中"新目录已有同名"的旧文件。
- 清理前二次校验：对应新域数据存在且可读（`hub.readPayload` 非 null）才删除；否则放弃并记录日志。
- **清理后回写 meta**（`legacyKeys: []`、`legacyCleanupAt: 0`），数据管理页显示已清理、不再常驻"N 项待清理"。

## 6. 导出 / 导入（Data Transfer）

### 6.1 容器格式

文件后缀 `.ngabackup`（可被系统识别为二进制/JSON，实际为 UTF-8 JSON）。

明文容器（`formatVersion = 1`）：

```json
{
  "magic": "NGA_OH_BACKUP",
  "formatVersion": 1,
  "dataVersion": 2,
  "exportedAt": 1730000000000,
  "appVersionName": "1.2.0",
  "appVersionCode": 1020000,
  "deviceTag": "phone",
  "domains": [
    {
      "id": "settings",
      "schemaVersion": 1,
      "updatedAt": 1730000000000,
      "payload": { }
    }
  ],
  "checksum": "sha256:<hex of JSON.stringify(domains)>"
}
```

- 数组而非对象：`domains` 用数组保证顺序稳定（同一数据两次导出字节级一致，便于 diff 与校验）。
- `checksum` 可选：计算 `domains` 序列化结果的 SHA-256（`cryptoFramework` 的 `MD`/`SHA256`），
  导入时校验，防止文件被截断/手改。缺失时视为"旧格式"，跳过校验并提示。
- `deviceTag` 仅作诊断信息，导入不依赖。

加密容器（用户勾选"加密导出"时）：

```json
{
  "magic": "NGA_OH_BACKUP_ENC",
  "formatVersion": 1,
  "kdf": "PBKDF2|SHA256",
  "iterations": 120000,
  "cipher": "AES256|GCM|PKCS7",
  "salt": "<b64>",
  "iv": "<b64>",
  "tag": "<b64>",
  "data": "<b64 of 明文容器 JSON>"
}
```

复用 `CredentialExportCrypto` 的算法参数（PBKDF2-SHA256 / 120000 次 / AES-256-GCM / 12B IV / 16B tag），
但 **AAD 必须不同**（`nga-oh-data-backup-v1`），防止把凭证文件当数据包导入（反之亦然）。

### 6.2 加密与口令策略

- 口令最短 8 位（与凭证导出一致）；不强制复杂度（可用性优先，风险由用户自担并在 UI 提示）。
- **默认加密**；用户关闭加密开关时弹二次确认（已实现：`DataManagementPanel` 加密 Switch 的 onChange
  调 `showAlertDialog`，取消则保持加密）。
- 口令不落盘、不记忆、不提供找回。
- 导入时若识别为加密容器 → 弹口令输入（复用 `CredentialPasswordContent` 组件模式）；
  口令错误 → 解密失败 → 明确提示「密码错误或文件损坏」，不区分二者（避免 oracle）。

### 6.3 选择性导出

- 数据管理页「导出数据」→ 弹窗：域清单（按 `DomainSpec` 生成，**平铺列表**，未做六组分类）；
  每项显示名称与说明；默认勾选 `ExportPolicy.INCLUDE`。
- 顶部「全选 / 全不选」；底部「加密」开关 + 口令。
- `ExportPolicy.NEVER` 的域（凭证/草稿媒体/动态照片缓存）不出现；`OPTIONAL` 的缓存域默认不勾选。
- 导出过程：完成后调 `picker.DocumentViewPicker.save()` 保存
  （⚠️ **纠偏**：早期草案写的 `DocumentSavePicker` 在 SDK 中不存在，权威 API 是
  `new picker.DocumentViewPicker(context).save(options)`）；
  文件命名 `nga-backup-<YYYYMMDD-HHmmss>.ngabackup`（加密则 `.ngabackup` 不变，靠 magic 区分）。
- 大文件：导出前显示"正在生成…"文案；超过 64MB 拒绝并提示先清理缓存。
  **未实现**：域级进度百分比、4MB 预警、分组展示、每域体积（列在 §13.3 遗留）。

### 6.4 导入策略与合并语义

导入流程：

```
选择文件 → 识别 magic（明文/加密）→ 需要时输入口令 → 解析容器
  → 校验 formatVersion / dataVersion / checksum
  → 逐域执行升级器（旧 formatVersion → 当前；旧域 schemaVersion → 当前）
  → 生成"导入计划"：每域 新增/覆盖/跳过/合并 的条数与变更摘要，展示给用户确认
  → 用户确认 → 逐域导入（每域写前备份到 v2.<domain>.undo）
  → 全部成功 → 写导入记录 → 刷新各 Store → 提示成功
  → 有失败 → 保留 undo 快照 → 提示"部分导入失败，可撤销"
```

每域合并语义：

| 域 | 策略 | 冲突处理 |
| --- | --- | --- |
| `settings` | 字段级：导入值覆盖本机值；数组字段按业务键并集（黑名单按 uid、屏蔽词按关键词、备注按用户、收藏版块按 fid、AI 配置按 id、AI 任务按 id） | 同名条目：导入值优先（用户导入的意图是"恢复"）；保留本机独有条目 |
| `theme` | 覆盖 | — |
| `history` | 按 tid：两边都有取 `ts` 较新；结果按 ts 降序截断 500 | 较旧版本被丢弃 |
| `reading_progress` | 按 tid 取 `ts` 较新；截断 200 | — |
| `votes` / `poll_voted` | 按 tid 取 `ts` 较新；截断 200 | — |
| `tracked_threads` | 按 `tid` 取 `lastCheckAt`（回退 `createdAt`）较新；按 50 条截断 | 较旧条目丢弃 |
| `ai_sessions` | 按 id：两边都有取 `updatedAt` 较新；总数超上限淘汰最旧 | 会话消息不合并（整条取新） |
| `drafts` | 按草稿键覆盖（同键以导入文件为准） | 键内 uid 哈希段保留导入值：**跨账号导入后当前账号按新哈希找不到旧草稿**（`DraftStore.draftUidPart` 用 FNV-1a 短哈希），需在导入时按当前 uid 重算键（Phase 4 实现，`DataTransferService` 已预留 `applyFileDomain` 的键处理点） |
| `draft_media` | 按草稿键：导入文件中的媒体副本**不包含**（媒体体积大且涉及沙箱路径不可移植） | 仅导入草稿正文，媒体由用户在编辑器重选（UI 明示） |
| `saved_threads` | 按 tid 覆盖（沿用现有 `importContent` 语义） | 已有实现 |
| `categories` / `profiles` / `notifications` / `activities` / `favorite_membership` / `ai_tool_cache` | 跳过（`ImportPolicy.SKIP`） | 提示"该域为缓存/账号镜像，导入已跳过" |
| `auth` / `sessions` | 永不导入（凭证走独立加密导入流程） | — |

**撤销（undo）**：导入前把每个将被修改的域的当前值复制到 `v2.<domain>.undo`（含 `undoAt`），
导入成功后保留 10 分钟（数据管理页显示「撤销导入」）；用户点撤销则写回 undo 快照并重载各 Store。
文件域的键为 `v2.<domainId>.undo`（不能用 `fullKey()`——文件域 fullKey 为空，草稿与存档会撞键）；
撤销文件域时**先清空目录再回写快照**（导入新增的文件必须删除才算还原）。

快照生命周期：导入成功后启动 10 分钟定时清理、每次启动清理过期快照、「清空本地数据」一并删除。
**已知取舍**：settings 快照包含明文 AI API Key（undo 需要恢复原密钥），因此保留期严格限制在 10 分钟，
不做脱敏；接受这一短暂驻留风险（已在 §13.3 记录）。

### 6.5 兼容性

| 来源 | 实际处理 |
| --- | --- |
| 旧版离线存档导出文件（`SavedThreadExportFile`，无 `magic`） | 识别到 `threads` 非空数组即转为 `saved_threads` 域（**不校验其 schemaVersion**，宽容导入；条目级校验由合并器/写入器做） |
| 旧版凭证 `.ngacred`（`NGA_CREDENTIAL_EXPORT`） | 识别 magic 后**明确拒绝**：「这是账号加密凭证文件，请在登录页 → 导入凭据文件」 |
| 未来格式（`formatVersion > 当前`） | 拒绝并提示升级 App；**不尝试部分解析** |
| 损坏文件 | 分阶段校验：magic → 结构/版本整数性 → checksum → 域级 schema；任一失败给出明确阶段 |
| 超大文件 | 读取前用 `fileIo.stat` 检查大小 > 64MB → 拒绝；单域载荷 > 8MB 字符跳过；域数 > 64 拒绝；重复域 ID 只保留首个 |

### 6.6 安全与隐私清单

1. **凭证永不进入数据包**（`ExportPolicy.NEVER` + 导入器硬拒绝 auth/sessions 域）。
2. **导出前隐私提示**：勾选 AI 会话/浏览历史时在底部提示"包含敏感内容"；`ai_sessions` 默认**不勾选**
   （`ExportPolicy.OPTIONAL`）。
3. **加密默认开启**，AAD 隔离凭证与数据两条链路（`nga-oh-data-backup-v1` vs `nga-oh-credential-export-v2`）。
4. **AI API Key 脱敏**：`settings` 域的 `aiProfiles[].apiKey`、`aiProfiles[].toolsApiKey`、
   `aiSearchProfiles[].apiKey` 在**导出副本**中清空（内存/磁盘真实配置不动）；导入时若包内该字段为空，
   保留本机同 id 配置的密钥（避免"导入设置后 AI 不能用"）。
5. **文件路径**：导入只从 `picker` 返回的 URI 读取，不拼接用户输入路径；存档 tid / 草稿键校验沿用
   （`isSafeDomainFileName` 拒绝 `/`、`\`、`..`）。
6. **解析防护**：JSON 解析失败不抛到 UI（统一转错误提示）；域数 ≤64、重复域 ID 去重、
   `formatVersion`/`dataVersion` 必须正整数、单域载荷 ≤8MB 字符（跳过并计入计划）、文件体积 >64MB 拒绝；
   条目级上限由合并器按域截断（history 500 / 通知 200 等）。
7. **加密参数防篡改**：解密时校验 `iterations ∈ [10000, 600000]`（修复凭证链路"直接信任文件内
   iterations"的缺陷，`EXPORT_IMPORT_RESEARCH.md` F2）、`kdf`/`cipher` 白名单、salt/iv/tag 长度；
   **解密路径的 `doFinal` 返回 null 属正常（SDK 明确），不得判空抛错**；口令错误与文件损坏
   给同一句提示（不做 oracle）。
8. **文件句柄**：导出写文件与导入读文件一律 `try/finally` 关闭 fd（修复凭证导出链路的 fd 泄漏，
   `EXPORT_IMPORT_RESEARCH.md` F1 类缺陷）。
9. **不导出临时态**：`undo`/`pending`/工具缓存不进入导出（后者可选勾选但默认不选）；
   **账号镜像域导出前校验 `ownerUid`**，磁盘快照属于其他账号时跳过（防跨账号数据外带）。
10. **撤销快照生命周期**：`v2.<domain>.undo` 含明文隐私数据，仅保留 10 分钟（导入成功后启动定时清理 +
    启动时清理 + 「清空本地数据」一并删除）。
11. **审计**：导出/导入各写一条日志（域数量、总体积、是否加密、耗时），不记录内容。

### 6.7 UI 流程

```
设置 → 「数据管理」 ────────────────────────────────────────────────
  [数据版本]  当前 v2 · 上次升级 2026-10-30 · 旧数据 27 天后清理   [重试升级]
  [数据健康]  ✓ 正常 / ⚠ 2 个域有异常（点开看详情 / 修复）
  [存储占用]  设置 12 KB · 历史 88 KB · AI 会话 1.2 MB · 存档 24 MB …（估算）
  ────────────────────────────────────────────────
  [导出数据]  → 选择域 + 加密开关 → 保存文件
  [导入数据]  → 选择文件 → 口令（如需）→ 导入计划确认 → 执行 → 结果
  [撤销导入]  （导入后 10 分钟内可见）
  ────────────────────────────────────────────────
  [清空本地数据]  （危险：二次确认 + 需输入"清空"二字；保留凭证与存档可选）
```

入口位置：SettingsPanel 的 Block 3C（导出账号凭证 / 清除缓存 / 退出登录）之前新增 Block「数据管理」，
沿用 `SettingRow` + 图标资源模式。

## 7. 调度机制（AppScheduler）

### 7.1 现状：六类时机任务，三套节流，两种失败语义

| 任务 | 触发 | 现状实现 | 节流 | 失败语义 |
| --- | --- | --- | --- | --- |
| 会话校验（前台） | 回前台 | `EntryAbility.onForeground → sessionGuard.verifyOnForeground` | 10min（降级 1min） | UNKNOWN 不处置 |
| 自动签到 | 回前台 + MainPage 进入 | `AppStore.autoCheckinIfNeeded`（两处重复调用） | 按日期 | 吞错 |
| 通知轮询 | 前台 | `PollingController(300s)` | 30s 最小刷新间隔 | 记 warn |
| 关注动态轮询 | 前台 | `PollingController` | 30s | 记 warn |
| 跟踪帖子检查 | 前台 | `PollingController(10min)` | 30s | 记 warn |
| 凭证降级复验 | 降级态定时 | `AppStore.scheduleCredentialRecheck`（退避 3/15/30/60s） | 幂等定时器 | 继续退避 |
| 草稿清理 | 启动 + 800ms | `AppStore.initDraftCleanup` | 无（一次性） | 记 warn |
| 工具缓存刷盘 | 变更后 | `AiToolCacheStore.scheduleSave(800ms)` | 合并 | 记 warn |
| 全量 flush | 回后台 | `EntryAbility.onBackground → flushAll` | — | 记 warn |

问题：① 没有统一的任务表（新增任务要改 AppStore/EntryAbility 多处）；② 节流/退避/单飞各写一套；
③ 无法回答"回前台跑了什么、上次何时跑、失败几次"；④ `autoCheckinIfNeeded` 在 Ability 与
MainPage 两处调用，靠内部状态去重；⑤ 任务与生命周期硬编码耦合，单测只能逐个击破。

### 7.2 任务模型

```ts
/** 触发源（与生命周期/系统事件一一对应）。 */
export enum SchedulerTrigger {
  /** 冷启动完成（Hub 加载 + Store init 之后）。 */
  STARTUP = 'startup',
  /** 回到前台（含冷启动后的第一次前台，二者可能同帧，由调度器去重）。 */
  FOREGROUND = 'foreground',
  /** 进入后台。 */
  BACKGROUND = 'background',
  /** 网络可用。 */
  NETWORK_AVAILABLE = 'network-available',
  /** 登录成功（新会话）。 */
  LOGIN = 'login',
  /** 退出登录。 */
  LOGOUT = 'logout',
  /** 周期触发（仅前台，由调度器 60s 心跳驱动，任务自行判断是否到点）。 */
  TICK = 'tick',
  /** 用户主动（按钮/下拉刷新）。 */
  USER = 'user',
}

/** 单次任务执行结果。 */
export enum TaskOutcome {
  OK = 0,
  /** 跳过（条件不满足/未登录）。 */
  SKIPPED = 1,
  /** 失败（可重试）。 */
  FAILED = 2,
}

/** 任务定义（静态注册，运行期不可增删）。 */
export class ScheduledTask {
  /** 唯一 ID，日志与状态查询的主键。 */
  id: string = ''
  /** 触发源集合：命中任一即参与（同一帧多个触发源按优先级排序执行一次）。 */
  triggers: SchedulerTrigger[] = []
  /** 最小成功间隔（ms）；0 = 不节流。 */
  minIntervalMs: number = 0
  /** 失败后的退避序列（ms，空数组 = 不重试）。 */
  retryDelays: number[] = []
  /** 仅前台执行。后台触发时直接 SKIPPED。 */
  foregroundOnly: boolean = true
  /** 需要已登录。 */
  requiresAuth: boolean = false
  /** 与首个触发源同时机注册的延迟（ms）。用于"启动后 800ms 再做清理"这类需求。 */
  startDelayMs: number = 0
  /** 任务体；必须自行处理异常（框架兜底 catch 并记 FAILED）。 */
  run: (context: SchedulerContext) => Promise<TaskOutcome> = async () => TaskOutcome.OK
}

/** 调度上下文（注入给任务体，便于测试与统一日志）。 */
export class SchedulerContext {
  /** 当前是否前台（任务体内长耗时操作可提前退出）。 */
  foreground: boolean = false
  /** 触发源。 */
  trigger: SchedulerTrigger = SchedulerTrigger.TICK
  /** 当前毫秒时间（测试可注入 fake clock 的时间）。 */
  now: number = 0
}
```

### 7.3 调度器契约

```
AppScheduler.register(task)       // 启动时一次性注册；重复 id 拒绝并 warn
AppScheduler.start()              // 启动 60s 心跳（后台保留心跳、只停派发 TICK）
AppScheduler.notify(trigger)      // 事件入口：匹配任务 → 排序 → 逐个串行 await
AppScheduler.requestRun(id, force) // 用户主动触发（当前无生产调用点，供数据管理页扩展）
AppScheduler.snapshot()           // 全部任务状态快照（当前无 UI 消费方）
```

保证（与实际实现一致）：

1. **单飞**：同一任务 ID 执行中再次触发直接忽略（记录 `coalesced` 计数）。
2. **节流**：以 `lastRunAt`（含 SKIPPED 之外的实际执行完成时间）为基准，`now - lastRunAt < minIntervalMs`
   → SKIPPED；失败后退避期间不受 minInterval 叠加约束。
3. **退避**：FAILED 后下一次触发按 `retryDelaysMs[failureCount-1]` 延迟（第 1 次失败用第 0 档）；成功后清零。
4. **前台门禁**：`foregroundOnly && !foreground` → SKIPPED。
5. **认证门禁**：`requiresAuth && !auth.isAuthenticated` → SKIPPED。
6. **异常隔离**：任务体抛错不影响其它任务；记录 `lastError`（截断 200 字符）。
7. **可观测**：每次执行写一条 `DOMAIN_APP` verbose 日志（id/trigger/outcome/耗时/coalesced）。
8. **可测试**：时钟与前台状态可注入（`bindClock` / `bindForegroundProbe`），任务体纯粹。

### 7.4 任务迁移表（现状 → 调度器）

**已注册到 `BuiltinTasks.ets` 的任务（7 个）**：

| 任务 ID | 触发器 | minInterval | requiresAuth | 迁移来源 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `session.verify` | FOREGROUND, TICK, LOGIN | 10min（降级 1min 由任务体内部判定） | 是 | `onForeground` 直调 | 保留 `verifyOnForeground` 的既有语义 |
| `checkin.auto` | STARTUP, FOREGROUND | 0（任务体内按日去重） | 是 | `onForeground` + `MainPage.aboutToAppear` | 消除重复调用点 |
| `notifications.poll` | STARTUP, FOREGROUND, TICK | 300s | 是 | `PollingController` 实例 | 后台停 TICK；保留 30s 普通刷新节流 |
| `activities.poll` | 同上 | 300s | 是 | 同上 | |
| `tracked.check` | 同上 | 10min | 是 | 同上 | 任务体内部逐帖串行检查 |
| `draft.cleanup` | STARTUP（startDelay 800ms） | 一次/启动 | 否 | `initDraftCleanup` | 提前退出判据：已有清理在跑 |
| `migration.legacyCleanup` | STARTUP, TICK | 每日 | 否 | 新增 | 见 §5.7 |

**明确不注册、保留既有实现的任务**：

| 任务 | 保留实现 | 原因 |
| --- | --- | --- |
| `credential.recheck` | `AppStore.scheduleCredentialRecheck` 有界退避定时器 | 与 `SessionGuard` 深度耦合，迁入收益低、回归风险高（R5） |
| `toolcache.flush` | `AiToolCacheStore` 内部 800ms 合并写 | 调度器异步派发可能晚于进程回收 |
| `persistence.flush` | `EntryAbility.onBackground → AppStore.flushAll` | 后台时机必须同步发起 |

**未实现**：`migration.retry`（设计阶段的"启动自动重试 partial"未注册；现状由数据管理页「重试升级」
手动触发，避免启动路径重复迁移开销）。

**不迁移项**：`NetworkMonitor`（只 bump 版本键，无任务）保留；TTS 长时任务保留独立实现（系统任务，
不属于应用内调度）；AI Agent 循环、流式请求等交互内任务不进入调度器（用户可见的即时操作）。

### 7.5 是否引入系统级后台任务（结论）

**结论：阶段 1 不引入。** 依据（`SCHEDULER_RESEARCH.md` §2，SDK 声明与官方文档行号见该文）：

1. **需求形态不支持**：后台任务的价值在于"用户不在前台时也要发生的副作用"（如下载、定时提醒）。
   本应用的时机任务全部是"用户回来时数据要是新的"——前台触发已经满足；后台执行只会提前消耗电量。
2. **无推送通道**：NGA 客户端没有系统推送，即使后台轮询到新通知也无法即时提醒用户（最多在下次打开时
   显示），后台轮询的收益趋近于零。
3. **系统能力限制**（本机 API 26 声明与官方文档核实）：
   - `workScheduler`：频率按活跃分组下限 2h/4h/24h/48h，单次回调 2 分钟超时即杀 Extension 进程，
     回调运行在**独立 Extension 进程**（拿不到 AppStore/SessionGuard 的内存态），且回调内禁用
     长时任务/相机/音视频接口；
   - `reminderAgentManager`：**只弹提醒通知、不执行代码、不能发网络请求**，无法替代签到/轮询；
   - `backgroundTaskManager` 长时任务：本应用 `KEEP_BACKGROUND_RUNNING` + `backgroundModes:["audioPlayback"]`
     已被 TTS 占用，系统做业务一致性校验，挪用有挂起与上架审核风险；短时任务日配额约 10 分钟，
     当前 `flushAll` 已在秒级完成、无需申请；
   - `commonEvent` 动态订阅在后台挂起即失效；`appRecovery` 是崩溃恢复，不是调度。
4. **复杂度过高**：引入 `WorkSchedulerExtensionAbility` 意味着多一个 Ability、多一套跨进程状态同步、
   多一种数据一致性路径，与"降低维护成本"目标相反。
5. **预留扩展点**：`SchedulerTrigger` 已按事件源设计，未来若需要"每日自动签到即使不打开应用"，可新增
   `SYSTEM_WORK` 触发器 + 一个 Extension Ability 实现，任务注册表无需改动（§7.2）。

**本次调度器还解决调研发现的"回前台请求风暴"**：现状 `onForeground` 会**同时**触发自动签到 +
iflogin 校验 + 三路轮询立即刷新（跟踪一轮最多 50 帖 × 400ms ≈ 20s）。调度器将所有任务收敛到同一
事件分发点后，按"注册顺序 + 前台 tick 错峰 + 最小间隔"串行执行，并可在数据管理页看到每个任务
上次执行时间与结果（§7.6）。

### 7.6 可观测性与测试

- **调度状态 UI 未实现**（原计划的数据管理页「调度状态」折叠区未落地）：当前只有 `snapshot()` API 与日志。
- 日志：`Logger(DOMAIN_APP, 'AppScheduler')`，每次执行一条 verbose；失败一条 warn（含截断错误）。
- 单测（`entry/src/test/SchedulerUnit.test.ets`）：注册/触发匹配、节流、单飞、退避、前台门禁、
  认证门禁、异常隔离、时钟注入（22 用例）。
- **触发源与消费方现状**：`FOREGROUND/STARTUP/LOGIN/TICK` 有任务订阅；`LOGOUT/BACKGROUND/
  NETWORK_AVAILABLE/USER` 目前**无任务订阅**（事件照发但无消费者，属预留扩展点）。

## 8. 生命周期与 AppStore 编排

### 8.1 启动时序（改造后）

```
EntryAbility.onCreate
  ├ TtsPlayer.initialize / 系统颜色模式 / 注册系统订阅
  ├ appStore.init(context)
  │   ├ hub.init：打开 Preferences；清 pending；枚举旧键做检测
  │   ├ migration.check + run（§5.3）
  │   ├ savedThreadStore.init / draftStore.init / draftMediaStore.init（文件域）
  │   ├ 各 Store 按域自读：settingsStore.initTheme/init、profileStore、trackedThreadStore、
  │   │   aiSessionStore、aiToolCacheStore、categoryStore、vote/history/readingProgress（均从 Catalog 键读）
  │   ├ authStore.init → 若已登录：loadMirrorData 加载 ACCOUNT_MIRROR 域（通知/动态/收藏关系）
  │   ├ settingsStore.applyCurrentTheme
  │   ├ initialized = true
  │   ├ scheduler.setStartupComplete → start → notify(STARTUP)   ← 取代 init 尾部散落的清理/轮询启动
  │   └ reconcilePolling → notify(FOREGROUND)（若已前台且已登录）
  ├ startNetworkMonitor（**仍只 bump 版本键**，未接调度器；NETWORK_AVAILABLE 触发源已预留）
  └ onWindowStageCreate → loadContent → Index 轮询 isInitializationFinished → 路由
```

> 注：Hub **没有** `loadAll`——日常加载由各 Store 自己完成（§8.4），Hub 只做治理面。

### 8.2 登录 / 登出 / 切号

**登录成功**（`AppStore.setAuth`）：

1. `authStore.setAuth` + 落盘（不变）
2. 重载 ACCOUNT_MIRROR 域（3 个）——**不动**设备级域
3. `sessionGuard.resetForNewSession` / `resetCredentialState`（不变）
4. `scheduler.notify(LOGIN)`（自动签到/通知轮询由任务注册表接管）

**退出登录**（`AppStore.clearAuth`）——改造重点：

```
1. writeQueue.cancel/reset（保留：防止旧账号镜像域的待写任务）
2. authStore.clearAuth（清凭证）
3. 清 ACCOUNT_MIRROR 域的内存（notifications/activities/favorite_membership）
4. 清运行态：floatingLayerStore、routerStore、各类轮询/调度任务的运行状态
5. **不 reset**：settings/history/reading_progress/votes/poll/tracked/ai_sessions/ai_tool_cache/
   profiles/categories/drafts/saved_threads —— 设备级数据保留并可继续使用
6. settingsStore.reset 的语义拆分：
   - resetForLogout()：只清"账号相关内存"（AI 配置等保留；黑名单/屏蔽词/备注/布局保留）
   - resetAll()：仅"清空本地数据"入口使用（数据管理页）
7. resetCredentialState + scheduler.notify(LOGOUT)
```

> 这是本设计**对现有代码改动最大、风险最高**的一处：现状 `clearAuth` 把 15 个 Store 全部 reset。
> 改造必须保证：① 退出后进入 LoginPage 时不会因残留状态崩溃；② 重新登录（可能换号）后界面数据正确。
> **实际实现口径**：未采用"先保守后放开"的两步走，而是直接实现"设备级域登出后内存保留、未登录可用"
> （`clearAuth` 只 reset 三个镜像域 + 浮层/路由运行态）；`settingsStore.reset()` 只被
> 「清空本地数据」入口调用。风险由两件事兜住：既有 44 个 Hypium 测试全绿 + 登录/登出路径的单测
> （`SessionUnit` / `AuthStore` 相关）+ 代码审查。

**切换账号**（A→B，不经过登出）：与登录成功同路径；`authStore.setAuth` 的 `uidChanged` 分支负责重载镜像域。

### 8.3 前台 / 后台

| 事件 | 改造前 | 改造后（实际） |
| --- | --- | --- |
| `onForeground` | `setForegroundActive(true)`（内部启轮询）+ `autoCheckinIfNeeded` + `verifyOnForeground` | `setForegroundActive(true)` → `scheduler.notify(FOREGROUND)`（EntryAbility 不再直调两个动作） |
| `onBackground` | `setForegroundActive(false)` + `flushAll` | 同左 + `scheduler.notify(BACKGROUND)`（当前任务表无后台任务，flush 仍由 `flushAll` 同步发起） |
| 网络可用 | 仅 bump 版本键 | 同左（`NETWORK_AVAILABLE` 触发源已预留，暂无任务订阅） |
| `onDestroy` | `setForegroundActive(false)` + TtsPlayer.shutdown | 同左 + `appStore.shutdownScheduler()` |

### 8.4 Store 与 Hub 的接入方式（实际实现）

放弃"Hub 侧 adapter 逐步下沉"的两阶段方案，采用**直接改造**：

1. **键统一**：各 Store 的键/目录一律从 `PersistenceCatalog.byId(id)` 派生（`fullKey()` / `dirPath()`），
   不再硬编码、不再拼 uid；
2. **载荷分两种模式**（见 `DomainSpec.rawPayload`）：存量域 RAW（裸 JSON，Store 只换键）；信封域
   （通知/动态/收藏关系/跟踪/AI 会话/工具缓存）由 `CacheEnvelopeStore` 或 FavoriteStore 自管统一信封；
3. **Hub 只做治理面**（迁移/导出导入/健康/统计/清空），**不参与 Store 的日常读写**——避免与
   `SerialQueue` + `scheduleFlush` 的既有写路径双写；
4. 迁移器/导出导入直接读写域键（不经 Store），保证"Store 未初始化时也能迁移"。

> 为什么放弃 adapter：两阶段并存需要"adapter 与 Store 一一对应、禁止双写"的强纪律，且 adapter 仍需
> 理解每个域的业务结构，收益低于直接改键（每 Store 约 10–30 行）。

## 9. UI 设计

### 9.1 设置页入口

在 `SettingsPanel` 的 Block 3C 之前插入 Block 3B2「数据管理」：

```
SettingRow(icon=数据管理, label='数据管理', badge=<版本/异常提示>, onAction=打开 DataManagementPanel)
```

badge 规则：迁移有失败 → 红点；迁移完成且未提示过 → 无 badge（用 Toast 告知）；无异常 → 空。

### 9.2 数据管理页（新 Panel）

新增 `pages/DataManagementPanel.ets`，经 `RouterStore.Screen.dataManagement()` 路由（`ScreenType` 增加
`'dataManagement'`，`getTitle()` 返回「数据管理」）。布局参照现有设置页：`PanelNavBar` + 滚动区 +
分组卡片（`AppColors.bgTertiary` + 圆角 12 + 92% 宽）。

区块（对应 §6.7）：

1. **数据版本**：`dataVersion` 文本、上次迁移时间、旧数据清理倒计时/「立即清理」、失败域列表、
   「重试升级」（调 `migration.retry()`）。
2. **数据健康**：异常域列表（域 ID + 错误摘要 + 丢弃条数）+ 「修复」（清空该域并重建）。
3. **存储占用**：按域估算体积（Preferences 用 `JSON.stringify(payload).length`，文件域用目录大小），
   合计；「刷新统计」。
4. **导出数据**：跳半模态（自定义 `CustomContentDialog` 或新子 Panel）显示域勾选清单 + 加密开关。
5. **导入数据**：文件选择 → 口令 → 导入计划确认对话框（每域变更条数）→ 执行 → 结果。
6. **撤销导入**（10 分钟内可见）。
7. **清空本地数据**（危险区，红字，二次确认 + 输入确认词）。

### 9.3 迁移提醒弹窗

- 组件：`CustomContentDialog`（与现有 `TipsDialog` 风格一致，材质走 `UIMaterialManager.dialogMaterial`，
  遮罩 `UIMaterialManager.scrim`；遵守 `docs/IMMERSIVE_LIGHT_DESIGN.md` 第 12 节契约）。
- 触发点：`MainPage.aboutToAppear` 中读取 `@StorageProp('migrationStatus')`，一次会话只弹一次
  （内存标记，不持久化——用户没看到的话下次启动再提醒）。
- 按钮：「知道了」（关闭）/「查看详情」（跳数据管理页并关闭）。

## 10. 分阶段实施计划（含实际状态）

| 阶段 | 内容 | 实际产出 | 状态 |
| --- | --- | --- | --- |
| **P1 基础设施** | `PersistenceCatalog`、`PersistenceHub`、`StorageBackends`、`PersistenceMetaStore`、`DomainHealth`、`MigrationEngine` + `DomainMigrators`、`AppScheduler`、`TransferTypes`/`TransferCrypto`/`DomainMergers`、`BuiltinTasks` | `common/persistence/*`、`common/scheduler/*`、`common/transfer/*` | ✅ 完成（编译 + 单测） |
| **P2 域接入** | 21 个域登记；15 个 Store 统一键/加载门禁；`AppStore.init` 编排迁移；迁移报告发布 | `PersistenceCatalog`、17 个 Store 文件、`AppStore` | ✅ 完成（替代原"adapter"方案，见 §8.4） |
| **P3 生命周期改造** | `clearAuth` 拆分（设备级域不 reset）、镜像域重载、未登录可用 | `AppStore`、各 store | ✅ 完成（直接放开，未走保守版） |
| **P4 导出导入** | `DataTransferService`（容器/校验/脱敏/撤销）、域合并器、`DataManagementPanel`、`FilePickUtils`、`reloadAfterImport` | `common/transfer/*`、`pages/DataManagementPanel.ets`、`AppStore` | ✅ 完成 |
| **P5 调度器接入** | 7 个内置任务注册；`EntryAbility`/`AppStore` 接线；回前台请求风暴收敛 | `BuiltinTasks`、`AppStore`、`EntryAbility` | ✅ 完成 |
| **P6 收尾** | 旧键清理任务、数据健康、体积统计、文档、遗留 TODO | 各文件 | ✅ 完成（已知遗留见 §13.3） |

> 本文档与代码同步维护：每个阶段完成后在 §10 标记状态并在文末「实施记录」补一段实测结论。

## 11. 测试策略

| 层 | 手段 | 覆盖点 |
| --- | --- | --- |
| 纯逻辑（无 IO） | Hypium Local Test | Catalog 完整性（键唯一/域 ID 唯一/scope 合法）、信封编解码容错、迁移规则选择、合并器幂等/冲突、调度器节流/退避/单飞/门禁 |
| 域适配器 | Hypium + `MemoryPreferencesStore`（现有测试已有该假实现） | 读旧格式→升级→写新格式；损坏数据兜底；导出 payload 形状 |
| 跨进程路径 | DevEco 编译 + 模拟器手测（用户明确要求时才启动应用） | 升级迁移提醒、导出文件保存、导入恢复、登出后数据保留、切号镜像重建 |
| 回归 | 现有 44 个 Hypium 测试文件必须全绿 | `FavoriteUnit`/`HistoryReadLedgerUnit`/`CacheEnvelopeUnit`/`SessionUnit` 等直接受影响的用例 |

新增测试文件：

- `entry/src/test/PersistenceCatalogUnit.test.ets`
- `entry/src/test/PersistenceMigrationUnit.test.ets`
- `entry/src/test/DataTransferUnit.test.ets`
- `entry/src/test/SchedulerUnit.test.ets`

## 12. 风险登记与回滚

| # | 风险 | 概率 | 影响 | 缓解 | 回滚 |
| --- | --- | --- | --- | --- | --- |
| R1 | 迁移把数据写坏 | 低 | 高 | 双键 pending 保护；旧键保留 30 天；迁移前导出一份建议 | 旧版本 App 回滚 + 旧键仍可读 |
| R2 | 登出语义改造导致登录后数据异常 | 中 | 高 | 分两步放开（先保守版）；登录路径单测；`clearAuth` 顺序注释保持 | 恢复 reset 全量（一行开关） |
| R3 | 导出文件泄露隐私 | 中 | 高 | 默认加密；隐私提示；不导出凭证 | 无法回滚（用户文件），文档警示 |
| R4 | 导入覆盖用户新数据 | 中 | 中 | 导入计划确认；undo 快照 10 分钟 | 「撤销导入」 |
| R5 | 调度器改动导致轮询不再运行 | 中 | 中 | P5 与现状日志对照；任务表快照可见；保留旧 `PollingController` 直到验证通过 | 关闭调度器任务开关（`SchedulerTask.enabled` 常量） |
| R6 | Preferences 16MB 上限被单域打爆 | 低 | 高 | 单域 4MB 告警；AI 会话/工具缓存已有上限；导出前体积检查 | 清缓存入口 |
| R7 | 旧键与新键并存造成双倍写入 | 低 | 低 | 迁移完成后旧键只读不写；30 天后清理 | 手动清理 |
| R8 | 系统备份恢复旧数据但用户不知道 | 中 | 中 | P2 触发路径覆盖 + 迁移提醒 | 数据管理页可见 |
| R9 | ArkTS 严格模式编译失败（接口/泛型） | 中 | 低 | 按 `entry/src/AGENTS.md` 约束设计（类/接口显式实现、不用索引签名） | 编译期暴露，逐项修 |

## 13. 附录

### 13.1 键迁移映射全表

| 旧键 | 新键 | 迁移方式 | 旧数据清理 |
| --- | --- | --- | --- |
| `auth` | `v2.auth` | 原样复制（不补 cid；缺失时由 `AuthStore.recoverSession` 的本地自愈路径处理） | 立即删除（凭证旧键不等 30 天，见 §5.6） |
| `sessions` | `v2.sessions` | 复制 | 保留 30 天 |
| `settings_<uid>` ×N | `v2.settings` | 取当前登录 uid 那份 | 保留 30 天 |
| `nga_theme` | `v2.theme` | 复制 | 保留 30 天 |
| `cached_categories` | `v2.categories` | 复制 | 保留 30 天 |
| `cached_profiles_v2_<uid>` ×N | `v2.profiles` | 多份合并 | 保留 30 天 |
| `cached_notifications_<uid>` | `v2.notifications` | 信封升级 + owner | 保留 30 天 |
| `cached_activities_<uid>` | `v2.activities` | 同上 | 保留 30 天 |
| `favorite_topic_membership_v1_<uid>` | `v2.favorite_membership` | 同上 | 保留 30 天 |
| `history_<uid>` ×N | `v2.history` | 多份合并去重 | 保留 30 天 |
| `reading_progress_<uid>` ×N | `v2.reading_progress` | 多份合并去重 | 保留 30 天 |
| `votes_<uid>` ×N | `v2.votes` | 多份合并 | 保留 30 天 |
| `pollVoted_<uid>` ×N | `v2.poll_voted` | 多份合并 | 保留 30 天 |
| `tracked_threads_<uid>` | `v2.tracked_threads` | 信封升级 + 按 tid 去重、上限 50 | 保留 30 天 |
| `ai_sessions_<uid>` | `v2.ai_sessions` | 信封升级 + 按 id 去重、上限 20 + 清 ownerUid | 保留 30 天 |
| `ai_tool_cache_<uid>` | `v2.ai_tool_cache` | 丢弃（缓存） | 保留 30 天 |
| `filesDir/drafts/*.json` | `filesDir/v2/drafts/*.json` | 逐文件搬移 | 保留 30 天 |
| `filesDir/saved_threads/*.json` | `filesDir/v2/saved_threads/*.json` | 逐文件搬移 | 保留 30 天 |
| `filesDir/draft_media/` | 原位 | — | — |
| `filesDir/mphoto/` | 原位 | — | — |

### 13.2 新增/修改文件清单（Phase 1–P5）

```
新增
  entry/src/main/ets/common/persistence/PersistenceTypes.ets      // 枚举/DomainSpec/DomainEnvelope/迁移报告
  entry/src/main/ets/common/persistence/PersistenceCatalog.ets    // 21 域静态注册表（唯一真相）
  entry/src/main/ets/common/persistence/PersistenceHub.ets        // 治理编排器（读写/健康/统计/flush）
  entry/src/main/ets/common/persistence/StorageBackends.ets       // Preferences/JsonFile 后端
  entry/src/main/ets/common/persistence/PersistenceMetaStore.ets  // v2.meta 读写
  entry/src/main/ets/common/persistence/MigrationEngine.ets       // 迁移编排（检测/计划/执行/清理）
  entry/src/main/ets/common/persistence/DomainMigrators.ets       // 各域旧键→新域规则与合并
  entry/src/main/ets/common/persistence/DomainHealth.ets          // 域健康状态
  entry/src/main/ets/common/scheduler/SchedulerTypes.ets          // 触发源/任务/状态类型
  entry/src/main/ets/common/scheduler/AppScheduler.ets            // 调度器（单飞/节流/退避/门禁）
  entry/src/main/ets/common/scheduler/BuiltinTasks.ets            // 7 个内置任务注册
  entry/src/main/ets/common/transfer/TransferTypes.ets            // 容器/计划/结果类型
  entry/src/main/ets/common/transfer/TransferCrypto.ets           // 加密容器（PBKDF2+AES-GCM，独立 AAD）
  entry/src/main/ets/common/transfer/DataTransferService.ets      // 导出/导入/脱敏/撤销
  entry/src/main/ets/common/transfer/DomainMergers.ets            // 各域导入合并器
  entry/src/main/ets/common/utils/FilePickUtils.ets               // picker 封装 + URI 读写
  entry/src/main/ets/pages/DataManagementPanel.ets                // 数据管理页
  entry/src/main/resources/base/media/settings_data_management.svg // 设置入口图标
  entry/src/test/PersistenceCatalogUnit.test.ets
  entry/src/test/PersistenceMigrationUnit.test.ets
  entry/src/test/DataTransferUnit.test.ets
  entry/src/test/SchedulerUnit.test.ets
修改
  entry/src/main/ets/store/AppStore.ets        // Hub 初始化/启动迁移/设备级与镜像域分离/clearAuth/调度接线/导入后重载
  entry/src/main/ets/store/{Auth,Settings,Category,Profile,Notification,FollowActivity,Favorite,
                            TrackedThread,History,ReadingProgress,Vote,AiSession,AiToolCache,SavedThread}Store.ets
                                             // 统一域键、取消 uid 物理隔离、加载门禁
  entry/src/main/ets/store/settings/domain/ThemeSettings.ets // v2.theme
  entry/src/main/ets/common/infra/CacheEnvelopeStore.ets     // 域信封工具（ownerUid 软隔离 / 旧格式兼容）
  entry/src/main/ets/common/infra/PreferencesStore.ets       // deleteKey/hasKey/getAll
  entry/src/main/ets/common/managers/DraftStore.ets          // filesDir/v2/drafts
  entry/src/main/ets/entryability/EntryAbility.ets           // 前后台只派发调度事件；onDestroy 关调度器
  entry/src/main/ets/store/RouterStore.ets                   // 新增 dataManagement Screen
  entry/src/main/ets/pages/MainPage.ets                      // 迁移提醒弹窗
  entry/src/main/ets/pages/SettingsPanel.ets                 // 数据管理入口 + 迁移徽标
  entry/src/main/ets/pages/ActivityRouter.ets                // DataManagementPanel 路由分支
  entry/src/main/ets/pages/LoginPage.ets                     // 凭证导入文件大小上限 + fd 泄漏修复
  entry/src/main/ets/common/security/CredentialExportCrypto.ets // iterations/字段长度校验
  entry/src/main/ets/common/constants/AppStorageKeys.ets     // migrationStatus/dataManagementVersion
  entry/src/main/ets/common/constants/Constants.ets          // 数据管理图标色
  entry/src/test/CacheEnvelopeUnit.test.ets                  // 按新信封语义重写
  entry/src/test/HistoryReadLedgerUnit.test.ets              // 旧键改 v2.history
  entry/src/test/List.test.ets                               // 注册 4 个新 suite
未改
  entry/src/main/resources*/element/string.json              // 文案暂用中文字面量（与 FontSizeSettingsPanel 一致）
  entry/src/main/module.json5                                // picker 免权限，无新增权限
```

### 13.3 实施记录

> 每阶段完成后补记：日期、完成项、验证方式、遗留问题。

- **2026-10-30 设计定稿 + Phase 1 基础设施**：
  - 完成本设计文档；三份并行调研完成（[盘点](research/PERSISTENCE_INVENTORY.md)、
    [调度](research/SCHEDULER_RESEARCH.md)、[导出导入](research/EXPORT_IMPORT_RESEARCH.md)），
    其结论（picker API 纠偏、apiKey 脱敏、ai_sessions 隐私降级、draft_media 排除、iterations 校验、
    fd 泄漏、回前台请求风暴）已并入本文。
  - 基础设施落地：`PersistenceTypes` / `PersistenceCatalog`（21 域）/ `StorageBackends` /
    `PersistenceMetaStore` / `DomainHealth` / `PersistenceHub` / `DomainMigrators` / `MigrationEngine` /
    `TransferTypes` / `DataTransferService` / `SchedulerTypes` / `AppScheduler` / `TransferCrypto` /
    `DomainMergers` / `FilePickUtils`。
  - 接入：`PreferencesStore` 扩展（getAll/hasKey/deleteKey）、`AppStore`（Hub 初始化 + 启动迁移 +
    设备级/镜像域分离加载 + 迁移报告发布 + 数据管理 Facade）、`RouterStore`（dataManagement）、
    `SettingsPanel`（数据管理入口 + 迁移徽标）、`MainPage`（迁移提醒）、`ActivityRouter`（面板路由）。
  - 单测：`PersistenceCatalogUnit` / `PersistenceMigrationUnit` / `SchedulerUnit` / `DataTransferUnit`。
  - **Phase 2 域接入**：15 个 Store（17 个文件）完成统一键迁移——`v2.<domain>` 命名空间、取消 uid
    物理隔离、设备级域无条件加载、账号镜像域 `ownerUid` 软隔离、`CacheEnvelopeStore` 重写为域信封工具、
    文件域改 `filesDir/v2/drafts` 与 `filesDir/v2/saved_threads`。
  - **Phase 5 调度器接入**：`BuiltinTasks` 注册 7 个内置任务（会话校验/自动签到/通知轮询/动态轮询/
    跟踪检查/草稿清理/旧数据清理），`EntryAbility.onForeground` 不再并列直调三个动作，
    `AppStore` 在初始化完成、前台/后台、登录/登出时派发对应触发源。
  - 顺带修复调研发现的既有缺陷：凭证导出 fd 泄漏、凭证导入文件大小无上限、
    凭证解密 `iterations` 无上下限、`DocumentPickerMode` 的 tablet/2in1 兼容告警。
  - **验证（2026-10-30 实测）**：
    - `hvigorw clean + assembleHap`：**BUILD SUCCESSFUL**（全量 CompileArkTS 37s，无 ERROR；
      仅有项目既有的设备能力/弃用类 WARN）。
    - Hypium Local Test（`hvigorw test -p module=entry -p coverage=false`）：
      **Tests run: 679, Failure: 0, Error: 0, Pass: 679, Ignore: 0**
      （`entry/.test/default/intermediates/test/coverage_data/test_result.txt`）。
      新增套件：`persistenceCatalog`(12) / `persistenceMigrationRules`(14) / `appScheduler`(22) /
      `dataTransferMergers`(16)。
    - 行尾：`node scripts/check-eol.mjs` → 全部已跟踪文本文件为 LF。
    - 交付物：HAP `entry-default-signed.hap`（10.12MB，编译时间戳晚于全部源码改动）。
    - **测试期间发现并修复的两个运行期缺陷**（编译期不报）：
      ① `PersistenceCatalog` 的 `DomainIds` 类声明在 `buildSpecs()` 之后，导致模块静态初始化
      `ReferenceError: DomainIds is not initialized`（应用启动与测试页都会崩）——已把 `DomainIds`
      前置并加注释；
      ② `TransferCrypto` 的加密用例在 Previewer 环境无法加载 `libcryptoframework_napi.dll`，
      导致整个测试页崩溃——加密用例已从 Local Test 移除，加密链路改为真机手动验证
      （见 `DataTransferUnit.test.ets` 文件头）。
  - **遗留（见 §10 P6 与 R5）**：草稿跨账号导入的 uid 哈希重算未实现；`credential.recheck`
    保留 AppStore 既有退避定时器（未迁入调度器，降低回归风险）；`notifications/activities` 的
    `loaded` 语义（登录后重载）沿用既有 init 调用路径。
  - 导入后内存重载已实现：`AppStore.reloadAfterImport()`（设备级域重新 init、懒加载域 reset 后按需重读、
    文件域重扫、镜像域重载），数据管理页在 applyImport / undoImport 成功后调用，导入数据无需重启即生效。
- **2026-10-30 交付后自检（文档 ↔ 代码一致性 + 运行时路径审查）**：
  - 修复 5 个代码缺陷：① 迁移器信封域未按业务键去重/截断（多账号旧键会叠加重复条目、突破 Store 上限），
    现按 `notificationId/id/tid` 去重、时间取新、按域上限（200/200/50/20）截断；② `Catalog` 的
    `draft_media` 导入策略由覆盖改为 SKIP（导出 NEVER，覆盖无意义）；③ 撤销导入时文件域未清理
    "导入新增的文件"，现先清目录再回写快照；④ settings 导入未还原本机被脱敏的 AI API Key，
    会导致导入设置后 AI 不可用（现按 id 为空值回填本机密钥）；⑤ 未登录时迁移账号镜像域会写入空
    `ownerUid` 造成串号，现未登录跳过镜像域迁移（服务端可重建）。
  - 修正文档与实现不一致项：§2.3 域表 schema/导入策略、§4.1–4.3 载荷双模式与写路径、§5.4 迁移
    映射逐行对齐实现、§6.4 跟踪域时间字段（`lastCheckAt`）、§7.4 已注册/未注册任务清单、
    §8.2 登出语义实际口径、§8.4 放弃 adapter 两阶段方案、§10 阶段状态、§13.2 实际文件清单。
  - 复验：全量编译 + Hypium（见 §13.3 顶部验证记录）。
- **2026-10-30 独立上下文复核（两个 fresh reviewer：代码正确性 + 文档一致性/安全）后的修复**：
  - **P0 修复**：
    ① 账号镜像域迁移跨账号串号（`convertMirrorEnvelope` 合并了其它 uid 的旧键后统一标当前 uid）→
    改为**只合并当前账号 uid 的旧键**，无匹配则 SKIPPED 且旧键保留待登录后重试；
    ② 撤销导入的文件域 undo 键冲突（`fullKey()` 对文件域返回空串，drafts 与 saved_threads 共用
    `.undo`，撤销会清空草稿）→ 文件域改用 `v2.<domainId>.undo`。
  - **P1 修复**：
    ③ 旧键清理的二次校验不足（延迟/失败域被用户先写新键后，30 天后旧数据被删）→ 只有 MIGRATED 域
    的旧键进入清理清单，SKIPPED/FAILED/DEFERRED 旧键永久保留重试；
    ④ 文件域迁移反复检测（用户删掉的旧草稿/存档复活）与坏文件导致每次启动"迁移失败"弹窗 →
    检测以 meta 报告为准（已迁移不再检测），全无效文件改 SKIPPED，逐文件检查启动预算（超时 DEFERRED）；
    ⑤ settings/favorite_membership 无当前账号匹配时 fallback 到他人旧键 → settings 多份无匹配则跳过、
    收藏关系无匹配则 SKIPPED（旧键保留待重试）；
    ⑥ 「清空本地数据」不彻底（draft_media 子目录删不掉、旧键/旧目录不删导致复活）→ 递归删除目录、
    一并删除旧键与旧目录、清空后主题恢复默认；
    ⑦ 导入/撤销写失败被忽略（`putString` 吞错）→ 治理写入增加写后读回校验、文件域写失败上报、
    部分失败也重载内存；`reloadAfterImport` 补主题重载。
  - **P2 修复**：清空后主题写回、调度器 shutdown 后不可重建（init 时重建实例）、
    导出镜像域前校验 ownerUid 归属、`clearAuth` 注释如实说明 cancel/reset 不真正取消在途写。
  - **P2 已知取舍（未改代码）**：`votes`/`poll_voted` 设备级共享——若投票帖入口依据本地记录判定
    "已投"并禁用投票，切换账号后可能误禁用（需真机验证，列在下方遗留）；`undo` 快照含 settings
    明文 API Key（10 分钟 TTL 兜底）；数据健康「修复」按钮、调度状态区、导出域级进度/分组、
    草稿跨账号提示均为**未实现的文档承诺**（本文档已逐处标注）。
  - 复验：全量编译 + Hypium 见顶部验证记录（修复后重跑）。

### 13.5 遗留清单（文档承诺但未实现 / 需真机验证）

| 项 | 状态 |
| --- | --- |
| 数据管理页「数据健康」的「修复」按钮 | 未实现（仅展示异常域） |
| 数据管理页「调度状态」折叠区 | 未实现（仅 `snapshot()` API 与日志） |
| 导出域级进度、4MB 预警、六组分类、每域体积 | 未实现（平铺列表 + 运行中文案） |
| 草稿跨账号一次性提示（马甲场景） | 未实现（仅键内 uid 哈希隔离） |
| 草稿跨账号导入的 uid 哈希重算 | 未实现（导入到其他账号后旧草稿不可见） |
| `credential.recheck` 迁入调度器 | 有意保留 AppStore 既有退避定时器 |
| 文件域迁移预算/断点续跑 | 已实现（逐文件检查 deadline，超时 DEFERRED） |
| 加密容器/checksum 往返、系统备份恢复、投票入口语义 | 需真机/模拟器实测（Local Test 无法覆盖 crypto 与真实恢复） |

### 13.4 与既有实现的兼容策略（实施口径）

| 场景 | 行为 |
| --- | --- |
| 旧版本 App 回滚 | 旧键在迁移后保留 30 天（`legacyCleanupAt`），旧版本仍可读；新键 `v2.` 不被旧版本识别（等价于旧版本看不到新数据） |
| 系统备份恢复旧数据 | 恢复后磁盘等价于旧版本目录 → 首次启动触发迁移（P2 路径），MainPage 提醒 |
| 升级后首次启动 | 迁移在 `AppStore.init` 内、Store 加载前完成；超时域标记 `deferred` 下次继续 |
| 迁移后再次启动 | `v2.meta` 存在且 `completed` → 只做旧数据清理检查，无迁移开销 |
| 未登录状态 | 设备级域（设置/历史/进度/投票/AI/草稿/存档）全部可用；镜像域为空 |
| 退出登录 | 设备级域保留；镜像域清内存、磁盘保留（换账号按 ownerUid 作废） |
| 切换账号 | 只重载镜像域；设备级数据共享（ADR-001 的产品决策） |


## 14. 调研文档索引与关键结论

| 文档 | 关键结论（对实现的直接影响） |
| --- | --- |
| [`PERSISTENCE_INVENTORY.md`](research/PERSISTENCE_INVENTORY.md) | 23 个数据域、12 个物理分键族、4 种隔离形态；登出从不清盘；`writeQueue.cancel/reset` 疑似失效；3 处严格信封"读失败写空"数据丢失点；`uidGuard` 死代码。→ 本设计 §0.1.1 的风险清单与 Phase 2 修复项。 |
| [`SCHEDULER_RESEARCH.md`](research/SCHEDULER_RESEARCH.md) | 系统级后台任务全部不适合（workScheduler 2h 起且 2min 超时、reminderAgent 不执行代码、长时任务被 TTS 占用）；现状触发点 = Ability 9 + 页面 8 + 定时器 8 + 系统事件 4；首要问题"回前台请求风暴"。→ §7.5 结论与调度器"串行 + 错峰"要求。 |
| [`EXPORT_IMPORT_RESEARCH.md`](research/EXPORT_IMPORT_RESEARCH.md) | 凭证链路 3 缺陷（iterations 无上下限、fd 泄漏、密码无二次确认）；`DocumentSavePicker` 不存在（正确为 `DocumentViewPicker.save`）；settings 含明文 API Key；picker 免权限。→ §6.3 / §6.6 纠偏清单与 `TransferCrypto` 参数校验。 |


