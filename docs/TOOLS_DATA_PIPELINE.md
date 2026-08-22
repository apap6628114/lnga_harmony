# NGA 数据工具链：网页 API 与 APP API

## 能力边界

`tools/nga-data-fetch` 只负责认证、请求、解码和响应分类；
`tools/bbcode-ts` 是帖子 HTML 解释与 BBCode 渲染的 TS 镜像真源。

两套数据源在工具侧并存：

| 数据源 | 请求形态 | 用途 |
|---|---|---|
| 网页 JSON | GET `read.php?__output=8`，GBK/GB18030 | 稳定结构化对照基准 |
| 网页 HTML | GET `read.php`，GBK/GB18030 | 保留既有网页端 HTML 回归能力 |
| APP JSON | 签名 POST，UTF-8，`__output` 可配置 | APP 协议探测与结构化接口抓取 |
| APP HTML | 签名 POST `read.php`，`__output=17`、`__localres=1` | 鸿蒙帖子详情的现行数据源 |

鸿蒙运行时不保留网页 HTML 请求通道。`ThreadApi` 只请求 APP `__output=17`，
从 `code=521` 包装中提取 HTML，再进入由 `tools/bbcode-ts/src` 同步过去的唯一
HTML 帖子解释器。网页 HTML 只存在于 Node 工具的兼容与对照套件中。

## 凭证门禁

任何真实抓取前先在项目根执行：

```powershell
node tools/nga-data-fetch/bin/nga-fetch.js verify
```

固定基准 `read.php?tid=44191387` 必须成功返回 `data.__R`。

## 通用抓取

网页 API 保持原命令：

```powershell
node tools/nga-data-fetch/bin/nga-fetch.js json read.php tid=44191387 page=1 __output=8
node tools/nga-data-fetch/bin/nga-fetch.js html "https://bbs.nga.cn/read.php?tid=44191387&page=1"
```

APP 签名 API：

```powershell
node tools/nga-data-fetch/bin/nga-fetch.js app-json read.php tid=44191387 page=1 __localres=1 --output 11
node tools/nga-data-fetch/bin/nga-fetch.js app-html 44191387 1
```

带 `__lib/__act` 的 APP 接口把 URL 参数通过可重复的 `--query` 传入，业务参数仍写成
位置参数 `k=v`。签名附加串通过 `--sign-params` 指定。

## 帖子成对对照

网页 HTML 兼容套件保持不变：

```powershell
Set-Location tools/bbcode-ts
node scripts/fetch-thread-pair.mjs 44191387 1
npm run compare:html-json
```

APP HTML 现行套件：

```powershell
Set-Location tools/bbcode-ts
npm run fetch:app-pair -- 44191387 1
npm run compare:app-html-json
```

APP 套件固定以同一 `tid/page` 的网页 `__output=8` JSON 为真值，对比：

- 普通楼层集合与 pid、作者、时间、评分、客户端等字段；
- 正文可见文本覆盖率和附件；
- 用户表用户名；
- 主题标题、作者、版块、总楼数、页码、最后回复时间；
- `comment` 楼中楼贴条的数量及逐字段内容；
- `hotreply` 热门回复。

样本分别登记在 `samples/html-pairs.lst` 与 `samples/app-html-pairs.lst`，互不覆盖。

## 修改门禁

解析器修改必须从项目根确认镜像状态：

```powershell
node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry
```

随后在 `tools/bbcode-ts` 执行：

```powershell
npm test
npm run sync
node scripts/sync-to-ets.mjs --dry
```

最终还需执行 DevEco 编译、Hypium 与项目根行尾检查。
