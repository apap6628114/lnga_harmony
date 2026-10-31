# 数据导入链路审计报告（AUDIT_IMPORT）

> 审计对象：NGA OH（HarmonyOS ArkUI）「持久化数据统一治理 + 数据管理（导出/导入）」重构的**导入侧**。
> 审计基线：工作区 `C:\Users\ll\Desktop\nga_oh`，HEAD = `72869858`，工作区干净；重构提交 `4e971cfe`、`cfc7d95e` 均已在基线内。
> 审计方式：**只读静态审计**（read/grep/git show），未编译、未运行测试、未启动模拟器，未修改任何源码；本文件是唯一写入产物。
> 证据约定：所有结论给出 `文件:行号`；无法从代码确证的影响标注「待验证」并给出验证方法。行号以基线 commit 为准。

---

## 1. 概述

### 1.1 总体结论

1. **正常同版本「导出 → 导入」往返，21 个域都有确定的 apply/跳过路径，导入后内存重载集合覆盖全部可导入域**，未发现「导出了、导入了、Store 没重载」的常态路径缺陷。
2. Lead 初筛中「tracked_threads / ai_sessions 合并输出形态（裸数组或 `{items}`）写回信封后 Store 读回不兼容，可能是数据丢失级缺陷」——**对同版本备份证伪**：这两个域在备份中的 payload 恒为 `{items}`（经 `PersistenceHub.readPayload` 读信封 payload），合并器输出形态跟随导入文件（同为 `{items}`），`writePayload` 再套一层标准信封，`CacheEnvelopeStore` 按 `payload.items` 读取，往返一致（详见 §3 疑点 3）。
3. **发现一个 P0 级「静默丢弃」**：导入解析阶段对单个域载荷做 8M **字符**上限过滤，超限域被直接丢弃且**不进入导入计划、无任何提示**；而导出侧只限制整包 64MB 字节，**同一份合法导出文件可能出现「导出成功、导入时整域消失」**。saved_threads（离线存档，ExportPolicy.INCLUDE 默认勾选，Catalog 自估单条 128KB）是最可能触发的域（IMP-01）。
4. 另有 1 个 P1（文件域导入缺少写入器级条目校验，旧版离线存档兼容路径可能「导入成功但存档看不到」）与 13 个 P2（计划展示口径、跳过原因被吞、重建计划残留、重载异常中断、裸数组形态兼容、镜像域归属、未登录草稿键等）。
5. 镜像域「跟随导出选择」的语义（`SKIP` + `restoreCacheDomains`）在导入侧**已按设计实现**：默认恢复、可关闭、未登录显式跳过；但「关闭开关」与「计划不可执行」的交互存在 UI 死角（IMP-04/IMP-05）。

### 1.2 问题统计

| 级别 | 数量 | 编号 |
| --- | --- | --- |
| P0（数据丢失级，条件触发） | 1 | IMP-01 |
| P1 | 1 | IMP-02 |
| P2 | 13 | IMP-03 ~ IMP-15 |

> 说明：本报告未把「缓存域被覆盖恢复」视为缺陷（设计 §6.4 明确「跟随导出选择、备份里出现即按导入值覆盖」）。

---

## 2. 逐域生效表（PersistenceCatalog 全部 21 域）

列说明：
- **备份中是否可达**：指正常导出（用户在导出弹窗勾选后）能否让该域出现在 `.ngabackup` 中；
- **apply 路径**：`buildImportPlan` 的合并分支 + `applyImport` 的写入方式；
- **写入后 Store 是否重载**：`AppStore.reloadAfterImport()`（`store/AppStore.ets:1294-1319`）是否让该域**内存**重新反映磁盘；
- 所有证据均来自 `common/persistence/PersistenceCatalog.ets` 的域声明与对应实现文件。

