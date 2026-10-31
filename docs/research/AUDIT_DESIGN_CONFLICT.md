# 审计报告：设计稿 ↔ 实现一致性（持久化统一治理 + 数据管理导出/导入）

> 审计对象：`docs/PERSISTENCE_UNIFICATION_DESIGN.md`（1476 行，后文简称「设计稿」）与
> `entry/src/main/ets/common/persistence/*`、`common/transfer/*`、`store/AppStore.ets`、
> `pages/DataManagementPanel.ets`、`pages/SettingsPanel.ets`、`pages/MainPage.ets`、
> `entryability/EntryAbility.ets`、`entry/src/test/*` 的实现。
> 审计日期：2026-10-31。只读审计，未修改任何源码、未运行编译/测试/模拟器。
> 证据口径：所有结论均给出「设计稿行号 / 代码文件:行号」，不做推断性指控；标注「（未核对）」的
> 条目已超出本次必读范围，需后续补充。

---

## 1. 概述

### 1.1 审计范围

本次审计聚焦「持久化数据统一治理（Persistence Unification）」与「数据管理（导出/导入）」两处重构
（git 4e971cfe、cfc7d95e）的**设计契约与实现一致性**，并检查导出/导入与迁移、清空、登出、健康、
调度等治理面的**交叉冲突**。审计点对应共享任务 task-3 的 6 项检查要求。

### 1.2 结论摘要

| 级别 | 数量 | 编号 |
| --- | --- | --- |
| P0（默认路径可达的数据损坏 / 崩溃 / 安全漏洞） | **0** | —（未发现满足 P0 定义的问题，见 §3.0 说明） |
| P1（契约落空 / 可复现数据丢失或隐私串号路径） | **4** | DES-01、DES-02、DES-03、DES-04 |
| P2（文档未更新 / 语义标签冲突 / 误导性 UI / 覆盖缺口） | **14** | DES-05 ～ DES-18 |
| P3（措辞、结构、可维护性观察） | 若干 | 见各差异表「低影响」行 |

**总体判断**：导出/导入的**核心行为**（21 域登记、合并语义常量、选择性导出、加密参数、撤销移除、
AI Key 不脱敏、清空防复活）与设计稿**主体一致**；主要问题集中在四类：

1. **设计稿承诺但代码不存在的机制**：导入「逐域升级器」（DES-01）；
2. **迁移与导出/导入的时序耦合缺口**：迁移异常/未完成时导出不可用或备份缺域，且清空会删旧键（DES-02）；
3. **同一枚举/契约出现两套语义**：缓存/镜像域的 `SKIP` 从「永不导入」改为「默认不恢复」后，
   Catalog 值、枚举注释、§2.3 表未同步（DES-03）；
4. **镜像域跨账号导入串号**：备份容器不带来源账号，导入时无条件标记当前 `uid`，换号恢复会串号（DES-04）。

另有大量**文档自身矛盾**（撤销导入相关章节未清理、§2.3 域数 15/16 不一致、theme/settings 策略标签
与 §6.4 冲突、4MB 预警前后矛盾、§13.5 与 §13.4 顺序颠倒、§6.3 引用错位等），逐条列在 §2.10。

### 1.3 对 Lead 初筛 7 个疑点的逐条结论

| # | 初筛疑点 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | §2.3 表格 vs Catalog 21 域逐格字段 | **大体一致**；逐格差异仅 4 处：`settings` 导入策略、`theme` 导入策略、`draft_media`/`moving_photo_cache` 的 schema（表写「—」实为 1）、以及表内未定义 `clearable/rebuildable/rawPayload/label` 四列 | §2.1 表；DES-06、DES-07 |
| 2 | §6.4 合并语义表 vs `DomainMergers` | **常量与语义全部一致**：history 500 / reading_progress 200 / votes 200 / poll_voted 200 / tracked 50 / ai_sessions 20；时间字段与回退字段一致；settings 数组字段为 `blacklist/filterKeywords/notes/favorites/aiProfiles/aiSearchProfiles/aiPresets` 7 个。**`SETTINGS_ARRAY_KEY_FIELDS` 无 `aiTasks`——因为持久化结构里本来就没有 `aiTasks` 字段；「AI 任务」对应 `settings.aiPresets`（`AiAgentPreset`），已按 `id` 并集**。属文档措辞与字段名不对应，非实现遗漏 | `DomainMergers.ets:33-50,134-161`；`SettingsState.ets:58-82`；`AiAgentPreset.ets:2-4` |
| 3 | §6.4「逐域执行升级器」是否存在 | **不存在**。`DataTransferService` 只有版本拒绝（`formatVersion`/`dataVersion` 高于当前拒绝；域 `schemaVersion` 高于当前跳过），无任何 `upgrade*` 逻辑，也未复用 `DomainMigrators`。当前所有域 schemaVersion=1，故无现网行为缺陷，但**属设计承诺未实现**（DES-01） | 设计稿 781、836；`DataTransferService.ets:412-510,472-477` |
| 4 | 撤销导入已移除 vs `clearLegacyUndoSnapshots` 残留、SKIP 语义 | **代码侧处理正确**：不再写 `v2.<domain>.undo`，仅保留清理旧版残留（启动 + 清空时调用）；`SKIP` 的实际行为已改为「默认不恢复，可由导入计划开关恢复」。**问题在文档/注释未同步**：§2.3 表仍写「跳过」、`PersistenceTypes` 枚举注释仍写「不导入」、§6.7/§9.2/§6.6#10/§12 仍写撤销导入（DES-03、DES-05） | `DataTransferService.ets:646-686`；`AppStore.ets:334,1279`；`PersistenceTypes.ets:54-56`；设计稿 802-807、825-828、864-865、878、1163、1210 |
| 5 | §6.6 导出前隐私提示、§6.3 顶部全选/全不选 | **全选/全不选已实现**；**隐私提示已实现但为「恒定提示」而非「勾选 AI 会话/浏览历史时提示」**：导出弹窗副标题与加密开关旁固定展示「未加密文件包含浏览历史、AI 对话、AI API Key 等隐私内容」，与勾选状态无关。判定：实现更保守，文档未更新（DES-11 附注） | `DataManagementPanel.ets:425,1201-1209,1248,1261-1288` |
| 6 | §6.7 UI 流程 vs §13.5 遗留清单是否自洽 | **不自洽**：§6.7 与 §9.2 仍列「撤销导入」「数据健康修复」「调度状态」等，§13.5 承认修复/调度状态/导出分组等未实现，§6.4 已宣布撤销导入移除——同一文档三处冲突（DES-05、DES-13） | 设计稿 868-884、1148-1164、1440-1453 |
| 7 | 交叉冲突（四维组合 / schemaVersion / dataVersion / 迁移未完成导出 / 清空复活 / 登出与 ownerUid） | 逐项结论见 §2.11 矩阵：①四维组合无严重自相矛盾（`NEVER` 导出域也可 `clearable=true`、`INCLUDE` 域全部 `clearable=true`）；②schemaVersion 全 1 但计划做版本拒绝：只对伪造/未来数据生效，**无升级路径**；③`dataVersion`/`formatVersion`/域 `schemaVersion` 三者分离清晰，未见混用，但 `dataVersion=0` 被接受（DES-12）；④**迁移未完成时导出会缺域**，且随后清空会删旧键（DES-02）；⑤清空后旧数据复活已被防住（删旧键/旧目录/文件域检测依赖 meta），但清空后迁移报告 UI 残留（DES-09）；⑥登出后镜像域导出被跳过（防外带），但**导入侧无对称校验**（DES-04） | §2.11、§3 |

---

## 2. 设计稿 ↔ 实现差异表

判定列取值：**一致** / **冲突** / **遗漏**（设计承诺未实现）/ **文档未更新**（实现已变、文档仍旧）。
「表内未定义」表示设计稿 §2.3 表格本身没有该列，无法逐格对照，改用其他章节交叉核对。

### 2.1 §2.3 全量域清单（21 域逐格核对）

设计稿表格列：新版键/目录、介质、scope、schema、导出、导入策略、登出行为（设计稿 263-285）。
Catalog 实际字段：`label/key/dirName/schemaVersion/scope/exportPolicy/importPolicy/clearable/rebuildable/avgItemBytes/note`（`PersistenceCatalog.ets:63-173`）+ 后置的 `rawPayload`（185-195）。

