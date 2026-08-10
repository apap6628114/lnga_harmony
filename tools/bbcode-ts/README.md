# tools/bbcode-ts — BBCode 解析器 TS 镜像验证工具

## 动机

ArkTS 是 TypeScript 严格子集。本工具把 HarmonyOS 工程的 BBCode 解析器/渲染器
（纯逻辑、零平台 API 依赖）镜像为 TS，在 Node 环境用真实楼层样本验证解析正确性，
验证通过后机械同步回 ArkTS，规避 DevEco/Hypium 编译链慢的问题。

## 目录结构

```
tools/bbcode-ts/
  src/                          # TS 镜像（真源）：与 entry/src/main/ets 同构
    parser/bbcode/              #   词法/块级/内联解析 + block-handlers
    parser/_shared/             #   实体解码、附件 URL
    parser/nga/html-thread/     #   HTML 模式解析器镜像（read.php HTML → JSON 形状）
    parser/NgaJsonSanitizer.ts  #   JSON 预处理镜像    model/BBCodeNode.ts         #   节点模型
    common/components/bbcode/   #   渲染逻辑（bbcode-utils）
    common/typography/          #   排版常量
    common/constants/           #   NGA 域名常量（NgaDomains.ts，与 entry 同构）
    common/utils/Utils.ts       #   bbNodesToPlainText 等
  tests/
    helpers.ts                  #   样本加载、序列化、子序列断言、官方差分 run 提取
    html-coverage.ts            #   HTML 模式 → JSON 覆盖分析引擎（测试与报告共用）
    invariants.test.ts          #   文本零丢失 + 结构断言 + 边角样例
    snapshot.test.ts            #   快照回归
    official.test.ts            #   官方渲染基准差分断言
    html-mode-coverage.test.ts  #   HTML 模式 → JSON 数据覆盖断言
  samples/
    samples.lst                 #   样本清单（每行一个文件名，自动纳入测试）
    demo.txt / demo2.txt        #   真实楼层样本（NGA API content 字段）
    demo.snapshot.json          #   解析树快照基线（npm run snapshot 生成）
    official-<tid>-lou<N>.html  #   官方渲染 DOM（调试流程第 8 步固化）
    official-<tid>-lou<N>-runs.json  # 官方渲染 run 序列（差分输入）
    html-pairs.lst              #   JSON/HTML 成对样本清单（覆盖验证套件）
    html-pair-gaps.json         #   成对样本已知缺口声明（页面行号错位映射等）
    html-pair-<tid>-p<page>.json / .html  # 成对样本（JSON API 响应 + read.php 原始 HTML）
  scripts/
    fetch-thread-json.mjs       #   拉取帖子 JSON 调试数据（整页或指定楼层 content）
    fetch-thread-pair.mjs       #   拉取同帖同页 JSON + HTML 成对样本（覆盖验证套件输入）
    sync-to-ets.mjs             #   TS 镜像 → entry/src/main/ets 单向同步
    gen-snapshot.ts             #   重新生成快照基线
    compare-official.ts         #   官方差分人类可读报告
    compare-html-json.ts        #   HTML 模式 → JSON 覆盖人类可读报告
```

## 使用

```bash
npm install        # 首次
npm test           # 编译 + 全部测试（不变量 + 快照 + 官方差分 + HTML 覆盖）
npm run snapshot   # 生成/更新快照基线（审查 git diff 后提交）
npm run compare:official   # 官方差分报告
npm run compare:html-json  # HTML 模式 → JSON 覆盖报告
npm run sync       # 把验证过的镜像写回 entry/src/main/ets（.ts → .ets）
```

调试数据拉取（详见下方调试流程）：

```bash
# 取帖子某楼层 content 存为样本（NGA_COOKIE 为浏览器登录后 document.cookie）
NGA_COOKIE=... node scripts/fetch-thread-json.mjs <tid> <page> <输出文件名> <lou>
# 取整页 JSON 落盘（不带 lou 参数）
NGA_COOKIE=... node scripts/fetch-thread-json.mjs <tid> <page>
# 取同帖同页 JSON + HTML 成对样本（HTML 模式覆盖验证套件输入）
NGA_COOKIE=... node scripts/fetch-thread-pair.mjs <tid> [page]
```

## HTML 模式 → JSON 覆盖验证套件

