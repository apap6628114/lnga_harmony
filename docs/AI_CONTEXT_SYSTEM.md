# AI Agent 上下文体系：精简、纠错与现代化

> 状态：**已实施**。本文是 L0（请求侧上下文）/ L1（会话持久化）的现行设计，
> 取代 `docs/AI_MEMORY_DESIGN.md` 中与本文冲突的参数与结论（旧文档保留作演进记录）。
> 涉及代码：`service/ai/ContextBudget.ets`、`ContextSummarizer.ets`、`ActiveAiService.ets`、
> `AiAgentRunner.ets`、`tools/ToolResultArchive.ets`、`tools/ExpandToolResultTool.ets`、
> `tools/ToolResultCache.ets`、`store/AiSessionStore.ets`、`store/AiToolCacheStore.ets`、
> `model/AiMemoryConfig.ets`、`pages/ai/AiChatPage.ets`。

## 0. 一句话

这套体系的评价标准不是「省了多少 token」，而是**模型在需要时能不能拿到它需要的全部信息，
并且拿得快、拿得便宜**。据此，本轮做的是三件事：

1. **删掉三条"看起来在省、实际在丢"的错误机制**；
2. **补上成熟 Agent 都有、这里缺的四个框架机制**（大结果外置续读、超窗自愈、
   增量摘要、缓存命中可观测）；
3. **把参数从"小窗口时代的保守值"调到"长上下文 + 前缀缓存时代的实际值"**。

## 1. 诊断：三条错误机制

### 1.1 "截断后同参数重调可恢复"是假的

`ContextBudget.fitToolResultContent` 旧尾注写着：需要剩余部分时用相同参数再次调用该工具，
客户端有缓存不会重复请求。这句话在**预算耗尽**时是错的：

- 同参数重调 → `ToolResultCache` 命中 → 返回同一份完整结果；
- 回传前仍然经过同一个 `fitToolResultContent` → 仍然按同样（甚至更小）的剩余额度截断；
- 模型每次只能看到开头，**后半段永远拿不到**。

也就是说，这不是"压缩"，是"丢弃 + 一句错误的指引"。模型可能因此反复调用，
把轮数耗在同一条结果上。

### 1.2 摘要重送整段旧历史

`resolveFoldedSection` 的增量分支只判断"旧记忆覆盖的是前缀"，然后把
**整段 dropped**（包含旧记忆已经压过的消息）送给摘要模型，同时把旧记忆也塞进输入。
后果：

- 摘要输入被旧内容占满，真正新增的对话可能被 `maxInputTokens` 截掉；
- 同一段内容被反复压缩，摘要会漂移、重复。

### 1.3 会话裁剪不移动摘要游标

`AiSession.digestCoveredCount` 记录"摘要覆盖到历史的前多少条"。`saveSession` 在消息超过
`MAX_AI_SESSION_MESSAGES` 时从头部物理丢弃，但游标不动。下一次压缩时：

- 游标大于当前消息数 → 指纹必然不匹配 → 旧摘要被丢弃并全量重压；
- 被物理裁掉的那段原文已经不在磁盘上 → **一次裁剪变成二次失忆**。

### 1.4 另外三处口径错误

| 问题 | 后果 |
| --- | --- |
| `estimateMessageTokens` 把 `reasoning` 算进水位，但请求根本不回传 reasoning | 预算凭空缩水，压缩触发得比真实早 |
| 工具 schema（约 2–4K token）完全没计入 | 水位偏乐观，工具结果把总量推过窗口才发现 |
| `hitContextBudget` 只进日志，不透传页面 | 用户不知道"部分取数没执行"，只看到回答变短 |

## 2. 对标：成熟 Agent 怎么做

| 能力 | 开源实现 | 本客户端的取舍 |
| --- | --- | --- |
| 前缀缓存 | Claude Code / OpenAI 系：system 与 tools 逐字节稳定，动态内容后置 | 已实施：`get_context` 工具承接动态上下文，system 只留稳定文案 |
| 大结果外置 | Claude Code 长输出落文件 + Read/Grep 按需读取；OpenHands observation 外置 | **本轮新增**：`ToolResultArchive` + `expand_tool_result` 分段续读 |
| 压缩 | Claude Code auto-compact、OpenHands Condenser、Gemini CLI chat compression | 已有生成式四段摘要；本轮修增量、提高容量、加超窗强制压缩 |
| 会话持久化 | Codex CLI rollout JSONL 追加、Aider 历史文件、Cline checkpoints | 已有 Preferences 信封；本轮修游标、补工具缓存持久化 |
| 溢出恢复 | 捕获 context overflow 后压缩重试（多家长上下文 Agent 的通用做法） | **本轮新增**：强制压缩 + 重试一次 |
| 分层记忆 | Letta/MemGPT core/archival/recall；Aider repo map | 已有 L1 会话 + 工具证据；L2/L3 仍预留，不引入自动记忆抽取 |
| 上下文隔离 | Claude Code subagent 独立上下文 | 暂不做：本客户端的工具子任务规模还不需要 |

