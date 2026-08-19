---
name: nga-data-fetch
description: NGA 真实数据通用抓取工具。处理持久化登录凭证（校验/落盘/失效验证）、任意 NGA 接口的 JSON/HTML 获取、GBK 解码与净化后处理。用户要求抓取 NGA 真实数据（帖子、接口、页面）、诊断凭证失效/未登录、获取并持久化 Cookie、固化线上样本时使用。不处理帖子解析语义（BBCode/HTML 降级解析见 bbcode-ts skill）；不输出 Cookie 明文。
---

# NGA 通用数据抓取（tools/nga-data-fetch）

取数层：凭证管理、任意接口 JSON/HTML 获取、GBK 解码与净化后处理，适用于任何 NGA API
（`read.php` / `nuke.php` / `app_api` 等）。解析语义（`preprocessJson`、`parseHtmlToRawJson`）
由 nga-bbcode-ts 镜像提供，本工具只 require 其 dist，不复制（单源）。

## 职责边界

| 能做 | 不能做 |
|---|---|
| 校验/落盘/复用持久化凭证 | 输出 Cookie / UID / CID 明文（任何输出） |
| 实际请求验证凭证（门禁） | 伪造登录态、替用户登录 |
| 抓取任意 JSON 接口 / 页面并后处理 | 复制净化/解析逻辑进本工具（单源在 bbcode-ts） |
| 固化真实响应为样本 | 无真实输入时编造数据 |

## 凭证门禁（任何抓取前 MUST 通过）

**固定基准**：`nga-fetch verify` 必须成功获取 `https://bbs.nga.cn/read.php?tid=44191387`
的帖子信息（判定 = `kind=ok` 且含 `data.__R`）。**门禁未通过前，不得用持久化凭证抓取任何数据。**

```bash
node tools/nga-data-fetch/bin/nga-fetch.js verify    # exit=0 通过；exit=1 凭证失效（附刷新指引）；exit=2 业务拒绝（换 --url 复核，勿刷新凭证）
```

### 门禁失败 → 刷新凭证（严格方法，可快速重复）

1. 浏览器打开 `https://bbs.nga.cn/read.php?tid=44191387`，确认已登录。
2. 页面内触发真实请求（chrome MCP `evaluate_script`，自动携带含 httpOnly CID 的 Cookie）：

   ```js
   () => fetch('https://bbs.nga.cn/read.php?tid=44191387&page=1&__output=8&__inchst=UTF8').then(r => r.status).then(s => 'ok ' + s)
   ```

3. `mcp__chrome__list_network_requests`（xhr/fetch）定位刚发出的 `read.php?...__output=8` 请求。
4. `mcp__chrome__get_network_request` 提取该请求的 `Cookie` 请求头——比 `document.cookie` 权威
   （cid 为 httpOnly，`document.cookie` 读不到，MUST 走请求头）。
5. 核验：`ngaPassportUid`（非空数字）与 `ngaPassportCid`（原样保留，不 decode/截短/转小写）。
6. 落盘：`nga-fetch save '<完整 Cookie 请求头值>'`（结构校验，缺 CID 拒绝）。
7. **复验**：重新 `verify`，exit=0 后才允许抓取；仍失败回到第 1 步。

补充规则：

- `NGA_COOKIE` 环境变量优先于文件；`check` 只做结构校验，不能替代 `verify`。
- Cookie、UID、CID MUST NOT 出现在回复、日志、测试输出或样本中；`.nga-cookie.txt` 已 gitignore。

## CLI 参考（工具根：tools/nga-data-fetch，即 `node bin/nga-fetch.js`）

| 命令 | 说明 |
|---|---|
| `nga-fetch check` | 凭证结构校验（不发请求） |
| `nga-fetch save '<完整 Cookie 值>'` | 校验并落盘持久化凭证（缺 CID / 带 `Cookie:` 前缀 / 混入 Set-Cookie 属性则拒绝） |
| `nga-fetch verify [--url <u>]` | 凭证门禁：固定基准 `read.php?tid=44191387`，成功 = `kind=ok` 且含 `data.__R`；exit=2 = 业务拒绝（凭证结构有效，换 `--url` 复核，勿刷新凭证） |
| `nga-fetch json <endpoint> [k=v ...] [--out <file>] [--raw] [--base <url>]` | 抓取任意 JSON 接口并净化落盘；`--raw` 跳过业务判定 |
| `nga-fetch html <url> [--out <file>] [--marker <文本>]...` | 抓取任意页面，可选校验页面标记 |

凭证来源解析顺序：`NGA_COOKIE` 环境变量 → `NGA_COOKIE_FILE` 指定文件 →
工具默认 `.nga-cookie.txt` → 兼容回退 `tools/bbcode-ts/.nga-cookie.txt`。

## 安装与前置

```bash
cd tools/nga-data-fetch
npm install          # file: 依赖 nga-bbcode-ts（symlink）
cd ../bbcode-ts
npm run build        # 生成 dist（本工具 require 其净化器/域名常量）
```

## lib API（供脚本编排）

- `lib/credential.js`：`resolveCookie()` / `validateCookieStructure()` / `saveCookie()` / `checkCredential()`
- `lib/request.js`：`ngaFetchText(url, {cookie, encoding})` / `buildApiUrl(endpoint, params)` / `ngaHeaders(cookie)`
  （域名单源自 `NgaDomains.ts`；错误响应也做 GBK 解码，403 业务体可被识别）
- `lib/json.js`：`fetchNgaJson(endpoint, params, {raw})` —— 解码 → script store 提取 →
  `preprocessJson` 净化（require bbcode-ts dist）→ parse → 业务判定（error 15 / 51 等分类）
- `lib/html.js`：`fetchNgaHtml(url, {markers})` / `extractStoreJson(html)`

## 架构与分工

| 层 | 归属 | 说明 |
|---|---|---|
| 凭证/请求/解码/错误分类 | 本工具 | UA `NGA_WP_JW` + `X-User-Agent`，GBK/GB18030 |
| JSON 净化、script store 提取 | **引用 nga-bbcode-ts dist** | 镜像真源，同步回 `.ets`，本工具不复制 |
| 帖子 HTML → JSON 同形状 | **nga-bbcode-ts 镜像** | 本工具不包含 |
| 帖子特定逻辑（楼层/样本/成对） | bbcode-ts `scripts/` | 薄封装调用本工具 lib |

## 与其他 skill/文档的关系

| 需要做的事 | 走哪里 |
|---|---|
| 抓取帖子（楼层提取/样本登记/成对抓取） | bbcode-ts npm scripts（`inspect:json` / `inspect:html` / `fetch-thread-pair`），内部调用本工具 |
| 抓取用户发帖/回帖记录成对样本（JSON+HTML） | bbcode-ts `scripts/fetch-topic-pair.mjs <uid> [reply] [page]`，内部调用本工具 |
| 修改解析器/净化器/HTML 降级（镜像真源） | **bbcode-ts** skill（改 `tools/bbcode-ts/src/` → 门禁 → sync） |
| 修改抓取层/凭证逻辑、抓取任意接口 | 本 skill |
| 完整调查分流（JSON 优先、降级条件） | bbcode-ts skill（Rule 2） |
