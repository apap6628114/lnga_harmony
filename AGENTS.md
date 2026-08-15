# 基础规则

## 语言要求

- 思考过程（内部推理）必须使用中文
- 回答用户时必须使用中文
- 与用户的交流、解释说明一律使用中文

# 项目规则 — NGA OH (HarmonyOS ArkUI)

NGA 论坛客户端，stage 模型，API 7.0.0(26)，单 entry 模块。

> 本文档由 Claude Code 侧 `.claude/CLAUDE.md` 与 `.claude/rules/*.md` 迁移而来，规则文件已内联；
> 修改规则时注意与 Claude 侧对应文件双向同步。

## 构建与部署

工程依赖 DevEco Studio 内置工具链，项目根目录**无 `hvigorw` Wrapper**，须从安装目录调用。

编译验证、模拟器拉起、HAP 安装部署的完整流程见 skill：**`harmonyos-build-deploy`**（`.zcode/skills/harmonyos-build-deploy/`，`.zcode/skills` 为指向 `.claude/skills` 的 junction）。该 skill 不执行自动化测试；应用启动也仅在用户明确要求时进行。

核心要点：
- 环境变量：`export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"`
- Git Bash 路径保护：`export MSYS_NO_PATHCONV=1`
- 别名：`alias hvigorw="/c/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.bat"`
- 调试构建：`hvigorw assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon`
- 发布构建：将 `buildMode` 改为 `release`；清理：`hvigorw clean`

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
涵盖两部分：
- **BBCode 解释器**（`parser/bbcode/`）：JSON 模式楼层 content（BBCode 源文）的解析/渲染
- **HTML 模式解析器**（`parser/nga/html-thread/` + `parser/NgaJsonSanitizer.ts`）：
  read.php 静态 HTML → 与 JSON API 同形状的数据（以 JSON 为基准尽力还原，含热点回复）
  —— 修复/新增必须同步走镜像流程

凡涉及解析器、渲染器、NGA 域名常量（NgaDomains.ts）、html-thread 解析器的修改：

- 只改镜像 `tools/bbcode-ts/src/` 下的 `.ts`，**禁止直接修改** `entry/src/main/ets/` 下被镜像的文件
  —— `npm run sync` 会把镜像目录整体机械覆盖回 `.ets`（当前 30 个文件）
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

## ArkTS 语法约束

> 内联自 `.claude/rules/ArkTS-syntax.md`，修改时请同步回该文件。

以下规则违反将无法编译通过。

### 类型系统

- 不支持索引访问类型，请改用类型名称
- 不支持 `any` 和 `unknown` 类型，请显式指定类型
- 不支持 `as const` 断言，请改用字面量的显式类型标注
- 不支持条件类型别名，请显式引入带约束的新类型或使用 Object 重写逻辑；不支持 `infer` 关键字
- 不支持映射类型，请使用常规类实现
- 当前不支持结构化类型，请改用继承、接口或类型别名
- 仅在表达式上下文中支持 `typeof` 运算符，不支持使用 `typeof` 指定类型标注
- 不支持使用 `this` 关键字进行类型标注，请改用显式类型
- 交叉类型当前不支持，请使用继承作为替代方案
- 假定对象布局在编译时已知且运行时不可更改，因此删除属性的操作没有意义，可声明可空类型并赋值为 null
- 不允许索引签名，请改用数组
- 不允许接口包含两个具有不可区分签名的方法，避免接口扩展具有相同方法签名的其他接口

### 类与对象

- 不支持类字面量，请显式引入新的命名类类型
- 不支持将类用作对象（赋值给变量等），类声明引入的是新类型而不是值
- 不支持在构造函数中声明类字段，请在类声明内部声明类字段
- 不支持对象类型中的调用签名，请改用 class 来实现
- 不支持对象类型中的构造函数签名，请改用 class 来实现
- 不支持将对象字面量直接用作类型声明，请显式声明类和接口
- 支持对象字面量的前提是编译器可以推断出对应的类或接口，否则编译时报错
- 不支持重新分配对象方法，可创建单独的包装函数或使用继承
- 不支持动态字段声明和访问，也不支持通过索引访问对象字段（`obj["field"]`），请在类中立即声明字段并使用 `obj.field` 语法
- 不允许类初始化存在多个静态代码块，请合并到一块

### 函数

- 不支持函数表达式，请改用箭头函数
- 不支持嵌套函数，请改用 lambdas
- 不支持在函数上声明属性，因为不支持具有动态更改布局的对象
- 不支持在独立函数和静态方法中使用 `this`，`this` 只能在实例方法中使用
- 支持函数返回类型推断但受限，当 return 语句中的表达式是对返回类型被省略的函数或方法的调用时会发生编译时错误，请显式指定返回类型
- 当前不支持生成器函数，请使用 async/await 机制进行多任务处理

### 枚举

