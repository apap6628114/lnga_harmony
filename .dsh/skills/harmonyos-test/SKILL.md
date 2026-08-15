---
name: harmonyos-test
description: 为 HarmonyOS/ArkTS 项目编写、审查和运行 entry/src/test 下的 Hypium Local Test，覆盖回归用例、解析器与格式化器语义、测试注册、ArkTS 兼容性、结果判定及本地测试故障诊断。用户要求“写测试”“补单测”“增加回归覆盖”“运行 Hypium”“检查 src/test”或验证纯 ArkTS 逻辑时使用。允许自动执行 Hypium Local Test；禁止 UI 自动化、src/ohosTest、onDeviceTest、HDC 调试、模拟器交互、安装和启动应用。
---

# HarmonyOS Hypium Local Test

把功能需求和已修复缺陷转化为稳定、可读、能定位回归原因的 `entry/src/test` 测试，并通过 Hypium 实际执行验证。

## 能力边界

严格区分三类验证：

| 验证方式 | 本 Skill 是否执行 | 能证明什么 |
|---|---:|---|
| Hypium Local Test（`entry/src/test`） | 是 | 纯 ArkTS 代码执行结果符合断言 |
| HAP 编译 | 仅作为 Local Test 管线的一部分 | 测试及其依赖能够编译 |
| UI、真机、模拟器 HDC 调试 | 否 | 不属于本 Skill |

执行以下规则：

- 创建或修改 `entry/src/test` 内的 `*.test.ets`、测试辅助代码和 `List.test.ets`。
- 完成测试代码修改后，默认运行完整 Hypium Local Test；用户明确要求不运行时除外。
- 用户只要求运行 Hypium 时，不修改代码；先执行并报告真实结果。
- 不创建或恢复 `entry/src/ohosTest`，不执行 `onDeviceTest`、UiTest 或设备测试。
- 不调用 `hdc`，不拉起模拟器，不安装 HAP，不启动或自动操作应用。
- 测试失败只授权诊断，不自动修改生产代码；只有用户同时要求修复时才实施修复。
- 不把“编译成功”“测试页面启动”或“应用能够运行”表述为测试通过。

## 工作流

### 1. 建立行为契约

先阅读目标实现、调用方、相关模型和相邻测试。把需求拆成可观察结果，每个结果至少对应一个用例。

优先覆盖：

1. 核心正常路径。
2. 用户报告缺陷的最小复现。
3. 空值、单元素、重复输入及合法边界。
4. 非法或不完整输入的降级行为。
5. 嵌套、组合和跨边界交互。
6. 修复容易误伤的相邻既有行为。

不要用多个近似用例堆数量。让用例名直接表达唯一行为，例如 `continuesInlineStyleAcrossImageBlock`。

### 2. 判断是否适合 Local Test

优先测试确定性的纯 ArkTS 行为：

- 解析器、格式化器、转换器和规范化函数。
- 状态机、策略函数、集合变换和缓存语义。
- 不访问真实系统资源的 Store 内存行为。
- 缺陷修复后的输入与输出契约。

不要把下列行为伪装成 Local Test：

- ArkUI 最终视觉效果和组件生命周期。
- 权限弹窗、文件选择器、媒体、网络可用性和设备能力。
- 真机性能、手势、滚动、动画和系统兼容性。
- 依赖 HDC 或模拟器人工调试才能观察的行为。

若生产逻辑与系统依赖耦合，优先寻找已有纯函数边界。只有当前功能任务允许修改生产代码时，才提取可测试逻辑；不要仅为测试擅自重构业务架构。

### 3. 选择测试位置并完成注册

- 同一领域已有测试文件时，在原文件对应的 `describe` 中补充用例。
- 新领域创建 `<Feature>Unit.test.ets`，默认导出一个测试注册函数。
- 在 `entry/src/test/List.test.ets` 中导入并调用新注册函数，且只注册一次。
- 保持测试套件名称稳定，以便从 `test_result.txt` 定位回归。

