# 需求覆盖 / 文档 / 测试一致性独立评审（REVIEW_REQUIREMENTS）

- **评审对象**：NGA OH（HarmonyOS ArkUI）「持久化统一治理 + 数据管理导出/导入」本会话三批需求
  （A 审计修复 / B 四项+产品决策+文档收口 / C 数据正确性两项）。
- **评审基线**：工作区 `C:\Users\ll\Desktop\nga_oh`，已提交 HEAD `a4634d6d`（第一批，18 文件 +2563/−233），
  工作区另有未提交修改（`git diff HEAD --stat`：9 文件 +1161/−216，新增 `DomainUpgraders.ets` /
  `DraftPortability.ets` / 3 个测试文件）。评审基线说明见 `.dsh/review/REVIEW_BRIEF.md`。
- **评审方式**：只读评审。使用 `read` / `grep` / `git show` / `git diff` 与读取 Lead 留下的验证产物
  （`entry/.test/default/intermediates/test/coverage_data/test_result.txt`、HAP 文件元数据）；
  仅执行了只读脚本 `node scripts/check-eol.mjs`。**未运行编译、Hypium、模拟器，未修改任何源码/文档/测试**，
  本文件是唯一写入产物。
- **验证状态口径**：以 brief 第 2.3 节为准（`assembleHap` BUILD SUCCESSFUL、Hypium 736 用例全绿、行尾 LF）。
  本次未复跑这些验证，只做产物一致性与代码/文档/测试三方比对。
- **交叉引用**：行为等价性（纯函数抽取前后逐分支比对）与对抗性/安全边界分别由 `REVIEW_CODE.md`、
  `REVIEW_ADVERSARIAL.md` 负责；本报告不重复论证，只标注依赖关系。

---

## 1. 总体结论：**有条件放行**

| 维度 | 结论 |
| --- | --- |
| 需求落实 | 三批需求核心实现均已落地；**需求 B-3（IO 编排层单测）与 B-6（设计稿 §13.5 收口并标注优先级）为部分落实**；需求 A 的「导出有、导入不用的多余数据」仍有 3 个残留容器字段（仅文档标注、未消除） |
| 设计稿一致性 | 主体一致；发现 **1 处文档失真**（§6.6#2 声称隐私提示"不随勾选联动"，代码已实现动态警示）、**1 处文档遗漏**（§13.5 缺 3 个已声明遗留项与优先级列）、**2 处过时**（§11/§8.2 "44 个 Hypium 测试"、§12 R2/R5）、**1 处清单遗漏**（§11/§13.2 漏新套件）、历史记录内部口径 1 处待标注 |
| 测试覆盖 | 新增 4 个套件（DomainParity 12 / ImportPlan 21 / RoundTrip 6 / MigrationUnsettled 3）断言有效、无随机/时间/JSON 顺序导致的偶发失败风险；**导出编排、导入编排（applyImport/reloadAfterImport）、历史 meta 持久层、legacyRetained 置位、真实 IO 往返仍无测试** |
| 审计闭环 | P0 2 项、P1 7 项均有代码闭环；高价值 P2 中 **4 项未闭环且设计稿 §13.5 未记录**（EXP-05 未登录置灰、IMP-12 策略标签、IMP-14 TTL 条数、DES-19 TOCTOU），构成"审计报告有、设计稿漏"的隐形待办 |
| 阻断项 | **无 P0**；P1 2 项（R-D01 测试契约部分落空；R-D02 文件域写盘截断风险，同模式缺陷已在真机导出链路复现过，本处待真机验证） |

**放行条件（建议）**：
1. 修正设计稿：§13.5 补 3 个隐形待办 + 增加优先级列；§6.6#2 按实现改写；§11/§13.2 测试清单补
   `MigrationUnsettled.test.ets`；§11/§8.2 的"44 个测试文件"改为当前实数（49 个测试套件文件）；§12 R2/R5 与实现对齐。
2. 补两类回归断言：需求 C-2 的 `legacyRetained` 四处置位；导出侧 `omitted` / 8MB 拦截（可通过注入哈希函数
   或拆分纯容器组装实现，见 R-D01）。
3. 真机验证文件域治理写盘完整性（R-D02）；若确认截断，升级为阻断。

---

## 2. 需求覆盖矩阵

> 判定口径：**已落实** = 代码实现 + 有测试或明确的只读校验证据；**部分** = 实现存在但契约/测试/文档缺一块；
> **文档不符** = 文档与代码不一致。证据行号以当前工作区文件为准。

### 2.1 需求 A：审计修复（commit `a4634d6d`）

