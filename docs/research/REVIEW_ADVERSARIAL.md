# 对抗性回归 / 安全 / 边界评审报告（独立评审③）

> 评审对象：本会话「用户数据系统（持久化统一治理 + 数据管理导出/导入）」第二批 + 第三批未提交改动，
> 以及第一批（`a4634d6d`）中与本会话需求（域对等性 / 草稿跨账号 / 导入计划口径 / 迁移未完成警示）相关的核心逻辑。
> 评审基线：`.dsh/review/REVIEW_BRIEF.md`；工作区 HEAD = `a4634d6d`。
> 评审日期：2026-10-31。评审方式：**只读静态推演**（git / read / grep）；**未运行编译、Hypium、模拟器**（Lead 已统一验证：
> assembleHap BUILD SUCCESSFUL、Hypium 736/736、check-eol 全 LF）。
> 本报告为独立对抗性结论，不复述已修复的审计条目；对「看起来危险但实际安全」的路径给出负面结论。
> 结论所引 `文件:行号` 均以工作区当前内容（含未提交改动）为准。

---

## 0. 总体结论

**有条件放行（不阻断）**。

- 未发现**默认主路径**可达的 P0（数据丢失 / 崩溃 / 安全漏洞）。
- 发现 **P1 × 1**：`R-A01` 草稿域跨账号数据外带/复制（导出含其他账号草稿正文；导入会把本机他账号草稿改键写入当前账号）。
  这是设计稿自认的「最高风险处」（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:394-396`），但本会话的键归一化与媒体可移植化都没有封住该路径；
  「跨账号一次性提示」仍列在 §13.5 遗留。**建议放行前至少补提示或过滤**，否则应在发布说明中明示该隐私边界。
- 发现 **P2 × 6**：`R-A02`（不可信容器资源耗尽）、`R-A03`（文件域计划计数与写入不一致）、`R-A04`（4MB 预警字符/字节口径混用）、
  `R-A05`（迁移未完成警示对可重试 SKIPPED 永久常驻且与「升级完成」自相矛盾）、`R-A06`（repairDomain 失败也报成功）、
  `R-A16`（ENVELOPE 域导入不校验条目 → 整封不可读 + 后续写入覆盖）。
- 发现 **P3 × 9**（时序 / 纯函数副作用 / UI 文案 / 死字段 / 待验证的运行时语义），见 §2。
- 上一批审计的关键修复经复核**仍然生效**（checksum 降级、8MB 超限可见、文件域条目校验、镜像 ownerUid 携带、TrackedThreadStore
  读失败不写空盘、ENVELOPE 强制 `{items}`、applyImport 前 flush、reloadAfterImport 逐域容错等），见 §3 负面结论。
- 放行条件建议：`R-A01` 修复或经产品确认接受并补提示；`R-A02`/`R-A03` 至少加条目数上限与计划口径校验；
  `R-A04`/`R-A05`/`R-A06` 属误导/可观测性问题，可随下一批修。`R-A16` 若能证明真实备份不会触发可降级为 P3。

---

## 1. 攻击面与边界推演

### R-A01（P1）草稿域跨账号数据外带/复制：导出不按账号过滤，导入把本机他账号草稿改键写入当前账号

**触发条件（可构造 / 可复现）**

1. 设备上账号 A 产生草稿（`filesDir/v2/drafts/draft_..._<hash(A)>.json`，键内 uid 短哈希见 `entry/src/main/ets/common/managers/DraftStore.ets:107-115`）；
   A 退出登录（`clearAuth` 不清设备级草稿，`entry/src/main/ets/store/AppStore.ets:799-836`）。
2. 账号 B 登录，进入 数据管理 → 导出：`drafts` 为 `ExportPolicy.INCLUDE` 默认勾选，导出结果中**包含 A 的草稿正文**。
3. 或仅执行导入：B 导入任意**含 `drafts` 域**的备份。导入计划的「本机载荷」读取的是整个草稿目录（含 A 的草稿），
   合并结果保留这些本机条目，写入阶段把**所有**草稿键尾账号段改写为 B → 磁盘上新增 `draft_..._<hash(B)>.json` 副本，
   B 的编辑器按当前账号键查找即可看到 A 的草稿。A 的原文件不会被删除（重复副本）。

**代码路径**

- 导出侧（不按账号过滤）：
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:326-355`（文件域走 `exportFileDomain`，只有 `drafts` 做了清媒体，没有账号过滤）；
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:386-414`（`exportFileDomain` 直接 `hub.files.listFiles(spec)` 全目录读）；
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:374`（`ownerUid` 只对 `ACCOUNT_MIRROR` 填充，草稿无归属信息）；
  - `entry/src/main/ets/common/transfer/DraftPortability.ets:46-84`（`makeDraftsPortable` 只清 `media`，正文/其他字段原样保留）。
- 导入侧（本机他账号草稿进入合并 → 被改键写盘）：
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:761-769`（`readDomainPayload` 对文件域同样返回整目录载荷）；
  - `entry/src/main/ets/common/transfer/DomainMergers.ets:313-330`（`mergeArrayPayloadByKey` 以 local ∪ incoming 并集，本机 A 草稿条目被保留）；
  - `entry/src/main/ets/common/transfer/DataTransferService.ets:1553-1592`（`planFileDomainWrites` 对**每一条**草稿调用
    `rewriteDraftKeyUidPart` 并按改写后的键写盘，包括本机 A 草稿）。
- 设计稿自认风险与缓解：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:394-396`（「马甲场景下可能把 A 的草稿发到 B 的账号」，
  缓解措施是键保留 uid 哈希；跨账号一次性提示未实现）。