客户端有两条帖子数据通道：**JSON 模式**（`__output=8`，主通道）与 **HTML 模式**
（`read.php` 静态 HTML 解析，`ThreadApi` 降级/调试通道）。实测 HTML 模式在客户端
缺少部分数据（如热门回复/楼中楼评论/签名等字段、渲染后不可恢复的表格/折叠结构）。
本套件以 JSON 为基准真值，验证 HTML 模式转成 JSON 数据的覆盖情况。

1. 抓取成对样本（同一 tid 同一 page，保证逐楼层可比）：
   `NGA_COOKIE=... node scripts/fetch-thread-pair.mjs <tid> [page]`
   - JSON 响应存 `samples/html-pair-<tid>-p<page>.json`（GBK 解码 + tab 转义）
   - HTML 存 `samples/html-pair-<tid>-p<page>.html`（与客户端 HTML 模式同 URL 同 UA
     `NGA_WP_JW`；校验含 `commonui.postArg.proc` 标记，拒绝 JS 启动壳）
   - 自动登记 `samples/html-pairs.lst`，提交样本后套件自动生效
2. `npm run compare:html-json` 输出人类可读覆盖报告（`tests/html-coverage.ts` 引擎）：
   - 楼层集合覆盖：JSON 每楼（lou）在 HTML 输出中是否有对应
   - 楼层元数据：pid/authorid/postdatetimestamp/type/score/score_2/content_length/
     from_client 等逐字段一致性（HTML 与 JSON 同源于页面 postArg JS 数据，必须一致）
   - 正文文本覆盖率：JSON content 经 BBCode 解析的纯文本，在 HTML content（渲染后
     HTML 经同一解析器）中的去空白子序列保留度；输出首个未覆盖片段定位"文字被吞"
   - 附件覆盖：JSON attachs 与 HTML `attach.load` 解析结果的数量与 URL 命中
   - 用户表 `__U`：UID 集合、交集用户名一致性、字段出现率（avatar/signature/yz 等）
   - 缺失字段清单：JSON 有值但 HTML 输出无法提供的字段（hotreply/comment/signature
     /js_escap_avatar/mute_time 等）按出现楼数排序
   - 结构清单：JSON 侧解析树 TABLE/COLLAPSE/LIST/IMAGE 等计数 vs HTML 渲染后经
     解析器可恢复量（量化"渲染丢结构"）
3. `npm test` 中的 `tests/html-mode-coverage.test.ts` 断言硬不变量：
   - 楼层零缺失；楼层元数据字段零差异；交集 UID 用户名一致；`__ROWS`/`__PAGE`/
     主题标题一致
   - 正文文本覆盖率 ≥ 90%（`TEXT_COVERAGE_THRESHOLD`，按真实样本可调）
   - 已知缺口经 `samples/html-pair-gaps.json` 声明（见下），声明之外的新缺口
     直接断言失败（套件告警）
   - 已知丢失维度（结构/附加字段/用户字段）不设断言，只进报告
4. 修复走既有工作流：改 `src/parser/nga/html-thread/` 镜像 → `npm test` →
   `npm run sync`（html-thread 5 文件 + NgaJsonSanitizer 已纳入镜像治理）。

### 已知缺口声明（html-pair-gaps.json）

read.php 页面存在"隐楼"行为：被隐藏/删除的楼层不渲染但服务器行号继续递增，
后续楼层行号与真实 lou 错位 +1。HTML 模式从页面无法恢复真实 lou 号，套件用
样本级 `rowShift`（页面行号 → JSON lou）映射对齐后再断言；报告保留原始错位信息
（楼层明细"页面行"列标注 `(映射)`）。新样本页面出现隐楼时，按报告确认后补充声明。

### 实测发现（2026-08-10，样本 html-pair-46425481-p1 / html-pair-47307683-p1）

- **隐楼行号错位**（46425481）：页面跳过 lou 11（容器内 `pid862841466Anchor` 为证），
  后续行 12-19 实为 JSON lou 11-18，客户端 HTML 模式楼层内容整体错位 +1；
  `rowShift` 对齐后 19/19 楼元数据与文本 100% 一致——解析器本身无 bug，页面行为所致
- **fid 负号**（46425481，已修复）：子版 fid 为负（`__CURRENT_FID=parseInt('-40063163')`），
  `extractIntVar` 正则不含负号导致 fid=0；已改为 `-?\d+`（两样本 19/19、20/20 一致）
