# 帖子两层递进树：楼层引用（quote / reply-to）真实数据调研报告

> 目标：为「帖子两层递进树」阅读模式提供**基于真实抓取数据**的引用关系提取依据。
> 调研对象：NGA 论坛真实帖子（JSON 主通道 + HTML 降级通道）。
> 交付说明：调研用的原始抓取样本与分析脚本（`docs/research/samples/`）已在交付前清理，报告中的统计数字与结论保留；
> 如需复验，可按报告中记录的抓取帖 tid 与 `read.php?__output=8` 方式重新采样。
> 结论先行：引用关系有**两种**载体（`[quote]` 引用 与 `[b]Reply to` 回复），主楼 pid 是哨兵值 `0`，
> `[pid=A,B,C]` 的 C 段**不能**当页码用，匿名引用无数字 uid，且 `__R` 行里混有楼中楼评论行——
> 这些都必须写进实现，否则引用图会错。

---

## 0. 一页纸结论（TL;DR）

1. **引用关系不止 `[quote]`**：真实数据中存在两种楼层级引用载体，都必须识别：
   - **载体 A（引用）**：`[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b] … [/quote]` 携带被引正文。
   - **载体 B（回复）**：`[b]Reply to [pid=A,B,C]Reply[/pid] Post by [uid=U]name[/uid] (date)[/b] …` 只带回复头、不带被引正文。
   6 个样本帖共 741 条引用关系，其中载体 A 547 条（73.8%）、载体 B 194 条（26.2%）。**只解析 `[quote]` 会漏掉 1/4 以上的引用关系。**
2. **`[pid=A,B,C]` 三段语义**（6 帖 741 条关系实证）：
   - **A = 被引用楼层的 `pid`**（非跨帖且有 pid 三段的 717 条中，710 条命中帖内楼层；A=0 是「主楼」哨兵，2 条）。
   - **B = 帖子 `tid`**（有 pid 三段的 731 条中 717 条 `B == 本帖 tid`；其余 14 条是**跨帖引用**，B 指向别的帖子 id，应丢弃）。
   - **C ≈ 被引用楼所在页码，但不可靠**：整体 97.4% 命中；其中 Web 端来源的错误率约 7.4%，且错误形态几乎都是「写成 1」。
     **实现时不要用 C 计算页码**（用 pid 跳转或自建 pid→page 映射）。
3. **主楼 `pid` 是 `0`（两通道一致）**：`posts[0].pid === 0`，不是真实楼层 id。引用主楼有两种真实形态：
   - `[quote][tid=<tid>]Topic[/tid] [b]Post by …`（App 端引用主楼，无 `reply_to`）
   - `[quote][pid=0,<tid>,1]Reply[/pid] [b]Post by …`（Web 端引用主楼，无 `reply_to`）
   6 帖共 11 条主楼引用（占 1.5%），**不常见但必须支持**。
4. **匿名引用没有数字 uid**：形态为
   `[b]Post by [uid]#anony_<32hex>[/uid][color=gray](N楼)[/color] (date):[/b]`（部分客户端产出裸 `(N楼)`）。
   6 帖共 26 条匿名引用，**全部带楼号提示 `(N楼)`，实测 100% 与被引楼 `lou` 一致**——这是匿名引用唯一可靠的楼层线索。
5. **JSON 通道的楼层级 `reply_to` 字段是最强数据源**（741 条关系覆盖 94.9%，目标存在时 100% 准确），但：
   - 客户端现有解析链路**没有保留**它（`ThreadParser.mapRow` 未映射，`ThreadRowInfo` 无此字段）；
   - **HTML 降级通道完全没有楼层级 `reply_to`**（`parseHtmlToRawJson` 不产出）；
   - 引用主楼/跨帖引用本来就没有 `reply_to`。
   → 建议实现「**优先 `reply_to`，content 正则兜底**」，且**两条通道都要能只靠 content 正则工作**。
6. **数据陷阱（必读）**：`data.__R` 的键是**页内行号**不是楼号（楼号取 `lou` 字段）；`__R` 行里混有**楼中楼评论行**
   （`comment_to_id` + `content` 缺失 + `subject="对…发表了一条评论"`，会占用 lou 序列）；JSON `content` 有 HTML 实体残留
   （`&amp;#129314;`），HTML 通道反而已解码；被引楼可能已删（0.7%）。
7. **两层树折叠参数**：引用链深度分布 1 层 61.2%、2 层 24.1%、3 层 8.2%、4+ 层 6.5%（721 条边）；
   被引楼 78.9% 跨页、单楼最高被 16 楼引用。→ 两层树（根 → 直接引用 → 被引用）可覆盖约 85% 的引用，
   深度 ≥3 的 14.7% 需要「继续展开/跳转原楼」入口；默认按「一层」折叠、按需展开「二、三层」是合理取舍。

---

## 1. 调研方法与样本

### 1.1 凭证门禁

按 AGENTS.md / skill `nga-data-fetch` 要求，抓取前先过凭证门禁（固定基准 tid=44191387）：

```bash
node tools/nga-data-fetch/bin/nga-fetch.js verify
# 输出：凭证门禁通过：固定基准 tid=44191387 获取成功（kind=ok，19 楼）
```

本报告所有数据均来自 `read.php?__output=8`（JSON 主通道，GBK 解码 + `preprocessJson` 净化），
HTML 降级通道数据来自 `read.php` 静态页经 `parseHtmlToRawJson` 转换。**任何样本/报告均不含 Cookie。**

### 1.2 样本帖（6 个，覆盖新帖/老帖/匿名帖/引用密集帖）

| # | tid | 标题（截断） | fid | 发帖时间 | 回复数 | 抓取页 | 抓取楼层 | 特点 |
|---|---|---|---|---|---|---|---|---|
| 1 | 44191387 | iOS客户端闪退问题，请下载恩基爱社区app。 | -7 网事杂谈 | 2025-05-26 | 576 | 29（全） | 570 | 长帖、时间跨度 1 年、含跨帖引用与两种主楼引用形式 |
| 2 | 47762778 | 对象报J要把我抓进去 | -7 网事杂谈 | 2026-10-22 | 336 | 17（全） | 332 | **匿名楼主 + 匿名引用密集** |
| 3 | 44681192 | [水一帖]每个人说一个行业秘密吧 | -7 网事杂谈 | 2025-07-23 | 889 | 45（全） | 856 | **引用极密集（57.6% 楼层有引用）、最深引用链 7 层** |
| 4 | 16897906 | [原创内容] 大旋涡随机杀人事件 | -7 网事杂谈 | 2019-04-08 | 252 | 13（全） | 252 | **老帖（2019）**、含 10 个评论行、JSON content 缺失 |
| 5 | 47830870 | 作为一个新手，昨天和朋友开车玩… | -7 网事杂谈 | 2026-11-02 | 202 | 11（全） | 202 | 新帖、含 1 条被删引用的目标 |
| 6 | 47251769 | 这云，你打几分… | -7 网事杂谈 | 2026-07-25 | 248 | 13（全） | 247 | 精选帖、低引用率对照 |

合计：**2459 行、128 页、741 条引用关系**（547 quote + 194 reply-to）。

### 1.3 样本文件与复查脚本

样本与脚本全部位于 `docs/research/samples/`，可逐项复查：

| 文件 | 说明 |
|---|---|
| `tid<tid>-page<NN>.json` | 每页原始 JSON（`read.php?__output=8` 净化后），共 128 个文件 |
| `tid<tid>-pages.json` | 每帖页面索引（页号/楼层/pid/lou/reply_to 摘要） |
| `fetch-thread-pages.mjs` | 抓取脚本（`node docs/research/samples/fetch-thread-pages.mjs <tid> [start] [end]`） |
| `analyze-quotes.mjs` | 引用关系全量分析（A/B/C 语义、变体、链深、reply_to 对照），输出 `quote-analysis.json` |
| `summary-report-data.mjs` | 跨帖汇总，输出 `summary.json`（本报告表格数据源） |
| `analyze-comment-rows.mjs` | `__R` 中「楼中楼评论行」统计，输出 `comment-rows-analysis.json` |
| `verify-numbers.mjs` | 引用形态数量核对（报告表格数据源） |
| `compare-html-channel.mjs` | HTML 降级通道 vs JSON 主通道逐楼对比，输出 `html-channel-<tid>*` |
| `diagnose-comment-rows.mjs` | 单页两通道逐行 pid/author 对照（诊断评论行） |
| `dump-quote-heads.mjs` | 导出所有引用头原文（人工归纳变体用） |
| `quote-analysis.json` | 6 帖引用关系全量统计 |
| `summary.json` | 6 帖汇总百分比 |
| `comment-rows-analysis.json` | 6 帖评论行统计 |
| `html-channel-<tid>.json` | HTML/JSON 通道差异对比结果 |

