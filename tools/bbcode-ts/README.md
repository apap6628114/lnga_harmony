# tools/bbcode-ts — NGA 解析链路镜像与验证规则

本文档是 `tools/bbcode-ts` 的强制工作规则，不是背景介绍或可选建议。

规范词含义：

- **MUST**：必须执行；不满足即不得宣称修复完成。
- **MUST NOT**：禁止执行。
- **SHOULD**：通常应执行；跳过时必须有可复核理由。
- **MAY**：按问题需要选择。

## Rule 0：先明确本工具解决什么问题

任何 Agent/AI 在抓取帖子、诊断异常或修改代码前，MUST 完整阅读 Rule 0 至 Rule 8；
MUST NOT 只复制末尾命令速查后跳过数据源、真源边界、特殊行为和门禁规则。

`tools/bbcode-ts` MUST 被视为 HarmonyOS 客户端解析逻辑的 Node.js 镜像验证工程，
不是独立于客户端的第二套实现。它承担三项职责：

1. 验证 JSON 主通道 `content` 的 BBCode 解析、语义树和渲染 Run。
2. 验证 HTML 降级通道把 `read.php` 静态 HTML 还原成 JSON API 同形状数据的能力。
3. 在毫秒级 Node 测试通过后，把 ArkTS 子集兼容的 TS 真源机械同步回 `.ets`。

必须区分以下两条链路：

```text
JSON 主通道：read.php?__output=8 → preprocessJson → JSON.parse
            → parseThreadData → content → parseBBCode → BBNode → InlineRun

HTML 降级通道：read.php 静态 HTML → parseHtmlToRawJson
              → 与 JSON 同形状对象 → parseThreadData → 后续链路相同
```

## Rule 1：数据源优先级不得颠倒

### R1.1 客户端帖子详情 MUST 先走 JSON

正常客户端调用链以 `entry/src/main/ets/service/api/ThreadApi.ets::getThread` 为准：

1. MUST 首先请求 `read.php?__output=8`。
2. JSON 请求、净化、解析或 NGA 业务检查失败后，MAY 降级抓取 `read.php` HTML。
3. `KEY_FORCE_HTML_MODE` 只用于显式调试，MUST NOT 被描述为正常默认路径。
4. 仅有 `pid`、没有 `tid` 的客户端场景当前直接走 HTML，这是现有特例，不改变 `tid` 帖子
   “JSON 优先”的总规则。

### R1.2 不同事实必须使用不同基准

| 要判断的问题 | 基准 | 规则 |
|---|---|---|
| 客户端先请求哪个通道 | `ThreadApi.getThread` | JSON 为主，HTML 为降级 |
| 楼层原始字段和正文是什么 | `__output=8` JSON | MUST 作为数据基准真值 |
| HTML 降级恢复得是否正确 | 同帖同页 JSON/HTML 成对样本 | MUST 以 JSON 对照 HTML |
| BBCode 最终视觉语义是什么 | 官方网页渲染后的 DOM/Run | 官方怎么渲染，解析器就怎么解释 |
| JSON 是否因传输异常而不可用 | 原始响应、解码结果、解析错误 | MUST 留证后才进入 HTML 降级 |

### R1.3 其他数据模式不得冒充主通道

- `__output=9` XML MAY 用于确认服务端是否也发生截断或字段缺失，但 MUST NOT 作为客户端
  常规取数方案；它与 JSON 同源，ArkTS 当前也没有更合适的 XML 解析链路。
- `__output=1` / `lite=js` 是 `window.script_muti_get_var_store={JSON}` 的 JS 包装，MUST NOT
  被当作独立数据源。
- 浏览器 DOM MAY 用于官方渲染差分，但 MUST NOT 替代 JSON 原始 `content` 样本。
- HTML 转 JSON MUST 被称为“降级/覆盖验证”，MUST NOT 被写成首选或更完整的数据来源。

## Rule 2：异常帖子调查必须按固定分流执行