| 域 ID | ImportPolicy | 备份中是否可达 | apply 路径 | 写入后 Store 是否重载 | 备注 |
| --- | --- | --- | --- | --- | --- |
| `auth` | NEVER | 否（ExportPolicy.NEVER） | 计划显式跳过：「该数据域不允许导入」 | —（不导入） | 凭证走独立 `.ngacred` 链路；`DataTransferService.ets:444-449` |
| `sessions` | NEVER | 否 | 同上 | — | 同上 |
| `settings` | SPECIAL | 是（INCLUDE） | `mergeSettings`（字段覆盖 + 数组按业务键并集）→ `hub.writePayload`（RAW） | 是：`settingsStore.init` → `loadUserSettings`（`AppStore.ets:1296`；`SettingsStore.ets:100-106,146-180`） | 另做了旧备份 AI Key 回填与端点校验（`DataTransferService.ets:1055-1141`） |
| `theme` | MERGE_FIELDS | 是（INCLUDE） | `mergeReplace` 整体覆盖 → RAW 写入 | 是：`settingsStore.initTheme` + `applyCurrentTheme`（`AppStore.ets:1298,1313`；`ThemeSettings.ets:58-65,96-137`） | 全局域，未登录也恢复 |
| `categories` | SKIP | 是（OPTIONAL，手动勾选） | 默认跳过；`restoreCacheDomains=true` 时走 `mergePayload` default→`passthrough`（整体覆盖）→ RAW 写入 | 是：`categoryStore.init`（`AppStore.ets:1299`） | 但 `loadCachedCategories` 不先清内存，本机独有的旧分类在内存中可残留到重启（`CategoryStore.ets:53-64`） |
| `profiles` | SKIP | 是（OPTIONAL） | 同上，RAW 写入（`Record<uid, ProfileData>`） | 是：`profileStore.init`（`AppStore.ets:1300`） | 同上：`loadCachedProfiles` 只 `cache.set` 不清空，本机独有条目在内存短暂保留（`ProfileStore.ets:51-67`） |
| `notifications` | SKIP | 是（OPTIONAL） | 默认跳过；恢复时 `passthrough` → 信封写入 `{items}`，ownerUid=当前 uid | 是：`loadMirrorData` → `notificationStore.init`（`AppStore.ets:1304,743-750`） | 未登录时计划跳过；读侧严格逐条校验（`NotificationStore.ets:316-349`） |
| `activities` | SKIP | 是（OPTIONAL） | 同上 | 是：`loadMirrorData` → `followActivityStore.init` | 同上 |
| `favorite_membership` | SKIP | 是（OPTIONAL） | 同上；payload 为 `{favoredFolderIds, knownFolderIds}`（非 `{items}`） | 是：`loadMirrorData` → `favoriteStore.init` | 形态与 Hub/Store 侧一致（`FavoriteStore.ets:92-121,953-982,987-1029`） |
| `history` | MERGE_BY_KEY | 是（INCLUDE） | `mergeArrayPayloadByTime` 按 tid 取 ts 较新、降序截断 500 → RAW 裸数组 | 是：`historyStore.reset()` + `preload`（`AppStore.ets:1308-1309`；`HistoryStore.ets:84-93,101-124`） | 已读台账同源重建 |
| `reading_progress` | MERGE_BY_KEY | 是（INCLUDE） | 按 tid 取 ts 较新、截断 200 → RAW 裸数组 | 是（懒加载）：`reset()` 后首次访问读盘（`AppStore.ets:1307`；`ReadingProgressStore.ets:51-77`） | — |
| `votes` | MERGE_BY_KEY | 是（INCLUDE） | `mergeVotes` 按 tid 取 ts 较新、截断 200 → RAW `Record` | 是（懒加载）：`reset()` 后首次访问读盘（`AppStore.ets:1306`；`VoteStore.ets:60-66,73-88`） | — |
| `poll_voted` | MERGE_BY_KEY | 是（INCLUDE） | `mergePollVoted` 取较大时间戳、截断 200 → RAW `Record` | 是（懒加载）：与 votes 共用 `VoteStore.reset()`（`VoteStore.ets:60-66,206-221`） | — |
| `tracked_threads` | MERGE_BY_KEY | 是（INCLUDE） | `mergeArrayPayloadByTime`（tid、lastCheckAt 回退 createdAt、截断 50）→ **输出 `{items}`** → 信封写入 | 是：`trackedThreadStore.init`（`AppStore.ets:1301`；`TrackedThreadStore.ets:140-148,647-658`） | 形态往返一致，见 §3 疑点 3；但读失败会「写空盘」，见 IMP-08 |
| `ai_sessions` | MERGE_BY_KEY | 是（OPTIONAL） | `mergeArrayPayloadByTime`（id、updatedAt 回退 createdAt、上限 20）→ **输出 `{items}`** → 信封写入 | 是：`aiSessionStore.init`（`AppStore.ets:1302`；`AiSessionStore.ets:60-72,216-248`） | 同上；`loadTolerant` 逐条跳过坏会话，不会整封判死 |
| `ai_tool_cache` | SKIP | 是（OPTIONAL） | 默认跳过；恢复时 `passthrough` → 信封写入 `{items}` | 是：`aiToolCacheStore.init`（`AppStore.ets:1303`；`AiToolCacheStore.ets:74-94,120-139`） | 恢复条目在 `hydrate` 时**按 TTL 过滤**，过期条目静默丢弃（`ToolResultCache.ets:489-500`），计划展示的条数可能大于实际可见条数（IMP-14） |
| `drafts` | REPLACE_BY_KEY | 是（INCLUDE，目录非空时） | `mergeArrayPayloadByKey`（key）→ `applyFileDomain`：草稿键 uid 段改写为当前账号后写 `<key>.json` | 是（懒加载）：`draftStore.reloadAfterClear()` 清内存，编辑器按需重读盘（`AppStore.ets:1312`；`DraftStore.ets:283-326,626-640`） | 文件名/键改写正确（§3 疑点 4）；媒体副本不随备份恢复（IMP-13） |
| `draft_media` | SKIP | 否（ExportPolicy.NEVER） | 若备份出现且恢复开关开：`passthrough` → `applyFileDomain`（条目录入预期失败） | 否（无重载入口） | 正常备份不会出现；构造包会触发整包部分失败（IMP-15） |
| `saved_threads` | REPLACE_BY_KEY | 是（INCLUDE，目录非空时） | `mergeArrayPayloadByKey`（tid）→ `applyFileDomain` 写 `<tid>.json` | 是：`savedThreadStore.reload()` 重扫目录（`AppStore.ets:1311`；`SavedThreadStore.ets:103-133`） | 文件名正确；**缺写入器级校验**：`rawPages`/纯数字 tid 不合法时写盘成功但 reload 静默跳过（IMP-02） |
| `moving_photo_cache` | SKIP | 否（ExportPolicy.NEVER） | 同 `draft_media` | 否 | 正常备份不会出现；构造包会触发部分失败（IMP-15） |
| `meta` | NEVER | 否（ExportPolicy.NEVER） | 计划显式跳过 | — | 内部版本锚点 |

**重载覆盖完整性核对（结论：集合完整）**：18 个「非 NEVER」域中，16 个出现在 `reloadAfterImport` 的直接/懒加载/文件域重扫名单，另 2 个（`draft_media`、`moving_photo_cache`）正常备份不可达、无对等重载入口（不可导出即不可导入）。**未发现「可导入但无任何重载路径」的域**——这一点与 Lead 初筛担忧相反，属「证实无缺陷」。

---

## 3. Lead 初筛疑点逐条核实（证实 / 证伪）

