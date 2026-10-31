# 代码正确性 / 行为等价性独立评审报告

> 评审对象：本会话「用户数据系统（持久化统一治理 + 数据管理导出/导入）」全部改动。
> 基线：HEAD = `a4634d6d`（已提交第一批）+ 当前工作区未提交的第二/三批改动。
> 评审方式：独立只读评审（fresh reviewer）。**未修改任何源码/文档/测试**，**未运行编译、Hypium、模拟器**（按评审约束由 Lead 统一验证）；仅运行 `node scripts/check-eol.mjs`（只读自检，结果：全部已跟踪文本文件 LF；另对 5 个新增文件做字节级 CR 检查，均为 0）。
> 结论：**有条件放行**（无 P0/P1；5 项 P2 需修复或明确登记，P3 共 18 项可进 §13.5 遗留）。

---

## 1. 总体结论

本会话改动的**代码正确性与行为等价性总体成立**：

- 纯函数抽取（`preEvaluateDomainImport` / `mergeDomainImportEntry` / `planFileDomainWrites`）与 `a4634d6d` 的旧内联实现逐分支等价（跳过原因文案、顺序、计数、异常处理均一致，唯一差异见 R-C06）；文件域写入逻辑包含条目校验、草稿键改写、非数组载荷处理，行为与旧实现一致。
- 草稿键归一化（DES-19）的**主目标达成**：计划阶段把键尾归一化为当前账号后，"同目标草稿"从「新增」变为「更新」，跨账号找回语义与写盘一致；归一化函数保持字段顺序、不修改入参、对非数组/空键/已是当前账号均安全。
- 迁移 `legacyRetained` 的**置位覆盖完整**（3 个转换器 + 1 个引擎分支），不可重试的 SKIPPED 不置位；`countUnsettled` 口径与 brief/设计稿一致；`normalizeReport` 反序列化已实现。
- 导出/导入历史**写入时机正确**（导出在文件保存 + 回读校验通过之后；导入在 `applyImport` 返回之后），上限截断、清空一并清理均已实现，记录内容不含业务数据。
- 升级器接入顺序符合设计（高版本拒绝 → 低版本升级/无规则跳过 → 草稿归一化 → 合并/写盘），升级后的 payload 确实流入 merge 与写盘。
- 上一批回归点（applyImport 前 flush、逐域容错 reload、无变化跳过、TrackedThreadStore 读失败不写空盘、ENVELOPE 强制 `{items}`、导出 updatedAt）全部仍然成立。

需要处理的是 **P2 级问题**（契约/可观测性/测试门禁）：清空数据后迁移「未完成」口径不重置导致长期误报（R-C01）；`repairDomain` 丢弃 reload 失败结果、未登录镜像域内存不刷新却提示成功（R-C02）；两类关键安全门禁（legacyRetained 置位、normalizeReport 读取）**没有测试能守住**（R-C03/R-C04）；DES-19 的"内容相同草稿识别为无变化"子承诺在真实导出形状下不成立（R-C05）。

**放行条件（建议）**：
1. R-C01 修复（清空时重置 `migration.domains/status`）或设计稿明确登记为已知行为；
2. R-C05 与设计稿/测试口径对齐（修 `makeDraftsPortable` 字段顺序或降级 §6.4/§13.3 承诺）；
3. R-C03/R-C04 补测试断言（或在 §13.5 明确登记为未覆盖风险）；
4. P3 清单择要登记 §13.5。

---

## 2. 问题清单

> 分级：P0 数据丢失/崩溃/安全漏洞（默认路径可达）；P1 契约落空/可复现数据错误或隐私问题；P2 体验/可观测性/文档；P3 可维护性。
> 除特别标注外，问题均位于**未提交**代码；标注「既有」表示 `a4634d6d` 之前已存在、本会话未引入。

### P2

#### R-C01（P2）清空本地数据后，「升级未完成」警示口径未重置 → 页面/导出/清空弹窗长期误报，且跨重启保留

**证据**
- `entry/src/main/ets/store/AppStore.ets:1277-1321`（`clearAllLocalData`）：删除可清空域、`removeLegacyKeys()`、`removeLegacyFileDirs()` 后调用 `resetMigrationLegacyReport()`（1317 行）。
- `entry/src/main/ets/store/AppStore.ets:1330-1348`（`resetMigrationLegacyReport`）：只清 `meta.migration.legacyKeys`、`legacyCleanupAt`、`transferHistory`；**`meta.migration.domains` 与 `meta.migration.status` 原样保留**，内存 `startupMigrationReport` 的 `domains` 同样保留（1332-1337）。
- `entry/src/main/ets/store/AppStore.ets:1196-1202`（`migrationUnsettledCount`）= `startupMigrationReport.countUnsettled()`；`entry/src/main/ets/common/persistence/PersistenceTypes.ets:368-379` 把 `SKIPPED && legacyRetained`、`FAILED`、`DEFERRED` 计入。
- `entry/src/main/ets/pages/DataManagementPanel.ets:446-448`（`canRetryMigration` 含 `migrationUnsettledCount > 0`）、`644-652`（导出副标题警示）、`1243-1252`（清空副标题警示）。
- 重启路径：`entry/src/main/ets/common/persistence/MigrationEngine.ets:178-191`（`inspect`）、`200-259`（`buildPlan`，旧键/旧目录已被清空 → `pending=false`）、`entry/src/main/ets/store/AppStore.ets:319-329`（`pending=false` 时直接 `report = meta.migration`）→ **从持久化 meta 读回旧 report，误报跨重启保留**。

**问题与影响**
清空本地数据后（用户已主动删除旧键/旧目录），数据管理页仍显示旧的 FAILED/DEFERRED/SKIPPED-retained 明细与「重试升级」按钮；导出弹窗仍提示"有 N 个数据域尚未完成升级，其旧数据不会包含在备份中"；清空弹窗（下一次打开）仍警告"清空会连同它们的旧数据一起删除"。这些文案与事实矛盾。无数据丢失，但会误导用户点「重试升级」（点一次可自愈：空计划 → `NOT_REQUIRED`），并降低警示的可信度。
既有背景：`a4634d6d` 的 DES-09 修复只重置 `legacyKeys`，FAILED/DEFERRED 的旧明细本就会残留；**本轮 C 批把 SKIPPED-retained 纳入统计后，触发面显著扩大**（未登录用户的镜像域跳过是常见状态）。