所有命令均从 `tools/bbcode-ts` 目录执行。正常调试 MUST 把登录 Cookie 持久化到已被 gitignore 的
`.nga-cookie.txt`；`NGA_COOKIE` 只用于同一命令的一次性显式覆盖。Cookie MUST NOT 提交到仓库。

### R2.1 第一步：通过 Chrome DevTools MCP 获取并持久化请求凭证

抓取脚本不会执行登录。Agent MUST 通过 `chrome-devtools` MCP 控制用户现有 Chrome 登录会话；
MUST NOT 改用无登录态的网页搜索、普通 HTTP 抓取或要求用户把 Cookie 粘贴到聊天中。

#### R2.1.1 绑定已登录 Chrome 页面

1. MUST 用 `list_pages` 找到现有的 `https://bbs.nga.cn/` 标签页并选择它；没有时才可用
   `new_page` / `navigate_page` 打开 NGA。
2. MUST 用 `take_snapshot` 确认页面已登录。若仍在登录页、出现验证码或需要用户输入密码/二次验证，
   MUST 保留该 Chrome 标签页并请用户完成登录；Agent 不得伪造登录态。
3. 登录跳转完成后 MUST 保持同一 Chrome DevTools MCP 会话和同一 `bbs.nga.cn` 页面；不得换成
   `ngabbs.com`、其他浏览器或无登录态的新会话取 Cookie。

#### R2.1.2 `document.cookie` 只作为初始候选

Agent MAY 先用 `evaluate_script` 在 `bbs.nga.cn` 页面执行：

```js
() => document.cookie
```

但 `document.cookie` 的返回值 MUST NOT 直接视为最终可持久化凭证。Agent MUST 解析分号分隔的
键值对并确认至少存在：

```text
ngaPassportUid=<非空数字>
ngaPassportCid=<非空原始值>
```

当前 `.nga-cookie.txt` 的无明文基准是：单行完整 Cookie 字符串、共 12 个键值对、694 字符；
其中 UID 长度为 8，CID 长度为 40。该数据只用于本机当前登录态的结构核对，MUST NOT 写成 NGA
永久固定长度，也 MUST NOT 在日志、回复或测试输出中显示实际 UID/CID。

#### R2.1.3 CID 必须从实际请求核验

`ngaPassportCid` 是会话凭证，不是 UID、用户名 Cookie 或可自行推导的值。以下情况均视为
CID 尚未可靠取得：

- `document.cookie` 只有 `ngaPassportUid`、没有 `ngaPassportCid`；
- CID 为空、被截断、带 `Cookie:` 前缀或混入 `Path` / `Expires` 等 `Set-Cookie` 属性；
- Cookie 来自其他 NGA 域名/路径，而不是当前成功访问 `bbs.nga.cn` 的请求；
- Node 抓取返回 `error 15`，但同一 Chrome 页面仍能正常查看登录后内容。

遇到上述情况 MUST 按以下顺序处理：

1. 等待登录重定向完成，必要时用 `navigate_page` 重新进入目标帖子，再次执行 `evaluate_script`；
   SHOULD 像客户端 `LoginPage` 一样轮询，直到 UID 与 CID 同时出现，不能只看到 UID 就落盘。
2. 用 `list_network_requests` 找到同一页面刚刚成功发往 `https://bbs.nga.cn/` 的 `read.php`
   或 `nuke.php` 请求。
3. 用 `get_network_request` 检查该成功请求实际携带的 `Cookie` 请求头；该请求头比
   `document.cookie` 更权威，因为它已经过 Chrome 的 Domain、Path、Secure 和可见性规则筛选。
4. MUST 从实际请求头按精确键名提取 `ngaPassportCid`，原样保留 `=` 后到下一个 `;` 之前的值；
   MUST NOT `decodeURIComponent`、截短、转小写或拿 `ngaPassportUid` 代替。
5. 如果请求头存在多个同名 CID，MUST 使用能够产生成功登录请求的那一项；无法判定时不得覆盖
   现有凭证，必须重新登录后再捕获一次。