| # | 疑点 | 结论 | 关键证据 |
| --- | --- | --- | --- |
| 1 | `buildImportPlan` 中 `importPolicy===SKIP && !restoreCacheDomains` 的跳过逻辑；`restoreCacheDomains` 默认参数 true 但 UI 传入值是什么 | **符合设计（开关语义正确）**。默认参数 `true`；UI 传入 `this.restoreCacheDomains`，该 `@State` 初始值为 `true`，且计划弹窗内有开关可关；关闭后 SKIP 域进计划并显示跳过原因 | `DataTransferService.ets:412-413,461-471`；`DataManagementPanel.ets:169,660,681,1365-1377` |
| 2 | SKIP 域走 `mergePayload` default→passthrough 的整体覆盖，ENVELOPE 域（notifications/activities/favorite_membership/ai_tool_cache）payload 形态是否与 `writePayload` 期望一致 | **证伪（形态对称，无缺陷）**。导出时 `hub.readPayload` 对 ENVELOPE 域返回的是「信封内 payload」（`notifications/activities/ai_tool_cache` 为 `{items}`，`favorite_membership` 为 `{favoredFolderIds,knownFolderIds}`）；passthrough 原样返回；`hub.writePayload` 把该 payload 原样放进新信封；各 Store 的读取分别消费 `payload.items`（`CacheEnvelopeStore`）与 `payload.favoredFolderIds/knownFolderIds`（`FavoriteStore`），一致 | `PersistenceHub.ets:141-167,247-280`；`DataTransferService.ets:483,554-555`；`CacheEnvelopeStore.ets:92-116`；`FavoriteStore.ets:92-121` |
| 3 | tracked_threads/ai_sessions 合并输出（裸数组或 `{items}`）写回信封后 Store 读回是否兼容（疑似数据丢失级） | **正常备份证伪（`{items}` 往返一致）**：这两个域导出 payload 恒为 `{items}`，`mergeArrayPayloadByTime` 输出形态跟随导入文件（`wrapped`），仍为 `{items}`；`writePayload` 套标准信封后 `CacheEnvelopeStore.structuralItems` 读 `payload.items`，与 `TrackedThreadStore/AiSessionStore` 写盘形态相同。**但存在条件性兼容缺陷**：若导入 payload 是裸数组（构造/旧格式），输出也变裸数组，写回信封后 `CacheEnvelopeStore` 走不进新信封分支→判非法，`TrackedThreadStore` 随即「清空并写空盘」，属数据丢失路径（IMP-09，待验证） | `DomainMergers.ets:277-295,286,702-709`；`PersistenceHub.ets:258-267`；`CacheEnvelopeStore.ets:92-116,215-234`；`TrackedThreadStore.ets:647-658` |
| 4 | `applyFileDomain` 对 drafts 改写 key 后文件名是否正确、saved_threads 的 tid 文件名、本机残留文件 | **文件名/键改写正确；无目录级清理但符合合并语义**。drafts：`rewriteDraftKeyUidPart` 改写最后一段后写 `<rewrittenKey>.json`，与 `DraftStore.filePathOf` 期望一致，内容 `key` 也同步改写；saved_threads：写 `<tid>.json`，与 `SavedThreadStore.filePathOf` 一致。本机多余文件不删除（drafts/saved_threads 是「按业务键合并」，本机独有文件保留是设计语义，不是残留缺陷）。**但缺条目级校验**（IMP-02） | `DataTransferService.ets:603-625`；`DraftKeyUtils.ets:50-61`；`DraftStore.ets:268-270`；`SavedThreadStore.ets:96-98` |
| 5 | `reloadAfterImport` 覆盖的 Store 是否等于「所有可导入域」集合；逐个 Store 核对是否真重读磁盘 | **集合完整（证实无遗漏）**，且各入口确实重读磁盘：`settings/theme/categories/profiles/tracked/ai_sessions/ai_tool_cache` 走 `init`（读盘），镜像域走 `loadMirrorData`（读盘），`history` reset+preload（读盘），`votes/poll_voted/reading_progress` reset 后懒加载（读盘），`drafts` 清内存后按需读盘，`saved_threads` 重扫目录。**但**：单个 Store 重载抛异常会中断后续所有域且只记日志（IMP-07）；`categories/profiles` 重载前不清内存（陈旧内存项，见 §2 表备注） | `AppStore.ets:1294-1319,743-750`；各 Store init/reset/load 见 §2 表 |
| 6 | 导入计划 UI 是否展示全部条目（含 willSkip 原因）、policy 与 willSkip 展示是否矛盾 | **条目与跳过原因全展示；policy 未展示故无矛盾；但存在「展示与行为不一致」**：`added=0&&updated=0` 的域被标成灰色「无变化」（`line.willSkip=true`），实际 `applyImport` 仍会写入该域；SKIP 域的 `added` 是「备份内条目数」而非真实变更数；计划重建失败时弹窗沿用旧计划（IMP-03/IMP-04/IMP-05） | `DataManagementPanel.ets:702-721,1385-1399`；`DataTransferService.ets:489-497`；`TransferTypes.ets:129-138` |
| 7 | 未登录时镜像域跳过的提示、导入后立即使用时序（重载在 applyImport 之后吗） | **时序正确**：`applyPendingImport` 先 `await applyImport`，`appliedDomains>0` 时 `await reloadAfterImport`，再提示结果。**未登录提示存在但有死角**：跳过原因写入计划条目，但当备份中「只有被跳过域」时 `plan.ok=false`，UI 只弹「没有可导入的新数据」笼统文案，具体原因（含「未登录：请登录后重新导入」）永远看不到（IMP-04） | `DataManagementPanel.ets:742-773`；`DataTransferService.ets:455-460,505-508`；`DataManagementPanel.ets:661-664` |

补充核实（未在初筛清单但同属「域对等」范围）：
- **导出侧对账号镜像域的 ownerUid 过滤在导入侧没有对等校验**（导入一律标记当前账号，见 IMP-10）。
- **设计 §6.4 承诺的「逐域执行升级器（旧 formatVersion → 当前）」在导入实现中不存在**，只做「更高版本拒绝 / 更高域 schema 跳过」（见文末「附」）。

---

## 4. 问题清单

### IMP-01 [P0] 导入解析阶段对「单域载荷 > 8M 字符」的域静默丢弃：不进入导入计划、不提示

