# NGA 板块列表与主题列表官方签名通道设计（Forum / TopicList）

> **2026-08 迁移说明**：鸿蒙端板块分类、板块内帖子列表、主题搜索、版块搜索已
> 全面接入官方 APP 签名通道（POST form + sign，`ngaClient.postSigned` /
> `postSignedPath`），缓解网页版 JSON 通道的官方限流。协议情报完整来源：
> nga-hack `nga-client/docs/cards/1-read-content.md`（卡片 R2）与
> `2-app-business.md`（卡片 1），并经 nga-hack `nga-client` 真实凭证实测复核。

## 迁移范围

| 功能 | 旧通道（已下线/降级） | 新通道（官方签名） | 入口文件 |
| --- | --- | --- | --- |
| 板块分类树 | GET `app_api.php?__lib=home&__act=category`（未签名） | POST+sign `home/category`，`_v=2`，`__output=14`，signParams 空 | `service/api/ForumApi.ets` `getForumCategories` |
| 板块内帖子列表 | GET `thread.php?lite=js&noprefix`（网页版 JSON，限流重灾区） | POST+sign `thread.php`（无 `__lib/__act`），`__output=14`，signParams=fid | `ForumApi.getTopicList` |
| 主题搜索 | 同上（key 变体） | POST+sign `thread.php`，`key`+`table=7`，signParams=key | `ForumApi.getTopicList`（key 分支） |
| 版块搜索 | GET `forum.php?__output=8`（App 中**不存在** forum.php 入口） | POST+sign `app_api.php?__lib=forum&__act=search`，`key`+`page`，signParams=key；**失败降级网页版 forum.php**（官方接口关键字长度校验苛刻，中文短词必被 2048 拒绝） | `ForumApi.searchForum` |

不在本次范围（沿用既有官方通道）：用户发帖/回帖历史（`user/subjects|replys`）、
收藏夹内主题列表（`favor/all`）、帖子详情（`read.php` `__output=17` HTML 解析通道）。

## 未迁移接口（明确边界）

以下板块相关接口**保持网页版通道**，原因是 nga-hack 逆向情报（AppUrls/ct.d/kt.*）
中无对应官方实现证据，不编造协议；均为低频管理/辅助功能，非限流重灾区：

| 接口 | 用途 | 调用点 | 现状 |
| --- | --- | --- | --- |
| `nuke.php topic_key/get`（GET） | 发帖时的版块主题分类标签 | `ThreadApi.getTopicCategories`（`NewTopicManager` 发帖面板） | 保持网页版通道 |
| `nuke.php user_option/set`（POST） | 子版块显示/屏蔽设置 | `ForumApi.setSubforumFilter`（TopicListPanel 子版块筛选面板） | 保持网页版通道（MNGA 同款） |

若后续 nga-hack 补充这两组接口的官方协议（smali/抓包），按本文档同款模式迁移。

## 官方接口协议（实测，ngabbs.com）

### 1. 板块分类 `app_api.php?__lib=home&__act=category`

- 请求：POST form；`__lib/__act` 在 **URL query**；body 含公共参数 + `_v=2`；
  `__output=14`；signParams 空。
- 响应：`{code:0, msg, result: Category[], forum_icon_pre, forum_icon_list,
  forum_recommend, ...}`；`result` 为**数组**（实测 7 个分类）。
- `Category` 元素：`{id(恒 0), _id(分类标识，如 "other"/"wow"), name,
  groups:[{name, id, info, forums:[{fid, name, bit, is_forumlist, id, icon,
  info, nameS}]}]}`。
- 图标：`forum_icon_pre`（如 `http://img4.nga.cn/ngabbs/nga_classic/f/app/`）+
  `forum_icon_list` 编码表按 `_id` 拼 URL；鸿蒙端 `BoardContent.head` 虽有
  `icon` 字段赋值但 UI 暂未消费，后续可按需解析。

### 2. 板块内帖子列表 / 主题搜索 `thread.php`（无 `__lib/__act`）

- 请求：POST form（**URL 无 query**）；body 含公共参数 + 业务参数；
  `__output=14`；签名 `signParams`：
  - 变体 A 普通列表：`fid`（**`"356"` 映射为 `"323"`**，对齐官方 kt.c.e0）；
    `stid` 场景 fid 置空 → signParams 空
  - 变体 C 主题搜索：`key`（`table=7` 固定）
  - `page > 100` 必须补 `order_by=postdatedesc&nounion=1`（否则服务端报 2048）
