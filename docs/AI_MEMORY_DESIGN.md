# AI 记忆体系设计

> 状态：**L1（会话持久化）+ L0（上下文预算）已实施**；L0 的立场是「**先把窗口用满，
> 接近上限才压缩，压缩要彻底且高保真**」——预算由模型窗口推导（未知时假设 128K）、
> 工具结果共享同一份预算、压缩走生成式四段记忆且最近 4 轮原文不动。
> 产品化路线见 `docs/AI_MEMORY_PRODUCT_PLAN.md`。L2（跨会话长期记忆）、L3（任务级记忆）为预留设计。
> 涉及代码：`model/AiSession.ets`、`store/AiSessionStore.ets`、`service/ai/ContextBudget.ets`、
> `service/ai/ActiveAiService.ets`、`model/AiAgentPreset.ets`、`service/ai/tools/ContextTool.ets`、
> `pages/ai/AiChatPage.ets`、`store/AppStore.ets`

## 1. 问题：这套系统原本没有"记忆"

改造前只有「一次请求内的对话数组」：

| 能力 | 改造前 | 证据 |
| --- | --- | --- |
| 会话内历史 | 全部原样回传，无窗口、无预算 | `AiChatPage.buildHistory` |
| 会话持久化 | 无。`bubbles` 是页面 `@State`，退出即销毁 | `AiChatPage` |
| 切换任务 | 直接清空对话 | `applyPresetById(id, true)` |
| 工具证据 | 下一轮全部丢弃（历史只含 user/assistant 纯文本） | `buildHistory` 过滤 + `resetStreamingState` |
| 跨会话记忆 | 无 | `SettingsState` 无相关字段 |
| 任务状态 | 无（只有 prompt + 工具白名单 + 入口） | `AiAgentPreset` |

三个可观察的"失忆"症状：

1. **关页面就忘**：花三轮问出的结论，返回后全部丢失。
2. **追问细节就忘**：第二轮模型只看到自己上一轮的总结文本，原始楼层已不在上下文里。
3. **任务不会越用越懂你**：偏好、禁忌、上次跑到哪里，只能硬写进 systemPrompt。

## 2. 分层模型

| 层 | 名称 | 存什么 | 生命周期 | 状态 |
| --- | --- | --- | --- | --- |
| L0 | 工作记忆 | 本次请求可用的对话窗口 + 折叠摘要 + 工具证据 | 一次请求 | ✅ 已实施 |
| L1 | 情节记忆 | 会话（消息列表 + 任务归属 + 时间） | 跨页面、跨启动 | ✅ 已实施 |
| L2 | 语义记忆 | 跨会话的偏好 / 事实 / 规则条目 | 长期 | 预留 |
| L3 | 程序记忆 | 任务级笔记、运行游标、上次产出 | 随任务 | 预留 |

设计原则：**L0 控制"发出去多少"，L1 控制"留下来什么"**。L2/L3 都建立在 L1 的会话记录之上，
所以先做 L0+L1。

## 3. L1：会话持久化

### 3.1 数据模型

```ts
// model/AiSession.ets
class AiSessionMessage {
  role: string = 'user'        // 只允许 user / assistant
  content: string = ''
  toolNotes: string[] = []     // 这一轮读过什么（仅 assistant），**不回传模型**
  createdAt: number = 0
}
class AiSession {
  id: string = ''
  presetId: string = ''        // 任务归属（空 = 自由对话）
  presetName: string = ''      // 任务名快照：任务被删后历史仍可读
  title: string = ''           // 首条用户消息摘要
  messages: AiSessionMessage[] = []
  createdAt: number = 0
  updatedAt: number = 0
}
```

**为什么不存协议字段**（`toolCalls` / `outputItems`）：它们只在一次 Agent 循环内有效，跨请求回传
必须与 `tool_calls` 一一配对，否则 OpenAI 兼容服务端直接 400。持久层只留纯文本，与
`AiAgentRunner` 的「每轮重放纯文本历史」策略一致。

**`toolNotes` 为什么不回传**：会话恢复后模型看到的仍是文本历史；要原文就重新调用工具
（`ToolResultCache` 会命中，不重复请求）。把它当上下文塞回请求会放大 token 且容易让模型把
摘要当事实。

### 3.2 存储

