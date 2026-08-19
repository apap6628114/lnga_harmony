# 项目规则 — NGA OH (HarmonyOS ArkUI)

NGA 论坛客户端，stage 模型，API 7.0.0(26)，单 entry 模块。

## 构建与部署

工程依赖 DevEco Studio 内置工具链，项目根目录**无 `hvigorw` Wrapper**，须从安装目录调用。

编译验证、模拟器拉起、HAP 安装部署的完整流程见 skill：**`harmonyos-build-deploy`**（该 skill 不执行自动化测试；应用启动也仅在用户明确要求时进行）。

## 行尾纪律（LF 强制）

仓库通过 `.gitattributes`（`* text=auto eol=lf`）与 `.editorconfig` 强制全部文本文件 LF：
index/HEAD 恒为 LF；但 Windows 工具直接写盘可能产出 CRLF/混合行尾（git 对混合行尾文件的
eol 判断不可靠，`git ls-files --eol` 可能漏报）。规则：

- **禁止**用 PowerShell `Out-File` / `Set-Content` / `echo >` 重定向写仓库文件（Windows 默认
  CRLF，且 5.1 版 Out-File 带 BOM）；写文件一律用 write/edit 工具或 Node `writeFileSync`（内容用 `\n`）
- **禁止**用 `git checkout-index` / `git checkout -- .` 重写工作区（受 `core.autocrlf=true`
  影响会写出 CRLF）；恢复工作区用 `git restore`
- 修改文件后 `git status` 出现大面积"无内容差异的 M"时，先怀疑行尾/stat 缓存，用
  `git add --renormalize` 刷新后再判断
- 行尾自检：`node scripts/check-eol.mjs`（发现违规退出码 1）；修复：`node scripts/check-eol.mjs --fix`
  后再 `git add` 复查
- 字节级检测为准：CR 与 LF 并存即视为违规（无论 git 如何归类）

## BBCode / HTML 模式解析器修改规则（TS 镜像真源）

解析器、渲染器、`NgaDomains.ts`、html-thread 解析器、`Utils.ts` 的修改规则与完整流程见
skill：**`bbcode-ts`**（加载后按其操作；Rule 0–9 完整规则已并入 skill 正文）。

常驻红线摘要（即使 skill 未触发也必须遵守）：

- `tools/bbcode-ts/src/` 是**唯一真源**（当前 34 个镜像文件，含 `parser/nga/html-topiclist/`
  主题列表降级解析器）；**禁止直接修改**
  `entry/src/main/ets/` 下被镜像的文件 —— 下次 `npm run sync` 会机械覆盖
- **动手前先自查**：`node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry`（项目根执行）。
  输出含目标 `.ets` → 必须走镜像流程；输出「0 修改」→ 可安全直接改 entry 侧文件
- 标准门禁（在 `tools/bbcode-ts` 下执行）：改镜像 → `npm test` → `npm run sync` → `sync-to-ets.mjs --dry` 为 0 修改
  → DevEco 编译 + Hypium（`entry/src/test/BBCodeUnit.test.ets`）最终门禁
- 镜像代码必须遵守 ArkTS 子集（TS 能编译 ≠ ArkTS 能编译，`{}` 空字面量/`void` 表达式是硬错误）
- 「官方网页怎么渲染，解析器就怎么解释」是最高对齐标准

## NGA 真实数据抓取（通用层）

抓取 NGA 真实数据、管理持久化登录凭证（校验/落盘/失效验证）见 skill：**`nga-data-fetch`**
（工具在 `tools/nga-data-fetch/`，净化与解析语义仍由 `tools/bbcode-ts` 镜像提供）。

常驻要点：

- **抓取前 MUST 先过凭证门禁**：`node tools/nga-data-fetch/bin/nga-fetch.js verify`
  （固定基准 `read.php?tid=44191387`，获取成功才算通过；失败按 skill 指引刷新后复验）
- 凭证落盘：`node tools/nga-data-fetch/bin/nga-fetch.js save '<cookie>'`（项目根执行）；
  帖子特定入口仍是 bbcode-ts 的 `npm run inspect:json` / `inspect:html`，用户发帖/回帖记录
  成对样本用 `node tools/bbcode-ts/scripts/fetch-topic-pair.mjs <uid> [reply] [page]`
  （均在 `tools/bbcode-ts` 下执行，命令不变）

## 沉浸光感（Immersive Light）情报文档

凡处理涉及沉浸光感的内容——`systemMaterial`、`ImmersiveMaterial`/`uiMaterial`、`colorInvert` 自动反色、
材质按钮/面板/弹窗的适配与可视性问题——**必须先读取 `docs/IMMERSIVE_LIGHT_DESIGN.md` 再动手**。
该文档是 API 26 沉浸光感的契约与踩坑结论：三层开关体系、自动反色特殊资源值表（表 1，`ohos_id_color_*`
不生效）、生效属性白名单、属性冲突约束与故障排查清单。