- **`__T.lastpost` 偏早**（两样本，已修复）：原取页面最后一楼时间，跨页时早于全帖
  最后回复；`setDefault` 倒数第 2 个参数即全帖 lastPostTs（与 JSON `__T.lastpost` 实测
  逐位一致），已新增 `extractLastPostTs` 优先使用
- **`__U` 用户字段**：页面 `userInfo.setAll` 与 JSON `__U` 同源（uid/username/credit/
  medal/reputation/groupid/memberid/avatar/yz/regdate/mute_time/postnum/rvrc/signature/
  nickname 等全字段一致；该帖用户匿名显示故 avatar/signature 为空，非解析缺失）。
  两侧均无 `__GROUPS`（memberGroup 本来就取不到，非 HTML 模式独有问题）
- **`alterinfo` 缺失**：HTML 行硬编码为空，JSON 的"主楼"等 alterinfo 标记丢失（页面无数据源）
- **`__T.author` 差异**：JSON 为完整用户名，HTML 反查 `__U` 得 `UID:xxx`（匿名显示语义，
  交集 UID 用户名两侧一致）
- **附件/结构恢复完好**：`attach.load` URL 全命中；表格 4→4、单元格 750→750、
  折叠 2→2、图片 16→16、链接、引用均完整恢复（read.php 的 postcontent 为 BBCode 源文）
- **热点回复（hotreply）还原**（2026-08-10 新增 `HotReplyParser`，样本 47341103 验证）：
  网页版把热点回复渲染在楼主楼 `<span id='hightlight_for_<lou>'>` 容器（正文
  `postcomment__<pid>` 为 BBCode 源文、时间 `commentInfo__<pid>`、作者
  `commentauthor__<pid>`、元数据在独立 `postArg.proc( '__<pid>', ... )` 调用、
  原楼层号经 `pid<pid>Anchor` 后 `<a name='l<lou>'>` 反查）。提取后组装为与 JSON
  `hotreply` 同形状挂到 `__R` 行，pid/fid/tid/type/score/score_2/postdate/content/lou/
  postdatetimestamp 逐位一致，attachs 复用原楼层行；content_length/from_client
  页面无数据（proc 参数为 null）维持空值

### 数据模式盘点（2026-08-10，浏览器 + 直连实测）

- **`__output=8` JSON**（现有主通道）：字段最全（__U 全字段/__R 行/__T/__F/__ROWS/__PAGE），
  客户端唯一获得 hotreply/comment/alterinfo 的通道，无可替代
- **`__output=9` XML**：同源完整数据（GB18030 声明、`<root><__U><item>` 结构），
  ArkTS 无顺手 XML 解析路径，无优势
- **`__output=1` / `lite=js`**：`window.script_muti_get_var_store={JSON}` JS 壳包同源 JSON
- **read.php HTML**（现有 HTML 降级模式）：postcontent 为 BBCode 源文（正文/表格/折叠
  可完整恢复）；`postArg.proc` 参数 [0]lou [10]pid [11]type [13]authorid [14]ts [15]score
  [16]content_length [19]from_client [20]model；`setAll`=__U；`setDefault` 含总回复数/
  lastPostTs/页大小
- **`read.php?pid=` 单帖视图**：ThreadPanel REPLACE 兜底已用
- **`thread.php?__output=8`**：版块列表（ForumApi 已用）
- **`nuke.php?__lib=&__act=`**：仅个人功能（收藏/翻译/举报/用户选项），无帖子数据
- **移动端 m.nga.cn / wap.nga.cn**：404 不存在
- **待验证**：`postArg.proc` 参数 [22]（恒为 0，疑似 recommend）

## 工作流（单一真源）

1. 改解析/渲染逻辑只改 `src/` 下 TS 镜像（须遵守 `.claude/rules/ArkTS-syntax.md`，
   否则同步回 .ets 无法编译）
2. `npm test` 快速验证
3. `npm run sync` 回写 `entry/src/main/ets/`
4. DevEco 编译 + Hypium（`entry/src/test/BBCodeUnit.test.ets`）最终门禁

> ⚠️ 禁止直接修改 `entry/src/main/ets` 下被镜像的 30 个文件——下次 `npm run sync`
> 会整体覆盖。确需直接改 .ets 时，改完立即反向同步回镜像。
> 域名常量 `common/constants/NgaDomains.ts` 同样纳入镜像，切域时两侧都要同步。