| # | 需求项（审计编号） | 实现证据 | 测试证据 | 设计稿 | 判定 |
| --- | --- | --- | --- | --- | --- |
| A1 | 域对等性：21 域、可导出域导入侧全部有对等路径（任务总目标） | `PersistenceCatalog.ets:60-197`（21 域）；`DomainMergers.ets:126-168`（分派）；`DataTransferService.ets:563-636`（计划逐域） | `DataTransferDomainParity.test.ets:114-352`（12 例，含策略对等/域集合/未知域） | §2.3:259-296、§6.4:803-858 | 已落实 |
| A2 | EXP-02/IMP-01（P0）单域 8MB 上限双向可见 | 导出：`DataTransferService.ets:104-107, 356-367, 226-232`（超限→omitted）；UI `DataManagementPanel.ets:922-958`；导入：`DataTransferService.ets:537-540, 570-579, 915-927` | `DataTransferDomainParity.test.ets:172-206`（超限进 droppedDomains）、`:327-350`（超限进计划跳过条目） | §4.4:522、§6.5:887-888、§6.6:908 | 已落实（**导出侧无单测**，见 R-D01） |
| A3 | EXP-01（P1）勾选域静默省略 → 未包含清单 | `DataTransferService.ets:206-232`（omitted 收集）；`DataManagementPanel.ets:938-958`（弹窗清单） | 无 | §6.3:792-793 | 已落实（测试缺） |
| A4 | EXP-03（P1）迁移未完成 → 导出/清空警示 | `AppStore.ets:1184-1202`（`migrationUnsettledCount`）；`DataManagementPanel.ets:644-652`（导出副标题）、`:1243-1252`（清空副标题） | `MigrationUnsettled.test.ets:20-58`（统计口径）；置位路径无测试 | §5.6:691-693、§6.3:794-797、§6.7:942-943 | 已落实（置位测试缺，见 R-D05） |
| A5 | DES-04（P1）镜像域跨账号串号 | `TransferTypes.ets:57-62`（域条目 ownerUid）；`DataTransferService.ets:311-319`（导出归属校验）、`:373-374`（写入来源归属）、`:1422-1435`（导入跨账号跳过） | `DataTransferImportPlan.test.ets:128-159`；`DataTransferRoundTrip.test.ets:299-328` | §6.4:833、§6.6:917-918、§13.4:1643 | 已落实 |
| A6 | IMP-09（P2）ENVELOPE 域裸数组归一 `{items}` | `DomainMergers.ets:146-151`（forceWrapped）、`:281-295`、`:710-716` | `DataTransferDomainParity.test.ets:208-233`；`DataTransferRoundTrip.test.ets:389-426`；`DataTransferImportPlan.test.ets:270-290` | §6.4:828-829 | 已落实 |
| A7 | IMP-02（P1）文件域导入条目校验（写盘前与 Store 读取同规则） | `DataTransferService.ets:1110-1129`（`isValidFileDomainItem`）、`:733-753`（失败上报）、`:1553-1592`（写入计划） | `DataTransferDomainParity.test.ets:248-288`；`DataTransferImportPlan.test.ets:357-394` | §6.4:830、§6.5:883 | 已落实 |
| A8 | IMP-08（P2）TrackedThreadStore 读失败不写空盘 | `TrackedThreadStore.ets:648-673`（读失败只清内存，明确注释不得 persist） | **无回归测试** | §0.1.1:66-69、§13.3:1543 | 已落实（测试缺） |
| A9 | EXP-04（P2）`dataTransferService.init` 移出迁移 try | `AppStore.ets:331-346`（catch 之后无条件 init + 清 undo 残留）、`:1221-1236`（重试升级成功后再 init） | 无（AppStore 层） | §8.1:1129、§13.3:1538 | 已落实（测试缺） |
| A10 | IMP-07（P2）`reloadAfterImport` 逐域容错 | `AppStore.ets:1389-1457`（步骤表 + `reloadImportStep` 逐域 catch，返回失败步骤）；UI `DataManagementPanel.ets:1193-1208`（部分刷新失败提示重启） | 无 | §13.3:1542 | 已落实（测试缺） |
| A11 | EXP-08（P2）离线存档/凭证导出复用加固写入器 | `FavoriteSavedPanel.ets:825`、`SettingsPanel.ets:356` 均走 `writeTextToUri` | 无（真实 IO） | §13.3:1576-1579 | 已落实 |
| A12 | DES-09（P2）清空后重置迁移报告 | `AppStore.ets:1277-1348`（`clearAllLocalData` → `resetMigrationLegacyReport` 清 `legacyKeys/legacyCleanupAt`） | 无 | §5.5:682、§6.7:943 | 已落实 |
| A13 | DES-05/06/07/08/10/11/12/14/15/16/18（文档类 P2） | 见 §4 文档差异表；设计稿对应章节已按审计改写 | — | §2.3、§4.1、§4.4/4.5、§6.1/6.5/6.6/6.7/9.3、§13.2 | 已落实 |

### 2.2 需求 B：四项实现 + 2 个产品决策 + 文档收口

