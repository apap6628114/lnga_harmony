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
  → ActiveAiService.chatCompleteWithActiveAiStream（流式 + 服务端联网搜索）
```

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
| 入口 | 页面 + 组件 | **帖子级动作**（全帖总结、收藏、离线保存…）放「更多」菜单 `moreMenuItems()`；标题栏入口走 `PanelNavBar`（见 §2）；楼层级入口走 `PostVoteBar` 的 `onSummarize` 一类的回调 |
| 组装 | `entry/src/main/ets/service/*.ets` | 取数 + 截断 + 拼提示词；**不调用模型** |

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

## 5. 验证门禁

1. `node scripts/check-eol.mjs`（LF 强制；注意仓库里 `oh-package-lock.json5` 是历史遗留违规，
   与本工程改动无关，不要去"顺手修"）。
2. `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` —— 输出「0 修改」才说明没有误改镜像文件。
3. 编译：`.dsh/skills/harmonyos-build-deploy`（**必须导出 `JAVA_HOME`**，否则 `PackageHap`
   报 `00308018 / spawn java ENOENT`；ArkTS 编译通过 ≠ 打包成功）。
4. 编译成功只证明能出 HAP。AI 功能的接线正确性要在设备/模拟器上按"未配置 AI → 门禁提示 →
   正常发起 → 覆盖范围文案与楼层数一致"逐项走一遍。
