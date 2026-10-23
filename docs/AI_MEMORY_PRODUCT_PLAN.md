# AI 工作记忆预算：产品化优化方案

> 状态：**已实施，并在第二轮按「效果优先」重构**。核心转变：上下文是效果资源，不是成本项。
> 现在的形态是「窗口用满 → 95% 才压缩 → 生成式四段记忆 → 最近 4 轮原文不动」。
> 基线为 `docs/AI_MEMORY_DESIGN.md` §4 的 L0 上下文预算。
> 本文只讨论「L0 如何从工程实现变成产品能力」；L1 及以上见该文档 §6。

## 0. 一句话结论

现在的 L0 是**请求侧的一个静默裁剪函数**，不是用户能感知的记忆能力。产品化要做三件事：

1. **真源换位**：预算从代码常量搬到「模型配置」——用户看得见、改得动；
2. **计量换对象**：从「历史消息窗口」扩到「整轮上下文水位」——因为吃预算的是工具结果；
3. **压缩换语义**：从「丢原文 + 警告模型」改为「沉淀要点 + 原文可回看」——折叠是记忆，不是丢弃。

三者之上再补三个**用户手势**：看见进度、调整档位、干预裁剪（钉住 / 重看 / 记住）。

## 1. 现状诊断：五个错位

### 1.1 真源错位：预算是常量，不是配置

| 证据 | 位置 |
| --- | --- |
| `DEFAULT_HISTORY_TOKEN_BUDGET = 24000` 写死 | `service/ai/ContextBudget.ets:22` |
| 调用处直接传常量，`profile` 不参与 | `service/ai/ActiveAiService.ets:225` |
| 模型窗口其实已经抓到了，却只用于展示 | `service/ai/AiEndpoint.ets:164`、`pages/ai/AiSettingsPanel.ets:1097` |

同一个 App 里，「模型窗口多大」和「该给多少历史」是两套互不相干的世界。

后果：
- 8K / 16K 窗口的模型，24000 预算**必然超窗**，表现为 400 或回答被截断；
- 128K / 200K 窗口的模型只用到约 19% / 12%，用户付了长上下文模型的钱，体验上仍然是"聊十轮就忘"。

### 1.2 计量对象错位：吃预算的不是历史，是工具结果

`fitHistoryToBudget` 只处理页面传进来的 `messages`；Agent 循环里追加的 **`tool` 消息完全不经过任何预算**：

```ts
// service/ai/AiAgentRunner.ets:217-220
const toolMsg: ChatMessage = new ChatMessage('tool', toolResult.content)
toolMsg.toolCallId = call.id
toolMsg.name = call.function.name
conversation.push(toolMsg)      // ← 体量不设上限
```

而 `toolChars` 只做日志统计（`AiAgentRunner.ets:123 / 213 / 230`）。`nga_read_thread` 一次读一页 20 楼，正文量级是万字符以上——单次工具结果就足以吃掉整个 24000 预算。

后果有两层：
- **任何"记忆占用"显示都会是假的**（你量的桶和漏的水不是一个桶）；
- 长会话 400 的真实根因在这里，而现有日志把 `droppedMessages` 当成了唯一嫌疑。

### 1.3 压缩语义错位：折叠产出的是警告，不是记忆

`buildFoldedHistorySection` 只列**问题**、不列答案，并要求模型「不要凭记忆复述」（`ContextBudget.ets:193-208`）。

产品语义上这等于说：**「我记得你问过什么，但不记得答案」**。上一轮辛苦总结出的结论、偏好、清单，裁剪后是真的消失了——不是被记住，是被明确禁止复述。

### 1.4 两套裁剪互不相干

| 层 | 上限 | 行为 |
| --- | --- | --- |
| L1 会话 | `MAX_AI_SESSION_MESSAGES = 200`（`model/AiSession.ets:24`） | 从头部**物理丢弃**（`AiSession.ets:124-126`） |
| L0 请求 | 24000 token | 折叠成问题清单（不落盘） |

长期使用的会话，历史会先被 L1 从磁盘删掉，L0 的折叠清单也救不回来。**两层各裁各的，没有一次"压缩沉淀"的动作。**