## 不变量

- **文本零丢失**：期望纯文本（预处理 → 删媒体内容 → 剥标签 → 解码实体）必须是
  解析树全部 TEXT 拼接的子序列，抓"漏解释/文字被吞"
- **官方渲染基准差分**：官方网页渲染 DOM 提取的"带样式 run 序列"与解析树生成的
  同构 run 序列对比——官方怎么渲染，解析器就怎么解释。断言 `tests/official.test.ts`，
  报告 `npm run compare:official`
- **结构断言**：真实样本的表格数、行数、合并单元格、折叠块、关键短语、链接
- **快照回归**：demo.txt 解析树 JSON 与基线逐字节对比，防意外漂移
- **边角样例**：20 个手写用例覆盖标签嵌套/容错/属性/特殊字符

## 异常渲染调试流程

前置：chrome 已登录 NGA（取 cookie 与渲染 DOM）；chrome devtools MCP 处于持久化调试模式。

1. 记录用户报告的帖子 URL 与异常楼层号（URL `read.php?tid=<tid>` 中 tid= 后为帖子 ID）
2. 一键拉取楼层数据：
   `NGA_COOKIE=<浏览器 document.cookie> node scripts/fetch-thread-json.mjs <tid> <page> <输出文件名> <lou>`
   - 输出为 `"content": "..."` 格式，`tests/helpers.ts::loadSampleContent` 直接可读
   - 不带 lou 参数则整页 JSON 落盘（`data.__R` 为楼层列表）
   - 脚本已封装取数要点（2026-08-07 实测）：
     - URL 构造：`__output=8` 强制 JSON（不加返回 JS 启动壳）；`__inchst=UTF8` 与鸿蒙端
       ThreadApi 参数一致
     - 登录 cookie + UA（`NGA_WP_JW` + `X-User-Agent: Nga_Official`）；游客返回 error 15
     - 响应 GBK 编码：须 `TextDecoder('gbk')` 显式解码，否则 `JSON.parse` 报
       "Bad control character"
     - JSON 内 tab 未转义：parse 前 `replace(/\t/g, '\\t')`（即鸿蒙端 `preprocessJson`，
       见 `entry/.../parser/NgaJsonSanitizer.ets`）
   - 手动事项：cookie 从浏览器 `document.cookie` 获取（需 `ngaPassportUid`/`ngaPassportCid`）；
     整页响应完整性校验看 `"__R":`（双下划线开头、**单下划线结尾**，勿用 `__R__` 误匹配
     `__R__ROWS` 分页行数而误判防爬——实测该 API 无防爬，请求均完整返回）
3. 用 TS 镜像解析该 content，检查解析树/run 序列是否符合预期
4. devtools 打开帖子页，滚动至异常楼层，取该楼层内容容器
   （id 为 `postcontent<lou>` 或 `postcontentandsubject<lou>`）的 HTML
   （注意：read.php 静态抓取只返回 JS 启动壳，楼层 DOM 由浏览器 JS 渲染，必须从浏览器取）
5. 官方 HTML 与解析输出逐项对照，差异即 bug
6. 修复镜像 → `npm test` → `npm run sync` → DevEco 编译 + Hypium
7. 固化回归样本：content 存 `samples/` 并登记 `samples.lst`；官方 DOM 存
   `samples/official-<tid>-lou<lou>.html`，run 序列存 `samples/official-<tid>-lou<lou>-runs.json`
8. 运行 `npm run snapshot` 生成 `<name>.snapshot.json`（快照测试遍历 samples.lst，
   缺基线即失败），审查 git diff 后提交

官方差分挂载：`tests/official.test.ts` / `scripts/compare-official.ts` 当前硬编码
demo.txt ↔ `official-tid46425481-lou0-runs.json`；新固化的 runs.json 经
`npm run compare:official` 人工对照，需接入差分时改挂载点。

runs.json 提取方式：浏览器内脚本遍历楼层 DOM，跳过 `.x` 表格占位 /
`.urltip` 链接提示 / `.apd`，颜色 class 用 computedStyle 动态发现；
格式与生成逻辑见 `tests/helpers.ts` 注释及现有样本 `official-tid46425481-lou0-runs.json`。

## 已知的官方渲染行为（差分已对齐，非解析器错误）