| # | 需求项 | 实现证据 | 测试证据 | 设计稿 | 判定 |
| --- | --- | --- | --- | --- | --- |
| B1a | 导出/导入历史（`v2.meta.transferHistory`，只记元数据、上限 10、清空一并清） | `PersistenceTypes.ets:382-452`（类型/`appendTransferHistory`/上限）、`:478-482`（meta 字段）；`PersistenceMetaStore.ets:174, 184-220`（反序列化容错）；`DataTransferService.ets:273-290`（写入）；`DataManagementPanel.ets:341-371`（刷新）、`:1560-1582`（卡片）、`:903-916`（导出后写）、`:1210-1223`（导入后写）；`AppStore.ets:1342`（清空重置） | 仅 `appendTransferHistory` 纯函数：`DataTransferImportPlan.test.ets:468-501`；持久层/写入时机/清空重置均无测试 | §0.2:93-95、§6.4:853-854、§6.6#11:921-923、§6.7:933、§9.2:1227-1228 | 已落实（测试缺，R-D08） |
| B1b | 4MB 单域预警（页面红字 + warn 日志） | `PersistenceTypes.ets:127-128`（常量）；`DataManagementPanel.ets:501-542`（`refreshStorage` 置 `oversized` + warn）、`:1635-1651`（红字与提示文案） | 无（UI） | §4.4:512、§4.5:530-531、§6.7:931-932、§13.5:1618 | 已落实（无自动化测试，属声明口径） |
| B2 | 导入域升级器 | `DomainUpgraders.ets:23-61`（`upgradeDomainPayload` + 无规则默认拒绝语义）；`DataTransferService.ets:1453-1470`（计划层接入）；`TransferTypes` 无版本演进 | `DataTransferImportPlan.test.ets:445-464`（无注册规则→ok=false 且原因含"升级规则"） | §5.2:585、§6.4:849-852、§6.5:890、§13.5:1620 | 已落实（入口 + 显式拒绝；当前无实际升级规则，文档如实标注） |
| B3 | IO 编排层单测 + 导出→导入往返一致性测试 | 纯函数抽取：`DataTransferService.ets:1368-1592`（`preEvaluateDomainImport`/`mergeDomainImportEntry`/`planFileDomainWrites`）；往返测试 | `DataTransferImportPlan.test.ets`（21 例）、`DataTransferRoundTrip.test.ets`（6 例，手工构造容器→parse→merge）；**`exportBackup`/`applyImport`/`reloadAfterImport`/`recordTransferHistory` 零测试** | §11:1277-1279 | **部分**（R-D01） |
| B4 | 数据管理页：健康修复 + 调度折叠区 + 域级进度/六组分类/每域体积 | 健康修复：`DataManagementPanel.ets:549-595` + `AppStore.ets:1360-1373`（清盘→重载→清健康标记）；调度：`DataManagementPanel.ets:376-408, 1586-1615`；进度：`DataTransferService.ets:179-232` + UI `:862-867`；六组：`:109-118, 698-754`（含"其它"兜底）；体积：`:501-542, 759-773, 1793` | 无（UI 层） | §6.3:781-786、§6.7:925-944、§9.2:1213-1236、§13.5:1615-1617 | 已落实（无 UI 自动化，属声明范围） |
| B5 | 产品决策：镜像域跨账号"默认跳过并提示"；草稿媒体"导出清空引用" | 镜像：`DataTransferService.ets:1422-1435`（来源账号不符→跳过+原因）、`:1497-1499`（来源账号未知→提示但恢复）；草稿：`DraftPortability.ets:46-84` + `DataTransferService.ets:343-355`（导出接线） | 镜像：`DataTransferImportPlan.test.ets:128-159`；草稿：`DataTransferImportPlan.test.ets:398-441` | §6.4:830/833、§6.3:798-799、§6.6:917-918 | 已落实 |
| B6 | 文档收口：审计未进设计稿的待修项补进 §13.5 并**标注优先级** | 设计稿 §13.5 已重写并如实标注"已实现/未实现"（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:1609-1630`） | — | §13.5 | **部分**（R-D03：无优先级列 + 3 个声明遗留项未入表；§13.5 状态本身未虚标，见 §8） |

### 2.3 需求 C：数据正确性两项

| # | 需求项 | 实现证据 | 测试证据 | 设计稿 | 判定 |
| --- | --- | --- | --- | --- | --- |
| C1 | DES-19：`drafts` 导入计划计数口径（计划阶段按当前账号键归一化、写入阶段复用改写） | `DraftPortability.ets:109-151`（`normalizeDraftKeysForAccount`，保持字段顺序、不可变入参）；`DataTransferService.ets:1471-1478`（计划阶段调用，在升级/未登录跳过之后）、`:1570-1580`（写入阶段 `rewriteDraftKeyUidPart` 幂等） | `DataTransferImportPlan.test.ets:505-540`（归一化/不可变/非数组）、`:542-579`（同目标草稿计 updated 而非 added；内容一致→无变化） | §6.4:830、§13.3:1591-1597 | 已落实 |
| C2 | 迁移未完成警示覆盖可重试 `SKIPPED`（区分"无需迁移的 skipped"与"旧键保留待重试的 skipped"） | `PersistenceTypes.ets:294-304`（`legacyRetained` 语义）、`:360-379`（`countUnsettled`）；`DomainMigrators.ets:152, 324, 434, 498`（3 处置位）；`MigrationEngine.ets:458-460`（未登录镜像）、`:481-484`（转换器透传）；`AppStore.ets:1196-1202`；UI `DataManagementPanel.ets:644-652, 1246-1250` | `MigrationUnsettled.test.ets:20-58`（仅 `countUnsettled` 与 JSON 保真）；**4 处置位无断言**（`PersistenceMigrationUnit.test.ets:345-396` 三条可重试跳过用例仍只断言 `skippedReason`） | §5.6:691-693、§6.3:794-797、§13.3:1598-1601 | 已落实（置位测试缺，R-D05） |

---

## 3. 三份审计报告闭环核对

### 3.1 P0 / P1（必须闭环）

| 编号 | 级别 | 问题 | 代码闭环 | 测试 | §13.5 记录 | 判定 |
| --- | --- | --- | --- | --- | --- | --- |
| EXP-02 | P0 | 导出不校验导入侧 8MB 上限，可生成不可导回备份 | ✅ 导出 `:356-367/226-232`，导入 `:915-927/570-579` | ✅ 导入侧 2 例；导出侧 ❌ | 无（属已修项） | **已闭环**（导出侧测试缺） |
| IMP-01 | P0 | 导入对超限域静默丢弃 | ✅ `droppedDomains` + 计划条目 `:537-540/570-579` | ✅ `DataTransferDomainParity.test.ets:172-206, 327-350` | 无 | **已闭环** |
| EXP-01 | P1 | 勾选域静默省略、无跳过清单 | ✅ `omitted` + UI 清单 | ❌ | 无 | **已闭环**（测试缺） |
| EXP-03 | P1 | 迁移未完成时导出缺域且无提示 | ✅ `migrationUnsettledCount` + 双弹窗警示 | 部分（统计口径 3 例；置位无） | 无 | **已闭环** |
| IMP-02 | P1 | 文件域导入写盘成功但 Store 静默跳过 | ✅ `isValidFileDomainItem` + `planFileDomainWrites` + 失败上报 | ✅ 2 套 4 例 | 无 | **已闭环** |
| DES-01 | P1 | 导入"逐域升级器"设计承诺但代码不存在 | ✅ `DomainUpgraders` 入口 + 低版本显式跳过 | ✅ 无规则路径（`ImportPlan:445-464`）；升级成功路径当前无规则不可测 | 无（§13.5:1620 记录"入口已实现、无规则"） | **已闭环**（按审计建议方案 2 落地） |
| DES-02 | P1 | 迁移异常/未完成时导出导入不可用或备份缺域、清空删旧数据 | ✅ init 移出 try、undo 清理不跳过、双警示 | 部分（统计口径；初始化/UI 无测试） | 无 | **已闭环** |
| DES-03 | P1 | SKIP 两套语义（Enum 注释/§2.3/Catalog） | ✅ 枚举注释 `PersistenceTypes.ets:53-55`、Catalog 值不变、`DomainMergers.ets:160-166` 注释、§2.3"跳过（可恢复）" | 声明式策略对等 1 例 | 无 | **已闭环** |
| DES-04 | P1 | 镜像域跨账号导入串号 | ✅ 容器域条目 `ownerUid` + 跨账号跳过 | ✅ 2 例 | 无（§13.5:1626 "镜像域跨账号导入 已实现"） | **已闭环** |

### 3.2 高价值 P2

| 编号 | 问题 | 闭环状态 | 证据/测试 | §13.5 记录 |
| --- | --- | --- | --- | --- |
| EXP-04 | dataTransfer 初始化在迁移 try 内 | ✅ 已闭环 | `AppStore.ets:331-346, 1221-1236` | 无 |
| EXP-05 | 镜像域 ownerUid fail-open + 未登录静默跳过（建议未登录置灰） | **部分**：跳过原因经 omitted 可见、导入侧对称；**未登录置灰未实现**；`ownerUid==''` 仍 fail-open 导出 | `DataTransferService.ets:311-319`（仅非空且不等才跳过） | ❌ **未记录**（brief §5 已声明未实现） |
| EXP-06 | `updatedAt/deviceTag/appVersionCode` 导出但导入不消费 | **部分（文档口径）**：ENVELOPE/文件域 `updatedAt` 已真实，RAW 恒 0 已如实文档化；3 字段仍不被导入消费 | §6.1:740-749 标注"仅诊断"；导出 `:205, 305-335, 368-376` | 无 |
| EXP-07 | 草稿媒体绝对路径随备份导出 | ✅ 已闭环 | `DraftPortability.ets:46-84`；测试 `ImportPlan:398-441` | 无（§13.5:1624 设计如此） |
| EXP-08 | 其它导出入口未复用加固写入器 | ✅ 已闭环（两处入口） | `FavoriteSavedPanel.ets:825`、`SettingsPanel.ets:356` | 无（§13.3:1576-1579 记录） |
| IMP-03/04/05/06/07/08/09/10/11/13/15 | 计划口径、全跳过展示、计划重建、开关复位、重载容错、读失败写空盘、ENVELOPE、跨账号、未登录草稿、草稿媒体提示、伪造文件域 | ✅ 全部代码闭环（IMP-07/08 无测试） | 见 §2.1/§2.2 | 无 |
| IMP-12 | 导入计划不展示逐域策略 | **未闭环**（计划行只有"覆盖恢复/新增/更新"文案，无策略标签） | `DataManagementPanel.ets:1131-1157` | ❌ **未记录**（brief §5 已声明未实现） |
| IMP-14 | `ai_tool_cache` TTL 过滤导致计划条数 > 实际恢复条数 | **未闭环** | `DataTransferService.ets:1509-1517`（按备份条目数展示） | ❌ **未记录**（brief §5 已声明未实现） |
| DES-05/06/07/08/09/10/11/12/14/15/16/18 | 文档/语义类 | ✅ 已按审计修正（见 §4） | 设计稿对应章节 | 已在 §13.3 记录 |
| DES-13 | 计划展示 vs §6.4 契约、修复/撤销/保留存档 | **大部分闭环**：修复按钮已实现、撤销口径已统一、保留存档文档已对齐实现；**逐域策略标签仍未实现**（同 IMP-12） | `DataManagementPanel.ets:1131-1157` | 无（修复/调度已标已实现） |
| DES-17 | 交叉引用与附录结构错误 | **部分**：引用错位与 §13.5/§13.4 顺序已处理（§13.5 前置加注）；**§11/§13.2 文件清单仍漏 `MigrationUnsettled.test.ets`** | 设计稿 §11:1270-1280、§13.2:1348-1356 | 无 |
| DES-19 | (a) 草稿键计划口径 ✅；(b) 计划→执行 TOCTOU 无并发保护 | **部分**：(a) 已闭环；(b) 仍未处理 | `DataTransferService.ets:563-636`（计划）→ `:646-720`（应用，直接用旧 mergedPayload） | ❌ **未记录** |

### 3.3 审计"隐形待办"汇总（审计报告有、设计稿 §13.5 漏）

| 来源 | 待办 | 现状 |
| --- | --- | --- |
| EXP-05 | 未登录时导出弹窗镜像域置灰（brief §5 声明未实现） | 未实现、§13.5 未记录 |
| IMP-12/DES-13 | 导入计划逐域策略标签（brief §5 声明未实现） | 未实现、§13.5 未记录 |
| IMP-14 | `ai_tool_cache` TTL 后可恢复条数（brief §5 声明未实现） | 未实现、§13.5 未记录 |
| DES-19(b) | 导入计划生成到执行之间的 TOCTOU（审计 P2，未修） | 未处理、§13.5 未记录 |
| EXP-05 | 导出侧 `ownerUid==''` fail-open（审计 P2，未修） | 未处理、文档未说明 |
| §13.5 要求 | "补进 §13.5 并标注优先级" | §13.5 表格为"项/状态"两列，**无优先级列** |

---

## 4. 设计稿 ↔ 代码差异表（按任务指定章节）

> 判定：**一致** / **文档未更新**（实现已变、文档仍旧）/ **文档失真**（文档描述与实现相反）/ **文档遗漏**。

| 章节 | 设计稿断言（行号） | 实现实际（文件:行号） | 判定 |
| --- | --- | --- | --- |
| §0.2 | 导出/导入历史、体积统计、迁移报告集中在数据管理页（93-95） | `PersistenceMeta.transferHistory` + `DataManagementPanel` 历史卡片/体积统计 | 一致 |
| §2.1 | 枚举示例注释：`MERGE_FIELDS = 字段级合并（theme 等）`（215）；`/** 导入策略。 */（实际枚举有 6 个值）`（213） | 源码注释已改为"字段级合并/覆盖（theme 这类单字段域整体覆盖…）"（`PersistenceTypes.ets:50-58`）；theme 实际整体覆盖（`DomainMergers.ets:138-139, 244-264`） | **文档未更新**（P3） |
| §2.3 | 21 域、DEVICE 16、SKIP"跳过（可恢复）"、draft_media/moving_photo_cache schema=1、21=16+3+2（264-296） | `PersistenceCatalog.ets:60-197` 逐域一致 | 一致 |
| §4.1 | RAW 域清单含 `meta`、ENVELOPE 6 域（447-455） | Catalog `rawPayload` 分配（`PersistenceCatalog.ets:185-195`）与清单一致 | 一致 |
| §4.4 | 4MB 单域告警 = 页面红字 + 日志 warn（512）；8MB 双向上限（522） | `DataManagementPanel.ets:523-531`；`DataTransferService.ets:104, 356-367, 915-927` | 一致 |
| §4.5 | 健康区块 +「修复」按钮（清盘→重载→清健康标记、二次确认）（530-531） | `DataManagementPanel.ets:549-595`；`AppStore.ets:1360-1373` | 一致（异常路径见 R-D15） |
| §5.2 | P3 导入触发路径：升级器入口已落地、无规则低版本跳过（585） | `DomainUpgraders.ets:45-60`；`DataTransferService.ets:1459-1470` | 一致 |
| §5.6 | `countUnsettled = FAILED + DEFERRED + SKIPPED&&legacyRetained`（691-693） | `PersistenceTypes.ets:360-379`；4 处置位见 §2.3 C2 | 一致 |
| §6.1 | `domains` 顺序稳定、整文件不保证字节一致；`updatedAt` 口径；`deviceTag/appVersionCode` 仅诊断；`ownerUid` 镜像域来源（740-749） | `DataTransferService.ets:198-240, 305-376` | 一致 |
| §6.1 | checksum 缺失时"跳过校验并提示"（743-744） | `DataTransferService.ets:534-536`（warning） | 一致 |
| §6.3 | 六组分类、每域体积、域级进度、8MB 未包含清单、迁移警示、草稿媒体清空、导出历史（779-801） | `DataManagementPanel.ets:109-118, 759-773, 862-867`；`DataTransferService.ets:206-232, 343-355`；`AppStore.ets:1196-1202` | 一致 |
| §6.4 | 导入流程含升级器/计划 UI 行为/草稿键归一化/缓存域覆盖/导入历史（803-858） | `DataTransferService.ets:563-636, 1392-1592`；`DataManagementPanel.ets:1065-1231` | 一致 |
| §6.4 | "备份含 drafts 时提示草稿媒体需重选"（847） | `DataManagementPanel.ets:1988-1991` 为**恒定提示**（不区分备份是否含 drafts） | **文档未更新**（实现更保守，P3） |
| §6.5 | 超大文件读取后按 UTF-8 字节校验、单域超限进计划、dataVersion=0 接受、低版本域升级器（887-890） | `DataTransferService.ets:437-440, 915-927, 570-579, 874-877, 1453-1470` | 一致 |
| §6.6#2 | 导出隐私提示"实现为恒定提示、**不随勾选联动**"（895-897） | 实现除恒定提示外，勾选 AI 会话/浏览历史**且未加密**时额外动态警示（`DataManagementPanel.ets:1882-1890`，审计 EXP-09 部分落实） | **文档失真**（P2，R-D04） |
| §6.6#11 | 导出/导入各写一条日志（域数、体积、是否加密、耗时）（921-923） | 导出日志含 bytes/encrypted/costMs（`:254-255`）；**导入日志无体积/耗时/加密标志**（`:717-718`） | **文档未更新**（P3，R-D13） |
| §6.6#9 | 镜像域导出前校验 ownerUid、导入跨账号跳过（917-918） | `DataTransferService.ets:311-319, 1422-1435` | 一致（fail-open 未写，见 §3.3） |
| §6.7 | 数据版本/健康修复/存储 4MB/历史卡片/调度折叠/导出进度/导入计划/清空媒体文案/清空重置历史（925-944） | `DataManagementPanel.ets:1451-1748, 1752-2063`；`AppStore.ets:1277-1348` | 一致 |
| §7.6 | 调度状态 UI 已实现（`AppScheduler.snapshot()`）（1111-1112） | `DataManagementPanel.ets:376-408, 1586-1615` | 一致 |
| §8.2 | "既有 44 个 Hypium 测试全绿"（1172） | 当前 `entry/src/test` 有 **49 个测试套件文件**（另有注册入口 `List.test.ets`）、源码 `it()` 共 752 处 | **文档未更新**（P3，R-D06） |
| §9.2 | 8 区块含修复/历史/调度/六组/进度（1213-1236） | 面板结构 `DataManagementPanel.ets:1403-1447` 逐区块存在 | 一致 |
| §10 | P4/P6 状态含升级器/数据管理页完善（1248-1257） | 与实现一致 | 一致 |
| §11 | "现有 44 个 Hypium 测试文件必须全绿"（1268）；新增测试清单（1270-1280） | 49 个测试套件文件；清单**漏 `MigrationUnsettled.test.ets`**（已注册 `List.test.ets:48, 102`） | **文档未更新 + 遗漏**（P2，R-D06） |
| §12 | R2"分两步放开（先保守版）"（1287）；R5 回滚"`SchedulerTask.enabled` 常量"（1290） | §8.2:1170-1173 明确"未采用两步走"；`common/scheduler` 无 `SchedulerTask`/`enabled` 符号（grep 0 命中） | **文档未更新**（P3，R-D09） |
| §13.2 | 新增/修改文件清单（1323-1381） | 清单漏 `MigrationUnsettled.test.ets`（本轮新增）；其余（DomainUpgraders/DraftPortability/ImportPlan/RoundTrip）已列 | **文档遗漏**（P2，R-D06） |
| §13.3 | 三批实施记录 + 验证数字（1383-1607） | 与 brief 一致（736 用例 / HAP 10.81MB / LF）；但产物明细见 R-D12；批次 1 记录仍写"升级器未实现、4MB 未实现"未标注已被后续记录取代 | 主体一致（P3，R-D10） |
| §13.5 | 遗留清单状态（1609-1630） | 逐项抽查均与代码一致（**无虚标**，见 §8）；但缺 3 个声明遗留项与优先级列 | **文档遗漏**（P2，R-D03） |
| §13.4 | 兼容策略含跨账号导入跳过（1632-1643） | 与实现一致 | 一致 |

---

## 5. 问题清单

> 编号 R-Dnn；级别 P0/P1/P2/P3。每条含证据、影响、修复建议。P0：无。

### R-D01（P1）需求 B-3「IO 编排层单测」契约部分落空：导出/导入编排零测试，且 `exportBackup` 在 Local Test 不可调用

- **证据**：
  - 现有新增测试只覆盖纯函数与"手工构造容器 → parse → merge"：
    `DataTransferImportPlan.test.ets:96-581`（21 例）、`DataTransferRoundTrip.test.ets:252-469`（6 例）；
  - 测试文件明确禁止调用导出编排：`DataTransferRoundTrip.test.ets:31-33`、`DataTransferDomainParity.test.ets:33-36`
    （"禁止在测试里调用 `exportBackup` / `encryptBackup`"）；
  - 根本原因：`exportBackup` **无条件**计算 SHA-256（`DataTransferService.ets:239`），Local Test 无
    cryptoFramework（brief 2.3 已声明），因此无法构造仅内存 Hub 的导出编排测试；
  - `applyImport` / `reloadAfterImport` / `recordTransferHistory` 同样无测试（grep `entry/src/test` 无引用）。
- **影响**：本轮修复的导出侧 P0/P1 契约（8MB 超限→`omitted`、NEVER 二次拦截、草稿媒体清空接线、
  镜像域 ownerUid 写入、进度回调、64MB 拒绝、历史写入时机）**没有回归门禁**；改坏这些路径测试仍全绿。
  需求 B-3 原文为"IO 编排层单测 + 导出→导入往返一致性测试"，当前只交付了后者（且为手工构造容器，
  不经过导出实现，无法发现"导出产物形状漂移"）。
- **修复建议**（任一）：
  1. 把 checksum 计算抽成可注入函数（默认 crypto 实现，测试注入 `''`/桩），使 `exportBackup` 可配
     `MemoryPreferencesStore` 在 Local Test 跑；
  2. 或把"容器组装"从 `exportBackup` 中抽出为纯函数（`buildContainer(domains, options)`，不含 hash/加密），
     单测其 omitted/8MB/草稿清空/镜像归属/进度回调，checksum+加密留在薄壳；
  3. 至少为 `applyImport`（无 crypto 依赖，可用 MemoryPreferencesStore + 内存 Hub）补 flush/无变化跳过/
     文件域失败上报/部分失败 `failedDomains` 用例。

### R-D02（P1，待真机验证）文件域治理写入仍是单次 `fileIo.writeSync` 且不校验返回值，与已确证的真机截断缺陷同模式

- **证据**：
  - 治理路径：`StorageBackends.ets:265-283`（`writeFileAtomic`：单次 `writeSync` 后直接 rename，无返回值校验）；
    导入文件域走此路径（`DataTransferService.ets:744-747`）；
  - 迁移路径：`MigrationEngine.ets:866-876`（`writeTextAtomic` 同样单次写）；Store 路径：
    `SavedThreadStore.ets:233-239`、`DraftStore.ets:344-355`（存档/草稿可达数 MB）；
  - 设计稿 §13.3:1470-1479 明确记录过该真机缺陷（"单次调用不保证写完整个字符串，数 MB 的备份会被截断"），
    修复只覆盖了导出写入器（`FilePickUtils.writeTextToUri`，`FilePickUtils.ets:348-380` 分块循环）。
- **影响**：导入/迁移写入大离线存档、大草稿时，真机上可能截断且被计为写入成功（`written++`）；
  与需求 A/C 的"导入数据正确性"承诺冲突。导出链路已证明该 API 行为风险真实存在。
- **修复建议**：把 `FilePickUtils` 的分块写 + 返回值校验下沉为公共 `writeAllSync(fd, content)`，
  `StorageBackends.writeFileAtomic`/`MigrationEngine.writeTextAtomic`/`SavedThreadStore`/`DraftStore` 复用；
  写后按字节数或读回校验。**真机验证方法**：构造 8MB 级 `saved_threads` 文件走导入/离线保存，检查落盘文件
  `stat.size` 与内容是否完整。

### R-D03（P2）需求 B-6 未完全兑现：§13.5 无优先级标注，且 3 个 brief 已声明的遗留项未入表

- **证据**：
  - §13.5 表格仅"项 / 状态"两列（`docs/PERSISTENCE_UNIFICATION_DESIGN.md:1613-1630`），无优先级；
  - brief §5 明确列为"未实现"的 3 项在 §13.5 中不存在（grep 全文无"置灰/可恢复条数/逐域策略"）：
    ① 未登录时导出弹窗镜像域置灰；② 导入计划逐域策略标签；③ `ai_tool_cache` TTL 后可恢复条数；
  - 对应代码确认未实现：`DataManagementPanel.ets:655-690`（导出弹窗无登录态置灰逻辑）、
    `:1131-1157`（计划行无 policy 展示）、`DataTransferService.ets:1509-1517`（按备份条目数展示）。
- **影响**：审计→文档收口承诺落空；后续维护者在 §13.5 看不到这些待办，会误以为已全部收敛。
- **修复建议**：§13.5 增加"优先级（P0..P3）/来源（EXP-05…）"列，补上述 3 行；同时补 DES-19(b) TOCTOU、
  EXP-05 导出 fail-open 两行（见 §3.3）。

### R-D04（P2）§6.6#2 隐私提示描述与实现相反（文档失真）

- **证据**：设计稿 `:895-897` 称"实现为恒定提示、**不随勾选联动**，比原设计'勾选时提示'更保守"；
  实现除恒定提示（`DataManagementPanel.ets:1815-1819, 1892-1894`）外，还有
  `hasSensitiveSelection() && !exportEncrypt` 的动态警示（`:845-848, 1882-1890`，注释明确写"审计 EXP-09"）。
- **影响**：验收按文档断言"不随勾选联动"会与实现相反；该动态提示是本轮新增能力，文档未记录。
- **修复建议**：改为"恒定提示 + 勾选敏感域（AI 会话/浏览历史）且未加密时追加动态警示（EXP-09）"。

### R-D05（P2）需求 C-2 的 `legacyRetained` 四处置位无回归断言（测试锁不住原 bug）

- **证据**：
  - 置位实现：`DomainMigrators.ets:152`（字段）、`:321-324`（多账号设置无匹配）、`:431-434`（镜像旧缓存无匹配）、
    `:495-498`（收藏关系无匹配）；`MigrationEngine.ets:458-460`（未登录镜像）、`:481-484`（透传转换结果）；
  - 现有测试：`MigrationUnsettled.test.ets:20-58` 只测 `countUnsettled` 与 JSON 序列化；
    `PersistenceMigrationUnit.test.ets:345-396` 的三条可重试 skip 用例只断言 `skippedReason.length > 0`，
    **未断言 `legacyRetained`**（grep `entry/src/test` 中 `legacyRetained` 仅出现在 MigrationUnsettled）；
    `PersistenceMetaStore.normalizeReport` 的 `legacyRetained` 反序列化（`:262-265`）亦无测试。
- **影响**：删除任一置位或改坏透传逻辑，测试仍全绿 → 用户会再次遇到需求 C 描述的原 bug
  （有旧键待重试但升级警示不出现），静默失效。
- **修复建议**：在 `PersistenceMigrationUnit` 三条可重试用例加 `expect(result.legacyRetained).assertTrue()`；
  对不可重试 skip（如 `ai_tool_cache` 丢弃、旧目录为空）加 `assertFalse()`；如有条件补
  `MigrationEngine` 层透传断言（或把 4 类 skip 判定抽纯函数）。

### R-D06（P2）需求/文档测试清单过时与遗漏

- **证据**：
  - 设计稿 §11:1268 与 §8.2:1172 均写"44 个 Hypium 测试"；实际 `entry/src/test` 有 **49 个测试套件文件**
    （另有注册入口 `List.test.ets`），源码 `it()` 共 752 处；
  - §11:1270-1280 与 §13.2:1348-1356 的测试文件清单**漏 `MigrationUnsettled.test.ets`**
    （本轮新增并在 `List.test.ets:48, 102` 注册），§13.3:1605-1607 却提到该套件，文档内部不一致。
- **影响**：文档测试清单不可作为索引；"44 个全绿"已不能描述当前回归面。
- **修复建议**：更新两处计数（按套件/用例口径分别写明），补 `MigrationUnsettled.test.ets` 到 §11/§13.2。

### R-D07（P2）需求 A「导出有、导入不用的多余数据」仅做文档标注，未消除

- **证据**：容器仍携带且导入侧不消费：`updatedAt`（导出 `DataTransferService.ets:305-335, 368-376`；
  导入计划/应用不读取）、`deviceTag`（`:205` 写死 `'phone'`，导入 `normalizeContainer` 解析后无消费方）、
  `appVersionCode`（`:204`，导入无消费方）；设计稿 §6.1:745-746 将其标注为"仅诊断信息"。
- **影响**：与用户需求 A 的"不要出现导出有、导入不用的多余数据"字面不一致；属产品口径取舍而非数据风险
  （体积增量极小、不误导用户）。
- **修复建议**：二选一并在 §6.1 写明——① 删除 3 个字段（会降低排障能力）；② 明确"诊断字段不属于导入契约，
  用户要求的多余数据指业务数据"并保留。建议 Lead 与用户确认口径。

### R-D08（P2）历史持久层 / 4MB 预警无测试；历史 meta 读改写并发面无测试

- **证据**：
  - `normalizeTransferHistory`（`PersistenceMetaStore.ets:184-220`：坏条目丢弃、未知 kind 丢弃、上限 10）
    与 `recordTransferHistory`（`DataTransferService.ets:273-290`：load→append→save 全量覆盖）无测试；
  - 清空时 `meta.transferHistory = []`（`AppStore.ets:1342`）无测试；4MB 判定（`DataManagementPanel.ets:527`）
    无测试（可抽纯函数 `isOversized(bytes)` 复用 `PersistenceTypes.DOMAIN_SIZE_WARN_BYTES`）；
  - `PersistenceMetaStore.save` 为全量 meta 覆盖（`:83-95`），而 `recordTransferHistory` 与
    迁移 `saveReport`（`:126-139`）、`acknowledgeMigrationNotice`（`AppStore.ets:1157-1162`）都可能 load→save；
    虽 `load()` 返回同一缓存对象（`:54-75`）降低风险，但 `ensureMeta(load(true))` 会替换缓存实例
    （`MigrationEngine.ets:600`），并发窗口未验证。
- **影响**：历史条目可能丢失/覆盖 meta 其他字段的回归无法被发现；4MB 预警文案真假无门禁。
- **修复建议**：补纯函数级历史归一化/截断用例；把"组装 4MB 行"抽纯函数后断言 oversized；对 meta 读改写
  补"两次 recordTransferHistory + 迁移 saveReport 交错"的测试（MemoryPreferencesStore 可复用
  `HistoryReadLedgerUnit.test.ets:25` 的假实现）。

### R-D09（P3）§12 风险登记两条与实现/自身文档矛盾

- **证据**：R2 缓解写"分两步放开（先保守版）"（`:1287`），但 §8.2:1170-1173 明确"未采用先保守后放开的
  两步走"；R5 回滚写"关闭调度器任务开关（`SchedulerTask.enabled` 常量）"（`:1290`），
  `common/scheduler` 无 `SchedulerTask`/`enabled` 符号（grep 0 命中），实际回滚手段不可用。
- **修复建议**：R2 改为"直接放开（已实现）"；R5 改为实际可用的回滚/降级手段（如日志对照 + 关闭任务注册）。

### R-D10（P3）§13.3 批次记录内部口径需加"已被后续批次取代"标注

- **证据**：2026-10-31"审计后的实现修正"记录末尾仍写"升级器未实现、4MB 未实现"（`:1547-1549`），
  而后续 2026-10-31 第二批记录已写二者已实现（`:1557-1582`）、§13.5:1618-1620 标"已实现"。
- **影响**：按时间顺序阅读会误判当前状态。
- **修复建议**：在该历史条目加注"（上述两项已由后续批次补齐）"或统一以 §13.5 为唯一状态源并注明。

### R-D11（P3）§2.1 枚举示例与编辑残留

- **证据**：设计稿 `:213` 代码块内混入"（实际枚举有 6 个值）"；`:215` 注释"字段级合并（theme 等）"与
  实际 theme 整体覆盖、源码已更新注释（`PersistenceTypes.ets:50-58`）不符。
- **修复建议**：同步源码注释、删除编辑残留。

### R-D12（P3）验证数字口径：`test_result.txt` 明细 752 条 Success vs 摘要行 736

- **证据**：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`（mtime 2026-10-31 20:20:15）
  含 `test=` 752 条、`result=Success` 752 条、`class=` 83 条，末行摘要为
  `Tests run: 736, Failure: 0, Error: 0, Pass: 736, Ignore: 0`；与 brief/doc 的 736 一致，但与明细不一致。
  本次未复跑 Hypium（遵守 brief），无法判定是 Harness 统计口径还是结果文件跨次累加。