`store/AiSessionStore.ets`，复用 `CacheEnvelopeStore`（键 `ai_sessions_<uid>`）：

```jsonc
{ "schemaVersion": 1, "uid": "...", "items": [ /* AiSession[] */ ], "updatedAt": 0 }
```

- **账号隔离**：信封校验 `schemaVersion` + `uid`，换账号读到别人的信封整封丢弃；
- **写盘**：`putString(flush=false)` + `scheduleFlush(500ms)`，每轮保存只入队不阻塞；
- **上限**：单账号 20 个会话（按 `updatedAt` 淘汰最旧）、单会话 200 条消息；
- **对齐**：裁剪后从头部丢到最近一条用户消息为止，保证恢复后不是以 AI 答复开头；
- **空会话不落盘**：只开页面不说话不产生记录；
- **未登录不落盘**：会话按 uid 归属，没有账号就没有归属（内存中仍可聊）。

### 3.3 页面生命周期

| 时机 | 行为 |
| --- | --- |
| 进入（无 `sessionId`） | 以当前任务新开一条会话 |
| 进入（带 `sessionId`） | 恢复该会话；任务以**会话记录**为准，任务被删则回落自由对话但内容照常可读 |
| 每轮结束 | `persistSession()`（进程被杀也不丢这一轮） |
| 退出页面 | `persistSession()`，**先落盘再 `scope.end()`**：`scope.end()` 后运行中的请求 finally 不再写会话 |
| 切换任务 / 切回自由对话 | 先落盘旧会话（此时任务名快照才正确）→ 清屏 → 新开一条 |
| 删除当前会话 | 连带清屏并新开，避免"内容还在、下次保存又冒出来"的幽灵记录 |

什么不写进会话：失败气泡、被用户停止的半截回答、本机兜底文案（`localOnly`）。
它们不是模型产出，写进去会让下一轮上下文出现"AI 说过但其实是客户端提示"的伪事实。

### 3.4 入口

- 导航栏第二颗按钮（`icon_clock`）打开「历史对话」面板：新对话、会话列表（标题 / 任务名 · 轮数 / 时间）、
  单项删除、清空全部（官方 `AlertDialog` + `systemMaterial` + `UIMaterialManager.scrim`）；
- 面板遮罩统一用 `UIMaterialManager.scrim`，不再自取 `#66000000`。

## 4. L0：上下文预算

> **立场**：上下文是**效果**，不是成本。1M 窗口 + 缓存命中 0.02–0.04 元/百万 token 的今天，
> 为省 token 而压缩是净亏损——省下的钱不值钱，丢掉的信息很贵，压缩本身还要多一次模型调用。
> 所以整套策略是「**先把窗口用满，接近上限才压缩，压缩要彻底且高保真**」。

### 4.1 token 估算

`estimateTextTokens`：CJK（`>= 0x2E80`）按 1 字 1 token，其它按 4 字符 1 token；每条消息再加 4
token 固定开销。估值刻意**偏保守**（宁多算），精确分词只有服务端知道，客户端不值得为此引入词表。

**已知偏差与在线校准**：主流 BPE 对中文约 0.6–0.9 token/字，所以中文会被高估 1.1–1.6 倍；
工具 schema（约 2–3K）未计入，方向相反。净效果是"提前压缩"，不会超窗。

校准机制（`nextCalibrationFactor`）：

- 每次请求记录「发出前的本地估算」与「服务端返回的 `usage.promptTokens`」，算比值；
- 用 **EMA（α=0.3）** 收敛，夹在 `[0.5, 2.0]`——单次跳变不能带偏，极端样本不能把预算调爆；
- 预算按 `预算 / 系数` 调整：系数 0.7（我们高估）→ 预算放宽 1.43 倍；系数 1.5 → 收紧；
- 偏差超过 0.02 才写盘，避免每轮持久化；
- 系数存 `AiMemorySettings.tokenCalibration`，跨会话生效。

这让「上下文 N%」和「是否超窗」都贴近真实，而不是永远停在估算自己编出来的世界里。

### 4.2 预算与触发