**修复建议**
在 `resetMigrationLegacyReport` 中一并重置迁移结果：`meta.migration.domains = []`、`meta.migration.status = MigrationStatus.NOT_REQUIRED`（保留 `legacyCleanupAt=0`），并同步更新内存 `startupMigrationReport`；**不要**重置 `meta.dataVersion` / `migratedAt` / `migrationNoticeAcknowledged`（避免触发重复迁移/重复提示）。同时把设计稿 §6.7/§13.3"清空后重置迁移报告"的口径补成"旧数据清单 + 迁移结果明细 + 导出/导入历史"。

---

#### R-C02（P2）`repairDomain` 丢弃 `reloadAfterImport` 失败结果、未登录镜像域内存不刷新，却统一提示「已修复」并清健康标记

**证据**
- `entry/src/main/ets/store/AppStore.ets:1360-1373`（`repairDomain`）：`removeDomain` → `flush` → `await this.reloadAfterImport()`（**返回值 `string[]` 被丢弃**）→ `health.reset(domainId)` → 返回 `true`。
- `entry/src/main/ets/store/AppStore.ets:1389-1440` + `1449-1457`（`reloadImportStep`）：任一 Store 重载失败只记录到 `failed` 数组并记日志，不抛出。
- `entry/src/main/ets/store/AppStore.ets:754-757`（`loadMirrorData`）：未登录（`uid` 为空）时**直接 return**，不重载/不清空镜像域内存。
- `entry/src/main/ets/pages/DataManagementPanel.ets:587-595`：`ok === true` 即 toast「已修复该数据域」并 `refreshAll()`。

**问题与影响**
1. 若被修复域对应的 reload 步骤失败（例如 preferences 读失败仍存在），内存仍是**清盘前的旧快照**，而健康标记已被清除、用户被告知修复成功；之后用户对任一 Store 的写操作会把旧快照整体回写磁盘，**复现本次想清除的脏数据**，且故障被掩盖（健康卡片不再显示）。
2. 未登录时修复镜像域（notifications/activities/favorite_membership）：磁盘已清空，但 `loadMirrorData` 提前返回，内存缓存不刷新，页面继续显示已删除的缓存，直到重新登录/重启。
3. 修复操作没有清空 `dataTransferService` 相关持久化锚点之外的状态——这一条本身没问题，但"提示成功"与"实际刷新失败"不一致属于契约落空。

**修复建议**
`repairDomain` 收集 `reloadAfterImport()` 的 `failed`；若本域映射的步骤失败（可建立 domain → step 名映射），保留健康标记并返回失败/提示"已清空但界面刷新失败，建议重启"。未登录时对镜像域直接提示"请登录后修复"或跳过镜像域修复入口。文档（§6.7 修复按钮语义）补"刷新失败会保留健康标记"。

---

#### R-C03（P2）迁移 `legacyRetained` 置位链路无测试门禁（安全警示可静默漏报）

**证据**
- 置位点（本轮新增）：`entry/src/main/ets/common/persistence/DomainMigrators.ets:320-326`（多账号 settings 无匹配）、`431-436`（镜像 envelope 无当前账号缓存）、`492-499`（收藏关系无当前账号缓存）；`entry/src/main/ets/common/persistence/MigrationEngine.ets:458-461`（未登录跳过镜像域，`MigrationDomainResult` 第 5 参传 `true`）、`481-485`（把 `converted.legacyRetained` 透传）。
- 现有测试：`entry/src/test/PersistenceMigrationUnit.test.ets:345-358`、`361-376`、`379-395` 对上述三种 SKIPPED 只断言 `result.ok === false` 与 `skippedReason.length > 0`，**未断言 `legacyRetained`**；`entry/src/test/MigrationUnsettled.test.ets:20-34` 用手工 `new MigrationDomainResult(..., true)` 验证 `countUnsettled`，**不覆盖置位逻辑本身**。

**问题与影响**
若后续重构漏置位（例如改写跳过分支、把 `skippedReason` 改成其它字段），全部 736 个用例仍会通过，但导出/清空警示会静默漏报——用户在"以为备份完整"的状态下清空本地数据，属**安全门禁失效**（潜在数据丢失路径）。这是本轮 C 批交付的核心正确性，却没有被测住。

**修复建议**
在 `PersistenceMigrationUnit.test.ets` 上述三个用例补 `expect(result.legacyRetained).assertTrue()`；对不可重试跳过补 `false` 断言（`DomainMigrators.ets:746-750` 的 `convertDropped`、`MigrationEngine.ets:476-478` 旧数据不可解析、`491-495` 新键已存在）。如需覆盖 `MigrationEngine.runTask` 的"未登录镜像域"分支，可复用 `entry/src/test/HistoryReadLedgerUnit.test.ets:25` 的内存 `PreferencesStore` 替身思路（建议抽成可复用测试工具）。

---

#### R-C04（P2）`normalizeReport` 的 `legacyRetained` 反序列化路径无测试覆盖（重启后警示静默丢失风险）

**证据**
- `entry/src/main/ets/common/persistence/PersistenceMetaStore.ets:239-282`（`normalizeReport`，`legacyRetained` 读取仅 265 行）；持久化写入走 `JSON.stringify(meta)`（83-95 行）。
- `entry/src/test/MigrationUnsettled.test.ets:48-58` 的「JSON 保真」用例只做 `JSON.stringify(report)` → `JSON.parse`，**不经过** `normalizeMeta`/`normalizeReport`（`PersistenceMetaStore.ets:165-176`、`239-282`）。
- 重启后报表来源：`AppStore.ets:319-329`（读取 `meta.migration`）→ `normalizeReport` 是唯一反序列化入口。

**问题与影响**
若 `normalizeReport` 漏读/读错 `legacyRetained`（或字段改名、旧 meta 兼容回归），警示只在**当次进程**有效，重启后 `countUnsettled` 归零；现有测试仍全绿。该字段是跨重启警示的唯一数据来源，属安全门禁的持久化环节。

