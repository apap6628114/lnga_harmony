# 数据导出链路审计（AUDIT_EXPORT）

- **审计对象**：NGA OH（HarmonyOS ArkUI）「持久化数据统一治理 + 数据管理（导出/导入）」重构的**导出侧**，基准提交 `4e971cfe`（统一治理）、`cfc7d95e`（跨账号草稿找回），审计时 HEAD = `72869858`。
- **审计方式**：只读代码审计。**未修改任何源码**，未运行编译 / 测试 / 模拟器。仅写本报告文件。
- **审计日期**：2026-10-31。
- **任务来源**：共享任务板 `task-1`；重点关注用户提出的三类问题：① 导出的域在导入侧必须被真正使用；② 不能有「导出有、导入不处理/静默丢弃」的多余数据；③ 不能出现「UI 承诺能导出、实际导不出/导出不全」。
- **口径**：域清单以 `entry/src/main/ets/common/persistence/PersistenceCatalog.ets` 为唯一真相；容器/导入语义见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6（行号引用以当前工作区文件为准）。

## 结论摘要

- 导出主链路（弹窗域清单 → `exportBackup` → 加密 → picker 保存 → 回读校验）的**域选择逻辑与 NEVER 防护实现正确**：「`PersistenceCatalog.exportable()` 生成列表、INCLUDE 默认勾选、OPTIONAL 默认不勾选」「NEVER 域不出现且导出侧二次拦截」均核实成立（详见 §4 疑点核实）。
- 存在 **1 个 P0、2 个 P1、5 个 P2、2 个 P3**：
  - **P0**：EXP-02「导出不校验导入侧 8MB 单域上限」，可生成**本应用自己无法导入**的备份，且导入时该域被静默丢弃（大离线存档最容易触发）。
  - **P1**：EXP-01「勾选域被静默省略，导出结果不提供任何跳过清单/原因」；EXP-03「迁移未完成（FAILED/DEFERRED）时导出不阻断也不提示，旧键数据不会进入备份」。
  - **P2**：EXP-04（`dataTransferService` 初始化位置导致的"存储未就绪"死路）、EXP-05（镜像域 ownerUid 校验 fail-open + 静默跳过）、EXP-06（`updatedAt`/`deviceTag`/`appVersionCode` 属"导出但导入从不消费"的死字段，且 `updatedAt` 恒为 0）、EXP-07（草稿媒体绝对路径被导出但媒体文件永不导出）、EXP-08（其它遗留导出入口未复用加固写入器，存在截断风险）。
  - **P3**：EXP-09/EXP-10（设计稿承诺的隐私提示未实现；文档/常量一致性小项）。
- **域对等性结论（正常登录 + 默认参数）**：21 个域中 16 个可导出域在导入侧都有明确策略路径（`DomainMergers` 或缓存域覆盖恢复），**未发现"导出后导入侧完全不处理"的域**；问题集中在**条件性静默跳过**（空/读失败/归属不符/超大）与**容器冗余字段**，见 §3、§6。

## 1. 审计范围与核对基线

### 1.1 涉及文件

| 角色 | 文件 |
| --- | --- |
| 域注册表 | `entry/src/main/ets/common/persistence/PersistenceCatalog.ets`、`PersistenceTypes.ets` |
| 持久化编排 | `PersistenceHub.ets`、`StorageBackends.ets`、`CacheEnvelopeStore.ets`（`common/infra`） |
| 导出服务 | `entry/src/main/ets/common/transfer/DataTransferService.ets`、`TransferTypes.ets`、`TransferCrypto.ets`、`DomainMergers.ets` |
| 导出 UI | `entry/src/main/ets/pages/DataManagementPanel.ets`（openExportDialog / ExportDialogContent / runExport） |
| 入口 | `SettingsPanel.ets`（「数据管理」入口）、`RouterStore.ets`（`dataManagement` 路由） |
| 保存链路 | `entry/src/main/ets/common/utils/FilePickUtils.ets`、`AppStore.ets` 的 `dataTransfer` facade 与初始化 |
| 其它导出入口 | `FavoriteSavedPanel.ets`（离线存档导出）、`SettingsPanel.ets`（账号凭证导出） |
| 设计稿 | `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §2.3、§6.1–6.7、§13.3、§13.5 |

### 1.2 核对基线（代码实测统计）

| 指标 | 数值 | 证据 |
| --- | --- | --- |
| Catalog 注册域总数 | 21 | `PersistenceCatalog.ets:60-197`（`buildSpecs` 21 次 `specs.push`） |
| `ExportPolicy.NEVER` 域 | 5：`auth` / `sessions` / `draft_media` / `moving_photo_cache` / `meta` | `PersistenceCatalog.ets:63-72, 148-173` |
| 可导出域（弹窗可见） | 16 = INCLUDE 9 + OPTIONAL 7 | `PersistenceCatalog.ets:269-278`（`exportable()` 排除 NEVER）；`DataManagementPanel.ets:403` 以其生成列表 |
| 默认勾选 | 9 个 `ExportPolicy.INCLUDE`（settings/theme/history/reading_progress/votes/poll_voted/tracked_threads/drafts/saved_threads） | `DataManagementPanel.ets:406-412`（`if (spec.exportPolicy === ExportPolicy.INCLUDE) selected.push(...)`） |
| OPTIONAL 默认不勾选 | 7 个（categories/profiles/notifications/activities/favorite_membership/ai_sessions/ai_tool_cache） | 同上；`PersistenceTypes.ets:34-45`（策略定义） |
| 导出容器 `domains` 上限 | 导出侧最多 16；导入侧 >64 拒绝 | 导出：`DataTransferService.ets:160-173`；导入：`DataTransferService.ets:763-766` |
| 文件总大小上限 | 64MB（导出/导入一致） | `PersistenceTypes.ets:122-123`；导出 `DataTransferService.ets:184-188`；导入 `DataTransferService.ets:298-301`、`DataManagementPanel.ets:574` |
| 单域载荷上限（**仅导入侧**） | 8MB 字符 | `DataTransferService.ets:71`、`786-795` |

> 说明：`ExportPolicy.NEVER` 的描述见 `PersistenceTypes.ets:34-45`；设计稿 §6.3 的括号列举为「凭证/草稿媒体/动态照片缓存」，未提 `meta`（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:766`），代码把 `meta` 也排除（与 §2.3 一致，属文档列举不完整，见 EXP-10）。