- 不支持枚举的声明合并，请保持每个枚举的声明紧凑
- 不支持使用在程序运行时评估的表达式初始化枚举成员，所有显式设置的初始化器必须是相同类型

### 运算符

- 仅支持 `+`、`-` 和 `~` 一元运算符作用于数字类型
- 不支持 `in` 运算符，请使用 `instanceof` 作为替代方案
- 不支持 `is` 运算符，请替换为 `instanceof`，使用对象字段前必须用 `as` 转换为适当类型
- 仅在 for 循环中支持逗号运算符

### 导入导出

- 所有 import 语句应在程序中所有其他语句之前
- 不支持 `export = ...` 语法，请改用普通的 export 和 import
- 不支持通过 `require` 导入，也不支持 import 赋值，请改用常规 import 语法
- 不支持导入断言，导入在 ArkTS 中是编译时特性
- 不支持模块名称中的通配符
- 不支持通用模块定义（UMD）
- 不支持环境模块声明，请从原始模块中导入所需内容

### 解构与展开

- 不支持解构赋值，请改用临时变量
- 不支持解构变量声明，请创建中间对象逐字段操作
- 不支持参数解构，请直接传递参数并手动分配局部名称
- 展开运算符仅支持将数组或派生自数组的类展开到 rest 参数或数组字面量中

### 标准库限制

- 不支持 `Function.apply`、`Function.call`、`Function.bind`，请遵循传统 OOP 风格处理 `this`
- 不支持 `Symbol()` API（Symbol.iterator 除外）
- 不支持 `new.target`
- TypeScript 扩展标准库中的实用类型仅支持 `Partial`、`Required`、`Readonly`、`Record`，其中 `Record<K, V>` 的索引表达式 `rec[index]` 类型为 `V | undefined`

### 其他

- 不支持声明合并，请保持类和接口的定义紧凑
- 不支持确定性赋值断言 `let v!: T`
- 不支持 `#` 开头的私有标识符，请改用 `private` 关键字
- 不支持 `var` 关键字，请改用 `let`
- 不支持 `with` 语句
- 不支持 `globalThis` 和全局作用域，请使用模块导出导入共享数据
- 不支持原型赋值，请使用类和接口
- 不支持通过 `for .. in` 循环遍历对象，数组请使用常规 for 循环
- 不支持 JSX 表达式
- 不支持接口中的构造函数签名，请改用方法
- 不支持 `as const` 断言
- 不支持函数表达式
- 如果数组字面量中至少有一个元素具有不可推断的类型，则会发生编译时错误
- 允许在函数调用时省略泛型类型参数（如果可从参数推断），但不支持仅基于返回类型推断
- 不支持将命名空间用作对象，请将类或模块解释为命名空间的类似物
- 不支持命名空间中的语句，请使用函数来执行语句
- TypeScript 代码库不得通过导入 ArkTS 代码库来依赖 ArkTS（反向导入支持）
- `catch` 子句变量请省略类型标注
- 不支持 `this` 关键字用于类型标注

## HarmonyOS API 使用规范

> 内联自 `.claude/rules/HarmonyOS-development.md`，修改时请同步回该文件。

- 优先使用 HarmonyOS 官方提供的 API、UI 组件、动画、代码模板
- API 调用前请确认遵循官方文档入参、返回值及对应 API Level 和设备支持情况
- 对于任何不肯定的语法和 API 使用，不要猜测或自行构造 API，请尝试使用搜索工具获取华为开发者官方文档并进行确认
- 使用 API 前请确认是否需要在文件头添加 import 语句
- 调用 API 前请确认是否需要对应权限，在对应模块的 `module.json5` 中确认权限配置
- 如需使用依赖库，请确认依赖库的存在和匹配版本，并在对应模块的 `oh-package.json5` 中添加依赖配置
- 使用 `@Component` 和 `@ComponentV2` 时需要区分兼容性，尽量与已有工程代码保持一致
- UI 界面展示引用的常量需要定义 resources 资源值，并使用 `$r` 引用，一般不直接使用字面值
- 新增国际化资源字符串时在对应的国际化每种语言下添加值，避免遗漏
- 新增颜色等资源请确认是否需要添加黑色主题支持（参考历史工程），新工程建议默认支持黑色及白色主题

### ArkTS 疑难处理

当处理或使用 ArkTS 时，如遇到不确定的语法、API 用法，或用户报告了编译/运行错误，必须积极通过网络搜索工具查阅华为开发者官方文档，确认正确的 ArkTS 使用方式，而非凭经验猜测

### ArkUI 动画规范

- 优先使用 HarmonyOS 提供的原生动画 API 和高级模板
- 优先使用 HarmonyOS 的声明式 UI 和 `@State` 驱动动画，通过改变状态变量触发动画
- 对于包含复杂子组件的动画，将其设置为 `renderGroup(true)`，减少渲染批次
- 不可以在动画过程中频繁改变组件的 `width`、`height`、`padding`、`margin` 等布局属性，严重影响性能