#### R2.1.4 必须写入 `.nga-cookie.txt` 才算持久化完成

Chrome DevTools MCP 取得的是浏览器当前内存状态。只在某一次 shell 中设置
`$env:NGA_COOKIE` / `export NGA_COOKIE` 不能跨 Agent 工具调用可靠保留，因此正常调试流程 MUST
把已核验的完整 Cookie 请求头值写入：

```text
tools/bbcode-ts/.nga-cookie.txt
```

持久化规则：

1. SHOULD 保存成功请求实际携带的完整 Cookie 键值串，与当前文件形态一致；不得只记录工具返回对象、
   CID 截图或一条临时环境变量命令。
2. 文件 MUST 为单行纯 Cookie 值，不带 `Cookie:` 前缀，不带 JSON 引号，不带 `Set-Cookie` 属性。
3. 文件 MUST 同时包含非空 `ngaPassportUid` 与 `ngaPassportCid`；CID 缺失时禁止写入。
4. Agent MUST 在同一任务内完成“Chrome 获取 → CID 核验 → 文件写入 → 请求验证”，不得把内存中的
   Cookie 留给后续任务猜测。
5. `NGA_COOKIE` 环境变量优先于文件。若外层环境已有旧值，MUST 清除或更新，否则它会遮蔽刚写入的
   `.nga-cookie.txt`。
6. `.nga-cookie.txt` 已在项目根 `.gitignore` 中登记；提交前仍 MUST 用 `git status` 确认未被跟踪。
7. Cookie、UID 和 CID MUST NOT 出现在 commentary、最终回复、Issue、测试快照或命令输出中。

#### R2.1.5 写入后必须实际验证

MUST 在不显式设置 `NGA_COOKIE` 的新命令中运行一次 JSON 主通道，使脚本从
`.nga-cookie.txt` 读取持久化凭证；成功标准见 R2.3：

```bash
npm run inspect:json -- <tid> <page>
```

若目标 JSON 本身发生已确认的服务端半包，MAY 改用下面的 HTML 请求验证“凭证可用”，但这只验证
Cookie，不改变 JSON 主通道优先级：

```bash
npm run inspect:html -- <tid> <page> <lou>
```

返回 `error 15`、未登录或权限错误时，MUST 回到 R2.1.3 重新核验 CID；不得直接进入解析器修复。

### R2.2 第二步：定位 tid、page、lou

MUST 从报告中记录：

- 帖子 `tid`；
- 异常楼层 `lou` 或 `pid`；
- 客户端实际加载页码 `page`；
- 异常属于原始数据、BBCode 解析、Run 格式化、ArkUI 渲染，还是 HTML 降级恢复。

楼层未知时 MAY 从第 1 页开始；不得在没有真实输入的情况下猜标签语义。

### R2.3 第三步：先拉 JSON 主通道

```bash
# 整页 JSON；输出 raw-tid<tid>-page<page>.json
npm run inspect:json -- <tid> <page>

# 提取指定楼层 content 并直接固化为样本
npm run inspect:json -- <tid> <page> samples/tid<tid>-lou<lou>-case.txt <lou>

# 示例：tid=47373567，第 2 页，第 20 楼
npm run inspect:json -- 47373567 2 samples/tid47373567-lou20-case.txt 20
```

JSON 成功必须同时满足：

1. HTTP 成功；
2. GBK/GB18030 解码并经 `preprocessJson` 等价净化后可 `JSON.parse`；
3. 没有 NGA 业务错误；
4. `data.__R` 存在；
5. 目标页与目标楼层存在，且 `content` 是待调查的真实输入。

JSON 满足以上条件后，MUST 直接以 JSON `content` 调试 BBCode 链路；不得为了方便改用 HTML。

### R2.4 第四步：只在满足降级条件时使用 HTML

允许进入 HTML 降级的条件：