**影响**

- 隐私串号：B 账号的可编辑/可导出范围出现 A 的草稿正文（同一设备多账号场景）；配合导出即把 A 的正文带出设备。
- 设计上依赖"键内 uid 哈希"做隔离，但导入/导出链路**主动改写/忽略**该哈希，缓解措施被绕过。
- 注意：跨账号"备份 → 当前账号找回草稿"本身是 cfc7d95e 的有意功能；本条 P1 针对的是**本机磁盘上的他账号草稿**
  未经用户明确选择也被复制/带出，且 UI 无任何提示（§13.5 遗留项）。

**修复建议**

1. 导出 `drafts` 与导入计划读取本机载荷时，按 `draftUidPart(currentUid)` 过滤键尾（未登录则按 `anon`）；或
2. 至少在导入计划与导出弹窗对「检测到其他账号的草稿 N 条」给出一次性提示（原 Phase 3 遗留），并默认**不复制**他账号条目；
3. 补充回归用例：`planFileDomainWrites(DRAFTS, merged, currentUid)`，merged 含两个不同 uid 尾的草稿，断言只写当前账号条目（现实现会两条都写）。

**存量说明**：同样的"合并全部 local 条目 + 统一改键写盘"在 `a4634d6d` 已存在；本批 DES-19 归一化把该行为在计划阶段显式化，
但未改变"本机他账号草稿也会被写入"的结果，属会话内未闭环（非本批新引入，但属本会话需求的核心边界）。

---

### R-A02（P2）不可信容器的资源耗尽：文件域海量条目 + legacy 路径绕过单域上限 + 大 record 合并

**触发条件（可构造）**

- 构造明文容器，`drafts`（或 `saved_threads`）payload 为接近 8M 字符的数组，使用**最小合法条目**：
  `{"key":"k000001","content":""}`（约 32 字符/条）→ 约 25 万条；`saved_threads` 用 `{"tid":"1","rawPages":[{}]}` 同量级。
  导入计划可执行（计数 > 0），确认后 `applyFileDomain` 逐条执行**同步** `openSync/writeSync/renameSync` → 主线程长时间无响应（ANR），
  并产生约 20~30 万个文件（磁盘块占用可达数百 MB~1GB）。
- 或直接用旧版离线存档兼容路径：`{"threads":[...]}`（无 magic、无 checksum）→ 被 `tryConvertLegacySavedThreadExport` 转成容器，
  **完全绕过** `normalizeContainer` 的单域 8MB/域数/结构校验，可利用到 64MB 文件上限（约 200 万条）。
- 同类资源面：`votes`/`poll_voted` 的 `Record<tid, ...>` 载荷最大 8M 字符可含上百万键，`mergeRecordByTime`/`mergePollVoted`
  会构造成千上万个 `Map`/对象条目，内存峰值可达数百 MB（低端机 OOM 风险）。

**代码路径**

- 单域上限只校验**字符数**且不限制条目数：`entry/src/main/ets/common/transfer/DataTransferService.ets:104-107, 356-367, 915-927`；
- 文件域写入无条数上限、逐条同步 IO：`entry/src/main/ets/common/transfer/DataTransferService.ets:733-753, 1553-1592`；
  `entry/src/main/ets/common/persistence/StorageBackends.ets:257-301`（`writeFileAtomic` 同步写）；
- 旧存档兼容路径绕过 `normalizeContainer`：`entry/src/main/ets/common/transfer/DataTransferService.ets:442-447, 1047-1080`；
- 大 Record 合并：`entry/src/main/ets/common/transfer/DomainMergers.ets:339-425, 565-621`；文件上限见 `PersistenceTypes.ets:124-125`。

**影响**：导入恶意/异常容器可能造成主线程 ANR、OOM、磁盘膨胀。需要用户主动选择并确认导入该文件（非默认路径），
且计划页会显示巨大条数可作人为中断信号；但这属于"不可信输入不应拖垮应用"的边界缺口。

**修复建议**

1. 文件域设置**条目数上限**（例如每域 ≤ 500/2000，超出整域拒绝并给出计划跳过原因）；
2. 旧存档兼容路径复用 `normalizeContainer` 的体积/域数/结构校验（至少单域 8MB 上限 + 条目数上限）；
3. `applyImport` 的文件逐写改为分批 + 让出主线程（或先预估写入数量并要求用户确认）；
4. `votes`/`poll_voted` 合并前对键数设上限（可按 `VOTE_MAX_ENTRIES` 截断输入，避免先建全量）。

---

### R-A03（P2）文件域导入计划计数与写入结果口径不一致：可显示"新增 N 条"但实际 0 写盘

**触发条件（可构造）**

- `drafts` payload 使用合并器容忍的 `{items: [...]}` 包裹形态（外部/工具构造容器）：
  `mergeArrayPayloadByKey` 按 `readArrayPayload` 接受包裹形态并输出同形态 `{items: [...]}`、`added=N`；
  `planFileDomainWrites` 只接受数组（`!Array.isArray(payload)` 直接返回 0 写盘、0 失败），`applyImport` 因此把该域当成功，
  `result.added += N`，UI 提示"导入完成：新增 N 条"，但磁盘上没有任何草稿文件。
