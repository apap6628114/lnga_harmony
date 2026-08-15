---
name: bbcode-ts
description: NGA 解析链路 TS 镜像验证与回写。处理 BBCode 解析/渲染、HTML 降级解析（read.php 静态 HTML → JSON 同形状）、NgaJsonSanitizer、NgaDomains、Utils 工具函数、解析相关样本/快照/官方差分，需要抓取帖子内容诊断异常，或执行 Node 镜像门禁（npm test / sync / compare:html-json）并同步回 .ets 时使用。允许在 tools/bbcode-ts 下运行 Node 构建、测试与抓取脚本；禁止直接修改被镜像的 entry/src/main/ets 文件，禁止将 Node 测试结果等同于 ArkTS 最终门禁（DevEco 编译见 harmonyos-build-deploy，Hypium 见 harmonyos-test）。
---

# NGA 解析链路镜像验证（tools/bbcode-ts）

`tools/bbcode-ts` 是客户端解析逻辑的 Node.js 镜像验证工程与**唯一真源**：验证 JSON 主通道
BBCode 解析、HTML 降级恢复，并在 Node 门禁通过后把 ArkTS 子集兼容的 TS 机械同步回 `.ets`。

## 职责边界

| 能做 | 不能做 |
|---|---|
| 在 `tools/bbcode-ts` 下运行 Node 构建/测试/抓取/差分/同步 | 直接修改 `entry/src/main/ets/` 下被镜像的文件（会被下次 sync 覆盖） |
| 抓取真实帖子（JSON 优先、HTML 降级）固化为样本 | 无真实输入时猜标签语义、伪造样本 |
| 修改 `src/` 真源并完成 Node 门禁后 `npm run sync` | 把 Node 测试通过等同于 ArkTS 可编译（需 DevEco + Hypium 最终门禁） |
| 维护样本、快照、官方差分、HTML 成对覆盖 | 用更新快照掩盖未知回归 |

最终门禁分工：DevEco 编译见 skill `harmonyos-build-deploy`；Hypium Local Test 见 skill `harmonyos-test`。

## 动手前（MUST）

1. 完整阅读 `tools/bbcode-ts/AGENTS.md`（Rule 0–9 强制规则；本文件是其浓缩，冲突时以 AGENTS.md 为准）。
2. 自查镜像边界（项目根执行）：
   `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry`
   输出含目标 `.ets` → 该文件在镜像清单内，必须改 `tools/bbcode-ts/src/` 再 sync；
   输出「0 修改」→ 可安全直接改 entry 侧文件。
3. 确认数据源：客户端帖子详情 MUST 先走 JSON（`read.php?__output=8`）；HTML 仅在 JSON 失败
   或专门调查降级解析器时使用，不得颠倒优先级。

## 异常帖子调查分流（浓缩 Rule 2）

1. 先检查 `tools/bbcode-ts/.nga-cookie.txt` 凭证：存在且结构完整（含非空 `ngaPassportUid` 与
   `ngaPassportCid`）直接复用；缺失/失效才用 chrome-devtools MCP 重取（流程见 AGENTS.md R2.1）。
2. 记录 tid / page / lou / 异常环节（原始数据、BBCode 解析、Run 格式化、ArkUI 渲染、HTML 降级）。
3. `npm run inspect:json -- <tid> <page>` 拉 JSON 主通道；JSON 满足条件后 MUST 直接调 JSON 链路。
4. 仅满足降级条件（JSON 截断/错误页/专查 HTML 模式/只有 pid）时
   `npm run inspect:html -- <tid> <page> [lou ...]`。
5. 按 R2.5 现象表进入唯一下一步（如 BBNode 正确但 InlineRun 错误 → 查 `bbcode-utils.ts`；
   解析语义与官方不同 → 提取官方渲染 DOM/Run 差分）。

## 修改与门禁（浓缩 Rule 4–6）

- 只改 `tools/bbcode-ts/src/` 下的 `.ts`（31 个镜像真源）；`scripts/`、`tests/`、`samples/`
  属 Node 验证工具，不会同步到客户端。
- 镜像代码必须同时通过 TypeScript strict 与 ArkTS 子集约束（TS 能编译 ≠ ArkTS 能编译，
  `{}` 空字面量、`void` 表达式是 ArkTS 硬错误）。
- 门禁顺序：

```bash
cd tools/bbcode-ts
npm run snapshot   # 仅新增样本或预期解析树变化时执行；生成后 MUST 人工审查 diff
npm test
npm run sync
node scripts/sync-to-ets.mjs --dry   # 必须 0 修改、0 新增
# 回项目根：DevEco HAP 编译 → entry/src/test/BBCodeUnit.test.ets 等 Hypium Local Test
```

- 只改 README、Node 脚本或测试工具且没改镜像 `src/` 时，MAY 跳过 sync/DevEco/Hypium，
  但 MUST 至少运行相关 Node 构建/测试。

## 特殊行为速查（浓缩 Rule 8，完整清单见 AGENTS.md）

- 匿名名 `[uid]#anony_...[/uid]` 只在 Run 格式化阶段解码；BBNode 保留原始编码。
- `[attach]` 只接受官方精确语法与 NGA 附件域；非法域、未闭合、带属性时按官方行为退化为原文。
- `[img]` 旧域 `img.nga.178.com` 归一化到 `img.nga.cn`；`img7?` 只覆盖 `img`/`img7`，不得误改 `img4`。
- 链接类内联标签长度上限 8192，样式类保持 512。
- 渲染层连续空行折叠为一个换行；解析树保留原始连续换行。
- 零丢失断言用 `concatTextNodes`（`bbNodesToPlainText` 会剥除样式子树边缘空白）。
- HTML 降级：负数子版 fid 用 `-?\d+` 提取；`__T.lastpost` 取 `setDefault` 倒数第 2 参数；
  hotreply 按精确 pid 匹配 `commonui.postArg.proc( '__<pid>', ...)`。

## 命令速查（均从 tools/bbcode-ts 目录执行）

```bash
npm install / npm run build
npm run inspect:json -- <tid> [page] [输出文件名] [lou]   # JSON 主通道抓取/固化样本
npm run inspect:html -- <tid> [page] [lou ...]            # HTML 降级抓取
node scripts/fetch-thread-pair.mjs <tid> [page]           # 成对样本（JSON+HTML 同页）
npm run compare:html-json                                 # HTML 覆盖报告（正文覆盖率硬阈值 ≥90%）
npm run compare:official                                  # 官方渲染差分
npm run snapshot                                          # 生成解析树快照（需人工审查 diff）
npm test                                                  # Node 门禁
npm run sync                                              # 回写 .ets
node scripts/sync-to-ets.mjs --dry                        # 镜像边界自查 / 同步后校验
```

## 完整规则

一切以 `tools/bbcode-ts/AGENTS.md` 为准：数据源优先级（Rule 1）、调查分流（Rule 2）、
净化契约（Rule 3）、真源边界（Rule 4）、解析渲染契约（Rule 5）、门禁（Rule 6）、
HTML 覆盖（Rule 7）、特殊行为（Rule 8）、命令速查（Rule 9）。动手前必须通读。