**修复建议**
新增 `PersistenceMetaStore` 用例（用内存 `PreferencesStore` 替身写入一段含 `legacyRetained: true` 的 meta JSON）：`load()` 后断言 `meta.migration.domains[i].legacyRetained === true` 且 `countUnsettled()` 正确；同时断言缺失/坏类型字段容错（默认 `false`）。可同时覆盖 `transferHistory` 的 normalize 截断/坏条目丢弃。

---

#### R-C05（P2）DES-19「内容完全相同的草稿被识别为『无变化』」在真实导出产物上不成立（文档承诺与实现不一致）

**证据**
- `entry/src/main/ets/common/managers/DraftStore.ets:152-167`（`EditorDraft` 字段声明顺序：`key, content, subject, media, updatedAt`）；`340-351`（`saveDraft` 用 `JSON.stringify(draft)` 写盘，即原生草稿的 `media` 位于 `updatedAt` 之前）。
- `entry/src/main/ets/common/transfer/DraftPortability.ets:60-80`（`makeDraftsPortable`）：逐字段复制时**跳过 `media`**（66-74），最后**追加** `next['media'] = []`（75 行）→ 导出草稿的字段顺序变为 `key, content, subject, updatedAt, media`。
- `entry/src/main/ets/common/transfer/DataTransferService.ets:1476-1478`：计划阶段只**保序**归一化 key（`DraftPortability.ets:136-146`）；判等走 `DomainMergers.ets:514-554` 的 `mergeArrayPreferIncoming` → `sameValue`（543 行）→ `JSON.stringify(left) === JSON.stringify(right)`（854-861 行）。
- 设计稿承诺：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:830`（"内容完全相同的草稿被识别为「无变化」而不触发写盘"）、`1594-1597`。
- 现有测试：`entry/src/test/DataTransferImportPlan.test.ets:567-579` 的"内容完全一致 → 无变化"分支用手工构造的**同字段顺序**对象，绕过真实导出形状。

**问题与影响**
同设备"导出→回导"（或跨账号找回且内容等价）时，本机原生草稿（`media` 在 `updatedAt` 前）与备份草稿（`media` 在末尾）即使内容等价（media 均为空、其余字段相同），也会被 `JSON.stringify` 判为不同 → 计划显示「更新 N 条」并触发写盘（把文件改写成导出顺序）。首次回导必然发生一次；之后草稿以导出顺序落盘，再导才可判等。无数据丢失（media 清理是产品既定决策且 UI 有提示），但**计划计数虚高、多一次无意义写盘、文档/测试承诺失真**。主目标"跨账号同目标草稿按更新计"已验证成立（见 A 项），问题仅在"无变化"子承诺。

**修复建议（择一）**
a) `makeDraftsPortable` 保持字段顺序：复制其余字段时**在原位置写入空 `media`**（而非追加到末尾）；
b) 草稿判等改为字段序无关比较（递归按键排序后序列化，或对 `media` 单独处理）；
c) 接受现状：把设计稿 §6.4/§13.3 的"内容完全相同→无变化"降级为"同键→更新/覆盖（含媒体引用清空），仅当字段顺序一致时识别无变化"，并把测试注释改为明确覆盖范围。

---

### P3

#### R-C06（P3）合并失败分支丢失 `policy`（相对 `a4634d6d` 的细微行为差异）
- 证据：`entry/src/main/ets/common/transfer/DataTransferService.ets:622-629` 新建 `failedEntry` 只设 `domainId/label/willSkip/reason`；旧实现（`HEAD:entry/src/main/ets/common/transfer/DataTransferService.ets` 的 `buildImportPlan` catch 分支）复用已设 `entry.policy = spec.importPolicy` 的条目。
- 影响：当前 UI 的 `buildPlanLines` 对 `willSkip` 条目不读 `policy`（`DataManagementPanel.ets:1138-1140`），用户不可见；但计划数据消费方（测试/未来 UI）拿到的策略字段是默认 `SKIP`，与真实策略不符。
- 建议：`failedEntry.policy = spec.importPolicy`。

#### R-C07（P3）`TransferHistoryEntry.formatVersion / dataVersion` 永远为 0（字段语义落空）
- 证据：`entry/src/main/ets/common/persistence/PersistenceTypes.ets:408-411`（字段注释"容器格式版本/数据版本"）；两处构造均未赋值：`DataManagementPanel.ets:903-916`（导出历史）、`1210-1223`（导入历史）；`DataTransferService.ets:273-290` 原样保存。
- 影响：历史记录中两字段恒 0；若未来 UI/诊断消费该字段会得到错误结论。属"死字段"。
- 建议：导出时填 `container.formatVersion/dataVersion`（`BackupExportResult` 未携带，可在结果中补或由 UI 传已知常量），导入时填 `plan.formatVersion/dataVersion`；否则删除字段与注释。

#### R-C08（P3）`planFileDomainWrites` 声明"纯函数"但会修改入参条目
- 证据：`entry/src/main/ets/common/transfer/DataTransferService.ets:1553-1592`，其中 `1576-1580` 直接 `record['key'] = rewritten`；同批 `DraftPortability.ets` 的函数明确"不修改入参"（17/44/107 行注释），两份纯函数的约定不一致。
- 影响：正常路径下计划阶段已把 key 归一化，此处改写是 no-op；但若 `uid` 在计划与应用之间变化（见 R-C09），会就地改写 `entry.mergedPayload` 中**包括本机条目**的所有 key。测试也没有断言该函数是否修改入参。
- 建议：若要保持"纯函数"承诺，改写前 `JSON.parse(JSON.stringify(record))` 复制；或在注释中如实写明"会就地改写草稿 key"。

#### R-C09（P3，待验证可达性）计划阶段与应用阶段使用不同 uid 快照，无一致性校验
- 证据：`DataTransferService.ets:592`（`currentUid = this.uidProvider()`，计划阶段）、`613-618`、`1476-1478`；应用阶段 `686-697`（镜像域 `ownerUid = this.uidProvider()`）、`742`（`planFileDomainWrites(..., this.uidProvider())`）。
- 影响：若导入计划弹窗打开期间登录态变化（后台 401/会话校验触发 `clearAuth`、或用户在另一入口登出/切号），应用会按**新账号**写：草稿 key 被改写到新账号片段、镜像域 ownerUid 写成新账号；计划里的"新增/更新"计数与实际落盘不一致；极端情况把 A 的镜像缓存标成 B 的（反向串号）。
- 待验证：确认计划弹窗打开期间 auth 状态是否可能异步变化（`AppStore.ets:799` `clearAuth` 的触发路径：后台请求 401、会话校验任务等）。验证方法：在计划弹窗打开时通过调试触发 `appStore.clearAuth()` 后再确认导入，检查 drafts 文件名与镜像域信封 ownerUid。
- 建议：`buildImportPlan` 把 `currentUid` 记录到 `ImportPlan`（或 `ImportPlanEntry`），`applyImport` 时校验一致性，不一致则拒绝并提示重新生成计划；草稿/镜像域写入使用计划阶段的 uid。

#### R-C10（P3，待验证竞态）`v2.meta` 读-改-写无串行化，历史与迁移断点可能互相覆盖
- 证据：`DataTransferService.ets:273-290`（`recordTransferHistory`：`load()` → 改 `transferHistory` → `save()`）；`PersistenceMetaStore.ets:54-95`（load 返回缓存引用；save 整体 `JSON.stringify` 覆盖）；并发写入方：`MigrationEngine.ets:346-347`、`361-362`、`392`（逐域断点 `saveReport`/`save`）、`AppStore.ets:1157-1162`（ack notice）、`1259-1263`（cleanup 回写）。
- 影响：`retryMigration` 与导出/导入完成交错时，`ensureMeta` 的 `load(true)`（`MigrationEngine.ets:599-610`，**强制重读并新建 meta 对象**）可能从磁盘读到不含新历史的快照，随后逐域保存把它写回，**丢失刚记录的导出/导入历史**；反向也可能回退一次迁移断点（迁移幂等，影响小）。窗口窄（同页可先点「重试升级」再导出），但属于静默丢失一条元数据。
- 待验证：注入延迟 `metaStore.save`，交错 `recordTransferHistory` 与 `engine.run` 的 meta 保存，断言最终 `transferHistory`/`migration.domains` 是否完整。
- 建议：meta 变更统一经 `PersistenceMetaStore` 的串行化入口（同一 Promise 链），或 `recordTransferHistory` 在 save 前比对 `cached` 引用/版本号重试。

#### R-C11（P3，待验证）`recordTransferHistory` 在 meta 缺失时写入 `new PersistenceMeta()`，会把 `dataVersion` 直接标成当前版本
- 证据：`DataTransferService.ets:277-281`；`PersistenceTypes.ets:457-459`（`dataVersion` 默认 `PERSISTENCE_DATA_VERSION`）。
- 影响：若 `v2.meta` 不存在/解析失败（`PersistenceMetaStore.load()` 返回 null），记一次历史会落一个"已是最新数据版本"的锚点，可能掩盖本应执行的迁移检测（`AppStore.ets:320-328` 的 createFresh 分支被绕过）。正常流程 init 已保证 meta 存在，实际可达性低。
- 待验证：删除/写坏 `v2.meta` 后触发一次导出记历史，检查读回的 `meta.dataVersion` 与 `migration.status`。
- 建议：meta 为 null 时不要落锚点（或从 `PersistenceHub.currentDataVersion()` 语义上显式写 `dataVersion: 0`）。

#### R-C12（P3）`repairDomain` 未在清盘前排空写队列（与 `applyImport` 的防护不一致）
- 证据：`AppStore.ets:1360-1366`（`removeDomain` → `flush`）；对照 `DataTransferService.ets:656-661`（`applyImport` 明确"排空在途写队列再写导入数据"）。写队列 `SerialQueue`（`entry/src/main/ets/common/infra/SerialQueue.ets:9-17`）在微任务中自动执行，`removeDomain` 内部 delete 与排队写入可能交错。
- 影响：理论上排队中的旧快照写入可能在删除之后执行，把刚清掉的域写回；repair 提示成功但数据仍在。窗口窄（删除本身有多次 await，排队任务多数会先执行完）。
- 建议：`await persistenceHub.flush()` 移到 `removeDomain` 之前。

#### R-C13（P3）健康卡片对不可清空域（auth/sessions/meta）也显示「修复」，且确认文案暗示可删除
- 证据：`DataManagementPanel.ets:1524-1556`（每个健康问题行都渲染修复按钮）、`549-580`（`confirmRepairDomain` 按 `spec.rebuildable` 选文案，未判断 `clearable`）；`AppStore.ets:1360-1363`（`!spec.clearable` → `return false`）；对照 `PersistenceCatalog.ets:63-72`（auth/sessions `clearable=false`）、`169-173`（meta `clearable=false`）。
- 影响：若 auth/sessions/meta 因 Hub 读写失败进入健康列表，用户看到「修复」但点击只得到「该数据域不可修复」；确认文案对不可清空域给出"删除全部本地数据并重建"的误导。目前健康数据主要来自治理路径、这些域较少出现，故 P3。
- 建议：健康卡片按 `spec.clearable` 隐藏/置灰修复按钮；`confirmRepairDomain` 先判断 `clearable`。

#### R-C14（P3）调度状态展开时不刷新，可能显示旧快照
- 证据：`DataManagementPanel.ets:330-336`（`refreshAll` 才调 `refreshScheduler`）、`376-408`、`1586-1615`（`schedulerExpanded` 只切换折叠，不触发刷新）。
- 影响：页面停留期间展开折叠区看到的是进入页面/版本 bump 时的状态，非实时。属可观测性小问题。
- 建议：展开时调用一次 `refreshScheduler()`。

#### R-C15（P3）导入计划「恢复缓存类数据」开关的异步重建无并发保护，快速切换可能显示/执行过期计划
- 证据：`DataManagementPanel.ets:1097-1116`（`rebuildImportPlan` 未 await 前一次、无请求序号）、`1952-1957`（Toggle onChange 直接调用）。
- 影响：快速来回切换时，先发起的 `buildImportPlan` 可能后完成并覆盖 `pendingPlan`，导致开关显示"开"而计划/执行仍按"关"（或反之）——不会丢数据，但"恢复缓存类数据"的实际行为与 UI 状态不符。
- 建议：递增请求序号，只有最新一次的结果写入 `applyPlanToDialog`。

#### R-C16（P3）文件域「部分条目非法/部分写失败」时整域按失败上报，已写入文件不计入结果
- 证据：`DataTransferService.ets:733-753`（`applyFileDomain` 返回 `written/failed`）、`684-712`（`failed > 0` → 抛错，`result.appliedDomains/added/updated` 不增加，失败域只有 ID）。
- 影响：行为与 `a4634d6d` 一致（非回归）：一个坏条目会让整个 drafts/saved_threads 域在结果里显示失败，但其它文件可能已写入；用户看到"失败域：drafts"难以判断实际导入量。属可观测性问题。
- 建议：结果里补"文件域 written/failed 明细"，或按写入数计入 `added` 并在 note 里说明部分成功。

#### R-C17（P3）升级器无规则提示的文案问题
- 证据：`entry/src/main/ets/common/transfer/DomainUpgraders.ets:56-59`：`fromVersion` 为 0 时 `fromLabel='未知'`，拼出"该数据域的格式版本较低（v未知）"；提示"请用新版应用重新导出后导入"在源设备已是新版时并不成立（问题在旧备份缺少规则）。
- 影响：文案略拗口/引导不精确，P3。
- 建议：版本未知单独分支（"该数据域的格式版本未知/较低"），提示改为"该备份来自旧版本应用，请用与本应用兼容的版本重新导出"。

#### R-C18（P3，既有）导入入口文案「冲突按较新合并」与 `REPLACE_BY_KEY`/整体覆盖域的实际语义不符
- 证据：`DataManagementPanel.ets:1695`（"从备份文件恢复，冲突按较新合并"）；`DomainMergers.ets:313-330`（drafts/saved_threads 同键**恒取导入值**，不比较时间）、`250-270`（theme 整体覆盖）、`179-241`（settings 标量导入优先）。该文案来自 `4e971cfe`，非本会话引入。
- 影响：用户可能以为旧备份不会覆盖本机较新的草稿/存档/设置。无数据丢失（有导入计划逐域展示），但文案与设计稿 §6.4（同键以导入文件为准）矛盾。
- 建议：改为「按域策略合并：历史/进度/投票/跟踪/AI 取较新，草稿/存档/主题以备份为准」这类准确描述。

---

## 3. 重点项 A–G 逐项核对

| 项 | 核对内容 | 结论 | 证据 |
| --- | --- | --- | --- |
| A | 草稿键归一化：字段顺序保持、幂等、非数组、未登录边界、计划/写入一致性、相同内容判无变化 | **有条件通过** | 见 A 明细 |
| B | `legacyRetained` 传播完整性、normalizeReport、countUnsettled 口径、canRetryMigration 回归 | **有条件通过** | 见 B 明细 |
| C | 历史写入时机、meta 并发/覆盖、上限、序列化保真、清空语义 | **通过（P3 遗留）** | 见 C 明细 |
| D | 升级器判定顺序、升级后 payload 流向、无规则提示 | **通过** | 见 D 明细 |
| E | 纯函数抽取与原内联逻辑逐分支等价 | **通过（1 处 P3 差异）** | 见 E 明细 |
| F | UI ForEach key、@State 依赖、六组兜底、Record 类型、弹窗异步、修复语义、进度回调 | **通过（P3 遗留）** | 见 F 明细 |
| G | 上一批回归点（flush/容错重载/无变化跳过/不写空盘/ENVELOPE/清空重置/updatedAt） | **有条件通过**（清空重置不完整，R-C01） | 见 G 明细 |

### A. 草稿键归一化（DES-19）
- 函数质量 ✓：`normalizeDraftKeysForAccount`（`DraftPortability.ets:109-151`）重建对象时按 `Object.keys(record)` 原序替换 `key`（140-146），字段顺序保持；已是当前账号时返回原引用不重建（132-135），天然幂等；非数组原样返回（111-114）；条目非对象/空 key 原样保留（120-130、127-130）。
- 位置顺序 ✓：`preEvaluateDomainImport` 中"未登录草稿跳过"（`DataTransferService.ets:1440-1445`）在归一化（1476-1478）之前；低版本升级（1459-1470）也在归一化之前，升级后的 payload 才被归一化，顺序合理。
- 计划/写入规则一致 ✓：两处都用 `draftUidPart(uid)` + `rewriteDraftKeyUidPart`（`DraftPortability.ets:115/131`；`DataTransferService.ets:1560/1576`），同 uid 时结果一致；uid 时点差异见 R-C09。
- 主目标 DES-19 ✓：计划阶段归一化后，同目标跨账号草稿由"新增"改判"更新"，`entry.mergedPayload` 与写入文件名一致（`DataTransferService.ets:621` → `686` → `742`）；测试 `treatsRenamedDraftAsUpdateNotAdd`（`DataTransferImportPlan.test.ets:542-579`）能捕获"去掉归一化"的回归（会变成 added=1）。
- "内容相同→无变化" ✗：真实导出形状下因 `makeDraftsPortable` 把 media 移到末尾而不成立，见 R-C05。
- 测试缺口：字段顺序保持与"归一化不修改入参"只有 `DataTransferImportPlan.test.ets:505-540` 覆盖了不修改入参/已当前账号；**未断言字段顺序**（可用 `Object.keys` 顺序断言）；未串联"计划 payload → `planFileDomainWrites`"验证两端一致（见 §4）。

### B. 迁移未完成口径（legacyRetained）
- 置位覆盖 ✓：可重试跳过 = `convertSettings` 多账号无匹配（`DomainMigrators.ets:320-326`）、`convertMirrorEnvelope` 无当前账号旧值（431-436）、`convertFavoriteMembership` 无当前账号缓存（492-499）、`MigrationEngine.runTask` 未登录镜像域（458-461）、转换器结果透传（481-485）。不可重试跳过（`无旧数据`/`旧数据不可解析`/`新键已存在`/`旧目录为空`/`文件均无效`/`convertDropped`）均未置位 ✓。
- 反序列化 ✓：`PersistenceMetaStore.ets:265`。
- 口径 ✓：`PersistenceTypes.ets:368-379` = FAILED + DEFERRED + (SKIPPED && legacyRetained)；`AppStore.ets:1196-1202` 直接委托；brief/设计稿一致。
- `canRetryMigration` ✓/风险：扩展为 `failedCount>0 || PARTIAL/FAILED || unsettled>0`（`DataManagementPanel.ets:446-448`）。回归风险：未登录且仅存在可重试 SKIPPED 时，按钮常驻且重试无可见变化（镜像域仍跳过），用户得不到"请先登录"的下一步指引（P3，可接受但建议在迁移明细/对话框加提示）。
- 清空语义 ✗：见 R-C01（P2）。
- 测试门禁 ✗：见 R-C03/R-C04（P2）。

### C. 导出/导入历史
- 写入时机 ✓：导出仅在 `writeTextToUri` 成功且 `readBack === result.content` 后记录（`DataManagementPanel.ets:885-916`）；保存失败/回读不一致时提前 return，不记成功（正确）。导入在 `applyImport` 返回（含部分失败）后记录（`1204-1223`），`ok = result.ok && reloadFailed.length===0`，`note` 为错误摘要 ✓。
- 上限/截断 ✓：`appendTransferHistory`（`PersistenceTypes.ets:439-452`，最新在前、≤10）+ `normalizeTransferHistory`（`PersistenceMetaStore.ets:184-220`，坏条目丢弃、未知 kind 丢弃、截断、note 截 120）。
- 序列化保真 ✓：`TransferHistoryEntry` 纯字段类，无方法依赖；`note` 只来自固定文案/错误摘要，不含业务内容 ✓；未发现敏感信息进入历史。
- 清空语义 ✓：`resetMigrationLegacyReport` 清 `transferHistory`（`AppStore.ets:1342`）。
- 竞态/遗留：R-C10（P3）、R-C07（字段未填）、R-C11（meta 缺失兜底）。
- 测试缺口：`recordTransferHistory` 无单测（依赖 hub），可接受；但 `appendTransferHistory` 已覆盖（`DataTransferImportPlan.test.ets:468-501`）。

### D. 升级器接入
- 顺序 ✓：`ImportPolicy.NEVER` → NEVER 导出+SKIP（媒体域）→ 镜像域登录态/来源账号 → 未登录草稿 → `restoreCacheDomains` 开关 → 高版本拒绝 → 低版本升级/无规则跳过 → 草稿归一化（`DataTransferService.ets:1401-1478`）。与设计稿 §6.4 流程图（`PERSISTENCE_UNIFICATION_DESIGN.md:807-817、849-852、890`）一致。
- payload 流向 ✓：`DomainPreCheckResult.payload` 初始化为 `incoming.payload`（1395），升级成功写入（1469），随后 `mergeDomainImportEntry(spec, incoming, pre.payload, local)`（621）→ `mergedPayload` 写盘（697）或文件域（686/742）；不存在"升级了但没用"的路径。高版本/无规则时生成 `skipEntry`，不会进入 merge/写盘 ✓。
- 无规则提示 ✓（`DomainUpgraders.ets:56-59`，文案小问题见 R-C17）；当前所有域 schema=1，生产不可达，与设计稿声明一致。
- 测试：仅覆盖"无规则拒绝"（`DataTransferImportPlan.test.ets:445-464`），"升级成功→流入 merge/写盘"无法在无规则时覆盖，属可接受（需在注册首个规则时同批补测，建议在 DomainUpgraders 头注释/§13.5 强调）。

### E. 纯函数抽取等价性（对照 `HEAD` 内联实现）
逐分支比对结论（旧 = `HEAD:a4634d6d:entry/src/main/ets/common/transfer/DataTransferService.ets`，新 = 工作区）：

| 分支 | 旧实现 | 新实现 | 等价性 |
| --- | --- | --- | --- |
| label 以 Catalog 为准 | 旧代码在 spec 命中后覆盖 `entry.label` | 同（`preEvaluateDomainImport` 1398-1400、`mergeDomainImportEntry` 1494-1496） | ✓ |
| `ImportPolicy.NEVER` | 跳过 + "该数据域不允许导入" | 同（1401-1406） | ✓ |
| 媒体域硬跳过 | 跳过 + "该数据域不参与导入（媒体/缓存副本不可移植）" | 同（1411-1416） | ✓ |
| 镜像域未登录 | 跳过 + "未登录：账号镜像缓存需按账号归属恢复，请登录后重新导入" | 同（1422-1428） | ✓ |
| 镜像域跨账号 | 跳过 + "该缓存来自其他登录账号的备份，已跳过（可由服务端重建）" | 同（1429-1434） | ✓ |
| 镜像域 ownerUid 空 | `entry.reason='来源账号未知（旧版备份），将按当前账号恢复'`（不跳过） | 同（`mergeDomainImportEntry` 1497-1499） | ✓（位置后移，语义一致） |
| 未登录草稿 | 跳过 + "未登录：草稿需要当前账号标识，请登录后重新导入" | 同（1440-1445） | ✓ |
| SKIP 域关闭恢复开关 | 跳过 + "缓存类数据，默认跳过（可开启「恢复缓存类数据」）" | 同（1446-1452） | ✓ |
| schemaVersion 高 | 跳过 + "数据格式版本高于当前应用，已跳过" | 同（1453-1458） | ✓ |
| schemaVersion 低 | **旧：不判断，直接合并/写盘** | 新：走升级器，无规则 → 新跳过文案（`DomainUpgraders.ets:58-59`） | **有意变更**（设计稿 §6.4/§6.5，非缺陷） |
| settings 本机密钥还原 | 合并前 `restoreLocalSecrets` | 同（`mergeDomainImportEntry` 1500-1502） | ✓ |
| 计数 | `total = added + updated`；SKIP 域 `added=countPayloadEntries(merged), updated=0` | 同（1504-1517） | ✓ |
| 合并异常 | 复用 `entry`（已设 label/policy），`willSkip=true` + "合并失败：…" | 新建 `failedEntry`，**缺 policy** | 差异见 R-C06（P3，功能等价） |
| 文件域写入 | hub 判空 → 非数组 0 条 → 逐条校验（saved_threads 用 tid、drafts 改写 key+rules、`isSafeDomainFileName`+`isValidFileDomainItem`）→ `writeFileAtomic(key.json, JSON.stringify(record))` | 同（`applyFileDomain` 733-753 → `planFileDomainWrites` 1553-1592） | ✓（含草稿 key 就地改写这一既有语义） |
| 文件域 hub 未就绪 | `failed++` | 同（735-738） | ✓ |

### F. UI 逻辑（DataManagementPanel）
- ForEach key ✓：迁移明细 `line + '#' + index`（1476）、健康行（1548）、历史（1573）、调度（1605）、存储行 `domainId|sizeBytes`（1651）、导出弹窗行 `kind|text|domainId`（1807）、导入计划行 `label#detail#index`（1979-1980）——均含内容（或至少含稳定 id+内容），不存在"内容变化但 key 不变 → 复用不刷新"的典型问题。
- @State 依赖 ✓：`transferHistoryLines`（341-371）、`schedulerLines/schedulerExpanded`（376-408、1586-1615）、`healthProblemLines/healthProblemDomains` 同步构建（471-498）、`exportDomainSizes`（759-773）、`exportProgressText`（862-867、1876-1880）均齐全；`refreshAll` 在 `onDataManagementVersionChange` 与导出/导入/修复/清空后调用。
- 六组分类 + 兜底 ✓：`EXPORT_GROUPS`（109-118）覆盖 16 个可导出域（2+4+1+2+2+5），`buildExportRows` 按 `exportable()` 过滤并对未登记域兜底「其它」（733-752）。
- ArkTS 类型 ✓：`this.exportDomainSizes[row.domainId] ?? ''`（1793）对 `Record<string,string>` 索引的 `string | undefined` 做了兜底；`FileDomainWritePlan` 等新类字段显式初始化，未见 ArkTS 子集违规（编译已由 Lead 验证）。
- 修复按钮 ✓/风险：二次确认 + `rebuildable` 文案（549-580），但丢弃 reload 失败（R-C02）、非 clearable 域入口（R-C13）。
- `exportBackup` 进度回调 ✓：回调只更新 `@State`，导出结束后 `finally` 清理（855-930）；用户中途关闭弹窗不会取消导出（弹窗 `autoCancel: true`，取消按钮未禁用），属既有行为，低风险。
- 弹窗异步刷新：计划重建竞态（R-C15）、调度状态不刷新（R-C14）。