**没有照搬的**：精确分词器（成本换不来收益，服务端 usage 校准更准）、自动长期记忆
（不可审计、易污染）、逐条裁剪（每轮改写前缀 = 每轮 miss）。

## 3. 现行框架：五层

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 稳定前缀层  system（任务提示词 + 工具约定） + tools schema │  ← 逐字节稳定，吃前缀缓存
├─────────────────────────────────────────────────────────────┤
│ 2. 原文窗口层  最近 N 轮原文 + 未被压缩的历史                │  ← 尽量用满窗口
├─────────────────────────────────────────────────────────────┤
│ 3. 记忆层      结构化摘要（结论/用户要求/关键数据/待办）      │  ← 低频、彻底、增量、可复用
├─────────────────────────────────────────────────────────────┤
│ 4. 工具证据层  结果缓存（跨启动）+ 大结果归档 + recentReads   │  ← 原文可回取，不靠摘要复述
├─────────────────────────────────────────────────────────────┤
│ 5. 持久化层    会话信封 + 摘要游标 + 工具缓存信封             │  ← 按账号隔离、容量受控
└─────────────────────────────────────────────────────────────┘
```

### 3.1 稳定前缀层

- system 只放：任务提示词、工具使用约定、**压缩记忆**（唯一的低频变化点）；
- 页面上下文（tid / uid / fid）、登录账号、工具可用性全部走 `get_context` 按需返回；
- tools 声明顺序由注册表固定，`expand_tool_result` 始终存在（不因"当前有没有归档"而消失），
  避免 tools 段逐轮变化；
- 工具定义不发 `title` / `annotations`（服务商只认 name / description / parameters）。

**为什么这层最重要**：DeepSeek 的上下文硬盘缓存与 OpenAI automatic prompt caching 都按前缀命中。
前缀里任何一个字节变化，从该点之后全部按全价计费，首字延迟也会上升。

### 3.2 原文窗口层

预算推导（`resolveHistoryBudget`）：

```
窗口 = 用户手填 > 已知模型表 > 假设 128K
预留 = clamp(窗口 × 12%, 4096, 窗口 × 50%)
历史预算 = 窗口 − 预留
```

触发与保留（`AiMemoryConfig`）：

| 档位 | 触发 | 压缩后保留 | 适用 |
| --- | --- | --- | --- |
| 精简 | 80% | 45% | 窗口很小 / 流量受限 |
| 平衡 | 90% | 60% | 折中 |
| **长记忆（默认）** | **95%** | **80%** | 先用满，压缩后仍留八成 |

最近 **4 轮**原文永不被摘要（`KEEP_RECENT_TURNS`）；超窗强制压缩时降为 2 轮。

### 3.3 记忆层：摘要

- 生成式四段结构（结论 / 用户要求 / 关键数据 / 待办），输出上限 **6000 字**；
- 摘要输入上限 `max(24000, 窗口 × 50%)` token，单条消息最多 8000 字；
- **增量**：旧记忆覆盖的前缀不再重送，只送 `dropped.slice(coveredCount)`；
- **复用**：覆盖范围与指纹一致、或旧记忆覆盖范围比本次丢弃区更大（会话裁剪后）时，
  直接复用、零模型调用；
- **失败回落**抽取式清单，且不写入记忆（避免把劣质摘要固化）；
- **游标**：`digestCoveredCount` / `digestFingerprint` 随会话落盘；会话物理裁剪时同步前移。

### 3.4 工具证据层

1. **结果缓存**（`ToolResultCache`）：按 `tool|uid|上下文指纹|规范化参数` 建键；
   失败 / 空结果不缓存；`freshness=auto|fresh|no_cache` 由模型控制；
   长 TTL 10 分钟（读帖 / 版块 / 用户活跃），短 TTL 45 秒（列表 / 搜索）。
2. **跨启动持久化**（`AiToolCacheStore`）：最多 80 条 / 约 1.2M 字符，按 uid 隔离，
   800ms 合并写盘；恢复时按原 TTL 判断，不"续命"。
3. **大结果归档**（`ToolResultArchive`）：单次运行内最多 32 条 / 2M 字符 LRU；
   超出本轮预算的结果完整留在归档里，上下文只放头部 + `result_id` + 总字符数；
   模型用 `expand_tool_result(result_id, offset, limit)` 按需续读。
4. **重复调用熔断**：同一运行内同参数（`freshness=auto`）成功调用过第二次时，
   不再执行、不再塞正文，只回一条"结果见上文"的短消息；模型要最新数据需显式
   `freshness=fresh`。
5. **最近读过什么**（`AiTaskContext.recentReads`）：会话恢复后由 `get_context` 提供给模型，
   提示它重新取原文而不是复述摘要。

### 3.5 持久化层

| 对象 | 存储 | 上限 | 恢复语义 |
| --- | --- | --- | --- |
| 会话 | `ai_sessions_<uid>` 信封 | 20 个会话 × 200 条消息 | 按 uid 隔离，结构版本不符整封丢弃 |
| 摘要游标 | 随会话 | — | 裁剪时同步前移，游标归零仍保留摘要正文 |
| 工具缓存 | `ai_tool_cache_<uid>` 信封 | 80 条 / 1.2M 字符 | 只恢复未过期、成功、非空条目 |

写盘统一走 `SerialQueue` + `putString(flush=false)` + `scheduleFlush(500ms)`，
缓存另加 800ms 合并窗口；`flushAll()`（应用后台 / 退出）补一次工具缓存落盘。

## 4. 超窗自愈

即便估算再保守，服务端模板、工具 schema、缓存计费口径都可能让真实请求比预估更大。
旧行为：400 直接抛给用户，整轮对话丢失。

现在的处理（`ActiveAiService.chatCompleteWithActiveAiStream`）：

1. 捕获异常，`isContextOverflowError` 只匹配服务商的明确措辞
   （`context_length_exceeded` / `maximum context length` / `input is too long` …）；
2. 仅当本轮**尚未输出任何正文**时重试（避免页面出现重复内容）；
3. 强制压缩：目标压到正常阈值的 50%，最近 2 轮原文不动，**不再调用生成式摘要**
   （摘要请求本身也可能超窗）；
4. 重试一次；成功后 `AiChatResult.recoveredFromOverflow = true`，页面追加一条轻提示；
5. 仍失败则抛出原错误，不做无限重试。

## 5. 缓存机制与命中率

### 5.1 两类缓存，两个指标

| 缓存 | 命中条件 | 观测 |
| --- | --- | --- |
| 服务端前缀缓存 | system / tools / 历史前缀逐字节不变 | `usage.cachedTokens / usage.promptTokens` |
| 客户端工具缓存 | 工具 + uid + 页面指纹 + 规范化参数 + 未过期 | 工具时间线「缓存」标记、`fromCache`、日志 |

页面在输入栏上方的记忆条里展示 `缓存 N%`（无真实 usage 时不展示，避免假的 0%）。
这是判断"历史是否只追加、有没有动态内容混进前缀"的体温计。

### 5.2 只追加原则

- 历史只追加，不重排；删除 / 停止 / 本机兜底气泡不写入会话；
- system 只在压缩、任务切换、强制压缩时变化；
- `get_context` 的 `recentReads` 每轮变化，所以它走工具、不进 system；
- 压缩本身是唯一的常规前缀破坏点，用 95% 触发 + 80% 保留把它压成低频事件。

## 6. 精简掉的冗余

| 删掉 / 收敛 | 原因 |
| --- | --- |
| "同参数重调可恢复"的错误尾注（无归档时保留兜底文案） | 预算耗尽时不可恢复，会诱导模型反复调用 |
| 摘要重送整段 dropped | 输入被旧内容占满，新增对话被挤掉 |
| `estimateMessageTokens` 计 reasoning | 请求不回传 reasoning，属于虚增水位 |
| 会话裁剪后游标不动 | 造成二次失忆 |
| 折叠清单上限 6 条 | 提高到 12 条：兜底摘要不该只剩 6 句 |
| 工具结果最小保留 200 token | 降到 128，给剩余额度很小的场景留出续读入口 |
| `hitContextBudget` 只进日志 | 透传页面并提示"部分取数未执行" |

保留但标注的字段：`AiChatResult.outputItems` 目前恒为空（协议中间 items 不跨轮），
保留是给 Responses 协议后续扩展；页面不消费。

### 6.1 审查后补的加固

- **账号切换竞态**：`AiSessionStore.init` / `AiToolCacheStore.init` 在异步加载完成后
  比对 generation 与 uid 快照，不一致就整体丢弃；`saveSession` 还校验会话归属
  （`AiSession.ownerUid`），避免 A 的对话页在切到 B 之后把内容写进 B；
- **客户端提示不落历史**：截断 / 轮数 / 预算 / 超窗提示改放 `ChatBubble.notice`，
  只渲染、不进 `content`，因此不会被 `persistSession` 写进会话、也不会作为
  assistant 历史回传给模型；
- **校准预算夹紧**：`resolveCalibratedBudget` 把「预算 / 系数」限制在窗口安全线内，
  修复系数 0.7 时 1M 窗口被放大到 1.25M 的问题；
- **摘要输入夹紧**：`resolveSummaryInputLimit` 把输入限制在窗口 75% 以内，
  修复 8K 窗口仍按 24000 送摘要、摘要请求自己超窗的问题；
- **摘要失败不丢旧记忆**：生成式摘要失败时，回落清单会拼上 `previous.digest`，
  避免"旧摘要覆盖的原文已被裁剪、本轮直接失忆"；
- **截断预算不足时整条外置**：剩余额度连「最小正文 + 尾注」都放不下时，不再塞正文，
  只回 result_id + 续读指引；
- **重复调用不计取数预算**：同参数重复调用只回一条短说明，不消耗 30 次工具调用额度；
- **缓存容量双上限**：内存缓存除 200 条外增加 8M 字符预算，避免长帖正文把内存撑爆；
- **宽容加载**：会话 / 工具缓存逐条校验，单条坏数据只跳过该条，不再让整封信封失效。

## 7. 关键参数表

| 参数 | 值 | 位置 |
| --- | --- | --- |
| 未知窗口假设 | 128K | `ContextBudget.ASSUMED_CONTEXT_WINDOW` |
| 输出预留 | `min(窗口×50%, max(4096, 窗口×12%))` | `resolveHistoryBudget` |
| 触发 / 保留（默认） | 95% / 80% | `AiMemoryConfig` |
| 最近原文轮数 | 4（强制压缩 2） | `KEEP_RECENT_TURNS` |
| 摘要输出上限 | 6000 字 | `SUMMARY_MAX_CHARS` |
| 摘要输入上限 | `min(窗口×75%, max(24000, 窗口×50%))` | `resolveSummaryInputLimit` |
| 工具结果缓存 TTL | 10 分钟 / 45 秒 | `AI_TOOL_CACHE_TTL_*` |
| 工具缓存持久化 | 80 条 / 1.2M 字符 | `AiToolCacheStore` |
| 归档容量 | 32 条 / 2M 字符 | `ToolResultArchive` |
| 续读单次上限 | 16000 字符（默认 4000） | `ARCHIVE_MAX_READ_CHARS` |

## 8. 验收

- `hvigorw assembleHap`：`BUILD SUCCESSFUL`；
- Hypium Local Test：全部通过；新增 `AiContextArchive.test.ets`（18 例）覆盖
  归档读写 / 代理对安全 / LRU / 字符预算 / 续读工具 / 超窗识别 / schema 计数 /
  缓存命中率 / 缓存快照恢复 / 预算窗口夹紧 / 摘要输入夹紧；更新 `AiToolContract`
  （未登录暴露 2 个元工具 + 目录顺序）与 `AiSessionUnit`（新档位比例）；
- 手工验收要点：
  1. 长帖读取触发预算截断时，回答里能看到"已保存 result_id"，追问后半段模型会调用
     `expand_tool_result` 而不是重复读帖；
  2. 长会话压缩后再等一轮，`较早 N 轮已压缩` 不重复增长（增量摘要没有重压旧内容）；
  3. 杀掉应用冷启动，重复问同一帖子，工具时间线出现「缓存」；
  4. 用小窗口模型（如 8K）发长输入，观察"输入超出模型窗口，正在压缩并重试"后成功；
  5. 输入栏记忆条显示 `上下文 N% · 缓存 M%`（服务商返回 usage 时）。

## 9. 后续

| 项 | 价值 | 为什么本轮不做 |
| --- | --- | --- |
| 预压缩（80% 时后台生成摘要，95% 直接复用） | 把压缩延迟从首字前移到空闲时 | 需要页面级后台任务与取消协调，先保证正确性 |
| L2 语义记忆（用户偏好 / 事实条目 + `recall_memory`） | 跨会话"越用越懂你" | 需要确认式写入与可审计面板，不能自动落库 |
| L3 任务级记忆（游标 / 上次产出） | "每天汇总新帖"类任务可反复运行 | 依赖任务运行模型，属于产品能力 |
| 只读工具并行执行 | 降低多工具轮延迟 | NGA 风控下并行更容易触发限流，收益/风险不划算 |
| 精确分词器 | 更准的预算 | 词表换不来收益，服务端 usage 校准已足够 |