基础结构：

```typescript
import { describe, expect, it } from '@ohos/hypium'
import { ResultModel } from '../main/ets/model/ResultModel'
import { transformValue } from '../main/ets/common/utils/ValueUtils'

/**
 * 注册值转换回归测试。
 */
export default function valueUnitTest(): void {
  describe('valueTransform', (): void => {
    it('preservesMeaningAcrossBoundary', 0, (): void => {
      const result: ResultModel = transformValue('输入')

      expect(result.text).assertEqual('输入')
      expect(result.isValid).assertTrue()
    })
  })
}
```

把示例类型和路径替换为项目真实声明，不要为了套模板创建虚假 API。

### 4. 遵守 ArkTS 测试代码约束

读取并遵守 `entry/src/AGENTS.md` 的「ArkTS 语法约束」章节和项目根级规范。

- 使用显式类型和 `const`；禁止 `any`、`unknown`、忽略指令和确定性赋值断言。
- 为新增类、成员、函数、枚举、类型和接口编写 JSDoc。
- 不在新增 `.ets` 代码中使用 `//` 单行注释。
- 为测试注册函数声明 `void`，为异步用例声明 `Promise<void>`。
- 使用真实领域类型，不用宽泛的 `object` 代替已知模型。
- 只有解析器边界确实接收原始对象时，才把 JSON 字符串经 `JSON.parse` 赋给显式 `object` 或 `Object` 类型。
- 不直接传入无法推断类型的 `{}` 或嵌套对象字面量；使用具名类、接口、明确上下文类型或 `JSON.parse` 边界数据。
- 不共享可变用例数据，不依赖用例执行顺序。
- 不使用真实时间、随机数、网络或磁盘状态作为断言条件。

异步用例必须返回等待链：

```typescript
it('loadsStateBeforeAssertion', 0, async (): Promise<void> => {
  const result: ResultModel = await loadResult()

  expect(result.isValid).assertTrue()
})
```

不要启动未等待的 Promise；否则 Hypium 可能在异步断言完成前结束用例。

### 5. 设计高价值断言

- 先断言集合长度或节点类型，再访问固定下标。
- 同时断言内容和关键元数据，例如链接地址、继承样式、作者 ID 和分页状态。
- 对枚举使用枚举成员，不比较魔法数字。
- 优先断言公开语义，不锁死无关内部字段。
- 不用整棵对象 JSON 快照替代有含义的断言。
- 一个用例可以包含多条共同证明同一行为的断言，但不要混入第二个独立行为。
- 为缺陷保留最小复现，再补一个相邻反例，防止修复过度。

## BBCode、解析器与格式化器测试模式

参照 `entry/src/test/BBCodeUnit.test.ets` 分层验证：

1. 词法辅助函数：断言位置、大小写和边界结果。
2. 解析结构：断言根节点数、`BBNodeType`、子节点和关键字段。
3. 显示语义：通过 `flattenInlineNodes` 断言文字、`InlineRunKind`、链接和最终继承样式。
4. 块级中断：验证图片、段落、引用等块前后的格式是否正确延续或结束。
5. 容错：覆盖未知标签、未闭合标签、交叉闭合、非法属性和大小写变体。
6. 规范化：覆盖 HTML 实体、换行、颜色、字号、字体、上下标和 CSS 白名单。

性能优化测试只保护语义等价，不在普通 Local Test 中加入毫秒耗时阈值。需要性能测量时使用独立基准，避免机器负载导致不稳定失败。

## 运行 Hypium Local Test