### G. 上一批回归点
| 回归点 | 结论 | 证据 |
| --- | --- | --- |
| `applyImport` 前 flush | ✓ | `DataTransferService.ets:656-661` |
| `reloadAfterImport` 逐域容错 | ✓ | `AppStore.ets:1389-1457`，返回 failed 列表并被 UI 消费（`DataManagementPanel.ets:1193-1203`） |
| `applyImport` 无变化域跳过 | ✓ | `DataTransferService.ets:675-683` |
| TrackedThreadStore 读失败不写空盘 | ✓ | `TrackedThreadStore.ets:652-670`（失败分支只清内存 + warn，不 `persist()`） |
| ENVELOPE 域强制 `{items}` | ✓ | `DomainMergers.ets:146-151、281-303`（`forceWrapped`）；测试覆盖 |
| 清空后重置迁移报告/历史 | **部分** | `legacyKeys/legacyCleanupAt/transferHistory` 已重置（`AppStore.ets:1330-1348`），`domains/status` 未重置 → R-C01 |
| 导出 `updatedAt` 口径 | ✓ | `DataTransferService.ets:305-324、335`：镜像/其它 ENVELOPE 取信封、RAW 恒 0、文件域取 `latestMtimeMs`（`StorageBackends.ets:371-397`）；与设计稿 DES-08 一致 |