---

## 2. 引用头的真实形态（全变体清单）

> 判定方法：对每个 `[quote]` 块与每个 `[b]Reply to …[/b]` 头做结构解析，统计出现频次；
> 每条都给出来自哪个样本帖的 `lou` 与原文片段。片段中 `<br/>` 为 JSON 里的换行标记。

### 2.1 载体 A：`[quote]` 引用（带被引正文）—— 547 条

**标准形式（数字 uid，含 date）—— 517 条（94.5%）**

原文（`tid44191387-page03.json`，lou=50）：

```bbcode
[quote][pid=824931876,44191387,1]Reply[/pid] [b]Post by [uid=1197343]miniyoyo[/uid] (2025-05-26 18:55):[/b]<br/><br/>为啥用这个名字，容易引起误会啊。我是直男[/quote]<br/><br/>对呀，就不能起个别的名字吗？非要显得基佬一样。
```

结构：`[pid=A,B,C]Reply[/pid] ␠ [b]Post by [uid=U]name[/uid] ␠ (YYYY-MM-DD HH:mm):[/b]`，随后可跟 `<br/>` 与正文。
命名空间固定：`Reply`、`Post by`、`[b]`、`/b`、`/pid`、`/uid`、`/quote` 的**大小写**在 2459 行样本中从未出现变体；
`[quote]` 与 `[pid=…]` 之间、`[/pid]` 与 `[b]` 之间固定 1 个空格；**载体 A** 的 date 后固定 `:` + `[/b]`
（载体 B 无冒号，见 §2.2）。date 格式 100% 为 `YYYY-MM-DD HH:MM`（740/740）。

**匿名形式 A1（`#anony_` + `[color=gray](N楼)[/color]` 楼号提示）—— 17 条**

原文（`tid47762778-page05.json`，lou=97）：

```bbcode
[quote][pid=885371636,47762778,1]Reply[/pid] [b]Post by [uid]#anony_9edf3df962da423b1440d7b1981289a7[/uid][color=gray](5楼)[/color] (2026-10-22 11:13):[/b]<br/><br/>打少了，多打几下，她只会让你不要再打了[s:a2:doge][/quote]
```

注意：`[uid]` **没有 `=` 属性**，内容是 `#anony_` + 32 位小写 hex；`[/uid]` 后紧跟 `[color=gray](N楼)[/color]`。

**匿名形式 A2（裸 `(N楼)`，无 `color` 包裹）—— 1 条**

原文（`tid44681192-page07.json`，lou=351）：

```bbcode
[quote][pid=833275116,44681192,2]Reply[/pid] [b]Post by [uid]#anony_329fb3aec19781f8dee00759e0b20312[/uid](31楼) (2025-07-24 22:21):[/b]<br/><br/>……
```

**匿名形式 A3（无楼号提示）—— 0 条**（26 条匿名引用全部带楼号提示，只是 A1/A2 两种包裹形式）。

> 现有解析器 `handleQuote.ts` 的 `P_QUOTE_HEADER` 只支持数字 uid + 必有 date，
> 以上 A1/A2 全部 **不匹配**（会退化为普通内联标签渲染）。样本实测：`tid47762778` 的 41 条 quote 中
> 现行正则只覆盖 32 条（78.0%），`tid44681192` 的 377 条只覆盖 363 条（96.3%）。

### 2.2 载体 B：`[b]Reply to …[/b]` 回复头（不带被引正文）—— 194 条

原文（`tid44191387-page01.json`，lou=13）：

```bbcode
[b]Reply to [pid=824926672,44191387,1]Reply[/pid] Post by [uid=38775163]Lmnnnnnnnnn[/uid] (2025-05-26 18:16)[/b]<br/><br/>史诗级草台班子，微博账号加载不了，QQ账号还要我自己输入账密，我都怀疑是要盗我的号
```

结构差异（相对载体 A）：
- 外层是 `[b] … [/b]`，**不是** `[quote]`；
- 前缀多出 `Reply to `；
- `[pid=…]Reply[/pid]` 内部仍相同；
- `(date)` 后**没有 `:`**（载体 A 有 `:`）；
- 没有 `[quote]` 包裹，因此**不携带被引正文**。

该形式**正是** `handlePostBy.ts` 的 `P_REPLY_REF` 所处理的对象（注释称「回复引用头」），说明库作者已见过此形态。

真实语义：NGA 网页/App 的「回复」按钮产生的楼层正文以此头开头（不带被引正文）；「引用」按钮才产生 `[quote]`。
两者对「两层树」而言都是**楼层间引用回复关系**，应同等建边。

匿名形式的载体 B（`tid47762778-page11.json`，lou=205，裸楼号）：

```bbcode
[b]Reply to [pid=885398355,47762778,10]Reply[/pid] Post by [uid]#anony_a8ce8bcc6e81adddcd9b47ac39e2ceac[/uid](181楼) (2026-10-22 15:14)[/b]<br/>你不闹的人尽皆知最后你全锅信不信，国女老技能了
```

带 `[color=gray]` 楼号的匿名载体 B（`tid47762778-page13.json`，lou=248）：

```bbcode
[b]Reply to [pid=885418540,47762778,12]Reply[/pid] Post by [uid]#anony_0d1b05e2b2a6b4ae5b1d68d623f62af7[/uid][color=gray](224楼)[/color] (2026-10-22 18:07)[/b]有理有据，令人信服
```

（注意：载体 B 的 date 后可能**无 `:`**，`[/b]` 前可能直接是正文，甚至 `[/b]` 缺失——正则需容忍尾部噪音；
上两例中 `(2026-10-22 15:14)[/b]` 后直接 `<br/>`，不需要冒号。）

### 2.3 引用主楼：两种形式（11 条，1.5%）

**形式 1：`[tid=<tid>]Topic[/tid]`（App 端产出，无 `reply_to`）—— 9 条**

原文（`tid44191387-page05.json`，lou=95，`from_client="7 iOS"`）：

```bbcode
[quote][tid=44191387]Topic[/tid] [b]Post by [uid=205511]gerraerd[/uid] (2025-05-26 17:27):[/b]<br/><br/>[del]别骂了别骂了[/del]<br/>原客户端 NGA玩家社区 停止更新已久，……
```

匿名主楼同样如此（`tid47762778-page08.json`，lou=151）：

```bbcode
[quote][tid=47762778]Topic[/tid] [b]Post by [uid]#anony_a8ce8bcc6e81adddcd9b47ac39e2ceac[/uid][color=gray](0楼)[/color] (2026-10-22 11:12):[/b]<br/><br/>我和对象处了一年多了，……
```

注意楼号提示是 **`(0楼)`**——与「主楼 = lou 0」一致，可用来反证。

**形式 2：`[pid=0,<tid>,1]`（Web 端产出，无 `reply_to`）—— 2 条**

原文（`tid44191387-page17.json`，lou=322，`from_client="0 /"`）：

```bbcode
[quote][pid=0,44191387,1]Reply[/pid] [b]Post by [uid=205511]gerraerd[/uid] (2025-05-26 17:27):[/b]<br/>[del]别骂了别骂了[/del]<br/>原客户端 NGA玩家社区 停止更新已久，……
```

**结论**：识别「引用主楼」必须同时覆盖 `A === 0` 与 `[tid=<本帖 tid>]Topic[/tid]` 两种；
不要假设「主楼 = 某个真实 pid」，主楼在数据里就是 `pid=0`。

### 2.4 无 `pid` 头的 `[quote]`（不是引用）—— 1 条

原文（`tid44681192-page23.json`，lou=496，`from_client="0 /"`）：

