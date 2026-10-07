---
name: nga-ai-scenario
description: 在本工程新增或改造 AI 功能（新场景、新入口、新的注入数据组装）时使用。覆盖「场景配置 → 设置页注册 → 页面入口 → 取数与提示词组装」四层链路的完整改动点、ArkTS/ArkUI 编译红线与验证门禁。不负责模型调用本身（那仍是 AiChatPage → ActiveAiService 的既有链路），也不负责 NGA 取数层（见 nga-data-fetch）。
---

# AI 场景与入口扩展

所有 AI 功能共用一条链路，**新增功能只允许在既有链路上扩点，不得另起第二条调用路径**：

```text
入口（页面）
  → 组装提示词（service/，纯取数 + 拼文本）
  → router.pushUrl('pages/ai/AiChatPage', { initialPrompt, title, scenario })
  → AiChatPage 取 appStore.settingsStore.getScenarioPrompt(scenario)
  → ActiveAiService.chatCompleteWithActiveAiStream（流式）
  → AiProviderRouter.streamChatCompletion（按 profile.providerId 分流协议）
      ├─ ResponsesApiClient      DeepSeek /responses，可带服务端内置联网搜索
      └─ ChatCompletionsClient   其余服务商，OpenAI 兼容 chat/completions
```

**调用链只此一条**：页面/服务不要直接 import `ResponsesApiClient` 或
`ChatCompletionsClient`，协议分支只存在于 `AiProviderRouter`（见 §5.1）。

**另有一类「就地取结果」的场景不跳 AiChatPage**（如智能去水的「按本帖主题生成规则」）：
结果是一段要被程序解析的 JSON、不展示对话过程，因此由自己的 `service/` 直接调
`chatCompleteWithActiveAiStream` 并只取最终文本。**唯一 AI 通道不变**，但要自己承担
下面三件事（见 §6）：

- 门禁：复用 `getActiveAiValidationMessage()`，空串才发起；
- 取消：自建 `RequestCanceller` 传给通道，并在构件 `aboutToDisappear` 里 `cancel()`
  —— 不取消会留下无人接收的回调；
- 输出按**不可信输入**防御性解析，任何一条不合格就丢掉那一条，不抛异常打断主流程。

场景（`scenario`）是这条链路里唯一的扩展键：它决定注入哪个 system prompt。
取数与拼装必须下沉到 `service/`，页面只留门禁、状态与路由——参照
`service/ThreadSummaryService.ets` 与 `pages/ThreadPanel.ets` 的
`summarizeThread()` / `cancelThreadSummary()` / `SummaryProgressOverlay()` 三分法。

## 1. 改动点清单（缺一处就会静默少一个环节）

| 层 | 文件 | 要改什么 |
| --- | --- | --- |
| 场景定义 | `entry/src/main/ets/model/AiScenarioConfig.ets` | `AiScenario` 加枚举值；`SCENARIO_META`（设置页卡片标题与描述）；`DEFAULT_SYSTEM_PROMPTS`（默认 prompt）；`SCENARIO_INJECTED_FIELDS`（设置页「注入数据」预览，只读展示） |
| 设置页 | `entry/src/main/ets/pages/ai/AiSettingsPanel.ets` | `ScenarioSection()` 里加一张 `this.ScenarioCard(AiScenario.XXX)`；`scenarioIcon(scenario)` 加图标分支 |
| 图标资源 | `entry/src/main/resources/base/media/icon_*.svg` | 每个场景一个**语义独立**的 SVG，`fill="#000000"` 交给 `.fillColor()` 着色（只需 base，无需 dark 变体） |
| 入口 | 页面 + 组件 | **帖子级动作**（全帖总结、收藏、离线保存…）放「更多」菜单 `moreMenuItems()`；标题栏入口走 `PanelNavBar`（见 §2）；楼层级入口走 `PostVoteBar` 的 `onSummarize` 一类的回调。**「就地取结果」类场景（§5）没有独立入口**——它是某个功能的内部一步，这一行留空即可，但场景定义 / 图标 / 设置页卡片**仍然要配**（用户得能编辑它的 prompt） |
| 组装 | `entry/src/main/ets/service/*.ets` | 取数 + 截断 + 拼提示词；**不调用模型**（就地取结果类才允许在同一层继续调通道取结果 + 解析） |