- **证据**
  - `common/transfer/DataTransferService.ets:786-795`：`normalizeContainer` 对每个域 `JSON.stringify(payload).length` 超过 `MAX_DOMAIN_PAYLOAD_CHARS`（8×1024×1024，见 `:71`）时直接 `continue`，无任何记录；
  - `common/transfer/DataTransferService.ets:767-803`：该循环内所有非法/超限域均 `continue`；`ParseOutcome.warning` 只在 checksum 不匹配（`:391`）与尾部截断修复（`:345`）两种场景赋值，**解析成功但丢域时 warning 为空**；
  - `common/transfer/DataTransferService.ets:431`：`buildImportPlan` 只遍历 `container.domains`，被丢弃的域**不会生成 `ImportPlanEntry`**，用户无感知；
  - 导出侧限制不一致：导出只校验**整包** `BACKUP_MAX_FILE_BYTES = 64MB`（`:185`、`PersistenceTypes.ets:123`），对单域没有 8MB 限制；而 Catalog 自估 `saved_threads` 单条 131072 字节（`PersistenceCatalog.ets:159-161`）——100 条左右存档即可超过 8M 字符；
  - 设计承诺反例：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:838`「单域载荷 > 8MB 字符**跳过并计入计划**」。
- **问题描述**：一份**合法导出**的备份（总大小 < 64MB）中的某个大域（最可能是 saved_threads——Catalog 自估单条 131072 字节；理论上任何文本量大的域都可能）在导入端被静默丢弃；导入计划看不到该域、没有任何警告，确认后仍提示「导入完成」。这正是用户红线中的「导出了、导入了、但（该域）界面看不到 / 静默丢弃」。
- **影响**：P0，条件触发。用户导出「离线存档」备份后换机/重装导入，存档域整域丢失且无任何提示；备份失去恢复价值。
- **修复建议**
  1. `normalizeContainer` 把被丢弃的域收集为 `droppedDomains: {id, reason}[]` 并回传（扩展 `ParseOutcome` 或容器字段）；
  2. `buildImportPlan` 为每个被丢弃域生成 `ImportPlanEntry{willSkip:true, reason:'载荷超过 8MB 已被跳过…'}`，计划弹窗可见；
  3. 解析成功但存在丢弃域时，UI 用 `showToast/warning` 明确提示「N 个域因体积过大未导入」；
  4. 更彻底：导出时对单域同样做 8MB 拦截或提示（导出前提示用户分开导出），避免产出「自身导入器不接收」的备份；或把导入单域上限提高到与整包一致（64MB），仅保留内存防护；
  5. 补单测：构造单域 > 8M 字符的容器，断言 `buildImportPlan` 含该域的跳过条目（当前完全无覆盖）。
- **验证方法**：真机/构造数据——在 saved_threads 目录放约 100+ 条存档（或直接构造 `JSON.stringify(payload).length > 8388608` 的容器字符串），导出（默认勾选 INCLUDE 域）→ 导入，观察计划弹窗是否缺 saved_threads 域、是否无警告。

### IMP-02 [P1] 文件域导入缺少「写入器级」条目校验/规范化：可写盘成功，但 Store 永不读取；旧版离线存档兼容路径尤其危险

- **证据**
  - `common/transfer/DataTransferService.ets:596-626`（`applyFileDomain`）：逐条只校验「是对象」、业务键 `saved_threads→tid` / 其他→key 为字符串、`isSafeDomainFileName`（仅拒绝 `/`、`\`、`..`、长度上限），随后直接 `writeFileAtomic(spec, key + '.json', ...)`；
  - `store/SavedThreadStore.ets:49-60,116-123`：`reload()` 要求 `isValidTid(parsed.tid)`（**纯数字**）且 `parsed.rawPages` 为非空数组，否则**静默跳过**该文件（仅 debug 日志）；
  - `common/managers/DraftStore.ets:85-99,283-286`：`loadDraft` 要求 `isValidDraftKey`（仅 `[0-9a-zA-Z_]`），而导入侧 `isSafeDomainFileName` 允许任意字符（除 `/ \ ..`）；
  - 旧版兼容路径：`DataTransferService.ets:909-942`（`tryConvertLegacySavedThreadExport`）把旧版 `SavedThreadExportFile.threads` **原样**作为 `saved_threads` 域 payload，未做任何条目级转换/校验；
  - 设计承诺：`docs/PERSISTENCE_UNIFICATION_DESIGN.md:834`「旧版离线存档导出文件…**条目级校验由合并器/写入器做**」——实现未做。
- **问题描述**：备份/旧版导出中的文件域条目若字段不符合 Store 的读取校验（旧版存档缺少 `rawPages`、tid 非纯数字、草稿键含非法字符），`applyFileDomain` 仍会写盘成功并计入 `written`，`applyImport` 报成功；随后 `reload()`/`loadDraft()` 静默跳过这些文件，形成「导入成功但看不到 / 数据在盘上却不可见」，且导入结果里没有任何失败统计。
- **影响**：P1（代码缺口确证；真实旧样本触发概率待验证）。直接违反「不允许静默丢弃」与设计 §6.5 的条目级校验承诺。
- **修复建议**
  1. `applyFileDomain` 按域复用 Store 的校验/规范化函数：saved_threads 用 `isValidTid` + `rawPages` 非空校验（与 `SavedThreadStore.reload` 同源），drafts 用 `isValidDraftKey`；无效条目计入 `failed`（或 `skipped` 并在结果中单列），不得计入 `written`；
  2. 旧版存档转换时对 `threads` 逐条校验；对 v1 结构（无 `rawPages`）给出明确「该旧格式存档无法恢复」的跳过原因，而不是写一个永远读不到的文件；
  3. `applyImport` 的 `ImportResult` 增加文件域 `written/failed` 明细与跳过原因，UI 结果页展示；
  4. 补单测：`mergePayload` 无 IO 但可把「条目校验」抽为可测纯函数；至少为 `isFilePayloadValid` 类逻辑加覆盖。
- **验证方法**：构造一个 `drafts` payload 条目 `{key:'bad key!',content:'x'}` 与一个 `saved_threads` 条目 `{tid:'abc'}` 的备份，导入后检查 `drafts/`、`saved_threads/` 目录是否出现文件、存档列表/草稿是否可见、导入结果是否提示失败。

### IMP-03 [P2] 计划展示口径：SKIP 域「新增条数」是备份内条目数而非真实变更；「无变化」域仍会被写入

- **证据**
  - `common/transfer/DataTransferService.ets:489-497`：SKIP 域恢复时 `entry.added = countPayloadEntries(merged.merged)`（`countPayloadEntries` 见 `:695-711`），与本地是否已有相同数据无关；
  - `common/transfer/TransferTypes.ets:129-138`：`changedDomainCount()` 以 `added>0||updated>0` 判定「可导入域」，因此缓存域即使内容完全一致也算「可导入」；
  - `pages/DataManagementPanel.ets:712-717`：`added===0&&updated===0` 时 `line.willSkip=true, detail='无变化'`（灰色「跳过」样式），但 `applyImport`（`DataTransferService.ets:531-568`）对 `willSkip=false` 的条目**仍会执行写入**（含合并后 payload 与文件域全量重写）。
- **问题描述**：计划文案与真实行为不一致：缓存域把「备份里有多少条」当成「新增多少条」展示（用户可能看到「新增 200 条」但本机本来就有同样 200 条）；被标成「无变化/跳过」的域实际会被覆盖写入（尤其文件域会重写全部本地文件并刷新 mtime，延长草稿保留期）。不影响数据正确性，但陈述不准确，会让用户误判导入规模。
- **影响**：P2（展示/预期管理）。
- **修复建议**：SKIP 域改为展示「覆盖恢复 N 条（备份内条目数）」而非「新增」；「无变化」域要么真正跳过写入（省 IO），要么文案改为「无变化，仍将覆盖写入」；`changedDomainCount` 对 SKIP 域单独计数并在摘要中区分「覆盖型」与「合并型」。
- **验证方法**：导出仅含 notifications 的备份，导入两次，观察两次计划文案是否都为「新增 N 条」。

### IMP-04 [P2] 仅含「被跳过域」的备份无法展示跳过原因，且缓存恢复开关无法在计划页重新打开

- **证据**
  - `common/transfer/DataTransferService.ets:505-508`：`plan.ok = plan.changedDomainCount() > 0`，否则 `plan.error='备份文件没有可导入的新数据'`；
  - `pages/DataManagementPanel.ets:661-664,682-685`：`!plan.ok` 直接 `showToast(plan.error)` 返回，**不打开计划弹窗**；
  - 跳过原因（未登录镜像域 `DataTransferService.ets:455-460`、缓存关闭 `:461-471`）只存在于 `plan.entries[].reason`，弹窗不打开就永远看不到；
  - 缓存恢复开关只存在于计划弹窗内（`DataManagementPanel.ets:1372-1377`）。
- **问题描述**：当备份中所有域都命中「跳过」时（例如：未登录导入只含镜像域的备份；或用户上次关闭了缓存恢复开关又导入只含缓存域的备份），用户只会看到「备份文件没有可导入的新数据」这一句误导性文案；他既看不到真正的跳过原因（如「未登录：账号镜像缓存需按账号归属恢复，请登录后重新导入」），也没有入口在计划页打开开关，只能反复重试。
- **影响**：P2（可用性/误导；在未登录导入场景下会让用户误以为备份损坏）。
- **修复建议**：`plan.ok=false` 但 `entries.length>0` 时仍打开计划弹窗（只读展示跳过原因 + 可调缓存开关），「确认导入」按钮禁用或隐藏；错误文案改为「备份中的 N 个域均被跳过，原因见列表」。
- **验证方法**：用只含 notifications 域的备份、在缓存恢复开关为关的状态下导入，观察是否只剩笼统 toast、无原因列表。

### IMP-05 [P2] `rebuildImportPlan` 重建失败时残留旧计划：开关状态与「确认导入」实际执行内容不一致

- **证据**
  - `pages/DataManagementPanel.ets:674-692`：`rebuildImportPlan` 在 `!plan.ok` 时 `showToast` 后**直接 return**，未清空/更新 `this.pendingPlan`、`this.importPlanLines`、`this.importPlanSummary`；
  - `pages/DataManagementPanel.ets:742-752`：`applyPendingImport` 使用旧的 `this.pendingPlan`；
  - 触发条件：备份只含 SKIP 域，计划页把「恢复缓存类数据」开关从开→关，重建计划变为全部跳过 → `plan.ok=false`。
- **问题描述**：用户关掉了缓存恢复开关，弹窗仍显示关闭前的计划行（如「新增 200 条」），此时点「确认导入」执行的仍是**旧计划**（包含用户刚关闭的缓存域），与开关展示意图相反；且 UI 无任何「计划已失效」提示。
- **影响**：P2（错误执行用户意图 + 状态不一致）。
- **修复建议**：重建失败时清空 `pendingPlan/importPlanLines/importPlanSummary` 并禁用确认按钮（或关闭弹窗并提示）；计划与开关状态强绑定，任何一次重建失败都不得保留可执行的旧计划。
- **验证方法**：导出仅含 notifications 的备份 → 打开导入计划 → 关闭「恢复缓存类数据」→ 观察弹窗文案是否仍为开启时内容、点确认是否仍恢复缓存。

### IMP-06 [P2] `restoreCacheDomains` 跨导入保留：一次关闭后，同页面后续导入不再默认恢复

- **证据**：`pages/DataManagementPanel.ets:169`（`@State restoreCacheDomains: boolean = true` 只在组件创建时初始化一次）；`buildPlanAndShow`（`:657-669`）不重置该字段；开关唯一可变点是计划弹窗 `:1372-1377`。
- **问题描述**：用户在第一次导入中关闭「恢复缓存类数据」→ 取消/完成导入后，在数据管理页（面板未销毁）发起第二次导入，计划仍按「关闭」构建，与设计「默认恢复（跟随导出选择）」及开关说明文案不符；用户可能因此静默丢失缓存域恢复。
- **影响**：P2（与设计默认值语义不符）。
- **修复建议**：每次 `buildPlanAndShow` 前重置 `restoreCacheDomains = true`（或按用户上次选择持久化并显式标注）；弹窗内开关文案说明当前状态来源。
- **验证方法**：同页面连续两次导入，第一次关闭开关，第二次观察开关初始状态。

### IMP-07 [P2] `reloadAfterImport` 单点异常中断全部重载，且失败仅写日志、UI 仍提示导入完成

- **证据**：`store/AppStore.ets:1294-1319`：整个重载序列包在一个 `try/catch` 中，任一 Store 的 `init/preload/reload` 抛异常即跳到 `catch`，**后续域不再重载**；`catch` 仅 `logger.warn`，不向上返回失败。
- **问题描述**：导入写盘已成功（`ImportResult.ok` 由 `applyImport` 决定），但若某个 Store 重载抛异常，其余域的内存快照仍是旧值；UI 照常提示「导入完成」。用户随后操作（例如改任一设置）可能把旧内存快照整体写回磁盘，覆盖刚导入的数据（该风险 `DataManagementPanel.ets:753-756` 的注释已意识到「部分失败也必须重载」，但重载本身失败没有兜底）。
- **影响**：P2（可观测性 + 条件性的「导入后界面不生效/回写覆盖」）。
- **修复建议**：① 逐域 `try/catch`，一个域失败不影响其余域；② 记录失败域并在 UI 提示「部分数据已导入但界面刷新失败，请重启应用或重试」；③ `reloadAfterImport` 返回成功/失败域列表，`applyPendingImport` 据此调整提示。
- **验证方法**：代码审查即可确认；若要动态验证，可临时在某个 Store 的 init 中注入异常（不修改源码前提下只能静态确认）。

### IMP-08 [P2] `TrackedThreadStore` 读失败即「清空并写空盘」，与通知/动态的「读失败不写空」策略不一致；导入路径上可能销毁刚写入的数据

- **证据**
  - `store/TrackedThreadStore.ets:647-658`：`loadCachedItems` 在 `cacheEnvelope.load()` 返回 `null`（信封/条目校验失败）时 `items=[]` 并立即 `persist()`（把空列表写回 `v2.tracked_threads`）；
  - 对照：`store/NotificationStore.ets:269-286` 与 `store/FollowActivityStore.ets:361-384` 明确「读失败只清内存、不写空盘」；
  - `common/infra/CacheEnvelopeStore.ets:215-234`：`load` 对任一坏条目整体返回 `null`（严格语义）；条目校验见 `common/utils/ThreadTrackPolicy.ets:272-295`（要求 16 个字段类型全部匹配）。
- **问题描述**：正常同版本备份不会触发；但导入是外部不可信输入，若导入的 `tracked_threads` 条目结构与当前校验规则不一致（跨版本/手工改包/未来新增字段但未 bump 域 schemaVersion），`reloadAfterImport` 会先成功写盘、随后 `init` 判非法 → `items=[]` + `persist()` 用空信封覆盖，**导入的跟踪列表与原有列表一起不可恢复地丢失**。这与「导入失败应可见、不应静默摧毁数据」的原则冲突。
- **影响**：P2（条件触发，但后果为数据丢失）。
- **修复建议**：改为与 Notification/Followers 一致——读失败只清内存、不写盘（等下一次用户真实写入再覆盖）；或改用 `loadTolerant`（如 AiSessionStore）逐条跳过坏条目；同时把「条目级校验失败」上报到域健康/导入结果。
- **验证方法**：构造 tracked_threads 备份，其中一条缺 `seenLastPostTs` 字段（利用 `mergePayload` 不校验条目结构），导入后观察跟踪列表是否整体变空、磁盘 `v2.tracked_threads` 是否被写成空 `{items:[]}`。

### IMP-09 [P2] 合并输出形态「跟随导入文件」对 ENVELOPE 域是单向兼容：裸数组输入会写出 Store 读不懂的载荷

- **证据**
  - `common/transfer/DomainMergers.ets:14-18`（文件头声明「数组类域对两种形态都容忍…输出形态优先跟随导入文件」）、`:277-295`（`mergeArrayPayloadByTime` 用 `incomingView.wrapped` 决定输出形态）、`:702-709`（`buildArrayPayload`）；
  - `common/persistence/PersistenceHub.ets:258-267`：`writePayload` 对 ENVELOPE 域把 payload **原样**放进 `envelope.payload`；
  - `common/infra/CacheEnvelopeStore.ets:92-116`：新信封要求 `payload` 是**非数组对象**且含 `items` 数组；若 `payload` 是裸数组则落入旧格式兼容分支（在信封顶层找 `items`），返回 `null`；
  - 后果：`TrackedThreadStore` 进一步写空盘（见 IMP-08）；`AiSessionStore` 内存为空，下一次保存时写回空信封。
- **问题描述**：设计声称「容忍裸数组与 `{items}` 两种形态」，但只有**读侧**（合并器）容忍；写侧不保证 Store 能读回。若导入的 tracked/ai 域 payload 为裸数组（手工构造、第三方工具生成、或未来某版本导出格式变化），合并器会输出裸数组并写入信封，Store 直接判非法。
- **影响**：P2（待验证：需要构造裸数组 payload 的备份才能触发；当前同版本导出不会产生）。
- **修复建议**：对 ENVELOPE 域强制输出形态（`tracked_threads/ai_sessions` 恒为 `{items}`，与 `CacheEnvelopeStore.persist` 一致），忽略导入文件的裸数组形态（读取时仍可兼容裸数组，但写出前包一层）；或 `writePayload` 对 ENVELOPE 域做一次形态归一。
- **验证方法**：把一份正常备份中的 `tracked_threads.payload` 手工改成裸数组后导入，观察跟踪列表是否变空、磁盘信封是否被写成空 `items`。

### IMP-10 [P2] 账号镜像域导入不携带/不校验来源归属：导入侧绕开导出侧的 ownerUid 防护（跨账号串号风险）

- **证据**
  - `common/transfer/TransferTypes.ets:17-28`：`BackupDomainEntry` 只有 `id/label/schemaVersion/updatedAt/payload`，**没有 ownerUid**；`DataTransferService.ets:236-242` 导出时未写入归属；
  - `common/transfer/DataTransferService.ets:218-226`：导出侧对镜像域校验 `ownerUid===当前 uid`，不符则跳过（防跨账号数据外带）；
  - `common/transfer/DataTransferService.ets:554-555`：导入侧对镜像域**一律**以当前 uid 写入信封 `ownerUid`；
  - 读取侧：`CacheEnvelopeStore.ets:125-141` 仅比较 `ownerUid` 与当前 uid，因此导入后数据会被当成当前账号的合法缓存。
- **问题描述**：导出侧刻意防止「A 账号的镜像缓存被带出」，但导入侧无法判断备份里的镜像数据属于谁：在已登录 B 时导入 A 账号导出的备份，A 的通知（含私信通知标题）/关注动态/收藏关系会被标记为 B 的缓存，并在下一次服务端刷新前展示给 B——短暂串号/隐私暴露；设计 §6.4 只写「镜像域写入时标记为当前账号 ownerUid」，未讨论该风险。
- **影响**：P2（需要「用 A 的备份在 B 账号下导入」的操作；同设备马甲场景可发生）。
- **修复建议**：① `BackupDomainEntry` 增加 `ownerUid` 元数据（导出时写入），导入计划对「来源账号 ≠ 当前账号」的镜像域给出明确提示（默认跳过或需确认）；② 或导入后立即触发一次镜像域强制刷新，缩短串号窗口；③ 计划页明示「镜像缓存将作为当前账号缓存恢复」。
- **验证方法**：账号 A 导出（勾选通知/动态）→ 切到账号 B → 导入该备份 → 观察消息/动态页在刷新前是否显示 A 的数据。

### IMP-11 [P2] 未登录导入时草稿键被改写为 `anon`，登录后编辑器按当前 uid 哈希查找 → 草稿不可见

- **证据**
  - `common/transfer/DataTransferService.ets:604-616`：草稿键末尾 uid 段改写为 `draftUidPart(this.uidProvider())`；`DraftKeyUtils.ets:34-36`：uid 为空时返回 `'anon'`；
  - 编辑器侧键生成：`common/managers/ReplyManager.ets:1093-1105`、`common/managers/NewTopicManager.ets:538-544` 均用 `draftUidPart(appStore.auth.uid)`（登录后为 uid 短哈希）；
  - 当前可达性：`pages/Index.ets:69-71` 在未认证时强制跳转 `LoginPage`，数据管理页仅从 `SettingsPanel`（`SettingsPanel.ets:711-727`）进入，因此「未登录导入」在正常 UI 流程中**基本不可达**；但 `AuthStore.ets:202` 的 `isAuthenticated = token !== ''` 说明「token 在、uid 空」在异常持久化数据下并非不可能。
- **问题描述**：防御性分支自身引入了「恢复不回来」的后果：未登录导入草稿 → 键尾变 `anon` → 之后登录，编辑器查 `<hash(uid)>` 键 → 草稿文件仍在盘上但界面看不到（与 IMP-02 的「静默不可见」同类）。
- **影响**：P2（当前 UI 门禁下低概率；属防御分支的正确性问题）。
- **修复建议**：未登录时不要导入 `drafts`（计划中跳过并说明「请登录后导入草稿」），与镜像域的处理一致；或登录成功后按当前 uid 对 `_anon` 结尾的草稿键做一次迁移。
- **验证方法**：构造「token 非空、uid 空」的启动状态（或临时从代码路径调用导入）→ 导入含草稿备份 → 登录后检查草稿可见性。

### IMP-12 [P2] 导入计划不展示 policy；「计划摘要/可导入域」与实际写入语义存在口径差

- **证据**：`common/transfer/TransferTypes.ets:87-106` 的 `ImportPlanEntry.policy` 在 `pages/DataManagementPanel.ets:702-721,1361-1428` 中从未展示；摘要 `buildPlanSummary`（`:695-699`）只显示 `changedDomainCount`。
- **问题描述**：用户无法区分「合并（保留本机独有）」还是「整体覆盖（缓存域连本机独有内容一起覆盖）」；对缓存域「恢复即整体覆盖」的语义无任何提示，容易被理解为「合并恢复」。不构成数据错误（设计如此），但影响用户预期。
- **影响**：P2（预期管理）。
- **修复建议**：计划行增加策略标签（合并/覆盖恢复/文件覆盖），缓存域注明「将整体覆盖本机同类缓存」。
- **验证方法**：静态确认 `policy` 无消费方即可。

### IMP-13 [P2] 草稿导入计划未提示「媒体副本不随备份恢复」，导入后草稿媒体引用失效

- **证据**
  - 导出侧仅提示：`pages/DataManagementPanel.ets:1312`（导出弹窗文案「草稿中的图片/视频副本不包含在备份内…」）；
  - 导入计划弹窗 `pages/DataManagementPanel.ets:1361-1428` 无对应提示；
  - 草稿 JSON 原样携带 `media[].localPath`（沙箱绝对路径，`DraftStore.ets:129-160`），`applyFileDomain` 不清理/不改写媒体字段（`DataTransferService.ets:596-626`）；`draft_media` 域永不导出（`PersistenceCatalog.ets:153-157`）。
- **问题描述**：导入到新设备后草稿正文可见，但图片/视频副本路径指向导出设备的沙箱路径（不存在）；编辑器打开/发送时媒体不可用，用户容易误判「草稿损坏/导入不完整」。设计 §6.4 要求「UI 明示」，导出侧已明示、导入侧未明示。
- **影响**：P2（功能预期/可用性）。
- **修复建议**：导入计划中若有 drafts 域，追加说明「草稿中的图片/视频不会恢复，打开草稿后需重新选择」；或在 `applyFileDomain` 导入草稿时清空 `media` 数组并记录提示（清空会丢引用但避免坏路径，需产品定夺）。
- **验证方法**：带媒体草稿导出 → 新环境导入 → 打开编辑器观察媒体状态。

### IMP-14 [P2] `ai_tool_cache` 恢复条目按 TTL 静默丢弃，计划展示条数可能远大于实际恢复条数

- **证据**：`store/AiToolCacheStore.ets:120-139`（`loadTolerant` → `normalizeSnapshot` → `aiToolResultCache.hydrate`）；`service/ai/tools/ToolResultCache.ets:489-500`（`hydrate` 对 `expiresAt <= now` 的条目直接跳过）；`DataTransferService.ets:489-497`（计划按备份条目数展示）。
- **问题描述**：缓存类域默认不勾选，但用户显式勾选后导入，若备份较旧，绝大多数条目已过期，`hydrate` 静默丢弃；计划页却显示「新增 N 条」，导入结果 toast 也按 `entry.added` 累计，导致「显示恢复了 N 条，实际 0 条」。属 TTL 语义的预期行为，但展示口径不准。
- **影响**：P2（展示/预期）。
- **修复建议**：计划/结果对缓存域不承诺条数，或按 `expiresAt` 过滤后展示「可恢复 N 条（M 条已过期）」。
- **验证方法**：导出含 ai_tool_cache 的备份，等待 TTL 过期后导入，对比计划条数与工具缓存实际命中数。

### IMP-15 [P2] 若备份中出现「正常导出不可能出现」的文件域（draft_media/moving_photo_cache），导入会整包部分失败且只报首个错误

- **证据**
  - `PersistenceCatalog.ets:153-157,163-167`：`draft_media`/`moving_photo_cache` 的 ExportPolicy=NEVER、ImportPolicy=SKIP；
  - `DataTransferService.ets:461-471`：`restoreCacheDomains=true` 时 SKIP 检查被绕过，这两域会进入合并/应用；
  - `DataTransferService.ets:591-601,603-625`：payload 若为数组，条目没有 `key` 字段 → `failed++`；`:543-548`：只要 `failed>0` 即抛错（该域失败）；
  - `DataTransferService.ets:563-568`：`result.error` 只保留**首个**失败信息，其余域失败只写日志；
  - 同时 `applyFileDomain` 不做「该域是否允许导入」的校验（NEVER 只针对凭证在计划阶段拦截）。
- **问题描述**：构造/篡改的备份可以在计划里显示 draft_media「可导入」，应用阶段整域文件写入失败；若同时导入其他域，结果是「部分成功 + 一条错误文案」，用户无法知道哪些域/文件失败。正常导出不会产生该场景，但导入是外部不可信输入，应有明确的域级白名单。
- **影响**：P2（健壮性/可观测性；也浪费一次导入计划展示）。
- **修复建议**：`buildImportPlan` 增加「ImportPolicy.SKIP 且 ExportPolicy.NEVER」的硬跳过（明确原因「该域不参与导入」）；`ImportResult` 增加失败域列表并在 UI 展示；文件域部分失败时保留已写文件的同时明确告知（undo 已下线，见设计 §6.4 注）。
- **验证方法**：构造包含 `draft_media` 域的备份，导入观察计划展示、失败文案与失败域可见性。

### 附：设计承诺但导入侧未实现（建议由设计一致性审计合并处理）

- **旧版本升级器缺失**：设计 §6.4（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:779-782`）要求「逐域执行升级器（旧 formatVersion → 当前；旧域 schemaVersion → 当前）」；实现只做「更新版本拒绝」（`DataTransferService.ets:419-426`）与「域 schemaVersion 更高则跳过」（`:472-477`），`DataTransferService` 未引用 `DomainMigrators`/`MigrationEngine`（imports 见 `:16-45`）。当前无历史备份格式，实际影响为 0；一旦格式演进，旧备份将不经过任何转换直接按当前形态写入/合并。
- **导入记录未落盘**：设计 §6.4 流程含「写导入记录」，实现无对应持久化（`applyImport` 仅写日志 `:573-574`）。属功能缺失而非数据缺陷。