## 2. 导出调用链（证据）

```
设置 → 数据管理（SettingsPanel.ets:711-722 → RouterStore.Screen.dataManagement()）
→ DataManagementPanel.ActionSection「导出数据」:1117-1129
→ openExportDialog():402-433（PersistenceCatalog.exportable() → exportDomainIds；INCLUDE → exportSelectedIds）
→ ExportDialogContent():1195-1338（域勾选 + 全选/全不选 + 加密开关 + 口令）
→ runExport():501-554
   → appStore.dataTransfer.exportBackup(options)（AppStore.ets:1178-1181 门面；DataTransferService.ets:135-201）
      → hub.flush()（DataTransferService.ets:151）
      → 逐 Catalog 域：勾选过滤 → NEVER 再过滤 → buildDomainEntry → null 跳过
      → checksum → JSON.stringify → 可选 encryptBackup → 64MB 校验
   → pickDocumentToSave()（FilePickUtils.ets:120-136）
   → writeTextToUri()（FilePickUtils.ets:348-380，UTF-8 分块写 + finally 关 fd）
   → readTextFromUri(uri, 0) 回读比对（DataManagementPanel.ets:539-544）
   → 关闭弹窗 + Toast「已导出 N 个数据域」（DataManagementPanel.ets:545-547）
```

## 3. 逐域核对表

图例：✅ = 有数据时写入容器（RAW/ENVELOPE/文件数组）；⚠ = 条件写入，可能静默跳过；❌ = 永不写入。

| 域 ID | ExportPolicy | 导出弹窗出现 | 默认勾选 | 实际是否写入容器 | 备注 / 证据 |
| --- | --- | --- | --- | --- | --- |
| `auth` | NEVER | 否 | — | ❌ | 凭证域；`exportable()` 排除 + `exportBackup` 二次拦截（`DataTransferService.ets:166-168`） |
| `sessions` | NEVER | 否 | — | ❌ | 同上 |
| `settings` | INCLUDE | 是 | 是 | ✅ RAW | 读 `v2.settings`（`SettingsStore.ets:131-144` 写入同键）；含 AI API Key，设计上原样导出（§6.6:846-850）；无单域 8MB 校验（EXP-02） |
| `theme` | INCLUDE | 是 | 是 | ✅ RAW | `ThemePersist` 对象（`ThemeSettings.ets:140-151`） |
| `categories` | OPTIONAL | 是 | 否 | ⚠ | RAW 数组（`CategoryStore.ets:70-79`）；空则 `readPayload` 返回 null 被跳过 |
| `profiles` | OPTIONAL | 是 | 否 | ⚠ | RAW `Record<uid, ProfileData>`；LRU 缓存，空则跳过 |
| `notifications` | OPTIONAL | 是 | 否 | ⚠ | ACCOUNT_MIRROR：**登录且信封 ownerUid == 当前 uid 才导出**，否则静默跳过（`DataTransferService.ets:218-226`，EXP-05） |
| `activities` | OPTIONAL | 是 | 否 | ⚠ | 同上 |
| `favorite_membership` | OPTIONAL | 是 | 否 | ⚠ | 同上（信封由 `FavoriteStore.ets:1016-1028` 写入，ownerUid 必填） |
| `history` | INCLUDE | 是 | 是 | ✅ RAW | 数组；空则静默跳过 |
| `reading_progress` | INCLUDE | 是 | 是 | ✅ RAW | 数组；空则静默跳过 |
| `votes` | INCLUDE | 是 | 是 | ✅ RAW | `Record<tid, VoteRecord>` |
| `poll_voted` | INCLUDE | 是 | 是 | ✅ RAW | `Record<tid, ts>` |
| `tracked_threads` | INCLUDE | 是 | 是 | ✅ ENVELOPE payload `{items}` | ENVELOPE 域，导出取其 payload（`PersistenceHub.ets:176-203`） |
| `ai_sessions` | OPTIONAL | 是 | 否 | ✅ ENVELOPE payload `{items}` | 隐私域默认不勾选；「全选」会一并选中（EXP-09） |
| `ai_tool_cache` | OPTIONAL | 是 | 否 | ⚠ ENVELOPE payload `{items}` | 写盘为 800ms 节流（`AiToolCacheStore.ets:144-160`），导出前 `hub.flush()` 不会触发该 store 的 `flush()`，最近 ≤800ms 的缓存可能未落盘（可重建域，影响可忽略） |
| `drafts` | INCLUDE | 是 | 是 | ✅ 文件数组 | `filesDir/v2/drafts/*.json`（`DraftStore.ets:51-54, 683-689`）；坏 JSON 文件静默跳过（EXP-01）；payload 保留 `media[].localPath` 绝对路径（EXP-07）；键末尾含导出账号 uid 短哈希，导入侧重写（§6.4:799） |
| `draft_media` | NEVER | 否 | — | ❌ | 草稿媒体目录沿用 `filesDir/draft_media/`，不导出（`PersistenceCatalog.ets:153-157`）；UI 有文字提示（`DataManagementPanel.ets:1312`） |
| `saved_threads` | INCLUDE | 是 | 是 | ✅ 文件数组 | `filesDir/v2/saved_threads/<tid>.json`（`SavedThreadStore.ets:96-98`）；大存档/多存档合并后可能超过导入 8MB 单域上限 → EXP-02 |
| `moving_photo_cache` | NEVER | 否 | — | ❌ | 可重建，不导出（`PersistenceCatalog.ets:163-167`） |
| `meta` | NEVER | 否 | — | ❌ | 内部迁移锚点（`PersistenceCatalog.ets:169-173`） |