---

## 4. 测试有效性评价

> 判定标准：实现被改坏时用例是否**必然失败**；以及是否覆盖本会话新增契约的关键分支。

| 套件 | 用例数 | 有效性 | 主要问题 |
| --- | --- | --- | --- |
| `DataTransferImportPlan.test.ets` | 21 | **中** | 策略矩阵/计数/升级器拒绝/历史截断断言有效；但 DES-19 的"无变化"用例用非真实形状（R-C05），字段顺序保持未断言，计划→写入链路未串联，legacyRetained 置位未覆盖 |
| `DataTransferRoundTrip.test.ets` | 6 | **较强** | 16 域解析、mirror ownerUid、重复域、ENVELOPE 归一、幂等均能捕获回归；但 `exportBackup`/`omitted`/进度、`buildImportPlan`/`applyImport` 因依赖加密与 hub 未覆盖（限制已知）；幂等仅覆盖 4 个域 |
| `MigrationUnsettled.test.ets` | 3 | **弱于其声称** | `countUnsettled` 口径有效；但"legacyRetained 随 meta JSON 保真"用例**绕过 `PersistenceMetaStore.normalizeReport`**（R-C04），且未覆盖置位逻辑（R-C03） |
| `DataTransferDomainParity.test.ets` | 12 | **较强** | 21 域唯一/策略对等/ENVELOPE 集合/8MB 丢弃可见/重复与缺 payload/文件域条目校验均有效；8MB 用例较重（约 16MB 字符串）但确定性好；硬编码 21/16/域顺序属"意图性守卫"（新增域时测试失败提醒更新），可接受 |