`SCENARIO_META` / `DEFAULT_SYSTEM_PROMPTS` / `SCENARIO_INJECTED_FIELDS` 是 `Record<string, …>`，
漏配任一项的表现分别是：设置页 `SCENARIO_META[scenario].name` 读到 `undefined`、
`getScenarioPrompt` 返回空串（**system prompt 静默丢失，AI 表现为"不听话"**）、
注入数据预览 `ForEach` 遍历 `undefined`。

## 2. 入口位置的选型（先选位置，再选组件）

**帖子级 / 页面级动作优先放「更多」菜单**（`moreMenuItems()` 返回的 `NavBarMenuItem[]`），
与同类动作并列、可发现性最好。菜单项是**纯文字**（只有 `label` / `active` / `action`，
没有图标字段），所以这类入口**不需要**新增 SVG 资源。

标题栏的次按钮只留给"必须常驻可见"的动作——目前 Thread 页只有一颗 more 按钮。
**不要给一个本该进菜单的功能额外挂标题栏图标**：多挂一颗语义不明显的图标既挤占滚动收起
动画的位置，也不比菜单项更容易被发现。

## 2.1 标题栏入口（PanelNavBar）的既定用法

- **纯动作**（点击直接执行，不带菜单）→ `secondaryRightIcon` + `secondaryRightIconAccessibilityText`
  + `onSecondaryRightClick`。排布是「主按钮在左、次按钮在右」，因此次按钮落在最右端。
- **带菜单** → `hasMenu: true` + `menuItemsProvider: (): NavBarMenuItem[] => this.xxx()`，
  菜单锚点默认是主按钮（`rightIcon`）。**菜单必须锚在一颗真实按钮上**：挂到标题栏整体
  或多列路由的外层容器上，菜单会被算到窗口左侧。
- 已有主按钮 + 菜单时再加动作按钮：`menuOnSecondary` 保持 `false`，让菜单继续锚在原来的
  主按钮上；**不要**为了"让主按钮留在最右"去改 `PanelNavBar` 的排布逻辑。
- 回调里一律用**箭头函数**；`@Prop` 不允许装饰 Function 类型，菜单项因此以"提供者"
  （`menuItemsProvider`）形式传入，而不是 `@Prop menuItems: NavBarMenuItem[]`。

## 3. ArkTS / ArkUI 编译红线（本次实际踩到的）

- **`Column` 没有 `alignContent`**：`alignContent` 只存在于 `Stack` / `RelativeContainer`。
  全屏浮层要写 `Stack() { … }.width('100%').height('100%').alignContent(Alignment.Center)`。
  报错形态：`Property 'alignContent' does not exist on type 'ColumnAttribute'`。
- 纯类型（`interface` / 只作标注的 `type`）用 `import type { … } from '…'` 单独一行，
  不要混进值导入：`import { fetchThreadRaw } from './api/ThreadApi'` +
  `import type { ThreadRawResult } from './api/ThreadApi'`。
- hilog 占位符必须是 `%{public}s` / `%{public}d`，写 `%s` 不会插值。
- 无对象字面量类型推断、无解构、无 `for...in`、无 `any`；`catch` 变量省略类型标注；
  数组/对象一律用 `class` 声明（见 `entry/src/AGENTS.md`）。
- 长内容取纯文本走 `bbNodesToPlainText(getCachedBBNodes(content))`；批量时先
  `preWarmBatchAwait(contents)`（taskpool）再取，避免主线程同步解析。解析缓存是
  `LruCache(150)`，**按页分批**（约 20 层）预热即可，别一次灌几百层把渲染侧缓存冲掉。