```bbcode
[quote]@echo off<br/>&gt;nul 2&gt;&amp;1 &quot;%SYSTEMROOT%&#92;system32&#92;cacls.exe&quot; …<br/>[/quote]
```

用户把 `[quote]` 当排版容器包代码/文本，头部没有任何 `[pid=…]`/`[tid=…]`。
**防御要求**：`[quote]` 本身不构成引用关系；必须有 `pid` 或 `tid` 链接标签才算。

### 2.5 跨帖引用（B ≠ 本帖 tid）—— 14 条（1.9%）

原文（`tid44191387-page05.json`，lou=96，`from_client="0 /"`）：

```bbcode
[b]Reply to [pid=820789420,43936925,11]Reply[/pid] Post by [uid=1225072]Moonforever[/uid] (2025-04-28 15:15)[/b]
```

- A=820789420 在本帖 `44191387` 的 570 行中**不存在**；B=43936925 是**另一个帖子**（tid）的 id；C=11 是该帖页码。
- 这类楼层的 `reply_to` 字段为 `undefined`，正文往往只有头、没有内容。
- 同一段跨帖头在 `44191387` 出现 13 次、`44681192` 出现 1 次，是用户复制粘贴/跨帖回复的产物。
- **防御要求**：鉴权 `B === 本帖 tid`；B 不匹配时丢弃该引用边（或标记为外部引用），不得把 A 当本帖楼层。

### 2.6 未观察到的变体（仍需防御）

在 2459 行 / 741 条关系中**未出现**，但实现仍应容错（见 §7 正则设计）：

| 变体 | 是否出现 | 防御建议 |
|---|---|---|
| 「匿名用户引用」的 uid 为负数 | **引用头里未出现**。真实形态：引用头用无属性 `[uid]#anony_<32hex>[/uid]`（不是负数）；**楼层行的 `authorid` 才是负数**（样本：tid47762778 匿名楼 `authorid=-1` / `-2`） | 正则用 `-?\d+` 兼容理论形态；匿名身份用 `#anony_` 判定，不要用负数 uid 判定 |
| 省略 uid（`[b]Post by name (date):` 无 uid 标签） | 未出现 | 「无属性 uid」只出现在匿名形态；其余 uid 段缺失时仍可凭 pid 定位 |
| 缺 date（`…[/uid]:[/b]`） | 未出现 | date 段整体可选 |
| 缺 `Post by`（`[b]Post by` 写成别的） | 未出现 | 以 `[pid=…]`/`[tid=…]` 为引用锚点，头装饰可选 |
| `Reply`/`Post by` 大小写变体、多余空格 | 未出现 | 关键字用大小写不敏感 + `\s*` |
| 三行以上 pid 段（`pid=a,b,c,d`） | 未出现（全部 3 段） | 允许 `(\d+)(?:,(\d+))?(?:,(\d+))?` |
| 头内 HTML 实体 | **头内 0 条**（实体只出现在被引正文） | 正则无需处理实体；正文渲染交给 BBCode 解析器 |

### 2.7 变体统计总表（6 帖）

| 形态 | 数量 | 占比 | 样本定位 |
|---|---|---|---|
| 载体 A 标准（`[pid=…]` + 数字 uid + date，含 2 条 `pid=0` 主楼哨兵） | 519 | 70.0% | tid44191387 p3 lou=50 |
| 载体 A 主楼 `[tid=…]Topic[/tid]`（数字 uid） | 7 | 0.9% | tid44191387 p5 lou=95 |
| 载体 A 匿名（`[pid=…]`，A1 color 17 条 + A2 裸楼号 1 条） | 18 | 2.4% | tid47762778 p5 lou=97；tid44681192 p7 lou=351 |
| 载体 A 匿名主楼 `[tid=…]Topic[/tid]` | 2 | 0.3% | tid47762778 p8 lou=151 |
| 载体 A 无链接标签（非引用，应丢弃） | 1 | 0.1% | tid44681192 p23 lou=496 |
| 载体 B 标准（数字 uid） | 188 | 25.4% | tid44191387 p1 lou=13 |
| 载体 B 匿名（`[color=gray]` 楼号 3 条 + 裸楼号 3 条） | 6 | 0.8% | tid44681192 p12 lou=281 |
| ↑ 其中跨帖引用（B ≠ tid，属载体 B 子类，不重复计数） | (14) | (1.9%) | tid44191387 p5 lou=96 |
| **合计** | **741** | 100% | — |

> 分层正则覆盖率（547 条 quote）：现行解析器正则（数字 uid、必有 date、`[pid]` 三段）519/547 = **94.9%**
> （它已覆盖 `pid=0` 主楼哨兵）；加入匿名 uid 后 536/547 = **98.0%**；
> 再加入 `[tid=…]Topic[/tid]` 后 546/547 = **99.8%**；剩余 1 条为「无链接标签的 `[quote]`」，本就应丢弃。

---

## 3. A/B/C 语义（数据证据）

验证方法：把每个 `[pid=A,B,C]` 与**全帖**（所有抓取页）的楼层表对照：
- A 是否等于某楼层 `pid`；
- B 是否等于本帖 `tid`；
- C 是否等于「被引用楼层所在页码」（页码由抓取页号确定，即 `floor(lou/20)+1` 实际所在页）。

### 3.1 A = 被引用楼层 pid（确凿）

6 帖 741 条关系中，`pid` 三段可解析且非跨帖的共 **717 条**：
- A 命中全帖楼层 `pid`：**710 条**
- A = `0`（主楼哨兵）：**2 条**
- A 找不到：**5 条**（0.7%，见 §5.3，均为引用已删除楼层；`reply_to` 同样指向不存在的 pid）
- （另有 14 条跨帖引用、10 条无 pid 三段的关系，不计入本表）

710 + 2 + 5 = 717，覆盖率 100%（在可解析样本内）。

A 命中的判定用「A 等于全帖任一楼层 `pid`」，与 `pid` 值本身无关（NGA pid 全局唯一）。
抽样证据：`[pid=824931876,44191387,1]` → 824931876 是 `tid44191387` 第 1 页 lou=18 的 pid；
`[pid=885371636,47762778,1]` → 该 pid 是 `tid47762778` 第 5 页 lou=91 的 pid（被引楼）。

### 3.2 B = 帖子 tid（确凿）

| 统计 | 数值 |
|---|---|
| 有 `[pid=A,B,C]` 三段的关系 | 731 |
| 其中 B == 本帖 tid | **717（98.1%）** |
| 其中 B ≠ 本帖 tid（跨帖） | **14（1.9%）** |
| B 缺失或非数字 | 0 |

跨帖样本见 §2.5。**实现必须在用 A 建边前校验 B==tid**，否则会把别的帖子的 pid 当本帖楼层（表现为「被引楼找不到」）。

### 3.3 C ≈ 被引用楼页码，但**不可靠**（重要）

统计口径：C 段存在且非跨帖的 717 条中，C 等于「被引楼真实页码」的比例：

| 帖子 | C 总条数 | 命中被引楼页码 | 其中 C=1 且正确 | C=1 但错误 | 其他错误 |
|---|---|---|---|---|---|
| 44191387 | 84 | 73（86.9%） | 15 | 11 | 0 |
| 47762778 | 56 | 56（100%） | 34 | 0 | 0 |
| 44681192 | 490 | 483（98.6%） | 55 | 3 | 4 |
| 16897906 | 23 | 23（100%） | 4 | 0 | 0 |
| 47830870 | 48 | 47（97.9%） | 16 | 0 | 1 |
| 47251769 | 16 | 16（100%） | 11 | 0 | 0 |
| **合计** | **717** | **698（97.4%）** | 135 | **14** | **5** |

**按产出客户端分组（`from_client` 字段）**：

| 客户端 | C 条数 | 命中 | 错误率 |
|---|---|---|---|
| iOS（`7 iOS`） | 129 | 128 | 0.8% |
| Android（`8 Android`） | 334 | 332 | 0.6% |
| Web（`0 /`） | 204 | 189 | **7.4%** |
| 其他（`100 /`、`101 /`、`31 /`） | 50 | 49 | 2.0% |

**错误样本**（`quote-analysis.json` → `thirdPart.samplesWrong`，`tid44191387`）：