### 具体缺口与建议新增断言（按价值排序）

1. **DES-19 端到端一致性（建议 P1 级补测）**：用真实导出形状（含 `makeDraftsPortable` 后的字段顺序）构造备份草稿，串联 `preEvaluateDomainImport` → `mergeDomainImportEntry` → `planFileDomainWrites`，断言：
   - 计划 `updated/added` 与 `writes` 的文件名/key 集合一致；
   - 同内容（含相同字段顺序）→ `added===0 && updated===0`；
   - 当前实现下"原生顺序 vs 导出顺序"会被判 updated（若 R-C05 不修，应把该行为写成显式用例并在注释说明，避免后续误判）。
2. **legacyRetained 置位**：在 `PersistenceMigrationUnit.test.ets` 三个 SKIPPED 用例补 `assertTrue()`，在不可重试 SKIPPED 补 `assertFalse()`（R-C03）。
3. **normalizeReport 持久化读**：新增 meta 读回用例（内存 `PreferencesStore` 替身），断言 `legacyRetained`/`transferHistory` 跨序列化保真（R-C04）。
4. **字段顺序保持**：`normalizesDraftKeysToCurrentAccount` 补 `Object.keys(items[0])` 顺序断言（键被改写但位置不变）。
5. **settings 幂等**：`mergePayload(SETTINGS, merged, merged)` → added/updated 均 0（当前只测了 history/votes/tracked/ai）。
6. **迁移报告 UI 口径**：为 `countUnsettled` 补"清空后应归零"的语义测试（依赖 AppStore，若不可测则在 R-C01 修复时以集成方式验证）。
7. **RoundTrip 增强**：对 `settings`（SPECIAL）与 `drafts`（REPLACE_BY_KEY）的"再次合并自身"幂等；对坏条目（非对象 payload 元素）确认 `skipped` 计数。