### 1.5 用户没有任何手

- 不能钉住某条消息、不能"记住这条"、不能展开被折叠的原文、不能调预算；
- 全仓库 UI 无 token / 占用 / 折叠展示（`AiChatPage.ets` 内 grep `usage|token|折叠|预算` 无匹配）；
- 裁剪只留一条 `logger.info`（`ActiveAiService.ets:228-231`）。

于是用户遇到的每一次"它怎么忘了"，客户端都不给任何解释——这是最伤信任的产品缺口。

## 2. 产品模型：把「预算」翻译成「记忆容量」

不要用 token 当主界面语言（普通用户无感，且数值不精确会招致质疑）。三层递进：

| 层级 | 用户看到 | 出现位置 |
| --- | --- | --- |
| 默认 | 「记忆 38%」细进度条 | 输入栏上方（`AiChatPage.RenderInputBar`） |
| 展开 | 模型窗口 128K · 已用 37K（工具 28K / 对话 9K）· 已折叠 4 轮 | 点击细条 → 半模态（`UIMaterialManager.sheetMaterial`） |
| 极客 | 本轮输入/输出 token、缓存命中率、工具次数 | 回答气泡脚注「详情」 |

三个产品承诺对应三个手势：

- **可见**：「我还剩多少记忆」随时可查，裁剪不再是黑箱；
- **可调**：按模型窗口和偏好选档位，而不是全场景一刀切；
- **可干预**：钉住重要的、重看被折叠的、手动记住该记的。

## 3. 六项改造

### 3.1 预算真源：模型窗口进配置（P0）

> **状态：已实施**（`contextWindow` 字段 + `resolveHistoryBudget` + 设置面板输入框 + 选中模型预填）。
> 三档保留比例已实施：**精简 30% / 平衡 50% / 长记忆 75%，默认长记忆**
> （`model/AiMemoryConfig.ets`，设置页「工具 → 对话记忆」）。

**目标**：让 24000 从"魔法值"变成"未知窗口时的保守回落"。

- `AiProviderProfile` 新增 `contextWindow: number`（0 = 未知）。AI 配置表单加「上下文窗口」输入框，默认取 `/models` 返回的 `contextWindow`，**允许用户手改**。
- **不内置厂商窗口对照表**：与 `AiModelPresets.ets` 已确立的「客户端不猜测任何厂商私有约定」一致；`/models` 不返回该字段的服务商（字段为 0）就落到未知分支，用户可自行填写。
- 预算推导（新增纯函数，便于 Hypunit 测试）：

```
resolveHistoryBudget(profile, mode):
  window = profile.contextWindow
  if window <= 0: return DEFAULT_HISTORY_TOKEN_BUDGET (24000)
  reserve = max(4000, window * 0.15)          // 输出 + system + 工具 schema 的余量
  return clamp(window - reserve, 4000, window * 0.85)
```

  注意：**不能**用 `maxOutputTokens` 精确预留——`AiProviderProfile` 明确「不设输出长度上限，请求不带 max_tokens」（`model/AiConfig.ets:53-58`），输出长度由服务端定，只能留保守余量。
- 保留比例改为档位（`AiMemorySettings.keepRatio`）：**精简 30% / 平衡 50%（沿用现有语义）/ 长记忆 75%**。
- **首次识别到窗口 < 32K 时提示一次**：「当前模型窗口 8K，长对话会被压缩，可切换长上下文模型」。这是把"必然 400"提前成"可理解的产品行为"。

### 3.2 统一水位：工具结果进预算（P0，优先级最高）

> **状态：已实施**（`AiAgentOptions.toolResultTokenBudget` + `contextTokens` 累计 +
> `fitToolResultContent` 压缩 + 体积耗尽收尾）。

**目标**：让"占用"这个数字第一次是真的。

