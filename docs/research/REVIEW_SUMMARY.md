# 评审汇总 — 本会话「用户数据系统（持久化统一治理 + 数据管理导出/导入）」

> 日期：2026-10-31
> 基线：HEAD = `a4634d6d`（已提交第一批）+ 当前工作区未提交的第二/三批改动
> 组织方式：Lead 准备评审基线（需求清单 / 改动范围 / 关键设计决策 / 验证状态 / 遗留声明），
> 3 名**全新独立评审员**（fresh context，不继承实现过程）并行只读评审，Lead 汇总并按评审结论修复、复验。

## 1. 评审分工与结论

| 评审员 | 报告 | 关注面 | 结论 | 发现 |
| --- | --- | --- | --- | --- |
| reviewer-code | [`REVIEW_CODE.md`](REVIEW_CODE.md) | 代码正确性 / 行为等价性 / 测试有效性 | 有条件放行 | 无 P0/P1；P2×5、P3×18 |
| reviewer-req | [`REVIEW_REQUIREMENTS.md`](REVIEW_REQUIREMENTS.md) | 需求覆盖 / 文档一致性 / 测试缺口 | 有条件放行 | 无 P0；P1×2、P2×6、P3×7 |
| reviewer-adversarial | [`REVIEW_ADVERSARIAL.md`](REVIEW_ADVERSARIAL.md) | 对抗性回归 / 安全 / 边界 | 有条件放行 | 无 P0；P1×1、P2×6、P3×9 |

**三方共同确认无回归的项**：上一批审计修复（flush / 逐域容错重载 / 无变化跳过 / 读失败不写空盘 /
ENVELOPE 成形归一 / init 顺序 / 清空重置清单 / updatedAt 口径）；容器解析防护（magic/版本/域数/重复域/
路径穿越）；加密参数校验；AI Key 端点一致性校验；升级器无绕过路径；历史不含业务内容。

## 2. 评审问题闭环

### 2.1 已修复（本轮，代码 + 测试）

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| R-D02（P1） | 4 处文件域治理写入是单次 `writeSync` 且不校验返回值（真机截断同模式） | `FileUtils.writeTextFully`（UTF-8 分块循环写 + 返回值校验）；`StorageBackends` / `SavedThreadStore` / `DraftStore` / `MigrationEngine` 统一接入 |
| R-A01（P1） | 导出含其他账号草稿正文；导入把本机其他账号草稿改键复制给当前账号 | `DraftPortability.filterDraftsForAccount`；导出与本机导入载荷都按当前账号过滤（跨账号"找回"语义保留） |
| R-C01 / R-A05（P2） | 清空本地数据后迁移明细不重置 → "升级未完成"警示跨重启误报 | `AppStore.resetGovernanceMetaAfterClear`：重置 `status=NOT_REQUIRED`、`domains=[]`、`legacyKeys=[]`、历史（保留 dataVersion/migratedAt/ack） |
| R-C02 / R-A06（P2） | `repairDomain` 丢弃重载失败却报"已修复"；未登录镜像域不刷新；弹窗异常时直接清盘 | 返回可读原因、失败不清健康标记、未登录镜像域显式提示；弹窗异常改为提示重试（不再清盘） |
| R-C05（P2） | `makeDraftsPortable` 把 media 移到末尾 → "内容相同"被误判为更新 | media 原位清空 + 保持字段顺序；旧草稿补空 media；文档口径修正 |
| R-A03（P2） | 文件域计划计数 ≠ 写盘（`{items}` 包裹/非法条目） | 前置拒绝非数组文件域载荷；`buildImportPlan` 用 `planFileDomainWrites` 预演并提示无效条目数 |
| R-A04（P2） | 4MB 预警字符/字节口径混用 → 中文域漏报 | `PersistenceHub.estimateBytes` 对 Preferences 域改用 UTF-8 字节数；阈值抽 `isDomainOversized` |
| R-A08（P3） | `planFileDomainWrites` 原地修改入参 | 重建记录，不修改调用方数据 |
| R-A09（P3） | 调度"从未执行"显示为"跳过" | 按 `lastRunAt===0` 单独显示"未运行" |
| R-A10（P3） | 4MB 预警文案给出无入口的"清理该域" | 文案改为指向「清除缓存」/「清空本地数据」 |
| R-C06（P3） | 合并失败条目缺 `policy` | catch 分支补齐 `policy` |
| R-D04（P2） | §6.6#2 隐私提示文档与实现相反 | 文档改为"恒定提示 + 敏感域动态警示" |
| R-D06（P2） | §11/§13.2 测试清单漏新套件、套件数过时 | 补齐 `MigrationUnsettled`/`DataReviewFixes`，更新为 49 套件 / 742 用例 |
| R-D10（P3） | §13.3 历史记录口径与后续批次矛盾 | 加"已被后续批次取代，当前状态以 §13.5 为准"注 |
| R-D11（P3） | §2.1 编辑残留 / 枚举注释失真 | 删除残留、注释与实现对齐 |
| R-D13（P3） | 导入日志缺耗时；草稿媒体提示口径 | `applyImport` 日志补 `costMs`；§6.4 口径改为"恒定提示" |
| R-D14（P3） | `TransferTypes.ets` 文件头残留"撤销" | 更新为"计划 → 应用" |
| R-D15（P3） | 修复按钮异常路径无二次确认 | 异常路径不再执行清盘，提示重试 |
| R-D03（P2） | §13.5 无优先级列、3 个已声明遗留项未入表 | §13.5 增"优先级/来源"列并补登：镜像域置灰、策略标签、TTL 条数、测试债、ENVELOPE 条目校验、资源保护、TOCTOU、容器诊断字段口径等 |