- 或条目字段畸形（`key` 为数字/`media` 为对象等）：计划把条目计入"新增/更新"；写入阶段 `isValidFileDomainItem` 判失败，
  `applyFileDomain` 的失败数 > 0 时整域抛错（`applyImport` 捕获为"文件写入失败 N 个"），计划显示与实际结果不一致。

**代码路径**

- 计划计数来自合并器：`entry/src/main/ets/common/transfer/DomainMergers.ets:306-330, 674-717`；
- 计划阶段不校验文件域条目/形态：`entry/src/main/ets/common/transfer/DataTransferService.ets:1471-1478`（drafts 只做键归一化）；
  `entry/src/main/ets/common/transfer/DataTransferService.ets:1491-1519`（计数直接来自 `mergePayload`）；
- 写入计划对非数组/非法条目的处理：`entry/src/main/ets/common/transfer/DataTransferService.ets:1553-1592`；
- 结果上报：`entry/src/main/ets/common/transfer/DataTransferService.ets:680-701`（`added` 计入）、`686-690`（失败整域抛错）；
- UI 展示规则：`entry/src/main/ets/pages/DataManagementPanel.ets:1131-1157`。

**影响**：计划与结果对用户**误导**（"新增 N 条"但无数据写入，或整域失败）；由于源备份文件仍在，不构成不可恢复的数据丢失。

**修复建议**：文件域在**计划阶段**就强制数组形态 + 逐条 `isValidFileDomainItem` 预检，把非法条目计入计划跳过/失败计数并展示；
或者计划阶段直接产出 `FileDomainWritePlan` 并以其条数为准。

---

### R-A04（P2）单域体积显示与 4MB 预警口径混用（字符 vs 字节）→ 中文密集域漏报、体积显示失真

**触发条件（常态可触发，非攻击）**：某 Preferences 域（如 `settings`/`history`/`ai_sessions`）内容以中文为主：

- `PersistenceHub.estimateBytes` 对 Preferences 域返回**字符串长度**（UTF-16 code unit 数），而文件域返回真实字节数
  （`entry/src/main/ets/common/persistence/PersistenceHub.ets:317-323`；`StorageBackends.ets:354-373`）；
- 页面用 `formatSize(bytes)` 展示并拿 `bytes > DOMAIN_SIZE_WARN_BYTES`（4×1024×1024）判断预警
  （`entry/src/main/ets/pages/DataManagementPanel.ets:501-542, 1344-1360`；常量 `PersistenceTypes.ets:127-128`）；
- 中文 JSON 实际 UTF-8 字节约为字符数的 3 倍：4M 字符 ≈ 12MB 实际，页面却显示约 4.0MB；
  1.4M 字符（≈4.2MB 实际）不会触发预警。`Preferences` 单值 16MB 上限的前哨因此被推后约 3 倍。

**影响**："存储占用"合计与真实磁盘不一致、域间不可比；4MB 预警对中文内容**漏报**（不会误报，因为 charCount ≤ utf8 字节数）。
不影响数据正确性。

**修复建议**：Preferences 域改用 UTF-8 字节数（`util.TextEncoder.encodeInto(raw).length`，导出侧已有 `utf8Bytes` 可用），
或把常量/文案明确为"字符数"并在文档 §4.4/§4.5 同步口径。

---

### R-A05（P2）迁移未完成警示对"可重试 SKIPPED"可能永久常驻，且与"升级完成"自相矛盾、重试无效果

**触发条件（常态，多账号/未登录用户可达）**

- 设备上存在旧键，且其归属账号与当前账号不同/未登录——具体为：
  - 未登录时的账号镜像域旧键（`MigrationEngine.ets:456-461` → `legacyRetained=true`）；
  - 多账号 settings 旧键且无当前账号匹配（`DomainMigrators.ets:313-326`）；
  - 镜像/收藏旧缓存无当前账号归属（`DomainMigrators.ets:431-435, 492-499`）。
- 迁移汇总状态 `summarize()` **只统计 FAILED/DEFERRED**，SKIPPED 不影响状态 → 报告状态为 `COMPLETED`（`MigrationEngine.ets:757-777`），
  但 `countUnsettled()` 会把上述 SKIPPED 计入（`PersistenceTypes.ets:360-379`）。
- 这些 SKIPPED 域的旧键**不会**进入 `legacyKeys`（只有 MIGRATED 才登记，`MigrationEngine.ets:337-344, 367-368`），
  因此每次启动 `buildPlan` 都会重新检测（`MigrationEngine.ets:200-245`）→ 迁移反复重跑、结论恒为 SKIPPED。
- 结果：数据管理页同时显示「升级完成」与「有 N 个数据域尚未完成升级」；`canRetryMigration` 因 `migrationUnsettledCount > 0`
  恒为 true（`DataManagementPanel.ets:441-448`），点「重试升级」只得到同样的 SKIPPED（`DataManagementPanel.ets:599-615`），
  导出/清空弹窗的警示也永久存在（`DataManagementPanel.ets:644-652, 1243-1252`）。
  只有用户重新登录**旧数据所属账号**才可能消除（未登录镜像域甚至登录别的账号也永远消除不了）。

**代码路径**：`entry/src/main/ets/common/persistence/MigrationEngine.ets:456-461, 481-489, 757-777`；
`entry/src/main/ets/common/persistence/DomainMigrators.ets:313-326, 431-435, 492-499`；
`entry/src/main/ets/common/persistence/PersistenceTypes.ets:360-379`；
`entry/src/main/ets/store/AppStore.ets:1184-1202`；`entry/src/main/ets/pages/DataManagementPanel.ets:411-468, 599-615, 644-652, 1243-1252`。