- **影响**：§13.3 的"736"可能低估/错记回归面；不影响"全绿"结论。
- **修复建议**：Lead 核对一次 `hvigorw test` 输出与结果文件行数，若明细 752 属实则同步更新 §13.3/§13.5 口径
  （或说明"摘要按去重后用例计"）。

### R-D13（P3）两处文档/日志小口径

- **证据**：§6.4:847"备份含 drafts 时提示草稿媒体需重选"→ 实现为恒定提示（`DataManagementPanel.ets:1988-1991`，
  更保守，无害）；§6.6#11"导出/导入各写一条日志（域数量、总体积、是否加密、耗时）"→ 导入日志无
  体积/是否加密/耗时（`DataTransferService.ets:717-718`，导出日志有 `:254-255`）。
- **修复建议**：按实现改写或补齐导入日志字段。

### R-D14（P3）源码残留"撤销"注释

- **证据**：`TransferTypes.ets:9` 文件头仍写"…→ 应用 → 撤销"（撤销导入已移除，DES-05 要求清理）；
  `DataTransferService.ets:90-91, 772-789` 的 undo 相关注释均已是"仅清理旧版本残留"，无误导。
- **修复建议**：更新 `TransferTypes.ets:9` 文件头。

### R-D15（P3）「修复」按钮异常路径无二次确认