| 引用楼层 | 引用者页 | 被引楼 | 被引楼真实页 | C | 客户端 |
|---|---|---|---|---|---|
| lou=111 | 6 | lou=110 | 6 | **1** | `0 /`（Web） |
| lou=115 | 6 | lou=113 | 6 | **1** | `0 /` |
| lou=131 | 7 | lou=128 | 7 | **1** | `0 /` |
| lou=527 | 27 | lou=511 | 26 | **1** | `0 /` |

结论：
- C 的语义确实是「被引用楼所在页码」，但 **Web 端回复/引用生成时经常错误地写 1**（尤其从「回复提醒」进入、只加载第 1 页后引用时）。
- **实现时禁止用 C 做楼层定位/分页计算**；楼层定位一律用 pid（`read.php?pid=<pid>` 服务端会自动定位页）或本地 pid→page 映射。
- 仅可把 C 作为「UI 跳转提示」的弱参考（且 C=1 时需要二次校验）。

### 3.4 主楼被引用的表现（两种形式，均无 `reply_to`）

| 形态 | 条数 | 样本 | `reply_to` |
|---|---|---|---|
| `[quote][tid=<tid>]Topic[/tid] [b]Post by …` | 9 | tid44191387 p5 lou=95；tid47762778 p8 lou=151（匿名，`(0楼)`） | 无 |
| `[quote][pid=0,<tid>,1]Reply[/pid] [b]Post by …` | 1 | tid44191387 p17 lou=322 | 无 |

- 主楼引用只占全部引用关系的 **1.5%（11/741）**，不常见。
- 但「引用楼主」在两层树中是**根节点直连**情形，必须正确归位；否则会退化成「找不到的引用」。
- 楼号提示 `(0楼)` 可用于交叉验证「主楼 = lou 0」。

---

## 4. 引用关系的数据源对比与实现选型

| 数据源 | 覆盖 | 准确率 | 可用性 | 结论 |
|---|---|---|---|---|
| **JSON 楼层级 `reply_to` 字段** | 741 条关系中 703 条有值（94.9%）；主楼引用/跨帖引用没有 | 有值时 100% 等于 `[pid]` 的 A | `read.php?__output=8` 原始数据有；**客户端 `ThreadParser.mapRow` 未映射、`ThreadRowInfo` 无字段**；**HTML 通道完全没有** | 强数据源，但要先改模型/解析器（走镜像流程）才可用；不能单独依赖 |
| **content 正则（载体 A + B）** | 741 条中 740 条可解析（99.9%；唯一漏的是无链接标签的真·无引用楼层） | 头内字段 100%；目标定位靠 A/B 校验 | JSON、HTML 两通道 content 逐字节一致（除实体解码/评论行差异） | **必须实现**；两条通道通吃；不依赖模型改动 |
| **`[tid]`/`pid=0` 主楼形式** | 11 条主楼引用全部可由正则提取（`[tid=…]Topic[/tid]` 9 条 + `[pid=0,…]` 2 条） | 高 | 仅 content | 必须由正则覆盖 |
| **匿名引用的 `(N楼)` 提示** | 26 条匿名引用 100% 带提示 | 楼号 100% 正确 | 仅 content | 正则兜底；也可用 `reply_to`（匿名引用也有 reply_to） |

**建议选型（按优先级）**：
1. **主路径**：`content` 正则提取（载体 A + B + 主楼两种 + 匿名），对 JSON/HTML 两通道一致；
2. **增强路径（可选，需改解析器）**：JSON 通道同时读取楼层级 `reply_to`，用于**校验与补漏**
   （例如 content 为空但 `reply_to` 有值的楼层，见 §6.3）；
3. **禁止**：仅依赖 `reply_to`（HTML 通道无此字段、主楼引用无此字段、模型未保留）。

---

## 5. 统计（覆盖率 / 多引用 / 失踪 / 跨页 / 链深）

### 5.1 引用覆盖率（6 帖）

| 帖子 | 行数 | 有 quote 头行 | 有 Reply-to 头行 | 有任一引用行 | 引用率 | quote 条数 | Reply-to 条数 |
|---|---|---|---|---|---|---|---|
| 44191387 | 570 | 69 | 31 | 100 | 17.5% | 69 | 31 |
| 47762778 | 332 | 41 | 17 | 58 | 17.5% | 41 | 17 |
| 44681192 | 856 | 376 | 117 | 493 | **57.6%** | 377 | 117 |
| 16897906（老） | 252 | 10 | 13 | 23 | 9.1% | 10 | 13 |
| 47830870 | 202 | 35 | 14 | 49 | 24.3% | 35 | 14 |
| 47251769 | 247 | 15 | 2 | 17 | 6.9% | 15 | 2 |
| **合计** | **2459** | — | — | **740** | **30.1%** | **547** | **194** |

- 引用率随帖子类型差异极大：讨论/问答帖 57.6%，生活/分享帖 6.9%-24.3%，老帖 9.1%。
- **两层树必须有「无引用楼层」的归宿**：70% 的楼层不引用任何人，它们应按「直接回复主楼/最后回复」挂到根下。
- 说明：表中「quote 条数 547」含 1 条无链接标签的 `[quote]`（用户手打、不构成引用），
  因此**有效引用关系为 740 条**；后文百分比以 741 为分母（差异 <0.15%，不影响结论）。

### 5.2 一楼层内多个引用（多 quote / quote+ReplyTo 混合）

| 指标 | 6 帖合计 | 说明 |
|---|---|---|
| 一层楼出现 ≥2 个 `[quote]` | **1 层**（tid44681192） | 极罕见（用户手动拼接 BBCode） |
| 一层楼同时有 quote 与 Reply-to 头 | **0 层** | 未观察到 |
| 一层楼出现 ≥2 个引用关系 | **1 层** | 占比 0.04%（2459 行） |
| `[quote]` 嵌套 `[quote]` | **0** | 被引正文中的内层 quote 已被 NGA 剥除 |

实现建议：**每层只取「第一个有效引用」建边**（任务要求一致），其余忽略即可；但提取函数应返回数组以便未来扩展。

### 5.3 被引 `pid` 在全帖中不存在（删楼/被吞）

| 帖子 | 不能定位的关系数 | 样本 |
|---|---|---|
| 44681192 | 4 | `pid=833609513,44681192,11`（被引 3 次，该 pid 不在 `tid44681192` 的 856 行中）；`pid=833695808,44681192,20` |
| 47830870 | 1 | 被引 pid 在本帖 202 行中不存在 |
| 其他 4 帖 | 0 | — |
| **合计** | **5 / 741 = 0.7%** | 全部为「被引楼已删除/被吞」，`reply_to` 指向同样不存在的 pid |

**实现要求**：建边前校验 A ∈ 全帖 pid 集合（或已知楼层缓存）；不命中时：
- 不建边（推荐，避免出现指向幽灵节点的树）；
- 或建「已删除楼」占位节点（UI 显示「该楼层已删除」），但必须防止死循环/空节点。

### 5.4 跨页引用比例

| 帖子 | 同页引用 | 跨页引用 | 引用主楼 | 目标不可定位 |
|---|---|---|---|---|
| 44191387 | 42 | 41 | 4 | 13（全部跨帖） |
| 47762778 | 6 | **50** | 2 | 0 |
| 44681192 | 73 | **412** | 3 | 6（1 跨帖 + 4 删楼 + 1 无链接头） |
| 16897906 | 14 | 9 | 0 | 0 |
| 47830870 | 11 | 36 | 1 | 1（删楼） |
| 47251769 | 4 | 12 | 1 | 0 |
| **合计** | **150** | **560** | **11** | **20** |

**跨页引用占「同页+跨页」的 78.9%**（560/710）。
「目标不可定位」20 条 = 14 条跨帖引用 + 5 条被删楼引用 + 1 条无链接标签的 `[quote]`（不构成引用）。

**实现要求**：
- 两层树**不能只在当前已加载页内建图**——被引用楼大概率在别的页；
- 需要「预取/按需加载被引用页」策略，或允许树节点只有 pid + 页码（点击时再加载）；
- 判断「同页/跨页」可用 `read.php?pid=` 跳转，不依赖 C 段。

### 5.5 引用链深度分布（两层树折叠参数依据）