**影响**：误导（用户以为升级未完成且可重试，实际可能只能由"登录原账号"或根本不影响导出）；常驻警示会降低用户对告警的敏感度；
每次启动重复迁移旧键有额外 IO。不直接造成数据丢失。

**修复建议**：
1. 对**可重建镜像缓存**（notifications/activities/favorite_membership）不置 `legacyRetained`，或单独归类为"可重建、无需迁移"；
2. settings 类无匹配账号的跳过，在 UI 明确"需登录该账号后自动迁移"，并让重试按钮条件区分"可立即解决"与"需登录态"；
3. `summarize()` 对 `countUnsettled()>0` 返回 `PARTIAL`（或 UI 在状态文案中并入"未完成域"口径），消除"升级完成 + 未完成"矛盾；
4. 被跳过的旧键纳入清理期（`legacyCleanupAt`）或至少不再每次启动重跑（可用 meta 标记已判定归属不可迁移）。

---

### R-A06（P2）`repairDomain` 无论清盘/重载是否成功都返回 true 并清健康标记

**触发条件（可复现思路）**：某域健康异常（读失败/带坏条目）→ 用户点「修复」→ `persistenceHub.removeDomain(spec)` 因 IO 失败返回 false，
或 `reloadAfterImport()` 对应 Store 重载抛异常（返回的失败列表被忽略）——此时 UI 仍提示"已修复该数据域"，
且 `persistenceHub.health.reset(domainId)` 清掉了健康标记；内存仍持有旧快照，用户下一次操作该 Store 时会把旧快照整体写回磁盘，
问题数据复现但健康面板不再显示。

**代码路径**：`entry/src/main/ets/store/AppStore.ets:1360-1373`（`removeDomain` 返回值未检查、`reloadAfterImport()` 返回值未检查、无条件 `health.reset`）；
`entry/src/main/ets/pages/DataManagementPanel.ets:549-595`（提示"已修复该数据域"）。

**影响**：虚假成功 + 可观测性丢失；可能绕过"修复→重建"的意图（旧内存快照回写）。不直接丢数据。

**修复建议**：`removeDomain` 返回 false 或 `reloadAfterImport()` 返回的 failed 列表包含该域（或非空）时：
不清健康标记、返回 false 并提示"修复未完全成功，建议重启应用/重试"。

---

### R-A16（P2）ENVELOPE 域导入不校验条目结构：一条坏条目使整封缓存不可读，随后真实写入覆盖（tracked_threads 数据丢失）

**触发条件（可构造）**：构造 `tracked_threads` payload `{"items":[{"tid":"1","lastCheckAt":1}]}`（缺其余字段），
来源为手工改包 / 未来版本 / 第三方工具。合并器只按 `tid`/时间合并（不校验条目结构）→ 计划显示新增 1 条 → 导入写盘成功；
`reloadAfterImport` 时 `CacheEnvelopeStore.load` 严格逐条校验失败 → 返回 null → `TrackedThreadStore` 清内存（不写盘，IMP-08 已修）；
用户随后任意"跟踪/取消跟踪/标记已读"都会以新内存快照 `persist()`，把磁盘上的本机原有跟踪任务彻底覆盖掉。
AI 会话因使用 `loadTolerant` 不会整封失效（`AiSessionStore.ets:219-226`），**tracked_threads 是唯一"整封严格"的设备级用户数据域**。

**代码路径**：`entry/src/main/ets/common/transfer/DomainMergers.ets:452-504`（只按业务键/时间，不校验条目字段）；
`entry/src/main/ets/common/transfer/DataTransferService.ets:684-701`（原样写信封）；
`entry/src/main/ets/common/infra/CacheEnvelopeStore.ets:215-234`（`load` 对任一坏条目返回 null）；
`entry/src/main/ets/common/utils/ThreadTrackPolicy.ets:266-295`（要求 16 个字段类型全部匹配）；
`entry/src/main/ets/store/TrackedThreadStore.ets:644-670, 675-677`（读失败只清内存；下一次真实写入覆盖）。

**影响**：导入不可信容器可导致本机原有跟踪数据在用户下一次操作后被永久覆盖（P2；需要 crafted 容器，非默认路径）。
审计 IMP-08/IMP-09 只修复了"读失败写空盘"，未修复"合并器不校验条目 → 整封不可读 → 后续覆盖"这一残余链路。

**修复建议**：合并器对 ENVELOPE 域输出前复用 Store 的 `validateItem`（如 `isValidCachedTrackedThread` / `isValidAiSession`）逐条过滤坏条目并计入 skipped；
或把 `TrackedThreadStore` 改为 `loadTolerant`（与 AI 会话一致），把"整封不可读"降级为"坏条目丢失"。

---

### R-A07（P3）计划与写入使用不同时刻的 uid：账号态在弹窗期间变化会把草稿写成 `anon` 键（登录后不可见）

**触发条件（异常时序）**：导入计划在已登录状态下构建（`preEvaluateDomainImport` 用计划时 uid 做草案键归一化，
`DataTransferService.ets:1440, 1476-1478`）；计划确认弹窗打开期间，后台会话校验失败触发异步退出登录（`SessionGuard` → `AppStore.clearAuth`，
`AppStore.ets:799-836`，会保留设备级数据但 uid 变空）；用户点确认 → `applyFileDomain` 用写入时 `this.uidProvider()`（空串）再次归一化，
草稿键尾写为 `anon`（`DataTransferService.ets:742, 1553-1580`；`DraftKeyUtils.ets:57-65`）。
登录后编辑器按当前 uid 哈希查找 → 草稿不可见（IMP-11 同类），且 UI 提示导入成功。

