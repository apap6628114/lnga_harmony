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
    model/BBCodeNode.ts         #   节点模型
    common/components/bbcode/   #   渲染逻辑（bbcode-utils）
    common/typography/          #   排版常量
    common/constants/           #   NGA 域名常量（NgaDomains.ts，与 entry 同构）
    common/utils/Utils.ts       #   bbNodesToPlainText 等
  tests/
    helpers.ts                  #   样本加载、序列化、子序列断言、官方差分 run 提取
    invariants.test.ts          #   文本零丢失 + 结构断言 + 边角样例
    snapshot.test.ts            #   快照回归
    official.test.ts            #   官方渲染基准差分断言
  samples/
    samples.lst                 #   样本清单（每行一个文件名，自动纳入测试）
    demo.txt / demo2.txt        #   真实楼层样本（NGA API content 字段）
    demo.snapshot.json          #   解析树快照基线（npm run snapshot 生成）
    official-<tid>-lou<N>.html  #   官方渲染 DOM（调试流程第 8 步固化）
    official-<tid>-lou<N>-runs.json  # 官方渲染 run 序列（差分输入）
  scripts/
    sync-to-ets.mjs             #   TS 镜像 → entry/src/main/ets 单向同步
    gen-snapshot.ts             #   重新生成快照基线
    compare-official.ts         #   官方差分人类可读报告
```

## 使用

```bash
npm install        # 首次
npm test           # 编译 + 全部测试（不变量 + 快照 + 官方差分）
npm run snapshot   # 生成/更新快照基线（审查 git diff 后提交）
npm run compare:official   # 官方差分报告
npm run sync       # 把验证过的镜像写回 entry/src/main/ets（.ts → .ets）
```

## 工作流（单一真源）

1. 改解析/渲染逻辑只改 `src/` 下 TS 镜像（须遵守 `.claude/rules/ArkTS-syntax.md`，
   否则同步回 .ets 无法编译）
2. `npm test` 快速验证
3. `npm run sync` 回写 `entry/src/main/ets/`
4. DevEco 编译 + Hypium（`entry/src/test/BBCodeUnit.test.ets`）最终门禁

> ⚠️ 禁止直接修改 `entry/src/main/ets` 下被镜像的 22 个文件——下次 `npm run sync`
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

前置：chrome 已登录 NGA；chrome devtools MCP 处于持久化调试模式。

1. 记录用户报告的帖子 URL 与异常楼层号
2. 取官方 JSON：`https://bbs.nga.cn/read.php?page=<页>&__output=8&tid=<tid>&__inchst=UTF8`

   > **取 JSON 操作要点**（2026-08-07 实测）：
   > - 从帖子 URL `read.php?tid=<tid>` 提取 tid 构造上 URL（`__output=8` 强制 JSON 输出，
   >   不加返回服务端渲染 HTML；`__inchst=UTF8`/`noprefix=`/`v2=` 与鸿蒙端 ThreadApi 参数一致）
   > - 必须带登录 cookie（`ngaPassportUid`/`ngaPassportCid`），游客返回 error 15；
   >   UA 用 `NGA_WP_JW` + `X-User-Agent: Nga_Official`
   > - 响应为 GBK 编码：`fetch().text()` 按默认编码解码会产出未转义控制字符（`JSON.parse`
   >   报 "Bad control character"），须 `arrayBuffer()` + `TextDecoder('gbk')` 显式解码
   > - NGA JSON 字符串内 tab 未转义：parse 前全局 `replace(/\t/g, '\\t')`
   >   （即鸿蒙端 `preprocessJson`，见 `entry/.../parser/NgaJsonSanitizer.ets`）
   > - 楼层字段名是 `data.__R`（双下划线开头、**单下划线结尾**）：检查响应完整性用
   >   `"__R":`（带引号冒号），用 `__R__` 会误匹配 `__R__ROWS`（分页行数）而误判
   >   "防爬空响应"——实测该 API 无防爬，请求均完整返回
3. 响应落盘，用 `tests/helpers.ts::loadSampleContent` 提取目标楼层 `content` 字段
4. 用 TS 镜像解析该 content，检查解析树/run 序列是否符合预期
5. devtools 打开帖子页，滚动至异常楼层，取该楼层内容容器
   （id 为 `postcontent<lou>` 或 `postcontentandsubject<lou>`）的 HTML
6. 官方 HTML 与解析输出逐项对照，差异即 bug
7. 修复镜像 → `npm test` → `npm run sync` → DevEco 编译 + Hypium
8. 固化回归样本：content 存 `samples/` 并登记 `samples.lst`；官方 DOM 存
   `samples/official-<tid>-lou<lou>.html`，run 序列存 `samples/official-<tid>-lou<lou>-runs.json`
9. 运行 `npm run snapshot` 生成 `<name>.snapshot.json`（快照测试遍历 samples.lst，
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