**核对结论**

1. **域对等性**：16 个可导出域在导入侧均有明确路径——`settings/theme/history/reading_progress/votes/poll_voted/tracked_threads/ai_sessions/drafts/saved_threads` 走 `DomainMergers.mergePayload`（`DomainMergers.ets:134-161`），`categories/profiles/notifications/activities/favorite_membership/ai_tool_cache` 走「跟随导出选择」的覆盖恢复（`DataTransferService.ets:461-498`，默认 `restoreCacheDomains=true`）。**没有域是"导出后完全无人处理"的**。
2. **没有"永远导不出"的域**（正常路径）：所有域只要有新键数据就能写出。条件性缺失场景为：域无数据、信封损坏/版本过新、文件域全部无可解析 `.json`、账号镜像域归属不符/未登录、以及 §6 的 8MB 超限（导入侧）。
3. `drafts`/`saved_threads` 目录均为**单层、仅 `.json`**（写入方证据：`DraftStore.ets:268-270, 351-389`；`SavedThreadStore.ets:96-98, 221-274`），故 `exportFileDomain` 的「不递归 + 只取 `.json`」在**当前布局下不会漏域文件**；被过滤的只有 `.json.tmp`（原子写残渣，非数据）与草稿媒体（独立 NEVER 域，设计明确不导出）。

## 4. Lead 初筛疑点核实

| # | 疑点 | 结论 | 证据 |
| --- | --- | --- | --- |
| 1 | 导出弹窗是否用 `PersistenceCatalog.exportable()` 生成列表、初始勾选是否与 `ExportPolicy.INCLUDE` 一致 | **证伪（实现正确）** | `DataManagementPanel.ets:403-414`：列表 = `exportable()`；默认勾选仅 `INCLUDE`；`exportable()` 排除 NEVER（`PersistenceCatalog.ets:269-278`） |
| 2 | `exportPolicy=NEVER` 被导出跳过，但 UI 是否可能列出它 | **证伪（双重防护）** | 列表侧 `exportable()` 排除；导出侧 `DataTransferService.ets:166-168` 再 `continue`；NEVER 域共 5 个（§1.2） |
| 3 | `buildDomainEntry` 对空载荷返回 null 跳过——哪些域可能「永远导不出」 | **部分证实**：无结构性永久缺失；但「空」与「读取失败/归属不符/文件损坏」不可区分，一律静默跳过（EXP-01）；镜像域在未登录/切号后必然跳过（EXP-05） | `DataTransferService.ets:169-172, 231-235`；`PersistenceHub.ets:141-167`；`DataTransferService.ets:218-226` |
| 3b | ACCOUNT_MIRROR 的 ownerUid 校验在 ownerUid 空 / 当前 uid 空时的行为 | **证实存在 fail-open**：`ownerUid.length > 0 && ownerUid !== currentUid` 才跳过；ownerUid 空 → 放行；当前 uid 空 + ownerUid 非空 → 跳过（静默）。正常写入路径下镜像信封 ownerUid 非空（`CacheEnvelopeStore.ets:247-269`、`FavoriteStore.ets:1016-1028`、迁移 `MigrationEngine.ets:489-496` 且未登录不迁移 :452-460），故 fail-open 是可兜底但不严谨的防御 | `DataTransferService.ets:218-226`；`PersistenceHub.ets:229`（legacy `uid` 回退） |
| 4 | `exportFileDomain` 只取 `.json` 且不递归，是否漏草稿/存档文件 | **基本证伪**：当前布局单层且仅 `.json`；草稿媒体是独立 NEVER 域（UI 已提示），非"漏"而是设计边界。**但**：坏 JSON 文件被静默丢弃（EXP-01）；草稿内 `localPath` 绝对路径被原样导出而媒体不导出（EXP-07） | `DataTransferService.ets:251-275`；`DraftStore.ets:51-54, 131-160`；`SavedThreadStore.ets:96-98`；`DataManagementPanel.ets:1312` |
| 5 | 容器字段 `updatedAt/label/schemaVersion/deviceTag` 导入侧是否消费 | **证实存在问题**：`label`、`schemaVersion` 被消费；**`updatedAt` 从不被导入逻辑消费且实际恒为 0**；`deviceTag`、`appVersionCode` 被解析后从未使用（"多余数据"） | 见 §5 字段表；EXP-06 |
| 6 | 导出保存链路（AppStore facade、FilePickUtils）是否二次加工/截断/编码 | **主链路证伪（已加固）**：`hub.flush()` 后读盘、UTF-8 显式编码、64KB 分块写、`try/finally` 关 fd、写入后整文件回读比对。**但**其它遗留导出入口未复用该写入器（EXP-08） | `DataTransferService.ets:149-201`；`FilePickUtils.ets:332-380`；`DataManagementPanel.ets:530-544`；反例 `FavoriteSavedPanel.ets:824-830`、`SettingsPanel.ets:361-366` |