- 响应：`{code:0, result:{__CU, __GLOBAL, __ROWS, __T:[...], __T__ROWS,
  __T__ROWS_PAGE(35), __R__ROWS_PAGE, __F}}`：
  - `__T` 为**数组**（网页版为 tid 字典），元素字段 `tid/fid/quote_from/icon/
    topic_misc/author/authorid/subject/type/postdate/lastpost/lastposter/replies/
    lastmodify/recommend/jdata/attachs/tpcurl/topic_misc_var/parent`；匿名作者
    `#anony_*` 同网页版
  - `__F`：`{fid, name, topped_topic, sub_forums, __SELECTED_FORUM}`；
    `sub_forums` 为「键 → [fid, 名称, 简介, tid, 类型位]」数组值字典（与
    `parseSubBoards` 兼容）；搜索响应 `__F` 为空数组 `[]`
  - **顶层无 `time`**（网页版有）→ 归一化时以本地秒级时间戳兜底
    （24 小时热门窗口依赖 `curTime`）
  - 错误：`code != 0` + `msg`（如 2048「页面错误」、15「频率限制」、
    5「签名错误」），无网页版 `error` 对象

### 3. 版块搜索 `app_api.php?__lib=forum&__act=search`

- 请求：POST form；`__lib/__act` 在 URL query；body `key` + `page`；
  `__output=14`；signParams=key（逆向 `NetRequestWrapper.E0`：`ft.k.T="page"`、
  `ft.m0.b="key"`，`v0(hashMap, str)` 追加签名）。
- 响应：`{code:0, msg:"操作成功", result: Forum[]}`，元素 `{id, fid, stid,
  name, parent:{fid, name, descrip}, info}`。
- ⚠️ **关键字长度校验苛刻**（实测）：ASCII 8~10 字符可行（`warcraft` 成功）；
  中文 7 字以内、11 字以上均 2048「关键字过短/长」；无匹配返回 2048
  「没找到符合条件的版面」。**鸿蒙端保留网页版 `forum.php` 降级**（官方失败时
  走旧通道，短词搜索体验不回退）。

## 实现结构

| 文件 | 职责 |
| --- | --- |
| `service/NgaClient.ets` | `postSigned`（`__lib/__act` 在 URL query）；新增 `postSignedPath`（无 `__lib/__act`，thread.php/read.php 专用）；公共部分抽出 `buildSignedFields` / `buildSignedHeaders` / `ngaPostSignedCore` |
| `parser/AppTopicListParser.ets` | 官方 thread.php 响应解析（纯函数）：`extractAppTopicListError`（code!=0 → msg）、`parseAppTopicList`（`{code,result}` → `{data,time}` 归一化 + `__T` 数组→数字键 Record，复用 `parseTopicList`） |
| `service/api/ForumApi.ets` | `getForumCategories` / `getTopicList` / `searchForum` 官方通道编排；`buildAppThreadQuery` / `buildAppSignParams` / `normalizeAppFid` |
| `parser/ForumParser.ets` | `parseForumSearch` 兼容官方 `result` 数组；`parseForumCategories` 兼容官方 result 数组（数字键遍历天然兼容） |
| `parser/TopicParser.ets` | 未改动（官方归一化后同形状复用） |

`getTopicList` 通道编排（普通版面/搜索）：

1. `authorid`（用户主页）与 `favor`（收藏夹）分支不动，仍走既有官方接口；
2. 普通版面/搜索：官方签名通道 `thread.php`（`postSignedPath`）是**唯一通道**，
   失败/业务错误/解析失败即返回错误，**不再降级**（与关注/收藏/用户列表迁移
   模式一致；网页版 JSON 通道与 HTML 静态页降级均已移除，相关死代码已清理：
   `buildThreadQuery`、`TopicListHtmlParseTask`、`TopicListResult.viaHtml/jsonError`，
   以及 html-topiclist 镜像解析器——2026-08 经 bbcode-ts 门禁整体移除，
   镜像数量 34→31，含 `fetch-topic-pair` 脚本与成对样本）。

`searchForum` 通道编排：官方 `forum/search` 主通道；**保留网页版 `forum.php`
降级**——官方接口对中文短词（≤7 字符）必返 2048「关键字过短/长」（实测 ASCII
8~10 字符才可），降级是功能补偿而非旧模式残留。

## 测试

- `entry/src/test/AppTopicListUnit.test.ets`（已注册 `List.test.ets`）：
  `extractAppTopicListError` 错误提取、`parseAppTopicList` 官方形状解析
  （主题字段/子版块/分页/匿名/黑名单/关键词）、`curTime` 本地兜底、
  业务失败与形状异常返回 null、`parseForumCategories` 官方分类数组、
  `parseForumSearch` 官方 result 数组与网页版 data 数组兼容。