- Agent 循环维护 `contextTokens` = 历史估算 + system 估算 + 已回传工具结果估算 + 本次待入队结果估算。
- **双预算**：调用次数（现有 `DEFAULT_MAX_TOOL_CALLS_PER_RUN`）+ **体积水位**（新增 `toolResultBudget`，默认取预算的 60%）。
- 超水位时的行为分层：
  1. 单条结果超余量 → 按余量截断，尾部显式追加「（已压缩；剩余 N 条可用同参数再次读取，客户端有缓存不重复请求）」；
  2. 余量耗尽 → 不再执行新工具（复用现有 `budgetExhausted` 收尾路径，`AiAgentRunner.ets:181-189`），回一条「本轮上下文预算已满，请基于已有信息作答」。
- UI：时间线对应条目标注「已压缩」，让用户知道模型看到的是节选。
- 与 `ToolInputLimits` 的分工：那里是**单次输入合法性**（GBK 字节 / 码点），这里是**整轮上下文体积**，两者不合并。

### 3.3 折叠即沉淀：L0.5 会话摘要（P1）

> **状态：已实施（高保真版）**——压缩时调一次模型，输出四段结构化记忆
> （结论 / 用户要求 / 关键数据 / 待办），输入按 `max(12000, 窗口×50%)` token 给足，
> 输出上限 3000 字，**最近 4 轮原文永不参与**。失败才回落「你问 + 我答（首句）」。
> 不做开关。未实施：`AiSession.digest` 落盘（跨轮复用摘要）、对话流里的可展开摘要条。

**目标**：把"折叠 = 丢失"改成"折叠 = 浓缩"。

- `AiSession` 新增 `digest: AiDigestEntry[]`（范围、要点、时间），随会话落盘。
- 生成策略两档：
  - **默认（零请求）**：本地规则摘要——每个被裁轮次压成一行「Q：… / A：首句…」，取 assistant 首句而非全丢；
  - **可选「深度记忆整理」**：用当前配置做一次小请求（max_tokens 300）压成 3-5 条结论，写回 digest。默认关闭，避免隐形成本。
- 回传：digest 替换现有的「问题清单」拼进 system 折叠段——**同一处既有例外**（`ActiveAiService.ets:300-303`），不新增前缀破坏点。
- UI：对话流插入一条可展开的「早期对话要点」折叠条（视觉上比普通气泡弱），点开可见被裁原文（原文仍在 L1 存储里）与「把这段重新加入上下文」按钮。

### 3.4 钉住消息（P1）

**目标**：给用户一只手，解决"我说过的规矩每次都忘"。

- 气泡长按 → 「钉住，不参与压缩」；`AiSessionMessage.pinned: boolean`。
- 上限 8 条 / 合计不超过预算的 20%（防止把钉住当无限记忆用）。
- 裁剪时豁免，按原始顺序插回窗口开头。UI 用图钉图标 + 输入栏「已钉住 2 条」角标。
- **代价**：钉住 / 取消钉住会改写历史前缀，是本次方案里**唯一新增的前缀缓存破坏点**。属于低频用户主动操作，可接受，但必须在文档与代码注释里写明（与 §4.4 的既有例外并列）。

### 3.5 记住这条 + 记忆面板（P2，L2 最小切片）

**目标**：把 `docs/AI_MEMORY_DESIGN.md` §6.1 的语义记忆，先做成人能用的、可信的那一半。

- 气泡长按 → 「记住这条」，**用户确认**后写入 `AiMemoryStore`（复用 `CacheEnvelopeStore`）；字段沿用预留设计：`scope(user|preset) / kind(preference|fact|rule) / text / sourceSessionId / pinned`。
- 设置页新增「AI 记忆」面板：列表、来源会话可回溯、逐条删除。
- **不做模型自动抽取**：模型推断直接落库会污染且用户无法审计；先做用户主动的那条通路。

### 3.6 透明化：用量回执与发送前预告（P1）

> **状态：第一层已实施**——输入栏上方「记忆 N% · 较早 N 轮已压缩 · 部分资料已压缩」。
> 未实施：回答脚注里的 token / 缓存命中率详情、发送前预告。

- 回答脚注「详情」（默认收起）：本轮输入 / 输出 token、**缓存命中率**、工具次数。`AiChatResult.usage` 已经带着这些数据（`ActiveAiService.ets:259`），现在只进了日志（`:267-269`）。
- 缓存命中率是最该露出的数字：它是"省钱"和"系统健康"的双重指标，而前缀缓存策略（§4.4）正是本设计的核心约束。
- 发送前：历史即将触发裁剪时，输入栏上方给一行轻提示「本次会压缩较早的 4 轮对话」，仅在该次出现，不常驻。