测试代码完成后，在项目根目录执行完整测试：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' test -p module=entry -p coverage=false --no-daemon
```

若本机路径不同，先只读检查 DevEco Studio 和 SDK 的实际位置，不猜测或修改系统配置。

`--no-daemon` 用于让本次 Hvigor 入口在完成后退出；不要因此终止 DevEco Studio 已有的普通后台守护进程。

### 判定测试结果

同时满足以下条件才可以报告“测试通过”：

1. 命令退出码为 `0`。
2. 本次运行完成了 `GenerateUnitTestResult`。
3. `entry/.test/default/intermediates/test/coverage_data/test_result.txt` 的修改时间属于本次运行。
4. 结果汇总中的 `Failure` 和 `Error` 都为 `0`。

读取正式结果：

```powershell
Get-Content -LiteralPath 'entry\.test\default\intermediates\test\coverage_data\test_result.txt'
```

不要只依据 `BUILD SUCCESSFUL` 下结论。必须报告：

- Tests run
- Pass
- Failure
- Error
- Ignore
- 与当前任务直接相关的测试套件及用例数量

如果 ArkTS 编译阶段失败，应明确写“测试未执行”，不要把编译错误计为用例失败。

## 诊断 Local Test 故障

按阶段定位，不盲目反复运行。

### ArkTS 编译失败

优先检查：

- 无类型 `{}` 或嵌套对象字面量。
- 不受支持的 TypeScript 语法。
- 新文件未注册或 import 路径错误。
- 异步回调返回类型不明确。
- 测试数据与实现边界类型不匹配。

修复测试夹具的类型表达，不改变测试原本要验证的语义。

### 测试启动后异常或挂起

检查本次日志尾部：

```powershell
Get-Content -LiteralPath 'entry\.test\default\intermediates\test\coverage_data\coverage.log' -Tail 250
```

优先查找首个 `ReferenceError`、`uncaught exception` 或 `Cannot execute module`。Local Test 会初始化导入模块图；即使某个系统 API 没被用例直接调用，循环依赖或模块顶层副作用也可能在用例开始前导致测试页面崩溃。

典型循环依赖形态：

```text
Store -> Api -> AppStore -> Store
```

遇到此类问题时：

- 记录完整依赖链和首个异常位置。
- 不用延长超时掩盖模块初始化错误。
- 未获得修复生产代码的授权时，只报告根因和建议。
- 已获得修复授权时，优先抽离无业务依赖的最小服务或纯数据注册表，保持原有持久化和请求语义。

若异常退出遗留 `Previewer.exe`，先核对进程命令行确实包含当前项目的 `entry\.test` 路径，再只终止该精确进程。禁止按进程名批量终止 Node、Java、Hvigor 或 DevEco Studio 进程。

### 结果文件缺失

把缺失视为“测试没有完成”，而不是“零失败”。核对：

- `coverage.log` 是否停止更新。
- 是否存在运行时未捕获异常。
- Hvigor 测试进程或 Previewer 是否仍然存在。
- 读取到的结果文件是否是上一次运行遗留的旧文件。

## 完成前审查

- 每项需求至少有一个直接用例。
- 缺陷最小复现和相邻反例均已覆盖。
- 新文件已在 `List.test.ets` 注册一次。
- import、类型、JSDoc 和 ArkTS 语法符合规范。
- 没有引入真实网络、设备状态、UI 自动化或不稳定时间断言。
- Hypium 已实际执行，或用户明确要求跳过执行。
- 结论来自本次 `test_result.txt`，不是旧报告或编译状态。

## 交付格式

向用户说明：

1. 修改了哪些测试文件及注册状态。
2. 新增用例分别保护哪些行为。
3. Hypium 的完整统计和相关套件统计。
4. 测试管线耗时与用例执行耗时，二者不要混淆。
5. 哪些 UI、设备和真机行为不在 Local Test 覆盖范围内。
6. 若未运行，明确说明原因，绝不声称用例通过。

需要单纯编译 HAP、拉起模拟器或安装应用时改用 `harmonyos-build-deploy`；不要把该 Skill 扩展为 UI 自动化或 HDC 调试流程。