- **表格块边界空白折叠**：官方把 `[table]` 前后连续 `<br/>`（含 `<br/> <br/>`）折叠为
  单个 `<br>`。解析树保留原文换行，对比时在解析树侧模拟折叠
- **collapse 内容服务端截断**：网页只渲染标题（`+ ` 前缀、` ...` 后缀为 UI 装饰），
  `collapse_content` 为空；折叠内容仅解析树侧验证完整保留
- **图片懒加载**：网页图片为 `about:blank` 占位，仅作数量参考

## 已知设计行为（非 bug，断言已对齐）

- `bbNodesToPlainText` 剥除样式子树边缘空白；零丢失断言用 `concatTextNodes`（逐字保留）

## 修复记录

- **2026-08-11 投票帖支持（tid=47344482 主楼验证，镜像 136 项全绿）**：
  - 背景：投票帖在鸿蒙客户端完全不可见。排查结论：JSON 数据（楼级 `__R[0].vote` /
    `__T.post_misc_var.vote`）完整，但 `ThreadParser` 只透传字符串、`mapRowToPost` 映射时
    丢弃字段、渲染层无投票组件——整条链路从未实现（官方网页投票是正文外独立容器
    `votec0`，由 JS 依 vote 字段渲染，与 BBCode 解析无关）
  - vote 字符串格式（官方 `__NUKE.scEn/scDe` 编码）：`键~值~...` 两两配对；
    `<选项ID>~<标题>` 数字键为选项，`_<ID>~<票数>,<投注量>,<总人数>` 为统计
    （总人数取各选项第三段最大值），`max_select~n` 最多可选（缺省 1）、`end~ts` 结束
    时间戳、`type~n`（0投票 1投注 2评分 3评分单条 4问答，缺省 0）、`opt~bit`
    （&1 提交后可查看结果 &2 结束后可查看结果）、`min/max/priv/done` 投注评分用
  - 提交接口（官方 js_read.js `commonui.vote.submit` → `__API.vote`）：
    `POST nuke.php?__lib=vote&__act=vote&tid=<tid>&voteid=<逗号分隔选项ID>&raw=3`，
    成功提示在 data[0]；`max_select>1` 时 checkbox 多选，否则 radio 单选
  - 客户端实现：`parser/VoteParser.ets` 解码（镜像 scDe+voteFormat 语义，百分比
    `((票/组总票*1000)|0)/10`、进度条组内最高项归一化 75% 宽度与官方一致）；
    `model/Vote.ets` 模型；`PostInfo.vote` 字段 + `ThreadApi.mapRowToPost` 映射 +
    `__T.post_misc_var.vote` 主题级兜底（HTML 模式主楼无 vote 时回填）；
    `service/api/VoteApi.ets` 提交；`PostPoll.ets` 组件（选项行/票数/百分比/进度条/
    信息行/提交/已投乐观更新），挂到 PostItem 主楼正文之后；Hypium 新增
    `VoteUnit.test.ets`（4 例，真实样本 170/11/28 票与官方渲染一致）
  - HTML 模式：`PostArgScanner` 新增 `extractSetDefaultVote`（`setDefault` 第 9 参，
    与 `commonui.vote($('votec<N>'),tid,'...')` 内联调用同源），填入 lou=0 行 vote +
    `__T.post_misc_var`；成对样本 `html-pair-47344482-p1` 固化，覆盖套件楼层元数据
    逐字段零差异通过（该字段在 `ROW_FIELDS` 对比清单，投票样本将强制两侧一致）
  - 官方源码推理（2026-08-11，js_commonui.js / js_read.js 逐行核对）：
    - **编码端 `~` 消毒**：`scEn` 对 string 直接 `replace(/~/g,'')`——服务端生成 vote
      字符串时删除标题中的 `~`，客户端 scDe 无需处理转义，双端天然一致（标题含 `~`
      不可能出现）
    - **结束时间用服务端时钟**：官方 `atv = !x.end || w.__NOW<=x.end`（`__NOW` 为服务端
      注入时间戳）；客户端无 `__NOW`，用 `Date.now()/1000` 替代（epoch 秒无时区问题，
      仅客户端时钟漂移），边界 `<=` 与官方逐字一致
    - **`max_select~0` 官方残缺语义**：发帖注释"0不限"但渲染/提交未实现——UI 走
      radio（单选），提交时 `myvote>max_select` 即 `1>0` 直接拒绝（官方 bug 行为）；
      客户端归一化为 1（单选），UI 一致且避开拒绝 bug
    - **进度条归一化**：`voteMul` 仅当组内最高项占比 `<0.75` 时取 `0.75/mostRate`
      （最高项压到 75% 宽），否则 1 不缩放（最高票 81.3% 全宽展示），`barPercent` 同构
    - **`opt` 位不隐藏结果**：票数/百分比/进度条无条件渲染，`opt&1/&2` 仅进信息行
      文案（"提交后可查看结果"/"结束后可查看结果"）
    - **无已投标识**：数据无已投字段，官方提交后仅 `alert(data[0])` 且不刷新——
      客户端"提交后乐观更新 + 隐藏控件"体验优于官方
    - **type 1/2/3/4 渲染**（客户端 PostPoll 按官方 voteBet/voteScore/TYPE_SCORE_VOTE/
      TYPE_QACHART 对齐）：type 1 双指标（票数 + 投注铜币，结算 `done` 逗号串标"胜出"）；
      type 2 均分 `((scoNum/voteNum*100)|0)/100` + 相对 `max` 进度条；type 3/4 只读列表
      （问答带序号）；统计计算提取为可测纯函数 `votePercent`/`barPercent`/`scoreValue`