定义：以楼层为节点、`来源楼 → 被引楼` 为边（每层取第一个有效引用），
链深度 = 沿「被引楼自己又引用了别人」回溯的最大层数（例如 A 引用 B、B 引用 C，则 A 深度=2）。

| 深度 | 边数 | 占比 |
|---|---|---|
| 1（只引用了一个没有引用的楼） | 441 | 61.2% |
| 2（引用了一个「也引用别人」的楼） | 174 | 24.1% |
| 3 | 59 | 8.2% |
| 4 | 30 | 4.2% |
| 5 | 10 | 1.4% |
| 6 | 4 | 0.6% |
| 7（最深，出现在 tid44681192） | 3 | 0.4% |
| **合计** | **721** | 100% |

- **深度 1+2 = 85.3%**：两层树（根 → 第一层引用 → 第二层被引）能覆盖绝大多数阅读场景；
- **深度 ≥3 = 14.7%**（其中 tid44681192 这类引用密集帖更高）：两层树折叠后必须提供「继续展开」入口，
  否则用户看不到更深链条；
- 单帖差异：老帖 16897906 最大深度 4 但深度 1 占 16/23；44681192 最大深度 7。

**入度分布（被引次数）**：绝大多数楼被引 1 次（例如 44681192 的 285 个被引节点中 189 个只被引 1 次，66%），
少数热点楼被引多次——最高单楼被引 **16 次**（tid47762778，lou=8）；
44681192 有 2 个楼分别被引 11 次。→ 两层树的「展开引用列表」需要支持大量同父楼层（列表/分页）。

### 5.6 引用主楼的比例

| 帖子 | 主楼引用条数 | 占该帖关系 |
|---|---|---|
| 44191387 | 4 | 4.0% |
| 47762778 | 2 | 3.4% |
| 44681192 | 3 | 0.6% |
| 47830870 | 1 | 2.0% |
| 47251769 | 1 | 5.9% |
| 16897906 | 0 | 0% |
| **合计** | **11** | **1.5%** |

结论：**引用主楼不常见**（1.5%），但为 0 并不成立——两层树把「引用主楼的楼层」直接挂根节点即可，
不需要单独的「楼主引用」特殊 UI。

### 5.7 「只有引用、没有正文」的楼层

- 6 帖中「去掉引用块/头后正文为空」的楼层：44191387 有 14 层（13 层是跨帖引用——只有 `[b]Reply to` 头、
  无正文；1 层是普通引用后无正文，见下例）；44681192 有 9 层；其他帖 0。
- 这类楼层在树里必须保留（它们是合法的回复），但摘要区会为空，UI 需要占位（如「（仅引用）」）。
- `tid44191387` lou=557 是「引用后正文空且无 `reply_to`」的样本：
  `[quote][pid=825209253,44191387,4]Reply[/pid] [b]Post by [uid=60528507]湛鲤[/uid] (2025-05-28 16:32):[/b]<br/>新版本ios确实不提示网络异常问题了，这点还是要给你们点赞[/quote]`（注意 `reply_to` 缺失，from_client=`0 /`）。

### 5.8 两层树折叠参数建议（数据结论）

综合 §5.4/§5.5：

| 参数 | 建议值 | 数据依据 |
|---|---|---|
| 默认展开层数 | **2 层**（根 + 直接引用链） | 深度 1+2 覆盖 85.3% |
| 每层「引用列表」默认展示条数 | 3-5 条（可展开） | 入度中位数 1，但存在被引 16 次的节点 |
| 深层链处理 | 第 3 层起折叠为「继续展开 / 跳转原楼」 | 深度 ≥3 占 14.7%，不宜全部预渲染 |
| 跨页引用处理 | 树节点先显示摘要（作者/日期/页码），点击按 pid 懒加载 | 跨页引用 78.9% |
| 无引用的楼层 | 作为根节点的「普通回复」列表（按楼层顺序） | 70% 楼层无引用 |
| 主楼引用 | 直接挂根节点（不单独分组） | 仅 1.5% |
| 被删引用目标 | 不建节点（或灰显占位），不得进入循环 | 0.7% 目标不存在 |

---

## 6. 数据陷阱清单（实现必读）

### 6.1 `data.__R` 的键是「页内行号」，不是楼号

`tid44191387-page03.json` 的 `__R` 键为 `0..19`，但行内 `lou` 为 `40..59`（第 3 页）。
`page01` 的键也是 `0..18`（lou 0-18），`page17` 的键 `0..16`（lou 320-336）。
→ **建树/索引必须用 `row.lou`，禁止用 `__R` 的键**。

### 6.2 主楼 `pid` 是 `0`（两通道一致）

- JSON：`data.__R[?].lou===0` 的行 `pid: 0`；
- HTML 降级：`parseHtmlToRawJson` 产出的 `lou=0` 行 `pid` 同样是 **0**（`html-channel-44191387-p1.json`：`htmlMainPid=0`、`jsonMainPid=0`）。
→ 「主楼」用 `lou===0` 识别；引用主楼用 `A===0` 或 `[tid=<tid>]Topic[/tid]` 识别。

### 6.3 `__R` 行里混有「楼中楼评论行」（会占 lou 序列）

特征（`comment-rows-analysis.json`）：

| 字段 | 值 |
|---|---|
| `comment_to_id` | 有值（楼层 pid）或 `-1`（对主题评论） |
| `content` | **缺失（`undefined`）或空串** |
| `subject` | `"对主题发表了一条评论"` / `"对回复(<被评论pid>)发表了一条评论"` |
| `author` | 空字符串（JSON 原始；HTML 通道能补出名字） |
| `type` / `content_length` | 缺失 |

分布：44191387 有 1 行（lou=7，评论目标 824921217）、16897906 有 10 行（9 个对主题 + 1 个对回复），
其余 4 帖 0 行。评论行**占用 lou**（例如 44191387 的 lou=7 就是评论行，不是普通楼层）。

**对引用图的影响**：
- 评论行没有 content → 不能靠 content 提取其引用关系；但 `comment_to_id` 是「评论目标楼层 pid」，
  可作为另一种关系（楼层 ↔ 评论）使用；
- **必须过滤评论行**（`comment_to_id !== undefined` 或 `content === undefined`），否则树里会混入「假楼层」；
- `subject` 中的 `(<pid>)` 也可直接解析出被回复对象（可作为补充数据源）。

**HTML 通道的差异**：`parseHtmlToRawJson` 会把评论行的正文恢复出来（44191387 lou=7 的 HTML content
为 `[b]Reply to [pid=824921217,…]…[/b]<br/><br/>不是啦 是恩基爱社区`），而 JSON 通道 content 为 `""`。
→ HTML 降级时该行反而**可提取引用关系**；JSON 通道则需要 `comment_to_id` 兜底。

### 6.4 JSON `content` 含 HTML 实体，HTML 通道已解码

样本（`tid47762778-page05.json` lou=82）：

| 通道 | content |
|---|---|
| JSON | `聚会卖淫，恶心&amp;#129314;女`（`&amp;` + `#129314;` 双重转义） |
| HTML | `聚会卖淫，恶心🤢女`（解码后，`&#129314;` = 🤢） |

- 引用头本身（到 `[/b]` 为止）**不含任何实体**（2459 行统计为 0），所以正则提取引用不受影响；
- 但「被引正文」的展示需要走 BBCode 解析器，已由 `NgaJsonSanitizer`/实体解码链路处理，**不要在引用提取器里做 HTML 解码**；
- 若在引用提取器里对整段 content 做实体解码，会与渲染层重复解码，导致 `&amp;` → `&` → 二次解码风险。

### 6.5 HTML 降级通道差异汇总（逐页对比）

| 对比项 | 结论 | 证据 |
|---|---|---|
| 楼层数 | 一致 | `html-channel-44191387`、`html-channel-47762778`、`html-channel-44681192` 各页 htmlFloors == jsonFloors |
| content（BBCode） | 基本逐字节一致；差异仅两类：① JSON 实体未解码 ② 评论行 JSON 空/HTML 有 | `contentMismatch` 0-1/页 |
| **引用头文本** | **完全一致（0 条不一致）** | `quoteHeadMismatch=0`、`htmlOnlyQuotes=0`、`jsonOnlyQuotes=0` |
| **楼层级 `reply_to`** | **HTML 通道完全没有**（0 条） | `htmlReplyToPresent=0` vs `jsonReplyToPresent=1..10` |
| 主楼 `pid` | 两通道都是 `0` | `htmlMainPid=0`、`jsonMainPid=0` |