| # | 域 | 设计稿声明（行号） | 实现实际（Catalog 行号 / 其他证据） | 判定 |
| --- | --- | --- | --- | --- |
| 1 | `auth` | `v2.auth` / Pref / SECRET / schema 1 / 导出永不 / 导入拒绝 / 登出「清空（当前态）」（265） | PREFERENCES / key `auth` / schema 1 / SECRET / NEVER / NEVER / clearable=false / rebuildable=false / rawPayload=true / label「登录凭证」（63-67）；`AuthStore.clearAuth` 清当前态（`AuthStore.ets:134-151`） | 一致（表内未定义 clearable/rebuildable/rawPayload/label） |
| 2 | `sessions` | `v2.sessions` / Pref / SECRET / 1 / 永不 / 拒绝 / 登出「保留（多会话表）」（266） | 同 auth 形态（68-72）；clearAuth 只删当前 token 会话、其余会话保留（`AuthStore.ets:134-139`） | 一致 |
| 3 | `settings` | `v2.settings` / Pref / DEVICE / 1 / 默认 / **字段合并** / 保留并重载（267） | INCLUDE / **SPECIAL** / clearable=true / rawPayload=true（74-78）；`mergeSettings` 字段级覆盖 + 数组并集（`DomainMergers.ets:173-235`）；§6.4 表格写「字段级：导入值覆盖本机值」（792） | **冲突**（「字段合并」= MERGE_FIELDS vs 实现 SPECIAL；§2.3 与 §6.4 用词不一致，语义实际相符） |
| 4 | `theme` | `v2.theme` / Pref / DEVICE / 1 / 默认 / **覆盖** / 保留（268） | INCLUDE / **MERGE_FIELDS** / rawPayload=true（79-83）；`mergePayload` 对 theme 调 `mergeReplace` 整体覆盖（`DomainMergers.ets:137-138,244-264`）；§6.4 表格写「覆盖」（793） | **冲突**（策略标签与实现语义不符：MERGE_FIELDS 却做整体覆盖） |
| 5 | `categories` | `v2.categories` / Pref / DEVICE / 1 / 可选 / 跳过 / 保留（269） | OPTIONAL / SKIP / clearable=true / rebuildable=true（84-88） | 一致（「跳过」的现行语义见 DES-03） |
| 6 | `profiles` | 同上（270） | OPTIONAL / SKIP / clearable=true / rebuildable=true（89-93） | 一致 |
| 7 | `notifications` | `v2.notifications` / Pref / ACCOUNT_MIRROR / 1 / 可选 / 跳过 / 清内存、重载镜像（271） | OPTIONAL / SKIP / clearable=true / rebuildable=true / ENVELOPE（95-99、185-195）；clearAuth reset（`AppStore.ets:815`）、登录 `loadMirrorData`（743-750） | 一致 |
| 8 | `activities` | 同上（272） | 同 notifications 形态（100-104） | 一致 |
| 9 | `favorite_membership` | 同上（273） | 同 notifications 形态（105-109） | 一致 |
| 10 | `history` | `v2.history` / Pref / DEVICE / 1 / 默认 / 按键去重合并 / 保留并重载（274） | INCLUDE / MERGE_BY_KEY / rawPayload=true / note「上限 500 条」（111-115）；合并常量 500（`DomainMergers.ets:33`） | 一致 |
| 11 | `reading_progress` | … / 按键去重合并 / 保留并重载（275） | INCLUDE / MERGE_BY_KEY / note 200（116-120）；常量 200（`DomainMergers.ets:36`） | 一致 |
| 12 | `votes` | … / 按键去重合并 / 保留并重载（276） | INCLUDE / MERGE_BY_KEY / note 200 帖（121-125）；常量 200（`DomainMergers.ets:39`） | 一致 |
| 13 | `poll_voted` | … / 按键去重合并 / 保留并重载（277） | INCLUDE / MERGE_BY_KEY / note 200 帖（126-130） | 一致 |
| 14 | `tracked_threads` | … / 按键去重合并 / 保留并重载（278） | INCLUDE / MERGE_BY_KEY / ENVELOPE（131-135、185-195）；上限 `TRACK_MAX_COUNT=50`（`TrackedThread.ets:19`） | 一致 |
| 15 | `ai_sessions` | `v2.ai_sessions` / Pref / DEVICE / 1 / 可选（隐私）/ 按键去重合并（279） | OPTIONAL / MERGE_BY_KEY / ENVELOPE / note「含隐私内容，默认不勾选」（137-141）；上限 `MAX_AI_SESSIONS=20`（`AiSession.ets:18`） | 一致 |
| 16 | `ai_tool_cache` | … / 可选 / 跳过 / 保留（TTL 自净）（280） | OPTIONAL / SKIP / clearable=true / rebuildable=true / ENVELOPE（142-146） | 一致 |
| 17 | `drafts` | `v2/drafts/` / Files / DEVICE / 1 / 默认 / 按键覆盖 / 保留（281） | JSON_FILES / key='' / dirName `drafts/` / schema 1 / INCLUDE / REPLACE_BY_KEY（148-152）；`dirPath` → `filesDir/v2/drafts`（`PersistenceTypes.ets:242-259`） | 一致 |
| 18 | `draft_media` | `draft_media/`（沿用）/ Files / DEVICE / **schema —** / 永不（不可移植）/ 跳过 / 保留（282） | JSON_FILES / dirName `!draft_media/` / **schemaVersion 1** / NEVER / SKIP / clearable=true / rebuildable=false（153-157） | **文档未更新**（表写「—」实现为 1；文件域不套信封，schema 仅用于容器/计划，无实际影响） |
| 19 | `saved_threads` | `v2/saved_threads/` / Files / DEVICE / 1 / 默认 / 按 tid 覆盖 / 保留（283） | JSON_FILES / dirName `saved_threads/` / schema 1 / INCLUDE / REPLACE_BY_KEY（158-162） | 一致 |
| 20 | `moving_photo_cache` | `mphoto/`（沿用）/ Files / DEVICE / **schema —** / 永不（可重建）/ 跳过 / 保留（284） | JSON_FILES / dirName `!mphoto/` / **schemaVersion 1** / NEVER / SKIP / clearable=true / rebuildable=true（163-167） | **文档未更新**（同 draft_media） |
| 21 | `meta` | `v2.meta` / Pref / DEVICE / 1 / 永不 / 拒绝 / 保留（285） | PREFERENCES / key `meta` / schema 1 / DEVICE / NEVER / NEVER / clearable=false / rebuildable=false / rawPayload=true（169-173） | 一致（`rawPayload` 未在 §4.1 清单出现，见 DES-18） |

**表内未定义、需交叉核对的字段：**

| 字段 | 设计稿定义位置 | 实现实际 | 判定 |
| --- | --- | --- | --- |
| `label` | §2.1 `DomainSpec` 字段（223-240）有定义，§2.3 表无列 | 21 个域均有中文 label（63-173） | 表内未定义；无法逐格对照，实现齐备 |
| `clearable` | §2.1 有字段定义（235），§2.3 表无列；§2.3 治理边界（293-300）只说明 cacheDir 不入清单 | `clearable=false`：auth/sessions/meta（3 个）；其余 18 个 true（含 draft_media/moving_photo_cache） | **文档未更新/遗漏**（设计稿缺少逐域 clearable 口径，属契约不完整；实现与 §13.3「清空本地数据」描述基本吻合，但清空文案未覆盖媒体缓存，见 DES-14） |
| `rebuildable` | §2.1 有字段（236）；§2.3 note 隐含（categories/profiles 可重建、镜像域、ai_tool_cache、moving_photo_cache） | true：categories/profiles/notifications/activities/favorite_membership/ai_tool_cache/moving_photo_cache（7 个） | 一致（语义与 note 吻合） |
| `rawPayload` | §4.1（419-453）定义：ENVELOPE=通知/动态/收藏关系/跟踪/AI 会话/AI 工具缓存；RAW=其余存量域 | ENVELOPE 6 个与 §4.1 完全一致（`PersistenceCatalog.ets:185-195`）；RAW 15 个包含 §4.1 清单外的 `meta` | 一致；§4.1 清单遗漏 `meta`（DES-18，低影响） |
| `avgItemBytes` / `note` | §2.1 有字段（237-238），§2.3 无值 | 每域均有点位与中文 note（63-173） | 表内未定义；实现齐备（`note` 被导出弹窗展示，`DataManagementPanel.ets:1229`） |

### 2.2 §2.3 表格外的声明

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 「域数：21」（287） | `PersistenceCatalog.all().length = 21`（63-173；`validate()` 自检 349-392） | 一致 |
| 「scope 实际分布：DEVICE 15 / ACCOUNT_MIRROR 3 / SECRET 2」（287-291） | Catalog：DEVICE **16**、ACCOUNT_MIRROR 3、SECRET 2；且文档括注中实际列举了 16 个 DEVICE 域 | **冲突（文档自身算术错误）**（DES-06） |
| 「cancel uid 物理隔离后全部设备级域不再按 uid 分键」（291-292） | 各 Store 键从 Catalog 派生（`AuthStore.ets:20-31`、`HistoryStore.ets:19-20`、`SettingsStore.ets:47-48` 等），无 uid 拼键 | 一致 |
| 治理边界：cacheDir 临时产物不参与迁移/导出/清空；ArkWeb Cookie 刻意不纳入；系统云备份不在域治理内（293-300） | `clearable` 域不含 cacheDir；`WebViewCookieUtils` 独立（未核对细节）；`EntryBackupAbility` 空实现（设计稿自述） | 一致 |
| 域表「登出行为」列（265-285） | `clearAuth` 只 reset 三个镜像域 + 浮层/路由（`AppStore.ets:788-825`），设备级域不 reset（注释 803-814 明示刻意） | 一致（settings/history 等「保留并重载」中的「重载」在登出路径并不发生，属措辞冗余，无行为冲突） |

### 2.3 §4 统一存储层

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| ENVELOPE 字段 `{schemaVersion, domain, updatedAt, ownerUid, payload}`；`ownerUid` 仅 ACCOUNT_MIRROR（425-440） | `DomainEnvelope` 字段一致（`PersistenceTypes.ets:267-278`）；Hub 写信封时 `ownerUid` 由调用方传入（`PersistenceHub.ets:261-267`），导入时仅镜像域传当前 uid（`DataTransferService.ets:554-555`） | 一致 |
| RAW 域无信封、无版本字段（442-450） | `rawPayload=true` 域直接 JSON 落盘（`PersistenceHub.ets:156-160,258-259`） | 一致 |
| 「这样 15 个既有 Store 只换键」 | 实际 §13.3 写「15 个 Store（17 个文件）」；Catalog 有 21 域、4 个文件域 | **文档未更新（表述不一致，低影响）**（DES-18） |
| 读路径：无键→null；解析失败→null+健康；ENVELOPE 校验 domain/schemaVersion≤当前；ownerUid 校验在 Store 层（455-464） | `readPayload/readEnvelope` 实现一致（`PersistenceHub.ets:141-203`）；ownerUid 校验在 `CacheEnvelopeStore.parseItems`（`CacheEnvelopeStore.ets:125-160`） | 一致 |
| 「schemaVersion > 当前一律不解析」（470） | `readEnvelope` 版本判断（`PersistenceHub.ets:187-194`） | 一致 |
| 写路径：日常 Store 直写、不经 Hub；治理写入 `pending` 双键 + 写后读回校验；不双写（474-499） | `PreferencesBackend.writeRaw` 承担 pending/清洗（`StorageBackends.ets`，细节未逐行核对）；Hub 只在迁移/导入/导出路径使用（`AppStore.ets:1236-1237` 注释、`DataTransferService`）；`writePayload` 有健康记录（`PersistenceHub.ets:274-279`） | 一致（写后读回校验在 `PreferencesStore`/后端层，未逐行核对） |
| `flush` 分级、后台必 flush（497-498） | `flushAll`（`AppStore.ets:753-760`）、`EntryAbility.onBackground` 调 `flushAll`（`EntryAbility.ets:264-267`） | 一致 |
| 单域 4MB 告警：日志 warn + 数据管理页红字（§4.4 507；§4.5 524） | `DOMAIN_SIZE_WARN_BYTES` 与 `DomainHealth.isOversized` 存在（`PersistenceTypes.ets:126`；`DomainHealth.ets:132-135`），但**无任何调用方**，数据管理页也不展示超限红字；§6.3/§13.5 又承认「4MB 预警未实现」 | **冲突（文档自相矛盾 + 遗漏）**（DES-10） |
| 迁移器/导入器写盘前 `pending`、启动清 pending（525-528） | Hub.init 调 `cleanupPending`（`PersistenceHub.ets:70-72`） | 一致 |