## 4. 数据与接口变更

| 文件 | 变更 |
| --- | --- |
| `model/AiConfig.ets` | `AiProviderProfile.contextWindow`；`normalizeAiProfile` 补默认值 |
| `service/ai/ContextBudget.ets` | 新增 `resolveHistoryBudget`；`fitHistoryToBudget` 接收档位后的预算；摘要裁剪改为产出 `digest` 条目 |
| `model/AiSession.ets` | `AiSession.digest`、`AiSessionMessage.pinned`；`normalizeAiSession` 逐字段重建（旧信封缺字段即空，`schemaVersion` 不需要升） |
| `service/ai/AiAgentRunner.ets` | `contextTokens` 水位；工具结果截断与「可再读」尾注；`AiAgentResult.contextUsage` |
| `service/ai/ActiveAiService.ets` | 预算改为由 profile 推导；`AiChatResult.contextUsage` 回传页面 |
| `pages/ai/AiChatPage.ets` | `RenderInputBar` 上方记忆条；气泡长按菜单（钉住 / 记住 / 复制）；折叠条渲染；脚注详情 |
| `pages/ai/AiSettingsPanel.ets` | 「上下文窗口」输入框；「对话记忆」档位；「AI 记忆」面板 |
| `store/settings/domain/AiSettings.ets` | `AiMemorySettings`（档位、深度整理开关） |
| `test/AiSessionUnit.test.ets` | 摘要条目 / 钉住上限 / 预算推导的新用例 |

## 5. 优先级与验收

| 优先级 | 改造 | 理由 |
| --- | --- | --- |
| P0 | 3.2 工具结果进预算 | 不修这条，后面所有"占用"展示都是假的 |
| P0 | 3.1 预算随模型配置 | 修复 8K 模型必然超窗；低改动、高收益 |
| P1 | 3.3 折叠沉淀 + 3.6 用量回执 | "记忆"的语义与信任感 |
| P1 | 3.4 钉住 | 用户唯一能主动干预记忆的手 |
| P2 | 3.5 记忆面板 | L2 的最小可用切片 |

产品指标（上线前后对比）：

| 指标 | 现状 | 目标 |
| --- | --- | --- |
| 上下文超窗导致的 400 率 | 未观测（根因在工具结果） | ≈ 0 |
| 折叠后用户重复提问率 | 未观测 | 下降 |
| 前缀缓存命中率 | 只有日志 | 面板可见，保持高位（钉住是唯一例外） |
| 每问平均输入 token | 只有日志 | 可对比，作为档位默认值的依据 |

## 6. 明确不做

| 不做 | 原因 |
| --- | --- |
| 客户端精确分词器 | 词表换不来收益，精确值只有服务端知道；估算偏保守即可 |
| 把动态内容塞回 system 换"记忆" | 已论证会打死前缀缓存（`AI_AGENT_REDESIGN.md` §8.2、`AI_MEMORY_DESIGN.md` §4.4） |
| 模型自动抽取记忆落库 | 污染不可审计；先做用户确认的那条通路 |
| 逐条裁剪（而非一次裁到目标比例） | 每轮都改写前缀 = 每轮都 miss（`ContextBudget.ets` 文件头） |
| 把裸 token 数当主界面文案 | 用户无感且易招致"数值不对"的质疑，分层披露 |

## 7. 风险

- **前缀缓存**：3.4 钉住是唯一新增破坏点；3.1/3.2/3.5/3.6 都不改 system，只在请求构造前生效或纯 UI。
- **ArkTS**：新模型字段一律走 `normalize*` 逐字段重建；估算 / 截断逻辑放纯函数，先补 Hypium 用例再接 UI（现有 `aiContextBudget` 7 例的模式）。
- **体感风险**：体积水位截断工具结果时，模型可能"看不到关键楼层"。必须靠尾注给出可再读路径，并在时间线标注，不能让用户以为读全了。