- JSON 响应在字符串、对象或传输流中途结束，例如 `Unterminated string`、意外 EOF；
- JSON 请求返回 HTML 错误页、网络错误或客户端可识别的业务错误；
- 正在专门调查“强制 HTML 模式”或 `parseHtmlToRawJson` 本身；
- 客户端只有 `pid` 而没有 `tid`，与当前 `ThreadApi` 特例一致。

JSON 截断时 MUST 保留原始响应和错误信息，MUST NOT 把 `JSON.parse` 失败误判成 BBCode
解析器错误。随后才可运行：

```bash
npm run inspect:html -- <tid> <page> [lou ...]

# 示例：检查第 2 页的 20、23、34 楼
npm run inspect:html -- 47373567 2 20 23 34
```

`inspect:html` 使用客户端同源 UA/Cookie 抓取静态 `read.php`，校验
`commonui.postArg.proc(` 标记，再调用 `parseHtmlToRawJson`。HTML 结果可用于继续定位问题，
但所有 HTML 独有缺口 MUST 按 Rule 7 解释。

### R2.5 第五步：按现象进入唯一下一步

| 现象 | MUST 执行的下一步 |
|---|---|
| JSON 完整且目标 `content` 存在 | 解析该 JSON 正文，检查 BBNode 与 InlineRun |
| JSON 完整但目标楼不在该页 | 先纠正 page/pid，不得切换数据模式掩盖定位错误 |
| JSON 返回登录/权限错误 | 先修正 Cookie/权限；不得直接归因于解析器 |
| JSON 响应截断或无法闭合 | 留存失败证据，再执行 `inspect:html` 降级 |
| JSON 与 XML 都在同一字段附近截断 | 视为服务端/传输证据，不得继续修 JSON 语法；转 HTML 降级 |
| 只调查 HTML 恢复覆盖 | 抓取成对样本并运行 `compare:html-json` |
| BBNode 正确但 InlineRun 错误 | 调查 `bbcode-utils.ts` 等渲染格式化逻辑 |
| InlineRun 正确但客户端视觉错误 | 调查 ArkUI 组件；浏览器 DOM 仅作官方视觉基准 |
| 解析输出与官方网页语义不同 | 提取官方渲染 DOM/Run，进入官方差分 |

## Rule 3：JSON 主通道的非标准输入必须统一净化

`src/parser/NgaJsonSanitizer.ts::preprocessJson` 是 JSON 主通道的镜像净化真源。所有新增
修复 MUST 在这里实现并同步，不得只在抓取脚本中做一次性替换。

当前净化契约包括：

- 去除 `window.script_muti_get_var_store=` 前缀；
- 去除 NGA 注入的 `$js$` 与 `error fill content` 非法注释；
- 把 `"content":+123`、`"subject":+123` 修复成字符串；
- 把 `content`、`subject`、`author` 的前导零数字修复成字符串；
- 转义 JSON 字符串内部未转义的 Tab、LF、CR 和其他控制字符。

抓取脚本使用 `TextDecoder('gbk')`；客户端使用 GB18030 解码。调试结果出现乱码、
`Bad control character` 或数字字段语义漂移时，MUST 先核对解码和净化，再检查 BBCode。

## Rule 4：TS 镜像是单一真源

### R4.1 真源边界

下列 31 个 `.ts` 文件属于镜像真源，`npm run sync` 会按相对路径机械覆盖为 `.ets`：

- `src/parser/bbcode/`：BBCode 词法、块级、内联和 handler；
- `src/parser/_shared/`：HTML 实体和附件 URL；
- `src/parser/AnonymousParser.ts`、`src/parser/NgaJsonSanitizer.ts`；
- `src/parser/nga/html-thread/`：HTML 降级解析器；
- `src/model/BBCodeNode.ts`；
- `src/common/components/bbcode/`：Run 格式化和表格布局；
- `src/common/typography/`、`src/common/constants/`、`src/common/utils/Utils.ts`。

### R4.2 修改规则

1. 解析器、渲染器、HTML 降级解析器、`NgaJsonSanitizer` 或 `NgaDomains` 的修改 MUST 先改
   `tools/bbcode-ts/src/`。