**影响**：条件极端（需会话在弹窗期间失效），但结果与 IMP-11 相同：草稿文件在盘但不可见；无提示。

**修复建议**：`applyImport` 前重新取 uid 并与计划捕获的 uid 比较（二者不一致则拒绝并要求重开计划）；
或在 `ImportPlan` 上固化计划时 uid，apply 时以计划 uid 写文件并在 UI 说明"请重新登录后重试"。

---

### R-A08（P3）`planFileDomainWrites` 声明为纯函数却原地修改入参记录

**触发条件（任何 drafts/saved_threads 导入）**：`planFileDomainWrites` 对每个条目执行 `record['key'] = rewritten`
（`entry/src/main/ets/common/transfer/DataTransferService.ets:1569-1581`），修改的是 `entry.mergedPayload` 内的对象引用，
而这些对象可能同时被 `pendingContainer.domains[].payload` 引用（合并器的 added 条目直接引用容器对象，
`DomainMergers.ets:530-553`）。当前因改写幂等（同一 uid）没有用户可见后果，但违反函数注释的"纯函数"契约，
未来若在 apply 之前复用计划载荷（比较/展示/重试）会出现难排查的隐性状态污染。

**修复建议**：复制 record（`const next: Record<string, Object> = {}` 逐字段拷贝 + 替换 key）后再 `JSON.stringify` 写盘。

---

### R-A09（P3）调度折叠区把"从未执行"的任务显示为"跳过"

**触发条件（页面首次打开即触发）**：`TaskStatus.lastOutcome` 默认值为 `SKIPPED`、`lastRunAt=0`
（`entry/src/main/ets/common/scheduler/SchedulerTypes.ets:110-127`）；`refreshScheduler` 先判断 `lastRunAt`/running 再依次判断
OK/FAILED/SKIPPED（`entry/src/main/ets/pages/DataManagementPanel.ets:376-408`）——`lastOutcome` 默认 SKIPPED 使"未运行"分支不可达，
从未跑过的任务显示"跳过"（看起来像被门禁跳过）。

**修复建议**：`lastRunAt <= 0` → "未运行"；"跳过"只在 `lastRunAt > 0 && lastOutcome === SKIPPED` 时显示。

---

### R-A10（P3）4MB 超标文案建议"清理该域"，但页面没有单域清理入口

**触发条件**：某域超过 4MB 阈值 → 存储占用行显示"⚠ 超过 4MB 单域预警阈值，建议清理该域"
（`entry/src/main/ets/pages/DataManagementPanel.ets:1641-1644`）。但「修复」按钮只出现在**数据健康异常**列表（`1524-1556`），
普通超域没有对应动作；唯一的清空是危险区全量清空。用户按提示无从操作。

**修复建议**：文案改为可执行路径（如"清除缓存/在设置中清理 AI 会话"），或为可清空域提供单域清理入口。

---

### R-A11（P3）修复文案对非可重建用户数据域夸大"重建"；弹窗异常时直接清盘（无二次确认）

**触发条件**：健康异常域为非 `rebuildable` 用户数据（settings/history/drafts/saved_threads 等）时，
面板说明写"「修复」（清空该域并重建）"，实际是**删除**（`DataManagementPanel.ets:1530, 556-559` 有"清空该域并重建"字样）；
`confirmRepairDomain` 在 `showAlertDialog` 抛异常时直接调用 `repairDomain` 执行清盘（`549-580` 的 catch 分支），
等于极端环境下跳过二次确认删除数据。

**修复建议**：文案按 `rebuildable` 二分（缓存"重建" vs 用户数据"删除且不可恢复"）；弹窗不可用时应**中止**并提示，而不是直接执行破坏操作。

---

### R-A12（P3，待验证）迁移整体异常时未完成计数漏报

**触发条件（故障注入）**：`runStartupMigration` 捕获异常后用**空 FAILED 报告**发布（`AppStore.ets:331-338`），
`startupMigrationReport` 被替换成没有任何 `domains` 的报告 → `migrationUnsettledCount` 返回 0（`AppStore.ets:1184-1202`），
导出/清空弹窗"旧数据不在备份中"的警示消失；虽然状态横幅仍显示"升级失败"，但用户可能在失败半步后导出/清空。
实际 `engine.run` 内部大多逐域捕获、整体抛错概率很低，故列 P3/待验证。

**验证方法**：临时在 `MigrationEngine.run` 注入一次抛错（只读评审不执行），或构造 `metaStore.save` 连续失败场景，
观察数据管理页 `migrationUnsettledCount` 与导出弹窗副标题。

**修复建议**：catch 分支优先从 `meta.migration` 读取上次报告作为 `startupMigrationReport`；读不到再退回空报告。

---

### R-A13（P3）导出/导入历史字段不完整（死字段）、同日记录不可区分

**触发条件（常态）**：`TransferHistoryEntry` 定义了 `formatVersion`/`dataVersion`（`PersistenceTypes.ets:403-428`），
但导出/导入两处写入都未赋值（`DataManagementPanel.ets:904-915, 1210-1223`），`refreshTransferHistory` 也不展示
（`DataManagementPanel.ets:341-374`）→ 与审计 EXP-06 同类的"导出但不消费"死字段；`note` 只在读侧截断 120 字符
（`PersistenceMetaStore.ets:215-216`）；`formatDate` 只显示到天（`DataManagementPanel.ets:1368-1375`），同一天多次导入无法区分。