→ **HTML 降级通道可以直接复用同一套 content 正则**；但「reply_to 优先」策略在 HTML 通道必须自动降级为正则提取。

### 6.6 被引楼已删除（0.7%）

见 §5.3。样本（`tid44681192`）：
`[quote][pid=833609513,44681192,11]Reply[/pid] [b]Post by [uid=65406720]moafier1[/uid] (2025-07-27 16:44):[/b]`
—— pid 833609513 在该帖 856 行中不存在（被引 3 次），`reply_to` 同样指向它。
→ 建边失败时要有「目标不存在」分支，不能崩、不能生成悬空节点。

### 6.7 匿名引用没有数字 uid

`[uid]#anony_<32hex>[/uid]` 无属性形式：`[uid=123]` 的正则匹配不到（`=` 都没有），
`AnonymousParser` 的编码名也不等于数字 uid。可用的定位信息：
- `[pid=A,B,C]` 的 A（最可靠）；
- `[color=gray](N楼)[/color]` / `(N楼)` 楼号（26/26 正确）；
- `reply_to`（匿名引用也有，见 §4）。

被引作者 uid/名字：匿名楼层 `authorid` 为负数（样本：tid47762778 主楼 `authorid=-1`、lou=5 `authorid=-2`、lou=181/lou=224 `authorid=-1`），
`author` 字段缺失或为空；**不要尝试从 `#anony_` hash 反推 uid**，也**不要用「负数 uid」判定匿名**（引用头里没有负数 uid）。

### 6.8 `reply_to` 覆盖不全

- 741 条关系中 703 条有匹配的 `reply_to`（94.9%）；
- 无 `reply_to` 的 38 条 = 主楼引用（11）+ 跨帖引用（14）+ 少数异常（13，含「纯引用无正文」和个别客户端漏写）；
- 「有 `reply_to` 但 content 无引用头」的楼层也存在（44191387 1 层、44681192 1 层）——`reply_to` 覆盖**更广**；
- `reply_to` 目标不存在的 5 条与 §5.3 一致。

---

## 7. ArkTS 实现建议

### 7.1 正则清单（分层，ArkTS 可直接用）

> ArkTS 支持标准 `RegExp`；避免 `matchAll`（用 `exec` 循环或 `indexOf` 扫描），避免解构/`any`。
> 建议全部使用**大小写不敏感**（`i`）与**非贪婪**（`*?`），并对每段加 `\s*` 容忍空格。

**R1｜quote 块定位（先切块，再解析头）**

```ts
const RE_QUOTE_OPEN: RegExp = /\[quote(?:=[^\]]*)?\]/gi
const RE_QUOTE_CLOSE: RegExp = /\[\/quote\]/gi
// 用 indexOf('[quote') + indexOf('[/quote]') 手动配对更快；未闭合时以 content 末尾为界
```

**R2｜quote 引用头（载体 A，含主楼/匿名，一次匹配出全部字段）**

```ts
// 数字 uid 版
const RE_QUOTE_HEAD_STD: RegExp =
  /^\[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\]\s*\[b\]\s*Post by\s*\[uid=(-?\d+)\]([\s\S]*?)\[\/uid\]\s*(?:\(([^()]*)\))?\s*:?\s*\[\/b\]/i

// 匿名 uid 版（[uid]#anony_xxx[/uid]，可选 [color=gray](N楼)[/color] 或裸 (N楼)）
const RE_QUOTE_HEAD_ANON: RegExp =
  /^\[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\]\s*\[b\]\s*Post by\s*\[uid\]#anony_([0-9a-f]+)\[\/uid\]\s*(?:\[color=gray\]\s*\((\d+)楼\)\s*\[\/color\]|\((\d+)楼\))?\s*\(([^()]*)\)\s*:?\s*\[\/b\]/i

// 主楼版（两种）
const RE_QUOTE_HEAD_TID: RegExp =
  /^\[tid=(\d+)\]Topic\[\/tid\]\s*\[b\]\s*Post by\s*(?:\[uid=(-?\d+)\]([\s\S]*?)\[\/uid\]|\[uid\]#anony_([0-9a-f]+)\[\/uid\])\s*(?:\[color=gray\]\s*\((\d+)楼\)\s*\[\/color\]|\((\d+)楼\))?\s*\(([^()]*)\)\s*:?\s*\[\/b\]/i
```

**R3｜Reply-to 回复头（载体 B）**

```ts
const RE_REPLY_TO_HEAD: RegExp =
  /\[b\]\s*Reply to\s*\[pid=(\d+),(\d+),(\d+)\]Reply\[\/pid\]\s*Post by\s*(?:\[uid=(-?\d+)\]([\s\S]*?)\[\/uid\]|\[uid\]#anony_([0-9a-f]+)\[\/uid\])\s*(?:\[color=gray\]\s*\((\d+)楼\)\s*\[\/color\]|\((\d+)楼\))?\s*\(([^()]*)\)\s*:?/i
// 注意：真实数据里 date 后可能直接跟正文（无 ':'、无 [/b]），所以不要求 [/b] 收尾
```

**R4｜宽松兜底（任意 `[pid=…]`，用于未来未知格式）**

```ts
const RE_PID_LOOSE: RegExp = /\[pid=(\d+)(?:,(\d+))?(?:,(\d+))?\]/i
const RE_TID_LOOSE: RegExp = /\[tid=(\d+)\]/i
```

**R5｜楼号提示（匿名/主楼辅助校验）**

```ts
const RE_FLOOR_HINT: RegExp = /(?:\[color=gray\]\s*\((\d+)楼\)\s*\[\/color\]|\((\d+)楼\))/i
```

### 7.2 提取函数伪代码（ArkTS 子集风格）