## 5. 导出容器字段消费核对（"多余数据"判定）

| 字段 | 导出写入 | 导入消费 | 判定 |
| --- | --- | --- | --- |
| `magic` | `DataTransferService.ets:153` | 校验 `:726-734` | ✅ 消费 |
| `formatVersion` | `:154` | 版本闸门 `:419-421`（>当前拒绝） | ✅ 消费 |
| `dataVersion` | `:155` | 版本闸门 `:423-426` | ✅ 消费 |
| `exportedAt` | `:156` | `plan.exportedAt`（`:417`）→ 导入计划副标题展示（`DataManagementPanel.ets:695-699`） | ✅ 消费 |
| `appVersionName` | `:157` | `plan.appVersionName`（`:418`）→ 展示（`DataManagementPanel.ets:697`） | ✅ 消费 |
| `appVersionCode` | `:158` | `normalizeContainer` 解析（`:741`）后**无任何使用点** | ❌ 死字段（EXP-06） |
| `deviceTag` | `:159` 硬编码 `'phone'` | 解析（`:742`）后**无任何使用点**（设计 §6.1:731 也声明"仅诊断"） | ❌ 死字段（EXP-06） |
| `domains[].id` | `:237` | 域路由 `:436` | ✅ 消费 |
| `domains[].label` | `:238` | 导入计划展示 `:435` + `DataManagementPanel.ets:708` | ✅ 消费（仅 UI） |
| `domains[].schemaVersion` | `:239` | 域版本闸门 `:472-477`（>当前跳过） | ✅ 消费 |
| `domains[].updatedAt` | `:240`（`hub.lastWriteTime`） | `normalizeContainer` 解析（`:801`）后**从无使用点** | ❌ 死字段，且**取值不可信**（EXP-06） |
| `domains[].payload` | `:241` | 合并/写入 `:479-498, 542-559` | ✅ 消费 |
| `checksum` | `:178` | 校验不一致时仅告警继续（`:381-393`） | ✅ 消费（降级为警告） |

**`updatedAt` 恒 0 的论证**：`hub.lastWriteAt` 仅在 `PersistenceHub.writePayload()` 成功时（`PersistenceHub.ets:276-279`）与 `markMigrated()`（`:400-402`）时更新；整个工程调用 `writePayload` 的只有 `MigrationEngine.ets:496`（启动迁移）和 `DataTransferService.ets:555`（导入）——**各 Store 日常写入都不经过它**（如 `SettingsStore.ets:135-144` 直接 `putJSON`、`CacheEnvelopeStore.ets:264-268` 直接 `putString`、`ThemeSettings.ets:140-151` 直接 `putJSON`）。因此用户正常使用一段时间后导出，除"本进程内刚发生过迁移/导入"的域外，`updatedAt` 均为 `0`；进程重启后归零。该字段既不准确也不被消费。

## 6. 问题清单

### EXP-01（P1）勾选域被静默省略，导出结果不提供跳过清单/原因

- **证据**
  - 逐域循环中 `buildDomainEntry` 返回 null 直接忽略：`entry/src/main/ets/common/transfer/DataTransferService.ets:169-172`；
  - 空载荷 / 读取失败 / 信封非法（`readPayload` 返回 null）→ `:231-235`；`PersistenceHub.readPayload()` 对"键不存在、JSON 解析失败、信封域 ID 错配、信封版本过新、缺 payload"一律 `return null`（`PersistenceHub.ets:141-167, 176-203`），与"真的没有数据"不可区分；
  - 文件域坏 JSON 仅记 warn 并跳过该文件（`DataTransferService.ets:265-273`），全部坏则整域返回 null（`:274`）；
  - 导出结果结构 `BackupExportResult` 只有 `domainCount/bytes/encrypted`，**没有"请求域列表/跳过域/跳过原因"字段**（`TransferTypes.ets:66-82`）；
  - UI 只显示「已导出 N 个数据域」并立即关窗（`DataManagementPanel.ets:545-547`），N 小于用户勾选数时无任何解释。
- **问题描述**：用户勾选 N 个域导出的备份实际只包含其中 M 个（M<N），缺失原因（无数据 / 读取失败 / 信封损坏 / 镜像域归属不符 / 文件损坏）全部不可见；备份是否"完整"无法判断。
- **用户可见影响**：备份静默不全。用户若随后「清空本地数据」或换机恢复，缺失域的数据不可恢复；读取失败/文件损坏场景属于"数据已坏但备份也一起丢"，用户完全没有机会处理。
- **修复建议**：`BackupExportResult` 增加 `omitted: {id, reason}[]`（区分 `empty` / `read-failed` / `owner-mismatch` / `invalid-file`）；UI 在关窗前展示"已导出 M 个，跳过 K 个及其原因"，读取失败/文件损坏应作为失败提示而非静默；导出日志同时记录跳过域。

### EXP-02（P0）导出侧不校验导入侧 8MB 单域上限 → 可生成"本应用无法导回"的备份，导入时该域被静默丢弃