- **证据**：`DataManagementPanel.ets:560-579`：`showAlertDialog` 抛错时 catch 内直接 `repairDomain(domainId)`
  （注释"用户已通过按钮表达意图"），与需求 B-4/设计稿 §4.5/§9.2 的"二次确认"承诺在异常分支不一致；
  该分支会删除设备级用户数据。
- **修复建议**：异常路径改为 Toast 提示"无法弹出确认框，请重试"并不执行；或改为需要长按/输入确认。

---

## 6. 测试缺口清单（按优先级）

| # | 缺口 | 影响契约 | 可行性/建议 |
| --- | --- | --- | --- |
| T1 | `exportBackup` 编排：8MB 超限→`omitted`、NEVER 二次拦截、草稿媒体清空接线、镜像 ownerUid、进度回调、64MB 拒绝 | EXP-01/02、B-1、B-5、B-4 进度 | 需先注入/拆分 checksum（`DataTransferService.ets:239` 无条件 sha256，Local Test 不可用）；或抽纯组装函数 |
| T2 | `applyImport` 编排：flush 排空、无变化跳过、文件域失败上报、部分失败 `failedDomains`、镜像 ownerUid 写入 | IMP-03/07/15、A7 | 可用 `MemoryPreferencesStore`（`HistoryReadLedgerUnit.test.ets:25`）+ 内存 Hub 实现，无 crypto 依赖 |
| T3 | `AppStore.reloadAfterImport` 覆盖集合与单步失败隔离 | IMP-07、A10 | AppStore 依赖 Context；建议声明式断言"Catalog 可导入域 ⊆ 重载步骤表"或抽出步骤表纯函数 |
| T4 | `legacyRetained` 四处置位 + 不可重试 skip 为 false + `normalizeReport` 反序列化 | 需求 C-2 | 纯函数/`MemoryPreferencesStore` 可测；最便宜、价值最高 |
| T5 | 历史 meta：`normalizeTransferHistory`（坏条目/未知 kind/上限）、`recordTransferHistory` 写入与上限、清空重置、与迁移 saveReport 交错 | B-1、R-D08 | `MemoryPreferencesStore` + `PersistenceMetaStore` 可测 |
| T6 | 4MB 预警判定 | B-1b | 抽 `isOversized(bytes)` 纯函数后 3 行断言 |
| T7 | 导出/导入真实 IO 往返（分块写/读回校验/大文件） | A11、R-D02、EXP-08 | ohosTest/真机；Local Test 无法覆盖 |
| T8 | 解析层未覆盖分支：旧版 `SavedThreadExport`（无 magic）转换、`.ngacred` magic 拒绝、`dataVersion=0` 接受、checksum 不匹配（crypto） | §6.5 | 前三项无 crypto 可补；checksum 需真机 |
| T9 | `TrackedThreadStore` 读失败不写盘回归 | IMP-08、A8 | 需 mock `CacheEnvelopeStore`/Preferences；可参考 CacheEnvelopeUnit 的纯工具测试 |
| T10 | 旧版迁移置位/文件域预算 DEFERRED 续跑 | A4、DES-02 | 文件域需真实目录，建议 ohosTest |
| T11 | UI 逻辑：计划行文案（策略/覆盖恢复/无变化）、导出弹窗六组/体积/进度、修复二次确认 | B-4、IMP-12 | ArkUI 无单测框架；可把 `buildPlanLines/buildExportRows` 抽纯函数后测 |