```ts
// 引用关系（一条）
export class QuoteRef {
  sourcePid: number = 0          // 本楼 pid
  sourceLou: number = 0          // 本楼 lou（调用方已知）
  kind: string = ''              // 'quote' | 'reply-to'
  targetPid: number = -1         // 被引 pid；0 = 主楼哨兵；-1 = 无效
  targetLou: number = -1         // 被引楼 lou（由 pid→lou 映射填充；未知为 -1）
  targetTid: number = 0          // B 段（跨帖时 != 本帖 tid）
  targetPageHint: number = 0     // C 段（仅参考，不可当真实页码）
  targetFloorHint: number = -1   // 匿名引用的 (N楼)
  targetUid: number = -2         // 被引作者 uid；-1 = 匿名；-2 = 未知
  targetName: string = ''        // 被引作者显示名（匿名时为空）
  isAnonymousTarget: boolean = false
  isMainFloor: boolean = false   // 是否引用主楼
  isCrossThread: boolean = false
  isSelf: boolean = false
}

// 上下文：由调用方准备（全帖已加载楼层）
export class QuoteExtractContext {
  tid: number = 0
  pidSet: Set<string> = new Set()   // 全帖已知楼层 pid（字符串，便于 contains）
  pidToLou: Map<string, number> = new Map()
  mainFloorLou: number = 0          // 主楼 = 0
}

// 主入口：从 content 提取引用关系（返回数组，通常长度 0 或 1）
export function extractQuoteRefs(content: string, sourcePid: number, sourceLou: number,
  ctx: QuoteExtractContext): QuoteRef[] {
  const out: QuoteRef[] = []
  if (content.length === 0) return out

  // 1) 收集 quote 块（手动 indexOf 配对，天然支持多块）
  const blocks: string[] = []
  let cursor: number = 0
  while (cursor < content.length) {
    const open: number = content.indexOf('[quote', cursor)
    if (open < 0) break
    const close: number = content.indexOf('[/quote]', open)
    const end: number = close < 0 ? content.length : close + '[/quote]'.length
    blocks.push(content.substring(open, end))
    cursor = open + 6
    if (blocks.length > 8) break   // 防御：异常内容里大量 quote
  }

  // 2) 逐块解析头（块内头部一般在最前面）
  for (let i = 0; i < blocks.length; i++) {
    const block: string = blocks[i]
    const ref: QuoteRef = parseQuoteBlockHead(block, sourcePid, sourceLou, ctx)
    if (ref !== null && ref.targetPid !== -1) out.push(ref)
  }

  // 3) Reply-to 头（载体 B）：扫描 [b]Reply to 出现点
  let idx: number = 0
  while (idx < content.length) {
    const at: number = content.indexOf('[b]', idx)   // 可用正则更精确
    if (at < 0) break
    const headEnd: number = content.indexOf('[/b]', at)
    const headText: string = headEnd < 0 ? content.substring(at, at + 400)
      : content.substring(at, Math.min(headEnd + 4, at + 400))
    if (headText.indexOf('Reply to') >= 0 && headText.indexOf('[pid=') >= 0) {
      const ref: QuoteRef = parseReplyToHead(headText, sourcePid, sourceLou, ctx)
      if (ref !== null && ref.targetPid !== -1) out.push(ref)
    }
    idx = at + 3
  }

  // 4) 只保留第一个有效引用（两层树建边规则；保留数组便于未来扩展）
  return out
}

// 解析 quote 块头（顺序：标准 → 匿名 → 主楼 tidTag → 宽松兜底）
function parseQuoteBlockHead(block: string, sourcePid: number, sourceLou: number,
  ctx: QuoteExtractContext): QuoteRef | null {
  // 2.1 标准
  let m: RegExpExecArray | null = RE_QUOTE_HEAD_STD.exec(block)
  if (m !== null) {
    return buildRef(parseInt(m[1]), parseInt(m[2]), parseInt(m[3]),
      parseInt(m[4]), m[5], '', sourcePid, sourceLou, ctx, 'quote')
  }
  // 2.2 匿名
  m = RE_QUOTE_HEAD_ANON.exec(block)
  if (m !== null) {
    return buildRef(parseInt(m[1]), parseInt(m[2]), parseInt(m[3]),
      -1, '', m[4], sourcePid, sourceLou, ctx, 'quote')
  }
  // 2.3 主楼 [tid=…]Topic[/tid]
  m = RE_QUOTE_HEAD_TID.exec(block)
  if (m !== null) {
    return buildMainFloorRef(parseInt(m[1]), sourcePid, sourceLou, ctx, 'quote')
  }
  // 2.4 兜底：只取 [pid=…]，其余字段缺省（容忍未知变体，但要 B==tid 校验）
  m = RE_PID_LOOSE.exec(block)
  if (m !== null) {
    const a: number = parseInt(m[1])
    const b: number = m[2] !== undefined ? parseInt(m[2]) : -1
    const c: number = m[3] !== undefined ? parseInt(m[3]) : 0
    return buildRef(a, b, c, -2, '', '', sourcePid, sourceLou, ctx, 'quote')
  }
  // 2.5 [tid=…] 兜底
  m = RE_TID_LOOSE.exec(block)
  if (m !== null && parseInt(m[1]) === ctx.tid) {
    return buildMainFloorRef(ctx.tid, sourcePid, sourceLou, ctx, 'quote')
  }
  return null   // [quote] 里没有链接标签 → 用户手打，不是引用
}

// 把解析出的 A/B/C/uid 归一成 QuoteRef（核心校验逻辑）
function buildRef(a: number, b: number, c: number, uid: number, name: string,
  anonHash: string, sourcePid: number, sourceLou: number,
  ctx: QuoteExtractContext, kind: string): QuoteRef | null {
  const ref: QuoteRef = new QuoteRef()
  ref.sourcePid = sourcePid
  ref.sourceLou = sourceLou
  ref.kind = kind
  ref.targetTid = b
  ref.targetPageHint = c
  ref.isAnonymousTarget = anonHash !== ''
  if (anonHash === '') ref.targetUid = uid
  ref.targetName = name

  // ① 跨帖：B 必须是本帖 tid（B 缺失时放行给 ② 判定）
  if (b > 0 && b !== ctx.tid) { ref.isCrossThread = true; ref.targetPid = -1; return ref }

  // ② 主楼哨兵
  if (a === 0) {
    ref.isMainFloor = true
    ref.targetPid = 0
    ref.targetLou = ctx.mainFloorLou
    return ref
  }

  // ③ 必须在全帖 pid 集合中（防删楼/幽灵）
  const key: string = a.toString()
  if (!ctx.pidSet.has(key)) { ref.targetPid = -1; return ref }

  ref.targetPid = a
  const lou: number | undefined = ctx.pidToLou.get(key)
  if (lou !== undefined) ref.targetLou = lou
  if (a === sourcePid) ref.isSelf = true
  return ref
}
```

> 说明：`targetLou` 需要「全帖楼层表」才能得到；若树是**按页增量加载**的，可先只存 `targetPid`，
> 等目标页加载后再解析成楼；或直接用 `read.php?pid=<pid>` 跳转。

### 7.3 引用图构建（两层树）

```text
输入：当前已加载楼层 rows（含 pid/lou/page/content/reply_to）+ 全帖 pid→lou/page 缓存
步骤：
1. 过滤非楼层行：
   - comment_to_id !== undefined（楼中楼评论行）→ 跳过（或单独作为评论节点）
   - content === undefined 且 comment_to_id === undefined（纯占位行）→ 跳过
2. 节点表：node[pid] = { pid, lou, page, authorid, author, content, hasQuote }
3. 对每层取「第一个有效引用」建边（extractQuoteRefs → 第一个 targetPid >= 0 且 !isCrossThread）：
   - 若 JSON 通道且有 row.reply_to：targetPid 优先取 reply_to（校验其在 node 表中或全帖 pid 集合）
   - 否则用 content 正则结果
   - 目标不存在（pid 不在集合）→ 丢弃边，记录 orphan 计数（debug）
   - targetPid === 0（主楼）→ 目标节点 = 主楼节点
4. 根节点 = 主楼（lou === 0）；无引用楼层 = 根的直接子节点（按 lou 排序）
5. 第一层：引用根节点的楼层；第二层：引用第一层的楼层（递归深度 2）
6. 深层（深度 >= 3）：折叠为「继续展开」占位节点，点击时按 pid 懒加载；同时提供「跳转原楼」
7. 环保护：parent 链上若出现重复 pid，截断该边（样本未观察到自引用，但防御）
```

**两层树节点数据建议**：

```ts
export class QuoteTreeNode {
  kind: string = 'floor'        // 'main' | 'floor' | 'quote-ref' | 'deleted'
  pid: number = 0
  lou: number = 0
  page: number = 0              // 由 pid→page 映射；C 段不可信
  authorid: number = 0
  author: string = ''
  contentPreview: string = ''   // 纯文本摘要（不重新解析 BBCode）
  children: QuoteTreeNode[] = []
  quotedCount: number = 0       // 被引次数（用于折叠提示）
  isLoaded: boolean = false     // 跨页目标是否已加载
  refKind: string = ''          // 'quote' | 'reply-to'
}
```

### 7.4 与现有 BBCode 解析器的关系（重要边界）

现有镜像真源里已有两个相关 handler，但**都不足以直接产出引用图**：

| 现实现 | 能力 | 缺口（本调研实证） |
|---|---|---|
| `tools/bbcode-ts/src/parser/bbcode/block-handlers/handleQuote.ts` `P_QUOTE_HEADER` | 识别 `[quote][pid=A,B,C]Reply[/pid] [b]Post by [uid=U]name[/uid] (date):[/b]` → POST_BY 节点 | 只支持**数字 uid**、**必有 date**、只支持 `[pid]` 形式；**匿名（`#anony_`）、主楼 `[tid=]Topic[/tid]`、`[pid=0]` 均不匹配**（实测：47762778 覆盖率 78.0%） |
| `tools/bbcode-ts/src/parser/bbcode/block-handlers/handlePostBy.ts` `P_REPLY_REF` | 识别 `[b]Reply to [pid=…]…` → POST_BY 节点 | 只支持数字 uid、必有 date、只支持 `[pid]` 形式；且 POST_BY 节点**不保留 pid 原始数值**（被内联解析为链接/文本），从 BBNode 反推 pid 很别扭 |

