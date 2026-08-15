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

`tools/bbcode-ts/src/` 下的 TS 镜像工程（Node 环境毫秒级验证，绕开 DevEco 编译链）是**真源**，
涵盖三部分：
- **BBCode 解释器**（`parser/bbcode/`）：JSON 模式楼层 content（BBCode 源文）的解析/渲染
- **HTML 模式解析器**（`parser/nga/html-thread/` + `parser/NgaJsonSanitizer.ts`）：
  read.php 静态 HTML → 与 JSON API 同形状的数据（以 JSON 为基准尽力还原，含热点回复）
  —— 修复/新增必须同步走镜像流程
- **通用工具函数**（`common/utils/Utils.ts`）：日期格式化（`formatTime`/`formatTimestampCST`/
  `formatTodayCST`）、纯文本提取等 —— **也在镜像清单内**，直接改 `.ets` 会在下次 sync 时被覆盖

凡涉及解析器、渲染器、NGA 域名常量（NgaDomains.ts）、html-thread 解析器、Utils 工具函数的修改：

- **动手前先自查**：`node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry`（在项目根执行）。
  输出「修改 N 个文件」中若包含目标 `.ets` → 该文件在镜像清单内，必须走镜像流程；
  输出「0 修改」→ 可安全直接改 entry 侧文件
- 只改镜像 `tools/bbcode-ts/src/` 下的 `.ts`，**禁止直接修改** `entry/src/main/ets/` 下被镜像的文件
  —— `npm run sync` 会把镜像目录整体机械覆盖回 `.ets`（当前 31 个文件，清单以 sync 脚本 dry-run 输出为准）
- 镜像代码必须继续遵守 ArkTS 子集（见下方 ArkTS 语法约束），否则同步回 `.ets` 后无法编译
  （注意：TS 能编译 ≠ ArkTS 能编译，如 `{}` 空字面量/`void` 表达式是 ArkTS 硬错误，须跑 hvigor 确认）
- 标准流程：改镜像 → `npm test`（文本零丢失 + 官方渲染基准差分 + 快照回归 + HTML 覆盖验证）
  → `npm run sync` 回写 `.ets` → DevEco 编译 + Hypium（`entry/src/test/BBCodeUnit.test.ets`）最终门禁
- 「官方网页怎么渲染，解析器就怎么解释」是最高对齐标准，差异处理详见 `tools/bbcode-ts/README.md`
- HTML 模式覆盖套件：`npm run compare:html-json` 出报告；成对样本（JSON+HTML 同页）登记在
  `samples/html-pairs.lst`，已知缺口（如页面隐楼行号错位）声明在 `samples/html-pair-gaps.json`

## 沉浸光感（Immersive Light）情报文档

凡处理涉及沉浸光感的内容——`systemMaterial`、`ImmersiveMaterial`/`uiMaterial`、`colorInvert` 自动反色、
材质按钮/面板/弹窗的适配与可视性问题——**必须先读取 `docs/IMMERSIVE_LIGHT_DESIGN.md` 再动手**。
该文档是 API 26 沉浸光感的契约与踩坑结论：三层开关体系、自动反色特殊资源值表（表 1，`ohos_id_color_*`
不生效）、生效属性白名单、属性冲突约束与故障排查清单。