### 2.2 已登记为遗留（不阻塞放行，见设计稿 §13.5）

| 编号 | 项 | 原因 |
| --- | --- | --- |
| R-D01 / T1–T3（P1 测试债） | `exportBackup` / `applyImport` / `reloadAfterImport` 编排层无单测 | `exportBackup` 无条件 SHA-256（Local Test 无 crypto）+ Hub 真实 IO 依赖；需先引入可注入 hash 与内存 Hub 假实现（建议专项） |
| R-A16（P2） | ENVELOPE 域导入不校验条目结构（`tracked_threads` 坏条目整封不可读） | 同版本备份条目恒合法，仅构造/跨版本包触发；读失败已不写空盘；需导出各 Store 校验函数后统一做 |
| R-A02（P2，部分） | 海量文件域条目 ANR / 旧存档兼容路径未复用体积校验 | 受 8MB/64MB 限制但仍可构造；需条目数上限 + 分批让出主线程（改动较大） |
| R-A07（P3） | 计划→执行之间账号态变化会把草稿写成 `anon` | 窗口极小，需计划内记录 uid 并在 apply 前校验 |
| R-A14 / R-A15（P3 待验证） | `__proto__` 键合并语义 / 64MB 峰值内存 | 需 Hypium 构造断言 / 真机观测 |
| R-D07（P2 口径） | 容器 `updatedAt/deviceTag/appVersionCode` 导入不消费 | 属诊断字段，非业务数据；§6.1 已明确"不属于导入契约" |
| R-D08（P2，部分） | 历史 meta 读改写并发面无测试 | `normalizeTransferHistory` 已补测试；并发交错需 MemoryPreferencesStore 假实现（专项） |
| R-D12（P3） | `test_result.txt` 明细 Success 行数 > 摘要用例数 | 已核对为 Hypium 明细/摘要统计口径差异（明细含跨 suite 重复计数），以摘要 `Tests run` 为准；不影响全绿结论 |

## 3. 复验结果（Lead）

| 验证 | 结果 |
| --- | --- |
| DevEco `assembleHap` | **BUILD SUCCESSFUL**（无 ERROR） |
| Hypium Local Test | **Tests run: 742, Failure: 0, Error: 0, Pass: 742, Ignore: 0**（新增 `dataReviewFixes` 7 用例） |
| `node scripts/check-eol.mjs` | 全部已跟踪文本文件为 LF |

## 4. 结论

- 三份独立评审一致：**无 P0**；修复全部 P1（2 条代码/隐私类：文件写入完整性、草稿跨账号过滤）与
  可修的 P2（清空口径、修复结果如实、草稿无变化判定、文件域计划预检、体积口径、文档失真），
  其余以"优先级 + 来源"登记进设计稿 §13.5。
- 仍需真机验证：加密容器往返、跨账号镜像跳过、8MB 边界、草稿媒体重选、picker 回读、系统备份恢复、
  投票入口跨账号语义（见 §13.5）。
- 建议下一步专项：导入/导出编排层测试设施（可注入 hash + 内存 Hub）、ENVELOPE 域条目校验统一、
  文件域海量条目资源保护。