2. MUST NOT 直接修改 `entry/src/main/ets/` 下对应的镜像文件；下次同步会覆盖这些改动。
3. `scripts/`、`tests/`、`samples/` 只属于 Node 验证工具，不会同步到客户端。
4. 镜像代码 MUST 同时通过 TypeScript strict 与 ArkTS 子集约束；“tsc 通过”不代表
   “DevEco 可编译”。
5. `npm run sync` 只做 `.ts` → `.ets` 扩展名替换和字节级复制，MUST NOT 被期待做语法转换。
6. 同步后 SHOULD 执行 `node scripts/sync-to-ets.mjs --dry`，结果必须为 0 修改、0 新增。

## Rule 5：修复必须保持解析与渲染契约

### R5.1 真实输入优先

- 每个线上异常 MUST 尽量固化真实 JSON `content`；只有 JSON 不可用时才可固化 HTML 降级还原的
  `content`，并在样本或修复记录中注明来源。
- MUST 同时覆盖触发 bug 的真实形式和至少一个不应受影响的相邻形式。
- MUST NOT 为单个帖子硬编码 tid、pid、lou、用户名或正文片段。

### R5.2 文本与结构

- 容错解析 MUST 优先保证文字不被吞；未知或畸形标签 SHOULD 退化为可见文本。
- 解析树与最终 Run 可以承担不同职责：解析树 MAY 保留原始文本以满足零丢失，Run MAY 按官方
  规则格式化展示。匿名用户名解码就是这一契约的现有实例。
- 表格、引用、折叠、列表、代码、链接和图片的修复 MUST 保持嵌套结构，不得只比较最终纯文本。
- 性能优化 MUST 证明语义零变化；涉及扫描复杂度时 SHOULD 加入大输入回归。

### R5.3 官方对齐

- “官方网页怎么渲染，解析器就怎么解释”只约束渲染语义，不改变 Rule 1 的 JSON 数据优先级。
- 官方差分 MUST 使用浏览器执行脚本后的 DOM/Run；静态 HTML 不能证明最终 CSS、懒加载或
  JS 替换结果。
- 浏览器中目标容器通常为 `postcontent<lou>` 或 `postcontentandsubject<lou>`。

## Rule 6：样本和测试门禁不得跳级

### R6.1 样本类型

| 样本 | 登记/命名 | 用途 |
|---|---|---|
| BBCode 正文 | `samples/*.txt` + `samples.lst` | 文本零丢失、结构断言、快照 |
| 解析树快照 | `<sample>.snapshot.json` | 防止节点结构意外漂移 |
| 官方渲染 | `official-<tid>-lou<N>.html` / `-runs.json` | 官方 DOM/Run 差分 |
| HTML 成对覆盖 | `html-pair-<tid>-p<page>.json/.html` + `html-pairs.lst` | JSON 基准对照 HTML |
| 已知不可恢复缺口 | `html-pair-gaps.json` | 仅声明有证据的样本级映射 |

`npm run snapshot` MAY 只在解析树变化符合预期时执行。生成后 MUST 人工审查 diff；
MUST NOT 用更新快照掩盖未知回归。

### R6.2 Node 测试现状

`npm test` 会先 `tsc`，再执行全部 `dist/tests/*.test.js`：

- `invariants.test.ts`：真实样本文本零丢失、结构、边角语法、匿名名、附件、性能回归；
- `snapshot.test.ts`：`samples.lst` 全样本解析树快照；
- `official.test.ts`：当前挂载 `demo.txt` 与 `official-tid46425481-lou0-runs.json`；
- `html-mode-coverage.test.ts`：HTML 对 JSON 的楼层、字段、正文、用户、热评和分页覆盖；
- `table-layout.test.ts`：rowspan/colspan 非严格表格网格归一化；
- `font-family.test.ts`：字体归类与回退链。

### R6.3 完整门禁顺序

修改镜像 `src/` 后 MUST 按以下顺序完成：