---

## 5. 已验证正确 / 负面结论（避免误报）

- **导出历史不会在保存失败时误记**：`runExport` 在 picker 取消/写入失败/回读不一致时提前 return（`DataManagementPanel.ets:879-899`），历史记录在 903-916 之后才发生。
- **导入历史记录不泄露业务内容**：只记 kind/at/domainCount/bytes/added/updated/skippedDomains/ok/note，note 为固定文案或错误摘要（`DataManagementPanel.ets:1210-1223`；`TransferHistoryEntry` 注释 `PersistenceTypes.ets:403-428`）。
- **`appendTransferHistory` 截断正确**：新记录在首、上限 10、null 可用、不修改入参（`PersistenceTypes.ets:439-452`；测试 468-501）。
- **`makeDraftsPortable` 不修改入参、非数组原样返回、坏条目保留**（`DraftPortability.ets:46-84`；测试 398-441）。
- **`normalizeDraftKeysForAccount` 不修改入参**（测试 505-540 断言）。
- **升级后 payload 确实被消费**；高版本/无规则 skipEntry 不进入 merge/写盘（见 D）。
- **`planFileDomainWrites` 与 Store 读取侧规则一致**：saved_threads `tid` 纯数字 1-16 位 + `rawPages` 非空；drafts `isValidDraftKey` + `isSafeDomainFileName`（`DataTransferService.ets:1088-1148、1582-1585`；测试 331-394、`DataTransferDomainParity.test.ets:248-288`）。
- **历史记录上限与坏 meta 容错**：`normalizeTransferHistory` 丢弃坏条目/未知 kind、截断（`PersistenceMetaStore.ets:184-220`）。
- **清空本地数据会清 `transferHistory`**（`AppStore.ets:1342`）。
- **`exportBackup` 进度 total/done 口径自洽**：`countExportCandidates` 只统计"已勾选且非 NEVER"（`DataTransferService.ets:1601-1613`），循环中 `done++` 与之一致（208-224）。
- **4MB 预警阈值/触发点正确**（`PersistenceTypes.ets:128`、`DataManagementPanel.ets:527-531`；判 `>`，等于阈值不报警，合理）。
- **行尾**：`node scripts/check-eol.mjs` → 全部已跟踪文本 LF；5 个新增文件字节级 CR=0（复核通过）。
- **未发现**：新文件/改动引入的循环依赖（`DraftPortability`/`DomainUpgraders` 只依赖 `DraftKeyUtils` 与 `DomainIds` 等零依赖模块）；`AppStore` 公开字段 `scheduler`（`AppStore.ets:158`）与 `AppScheduler.snapshot()`（`entry/src/main/ets/common/scheduler/AppScheduler.ets:249`）、`PersistenceHub.estimateAll`（`PersistenceHub.ets:409-416`）均存在且签名匹配。

