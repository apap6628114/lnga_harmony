# 项目规则 — NGA OH (HarmonyOS ArkUI)

NGA 论坛客户端，stage 模型，API 6.1.0(23)，单 entry 模块。

## 构建与部署

工程依赖 DevEco Studio 内置工具链，项目根目录**无 `hvigorw` Wrapper**，须从安装目录调用。

编译验证、模拟器拉起、HAP 安装部署的完整流程见 skill：**`harmonyos-build-deploy`**（`.claude/skills/harmonyos-build-deploy/`）。该 skill 不执行自动化测试；应用启动也仅在用户明确要求时进行。

核心要点：
- 环境变量：`export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"`
- Git Bash 路径保护：`export MSYS_NO_PATHCONV=1`
- 别名：`alias hvigorw="/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.bat"`
- 调试构建：`hvigorw assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon`
- 发布构建：将 `buildMode` 改为 `release`；清理：`hvigorw clean`

## 项目结构

详见 `.wiki/入门指南.md` 及各模块 Wiki：页面模块、公共组件模块、状态管理层、服务层、数据模型、解析器模块、应用生命周期。

## BBCode 解析器修改规则（TS 镜像真源）

BBCode 解析/渲染逻辑的**真源**是 `tools/bbcode-ts/src/` 下的 TS 镜像工程（Node 环境毫秒级验证，
绕开 DevEco 编译链）。凡涉及解析器、渲染器、NGA 域名常量（NgaDomains.ts）的修改：

- 只改镜像 `tools/bbcode-ts/src/` 下的 `.ts`，**禁止直接修改** `entry/src/main/ets/` 下被镜像的文件
  —— `npm run sync` 会把镜像目录整体机械覆盖回 `.ets`
- 镜像代码必须继续遵守 ArkTS 子集（见下方 ArkTS-syntax.md），否则同步回 `.ets` 后无法编译
- 标准流程：改镜像 → `npm test`（文本零丢失 + 官方渲染基准差分 + 快照回归）→ `npm run sync`
  回写 `.ets` → DevEco 编译 + Hypium（`entry/src/test/BBCodeUnit.test.ets`）最终门禁
- 「官方网页怎么渲染，解析器就怎么解释」是最高对齐标准，差异处理详见 `tools/bbcode-ts/README.md`

## 规则索引

ArkTS 语法编译约束 @.claude/rules/ArkTS-syntax.md
HarmonyOS API 及动画规范 @.claude/rules/HarmonyOS-development.md