```bash
# 仅在新增样本或预期解析树变化时执行，并先审查快照 diff
npm run snapshot

npm test
npm run sync
node scripts/sync-to-ets.mjs --dry

# 回到项目根目录后执行 DevEco HAP 编译
# 再运行 entry/src/test/BBCodeUnit.test.ets 等相关 Hypium Local Test
```

Node 测试是快速门禁，DevEco 编译与 Hypium 是 ArkTS 最终门禁。只改 README、Node 脚本或测试工具
且没有改镜像 `src/` 时，MAY 不执行 `sync`、DevEco 和 Hypium，但 MUST 至少运行相关 Node 构建/测试。

## Rule 7：HTML 降级覆盖必须以 JSON 为基准

### R7.1 HTML 转 JSON 的现有数据来源

`parseHtmlToRawJson` 当前从静态页面提取：

- `commonui.postArg.proc`：lou、pid、type、authorid、时间戳、score、正文长度、客户端来源；
- `commonui.userInfo.setAll`：`__U` 用户表；
- `commonui.postArg.setDefault`：总回复数、全帖 lastpost、页大小和主题 vote；
- DOM marker：正文、楼层标题、时间、版块名、主题名；
- `ubbcode.attach.load`：附件；
- `hightlight_for_<lou>`、评论 `postArg.proc` 与 pid 锚点：hotreply；
- 页面变量：tid、fid、page、每页行数。

输出被组装为 `{ data: { __R, __U, __T, __F, __ROWS, __R__ROWS,
__R__ROWS_PAGE, __PAGE } }`，再复用 JSON 主通道之后的 `parseThreadData`。

### R7.2 成对覆盖流程

只有 JSON 可完整解析时才允许抓取成对样本：

```bash
node scripts/fetch-thread-pair.mjs <tid> [page]
npm run compare:html-json
npm test
```

`fetch-thread-pair.mjs` MUST 拒绝以下输入：JSON 不能解析、缺少 `data.__R`，或 HTML 缺少
`commonui.postArg.proc(`。该脚本用于覆盖验证，MUST NOT 被当作 JSON 失败后的降级抓取器。

当前仓库登记 5 对样本、99 个 JSON 楼层。现有报告在应用 `rowShift` 后楼层覆盖与正文文本覆盖均为
100%；自动门禁仍以正文覆盖率不低于 90% 为硬阈值，避免把当前样本结果误写成所有帖子的保证。

### R7.3 HTML 已知不可恢复或语义不同的情况

1. **隐楼/删除楼层**：页面不渲染该楼，但页面行号继续递增。HTML 无法从缺失 DOM 还原真实 lou。
   只有经 pid 锚点核实后，才可在 `html-pair-gaps.json` 写样本级 `rowShift`。
2. **`alterinfo`**：HTML 行当前只能置空，JSON 中“主楼”等标记不可恢复。
3. **楼中楼评论**：样本已观察到 `comment` / `comment_to_id` 在 HTML 结果中缺失。
4. **匿名主题作者**：`__T.author` 可能因 HTML 反查 `__U` 得到匿名显示语义而与 JSON 完整用户名不同；
   交集 UID 的 `username` 仍必须一致。
5. **热点回复部分字段**：`content_length`、`from_client` 在评论 `proc` 中为 null 时保持空值，
   不得伪造。
6. **页面未提供的字段**：MUST 保持空值并进入覆盖报告，不得凭其他楼层猜测。

`html-pair-gaps.json` MUST 只记录页面客观不可恢复的缺口；MUST NOT 为了让测试通过而宽泛白名单。

## Rule 8：已确认的特殊行为必须保留

### R8.1 HTML 降级特殊行为