### 2.4 §5 迁移

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 双版本模型：`dataVersion`（meta，当前 2）与域 `schemaVersion` 分离（535-568） | `PERSISTENCE_DATA_VERSION=2`、`BACKUP_FORMAT_VERSION=1`（`PersistenceTypes.ets:98-111`）；`v2.meta` 结构一致（345-367） | 一致 |
| 三触发路径 P1/P2/P3；P3 导入复用 P1 域升级器（570-582） | P1/P2 由 `MigrationEngine` 实现（`AppStore.ets:296-343`）；**P3 不存在**：`DataTransferService` 无升级器、不调用 `DomainMigrators` | **遗漏**（DES-01） |
| 启动时序：hub.init→check→run→Store 加载；无 `loadAll`（584-610、1077） | `AppStore.init` 顺序一致（`AppStore.ets:229-288`）；Hub 无 `loadAll`（全文 470 行） | 一致 |
| 总预算 3000ms，超时域 DEFERRED（609-610） | `MIGRATION_BUDGET_MS=3000`（`PersistenceTypes.ets:108`）；`run` 逐域检查 deadline（`MigrationEngine.ets:323-365`） | 一致 |
| §5.4 每域映射：精确键在前、前缀键在后；settings 当前 uid 优先/多份跳过；镜像只取当前 uid；集合域合并；ai_tool_cache 不迁移；文件域逐文件预算（612-643） | `LEGACY_RULES` 顺序一致（`DomainMigrators.ets:155-172`）；`convertSettings/convertMirrorEnvelope`（297-321、369-449）；`convertDropped`（736-745）；文件域 `runFileTask`（`MigrationEngine.ets:521-598`） | 一致 |
| 「只有 MIGRATED 域旧键进清理清单」（643） | `report.legacyKeys` 只合并 MIGRATED 的 key（`MigrationEngine.ets:326-368`） | 一致 |
| 凭证旧键立即删除（§13.1 1223） | `deleteLegacyCredentialKeys`（`MigrationEngine.ets:405-443`），仅新键读回校验通过才删 | 一致 |
| §5.5 提醒：`migrationStatus` 单一 AppStorage 键、`migrationNoticePending` + `acknowledgeMigrationNotice` 只提示一次（657-668） | `publishMigrationReport`（`AppStore.ets:407-411`）、`migrationNoticePending`（1133-1135）、`acknowledgeMigrationNotice`（1140-1155）、`MainPage.maybeShowMigrationNotice`（`MainPage.ets:135,153-185`） | 一致 |
| §5.5 提醒形式：成功 Toast 3s、部分失败对话框（单按钮「知道了」+「查看详情」跳数据管理页）（649-654） | 成功 `showToast`；失败 `showAlertDialog`（两个按钮「查看详情」/「知道了」）（`MainPage.ets:172-212`） | 一致（组件差异见 DES-15） |
| §5.6/§5.7（幂等、旧数据清理） | 未逐行核对；`cleanupLegacy` 存在（`MigrationEngine.ets:620+`）、`migration.legacyCleanup` 任务已注册（`BuiltinTasks.ets:171-172`） | （未核对，标注） |

### 2.5 §6 导出 / 导入

#### 6.1 容器格式

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 明文容器字段：magic/formatVersion/dataVersion/exportedAt/appVersionName/appVersionCode/deviceTag/domains/checksum（705-731） | `BackupContainer` 字段完全对应（`TransferTypes.ets:33-52`）；导出写入（`DataTransferService.ets:152-178`） | 一致 |
| `domains` 用数组保证顺序稳定，「同一数据两次导出字节级一致」（728） | 域顺序按 Catalog 声明顺序稳定；但 `exportedAt = Date.now()`（156）每次都不同，**整文件不可能字节级一致**（仅 `domains` 段一致） | **冲突（文档措辞不成立）**（DES-16） |
| checksum 可选；缺失时视为旧格式、跳过校验**并提示**（729-730） | 非空且不匹配→warning 继续（`DataTransferService.ets:380-393`）；**空 checksum 直接跳过、不提示** | **文档未更新/遗漏**（DES-11） |
| 加密容器字段与算法：PBKDF2-SHA256/120000/AES-256-GCM/12B IV/16B tag、AAD `nga-oh-data-backup-v1`（733-750） | `TransferCrypto` 参数与 AAD 完全一致（`TransferCrypto.ets:30-63,87-100`） | 一致 |
| deviceTag 仅诊断、导入不依赖（731） | 导出写死 `'phone'`（`DataTransferService.ets:159`）；导入不消费 | 一致 |

#### 6.2 加密与口令策略

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 口令最短 8 位、默认加密、关闭加密二次确认（752-756） | 8 位校验（`DataTransferService.ets:145-148`；`DataManagementPanel.ets:494`；`TransferCrypto.ets:198`）；`exportEncrypt` 默认 true（`DataManagementPanel.ets:415`）；关闭加密 `showAlertDialog` 二次确认（1261-1288） | 一致 |
| 口令不落盘、不记忆、不提供找回（757） | 仅内存 `@State exportPassword/importPassword`（`DataManagementPanel.ets:145`）；无持久化 | 一致 |
| 导入复用 `CredentialPasswordContent` 组件模式（758） | `DataManagementPanel` 导入弹窗使用 `CredentialPasswordContent`（`DataManagementPanel.ets:26,1343`） | 一致 |
| 口令错误与文件损坏同一提示（759） | `TransferCrypto` 统一抛「密码错误或备份文件已损坏」（`TransferCrypto.ets:297-301`） | 一致 |

#### 6.3 选择性导出

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 域清单按 `DomainSpec` 生成、平铺列表、名称+说明；默认勾选 INCLUDE（763-764） | `openExportDialog` 用 `PersistenceCatalog.exportable()`，INCLUDE 入默认勾选（`DataManagementPanel.ets:402-414`）；弹窗展示 label+note（1225-1233） | 一致 |
| 顶部「全选 / 全不选」（765） | 已实现（`DataManagementPanel.ets:1201-1209`） | 一致 |
| NEVER 域不出现；OPTIONAL 默认不勾选（766） | `exportable()` 排除 NEVER（`PersistenceCatalog.ets:269-278`）；默认只选 INCLUDE | 一致 |
| picker 纠偏（`DocumentViewPicker.save`）与文件名 `nga-backup-<YYYYMMDD-HHmmss>.ngabackup`（767-770） | `FilePickUtils.pickDocumentToSave`（120-131）；`DataManagementPanel.ets:523`（`BACKUP_SUFFIX='ngabackup'`，60 行常量） | 一致 |
| 大文件「正在生成…」、>64MB 拒绝（771） | 进度文案（`DataManagementPanel.ets:506,517,529,539`）；`exportBackup` 生成后 >64MB 拒绝（`DataTransferService.ets:184-188`） | 一致 |
| 未实现项：域级进度百分比、4MB 预警、分组展示、每域体积（列在 §13.3 遗留）（772） | 均未实现；但「§13.3 遗留」实为 §13.5（1440-1453） | **文档未更新（引用错位）**（DES-17） |

#### 6.4 导入策略与合并语义（重点）

**流程对照**：

| 设计稿流程步骤（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 识别 magic（明文/加密）→ 需要时口令 → 解析容器（779-780） | `parseBackup`（`DataTransferService.ets:286-397`）；旧 `.ngacred` 明确拒绝（727-730） | 一致 |
| 校验 formatVersion / dataVersion / checksum（780） | 计划阶段拒绝高版本（412-426）；checksum 降级为 warning（380-393） | 一致（宽松方向见 DES-11/12） |
| **逐域执行升级器（旧 formatVersion→当前；旧域 schemaVersion→当前）（781）** | **无任何升级器**；仅「域 schemaVersion 高于当前 → 跳过」（472-477） | **遗漏**（DES-01） |
| 生成导入计划：每域「新增/覆盖/跳过/合并」的条数与摘要（782） | 计划有 added/updated/skipped 计数（`DomainMergers`）与跳过原因；UI 只展示「新增 N 条 · 更新 M 条」或跳过原因，**不展示覆盖/合并语义**（`DataManagementPanel.ets:702-721`） | **文档未更新/部分实现**（DES-13） |
| 用户确认 → 逐域导入（每域写前备份到 `v2.<domain>.undo`）（783-785） | 无 undo 快照写入；直接写盘（`DataTransferService.ets:520-576`） | **文档未更新**（撤销已移除；见 DES-05） |
| 全部成功→写导入记录→刷新 Store→提示；有失败→保留 undo→提示可撤销（784-786） | 无导入记录、无 undo；`applyImport` 返回结果，UI 提示成功/部分失败，`reloadAfterImport` 重载（`DataManagementPanel.ets:742-773`） | **文档未更新**（DES-05） |

**每域合并语义对照（`DomainMergers.mergePayload` 派发 134-161）**：

| 域 | 设计稿 §6.4（790-803） | 实现实际 | 判定 |
| --- | --- | --- | --- |
| `settings` | 字段级覆盖；数组并集：黑名单按 uid、屏蔽词按关键词、备注按用户、收藏版块按 fid、AI 配置按 id、**AI 任务按 id**（792） | `mergeSettings`（173-235）；`SETTINGS_ARRAY_KEY_FIELDS = {blacklist:userId, filterKeywords:keyword, notes:userId, favorites:fid, aiProfiles:id, aiSearchProfiles:id, aiPresets:id}`（42-50）；`scenarioSystemPrompts` 按 key 合并（214-221）。`SettingsState` 无 `aiTasks` 字段；`aiPresets` 即「AI 任务」模型（`AiAgentPreset.ets:2-4`，「AI 任务（预设）」）；`aiTasks` 仅出现在 `ThreadPanel.ets:235`、`ProfileCardPopup.ets:38` 的 UI 临时态 | 一致（实现无遗漏；文档中文描述未映射到字段名，见 DES-13 附注） |
| `theme` | 覆盖（793） | `mergeReplace` 整体覆盖（244-264，派发 137-138） | 一致（与 §2.3/Catalog 标签冲突，见 DES-07） |
| `history` | 按 tid 取 ts 较新；按 ts 降序截断 500（794） | `mergeArrayPayloadByTime(...,'tid','ts','',500)`（139-140）；`mergeArrayByTime` 排序降序+截断（444-496） | 一致 |
| `reading_progress` | 按 tid ts 较新；截断 200（795） | 常量 200（141-143） | 一致 |
| `votes` / `poll_voted` | 按 tid 取 ts 较新；截断 200（796） | `mergeVotes`（331-347，`VOTE_MAX_ENTRIES=200`）；`mergePollVoted`（359-417，同样截断 200） | 一致 |
| `tracked_threads` | 按 tid 取 `lastCheckAt`（回退 `createdAt`）较新；按 50 截断（797） | `mergeArrayPayloadByTime(...,'tid','lastCheckAt','createdAt',TRACK_MAX_COUNT)`（144-146），`TRACK_MAX_COUNT=50` | 一致 |
| `ai_sessions` | 按 id 取 `updatedAt` 较新；总数超上限淘汰最旧；消息不合并（798） | `mergeArrayPayloadByTime(...,'id','updatedAt','createdAt',MAX_AI_SESSIONS)`（147-149），`MAX_AI_SESSIONS=20`；按时间降序截断 | 一致 |
| `drafts` | 按草稿键覆盖；导入时键末尾账号哈希改写为当前账号（799） | `mergeArrayPayloadByKey(...,'key')`（154-155）；`applyFileDomain` 用 `rewriteDraftKeyUidPart` 重写（585-628，604-616） | 一致（计划计数与写后键一致性见 DES-19） |
| `draft_media` | 媒体不包含、仅正文（800） | Catalog NEVER/SKIP（153-157）；导出弹窗有明示（`DataManagementPanel.ets:1312`） | 一致 |
| `saved_threads` | 按 tid 覆盖（801） | `mergeArrayPayloadByKey(...,'tid')`（156-157） | 一致 |
| 缓存/镜像域 | 「默认恢复（跟随导出选择）：备份里出现即覆盖；镜像域写当前账号 ownerUid；计划页可关闭『恢复缓存类数据』」（802） | `buildImportPlan`：SKIP 且 `restoreCacheDomains=false` → 跳过（461-471）；true → 走 `mergePayload` passthrough 整体覆盖（489-497；`DomainMergers.ets:158-160,425-429`）；`applyImport` 镜像域 ownerUid=当前 uid（554-555）；`restoreCacheDomains` 默认 true（`DataManagementPanel.ets:169`），弹窗开关触发重建计划（1365-1377） | 一致（与 §2.3 表/枚举注释冲突，见 DES-03；跨账号串号见 DES-04） |
| `auth` / `sessions` | 永不导入（803） | `ImportPolicy.NEVER` 计划跳过（444-449） | 一致 |