**影响**：历史可观测性弱（不影响数据）。**修复建议**：写入时补 `formatVersion/dataVersion`（导入取容器字段），
展示时间精确到分钟，或删除未消费字段。

---

### R-A14（P3，待验证）不可信 JSON 的 `__proto__` 键在合并器 Record 赋值语义下可能静默丢失/改变对象原型

**触发条件（构造 settings 容器）**：`JSON.parse` 会保留 `{"__proto__":{...}}` 的自有属性；`mergeSettings` 用
`merged[incomingKeys[i]] = incomingValue` 写入（`DomainMergers.ets:200-239`），键为 `__proto__` 时普通对象字面量会走原型赋值
（非自有属性），字段**静默丢失**（`added` 仍计数）；另 `SETTINGS_ARRAY_KEY_FIELDS['__proto__']` 会命中原型对象，
使数组分支的 `keyField` 变为非字符串（`DomainMergers.ets:210-214`）。`mergeRecordByTime`/`mergeStringRecord` 有同类写入点
（`DomainMergers.ets:614-619, 658-667`）。仅浅合并，未见全局原型污染（`Object.prototype`）路径；影响面限于恶意方自身数据。

**验证方法（Hypium Local Test 可测）**：`mergePayload(DomainIds.SETTINGS, null, JSON.parse('{"__proto__":{"x":1}}') as Object)`，
断言 `Object.keys(result.merged)` 是否包含 `__proto__`；或对 votes 构造 `{"__proto__": {...}}`。
**修复建议**：合并器统一过滤 `__proto__`/`constructor` 键（计入 `skipped`）。

---

### R-A15（P3，待验证）64MB 边界输入被多次整串解析/序列化 → 峰值内存数倍

**触发条件（恶意/超大输入）**：`parseBackup` 先 `tryConvertLegacySavedThreadExport(content)` 做一次 `JSON.parse`（`DataTransferService.ets:442`），
再 `isEncryptedBackup(content)` 内部再 parse（`TransferCrypto.ets:172-186`），加密容器 `decryptBackup` 再 parse（`TransferCrypto.ets:243-249`），
最后正式 `JSON.parse(plaintext)`（`DataTransferService.ets:462-464`）；`normalizeContainer` 又对每个域 `JSON.stringify(payload)` 度量体积
（`DataTransferService.ets:915-921`）。64MB 上限输入下峰值可数倍于文件大小，低端机有 OOM/ANR 风险（DoS，无数据后果）。

**修复建议**：先做 `trimStart().startsWith('{"magic"')` 前缀判断再 parse；解析结果复用；域名/体积度量改为共享同一次序列化。

---

## 2. 已验证安全 / 负面结论（避免误报）

以下路径经代码推演**未发现新增问题**，列出以缩小后续排查范围：

- **N-A01 容器解析防护完备**：`magic` 白名单、`formatVersion` 正整数、`dataVersion` ≥0 整数、`domains` 数组 ≤64、
  重复域 ID 只保留首个、缺 payload/非法条目/单域超限进入 `droppedDomains` 并在计划中可见（不静默丢弃）。
  证据：`DataTransferService.ets:845-948, 537-543`。
- **N-A02 加密容器无 PBKDF2/长度型 DoS**：`kdf`/`cipher` 白名单、`iterations` 区间 `[10000,600000]`、salt/iv/tag 长度校验、
  `doFinal` 判空、失败统一文案（无 padding oracle 提示）。证据：`TransferCrypto.ets:236-309`。