| 参数 | 值 | 理由 |
| --- | --- | --- |
| 预算 | `窗口 - min(窗口×50%, max(4096, 窗口×12%))`，剩余**全部**给历史；窗口未知时假设 **128K** | 旧版乘 0.75 是白白扔掉 25% 窗口；旧版 24K 兜底对 1M 模型是砍掉 97% |
| 触发 | 占用达到预算的 **95%**（长记忆档） | 压缩应该是低频事件：一年压几次，每次 miss 摊得很薄 |
| 保留 | 触发后保留预算的 **70%** | 一次压缩多留一些，别让"裁了又裁"把历史切碎 |
| 必留 | 最后一条 + **最近 4 轮原文** | 当前话题永远原样可得，这是"压缩不伤效果"的关键 |
| 对齐 | 窗口从用户消息开始 | 以 AI 答复开头的历史语义断裂 |

**档位**（`model/AiMemoryConfig.ets`）：

| 档位 | 触发 | 保留 | 适用 |
| --- | --- | --- | --- |
| 精简 | 80% | 40% | 成本敏感、随手一问 |
| 平衡 | 90% | 55% | 折中 |
| **长记忆（默认）** | **95%** | **70%** | 先把窗口用满，最不容易失忆 |

**窗口从哪来（三级取值）**：

1. `AiProviderProfile.contextWindow`——用户手填，或 `/models` 返回 `context_window` 时选中模型自动预填；
2. **已知模型窗口表**（`model/AiModelContextWindows.ets`，数据来自官方价目表，含来源 URL 与快照日期）；
3. 都没有 → 假设 128K（现代模型保守下限）。

第 2 级是必须的：当前 DeepSeek 官方模型（`deepseek-flash` / `deepseek-v4-pro`）上下文是 **1M**，
不预埋就等于"买了长上下文，却按 24K 裁剪"。这不违反 `AiModelPresets.ets`「不猜测厂商私有约定」——
那条原则禁止的是**猜**（按模型名瞎推断），而表里收的是官方文档写明的数值；且用户手填永远优先。

表只做**精确匹配**，不做前缀模糊匹配：把没见过的变体错配到旧窗口就是"猜"，宁可不命中。

**为什么留 12% 而不是按 `maxOutputTokens` 精确扣**：请求不携带 `max_tokens`（输出长度交给服务端），
只能留余量。这一点与 `model/AiConfig.ets` 的「不设输出上限」约定配套，不要改回精确扣减。

### 4.3 压缩：生成式、高保真、不可关闭

被裁掉的轮次由 `service/ai/ContextSummarizer.ets` 压成**工作记忆**，由
`ActiveAiService.buildConversation` 拼进 **system**：

```
【较早对话的记忆】
结论：……；……
用户要求：回答控制在 200 字以内（原话）；不要引用未读过的楼层
关键数据：tid=44191387；楼主 uid=12345；共 3 个要点
待办：还没确认第 7 楼的时间线
（更早的 3 轮已省略）
以上是从更早的对话里压缩出来的记忆，不是原文。需要具体原文数据时请重新调用对应工具读取
（客户端有缓存，不会重复请求）；涉及用户偏好等尚未确认的信息时，请向用户确认。
```

**这是生成式压缩，不是剪切**：用当前配置调一次模型，输出**四段结构化记忆**
（结论 / 用户要求 / 关键数据 / 待办），而不是"6 条 40 字"的提纲。成熟 Agent
（Claude Code 的 auto-compact、LangChain 的 `SummaryBufferMemory`）都这么做。
它**不提供关闭开关**——没有兜底压缩，窗口用满那天直接 400，整轮对话丢失。

| 约束 | 做法 |
| --- | --- |
| 不阻断主流程 | 失败（网络 / 取消 / 空输出）返回空串，回落抽取式折叠清单 |
| 摘要请求自己不能超窗 | 输入按 token 封顶：`max(12000, 窗口×50%)`，超长时**保留尾部** |
| 输出保真 | 单条消息最多 4000 字进摘要；输出最多 3000 字（四段结构）；只清 markdown 装饰，不压缩语义 |

**降级路径**：生成式摘要为空时，用抽取式清单（「你问 + 我答（首句）」）兜底——
它是兜底，不是主路径。

**压缩一次、长期复用**（`AiSession.digest` + `digestCoveredCount` + `digestFingerprint`）：