- **2026-08-08 引用回复跳转：保留引用楼层页码（[pid=pid,tid,page]）**：
  - 问题：NGA 引用头 `[pid=pid,tid,page]Reply[/pid]` 携带被引楼层所在页（第 3 值，
    实测 26 个真实引用样本与 `floor(lou/20)+1` 100% 一致），但 `createLinkHref` 丢弃
    page，跳转仅带 pid。帖子页 REPLACE 请求带 pid 时服务端返回单帖视图
    （`lou=0`、`__PAGE=1`，页码与楼层信息丢失），无法按页加载整页定位
  - 对齐实现：pid 链接第三段为纯数字时保留 `&page=`（两值形式行为不变）；
    ThreadPanel REPLACE 默认请求整页（不带 pid），按目标页加载后由既有
    `prepareListNavigation` 在页内按 pid 定位；整页未命中时一次性单帖兜底
    （`singlePostFallback`，兜底后恢复整页窗口真实 `totalPages`——单帖视图
    `__ROWS=1` 会把它重置为 1，否则用户被困在单帖窗口无法扩展），
    同帖且目标楼已在加载窗口时页内直接滚动（`quote-jump local` 日志）
  - 样本 `tid46425481-lou142-quote.txt`（真实引用楼层）固化 + 快照基线；
    该样本首次暴露既有解析行为：引用头 `[/b]<br/><br/>` 后的连续换行段被
    handleQuote 消费（测试 `removesQuoteHeaderSeparatingBreaks` 已固化），
    零丢失断言侧在 `expectedPlainText` 中镜像该消费语义
  - 镜像新增 1 测试（三值 href / 两值不变 / 非数字与四值第三值 / 空值），
    Hypium 1 例（`keepsQuoteReplyPageInPidLinkHref`）