---

## 5. 单测覆盖缺口（entry/src/test）

现状：`DataTransferUnit.test.ets` 仅覆盖 `DomainMergers.mergePayload`（16 个用例，见 `:259-527`）；`DataTransferParseUnit.test.ets` 仅覆盖 `parseBackup` 的 5 个解析用例（`:30-73`）。**导入链路的核心 IO/编排（buildImportPlan / applyImport / applyFileDomain / reloadAfterImport）完全没有测试**，这直接导致本报告多数 P2 与 P0 无法被现有门禁发现。

建议补充（按优先级）：

1. **解析→计划对等性（覆盖 IMP-01/IMP-02/IMP-15）**：构造含「超大单域（>8M 字符）」「缺 payload 的域」「未知域」「NEVER 域」「draft_media 域」的容器，断言 `buildImportPlan` 的每条域都有 `willSkip/reason` 或合并结果——即「备份中每个域都必须出现在计划里」的域对等断言（可用 `PersistenceCatalog.ids()` 做声明式核对）。
2. **SKIP 域 passthrough 形态往返（覆盖 §3 疑点 2）**：对 notifications/activities/favorite_membership/ai_tool_cache，模拟 `hub.readPayload` 的 payload 形态 → `mergePayload` → 断言输出与 `CacheEnvelopeStore`/`FavoriteStore` 读取协议一致；对 tracked_threads/ai_sessions 额外断言「裸数组输入仍应输出 `{items}`」（修复 IMP-09 后）。
3. **文件域（覆盖 IMP-02）**：`mergeArrayPayloadByKey` 之上的条目校验纯函数化后测试非法 tid/非法草稿键/缺 rawPages 的处置；drafts uid 段改写已有 `DraftKeyUtils` 纯函数测试，但缺少「改写后文件名 = `<key>.json` 且内容 key 同步」的断言。
4. **重载覆盖集合（覆盖 §3 疑点 5 / IMP-07）**：声明式测试「`PersistenceCatalog` 中 ImportPolicy ≠ NEVER 的每个域，必须命中 `reloadAfterImport` 的直接/懒加载/文件域重扫名单之一」；并测试单域重载异常不阻断其他域（修复后）。
5. **计划 UI 纯逻辑（覆盖 IMP-03/IMP-04/IMP-05）**：把 `buildPlanLines/buildPlanSummary` 抽为可测纯函数（当前内嵌在 UI 组件中不可测），断言：SKIP 域计数文案、全跳过时计划仍可展示原因、重建失败时旧计划被清空。