- **证据**
  - 导入侧上限：`const MAX_DOMAIN_PAYLOAD_CHARS: number = 8 * 1024 * 1024`（`entry/src/main/ets/common/transfer/DataTransferService.ets:71`）；`normalizeContainer` 中 `payloadSize > MAX_DOMAIN_PAYLOAD_CHARS` 时**直接 `continue` 丢弃该域**，不写错误、不计入计划（`:786-795`）；
  - 导出侧只有**总文件 64MB** 校验（`:184-188`），**没有单域上限校验**；`buildDomainEntry`/`exportFileDomain` 也不检查（`:209-243, 251-275`）；
  - `saved_threads` 是"整个域一个 payload 数组（含全部离线存档的 rawPages）"（`exportFileDomain` 返回 `items` 数组 `:251-275`；`SavedThreadStore.ets:221-274` 单帖可含多页原始 JSON）；`PersistenceCatalog.ets:158-162` 估算均值 131072 字节/条，`MigrationEngine.ets:540` 注释明确"存档单帖可达数 MB"；
  - 设计稿也自证该上限存在：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:838`（§6.5「单域载荷 > 8MB 字符跳过」）、`:854`（§6.6「单域载荷 ≤8MB 字符（跳过并计入计划）」），但实现既未"计入计划"，导出侧也未预防。
- **问题描述**：当任一勾选域的 `JSON.stringify(payload).length > 8MB`（最现实的是离线存档：几十个存档或单个超大帖；AI 会话长上下文也可能），导出**照常成功**并提示"已导出"；到导入时该域在容器归一化阶段被**静默剔除**——用户看到"导入完成"，但该域数据一条都没恢复，且导入计划里连"该域被跳过"都不会出现。
- **用户可见影响**：备份文件在磁盘上"看起来成功"，却是**该应用自己永远无法导入**的格式；如果用户导出后清空本地数据，超大存档域数据实质丢失（只能换工具/等修复版本手工处理）。这是导出/导入闭环的核心承诺失败，且完全无提示。
- **修复建议**（双向）：
  1. 导出侧用与导入一致的 `MAX_DOMAIN_PAYLOAD_CHARS` 校验单域体积：超限时**导出失败**并明确提示"离线存档整体超过 8MB，请分批删除后再导出"，或对大域做分片容器（更彻底）；
  2. 导入侧 `normalizeContainer` 把被过滤的域（超限/非法）记录进 `ParseOutcome.warning` 与导入计划条目（`willSkip + reason`），不要静默 `continue`；
  3. 至少让 `saved_threads` 按条分域或按条记录，避免"一个超大存档拖垮整个存档域"。

### EXP-03（P1）迁移未完成（FAILED/DEFERRED）时导出不阻断、不提示，旧键中的数据不会进入备份

- **证据**
  - 导出读取全部走新键：`DataTransferService.ets:227-232`（`hub.readPayload`）→ `PersistenceHub.ets:145`（`this.preferences.readRaw(spec)`，键 = `spec.fullKey()` = `v2.<domain>`，`PersistenceTypes.ets:227-234`）；
  - 迁移失败/延后/跳过时旧键被**刻意保留**、不进入 30 天清理：`MigrationEngine.ets:329-350`（DEFERRED 分支 `:331-334`；仅 MIGRATED 才进清理清单 `:338-343`）；
  - 数据管理页的导出入口完全不看迁移状态：`openExportDialog`/`runExport`（`DataManagementPanel.ets:402-433, 501-554`）未调用 `appStore.migrationSettled / migrationFailedCount`；迁移状态只在另一个卡片展示（`:246-299`），两者的信息没有联动；
  - 而「清空本地数据」会**同时删除旧键与旧目录**（`AppStore.ets:1252-1253`，`PersistenceHub.removeLegacyKeys/removeLegacyFileDirs`），即"不完整备份 + 清空"会让旧键数据彻底消失。
- **问题描述**：升级后首次启动的迁移有 3s 预算（`PersistenceTypes.ets:108`），大文件域/慢设备会出现 DEFERRED（下次启动再迁移，§13.4:1461），部分域也可能 FAILED。此时用户打开「数据管理」执行导出，导出只读 `v2.*` 新键，**仍留在旧键里的该域数据完全不会进入备份**，导出却显示成功，且没有任何"迁移未完成，建议先重试升级"的提示。
- **用户可见影响**：升级后立刻做备份（最常见的"升级→先备份再折腾"路径）得到的备份缺域；随后若清空数据，旧键被删，数据无法恢复。
- **修复建议**：导出前检查迁移报告——存在 `FAILED`/`DEFERRED` 域时：① 弹窗警示"有 N 个数据域尚未完成升级，其旧数据不会进入备份，是否先重试升级"，或 ② 直接禁用导出并引导「重试升级」；③ 更彻底的做法是导出时对"新键缺失但旧键存在"的域做只读兜底（走 `DomainMigrators` 转换后打包），保证备份至少不丢数据。

### EXP-04（P2）`dataTransferService` 初始化位于迁移 try 块尾部：迁移异常时导出/导入永久"存储未就绪"，且「重试升级」不重建该服务

- **证据**
  - 唯一初始化点：`AppStore.ets:331-334`（位于 `runStartupMigration()` 的 `try` 内、迁移执行之后）；异常被 `catch` 兜底为"迁移失败"并继续启动（`:335-342`）；
  - `DataTransferService` 未初始化时 `hub === null`：`exportBackup` 直接返回 `'存储未就绪'`（`DataTransferService.ets:136-140`）；`parseBackup`/`buildImportPlan`/`applyImport` 同理（`:427-430, 522-525`）；
  - `retryMigration()` 只重建迁移引擎并重跑迁移（`AppStore.ets:1190-1200`），**不调用 `dataTransferService.init`**；
  - 数据管理页的「重试升级」入口（`DataManagementPanel.ets:1010-1020`）走的就是 `retryMigration`。
- **问题描述**：只要启动迁移阶段抛出未捕获异常（该 `catch` 的存在说明实现预期它可能发生），本次进程内导出/导入功能全部不可用；用户按提示「重试升级」成功后功能仍不可用，必须重启应用，且错误文案只有"存储未就绪"，无可操作指引。
- **用户可见影响**：恰恰在"迁移出了问题、最需要先备份数据"的场景下，导出功能不可用且无恢复路径。
- **修复建议**：把 `dataTransferService.init(...)` 移到 `AppStore.init()` 中、`runStartupMigration` 的 `try/catch` 之外（Hub 初始化成功后立即注入）；`retryMigration()` 成功后再次 `init`；数据管理页在导出/导入按钮前做就绪检查并给出明确提示。

### EXP-05（P2）账号镜像域 ownerUid 校验 fail-open，且未登录/切号时静默跳过（与导入侧"显式原因"不对称）

- **证据**
  - 跳过条件：`if (ownerUid.length > 0 && ownerUid !== currentUid)`（`DataTransferService.ets:222`）——**ownerUid 为空时直接放行**（fail-open）；`ownerUid` 来自 `readEnvelopeMeta`，legacy 信封回退读 `uid`（`PersistenceHub.ets:211-236`，回退 `:229`）；
  - 当前 uid 提供者：`AppStore.ets:331-332`（`(): string => this.authStore.state.uid`）；退出登录后镜像域磁盘保留、内存清空（`AppStore.ets:803-817`），此时导出镜像域必然 `ownerUid !== ''` → 静默跳过；
  - 导出侧跳过只记日志（`DataTransferService.ets:223`），结果里没有说明（EXP-01）；**导入侧**对同场景是显式跳过并给出原因（`DataTransferService.ets:455-460`: "未登录：账号镜像缓存需按账号归属恢复，请登录后重新导入"），两侧用户体验不对称；
  - 导出弹窗对这些域不做登录态置灰/提示（`DataManagementPanel.ets:402-433, 1195-1338`）。
- **问题描述**：三个镜像域（notifications/activities/favorite_membership，OPTIONAL）在未登录或切换账号后可勾选，但会被静默跳过；同时 `ownerUid` 为空的信封会被无条件导出（正常写入路径不会产生这种信封，属防御性 fail-open，未来若新增写路径遗漏 ownerUid 即成为跨账号外带风险）。
- **用户可见影响**：用户勾选"通知/动态/收藏关系"后导出，得到不含这些域的备份且无提示；fail-open 在异常数据下可能把归属不明的镜像数据写进备份文件。
- **修复建议**：未登录时在导出弹窗把镜像域置灰并标注"需登录后才能导出"；`ownerUid === ''` 时按"归属未知"处理（跳过并在结果中给原因），不要 fail-open；导出结果按 EXP-01 增加跳过原因。

### EXP-06（P2）容器字段 `updatedAt` 恒 0 且导入侧不消费；`deviceTag`/`appVersionCode` 属"导出后即丢弃"的死字段

- **证据**：见 §5 字段表。要点：`entry.updatedAt = this.hub.lastWriteTime(spec.id)`（`DataTransferService.ets:240`）；`lastWriteAt` 仅在 `writePayload`/`markMigrated` 更新（`PersistenceHub.ets:50-51, 276-279, 400-402`），正常 Store 写入不经过 Hub（`SettingsStore.ets:135-144`、`CacheEnvelopeStore.ets:247-269`、`ThemeSettings.ets:140-151`）；导入侧 `normalizeContainer` 解析 `updatedAt`（`:801`）后 `buildImportPlan`（`:431-504`）与 UI（`DataManagementPanel.ets:694-721`）都不使用；`deviceTag` 硬编码 `'phone'`（`:159`）、解析于 `:742` 后无使用；`appVersionCode` 同理（`:158, :741`）。
- **问题描述**：容器里存在"导出写入但导入侧从不消费"的多余数据（正是用户关切的"多余数据"）：`updatedAt`、`deviceTag`、`appVersionCode`；且 `updatedAt` 取值本身不真实（正常使用恒 0，仅本进程内迁移/导入过的域才有值），属于"既多余又误导"的字段。
- **用户可见影响**：当前无直接 UI 影响，但若后续版本用 `updatedAt` 做合并/校验，会基于错误值决策；同时增大容器体积、误导排障（备份里所有域"最后写入时间=1970"）。
- **修复建议**：二选一——① 让 `updatedAt` 真实：各 Store 写入成功后统一更新 Hub 的 `lastWriteAt`（或从信封/文件 mtime 读取），并在导入计划里展示"域最后写入时间"；② 若不需要，从 `BackupDomainEntry`/`BackupContainer` 删除 `updatedAt/deviceTag/appVersionCode`（保留字段会继续误导）。`deviceTag` 若要保留应取真实设备类型（或至少写平台名而非固定 `'phone'`）。

### EXP-07（P2）草稿域导出了指向"导出端沙箱绝对路径"的媒体记录，但媒体文件永不导出

- **证据**
  - `DraftMedia.localPath / videoLocalPath` 定义为沙箱持久区绝对路径：`entry/src/main/ets/common/managers/DraftStore.ets:128-160`（头注释 `:131` 明确 `filesDir/draft_media/...`）；
  - 导出把整份草稿 JSON 原样解析进数组（`DataTransferService.ets:265-269`），因此 `media[].localPath/videoLocalPath` 被写入备份；
  - `draft_media` 是 `ExportPolicy.NEVER`（`PersistenceCatalog.ets:153-157`），媒体文件不会进入备份；UI 仅提示"草稿中的图片/视频副本不包含在备份内…需在编辑器中重新选择"（`DataManagementPanel.ets:1312`）；
  - 导入侧 `applyFileDomain` 把导入的草稿记录**原样写回**（只改写键尾 uid 片段，`DataTransferService.ets:596-626`），不做本地路径清理；编辑器重传时会因"本地副本已不存在"失败（`DraftMediaUploader.ets:434-438, 461-465`）。
- **问题描述**：草稿域 payload 中包含"导入侧永远不可用"的绝对路径字段（媒体副本未随备份走），属于"导出了但导入侧无意义的多余数据"；用户按提示重选媒体前，草稿的媒体清单处于"有记录、无文件"的悬空状态。
- **用户可见影响**：跨机/重装恢复草稿后，含未上传媒体的草稿在发送时出现"封面/视频：本地副本已不存在"类错误，需要用户逐个手动删除或重选；虽然 UI 已提前提示，但导出的数据本身对该字段无任何可用性。
- **修复建议**：导出时对草稿 payload 做"可移植化"处理（清空 `media[].localPath/videoLocalPath`，保留 `tag/url/fileName` 等可恢复字段），或导入侧写盘前清空这些绝对路径字段；并在导入计划中对 drafts 域额外提示"媒体需重新选择"。

### EXP-08（P2）其它遗留导出入口未复用加固后的写入器：离线存档 / 凭证导出仍是单次 `writeSync`（可能截断）

- **证据**
  - 加固后的写入器：`FilePickUtils.writeTextToUri`（UTF-8 编码 + 64KB 分块循环 + 校验 `written` + `finally` 关 fd，`entry/src/main/ets/common/utils/FilePickUtils.ets:332-380`），但全仓库仅 `DataManagementPanel.ets:47-55` 引用（grep 结果：`writeTextToUri` 唯一调用点 `DataManagementPanel.ets:530`）；
  - 离线存档导出仍走旧写法：`FavoriteSavedPanel.exportThreads` 直接 `picker` + `fileIo.openSync` + 单次 `fileIo.writeSync(file.fd, content)`（`FavoriteSavedPanel.ets:16, 798-835`，写入 `:824-830`），**忽略 `writeSync` 返回值、无分块、无回读校验**；
  - 账号凭证导出同样单次写（`SettingsPanel.ets:361-366`，凭证体积小、风险低，但属同一模式）；
  - 设计稿已确认"单次 `writeSync` 不保证写完"是该版本修过的真实缺陷：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:1385-1387`（§13.3 真机实测导出→导入失败修复）。