**测试有效性评价（正面结论）**：

- 新增 4 套件均为**行为断言**（计数、跳过原因、形状、幂等、不可变入参），不是"只断言不抛错"；
  用例名（`reportsOversizedDomainInsteadOfSilentlyDroppingIt`、`treatsRenamedDraftAsUpdateNotAdd` 等）
  与断言内容一致，可定位回归。
- 无随机数/真实时间依赖（`exportedAt` 用固定常量）；8MB 用例只多构造 4KB 边界，内存可控。
- 未发现"改坏实现仍能通过"的明显用例；交叉覆盖（DomainParity 形状 + DataTransferUnit 合并语义 +
  ImportPlan 计数）能覆盖大部分纯逻辑。
- 存在两处**结构性弱点**：① 往返测试**手工构造"导出形状"容器**，不经过 `exportBackup`，导出实现漂移
  不会被发现（见 R-D01/T1）；② `exposesDroppedDomainsAsSkippedPlanEntries`
  （`DataTransferDomainParity.test.ets:327-350`）手工构造 `SkippedDomain` 后调用 `buildImportPlan`，
  只锁定"计划层会展示传入的丢弃域"，**未验证 parse→plan 的端到端接线**（`buildPlanAndShow` 的
  UI 调用链无测试）。
- 本报告未重复验证"纯函数抽取前后行为等价"（任务-10 E 项）与对抗性边界（任务-12），结论以其报告为准。