- **`SelectDialog` 的 `SheetInfo.action` 是「选项被选中时」触发**（SDK
  `component/action_sheet.d.ts:65` 原文 "Callback when the sheet is selected"，类型
  `VoidCallback`），`confirm?: ButtonOptions` 另有独立的按钮回调
  （`@ohos.arkui.advanced.Dialog.d.ets:91` 的 `action?: () => void`）。由此两条硬规则：
  1. **不要传 `selectedIndex`**（它本身可选，见 `.d.ets:641`）：预选中某项后，点中
     「已是选中态」的那一项不产生选中变化 → 回调不触发 → 表现为「选了没反应」。
     服务商列表只有一项且被预选时，整个「添加 AI 服务」入口就是这么点不动的。
  2. **落地动作挂选项回调**，不要只挂 `confirm.action`——那样用户必须再按一次
     「确定」，选择后没有任何即时反馈。
  工程内已验证的用法：`SettingsPanel` 的「帖子楼层导航 / 预加载页数 / 图片加载模式」
  三个单选框都是「选项回调直接落地 + `confirm: { value: '确定' }` 无 action」。
- **创建类入口（"点一下就必须出现表单"）不要依赖对话框回调**：把它做成页内动作，
  平台/类型选择退化为表单里的一行。`AiSettingsPanel.startNewProfile()` 就是这么改的
  （点「+ 添加 AI 服务」直接展开新建卡片 + 套用首选预设，不经过任何弹窗）。
  一次回调语义判断失误就能让整个入口彻底不可用，而页内动作没有这种风险——
  能力缺失可以提示，功能入口不能用不了。

## 4. 跨页取数的约定（需要"全部楼层"一类全量语义时）

- 顺序请求 + 页间节流（`PAGE_FETCH_INTERVAL_MS = 300`），复用调用方已加载的窗口避免重复请求；
  参考 `SavedThreadService.saveThread` 与 `ThreadSummaryService.buildSummaryPrompt`。
- **硬上限 + 如实说明**：页数上限、字符预算、单条长度上限都要有，截断情况必须写进提示词
  （让模型知道数据不完整），不得在截断后仍宣称"已全部纳入"。
- **单页失败只跳过该页**并记 warn，不要让整批失败。
- **筛选视图不是全量**：调用方处于「只看楼主」这类筛选态时，窗口内不是全帖，
  必须按空窗口重新取数（或在参数契约里显式要求传空数组）。
- 任务是模块级单例（`export const xxxService = new XxxService()`），不随组件销毁结束：
  **页面销毁与切目标都必须显式 cancel**，并用独立的任务代际让在途回调失效；
  不要借用 `ThreadPaginationManager.getGeneration()`（那是窗口事务的代际，语义不同）。
- 进度反馈优先做**页内浮层**：只有"用户可能离开发起页仍需看到进度"（如 `savedThreadProgress`
  的离线保存）才做全局进度发布器 + `MainPage` 挂载的指示组件。

## 5. 「就地取结果」类场景的红线

适用形态：结果是**要被程序解析的结构化数据**（JSON 规则 / 标签 / 分类），
而不是给用户读的一段话。代表：智能去水的「按本帖主题生成规则」。
`service/WaterFilterAiRulesService.ets` 是可直接照抄的样板。

- **复用唯一通道**，不另开 HTTP：`chatCompleteWithActiveAiStream(messages, onDelta, …)`，
  `onDelta` 传空函数（一次性取 `result.text`）。
- **提示词契约三处同步**：默认 system prompt（`AiScenarioConfig`）、解析器、
  设计文档。用户可能已自定义过该场景的 prompt，格式不认识时解析器要按「没拿到结果」
  降级，**不得抛异常打断主流程**。