- **问题描述**：多域导出主链路已用分块写修复截断问题，但"离线存档导出"这一**同源导出入口**未收敛：离线存档 JSON 可达数 MB（`MigrationEngine.ets:540` 注释），单次 `writeSync` 在真机上可能写不全（设计文档实测过同类缺陷），且没有回读校验兜底，用户会得到一个"导出成功但内容截断"的存档文件。
- **用户可见影响**：离线存档导出/分享在特定文件/大文件下静默截断，导入端解析失败；与主链路修复后的行为不一致。
- **修复建议**：`FavoriteSavedPanel.exportThreads`/`SettingsPanel.exportEncryptedCredential` 改用 `FilePickUtils.pickDocumentToSave + writeTextToUri`（+ 必要时回读校验）；或把离线存档导出收敛到数据管理页的容器导出。

### EXP-09（P3）设计稿 §6.6 承诺的"勾选 AI 会话/浏览历史时底部敏感提示"未实现；"全选"会静默选中隐私域

- **证据**：设计稿 `docs/PERSISTENCE_UNIFICATION_DESIGN.md:843-844`（"导出前隐私提示：勾选 AI 会话/浏览历史时在底部提示'包含敏感内容'；`ai_sessions` 默认不勾选"）；实现中导出弹窗只有固定副标题"未加密文件包含浏览历史、AI 对话等隐私内容"（`DataManagementPanel.ets:425`）与底部"草稿媒体不导出"的静态提示（`:1312`），没有任何基于当前勾选的动态敏感提示；「全选」无条件 `exportDomainIds.slice()`（`:1201-1204`），会把 `ai_sessions` 等 OPTIONAL 隐私域一并选中且无额外确认。
- **问题描述**：文档承诺的"按勾选给出隐私提示"未实现；虽然默认加密（`:144, 1253-1288`）与域说明文字（`exportNoteOf`，`:482-484`）部分缓解，但"全选"的隐私提示缺失。
- **用户可见影响**：低（默认加密、每个域有说明文字）；但在用户关闭加密且全选时，缺少一次针对敏感域的明确提醒。
- **修复建议**：在 `ExportDialogContent` 底部按 `exportSelectedIds` 动态显示"已选择敏感数据域：AI 对话/浏览历史，未加密导出将暴露这些内容"；或让「全选」默认跳过 `ai_sessions` 并在勾选时二次确认。