- **2026-08-07 [img] 旧附件域归一化**（tid=47228037 主楼表格内图片裂图修复，镜像 71 项 + Hypium 80 项全绿）：
  - 症状：主楼表格 `[td]` 内 `[img]https://img.nga.178.com/...[/img]` 解析为 IMAGE 但
    src 保留旧域 `img.nga.178.com`，该域已不可解析（实测 HTTP 000 / DNS 落保留地址），
    图片加载失败；而 `./mon_...` 相对路径图片（拼新域 img.nga.cn）显示正常
  - 官方行为（js_default.js `commonui.correctAttachUrl`，imgGen 对全部 [img] src 调用）：
    匹配 `^https?://img7?\.(?:nga\.cn|ngacn\.cc|nga\.178\.com|nga\.donews\.com|ngabbs\.com)/`
    的附件域绝对 URL 统一替换为当前附件基域（官方 `_P_ATTACH_BASE_VIEW =
    https://img.nga.cn/attachments`，host 由 `_ATTACH_BASE_VIEW` 提供；页面 JSON
    `__GLOBAL._ATTACH_BASE_VIEW=img.nga.cn` 与之呼应）
  - 对齐实现：`AttachUrl.ts` 新增 `NGA_ATTACH_IMG_RE`（与官方正则逐字一致，`img7?` 只匹配
    img/img7，img4 等其余子域官方不动、此处也不动），`resolveImgUrl` 绝对 URL 分支先
    replace 再 strip 后缀；相对路径与其余 URL 行为不变。[attach] 链路官方不归一化（白名单
    放行旧域、渲染为链接文本），维持既有实现。替换协议固定 https（应用侧无 http 页面，
    官方 `HTTPS||$1` 的 http 分支不适用；http 输入同样归一化为 https 基域）
  - 样本 `tid47228037-lou0.txt`（LPL 赛程主楼，2 表格 310 单元格 93 图）固化 + 快照基线
    （基线内 178.com 零残留）；镜像新增 5 用例（旧域归一化 / http 旧域 / img7 匹配而 img4
    不匹配 / 非附件域保留 / 表格内解析后 src）；Hypium 3 例
    （`normalizesLegacyAttachDomainImgToNgaCn` / `keepsNonNgaDomainImgUrlUnchanged` /
    `normalizesImgInTableCells`）
  - 官方差分未接入：网页表格为 `.x` 占位客户端渲染，静态 HTML 无渲染后 DOM
  - 官方调研要点（2026-08-07 实测）：`commonSpec` 脚本在 `__RES_STYLE =
    http://img4.nga.cn/ngabbs/nga_classic`（README 之前记录的 common_res 路径仅 `lib`/`common`
    等适用）；页面 JSON 顶层 `data.__GLOBAL._ATTACH_BASE_VIEW` 即官方当前附件基域

- **2026-08-07 [attach] 附件标签支持**（tid=47307683 1 楼修复，59 项测试全绿）：
  - 此前 `[attach]` 无 handler，正文原样显示 `[attach]./mon_xxx.mp4[/attach]` 文本；
    官方网页由 `ubbcode.attach.load()` JS 将正文 `[attach]` 替换为附件链接
  - 对齐官方 ubbcode.js 语义：`./` 前缀拼 CDN 根（`getAttachBase` 同构），
    `commonui.ifUrlAttach` 附件域白名单校验（`NgaDomains.ts` 新增 `NGA_ATTACH_HOSTS`，
    含旧域），合法渲染为 URL 链接（显示文本 = 完整 URL，官方 `writelink` 语义）
  - 保留原文的情形与官方逐条对齐（独立 review 验证）：非 NGA 附件域、
    未闭合 `[attach]`（官方正则无匹配）、内容前后含空白/换行（官方不 trim、
    `.` 不匹配 `\n`）、`[attach=属性]` 形式（官方 `\[attach\]` 精确匹配）
  - 实现：`AttachUrl.ts` 新增 `resolveAttachBBCodeUrl`；`inline-parser.ts` 将 attach
    纳入链接标签族（open/close 栈帧记录原始标签文本供退化保留），闭合/段尾
    finalize 时解析并校验
  - 样本 `tid47307683-lou0.txt` 固化 + 快照基线；边角样例 4 例 + 渲染 Run 断言 +
    Hypium 2 例（`BBCodeUnit.test.ets`）
  - 官方差分未接入：正文 [attach] 替换依赖 JS 渲染，静态 HTML 无渲染后 DOM
  - 官方渲染调研要点（2026-08-07 实测）：read.php 网页 HTML 按 UA 反爬
    （Mozilla UA 403，`NGA_WP_JW` 可过）；脚本清单在页面 `__SCRIPTS` 配置，
    基础路径 `__COMMONRES_PATH = http://img4.nga.cn/common_res`，
    [attach] 替换逻辑在 `js_bbscode_core.js?1342409`（正则 `\[attach\](.+?)\[\/attach\]`），
    `getAttachBase`/`ifUrlAttach` 在 `js_default.js?9965017`（`_ATTACH_BASE_VIEW='img.nga.cn'`）