| 场景 | 判据 | 行为 |
| --- | --- | --- |
| 完全命中 | 覆盖条数与前缀指纹都一致 | 直接复用记忆，**零模型调用** |
| 增量更新 | 旧记忆覆盖的是前缀（历史只追加） | 把旧记忆作为「已有记忆」喂进去，只补新内容 |
| 失效 | 指纹不匹配（历史被重排/恢复错位） | 丢弃旧记忆，全量重压 |
| 压缩失败 | 摘要为空 | 回落抽取式，**不写入记忆**（避免把劣质摘要固化） |

指纹用 FNV-1a 覆盖前 N 条的 `role + content`：只要历史只追加，旧前缀的指纹就不变，
这是"增量更新"能成立的前提。

**延迟代价**：摘要发生在首字之前，会推迟首个 token。期间状态栏显示「正在整理较早的对话...」。
只有触发裁剪的轮次才付出这个代价，正常轮次零开销。

### 4.3.1 记忆用量回执

`AiChatResult.contextUsage`（`ContextUsage`）随每轮结果回传页面，输入栏上方展示
「记忆 38% · 较早 4 轮已压缩 · 部分资料已压缩」。用产品语言而不是裸 token 数：
普通用户关心的是"还剩多少、有没有被压缩"，而估算值本身也不精确。

### 4.3.2 工具结果也计入同一水位

`fitHistoryToBudget` 只裁历史，而长会话真正的体量来源是**工具结果**（一次读帖一页 20 楼）。
`AiAgentRunner` 维护 `contextTokens`（system + 历史 + 已回传工具结果），工具结果与历史**共享
同一份预算**（不再单独打六折），只在真的会把总量推过预算时才处理：

- 单条结果超余量 → 按余量截断，尾部追加「可再次调用取剩余部分（客户端有缓存）」；
- 余量耗尽 → 不再执行新工具，走 `appendSkippedCall` 补一条 tool 消息收尾
  （对话结构必须与 `tool_calls` 一一对应，少一条服务端直接 400）。

截断是可恢复的：`ToolResultCache` 保证模型用同样参数重新调用时不会重复请求。

### 4.4 与前缀缓存的关系（重要）

`docs/AI_AGENT_REDESIGN.md` §8.2 的结论是 system 必须逐字节稳定。压缩段是这条规则唯一的
例外，但代价可控：

- 常态下历史**只追加**，system 不变 → 缓存持续命中；
- 只有触发压缩时才改写前缀，而那一次请求本来就因为丢掉旧消息而 miss；
- 触发阈值 95% + 一次压到 70%，让 miss 变成**低频事件**（一年几次），而不是每几轮一次。

**绝不能**把"每轮都变"的内容放进 system（页面上下文、登录账号、工具可用性、最近的工具调用），
它们要么走 `get_context`，要么走 L2 的检索工具。

### 4.5 工具证据：走工具，不走 system

每轮结束后，页面把成功的工具调用压成短摘要（`读帖 · 44191387 · 20 条`）：

- 写进会话的 `toolNotes`（恢复后 UI 显示"这轮依据什么"）；
- 同时写入 `AiTaskContext.recentReads`，由 `get_context` 输出：

```
【本会话最近读过的资料】
- 读帖 · 44191387 · 20 条
用户追问这些内容的细节时，请重新调用对应工具取原文（客户端有结果缓存，不会重复请求），
不要凭上一轮的总结复述。
```

`get_context` 是零参数、按需调用的工具，天然不影响前缀缓存——这正是它存在的意义。

## 5. 边界与已知限制

| 项 | 行为 | 原因 |
| --- | --- | --- |
| 未登录 | 会话只在内存，不落盘 | 会话按 uid 归属 |
| 登出 | 内存清空，磁盘保留 | 重新登录同一账号应能看到之前的对话 |
| 换账号 | 看不到别人会话 | 信封 uid 校验 |
| 恢复会话 | 不恢复页面上下文（tid / uid / fid） | 上下文属于"当前页面"，不属于会话；`recentReads` 会提示读过什么 |
| 跨设备 | 不支持 | 仅本机 Preferences，不含云同步 |
| 会话体积 | 20 × 200 条上限 | 防持久化无限膨胀；详细归档属于后续能力 |
| 压缩摘要 | 生成式四段记忆，最近 4 轮原文不动 | 压缩只为"腾出窗口"，不为"省钱"；当前话题永远原样可得 |

## 6. 后续：L2 / L3 预留设计

### 6.1 L2 语义记忆（跨会话）