---

## 6. 待验证项与验证方法（无法仅靠静态代码确认）

| 编号 | 待验证点 | 验证方法 |
| --- | --- | --- |
| V1（R-C09） | 计划弹窗打开期间登录态是否可能变化 | 代码确认 `clearAuth` 的异步触发源（后台 401/会话校验/用户其他入口）；或调试注入 `appStore.clearAuth()` 后确认导入，检查 drafts 文件名与镜像域信封 ownerUid |
| V2（R-C10） | `recordTransferHistory` 与迁移 meta 保存的竞态 | 注入延迟 `metaStore.save`，交错「重试升级」与导出完成；断言最终 `v2.meta.transferHistory` 与 `migration.domains` 完整 |
| V3（R-C11） | meta 缺失/损坏时记历史是否落错锚点 | 删除或写坏 `v2.meta` 后触发导出记历史，检查读回 meta 的 `dataVersion`/`migration.status` |
| V4（R-C12） | repair 与在途写队列的竞态 | 单测注入延迟写队列任务，在 repair 前 enqueue 一次旧快照写，断言清空后该域是否复活 |
| V5（R-C05） | 真实导出→回导的草稿判等 | 真机/模拟器：建含/不含 media 的原生草稿 → 导出 → 不清理直接回导，观察计划是否显示"无变化"（预期：显示"更新"，印证 R-C05） |
| V6（R-C02） | repair 后内存一致性 | 真机：构造某域读失败（写坏 v2.settings 等）→ 健康卡片出现 → 修复 → 观察页面数据是否真正清空、健康标记是否消失（当前实现失败步骤会静默） |

> 说明：V5/V6 依赖真机或模拟器，按评审约束未执行。

---

## 7. 评审范围与限制

- 覆盖：未提交源码/测试/文档（`git diff HEAD --stat` 全量）+ `a4634d6d` 中与需求相关的核心逻辑（DataTransferService/DomainMergers/TransferTypes/AppStore/TrackedThreadStore/DataManagementPanel/DraftStore/DraftKeyUtils/StorageBackends）+ 4 个测试套件 + 设计稿相关章节。
- 未覆盖：`FavoriteSavedPanel`/`SettingsPanel` 的导出写入器改造（`a4634d6d`，属其他评审任务范围）、`TransferCrypto` 加密链路（限制：Local Test 无 cryptoFramework，设计稿与 brief 已声明需真机）、UI 视觉/交互（使用 `harmonyos-test`/UI 自动化不在本次范围）。
- 未执行编译/测试/模拟器（按约束，Lead 已统一验证：BUILD SUCCESSFUL、736/736 通过、EOL 全绿）。本报告所有结论均来自静态代码证据；标「待验证」的条目已给出验证方法。