- **2026-08-07 解析/渲染效率优化**（效果零变化，50 项测试全绿）：
  - `parseTableContent` 每行 3 次独立扫描（`[/table]` exec + `[tr]` exec + `indexOf`）合并为
    单次扫描 + 字符级 `matchesIgnoreCaseAt`，消除每行正则 exec 扫至表尾的重复扫描
    （签名 `closePattern: RegExp` → `closeTag: string`）；`parseTableRowCells` 的 `[td]`
    正则提升为模块常量
  - `parseBBCode` 快速路径：无 `[`/`<`/`===` 的纯文本（表格单元格正文）跳过
    preprocessContent（对该类输入为严格恒等变换，`===` 为标题规范化模式须排除），
    消除表格单元格递归中每个单元格重复的 6 正则链 + toLowerCase + 逐行扫描
  - `unescapeHtml` 无 `&` 短路；`cleanupHtmlSegment` 无 `<` 且无 `[img]` 短路；
    `handlePostBy` exec 前 `[b]Reply to ` 前缀预检；`tryMatchBlock` 20 个 if 改为
    Map 字典分派；全部 block-handlers 及 parser/heading-normalizer 的正则提升为
    模块级常量（所有 exec 前显式设 lastIndex，共享有状态正则安全）
  - 渲染层 `deriveNodeStyle` 对样式零修改的节点（TEXT/链接/表情等）复用父级样式
    引用（run.style 被 ArkUI 只读消费，值语义与克隆等价）；换行折叠对无连续换行的
    Run 短路
  - `parseBlockNodesUntil` 的闭合边界由“每遇到 `[` 都用正则向后搜索到块尾”改为
    当前位置固定标签比较，消除引用、折叠、列表、标题、段落、浮动与样式块中合法
    大量内联标签触发的 O(n²) 扫描；闭合标签仍从原文截取，大小写与 terminator 语义不变
  - `parseTableRowCells` 把每个单元格重复搜索 `[/tr]` 与 `[td` 改为单游标结构标签扫描，
    `[td...]` 在当前位置读取首个 `]`，保留原有未知属性、杂散内容和缺失闭合标签容错语义
  - Run 合并改为文字分片暂存后一次 `join`，HTML/代码块清理、标题逐行规范化与无属性 URL
    文字收集同步改为分片合并，避免大量同样式短节点或多行内容反复扩展不可变字符串
  - 仅用于当前位置校验的 block-handler 正则由全局搜索 `g` 改为 sticky 匹配 `y`；既有代码本就
    只接受 `match.index === state.pos`，因此捕获与消费结果不变，同时避免畸形同名标签先向后
    搜索下一处合法标签。4000 个 `[h x]` 畸形标签中位数 33.3ms → 2.8ms（12×）
  - 实测：demo.txt 冷启动 total ~49.5ms → ~40ms（-20%）；4000 行大表格
    218ms → 10ms（21×，消除单元格重复预处理与表格扫描 O(n²)）
  - 本轮 Node 合成基准中位数（5 次）：4000 个引用内粗体片段解析+格式化
    72.4ms → 5.2ms（14×）；单行 4000 单元格 522.8ms → 2.2ms（237×）。
    Git 中优化前实现与当前实现对 3005 组固定及随机畸形输入进行解析树、Run JSON
    逐字节差分，结果完全一致

- **2026-08-05 域名集中收敛同步**：entry 侧域名收敛到 `common/constants/NgaDomains.ets`
  时直接改动了被镜像的 `AttachUrl.ets` / `Utils.ets`（CDN 域 178.com → nga.cn）。
  已按「改完立即反向同步」原则回写镜像（新建 `NgaDomains.ts`、两文件改引用常量），
  镜像与 entry 逐字一致，`npm run sync` 幂等（0 变更）。
- **2026-08-05 表格分隔换行保留**：`parseTableContent` / `parseTableRowCells` 的容错
  跳过逻辑原先静默丢弃 `[tr]/[td]` 之间的杂散内容（含 `<br/>` 预处理后的换行，demo.txt
  约 720 处），现保留为行级/表级 TEXT 节点。UI 渲染零影响（`RenderTable` 只消费
  TABLE_ROW/TABLE_CELL），AI 总结与 TTS 朗读的表格文本获得单元格分隔。
  快照基线随之更新（`npm run snapshot`）。
- **2026-08-06 超长 URL 标签识别**：`MAX_INLINE_TAG_LENGTH=512` 使超长 `[url=]`
  （如 1349 字符 text fragment 链接）整体退化为纯文本，与官方渲染不符。链接类标签
  （url/pid/uid/tid）上限提至 `MAX_INLINE_LINK_TAG_LENGTH=8192`，样式类保留 512。
  样本 `demo2.txt` 固化（tid=47320652 的 10 楼），镜像与 Hypium 均补回归用例。