**导入完整性 / 安全性声明对照**：

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| AI API Key 原样导出（823、846-850） | 导出不做脱敏；旧包空密钥回填 `restoreLocalSecrets`（`DataTransferService.ets:1055-1160`、计划 480-482） | 一致 |
| 「撤销导入已移除」：不再写 undo，启动/清空时 `clearLegacyUndoSnapshots`（825-828） | 一致（`DataTransferService.ets:646-686`；`AppStore.ets:334,1279`） | 一致 |
| 导出完整性清单 7 行（813-823） | 逐项核对均成立：凭证/草稿媒体/动态照片永不；缓存域默认不选可勾选、导入默认恢复；ai_sessions 默认不选；他人镜像跳过；AI Key 原样 | 一致 |
| 「账号镜像域导出前校验 ownerUid，属于其他账号时跳过」（822、863） | `buildDomainEntry` 读信封 ownerUid，非空且 ≠ 当前 uid 则跳过（`DataTransferService.ets:213-226`） | 一致 |

#### 6.5 兼容性

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 旧版离线存档（无 magic，含 threads 数组）→ 转 `saved_threads`，不校验其 schemaVersion（834） | `tryConvertLegacySavedThreadExport`（`DataTransferService.ets:909+`），parse 阶段优先调用（302-308） | 一致 |
| 旧 `.ngacred` → 明确拒绝（835） | magic 识别拒绝（727-730） | 一致 |
| 未来 `formatVersion > 当前` → 拒绝、不部分解析（836） | 计划阶段拒绝（419-422）；解析阶段不拒绝（宽容解析，UI 提示升级） | 一致（拒绝时点在计划阶段，可接受） |
| 损坏文件分阶段校验（837） | magic→结构/版本整数→checksum→域 schema 分层（720-810、380-393、472-477） | 一致 |
| 超大文件：**读取前** `fileIo.stat` >64MB 拒绝；单域载荷 >8MB **跳过并计入计划**；域数 >64 拒绝；重复域 ID 只保留首个（838） | 读取前 stat 已按真机反馈**废弃**，改为读取后 UTF-8 字节校验（`FilePickUtils.ets:157-266` 文件头注释；`DataTransferService.ets:298-301`；`DataManagementPanel.ets:60,574`）；单域 >8MB 在 `normalizeContainer` 静默 `continue`（793-795），**不进入计划**；域数 >64 拒绝（763-766）；重复域 ID 保留首个（778-781） | **文档未更新 + 部分遗漏**（DES-11、DES-12） |

#### 6.6 安全与隐私清单（逐条）

