# NGA APP API 迁移评估报告：剩余可迁移项与无对应项清单

> 评估日期：2026-09（按工作区文件时间戳）
> 协议权威：`C:\Users\ll\Desktop\nga-hack\nga-client\docs\cards\`（13 张逆向情报卡片，v7.17.17）
> 补充权威：`nga-hack\jadx-out\sources\com\donews\nga\interfaces\AppUrls.java`（官方 URL 常量全集）、
> `nga-hack\ct_d_pswitch_map.txt`（Parsing→URL 映射全集）、`nga-hack\nga-client\docs\{interface-cards,network-layer,nga-harmony-arkts}.md`
> 评估对象：`entry/src/main/ets/service/` 下全部 API 通道（NgaClient + 11 个 api 模块）+ 全库 grep 交叉验证

---

## 1. 总评

鸿蒙客户端的 API 迁移已覆盖**全部核心读写链路**：帖子读取（read.php __output=17 官方 HTML 通道）、
主题列表/搜索（thread.php POST+sign）、首页分类/版块搜索（app_api.php）、用户发帖回帖（user/subjects|replys）、
私信/通知（message/*、notify/list）、关注系（follow_v2/*）、收藏系（topic_favor_v2/*、forum_favor2/get、favor/all）、
发帖/回帖/贴条/修改/引用/上传（post/* 全链路）、投票（subject/vote）、推荐/反对（post/recommend）、
签到（check_in/check_in）、用户信息（ucp/get）、登出（login/logout）——**均已是官方 APP 签名接口**，
网页版降级通道（thread.php?lite=js、nuke.php __output=3/8 形态等）已彻底移除。

**剩余未迁移的网页通道仅 1 处**，且有明确处置结论（见 §2）：

1. 登录系（`nuke.php login/login` + `login_check_code.php` + WebView account.html）——**官方 App 自身即走此通道**
   （登录接口无签名体系，靠 `__ngaClientChecksum` 防伪），不存在「迁移」问题。

> 子版块筛选（`nuke.php user_option/set`）已于 2026-09 迁移至官方 APP 签名接口
> `app_api.php subject/subscription`（订阅/取消订阅，含 subject/list 的
> subForum.checked 状态读取），网页通道已彻底移除，详见 §5 末行。

此外发现 **4 项「本地实现但官方有服务端接口」的候选迁移**（黑名单/屏蔽词/收藏版面/私信已读，见 §3），
以及 **若干官方有接口但鸿蒙端无对应功能**的未来能力（§4）。

---

## 2. 仍未迁移的网页 API（现存通道盘点）

| # | 通道 | 位置 | 形态 | 官方 APP 对应 | 结论 |
|---|---|---|---|---|---|
| ~~W1~~ | ~~`nuke.php?__lib=user_option&__act=set&__output=8`（子版块筛选显示状态）~~ | ~~`ForumApi.setSubforumFilter`~~ | ~~POST form + Cookie，无签名~~ | **已迁移**：`app_api.php subject/subscription`（官方 SUBSCRIBE/CANCEL_SUBSCRIBE，pswitch_2cc）+ `subject/list` 的 `subForum.checked` 状态读取（见 §5 末行） | ✅ 已迁移（2026-09） |
| W2 | `nuke.php?__lib=login&__act=login`（账号密码登录） | `NgaClient.loginPassword`（multipart + RSA + `__ngaClientChecksum`） | POST multipart，`__output=1` 脚本包装响应 | 官方 App 登录同通道（卡片 7：H5 页 JS 提交，原生不直连；nga-client 已按页面 JS 复刻） | **官方即此通道**，非迁移对象 |
| W3 | `login_check_code.php?id=&from=login`（登录验证码图） | `NgaClient.getCaptchaV2` | GET 图片 | 官方登录同通道 | 同上，非迁移对象 |
| W4 | WebView `account.html` 系列（登录/注册/改密/换绑/注销/OAuth） | `LoginPage`、外部链接分发 | H5 页面 | 官方 App 全部内嵌 WebView 使用 | 同上，非迁移对象 |

> 结论：**当前代码库中已不存在「可用官方 APP 接口替换但尚未动手」的网页 API**。
> W1（子版块筛选）已于 2026-09 迁移至 subject 系官方签名接口；W2–W4 为登录系，
> 官方 App 自身即此通道，不存在迁移问题。

---

## 3. 本地实现 → 官方 APP 接口（推荐迁移候选，按优先级）

鸿蒙端以下功能目前是**纯本地存储**，官方 App 有对应的服务端接口。迁移后获得跨端一致性
（换机/多端同步），且这些官方接口均为签名通道，可避开网页版限流。⚠️ 均需实测验证后再落地。

### P1. 黑名单（推荐，高价值）
- 现状：`SettingsStore.blacklist`（`BlacklistPanel.ets` 纯本地增删，无服务端同步）
- 官方接口（卡片 2，app_api.php）：
  - `block/list`（拉黑名单，`@Deprecated` 但可用）：POST form，`__output=14`，signParams 空
  - `block/add`：body `uid`，signParams=`uid`，`__output=14`
  - `block/del`：body `uid`，signParams=`uid`，`__output=14`
- 迁移方式：本地黑名单启动时与 `block/list` 合并（服务端为准 + 本地合并），增删操作同步调 `block/add|del`；
  或按官方语义以服务端为唯一真源。
- 备注：`block/list` 官方标注 `@Deprecated`，但 v7.17.17 仍存在调用点（kt.c.u），可用性需实测。

### P2. 关键词屏蔽（推荐）
- 现状：`FilterKeywordsPanel` + `SettingsStore`（纯本地标题屏蔽词）
- 官方接口（卡片 3，nuke.php）：
  - `ucp/get_block_word`：POST form，`__output=14`，signParams 空；空数据实测返回 `{"code":0,"result":null}`
  - `ucp/set_block_word`：body `data`，格式 `1\n<词1> <词2>...\n<uid1>/<用户名1>...`（**分隔符为空格**，verify 文档修正），`__output=14`
- 迁移方式：启动拉取 `get_block_word` 合并本地；保存时 `set_block_word` 全量上传。
- 备注：官方 `data` 格式（verify 文档已修正）= 第 1 行 `1` + 空格分隔关键词 + 换行后 `uid/用户名` 行（分隔符为**空格**，
  `HanziToPinyin.Token.SEPARATOR`，非逗号）；非空响应实体 `ShieldKeyword{_id,keyword,loginUid}`（分组方式仍需实测）；
  空数据实测 `{"code":0,"result":null}`。官方 App 本地 ormlite 存储 + 启动拉取模型，与鸿蒙端 SettingsStore 语义一致。

### P3. 收藏版面（推荐，但需先补 UI 语义）
- 现状：`appStore.settings.favorites`（`TopicListPanel.toggleCurrentBoardFavorite` 纯本地增删）；
  读侧已接 `forum_favor2/get`（`FavoriteApi.fetchForumFavorites`，官方接口）
- 官方接口（AppUrls + 卡片 2）：
  - 读：`nuke.php forum_favor2/get`（已接入）
  - **写（同步整表）**：`app_api.php favorforum/sync`，body `fidlist`（收藏版面 fid **逗号拼接**），
    signParams=`fidlist` 完整串，`__output=14`；官方 App 以「本地整表 → 全量同步」模型工作
- 迁移方式：收藏/取消收藏后调 `favorforum/sync` 上传整表；启动时以 `forum_favor2/get` 结果覆盖本地。
- 备注：鸿蒙端收藏版面（FavBoard）含 stid 语义（`favorite.stid`），官方 `forum_favor2/get` 的 Item 含
  `id/fid/stid/name/info` 字段，可对齐；`favorforum/sync` 的 l1 变体（file 参数）为上传文件形态，非默认。

### P4. 私信已读 / 离开会话（可选）
- 现状：私信已读为本地 `UnseenListPolicy` 模型（`MessageListPanel`/`NotificationPanel`），不通知服务端
- 官方接口：`app_api.php message/leave`，body `did` + `uid`，signParams=`did+uid`，`__output=12`
- 迁移方式：进入会话详情 / 点击已读时调 `message/leave`（官方语义 = 已读 + 移除会话提醒）。
- 备注：官方 App 无 `message/read` act（已由 leave 承担）；鸿蒙端无「删除会话」UI，leave 仅用于已读同步，优先级低。

### P5. 签到状态展示（可选增强）
- 现状：仅 `check_in/check_in`（手动/自动签到），无签到状态展示
- 官方接口：`nuke.php check_in/get_stat`（**URL 与响应均已实测**：`{code:0,result:[{continued,sum,money,money_n,...}]}`，
  result 为数组；App 内无调用点、属保留代码 gt/a.java，服务端接受请求）
- 迁移方式：个人页展示连续签到天数/累计；实测字段为字面推断，落地前抓包确认键名。
- 备注：官方自动签到（`check_in/check_in` + `_auto=1` + `__ngaClientChecksum`）鸿蒙端已实现且完全一致 ✓

---

## 4. 官方 APP 有接口、鸿蒙端暂无对应功能（未来能力候选）

以下功能鸿蒙端**尚未实现**（无 UI/无调用），官方接口已确认存在。接入时直接使用官方签名通道即可，
不存在「网页版待迁移」问题；按产品优先级决定是否排期。

| 功能 | 官方接口 | 备注 |
|---|---|---|
| 举报 | `nuke.php log_post/get_report_predef`（原因预定义，body fid/stid）+ `log_post/report`（提交，body pid/tid/content，signParams=tid） | 双 URL 已确认：`app_api.php post/report`（smali 主映射，pswitch_4b6）+ `nuke.php log_post/report`（实测有效但缺 info 参数返回 code=1「参数错误」，完整参数集需实测）；另一入口 `message/message&act=report`（私信举报） |
| 删除附件 | `nuke.php del_attach/del_attach`（body tid/pid/aid，`__output=14`） | 编辑帖子（modify）删图/删视频场景；鸿蒙端编辑仅回填+追加附件，无单删 |
| 搜索联想 | `nuke.php search/instant_search`（body word，`__output=12`，响应 recom_list） | 搜索框输入联想 |
| 登录态校验 | `nuke.php login/iflogin`（`__output=12`，响应 result.username） | 鸿蒙端现用 ucp/get 校验会话，等效；可作轻量替代 |
| 首页推荐流 | `nuke.php app_inter/recmd_topic`（page+opt） | 无首页推荐 UI |
| 首页 Banner | `nuke.php app_inter/banner_list` | 无 |
| 热帖/CPS | `nuke.php app_inter/cpsgame` | 无 |
| 版内推荐主题 | `nuke.php load_topic/load_recommend_by_fid`（body fids） | 无 |
| 收藏夹内搜索 | `nuke.php topic_favor_search/search_favors` | 鸿蒙端收藏搜索已用 `favor/all`+favkey 实现，等效 |
| 消息屏蔽总开关 | `nuke.php user_block/set_block_all`（body set=on/off） | 无 |
| 修改昵称 | `nuke.php?changename`（原生 POST，body nickName） | 无（账号中心 H5 也有） |
| 头像上传/头像挂件 | `ct.e.p` 原生 multipart（func=upload&avatar=1，sign 仅 t）/ `item/ap_avatar:*`、`set_buff/avatar_list` | 无 |
| 版本更新检查 | `nuke.php version_update/get_version_info` | ct.d.d 映射已确认（pswitch_49） |
| 过滤器操作日志 | `nuke.php filter/get_log` | ct.d.d 映射已确认（ct.d.f114593h），用途待实测 |
| 回复链/楼中楼拉取 | `nuke.php load_topic/load_topic_reply_ladder|ladder2` | 鸿蒙端楼中楼来自 HTML 解析（comment_for_<pid>），通知跳转用二分定位，等效；ladder2 实测返回主题数组（首页热帖用） |
| 私信会话列表的「已读离开」 | `app_api.php message/leave` | 见 §3 P4 |
| 静态资源清单 | `nuke.php app_inter/static_file_list` | App 启动资源预载，鸿蒙端无此需求 |
| 版面权限说明 | `nuke.php view_privilege/view`（code=521 特判 H5） | 无 |
| 获取公网 IP | `nuke.php ucp/get_client_ip` | 无 |

**明确不需要的官方功能域**（鸿蒙端产品面外）：VIP/支付（vip_pay/*、ap_vip_pay/*、blackstore/*、item/ap_vip:*、
redeem/*）、头像挂件/皮肤（ap_avatar/ap_skin）、游戏平台绑定（steam/psn/nintendo/arknights/genshin/auth_ys4fun/
event_mission_blizzard）、短剧（tvjoy/charge_unlock）、任务墙（mission/*、misc/mission/mission.php）、
「赞一下」商城（Great 加密域 13 接口，SHA-1+AES 独立签名体系）、附近的人（nearby）、聊天（chat/channel_list）、
广告/数据上报（general_ad_debug、data_query/temp_api_log|topic_share_log_v2）、账号中心 H5 系列。

---

## 5. 网页 API 在 APP 无对应的清单（重点核对结论）

以下为鸿蒙端**曾经使用或仍在使用**的网页版 API，逐一核对官方情报域（13 卡片 + AppUrls + pswitch 全集 + 源码）：

| 网页 API | 鸿蒙端现状 | APP 对应 | 处置 |
|---|---|---|---|
| `thread.php?lite=js`（网页版主题列表 JSON） | 已移除（2026-08 迁移） | ✅ `thread.php` POST+sign（官方通道） | 已解决 |
| `thread.php` GET + `__output=11`（网页版数据最全形态） | 已移除 | ✅ 官方 thread.php 通道（`__output=14`） | 已解决 |
| `read.php?__output=17` 结构化 JSON（data.__R） | 已改走官方 HTML 包装（同 URL、同 output） | ✅ 官方 read.php 通道（App 自身用 17） | 已解决 |
| `post.php`（网页版发帖） | 已移除（GBK 发帖链删除） | ✅ `app_api.php post/*` | 已解决 |
| `ucp.php` / `nuke.php?func=ucp`（网页版用户页） | 已移除 | ✅ `nuke.php ucp/get` | 已解决 |
| `nuke.php?__lib=noti&__act=get_all`（网页版通知） | 已移除 | ✅ `app_api.php notify/list` | 已解决 |
| `nuke.php message/message&act=list|read`（网页版私信） | 已移除 | ✅ `app_api.php message/list|detail` | 已解决 |
| `nuke.php __output=3` 关注动态（网页版） | 已移除 | ✅ `follow_v2/get_push_list` | 已解决 |
| `nuke.php __output=8` 收藏系（网页版） | 已移除 | ✅ `topic_favor_v2/*`、`favor/all` | 已解决 |
| **`nuke.php user_option/set`（子版块筛选，__output=8）** | **已迁移**（2026-09） | ✅ **`app_api.php subject/subscription` + `subject/list`**：官方 App 的「子版块筛选」即订阅机制——SUBSCRIBE/CANCEL_SUBSCRIBE（`Parsing` → `ct/d.smali :pswitch_2cc` → `app_api.php?__lib=subject&__act=subscription`），body `ufid`（父版块）/`fid`（子版块）/`type`（1=订阅 2=取消）/`sub_type`/`tid`，signParams=`ufid+fid+type`；订阅状态由 `subject/list` 响应 `result.subForum[].checked` 提供（账号级真实状态，替代 thread.php `sub_forums` 的 attributes 启发式），`allow_checked=0` 的版面服务端已排除其主题混合且 UI 禁用开关。已实测：取消订阅（type=2）后 `checked` 立即翻转、主题从列表消失；恢复订阅（type=1）还原 | **已解决**（`setSubforumFilter` → subject/subscription；`getTopicList` 版面列表/搜索 → subject/list\|search；`postWithQueryAndBody`、thread.php 列表通道、网页 sub_forums 解析已移除） |
| `nuke.php login/login`、`login_check_code.php`、`account.html` 系列 | 仍在使用（登录） | ⚠️ 官方 App 登录即此通道（无签名体系） | 非迁移对象 |

---

## 6. 附：迁移经验要点（供后续 P1–P5 落地）

1. **通道层已具备**：`ngaClient.postSigned(path, lib, act, params, cookies, signParams, output, includeChecksum, inchst)`
   即官方签名通道（`__lib/__act` 放 URL query，公共参数与业务参数进 body，完整认证头，固定 ngabbs.com）。
   P1–P5 均为该通道的简单扩展，无需新增底层设施。
2. **`__output` 纪律**：`buildNew()`=12 / `build()`=14 / 显式覆盖；收藏系实测 12/14 形状有差异
   （`forum_favor2/get` 12=扁平数组、14=分组数组），解析器需兼容两种形状（FavoriteParser 已兼容）。
3. **signParams 纪律**：P1 的 `block/add|del`=uid、P3 的 `favorforum/sync`=fidlist 完整串、P4 的 `message/leave`=did+uid；
   写错返回 `code=5 签名错误`。`block/list`、`get_block_word`、`set_block_word`、`get_stat` 均空。
4. **需要 checksum 的接口**：`check_in/check_in`（已带 `__ngaClientChecksum`）；`notify/list`（已带）；
   其余 P1–P5 无 checksum 要求。
5. **实测优先**：`block/list`（@Deprecated）、`get_block_word` 非空响应分组、`set_block_word` 的 data 格式、
   `favorforum/sync` 的响应形态、`get_stat` 字段——均标注「需实测」，落地前用 nga-data-fetch 工具验证。
6. **限流缓解**：所有官方接口经 `executeWithRetry` + `ngaThrottler`（6 并发/150ms/domain），
   迁移项自动获得与现有 APP 接口一致的限流保护（子版块订阅切换 subject/subscription 同享）。
7. **subject 系响应的时钟限制**：`subject/list|search` 响应**无 `time` 字段**（thread.php 有），
   `parseSubjectList` 以本地 `Date.now()` 兜底 `curTime`——热门模式 24h/7d/30d 时间窗过滤
   （`TopicListPanel`）随之依赖设备时钟，设备时钟偏差会造成窗口偏移（已注释 + 单测覆盖，
   属已知限制）。