---

## 7. 设计稿 §13.3 / §13.5 状态与验证数字核对

| 核对项 | 设计稿 | 事实（只读产物/代码） | 判定 |
| --- | --- | --- | --- |
| HAP 体积 | §13.3:1603 "HAP 10.81MB" | `entry-default-signed.hap` 10,806,803 B = 10.81 MB（十进制）/10.31 MiB，mtime 2026-10-31 20:20:42 | 一致 |
| 编译 | §13.3:1603 BUILD SUCCESSFUL、无 ERROR | 无法从产物反证；brief 声明通过，本次不跑编译 | 采信 brief |
| Hypium | §13.3:1604 "736 用例、全绿" | `test_result.txt` 摘要 736 / detail 752（R-D12） | 与 brief 一致；明细口径待核 |
| 用例增量 | §13.3:1586-1589 第二批 +25（19+6）；:1605-1607 第三批 +5（2+3） | 源码 `it()`：ImportPlan 21（19+2）、RoundTrip 6、MigrationUnsettled 3、DomainParity 12，与记录吻合 | 一致 |
| 行尾 | §13.3:1607 LF | 本次执行 `node scripts/check-eol.mjs` → `OK: 全部已跟踪文本文件为 LF`（exit 0） | 一致 |
| §13.5 状态 | 1615-1630：修复按钮/调度折叠/域级进度/六组/体积/4MB/历史/升级器入口/草稿键改写/镜像跨账号/checksum 缺失提示/文件域预算 = 已实现 | 逐项代码核实：`AppStore.ets:1360-1373`、`DataManagementPanel.ets:376-408/501-542/862-867/109-118/1560-1615`、`PersistenceTypes.ets:127,382-452`、`DataTransferService.ets:534-536, 1422-1435`、`DraftPortability.ets:109-151`、`MigrationEngine.ets:540-548` | **无虚标** |
| §13.5 未实现项 | 4MB 之外容量治理/草稿跨账号一次性提示/升级规则具体域/真机项 | 与代码一致；但缺 EXP-05/IMP-12/IMP-14/DES-19(b)（R-D03） | 部分 |