| # | 设计稿声明（行号） | 实现证据 | 判定 |
| --- | --- | --- | --- |
| 1 | 凭证永不进数据包（842） | `ExportPolicy.NEVER` + 导入硬拒绝（`DataTransferService.ets:444-449`） | 一致 |
| 2 | 导出前隐私提示：**勾选 AI 会话/浏览历史时**在底部提示「包含敏感内容」（843） | 弹窗副标题恒定为「未加密文件包含浏览历史、AI 对话等隐私内容，建议保持加密」（425），加密开关旁固定提示（1248）；**不随勾选变化** | **文档未更新/实现简化**（DES-11 附注） |
| 3 | 加密默认开启、AAD 隔离（845） | 默认开启（`DataManagementPanel.ets:415`）；AAD 常量（`TransferCrypto.ets:30-31`） | 一致 |
| 4 | AI Key 不脱敏 + 导入侧 restoreLocalSecrets（846-850） | 一致（1055+） | 一致 |
| 5 | 文件路径：仅 picker URI；`isSafeDomainFileName` 拒绝 `/`、`\`、`..`（851-852） | `isSafeDomainFileName`（`DataTransferService.ets:950+`）用于文件域写入（617-620）；读取仅 picker（`DataManagementPanel.ets:569-574`） | 一致 |
| 6 | 解析防护：域数≤64、去重、版本正整数、单域≤8MB **跳过并计入计划**、文件>64MB 拒绝、条目上限由合并器截断（853-855） | 域数/去重/文件大小/条目截断一致；单域 >8MB 静默丢弃不进计划；`dataVersion` 允许 0（`DataTransferService.ets:749`）与「必须正整数」不符 | **部分遗漏**（DES-11、DES-12） |
| 7 | 加密参数防篡改：iterations 区间、kdf/cipher 白名单、salt/iv/tag 长度、doFinal 判空说明、口令错误/损坏同一提示（856-859） | 全部实现（`TransferCrypto.ets:238-306`） | 一致 |
| 8 | 文件句柄 try/finally（860-861） | `FilePickUtils` 读写均 try/finally（157-266、348-380，未逐行复核 finally 分支） | 一致（标注：未逐行核对） |
| 9 | 不导出临时态（undo/pending/工具缓存）；镜像域 ownerUid 校验（862-863） | pending 键不在域读路径；ai_tool_cache OPTIONAL；ownerUid 校验存在 | 一致 |
| 10 | 撤销快照生命周期（10 分钟、启动/清空清理）（864-865） | **撤销功能已移除**，仅 `clearLegacyUndoSnapshots` 清理旧残留；该条为文档残留 | **文档未更新**（DES-05） |
| 11 | 导出/导入各写一条日志，不含内容（866） | `export ok ...`（`DataTransferService.ets:193-194`）、`import ok ...`（573-574）；参数为计数/布尔 | 一致 |

#### 6.7 UI 流程

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 数据版本块：当前 v2、上次升级、旧数据 N 天后清理、重试升级（872） | `MigrationSection`：`migrationSubText`、`legacyCleanupText`、重试/立即清理按钮（`DataManagementPanel.ets:972-1041` 区段；数据源 246-299） | 一致 |
| 数据健康：✓ 正常 / ⚠ N 个域异常（点开详情 / **修复**）（873） | `HealthSection` 仅展示异常列表（`DataManagementPanel.ets:1043-1066`），**无「修复」按钮、无「正常」态展示**；§13.5 已承认未实现 | **冲突（文档自身：§6.7/§9.2 承诺 vs §13.5 承认未实现）**（DES-13） |
| 存储占用（估算）（874） | `StorageSection` + `estimateAll`（1068-1108） | 一致 |
| 导出数据 → 选择域 + 加密 → 保存（876） | 已实现（399-554） | 一致 |
| 导入数据 → 选择文件 → 口令 → 计划确认 → 执行 → 结果（877） | 已实现（556-773） | 一致 |
| **撤销导入（10 分钟内可见）**（878） | 无任何撤销 UI/逻辑 | **文档未更新**（撤销已移除；DES-05） |
| 清空本地数据（危险：二次确认 + 输入「清空」二字；保留凭证与存档可选）（880） | 二次确认 + 输入「清空」（`DataManagementPanel.ets:1430-1475`，`CLEAR_CONFIRM_WORD='清空'` 66 行）；**无「保留凭证与存档可选」选项**（实现固定保留凭证，存档在清空范围内） | **文档未更新/遗漏**（「保留凭证与存档可选」未实现；凭证固定保留、存档固定删除） |
| 入口位置：SettingsPanel Block 3C 之前新增 Block（883-884） | Block 3B2「数据管理」+ badge（`SettingsPanel.ets:711-719`） | 一致 |

### 2.6 §7 调度机制

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 已注册 7 个任务（993-1003） | `BuiltinTasks.ets:76-172` 注册 `session.verify/checkin.auto/notifications.poll/activities.poll/tracked.check/draft.cleanup/migration.legacyCleanup` | 一致 |
| 不注册：credential.recheck、toolcache.flush、persistence.flush（1005-1011） | 文档声明保留既有实现；`AppStore.scheduleCredentialRecheck`/`AiToolCacheStore`/`flushAll` 未迁入（未逐行核对） | 一致（标注） |
| `migration.retry` 未实现（1013-1014） | 无该任务；数据管理页「重试升级」手动调 `retryMigration`（`AppStore.ets:1190-1200`） | 一致 |
| 调度状态 UI 未实现（1048） | 数据管理页无调度区块 | 一致 |
| §8.3 前后台：`onForeground`→scheduler.notify(FOREGROUND)、`onBackground`→flushAll+notify(BACKGROUND)、`onDestroy`→shutdownScheduler（1114-1119） | `AppStore.setForegroundActive` 派发 BACKGROUND（`AppStore.ets:906-918`）、`reconcilePolling` 派发 FOREGROUND（934-944）；`EntryAbility.onBackground` 调 `flushAll`（`EntryAbility.ets:264-267`）；onDestroy/scheduler shutdown（未逐行核对） | 一致 |

### 2.7 §8 生命周期与 AppStore

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| 登录成功 4 步：setAuth+落盘、重载 3 镜像域、sessionGuard 复位、notify(LOGIN)（1081-1086） | `setAuth` 实现 `loadMirrorData`、`resetForNewSession`、`reconcilePolling`、`notify(LOGIN)`（`AppStore.ets:768-786`） | 一致 |
| 登出 7 步：writeQueue cancel/reset、authStore.clearAuth、清镜像内存、清运行态、设备级不 reset、settings reset 拆分、resetCredentialState+notify(LOGOUT)（1088-1101） | `clearAuth` 一致（`AppStore.ets:788-825`）；`settingsStore.reset()` 只在清空入口调用（1265）；`resetForLogout` **不存在**（文档自述未采用两步走，实际直接用「不 reset」实现） | 一致（文档已注明实际口径 1105-1107） |
| 切号：与登录同路径，`uidChanged` 分支重载镜像域（1110） | `setAuth` 中 `uidChanged` 才 `loadMirrorData`（770-777） | 一致 |
| §8.4 键统一从 Catalog 派生；载荷双模式；Hub 只做治理面不参与日常读写；迁移/导出导入直接读写域键（1121-1134） | Store 键全部 `PersistenceCatalog.byId(...).fullKey()/dirPath()`（`AuthStore.ets:20-31`、`HistoryStore.ets:19-20`、`SettingsStore.ets:47-48`、`SavedThreadStore.ets:36-37` 等 15 处）；`CacheEnvelopeStore` 直接读写（不经 Hub）；Hub 仅在迁移/导出/导入使用 | 一致 |
| §8.1 注：Hub 没有 `loadAll`（1077） | `PersistenceHub.ets` 全文无 `loadAll` | 一致 |

### 2.8 §9 UI 设计

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| §9.1 入口 Block 3B2，badge 规则（1140-1146） | `SettingsPanel.ets:711-719`，badge 条件 `migrationStatus==='partial'||'failed'`（717），文案 `'!'` | 一致（「红点」为文字徽标，措辞差异） |
| §9.2 数据管理页 7 区块（1148-1164） | 数据版本/健康/存储/导出/导入/清空 已实现；**撤销导入未实现**（此条与 §6.4/§13.3 冲突） | **文档未更新**（DES-05） |
| §9.2 数据健康「修复」（清空该域并重建）（1158） | 未实现（无修复入口；`DomainHealth.reset` 无 UI 调用方） | **冲突（与 §13.5 自相矛盾）**（DES-13） |
| §9.3 迁移提醒弹窗：`CustomContentDialog` + 材质契约（1166-1172） | `MainPage` 使用系统 `showAlertDialog`（`MainPage.ets:192-211`），未使用 `CustomContentDialog`/材质 | **文档未更新**（DES-15） |
| §9.3 触发点：MainPage.aboutToAppear 读 `migrationStatus`、一次会话只弹一次（1170-1171） | `maybeShowMigrationNotice`（135-185）+ 内存标记 `migrationNoticeShown`（142）；实际判断依据 `migrationNoticePending` 而非 `@StorageProp` | 一致（判据比文档更严） |

### 2.9 §10 / §11 / §13 附录

| 设计稿声明（行号） | 实现实际 | 判定 |
| --- | --- | --- |
| §10 P1–P6 全部 ✅（1176-1183） | 文件与接线基本存在；但 P4「DataTransferService（容器/校验/合并/加密）」中的**逐域升级器不存在**，P1 表也未列升级器 | **文档未更新**（DES-01 关联） |
| §11 新增测试文件 4 个（1198-1201） | 实际存在的相关套件：`PersistenceCatalogUnit`/`PersistenceMigrationUnit`/`DataTransferUnit`/`DataTransferParseUnit`/`SchedulerUnit`/`DraftKeyUtilsUnit`/`CacheEnvelopeUnit`/`HistoryReadLedgerUnit` 等（见 `entry/src/test/`）；§11 与 §13.2 均漏 `DataTransferParseUnit`（§13.3 提及） | **文档未更新**（DES-17） |
| §13.2 新增/修改文件清单（1244-1294） | `common/persistence/*` 8 文件、`common/scheduler/*`、`common/transfer/*` 4 文件、`FilePickUtils`、`DataManagementPanel` 均存在；清单缺 `common/utils/DraftKeyUtils.ets`、`entry/src/test/DataTransferParseUnit.test.ets`、`entry/src/test/DraftKeyUtilsUnit.test.ets` | **文档未更新**（DES-17） |
| §13.3 实施记录（1296-1438） | 与代码基本可对上：撤销移除、AI Key 不脱敏、Parse bug 修复、文件域路径、迁移提醒、checksum 降级、跨账号草稿键改写、未登录镜像域跳过等均有对应实现（`DataTransferService.ets:604-616,671-686,727-730,824+`；`AppStore.ets:1140-1155`） | 一致（个别历史记录与现行代码冲突，见 DES-05） |
| §13.5 遗留清单（1440-1453） | 与代码基本一致：修复按钮未实现、调度状态未实现、导出域级进度/4MB 预警/分组/每域体积未实现、草稿跨账号提示未实现、credential.recheck 保留、文件域预算已实现、加密往返需真机 | 一致（**但 §13.5 排在 §13.4 之前，章节编号错序**；DES-17） |
| §13.4 兼容策略（1455-1465） | 与实现一致（旧键保留 30 天、系统备份恢复触发迁移、登出设备级保留、切号只重载镜像） | 一致 |

### 2.10 设计稿自身前后矛盾清单

| # | 矛盾 | 位置 | 说明 |
| --- | --- | --- | --- |
| D1 | 「撤销导入」在 §6.4 已明确移除，但 §6.4 流程段、§6.6#10、§6.7、§9.2、§12 R4、§13.3 末尾仍按「有撤销」描述 | 783-786、864-865、878、1163、1210、1374-1375 vs 825-828、1417-1420 | 读者按 §6.7/§9.2 验收会找不到「撤销导入」按钮 |
| D2 | §2.3 写「DEVICE 15」但实际列举 16 个 DEVICE 域（且总数 21 也要求 16） | 287-291 | 算术错误 |
| D3 | §2.3 表 `settings`=「字段合并」、`theme`=「覆盖」；§6.4 表 `settings`=「字段级」、`theme`=「覆盖」；Catalog 实际 `SPECIAL`/`MERGE_FIELDS` | 267-268 vs 792-793 vs `PersistenceCatalog.ets:74-83` | 术语/枚举三处不一致（theme 的 `MERGE_FIELDS` 与「覆盖」语义也不符） |
| D4 | §2.3 表缓存域「跳过」vs §6.4「默认恢复（跟随导出选择）」「SKIP 改为默认不恢复」 | 269-273 vs 802-807 | 同一文档两种策略描述 |
| D5 | §4.4「单域 4MB 告警（日志 warn + 数据管理页红字）」/§4.5「异常域高亮」vs §6.3/§13.5「4MB 预警未实现」 | 507、524 vs 772、1446 | 实现侧 `isOversized` 无调用方 |
| D6 | §6.5「读取前用 fileIo.stat 检查 >64MB」vs §13.3 记录「改为读取后校验」 | 838 vs 1381-1384 | §6.5 未随纠偏更新 |
| D7 | §6.4 承诺「单域载荷 >8MB 跳过并计入计划」vs 实现解析阶段直接丢弃（计划不可见） | 838、854 vs `DataTransferService.ets:793-795` | 文档语义未落地 |
| D8 | §6.1「同一数据两次导出字节级一致」vs `exportedAt=Date.now()` | 728 vs `DataTransferService.ets:156` | 仅 domains 段一致 |
| D9 | §6.1「checksum 缺失时跳过校验并提示」vs 实现缺失即静默跳过 | 730 vs `DataTransferService.ets:380-393` | 无 warning |
| D10 | §6.7/§9.2 承诺「数据健康修复」「撤销导入」「调度状态」vs §13.5 承认未实现 | 873、878、1158、1163、1444-1445 | 同一文档三处冲突 |
| D11 | §6.3 写「未实现项列在 §13.3 遗留」但遗留清单实为 §13.5 | 772 vs 1440 | 引用错位 |
| D12 | §13.5 位于 §13.4 之前（编号顺序错乱） | 1440 vs 1455 | 结构问题 |
| D13 | §13.3 末尾「undo 快照含 settings 明文 API Key（10 分钟 TTL 兜底）」与已移除撤销矛盾 | 1374-1375 | 历史记录残留 |
| D14 | §7.4 未注册清单称 `migration.retry` 未实现（合法声明），但 §10 P5 写「完成」 | 1013 vs 1182 | 阶段状态与「未实现」并列时口径需说明 |
| D15 | §4.1 RAW 域清单遗漏 `meta`（21 域分解不完整）；「15 个 Store」表述与 §13.3「15 Store/17 文件」混用 | 442-450 vs `PersistenceCatalog.ets:169-173`；449 vs 1313 | 低影响 |

### 2.11 交叉治理维度矩阵（ExportPolicy / ImportPolicy / clearable / rebuildable / 载荷 / schema）

| 域 | Export | Import | clearable | rebuildable | 载荷 | schema | 组合自洽性 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| auth | NEVER | NEVER | false | false | RAW | 1 | 自洽（凭证独立加密链路；登出清当前态） |
| sessions | NEVER | NEVER | false | false | RAW | 1 | 自洽 |
| settings | INCLUDE | SPECIAL | true | false | RAW | 1 | 自洽（导出可恢复、清空可删） |
| theme | INCLUDE | MERGE_FIELDS | true | false | RAW | 1 | **标签不自洽**（策略名与实现不符，DES-07） |
| categories/profiles | OPTIONAL | SKIP | true | true | RAW | 1 | 自洽（可重建缓存；导出可勾选、导入默认恢复） |
| notifications/activities/favorite_membership | OPTIONAL | SKIP | true | true | ENVELOPE | 1 | 自洽；**跨账号导入串号**（DES-04） |
| history/reading_progress/votes/poll_voted/tracked_threads | INCLUDE | MERGE_BY_KEY | true | false | RAW/ENVELOPE | 1 | 自洽 |
| ai_sessions | OPTIONAL | MERGE_BY_KEY | true | false | ENVELOPE | 1 | 自洽（隐私默认不选） |
| ai_tool_cache | OPTIONAL | SKIP | true | true | ENVELOPE | 1 | 自洽 |
| drafts/saved_threads | INCLUDE | REPLACE_BY_KEY | true | false | 文件 | 1 | 自洽（跨账号草稿键改写） |
| draft_media | NEVER | SKIP | true | false | 文件 | 1（文档写 —） | 自洽（不导出但参与清空；清空文案未提，DES-14） |
| moving_photo_cache | NEVER | SKIP | true | true | 文件 | 1（文档写 —） | 自洽 |
| meta | NEVER | NEVER | false | false | RAW | 1 | 自洽（清空保留锚点，防触发全量迁移） |

**交叉冲突结论**：

1. **export/import/clearable/rebuildable 四维组合**：未发现「导出包含但清空不含」或「导入恢复但必然失效」的
   直接矛盾；`NEVER` 导出域同时 `clearable=true`（draft_media/moving_photo_cache）是合理设计（不带走但可清）。
   全部 `INCLUDE` 域均 `clearable=true`；`clearable=false` 仅 3 个内部域。
2. **schemaVersion 全为 1 而导入计划做版本拒绝**：拒绝逻辑（`DataTransferService.ets:472-477`）与
   `Hub.readEnvelope`（187-194）只对「高于当前」生效，对等版本/低版本不做升级——即**只有拒绝、没有升级**。
   当前无触发路径（所有域 schema=1），但设计稿 §6.4/§5.2 承诺的升级器不存在（DES-01）。
3. **dataVersion 与域 schema 混用**：未发现混用。三者职责分离：`BACKUP_FORMAT_VERSION=1`（容器）、
   `PERSISTENCE_DATA_VERSION=2`（磁盘代际）、`spec.schemaVersion=1`（域格式）；容器同时携带
   `formatVersion` 与 `dataVersion`（`TransferTypes.ets:33-52`），导入分别做上限拒绝（419-426）。
   唯一偏差：`normalizeContainer` 接受 `dataVersion=0`（`DataTransferService.ets:749`），与 §6.6#6
   「必须正整数」不符（DES-12）。
4. **迁移未完成时导出**：`dataTransferService.init` 位于 `runStartupMigration` 的 `try` 内
   （`AppStore.ets:296-334`）；迁移抛异常进入 catch（335-342）时 **dataTransfer 保持未初始化**，
   数据管理页导出/导入均报「存储未就绪」（`DataTransferService.ets:137-139,427-429`），且
   `clearLegacyUndoSnapshots`（334）不会执行（旧明文 undo 快照残留）。若迁移返回 partial/failed 但未抛错，
   导出可用，但只读新键（`buildDomainEntry` 227-242），失败域旧键数据不会进备份；随后
   「清空本地数据」调用 `removeLegacyKeys/removeLegacyFileDirs`（`AppStore.ets:1252-1253`）删除旧数据 →
   **该域数据永久丢失**（DES-02）。
5. **清空后导入旧数据复活**：已防住——清空删除旧键与旧文件目录、文件域迁移检测依赖 meta 报告
   （`MigrationEngine.ets:246-258,270-292`），旧数据不会被重新迁回。残留问题是**清空后迁移报告
   `legacyKeys` 未清**，UI 仍显示「N 项旧格式数据已到期，可立即清理」（`DataManagementPanel.ets:281-298`；
   `AppStore.ets:1241-1283` 未更新 meta；`cleanupLegacy` 在 removed=0 时不回写 meta，1214-1229）（DES-09）。
6. **登出与镜像域 ownerUid**：登出后 `uidProvider()` 返回空，`buildDomainEntry` 对 ownerUid 非空的镜像域
   跳过导出（213-226）→ 防跨账号外带成立。但**导入侧无对称校验**：容器/域条目不含来源账号
   （`TransferTypes.ets:17-28` 无 ownerUid 字段），导入时镜像域一律写当前 uid（`DataTransferService.ets:554-555`）
   → 换号恢复会串号（DES-04）。

---

## 3. 问题清单

> 编号规则：DES-NN；级别 P0/P1/P2；每条含「结论 / 证据 / 影响 / 修复建议」。
> §3.0：本次**未发现满足 P0 定义**（默认用户路径可达的数据损坏、崩溃或安全漏洞）的问题；
> 最接近 P0 的是 DES-02（数据丢失，需「迁移失败 + 导出 + 清空 + 导入」叠加）与 DES-04（隐私串号，
> 需用户主动导入备份），均列入 P1。

### DES-01（P1）导入「逐域升级器」为设计承诺但代码不存在

- **结论**：设计稿 §6.4 导入流程明确「逐域执行升级器（旧 formatVersion → 当前；旧域 schemaVersion → 当前）」，
  §5.2 P3 进一步说明「导入器内逐域升级（复用 P1 的域升级器）」；实现只有**版本拒绝**，没有任何升级逻辑。
- **证据**：
  - 设计稿：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:578`、`:781`、`:836`；
  - 实现：`entry/src/main/ets/common/transfer/DataTransferService.ets:412-510`（`buildImportPlan` 全文）无
    upgrade 调用；`:472-477` 仅「`incoming.schemaVersion > spec.schemaVersion` → 跳过」；
    `:419-426` 对 `formatVersion`/`dataVersion` 高于当前直接拒绝；
    全文件无 `upgrade`/`migrate` 相关符号（grep 结果）；`DomainMigrators` 未被 `DataTransferService` 引用。
- **影响**：当前所有域 `schemaVersion=1`、容器 `formatVersion=1`，因此**现网无可触发路径**；但一旦未来把某个域
  `schemaVersion` 升到 2，旧备份（schemaVersion=1）会被判定「低于当前 → 不拒绝也不升级」并直接按新结构写盘，
  可能被 Store 误读为空域或坏数据；设计稿承诺的「复用迁移器升级」能力实际不存在，§10 的 P4「完成」状态
  与 §13.5「遗留清单」均未披露这一点。
- **修复建议**（二选一）：
  1. 实现按域升级函数表：`(domainId, incomingPayload, fromSchema) → upgradedPayload`，至少对 `settings`
     （历史字段增删）与信封域复用 `DomainMigrators` 的转换/去重逻辑；在 `buildImportPlan` 版本判断前调用，
     并把「升级成功/降级失败」写入计划展示；
  2. 若确定近期不演进 schema，则在设计稿 §6.4/§5.2/§10/§13.5 明确标注「升级器未实现，schemaVersion
     提升必须同步实现导入升级」，并在 `DataTransferService` 版本判断处对「低版本 + 无升级器」明确拒绝
     （当前是静默按新结构写入，风险最大的一种）。

### DES-02（P1）迁移异常/未完成时导出导入不可用或备份不完整，清空会永久删除未迁移旧数据

- **结论**：`dataTransferService.init` 只在迁移函数 `try` 内执行，迁移异常时导出/导入整体不可用且旧 undo 快照不清理；
  迁移 partial/failed 但未抛错时，导出不会包含失败域的旧键数据，而「清空本地数据」会删除旧键 → 用户
  「导出 → 清空 → 导入」链路会丢数据。
- **证据**：
  - `entry/src/main/ets/store/AppStore.ets:296-343`：`runStartupMigration` 内 `try` 中 `:331-332` 才
    调 `dataTransferService.init(...)`，`:334` 才 `clearLegacyUndoSnapshots()`；`:335-342` catch 只发布
    failed 报告后返回；
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:137-139`（`hub === null` → 「存储未就绪」）、
    `:427-429`（计划阶段同样报错）；
  - `DataTransferService.ets:209-243`（导出只读新键 `hub.readPayload`）；迁移中失败/延后的域旧键仍保留
    （`MigrationEngine.ets:338-344` 设计使然）；
  - `AppStore.ets:1241-1283`：清空时 `:1252 removeLegacyKeys()`、`:1253 removeLegacyFileDirs()`
    —— 删除失败域唯一的旧数据副本。
- **影响**：
  1. 迁移抛异常（数据目录异常、meta 损坏等）时，用户进入「设置 → 数据管理」无法导出/导入，且 UI 无
     「迁移未完成，导出不可用」的解释；旧版 `v2.<domain>.undo` 明文快照（可能含 AI Key）继续驻留；
  2. 迁移 partial/failed 且用户先导出（备份缺失败域）再清空（旧数据被删）再导入 → 失败域数据永久丢失。
     设计稿 §6.3/§6.7 对「迁移未完成能否导出/清空」没有任何门禁或警示。
- **修复建议**：
  1. 把 `dataTransferService.init(...)` 与 `clearLegacyUndoSnapshots()` 移到 `try/finally`（或迁移后无条件执行），
     保证迁移失败时导出/导入仍可用、旧明文快照仍被清理；
  2. 导出入口增加门禁：`!appStore.migrationSettled`（含 failed/partial）时提示「有 N 个域升级未完成，
     其旧数据不包含在备份中」；对 `clearAllLocalData` 同样在迁移未完成时增加专门警示（或强制先重试迁移成功）；
  3. 可选：导出时对仍存在旧键且新键为空/缺失的域，把旧键载荷作为附加域写入容器（复用迁移转换），
     彻底消除「备份不完整」窗口。

### DES-03（P1）缓存/镜像域 `SKIP` 存在两套语义，Catalog 值/枚举注释/§2.3 表与运行行为不一致

- **结论**：设计稿 2026-10-30 修正把缓存/镜像域的 `SKIP` 从「永不导入」改为「默认不主动恢复（可由导入计划
  开关恢复）」。代码运行时行为正确实现了新语义，但 `ImportPolicy.SKIP` 的**定义注释**、§2.3 域表的
  「跳过」列、以及「同一枚举值在 `buildImportPlan` 中分叉为跳过/整体覆盖两种处理」没有同步，形成契约双轨。
- **证据**：
  - 设计稿 §2.3 表：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:269-273,280`（「跳过」）；
  - 设计稿 §6.4 修正段：`:802-807`（「SKIP 仅表示默认不恢复，不再是无条件丢弃」）——与 §2.3 表冲突；
  - `entry/src/main/ets/common/persistence/PersistenceTypes.ets:54-56`：枚举注释仍写「SKIP：不导入
    （缓存/账号镜像，服务端可重建）」；
  - `PersistenceCatalog.ets:84-93`（categories/profiles）、`:97-109`（镜像）、`:144-146`（ai_tool_cache）
    仍登记 `SKIP`；
  - `DataTransferService.ets:461-471`（`SKIP && !restoreCacheDomains` → 跳过）与 `:489-497`
    （`SKIP && restoreCacheDomains` → 透传覆盖，并用 `countPayloadEntries` 改写计数）；
  - `DomainMergers.ets:158-160,425-429`（未归类域 passthrough 兜底，注释「缓存/账号镜像域由导入器整体
    跳过，不会走到这里」——与 `:489` 的覆盖恢复路径**直接矛盾**）。
- **影响**：后续维护者/审计者按枚举注释或 §2.3 表理解会得出「缓存域永不导入」的错误结论；`DomainMergers`
  的 default 分支注释与真实调用路径不符（缓存域确实会走到 default）；导入计划 UI 不展示 policy，
  但 `ImportPlanEntry.policy` 字段仍携带 `SKIP` 且 `willSkip=false`，属于自相矛盾的数据结构状态。
- **修复建议**：
  1. 更新设计稿 §2.3 的导入策略列为「跳过（可恢复）」并加 §6.4 引注；同步更新 `PersistenceTypes` 枚举注释
     与 `DomainMergers` default 分支注释；
  2. 建议把「缓存域默认不恢复、可开启恢复」建模为独立枚举值（如 `RESTORE_OPTIONAL`），避免同一 `SKIP`
     在计划阶段分叉导致 `policy` 与 `willSkip` 语义冲突；
  3. 导入计划 UI 可展示「默认恢复/已关闭恢复」标签，消除用户对缓存域处理方式的困惑。

### DES-04（P1）账号镜像域跨账号导入串号：备份不带来源账号，导入无条件标记当前 uid

- **结论**：导出时账号镜像域（notifications/activities/favorite_membership）做了 ownerUid 归属校验（防外带），
  但**导出容器不携带来源账号标识，导入侧也没有来源校验**；导入计划默认恢复这些域，并把 ownerUid 标为当前
  登录账号。用户 A 导出 → 登出 → 登录 B → 导入同一备份时，B 会看到 A 的通知/动态/收藏关系缓存，并被
  `CacheEnvelopeStore` 判为「合法归属」。
- **证据**：
  - 设计稿 §6.4 表：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:802`（「镜像域写入时标记为当前账号的
    ownerUid」）；§6.6#9：`:862-863`（只约束导出方向「防跨账号数据外带」）；
  - `entry/src/main/ets/common/transfer/TransferTypes.ets:17-28`：`BackupDomainEntry` 只有
    `id/label/schemaVersion/updatedAt/payload`，**无 ownerUid/sourceUid**；
  - `DataTransferService.ets:554-555`：`ownerUid = spec.scope === ACCOUNT_MIRROR ? this.uidProvider() : ''`；
  - `CacheEnvelopeStore.ets:125-160`：只校验信封 ownerUid 是否等于当前 uid，等于即视为合法；
  - 设计稿 §13.3 `:1434-1435` 只修复了「未登录时恢复镜像缓存等于白导入」，未覆盖「已登录换号导入」。
- **影响**：多账号/马甲场景（设计稿 §13.5 明确存在草稿跨账号场景）下，B 看到 A 的私信通知标题、关注动态、
  收藏夹归属缓存，造成隐私泄露与串号错觉；虽然这些域可被服务端数据重建，但「导入后立即显示他人缓存」
  且无提示，用户无法分辨。
- **修复建议**：
  1. 容器层或镜像域条目增加可选 `ownerUid`/`sourceUid`（脱敏哈希也可），导入计划对「来源账号 ≠ 当前账号」
     的镜像域默认跳过并展示原因（与未登录跳过的文案对称）；
  2. 或产品决策：镜像域一律不参与导入恢复（退回旧 SKIP 语义），只保留「缓存可重建」定位；
  3. 至少在导入计划页对镜像域提示「将作为当前账号缓存恢复，可能来自其他账号的备份」，并让用户显式确认。

### DES-05（P2）「撤销导入」已移除，但设计稿多点与代码注释仍按「存在撤销」描述

- **结论**：实现已完整移除撤销写入与 UI（仅保留 `clearLegacyUndoSnapshots` 清理旧版残留），设计稿
  §6.4 流程、§6.6#10、§6.7、§9.2、§12 R4、§13.3 末尾与 `TransferTypes` 文件头仍描述撤销。
- **证据**：
  - 实现：`DataTransferService.ets:646-686`（仅清理；`:515` 注释「应用导入计划（写盘 + 撤销快照）」为**残留
    注释**）、`AppStore.ets:334,1279`、`DataManagementPanel.ets`（无撤销 UI；无 `undo` 符号）；
  - 设计稿仍写撤销：`:783-786`、`:864-865`、`:878`、`:1163`、`:1210`、`:1374-1375`；
  - `TransferTypes.ets:9` 文件头仍写「… → 应用 → 撤销」；
  - 设计稿已声明移除：`:825-828`、`:1417-1420`、`:1450`。
- **影响**：验收/测试按 §6.7/§9.2 找不到「撤销导入」按钮会被记为缺陷；`applyImport` 注释与实际行为不符，
  易误导后续实现回写 undo。
- **修复建议**：同步更新上述文档段落（删除/改为「已移除」），修改 `DataTransferService.ets:515` 注释与
  `TransferTypes.ets:9` 文件头；如未来恢复撤销，需重新做隐私评估（undo 明文快照含 AI Key 的问题仍在）。

### DES-06（P2）§2.3 的 DEVICE 域计数「15」与列举的 16 项、实现的 16 个不一致

- **证据**：设计稿 `:287-291`（写「DEVICE 15」但括注列出 settings…meta 共 16 项）；实现
  `PersistenceCatalog.ets:63-173` 中 DEVICE 域 16 个（21 − 3 镜像 − 2 凭证）。
- **影响**：文档唯一契约中的域数自相矛盾，后续盘点/测试断言（如「21 域中 15 设备级」）会写错。
- **修复建议**：改为「DEVICE 16」，并在 §2.3 表后补一句「21 = DEVICE 16 + ACCOUNT_MIRROR 3 + SECRET 2」。

### DES-07（P2）`settings`/`theme` 导入策略标签与实现对不上

- **结论**：`settings` 设计稿 §2.3「字段合并」、§6.4「字段级」，Catalog 登记 `SPECIAL`；`theme` 设计稿两处
  「覆盖」，Catalog 登记 `MERGE_FIELDS`，但实现是整体覆盖（`mergeReplace`），`MERGE_FIELDS` 枚举注释还写
  「字段级合并（设置类）」。
- **证据**：设计稿 `:267-268,792-793`；`PersistenceCatalog.ets:74-83`；`PersistenceTypes.ets:50-56`；
  `DomainMergers.ets:134-161,244-264`。
- **影响**：策略枚举无法据名推断行为，新增域或测试断言容易选错值；`theme` 用 `MERGE_FIELDS` 与其「覆盖」
  语义、与 settings 的「合并」语义都冲突。
- **修复建议**：`theme` 改用更准确的策略值（如 `REPLACE_FIELD`/保留 `MERGE_FIELDS` 但更新注释为「字段级覆盖，
  数组按业务键并集」）；文档统一为「字段级覆盖 + 数组并集」与「整体覆盖」，并在 §2.3 表使用与枚举一致的中文术语。

### DES-08（P2）导出容器的 `updatedAt` 恒为 0（Hub 只记录治理写入时间）

- **结论**：§6.1 定义 `updatedAt` 为「域最后写入时间」，但日常写入不经过 Hub（§4.3 明确不双写），
  `PersistenceHub.lastWriteAt` 只由 `writePayload`（治理写）/`markMigrated` 更新；导出取
  `hub.lastWriteTime(spec.id)`，对平时只走 Store 的域返回 0。
- **证据**：设计稿 `:438`、`:476-499`；`PersistenceHub.ets:51,277,306-309,400-402`（`markMigrated` 仅迁移时）；
  `DataTransferService.ets:240`（导出赋值）。
- **影响**：备份文件中的域时间戳诊断字段失真（恒 0），跨设备/跨版本排查失去依据；导入不消费该字段，无数据风险。
- **修复建议**：导出时优先取信封 `updatedAt`（ENVELOPE 域）或文件 mtime（文件域）；RAW 域可用
  `PreferencesStore.get` 读时间的近似值，或把 `lastWriteTime` 语义改为「导出时刻」并在 §6.1 说明。

### DES-09（P2）「清空本地数据」不重置迁移报告，UI 长期显示可清理旧数据（实际已删）

- **结论**：`clearAllLocalData` 删除旧键/旧文件目录，但不更新 `v2.meta.migration.legacyKeys/legacyCleanupAt`；
  数据管理页据此显示「N 项旧格式数据已到期，可立即清理」，点击「立即清理」因键已不存在而 removed=0，
  且 removed=0 时不会回写 meta → 提示永久残留。
- **证据**：`AppStore.ets:1241-1283`（无 meta 更新）、`:1208-1231`（`removed > 0` 才更新）；
  `DataManagementPanel.ets:246-299`（刷新逻辑）；`MigrationEngine.ets:620+`（cleanup no-op）。
- **影响**：清空后数据管理页信息错误、清理按钮无效；若用户据此判断「旧数据还在」，可能误判清空失败。
- **修复建议**：`clearAllLocalData` 中同步把 `migrationReport.legacyKeys=[]`、`legacyCleanupAt=0`
  写回 meta（与 `cleanupLegacyData` 成功分支一致），并 bump `dataManagementVersion`。

### DES-10（P2）4MB 单域体积告警：文档承诺（日志 + 页面红字）与实现/§13.5 自相矛盾

- **证据**：设计稿 `:507`（§4.4「超过则日志 warn + 数据管理页红字」）、`:524`（§4.5「异常域高亮」）；
  实际 `PersistenceTypes.ets:126` 定义常量、`DomainHealth.ets:132-135` 提供 `isOversized`，但**全仓库无
  调用方**（grep `isOversized` 仅定义）；§6.3 `:772` 与 §13.5 `:1446` 又写「4MB 预警未实现」。
- **影响**：文档不同章节对同一能力给出相反结论；用户无法在页面看到单域超限警示，Preferences 16MB 上限的
  前哨（4MB 告警）实际缺失。
- **修复建议**：实现最小闭环——`refreshStorage` 中用 `isOversized` 标记行并写 warn 日志；或统一文档为
  「未实现」并删除 §4.4/§4.5 的承诺（与 §13.5 对齐）。

### DES-11（P2）解析防护的「跳过并计入计划」与「checksum 缺失提示」未实现

- **结论**：
  1. §6.5/§6.6#6 要求单域载荷 >8MB「跳过并计入计划」，实现 `normalizeContainer` 直接 `continue`
     （域被静默丢弃，导入计划看不到，用户无从得知某域未导入）；
  2. §6.1 要求 checksum 缺失时「跳过校验并提示」，实现仅在非空且不匹配时给 warning，缺失时无提示。
- **证据**：设计稿 `:730`、`:838`、`:854`；`DataTransferService.ets:793-795`（静默 continue）、
  `:380-393`（无 checksum 分支）；DMP 导入提示仅使用 `outcome.warning`（`DataManagementPanel.ets:589-593`）。
- **影响**：用户可能以为备份完整导入，实际缺少超大域；旧格式无 checksum 的备份被「无提示」接受，丧失
  发现文件被手改的机会。
- **修复建议**：`normalizeContainer` 收集 `droppedDomains[]`（域 id + 原因），`ParseOutcome`/`ImportPlan`
  增加 skipped 条目并在计划页展示；checksum 为空时设置 `warning='备份缺少校验和（旧格式），已跳过完整性校验'`。

### DES-12（P2）§6.5 的「读取前 stat 校验 64MB」未实现；`dataVersion=0` 被接受与 §6.6「必须正整数」不符

- **证据**：设计稿 `:838`（读取前 stat）vs `FilePickUtils.ets:157-266` 文件头注释（真机失败后改为
  直接读取 + 读取后字节校验）、`DataManagementPanel.ets:60,574`、`DataTransferService.ets:298-301`；
  `DataTransferService.ets:749`（仅拒绝 `<0` 或非整数 → 0 可通过）vs 设计稿 `:854`「必须正整数」。
- **影响**：文档与实现口径不一致（实现更宽容、更符合真机约束）；`dataVersion=0` 的伪/半成品容器会被接受为
  「旧格式」，虽无升级器可依赖（与 DES-01 关联），但无直接损坏路径。
- **修复建议**：§6.5 改为「读取后按 UTF-8 字节校验 64MB（真机 stat 不可靠，见 §13.3）」；
  明确 `dataVersion=0` 的语义（视为旧格式）并写入 §6.5/§6.6，或收紧为 `>=1`。

### DES-13（P2）导入计划展示内容与 §6.4 契约不一致；§6.7/§9.2 的「修复」「撤销」与 §13.5 矛盾

- **结论**：
  1. §6.4 要求计划展示「新增/覆盖/跳过/合并」的条数与变更摘要，UI 只展示「新增 N 条 · 更新 M 条」或跳过原因，
     不展示「覆盖/合并」语义与域策略；
  2. §6.7/§9.2 仍承诺数据健康「修复」按钮与「撤销导入」，§13.5 承认修复/调度状态未实现，§6.4 已宣布撤销移除；
  3. §6.7 清空流程写「保留凭证与存档可选」，实现无该选项（凭证固定保留、存档随清空删除）。
- **证据**：设计稿 `:782,873,878,880,1158,1163` vs `:1444-1445`；`DataManagementPanel.ets:702-721`
  （buildPlanLines）、`:1043-1066`（健康区块无修复）、`:1430-1475`（清空弹窗只有输入词，无「保留存档」开关）、
  `AppStore.ets:1241-1283`（存档域 drafts/saved_threads clearable=true 被清）。
- **影响**：验收标准与实现不一致；用户按 §6.7 预期能找到「修复」「撤销」「保留存档」而实际没有。
- **修复建议**：三处文档与实现二选一对齐：要么补实现（修复按钮最小可用版：`removeDomain` + Store reset；
  保留存档开关），要么更新 §6.7/§9.2 为「未实现（见 §13.5）」；同时计划页增加策略列/覆盖合并标注。

### DES-14（P2）清空文案未覆盖草稿媒体/动态照片缓存，但实际会被删除

- **结论**：`draft_media`、`moving_photo_cache` 在 Catalog 中 `clearable=true`，`clearAllLocalData` 会通过
  `removeDomain` 递归删除目录；但清空弹窗文案只列「设置、浏览历史、阅读进度、AI 会话、草稿与离线存档」，
  未提草稿图片/视频副本与动态照片缓存。
- **证据**：`PersistenceCatalog.ets:153-167`；`PersistenceHub.ets:288-298`；`StorageBackends.ets:330-419`
  （`clearDir` 递归）；`DataManagementPanel.ets:786`（文案）。
- **影响**：用户可能以为清空只删草稿正文，实际连草稿媒体一起删；与 §6.6「清空是不可逆动作必须让用户知情」的
  既有纪律不一致。
- **修复建议**：清空弹窗文案补充「草稿图片/视频副本、动态照片缓存」，或把这两个域从 `clearable` 移除
  （但会与「清空本地数据」完整性冲突，建议改文案）。

### DES-15（P2）§9.3 迁移提醒弹窗的实现组件与材质契约不符

- **证据**：设计稿 `:1166-1172`（`CustomContentDialog` + `dialogMaterial`/`scrim`）；实现
  `MainPage.ets:192-211` 用 `getUIContext().showAlertDialog(...)`，未走系统材质契约（虽然 §5.5 的
  Toast/双按钮行为一致）。
- **影响**：视觉与 `docs/IMMERSIVE_LIGHT_DESIGN.md` 第 12 节契约不一致（系统 AlertDialog 未显式材质/遮罩），
  迁移提醒是本轮新增 UI 中唯一未按材质规范实现的弹窗。
- **修复建议**：改为 `CustomContentDialog` + `UIMaterialManager.dialogMaterial`/`scrim`（与数据管理页弹窗一致），
  或更新 §9.3 说明此处刻意用系统弹窗及理由。

### DES-16（P2）§6.1「同一数据两次导出字节级一致」不成立

- **证据**：设计稿 `:728`；`DataTransferService.ets:156`（`exportedAt = Date.now()`）、`:178`
  （checksum 只覆盖 domains）。
- **影响**：文档承诺的「便于 diff 与校验」仅对 `domains` 段成立；若未来做二进制 diff/去重会踩坑。
- **修复建议**：文档改为「domains 段序列化稳定，容器含导出时间戳故整文件不保证字节一致」；或导出时支持
  注入固定 `exportedAt`（测试/诊断用）。

### DES-17（P2）设计稿交叉引用与附录结构错误

- **证据**：
  - §6.3 `:772` 写「列在 §13.3 遗留」，实际遗留清单是 §13.5（`:1440`）；
  - §13.5（`:1440`）排在 §13.4（`:1455`）之前，编号倒序；
  - §11 新增测试清单（`:1198-1201`）与 §13.2 文件清单（`:1266-1269`）缺 `DataTransferParseUnit.test.ets`
    （实际存在，见 `entry/src/test/DataTransferParseUnit.test.ets`、§13.3 `:1398`）；§13.2 还缺
    `DraftKeyUtilsUnit.test.ets`（实际存在）与 `common/utils/DraftKeyUtils.ets`（§13.3 `:1431` 提到）；
- **影响**：文档导航与文件清单不可信，后续维护/审计会按错位置查找。
- **修复建议**：修正引用编号、把 §13.5 移到 §13.4 之后、补全 §11/§13.2 文件清单。

### DES-18（P2）§4.1 域清单不完整（漏 meta）与「15 个 Store」表述不一致

- **证据**：设计稿 `:442-450`（RAW 域只列 10 个，未含 meta；21 域分解 10+6+4=20 缺 1）；实现
  `PersistenceCatalog.ets:169-173`（meta 也是 RAW）+ `:185-195`（ENVELOPE 6 个）；`:449`「15 个既有
  Store」vs §13.3 `:1313`「15 个 Store（17 个文件）」。
- **影响**：读者按 §4.1 无法完整还原 21 域载荷模式；无行为影响。
- **修复建议**：§4.1 的 RAW 列表补 `meta`（并注明「meta 由 PersistenceMetaStore 直接读写，不套信封」），
  统一 Store 文件数表述。

### DES-19（P2）文件域跨账号导入：计划计数与写入后键不一致；计划到执行之间无并发保护

- **结论**：
  1. `drafts` 合并按导入原始键（含导出账号哈希）比较，`applyFileDomain` 才把键改写为当前账号哈希；
     跨账号导入时计划显示「新增 N 条」，实际可能覆盖本机同键草稿（added/updated 统计与真实写入不一致）；
  2. `buildImportPlan` 生成 `mergedPayload` 后到用户点「确认导入」之间，本机 Store 可能已写入新数据；
     `applyImport` 直接用旧 `mergedPayload` 覆盖，会静默丢失这期间的改动（TOCTOU，设计稿未处理）。
- **证据**：`DataTransferService.ets:480-498`（计划期合并）、`:585-628`（应用期键改写）、`:520-576`
  （直接写 `entry.mergedPayload`）；`DomainMergers.ets:305-322`（按原始 key 合并）。
- **影响**：跨账号恢复草稿时统计失真、可能覆盖同标题草稿；计划确认期间用户若修改设置/历史，导入会覆盖新值。
- **修复建议**：计划阶段对 drafts 先做键改写再合并；`applyImport` 对关键域（settings）在写入前重新读一次本机
  payload 并做二次合并，或记录计划后若 Store 有写入则要求重新生成计划（版本号比对）。

---

## 4. 建议补的单测清单

> 现状：`DataTransferUnit.test.ets` 只覆盖 `DomainMergers.mergePayload` 纯逻辑（12 域合并/幂等/截断，`:260-525`）；
> `DataTransferParseUnit.test.ets` 5 个解析用例（`:31-70`）；`PersistenceCatalogUnit.test.ets` 12 个静态断言
> （`:23-146`）；`PersistenceMigrationUnit.test.ets` 18 个迁移规则用例（`:97-395`）。
> 覆盖缺口集中在**链路层与治理交叉面**（以下用例均不依赖 crypto/native，可在 Hypium Local Test 中跑）。

### 4.1 PersistenceCatalogUnit（域对等性）

1. `all().length === 21` 且域 ID 集合与设计稿 §2.3 表格逐一相等（硬编码 21 个 ID 数组，顺序也断言）。
2. 逐域断言 `{storage, key/dirName, schemaVersion, scope, exportPolicy, importPolicy, clearable, rebuildable, rawPayload}`
   的**完整快照**（当前只测了少数域的几个策略），任一枚举被改动必须失败。
3. `exportable().length === 16` 且恰好等于 INCLUDE(9)+OPTIONAL(7)；`NEVER` 5 个域不在其中。
4. `clearable()` 恰好 18 域、`clearable=false` 恰好 `{auth,sessions,meta}`。
5. `rebuildable=true` 恰好 7 域且都属于 OPTIONAL/SKIP 缓存域。
6. ENVELOPE 域集合恰好 `{notifications,activities,favorite_membership,tracked_threads,ai_sessions,ai_tool_cache}`。
7. 域数与设计稿口径一致性断言（DEVICE 16 / MIRROR 3 / SECRET 2）；`label` 全部非空。
8. `validate()` 返回空（已有）之外，补「所有 Preferences 域 `fullKey()` 以 `v2.` 开头且无 uid 段」的显式断言。

### 4.2 PersistenceMigrationUnit（迁移治理）

1. 文件域迁移：`drafts`/`saved_threads` 旧目录 → `filesDir/v2/*`（可用临时目录 mock），坏文件跳过计数、
   同名文件跳过续跑、预算超时 DEFERRED。
2. `buildPlan`：已 `COMPLETED` 且 `legacyKeys` 登记过的旧键不再进计划；SKIPPED/FAILED/DEFERRED 的旧键**不**进
   清理清单；`partial` 后重试只跑剩余域。
3. 上限断言补齐：`tracked_threads` 50（当前未测）、`ai_sessions` 20（合并器侧测了，迁移侧未测）、
   通知/动态 200。
4. 镜像域「只取当前 uid」在多键顺序不同的输入下稳定（当前有 1 个用例，补乱序/空 uid 分支）。
5. `cleanupLegacy(force=false/true)`：保留期未到不删、force 才删、删除后 meta 回写（与 DES-09 联动）。

### 4.3 DataTransferUnit / 新增 DataTransferPlanUnit（导入计划层，纯逻辑可测）

1. `buildImportPlan` 对 21 域构造容器（含每个域一条）后：每个域都有明确 `willSkip` + `reason`；
   `NEVER` 域必跳过；`SKIP` 域在 `restoreCacheDomains=false` 时跳过、`true` 时不跳过。
2. 版本拒绝：`formatVersion=2`、`dataVersion=3`、域 `schemaVersion=2` 分别给出预期 error/skip；
   非法版本（0、负数、小数）在 parse 层拒绝。
3. 未登录镜像域跳过（`uidProvider` 返回空）与 `desired reason`；已登录跨账号导入行为（为 DES-04 定策略后加断言）。
4. `drafts` 跨账号键改写后的合并计数与最终写入键一致（DES-19）。
5. 部分失败 `applyImport`：mock Hub 写失败 1 个域，断言 `ok=false`、`appliedDomains` 计数、已成功域不回滚、
   UI 提示文案路径（若抽函数可测）。
6. `repairTruncatedContainer` 已有解析用例（ParseUnit），补「修复后 checksum 被清空 + warning 文案」断言。

### 4.4 DataTransferParseUnit（解析防护）

1. checksum 不匹配 → `ok=true` + warning（当前缺）；checksum 缺失 → 应有提示（DES-11 修复后断言）。
2. 单域 payload >8MB → 该域被跳过且**计划/ParseOutcome 可见**（DES-11 修复后断言）。
3. 域数 >64 拒绝；重复域 ID 只保留首个；`dataVersion=0` 的当前行为（接受）锁定或改后断言。
4. 旧 `SavedThreadExport`（无 magic、threads 数组）→ 转 `saved_threads` 域；旧 `.ngacred` magic → 明确拒绝文案。
5. 加密容器的错误分支（缺字段/长度非法/iterations 越界）用构造 JSON 断言 `TransferCrypto` 抛错文案
   （若 native 依赖不可用，可把纯校验函数抽出为无 native 依赖的 `validateEncryptedContainerMeta` 再测）。

### 4.5 治理交叉（新增 suite，例如 PersistenceGovernanceUnit）

1. `clearAuth` 后：镜像域内存清空、设备级 Store 不 reset、镜像域磁盘保留、`uidProvider` 为空导出跳过镜像域。
2. `clearAllLocalData` 后：`clearable` 域磁盘键/目录全部不存在、`auth/sessions/meta` 键仍存在、
   旧键/旧文件目录不存在、meta 的 migration 报告被清（DES-09 修复后）。
3. `reloadAfterImport` 覆盖集合：断言 21 域中每个可导入域都有对应 Store 重载动作（可用轻量 mock 统计
   `init/reset/reload` 调用），防止未来新增域漏重载。
4. 迁移 partial + 导出门禁（DES-02 修复后）：`migrationSettled=false` 时导出被阻断或产生 warning；
   `dataTransferService` 在迁移抛异常后仍已初始化。
5. `restoreCacheDomains` 开关往返：对同一容器 true/false 各构建一次计划，断言 only-cache 域的
   `willSkip`、`added` 与预期一致。
6. 镜像域导入归属：登录 B 导入 A 的备份时，按最终产品决策断言「跳过/提示」而非静默串号（DES-04 修复后）。

---

## 5. 审计限制与未覆盖项

1. **只读审计**：未修改源码、未运行编译/Hypium/模拟器；行号以当前工作区文件为准（LF）。
2. 以下内容未逐行核对，建议由对应审计员补充：
   - `StorageBackends.PreferencesBackend.writeRaw` 的 pending 双键与写后读回校验实现细节（§4.3/§4.5）；
   - `PersistenceMetaStore` 的序列化容错；
   - `MigrationEngine` §5.6/§5.7（幂等、重试、旧数据清理提示）与 `cleanupLegacy` 全量语义；
   - `DomainMigrators.convertSettings/convertHistory` 内部逐字段实现（本报告依据 18 个迁移单测 + 派发代码判断一致）；
   - `EntryAbility.onDestroy`、`MainPage` 迁移提醒的 UI 生命周期细节；
   - `SchedulerUnit` 22 用例与 §7.3 契约的逐条对照。
3. `docs/research/AUDIT_DESIGN_CONFLICT.md` 之外未写入任何文件；导出/导入链路的分域细节请与
   `AUDIT_EXPORT.md` / `AUDIT_IMPORT.md` 交叉引用（如两报告结论与本报告冲突，以代码行号证据为准复核）。
