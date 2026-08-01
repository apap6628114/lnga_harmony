---
name: harmonyos-test
description: 为 HarmonyOS/ArkTS 功能编写和审查 entry/src/test 下的 Hypium Local Test，覆盖行为矩阵、回归用例、解析器与格式化器语义断言、测试注册及 ArkTS 兼容性。用户要求“写测试”“补单测”“增加回归覆盖”或为新功能设计 Local Test 时使用；只生成或修改测试代码，不自动运行 hvigor、设备测试、模拟器或应用。
---

# HarmonyOS Local Test 编写

把功能需求和已修复缺陷转化为稳定、可读、能定位回归原因的 `entry/src/test` 测试代码。优先验证公开行为和语义结果，不依赖 UI 截图、真机时序或实现细节。

## 强制执行边界

- 只读取实现与现有测试，并创建或修改 `entry/src/test` 内的 `*.test.ets`、测试辅助代码及 `List.test.ets`。
- 不把 Local Test 改写到 `entry/src/ohosTest`；设备测试属于另一个显式任务。
- 本 Skill 不具备测试执行能力，禁止调用 `hvigorw`、`hdc`、`onDeviceTest`、模拟器、安装命令或启动应用。
- “写测试”“补测试”“增加覆盖”“验证点补齐”只授权编写测试，不代表授权执行测试。
- 未执行时必须明确写“测试代码已编写，按约束未运行”，不得宣称用例通过。
- 不因已有测试可能失败而顺手修改无关测试；发现问题时单独报告。

## 工作流

### 1. 建立行为契约

先阅读目标实现、调用方、相关模型及相邻测试。把需求拆成可观察结果，每个结果至少对应一个用例。

优先选择以下用例：

1. 核心正常路径。
2. 用户报告问题的最小复现。
3. 边界输入：空值、单元素、最大/最小合法值、重复输入。
4. 非法或不完整输入的降级行为。
5. 嵌套、组合及跨边界交互。
6. 修复容易影响的既有行为。

不要用多个几乎相同的用例堆数量。每个用例名称应准确表达唯一行为，例如 `continuesInlineStyleAcrossImageBlock`。

### 2. 选择测试位置

- 同一领域已有测试文件时，在原文件的同一 `describe` 中补充用例。
- 新领域创建 `<Feature>Unit.test.ets`，默认导出一个注册函数。
- 新测试文件必须在 `entry/src/test/List.test.ets` 中导入并调用，否则不会进入测试套件。
- 只测试可在 Local Test 运行的纯 ArkTS 逻辑。依赖系统 API、ArkUI 生命周期、权限、网络或设备状态的行为不应伪装成本地单元测试。
- 若逻辑与系统依赖耦合，优先测试已有纯函数边界；只有功能任务本身允许时才提取纯逻辑，不为测试擅自重构生产代码。

### 3. 编写 ArkTS 兼容测试

遵守项目 `.claude/rules/ArkTS-syntax.md` 和根级开发规范：

- 使用显式类型、`const`、具名类或接口；禁止 `any`、忽略指令和无类型对象字面量。
- 所有新增声明性代码写 JSDoc；新增 `.ets` 代码不写 `//` 单行注释。
- 测试函数声明返回 `void`，回调在可行处显式声明 `(): void`。
- 使用 `BBNode[]`、`InlineRun[]` 等领域类型，不用宽泛的 `object` 代替已知模型。
- 原始 JSON 测试数据优先由字符串经 `JSON.parse` 得到，再赋给实现接受的显式边界类型。
- 不共享可变用例数据。确需修改全局状态时使用 `beforeEach`/`afterEach` 恢复，但不要引入无意义的空钩子。
- 不使用真实时间、随机数、网络、磁盘状态或用例执行顺序作为断言条件。

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

示例中的类型和路径必须替换为项目真实声明，不要为了套模板创建虚假 API。

### 4. 设计高价值断言

- 先断言集合长度或节点类型，再访问固定下标，令失败原因清晰。
- 同时断言内容与关键元数据，例如链接地址、继承样式、作者 ID、分页状态。
- 对枚举使用枚举成员比较，不比较魔法数字。
- 优先断言外部语义；除非内部结构就是公共契约，否则不要锁死全部对象字段。
- 不使用整棵对象 JSON 快照替代有含义的断言。快照会让无关字段变化掩盖真正回归。
- 一个用例可以包含多条共同证明同一行为的断言，但不要混入第二个独立行为。

## BBCode、解析器与格式化器模式

参照 `entry/src/test/BBCodeUnit.test.ets` 分层验证：

1. 词法辅助函数：直接断言位置、大小写和边界结果。
2. 解析结构：断言根节点数、`BBNodeType`、子节点和关键字段。
3. 显示语义：通过 `flattenInlineNodes` 断言文字、`InlineRunKind`、链接和最终继承样式。
4. 块级中断：验证图片、段落、引用等块前后的格式是否正确延续或结束。
5. 容错：覆盖未知标签、未闭合标签、交叉闭合、非法属性和大小写变体。
6. 规范化：覆盖 HTML 实体、换行、颜色、字号、字体、上下标及 CSS 白名单。

为已修复问题保留最小复现用例，再补一个相邻反例，防止修复过度。例如测试“合法样式跨图片延续”时，同时验证“非法样式不会跨块复制”。

不要在 Local Test 中加入毫秒耗时阈值。性能优化应通过语义等价用例保护结果；如需性能测量，等待用户另行明确授权并采用独立基准。

## 审查清单

完成修改前静态检查：

- 每项需求是否至少有一个直接用例。
- 缺陷最小复现是否已固化。
- 是否包含可能被修复误伤的相邻反例。
- 新文件是否已在 `List.test.ets` 注册且只注册一次。
- import 是否真实存在且路径、大小写正确。
- 新声明是否有 JSDoc，类型是否符合 ArkTS 限制。
- 是否错误引入系统 API、UI 组件、真实网络或不稳定时间断言。
- 是否在没有运行的情况下使用了“通过”“成功”等结论。

## 交付格式

向用户说明：

1. 修改了哪些测试文件及是否完成注册。
2. 新增用例分别保护什么行为。
3. 哪些设备/UI 行为不属于 Local Test 覆盖范围。
4. 明确标注“按约束未自动运行测试”。

测试执行不属于本 Skill 的能力范围。需要确认工程能否编译或部署时，只能使用 `harmonyos-build-deploy`，且不得借此运行任何测试用例。