---

## 8. 放行建议

**有条件放行**。建议在合入/交付前完成：

1. **文档**（低成本、必须）：按 R-D03/R-D04/R-D06/R-D09/R-D10/R-D11/R-D13 修正设计稿；§13.5 补优先级列与
   3+2 个隐形待办；§11/§13.2 补 `MigrationUnsettled.test.ets`；更新"44 个测试文件"的过时口径。
2. **测试**（中低成本、强烈建议）：补 T4（`legacyRetained` 置位，需求 C-2 的核心风险）与 T2/T5（applyImport、
   历史 meta）；T1 需先做 checksum 可注入/纯组装抽取，可作为后续迭代承诺但应在 §13.5 记录。
3. **真机**：验证 R-D02（文件域写盘完整性）与 brief §5 已列的真机项；若 R-D02 复现截断，升级为阻断。
4. **口径确认**：R-D07（`updatedAt/deviceTag/appVersionCode` 是否保留）与 Lead/用户确认；R-D12 由 Lead
   核对真实用例数后统一 §13.3 数字。

---

## 9. 评审限制

- 只读静态评审：未运行编译/Hypium/模拟器，无法动态验证 UI 行为、加密往返、真实 IO；相关结论以代码路径
  与 brief 已统一验证的产物为准。
- 行号基于当前工作区（含未提交修改）；后续提交会使行号偏移。
- 未重复论证纯函数抽取的行为等价性（任务-10）与对抗性安全边界（任务-12）；如三份报告结论冲突，以代码
  行号证据为准复核。