**建议**：
1. **不要改动现有 handler**（它们是渲染语义的一部分，改动要走 `bbcode-ts` 镜像门禁流程、影响快照）；
2. 另写**独立提取器**（数据层，输入 content 字符串），在 `ThreadParser` 之后或渲染前调用；
3. 提取器与渲染解耦，JSON/HTML 两条通道共用；
4. 若未来把 `reply_to` 纳入模型（`ThreadRowInfo.replyTo`），`ThreadParser.ets` 不在镜像清单内（可直接改 entry 侧），
   但 `NgaRawTypes.NgaRawPost.reply_to` 已有可选字段，改动成本低；
5. 若未来要让解析器支持匿名引用头（视觉上正确渲染），那是**另一个任务**，必须走镜像流程。

### 7.5 性能与实现细节

- `content` 长度：样本中单楼最大约数 KB；引用头绝大多数位于 content 开头（NGA 的引用/回复头由编辑器生成在正文前），
  但**仍建议扫描全文、命中即退出**，不要假设「只在开头 512 字符内」而漏判；
- 正则使用 `exec` 循环而非 `matchAll`；`RegExp` 对象建议 `const` 复用（ArkTS 允许正则字面量常量）；
- 提取结果按 `pid` 缓存（同一楼层重复渲染不重复解析）；
- 建图复杂度 O(n)（节点数 = 楼层数），跨页引用需要「目标 pid 未知 lou」状态；
- **不要在主线程对全帖（上千楼）做同步提取**，应在解析页数据时增量提取。

---

## 8. 风险与未决问题

| 风险 | 影响 | 缓解 |
|---|---|---|
| C 段语义不稳定（Web 端常写 1） | 若用来分页/跳转会错页 | 只用 pid 跳转；C 仅参考 |
| `reply_to` 未进入客户端模型 | 无法直接用最强数据源 | 先走 content 正则；如需启用 reply_to，改 `ThreadParser.ets`（entry 侧可直接改，但需 DevEco 编译验证） |
| HTML 降级通道无 `reply_to` | 降级时覆盖率下降 | content 正则必须完整覆盖（本报告已给） |
| 评论行占 lou | 树中出现「假楼层」、楼层号错位 | 过滤 `comment_to_id` / `content===undefined` 行 |
| 被引楼已删（0.7%） | 悬空引用 | 建边失败丢弃 + debug 计数 |
| 匿名引用无数字 uid | 作者身份缺失 | 用 pid / 楼号提示 / reply_to 定位；UI 显示「匿名用户」 |
| 跨帖引用（1.9%） | 误把外帖 pid 当本帖楼层 | 强制 `B === 本帖 tid` 校验 |
| 「回复」关系（载体 B）被忽略 | 漏掉 26% 引用关系 | 必须实现载体 B 正则 |
| 评论行 content 缺失（16897906 有 10 行） | 该行无法提取引用 | 该行本就无正文；可用 `comment_to_id` 建「评论↔楼层」关系，或直接跳过 |
| JSON 实体未解码 | 正则不受影响；若自行解码可能二次解码 | 引用提取不碰实体，正文展示交给既有 BBCode 链路 |
| 引用图规模爆炸（超大帖 8800+ 楼） | 渲染/内存 | 增量提取 + 树节点懒加载 + 只保留两层 |

**未确认项**：
1. 「负 uid」的真实形态：样本未出现（NGA 现用 `#anony_` 编码）；若历史数据有 `[uid=-1]`，正则已用 `-?\d+` 兼容。
2. 客户端 `read.php?__output=8` 是否对所有帖子都返回楼层级 `reply_to`：6 帖覆盖 94.9%，主楼/跨帖无；
   是否与小版本/客户端有关未验证。
3. 评论行（`comment_to_id`）在 App 端实际 UI 的表现（是否作为「点评」显示）未在客户端验证，需 UI 侧确认。
4. 楼主引用自己的「主楼 pid=0」与「楼主回复自己的楼」的树归属：建议都按 pid 正常建边，主楼引用挂根。

---

## 9. 附录

### 9.1 关键统计文件

- `docs/research/samples/quote-analysis.json`：6 帖全量统计（格式签名、严格正则覆盖、C 按客户端、链深、入度、样本）
- `docs/research/samples/summary.json`：跨帖汇总（表格数据来源）
- `docs/research/samples/comment-rows-analysis.json`：评论行统计
- `docs/research/samples/html-channel-44191387.json` / `-47762778.json` / `-44681192.json`：通道对比

### 9.2 关键样本原文（可直接复查）

| 场景 | 文件 | 定位 | 原文片段 |
|---|---|---|---|
| 标准 quote | `tid44191387-page03.json` | lou=50 | `[quote][pid=824931876,44191387,1]Reply[/pid] [b]Post by [uid=1197343]miniyoyo[/uid] (2025-05-26 18:55):[/b]` |
| Reply to 回复 | `tid44191387-page01.json` | lou=13 | `[b]Reply to [pid=824926672,44191387,1]Reply[/pid] Post by [uid=38775163]Lmnnnnnnnnn[/uid] (2025-05-26 18:16)[/b]` |
| 引用主楼（App） | `tid44191387-page05.json` | lou=95 | `[quote][tid=44191387]Topic[/tid] [b]Post by [uid=205511]gerraerd[/uid] (2025-05-26 17:27):[/b]` |
| 引用主楼（Web） | `tid44191387-page17.json` | lou=322 | `[quote][pid=0,44191387,1]Reply[/pid] [b]Post by [uid=205511]gerraerd[/uid] (2025-05-26 17:27):[/b]` |
| 匿名引用（color 楼号） | `tid47762778-page05.json` | lou=97 | `[uid]#anony_9edf3df962da423b1440d7b1981289a7[/uid][color=gray](5楼)[/color]` |
| 匿名引用（裸楼号） | `tid44681192-page07.json` | lou=351 | `[uid]#anony_329fb3aec19781f8dee00759e0b20312[/uid](31楼)` |
| 匿名引用主楼 | `tid47762778-page08.json` | lou=151 | `[quote][tid=47762778]Topic[/tid] [b]Post by [uid]#anony_a8ce8bcc6e81adddcd9b47ac39e2ceac[/uid][color=gray](0楼)[/color]` |
| 跨帖引用 | `tid44191387-page05.json` | lou=96 | `[b]Reply to [pid=820789420,43936925,11]Reply[/pid] Post by [uid=1225072]Moonforever[/uid] (2025-04-28 15:15)[/b]` |
| 无链接标签的 quote | `tid44681192-page23.json` | lou=496 | `[quote]@echo off<br/>…` |
| 评论行（JSON 空 content） | `tid44191387-page01.json` | lou=7 | `subject="对回复(824921217)发表了一条评论"`，`content=""`，`comment_to_id=824921217` |
| 被删引用目标 | `tid44681192-page12.json` | lou=220 | `[pid=833609513,44681192,11]`（该 pid 不在全帖 856 行中） |
| 实体差异（JSON） | `tid47762778-page05.json` | lou=82 | `聚会卖淫，恶心&amp;#129314;女`（HTML 通道为 `🤢`） |

### 9.3 复现步骤

```bash
# 1) 凭证门禁（项目根）
node tools/nga-data-fetch/bin/nga-fetch.js verify

# 2) 抓取样本（示例：6 帖；tid 见 §1.2）
node docs/research/samples/fetch-thread-pages.mjs 44191387 1 29
node docs/research/samples/fetch-thread-pages.mjs 47762778 1 17
node docs/research/samples/fetch-thread-pages.mjs 44681192 1 45
node docs/research/samples/fetch-thread-pages.mjs 16897906 1 13
node docs/research/samples/fetch-thread-pages.mjs 47830870 1 11
node docs/research/samples/fetch-thread-pages.mjs 47251769 1 13

# 3) 全量分析 + 汇总 + 评论行
node docs/research/samples/analyze-quotes.mjs 44191387 47762778 44681192 16897906 47830870 47251769
node docs/research/samples/summary-report-data.mjs
node docs/research/samples/analyze-comment-rows.mjs 44191387 47762778 44681192 16897906 47830870 47251769

# 4) HTML 降级通道对比（需要 tools/bbcode-ts/dist 已构建）
node docs/research/samples/compare-html-channel.mjs 44191387 1 3 17
node docs/research/samples/compare-html-channel.mjs 47762778 5
node docs/research/samples/compare-html-channel.mjs 44681192 14
```