---

## 6. 待验证清单（代码无法确证的影响）

| 项 | 验证方法 |
| --- | --- |
| IMP-01 实际触发概率（saved_threads 是否现实会超 8M 字符） | 用真实大存档导出 `.ngabackup`，统计 `domains[].payload` 字符数；或直接构造超限容器验证计划是否缺域 |
| IMP-02 旧版离线存档真实样本 | 找旧版本 App（`SavedThreadExportFile`，无 magic）导出的真实文件，看 `threads[]` 是否含 `rawPages`/纯数字 `tid`，导入后检查存档列表 |
| IMP-08/IMP-09 数据丢失路径 | 构造 tracked_threads 坏条目/裸数组 payload 的备份，导入后检查跟踪列表与 `v2.tracked_threads` 磁盘内容 |
| IMP-11 未登录导入可达性 | 确认数据管理页仅在 MainPage/SettingsPanel 内可达（`Index.ets:69-71` 登录门禁）；确认无「token 非空、uid 空」的现实持久化状态 |
| IMP-10 跨账号镜像串号 | 双账号真机：A 导出（勾选通知/动态）→ B 导入 → 刷新前观察消息/动态页内容归属 |
| IMP-13 导入草稿媒体 | 带图草稿导出→新环境导入→打开编辑器，观察媒体报错/发送行为 |
| `restoreCacheDomains` 跨导入保留（IMP-06） | 真机同页面连续两次导入，第一次关闭开关后观察第二次初始值 |

---

## 7. 审计取证文件清单

- 设计稿：`docs/PERSISTENCE_UNIFICATION_DESIGN.md`（§6.4 `:774-828`、§6.5 `:830-838`、§6.6 `:840-866`、§13.3 `:1296-1438`、§13.5 `:1440-1453`）
- 导入服务：`common/transfer/DataTransferService.ets`、`DomainMergers.ets`、`TransferTypes.ets`
- 持久化层：`common/persistence/PersistenceCatalog.ets`、`PersistenceTypes.ets`、`PersistenceHub.ets`、`StorageBackends.ets`、`MigrationEngine.ets`（文件域迁移校验）
- 重载入口：`store/AppStore.ets`（`reloadAfterImport:1294-1319`、`loadMirrorData:743-750`）、`common/managers/DraftStore.ets`、`store/*.ets`（各域 Store）
- UI：`pages/DataManagementPanel.ets`
- 单测：`entry/src/test/DataTransferUnit.test.ets`、`DataTransferParseUnit.test.ets`
- 其他：`common/infra/CacheEnvelopeStore.ets`、`common/utils/DraftKeyUtils.ets`、`common/utils/ThreadTrackPolicy.ets`、`model/SavedThread.ets`、`service/ai/tools/ToolResultCache.ets`