- **解析是纯函数**、逐条防御、不抛异常：截 JSON 子串（定位第一个 `{` 到最后一个 `}`，
  别匹配 ```json 前缀）→ 校验每个字段 → 归一化 → 去重 → 限条数。把最危险的坏数据
  写成显式规则丢掉（如「单字关键词的包含规则会命中大量正常文本」），并在 prompt 里
  也明令禁止——两道防线，因为模型输出不可信。
- **结果只归调用方本次使用**：若它依赖当前上下文（帖子主题、当前用户），
  就**不要落盘成全局配置**，否则换个上下文就是误伤。用回调把结果交回发起方。
- **门禁要区分两类可用性**：AI 不可用只提示、不阻断主功能（本地判定不依赖模型）；
  但**结果还在生成中时必须拦使用入口**（用户点了"开始"却用不上刚生成的结果，
  比不用 AI 更糟）。
- 取消：`RequestCanceller` 交给通道，构件 `aboutToDisappear` 里 `cancel()`。
- **联网搜索必须显式关**：这类场景的输入已被完整注入（帖子正文/上下文），
  输出又是纯 JSON，联网只会拖慢速度并引入无关内容。调用通道时把最后一个
  参数 `allowWebSearch` 传 `false`。

## 5.1 多服务商与能力降级

模型调用面已从「只支持 DeepSeek」恢复为多服务商。**新增/替换服务商只改一处**：
`entry/src/main/ets/service/ai/AiModelPresets.ets` 的 `PROVIDER_PRESETS`
（id / 名称 / 端点 / 默认模型 / `protocol` / `supportsWebSearch` / 说明 / API Key 占位），
调用链一行都不用动。

- `AiProviderProfile` 用 `providerId` 关联预设，决定协议与能力；`endpoint` 是**真实值**
  （预设端点会写进配置且允许用户改），不再是"忽略配置里的端点"。
- 平台切换的唯一入口是**表单里的** `AiSettingsPanel.ProviderPickerRow()`（不是
  「新建前置弹窗」），新建与编辑共用——这样新建无需任何弹窗回调、已建配置也能换平台。
- **历史配置没有 `providerId`**（DeepSeek-only 时期保存的），读的时候必须过
  `resolveProviderId()` 归一化，直接读字段会拿到 `undefined` —— 反序列化是
  `profiles.push(saved.aiProfiles[i])`，**不会走 class 默认值**。
- 两个协议的能力差异必须**显式告知而非静默降级**：
  - 设置页：表单内联提示（`AiSettingsPanel.ProviderCapabilityNotice()`）、卡片副标题
    （`getProfileSubtitle()`）；
  - 对话页：输入栏上方一行 `getActiveAiCapabilityNotice()`。
  文案统一由 `getCapabilityNotice(providerId)` 产出（空串表示能力完整），
  不要在各处另写一份措辞。
- 类型（`ChatMessage` / `RequestCanceller` / 流式回调 / `AiCompletionResult`）住在
  `service/ai/AiChatTypes.ets`。**两个客户端谁都不许 import 对方**，否则成环；
  新增协议客户端时也只依赖这个中立模块。
- 只有 `ResponsesApiClient` 支持服务端内置联网搜索；chat/completions 侧不下发
  任何 `tools`，`onSearch` 回调不会被触发，UI 不能靠"有没有回调"来判断能力。

## 6. 验证门禁

1. `node scripts/check-eol.mjs`（LF 强制；注意仓库里 `oh-package-lock.json5` 是历史遗留违规，
   与本工程改动无关，不要去"顺手修"）。
2. `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` —— 输出「0 修改」才说明没有误改镜像文件。
3. 编译：`.dsh/skills/harmonyos-build-deploy`（**必须导出 `JAVA_HOME`**，否则 `PackageHap`
   报 `00308018 / spawn java ENOENT`；ArkTS 编译通过 ≠ 打包成功）。
4. 编译成功只证明能出 HAP。AI 功能的接线正确性要在设备/模拟器上按"未配置 AI → 门禁提示 →
   正常发起 → 覆盖范围文案与楼层数一致"逐项走一遍。**AI 配置页（`AiSettingsPanel`）
   还必须真机走一遍「+ 添加 AI 服务 → 表单立刻出现 → 换平台 → 填 Key → 保存」**：
   弹窗回调语义与表单可见性都属于编译与静态检查发现不了的盲区（"点了没反应"已经
   发生两次）。换到不支持联网搜索的服务商后，要能看到设置页与对话页各一处提示文案，
   且对话本身照常可用。