```ts
class AiMemoryEntry {
  id: string
  scope: string       // user | preset
  kind: string        // preference | fact | rule
  text: string
  sourceSessionId: string
  hits: number
  pinned: boolean
}
```

- **写**：模型通过 `remember` 工具提交候选 → 对话页渲染"记住这条？"卡片，用户确认才入库；
  另支持从 `settings.notes`（`UserNoteEntry`）一键导入——用户手写的笔记是强信号。
- **读**：`recall_memory(query)` 按需检索 top-K，**不拼 system**（同 `get_context` 的理由）。
- **可撤销**：记忆面板逐条删除 / 纠正；每条记忆带来源会话，可回溯。
- **防污染**：只存"用户说过的事实"与"用户确认过的候选"，模型推断不直接落库；记忆内容按
  不可信输入处理（与工具结果同等对待）。

### 6.2 L3 程序记忆（任务级）

- `AiAgentPreset` 增加 `memoryKeys`（订阅哪些记忆 scope）与任务私有笔记；
- 运行记录：`lastRunAt` / `cursor`（上次处理到 tid 或时间戳）/ 上次产出摘要；
- 没有游标的"每天汇总新帖"每次都要全量重扫，这是自定义任务从"一次性问答"变成
  "可反复运行的代理"的关键缺口；
- 导出/分享任务时随行 prompt + 任务级笔记，不随行 user-scope 记忆。

## 7. 文件清单

| 文件 | 变更 |
| --- | --- |
| `model/AiSession.ets` | 新增：会话 / 消息模型、归一化、信封校验、标题与时间格式化；`digest` 三字段承载压缩记忆 |
| `store/AiSessionStore.ets` | 新增：按 uid 持久化、上限淘汰、增删查 |
| `service/ai/ContextBudget.ets` | 新增：token 估算、历史裁剪、折叠摘要；预算推导 `resolveHistoryBudget`、工具结果压缩 `fitToolResultContent`、占用汇总 `ContextUsage` |
| `model/AiConfig.ets` | `AiProviderProfile.contextWindow`（记忆预算真源）+ 归一化 |
| `service/ai/ContextSummarizer.ets` | 生成式摘要：被裁对话压成结论要点（失败回落抽取式） |
| `model/AiModelContextWindows.ets` | 已知模型窗口表（官方价目表，含来源与快照日期） |
| `model/AiMemoryConfig.ets` | 记忆档位（精简 30% / 平衡 50% / 长记忆 75%，默认长记忆） |
| `store/SettingsStore.ets` + `SettingsState` + `AiSettings` | 记忆档位读写 |
| `test/AiContextSummary.test.ets` | 已知窗口表 / 摘要输入输出边界 11 例 |
| `service/ai/AiAgentRunner.ets` | 工具结果计入上下文水位（`toolResultTokenBudget`）、超余量压缩、体积耗尽收尾 |
| `service/ai/AiConfigFormLogic.ets` | `parseContextWindowInput`（窗口输入框解析与归一化） |
| `model/AiAgentPreset.ets` | `AiTaskContext.recentReads` + `buildContextDetail` 追加"最近读过的资料" |
| `service/ai/ActiveAiService.ets` | `buildConversation` 接收入参改为裁剪结果，折叠段进 system |
| `pages/ai/AiChatPage.ets` | 会话恢复 / 每轮落盘 / 历史面板 / 工具证据展示 |
| `store/AppStore.ets` | 初始化、登出清理、Facade 方法 |
| `test/AiSessionUnit.test.ets` | 19 个用例（模型 / 校验 / 裁剪 / 折叠），已注册进 `List.test.ets` |

## 8. 验收

- `hvigorw assembleHap`：`BUILD SUCCESSFUL`；
- Hypium Local Test：全部通过（含 `aiSessionModel` 12 例 + `aiContextBudget` 12 例 +
  `aiMemoryMode` 3 例 + `knownModelContextWindows` / 摘要链路 11 例）；
- 手工验收要点（真机）：
  1. 对话三轮后返回再进「历史对话」→ 内容完整，工具证据行可见；
  2. 杀掉应用冷启动 → 历史仍在；
  3. 切换任务 → 旧会话进历史、新会话为空；
  4. 删除 / 清空 → 列表与屏幕状态一致；
  5. 长会话（数百轮）不出现"上下文超长"报错，且模型知道更早聊过什么。