- 负数子版 fid MUST 由 `-?\d+` 提取；不得退化为 0。
- `__T.lastpost` MUST 优先取 `setDefault` 倒数第 2 个参数，不能取当前页最后一楼时间。
- `__ROWS` MUST 取总回复数 + 1；取不到时才按当前页行数降级。
- `setDefault` 第 9 个参数的 vote MUST 写入 lou=0 行及 `__T.post_misc_var.vote`。
- hotreply MUST 按精确 pid 匹配 `commonui.postArg.proc( '__<pid>', ...)`，不得误取楼层 proc。
- hotreply 的原楼层号 MUST 由 `pid<pid>Anchor` 后的 `l<lou>` 锚点反查；附件复用原楼层附件。
- 静态 HTML 是否可用 MUST 以 `commonui.postArg.proc(` 标记判断。Mozilla UA 可能返回 403；
  工具与客户端使用 `NGA_WP_JW` 和 `X-User-Agent: Nga_Official`。

### R8.2 BBCode 与 Run 特殊行为

- 无属性 `[uid]#anony_...[/uid]` 在引用/回复头内 MUST 只在 Run 格式化阶段解码匿名名；
  BBNode 继续保留原始编码，普通无属性 UID 不得伪装为链接。
- `[pid=pid,tid,page]` 的第三段纯数字 MUST 保留为引用跳转页码；两段形式维持原行为。
- `[attach]` 只接受官方精确语法和 NGA 附件域；非法域、未闭合、带属性或内容含边缘空白时
  MUST 按官方行为退化为原文。
- `[img]` 的 `img.nga.178.com` 等官方旧附件域 MUST 归一化到 `img.nga.cn`；`img7?`
  匹配只覆盖 `img` / `img7`，不得误改 `img4`。
- 链接类内联标签长度上限为 8192，样式类保持 512；不得让超长官方 URL 退化为整段文本。
- 表格 `[tr]` / `[td]` 间杂散文字和换行 MUST 保留在解析树，UI 表格渲染可忽略这些文本节点。
- 渲染层连续空行折叠为一个换行；解析树仍保留原始连续换行。
- `bbNodesToPlainText` 会剥除样式子树边缘空白；零丢失断言 MUST 使用 `concatTextNodes`。

### R8.3 官方网页差分特殊行为

- 官方会把表格块边界连续 `<br/>` 折叠为单个换行；差分侧 MAY 模拟该行为。
- 官方 collapse 可能只渲染标题并截断内容；折叠正文完整性 MUST 在解析树侧单独验证。
- 官方图片可能以 `about:blank` 懒加载占位；静态 DOM 中的 src 只可作数量参考。
- 官方 `.x` 表格占位、`.urltip` 链接提示和 `.apd` 装饰 MUST 从 Run 基准中排除。

## Rule 9：目录与命令速查

```text
tools/bbcode-ts/
  src/                          # 31 个 TS 镜像真源
    parser/bbcode/              # BBCode 解析
    parser/_shared/             # 实体、附件 URL
    parser/nga/html-thread/     # HTML 降级 → JSON 同形状
    parser/NgaJsonSanitizer.ts  # JSON 非标准输入净化
    parser/AnonymousParser.ts   # 匿名名解码
    model/BBCodeNode.ts         # 语义树节点
    common/components/bbcode/   # Run 格式化、表格布局
    common/typography/          # 排版常量
    common/constants/           # NGA 域名常量
    common/utils/Utils.ts       # 纯文本提取等
  tests/                        # 不变量、快照、官方差分、HTML 覆盖
  samples/                      # 真实正文、快照、官方 Run、JSON/HTML 对
  scripts/                      # 抓取、报告、快照、同步工具
```

```bash
npm install
npm run build
npm run inspect:json -- <tid> [page] [输出文件名] [lou]
npm run inspect:html -- <tid> [page] [lou ...]
node scripts/fetch-thread-pair.mjs <tid> [page]
npm run compare:html-json
npm run compare:official
npm run snapshot
npm test
npm run sync
node scripts/sync-to-ets.mjs --dry
```

最后检查：若一次调查没有先尝试 JSON、没有真实样本、直接改了 `.ets`、生成快照后没有审查 diff，
或镜像修改后没有完成 DevEco/Hypium 门禁，则该调查 MUST 视为未完成。