- **N-A03 路径穿越被阻断**：草稿键 `isValidDraftKey` 仅允许字母/数字/下划线（`DraftKeyUtils.ets:26-40`）；
  文件名 `isSafeDomainFileName`/`isSafeFileName` 拒绝 `/`、`\`、`..`（`DataTransferService.ets:1088-1096`；
  `StorageBackends.ets:403-419`），`writeFileAtomic` 二次校验（`265-301`）；`saved_threads` tid 纯数字校验
  （`DataTransferService.ets:1110-1148`）。注意：`rewriteDraftKeyUidPart` 会把"键尾含非法字符"的畸形键改写为合法 uid 段
  （`DraftKeyUtils.ets:79-90`，再校验），这只会把畸形键"洗白"成合法键名——写入路径仍安全，无文件系统越界。
- **N-A04 镜像 ownerUid 跨账号跳过对"正常备份"有效，但不是防篡改安全边界**：导出对 `ACCOUNT_MIRROR` 读信封
  `ownerUid`，非空且 ≠ 当前 uid 时跳过（`DataTransferService.ets:304-318`）；导入计划对来源账号 ≠ 当前账号跳过并提示
  （`DataTransferService.ets:1417-1435`）；旧备份 ownerUid 为空按当前账号恢复（计划注明"来源账号未知"）。
  明文容器可由用户手改 `ownerUid` 绕过该防护——容器无签名，本就不是安全边界；加密容器需口令才能改。
  **结论：防误操作/默认路径串号有效，防恶意构造无效（与设计一致，建议文档不要表述为"防篡改"）。**
- **N-A05 导入不会把本机 AI Key 外带到第三方端点**：`restoreLocalSecrets` 回填密钥前做服务端点一致性校验
  （`endpoint`/`toolsEndpoint`，`DataTransferService.ets:1258-1366`）；AI 请求 URL 只由这两个字段构造
  （`service/ai/AiEndpoint.ets:58-100`；`AiChatClient.ets:93`），没有其它字段可替换 URL。本地 Key 只会在"同 id + 同端点"的导入 profile 上回填。
- **N-A06 草稿媒体的沙箱绝对路径不会进入备份/日志**：`makeDraftsPortable` 清空整条 `media` 数组（含 `localPath`/`videoLocalPath`）
  并重建对象（`DraftPortability.ets:46-84`）；即使 `media` 类型畸形也会被替换为 `[]`（`61-75`）；导出日志只记条数
  （`DataTransferService.ets:351-354`），历史/错误文案不含路径。
- **N-A07 导出/导入历史不含业务内容、防膨胀**：`TransferHistoryEntry` 仅元数据（`PersistenceTypes.ets:403-428`）；
  `normalizeTransferHistory` 只接受合法 kind、上限 10、`note` 截断 120（`PersistenceMetaStore.ets:178-220`）；
  `appendTransferHistory` 最新在前并截断（`PersistenceTypes.ets:439-452`）；`recordTransferHistory` 读取-追加-保存不会丢失
  meta 其它字段（normalizeMeta 覆盖全部现有字段，`PersistenceMetaStore.ets:165-176`）。
- **N-A08 升级器无绕过路径且对异常版本值保守**：唯一入口在 `preEvaluateDomainImport`（`DataTransferService.ets:1453-1470`）；
  `schemaVersion` 为字符串/NaN/Infinity 时 `readNumber` 兜底 0，负数/小数按"低于当前"走升级器（无规则→跳过并给原因），
  高于当前则跳过；不会按新结构误写。证据：`DataTransferService.ets:1227-1232, 1453-1470`；`DomainUpgraders.ets:36-61`。
- **N-A09 清空/导入/重载时序防线成立**：`applyImport` 写盘前排空写队列（`DataTransferService.ets:656-661`）、写后 flush（`713`）；
  文件域写失败整域上报（`686-690`）；无变化域跳过写盘（`675-683`）；清空时删除旧键/旧文件目录并重置 meta 历史
  （`AppStore.ets:1277-1321`），不会出现"清空后旧数据被迁移复活"；`reloadAfterImport` 逐域容错并提供失败列表
  （`AppStore.ets:1389-1457`）。`repairDomain` 也复用了该重载路径（见 R-A06 的返回值缺陷）。
- **N-A10 历史写入时机正确**：导出只在文件写入成功 + 回读校验一致后记录（`DataManagementPanel.ets:884-916`）；
  用户取消保存/写入失败/回读不一致都不记；导入在 `applyImport` 返回后记录（`1204-1223`）。
- **N-A11 文件域名与草稿键校验与 Store 读侧同规则**：`isValidFileDomainItem` 复用 `isValidDraftKey`/数字 tid + 非空 rawPages
  （`DataTransferService.ets:1098-1148`），避免"写盘成功但 Store 静默跳过"（审计 IMP-02 的修复仍生效）。
- **N-A12 不可清空域受保护**：`clearAllLocalData` 只遍历 `clearable()`（`AppStore.ets:1277-1283`）；`repairDomain` 显式拒绝
  `!clearable`（`AppStore.ets:1360-1364`）→ 凭证/会话表/meta 不会被导入修复入口误删。
- **N-A13 旧 meta 缺 `legacyRetained`（本批新增字段）不会长期漏报**：SKIPPED 域的旧键不进入 `legacyKeys`，
  而 `buildPlan` 只在报告 COMPLETED 时用 `legacyKeys` 过滤（`MigrationEngine.ets:200-216`），因此这些旧键每次启动都会被重新检测、
  重新跑迁移并重写报告（下一次启动即带 `legacyRetained`）。**但**这一"每次重跑"正是 R-A05 永久警示的根因之一。
- **N-A14 `transferHistory` 与迁移报告并发写 meta 的竞态不可达（当前 UI）**：`recordTransferHistory` 是 load→append→save
  （`DataTransferService.ets:273-290`），与 `MigrationEngine.run` 的逐域 `saveReport` 理论上存在"最后写赢"窗口
  （`PersistenceMetaStore.ets:54-95, 126-139`）；但两者分别由**模态**导出/导入弹窗与"重试升级"按钮驱动，UI 层互斥，
  当前流程不可并行。若未来放开并行 meta 写入，需要加版本号/串行锁。**结论：当前判为低风险，无需修复。**
- **N-A15 恢复旧备份的草稿不会被保留期立即清掉**：`DraftStore.cleanupStale` 按**文件 mtime** 判定 7 天保留期
  （`DraftStore.ets:519-580`），导入写入的文件 mtime 为当前时间 → 不会出现"导入旧备份后草稿立刻过期删除"的疑似丢失路径（已排除）。
- **N-A16 草稿"无变化"识别修复有效（DES-19 主目标达成）**：`normalizeDraftKeysForAccount` 重建对象时保持字段顺序
  （`DraftPortability.ets:136-146`），同账号重复导入时键/内容一致 → 合并器 `sameValue` 判定无变化 → `applyImport` 跳过写入
  （`DataTransferService.ets:675-683`）。但若设备上存在**其他账号**草稿，`drafts` 域每次都会因 R-A01 被计为"有变化"。
- **N-A17 导入不会删除本机多余文件**：`applyFileDomain` 只写不删（`DataTransferService.ets:733-753`），不会因导入失败/部分成功删除本地数据
  （REPLACE_BY_KEY 的并集语义，非整域替换）。
- **N-A18 重复/未知/缺内容域不静默**：解析丢弃 → `droppedDomains` → 计划跳过条目（`DataTransferService.ets:537-579`）；
  plan 中域名一律取 Catalog label、不信任容器 `label`（`DataTransferService.ets:605-614, 1396-1400`），避免伪装敏感域诱导确认。
- **N-A19 `checksum` 仅防截断不防篡改（设计已声明），降级为警告不会挡合法备份**：`DataTransferService.ets:521-536`。
- **N-A20 legacy 存档兼容路径输出形态安全**：`tryConvertLegacySavedThreadExport` 硬编码 `saved_threads` + schemaVersion=1
  （`DataTransferService.ets:1047-1080`），不会与未知域混淆；风险仅为 R-A02 的资源上限（无域限校验）。

---

## 3. 与上一批审计修复的复核（确认未回归，不重复列为问题）

| 上一批修复点 | 复核结论 | 证据 |
| --- | --- | --- |
| 单域上限双向可见（导出 omitted / 导入 droppedDomains） | 生效 | `DataTransferService.ets:356-367, 915-927, 571-583` |
| 文件域导入条目校验（IMP-02） | 生效 | `DataTransferService.ets:1098-1148, 1553-1592` |
| 镜像域 ownerUid 携带 + 跨账号跳过（DES-04） | 生效（防误操作，见 N-A04） | `TransferTypes.ets:48-65`；`DataTransferService.ets:304-318, 1417-1435` |
| 迁移未完成导出/清空警示（EXP-03 口径） | 警示存在，但口径副作用见 R-A05 | `DataManagementPanel.ets:644-652, 1243-1252` |
| `applyImport` 前 flush、写后 flush（竞态） | 生效 | `DataTransferService.ets:656-661, 713` |
| `reloadAfterImport` 逐域容错 + 失败上报（IMP-07） | 生效；但 repairDomain 未消费返回值（R-A06） | `AppStore.ets:1389-1457` |
| TrackedThreadStore 读失败不写空盘（IMP-08） | 生效；残余链路见 R-A16 | `TrackedThreadStore.ets:644-670` |
| ENVELOPE 域强制 `{items}`（IMP-09） | 生效（形态层面） | `DomainMergers.ets:285-303, 146-151` |
| 清空后重置迁移报告/历史（DES-09） | 生效 | `AppStore.ets:1330-1348` |
| `dataTransferService.init` 移出迁移 try（EXP-04） | 生效 | `AppStore.ets:339-346` |
| 未登录草稿跳过（IMP-11 改进） | 生效（计划层） | `DataTransferService.ets:1436-1445` |

---

## 4. 待验证 / 需真机或故障注入的项

| 编号 | 待验证点 | 建议验证方法 |
| --- | --- | --- |
| R-A05 | 永久警示与"升级完成"并存、重试无效果 | 构造旧键归属非当前账号（如清理 `v2.*` 后写旧 `notifications_<uid>` 键）→ 启动 → 数据管理页观察状态/警示/重试按钮；再登录另一账号重试观察是否仍跳过 |
| R-A02 | 海量文件域条目导致的 ANR/磁盘膨胀 | 构造 ~25 万条最小合法 drafts payload 的明文容器导入（真机/模拟器），观察写入耗时与文件数（仅测试环境） |
| R-A14 | `__proto__` 键在 ArkTS 运行时的 Record 赋值语义 | Hypium：`mergePayload(SETTINGS, null, JSON.parse('{"__proto__":{"x":1}}'))` 断言 `Object.keys(merged)`；对 votes 同理 |
| R-A15 | 64MB 输入的峰值内存 | 真机/模拟器导入 64MB 合法明文容器，观察内存曲线与是否 OOM |
| R-A12 | 迁移整体异常时 unsettled=0 | 故障注入（临时让 `MigrationEngine.run` 抛错）观察导出弹窗副标题 |
| R-A16 | 坏条目 tracked_threads 导入后整封不可读、下一次写入覆盖 | 构造缺字段条目的 tracked_threads 域导入 → 观察跟踪列表；随后新增一条跟踪 → 检查磁盘 `v2.tracked_threads` |
| R-A01 | 跨账号草稿外带/复制的完整链路 | 真机：A 建草稿 → A 退出 → B 登录 → B 导出检查备份 JSON 是否含 A 草稿；B 导入任一含 drafts 的备份后检查 `drafts/` 是否出现 B 键副本、编辑器是否可见 |

---

## 5. 评审方法与限制

- 只读静态评审：通读未提交改动的 9 个修改文件 + 2 个新增源码文件、第一批相关核心链路（DataTransferService / DomainMergers /
  TransferCrypto / PersistenceHub / CacheEnvelopeStore / 各 Store 读侧 / MigrationEngine / DomainMigrators）、3 份审计报告与设计稿相关章节。
- 未执行编译、Hypium、模拟器（按分工由 Lead 统一验证）；涉及 ArkTS 运行时语义（如 `__proto__`、OOM 峰值）的结论已标「待验证」。
- 未发现与「默认路径可达的 P0」相符的证据；R-A01 为本次唯一 P1，且其代码路径自第一批起即存在，评审意见已在文中标注存量属性。
- 本报告不修改源码/文档/测试，仅新增本文件（`docs/research/REVIEW_ADVERSARIAL.md`）。