### EXP-10（P3）文档/常量一致性小项（与 task-3 设计一致性审计重叠）

- **证据与说明**
  - `PersistenceTypes.ets:120` 定义 `BACKUP_FILE_SUFFIX: '.ngabackup'` 但**全仓库无引用**；文件名后缀实际由 `DataManagementPanel.ets:63`（`BACKUP_SUFFIX: 'ngabackup'`）与 `:523` 自行拼接 —— 双份定义，改一处会漂移；
  - 设计稿 §6.3 的 NEVER 列举只写"凭证/草稿媒体/动态照片缓存"（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:766`），漏了 `meta`；实现（正确）排除了 `meta`，属文档列举不完整；
  - 设计稿 §6.6-11 承诺导出日志含"耗时"（`:866`），`exportBackup` 日志只有域数/字节/是否加密（`DataTransferService.ets:193-194`），无耗时；
  - §13.5 已声明的未实现项（4MB 预警、域级进度、分组、每域体积，`docs/PERSISTENCE_UNIFICATION_DESIGN.md:1446`）与代码一致（`DOMAIN_SIZE_WARN_BYTES` 仅用于健康卡片：`DomainHealth.ets:134`），不算新问题，此处仅备案。
- **建议**：统一后缀常量来源；补齐/修正文档列举与日志字段（可合并到 task-3 处理）。

## 7. 待验证事项（代码静态无法确认，需真机/测试环境）

| # | 事项 | 验证方法 |
| --- | --- | --- |
| 1 | 导出弹窗「全选/全不选/单勾」后 Checkbox 视觉与计数是否同步刷新 | ArkUI V1 属性级依赖跟踪预期可刷新，但 ForEach 键值复用（key = id 不变）存在不同版本行为差异。真机操作：打开导出弹窗→点「全不选」→观察 9 个默认勾选是否全部取消、计数是否变 0；再点「全选」观察 16 项是否全部勾选。 |
| 2 | 加密容器导出→导入往返（含 `iterations`/AAD/中文 JSON 编码） | Local Test 无法加载 `cryptoFramework`（`entry/src/test/DataTransferUnit.test.ets:10-13`），需真机：加密导出→从文件导入→核对域数与内容。 |
| 3 | >8MB 单域时"导出自不可导入"的实际表现（EXP-02） | 构造多份大离线存档（或临时在测试环境构造 9MB payload 的 `BackupContainer` 走 `parseBackup`），确认导入计划/结果里是否出现该域、是否被静默丢弃。可用 Hypium 直接喂容器字符串（不涉 crypto）。 |
| 4 | picker 保存后 `readTextFromUri(uri, 0)` 回读校验在部分文件管理器 provider 上是否误报"写入不完整" | 真机分别保存到「文件管理/下载/第三方网盘」目录各一次，验证回读路径（`FilePickUtils.ets:177-259` 的两级兜底）是否都成功。 |
| 5 | 镜像域 ownerUid 行为：未登录导出是否确实跳过；导入侧同场景提示 | 真机：登录 A 导出（镜像域可选）→退出登录→导出同样勾选，确认容器是否缺域、UI 是否有提示；再用未登录状态导入含镜像域的备份，确认导入计划提示。本项目已有相关单测线索（`DataTransferUnit.test.ets` 未覆盖 ownerUid，需补）。 |

## 8. 测试覆盖缺口（导出侧；与 task-3 的"建议补的测试"重叠，供 Lead 合并）

- `entry/src/test/DataTransferUnit.test.ets:259-527` 只覆盖 `DomainMergers.mergePayload`（合并语义），**没有任何 `exportBackup`/`buildDomainEntry`/`exportFileDomain` 用例**——「勾选域是否真的写入容器」「空/坏文件/归属不符如何表现」无回归门禁。
- `entry/src/test/DataTransferParseUnit.test.ets:30-72` 只覆盖 `parseBackup` 的 5 个解析场景，且用 `new DataTransferService()`（`hub` 为 null，不触达导出路径）。
- `entry/src/test/PersistenceCatalogUnit.test.ets:69-100` 只断言部分 NEVER/OPTIONAL 策略，**没有**"`exportable()` 是否等于 INCLUDE∪OPTIONAL""NEVER 不进弹窗初选""默认勾选 = INCLUDE 集合"这类域对等性断言。
- 建议最小补测集：① `exportable()` 集合与策略断言；② 用假 Hub/内存数据验证 `exportBackup` 对空域、坏 JSON 文件、镜像域 owner 不符的"跳过"是否可观测（配合 EXP-01 的字段修复）；③ 域大小超限时导出拒绝（EXP-02）。

## 9. 已核实无问题（负面结论，避免误改）

- NEVER 域不会出现在导出弹窗，且导出服务二次拦截（§4-2）。
- 默认勾选与「全选/全不选」的状态操作正确（`DataManagementPanel.ets:406-412, 1201-1209`；计数文案 `:1198-1199`）。
- 导出前 `hub.flush()` 排空共享写队列（`DataTransferService.ets:151`；`PersistenceHub.ets:337-349`；`AppStore.ets:246` 注入同一 `writeQueue`），常规 Store 的排队写不会滞后。
- 加密默认开启、关闭需二次确认，AAD 与凭证链路隔离（`DataManagementPanel.ets:1253-1288`；`TransferCrypto.ets:31, 86-100`）。
- 写入 UTF-8 分块循环 + `try/finally` 关 fd + 写后回读整文件比对（`FilePickUtils.ets:348-380`；`DataManagementPanel.ets:530-544`）。
- 导入读取有 64MB 上限与三级兜底（`DataManagementPanel.ets:574`；`FilePickUtils.ets:177-259`），解析对 magic/版本/checksum/域数/重复域有防护（`DataTransferService.ets:720-810`）。
- 文件域导出无路径拼接风险；导入文件名有 `isSafeDomainFileName`/`isSafeFileName` 校验（`DataTransferService.ets:950-958`；`StorageBackends.ets:384-392`）。
- `drafts`/`saved_threads` 当前磁盘布局单层、仅 `.json`，`exportFileDomain` 的过滤不会漏域文件（§3-3）。

## 10. 审计限制

- 本次为**只读静态审计**：未运行编译、Hypium、模拟器或真机；动态行为均以代码路径与设计稿推断，无法通过运行证实的点已集中到 §7「待验证事项」。
- 行号基于当前工作区（HEAD `72869858`）；相关实现若继续提交，引用行号可能偏移。
- 报告只覆盖导出侧；导入侧的域生效性/内存重载/计划 UI 由 `AUDIT_IMPORT.md` 覆盖，设计稿一致性/交叉治理由 `AUDIT_DESIGN_CONFLICT.md` 覆盖（§6 中涉及导入侧静默丢弃的部分与 EXP-02 互为因果，建议合并处理）。
