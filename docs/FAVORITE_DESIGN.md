# NGA 主题收藏系统设计文档（Favorite）

> **2026-08 迁移说明**：主题收藏全链路已迁移至官方 APP 签名接口（POST form +
> sign，`__lib/__act` 放 URL query），网页版通道（`__output=8` 的
> `postWithQueryAndBody` 形态）已移除，不再降级。现行实现只走官方签名通道：
>
> - 收藏夹列表：`nuke.php?__lib=topic_favor_v2&__act=list_folder`，body `uid`+`page`，`__output=12`
> - 新建收藏夹：`nuke.php?__lib=topic_favor_v2&__act=new_folder`，body `name`+`opt`(`0`=设默认/`1`=不设，实测)，`__output=14`
> - 重命名收藏夹：`nuke.php?__lib=topic_favor_v2&__act=modify_folder`，body `folder`+`name`+`opt`（保持默认状态必须显式传），`__output=14`
> - 设为默认收藏夹：`nuke.php?__lib=topic_favor_v2&__act=modify_folder`，body `folder`+`name`+`opt=0`，`__output=14`
> - 删除收藏夹：`nuke.php?__lib=topic_favor_v2&__act=del_folder`，body `folder`，`__output=14`
> - 主题入夹：`nuke.php?__lib=topic_favor_v2&__act=add`，body `folder`+`tid`+`pid`(主楼 0)，`__output=12`
> - 主题出夹：`nuke.php?__lib=topic_favor_v2&__act=del`，body `folder`+`del`(tid 逗号串)，`__output=14`
> - 收藏夹内主题列表：`app_api.php?__lib=favor&__act=all`，body `folder`+`uid`+`page`（搜索加 `favkey`），`__output=12`
> - 收藏版面列表：`nuke.php?__lib=forum_favor2&__act=get`，body 无业务参数，`__output=12`
>
> 官方通道响应形状（ngabbs.com 实测，2026-08）：
>
> - `list_folder`（12）：`{"code":"0","result":[{id,type,name,bytes,length,default}]}`，
>   result 直接为收藏夹数组（字段均为字符串，default 缺失=非默认）；老封装 14 形状
>   `result=[[{...}],"0"]`（数组套数组，解析器防御兼容）
> - `new_folder`（14）：`{"code":"0","result":["操作成功",<新夹ID>]}`（ID 为 number）
> - `modify_folder`/`del_folder`/`del`（14）：`{"code":"0","result":["操作成功"]}`
> - `add`（12）：`{"code":"0","result":"操作成功"}`（result 为字符串）
> - `favor/all`（12）：`{"code":"0","msg":"操作成功","result":{"data":[主题数组]},
>   "totalPage":"1","total":"9","currentPage":"1","perPage":"35"}`（分页字段在顶层，
>   与 app_api.php user/subjects 同构，解析复用 parseAppUserTopicList）
> - `forum_favor2/get`（12）：`{"code":0,"result":[{id,fid,name,info}]}`（id==fid，
>   实测无 stid 字段；14 时为数组套数组分组，解析器兼容两种形状）
>
> 请求构造见 `service/api/FavoriteApi.ets`（收藏夹管理）与 `service/api/ForumApi.ets`
> （`getTopicList` 的 favor 分支），解析见 `parser/FavoriteParser.ets`。协议情报
> 完整来源：nga-hack `nga-client/docs/cards/3-nuke-user.md`（卡片 6/7）、AppUrls
> `GET_FAVORITES`/`ADD_FAVORITE`、`ct/d$a.smali` pswitch 映射（add/del/del_folder/
> modify_folder/new_folder/list_folder 六 act 与 FAVOR_ALL→app_api.php favor/all
> 已从 baksmali 确认）、`kt.c` 老封装（CREATE/EDIT/DELETE_FAVORITE、
> DELETE_POST_COMMENT、FAVOR_ALL）+ nga-hack nga-client 实测。

本文汇总 NGA 主题收藏（收藏夹）功能的接口契约与落地说明，作为 nga_oh 收藏系统的维护依据。
文中官方签名通道形状均通过真实登录账号在 ngabbs.com 上实测验证（list → new → modify →
add → del → del_folder 全流程闭环，测试夹已清理）。

---

## 1. 功能语义

NGA 主题收藏 = 账号级「收藏夹」体系：

- **收藏夹**：每个账号有多个收藏夹（其中至多一个默认夹），夹有 `id`/`name`/`type`（隐私位）/`length`（夹内主题数）/`default`（是否默认）。
- **收藏关系**：主题（tid）可加入任意收藏夹；主楼 pid=0。
- **收藏夹内主题列表**：按夹分页拉取主题（官方 `favor/all`，非 thread.php）。

nga_oh 覆盖的 UI：帖子详情「收藏到…」多选弹窗（`FavoriteFoldersPanel`）、个人主页「收藏主题」管理（`FavoriteSavedPanel` 在线收藏 Tab）、收藏夹内主题列表（`TopicListPanel` favor 分支）。

---

## 2. 接口协议（官方签名通道，实测验证）

所有接口走 `ngaClient.postSigned(path, lib, act, params, cookies, signParams, output)`，
`signParams` 恒为空串；`__lib/__act` 放 URL query，其余公共参数与业务参数放
POST body（urlencoded）。

### 2.1 收藏夹列表 `topic_favor_v2/list_folder`（`__output=12`）

```
POST https://ngabbs.com/nuke.php?__lib=topic_favor_v2&__act=list_folder
Body: uid={uid}&page=1&__output=12&app_id=1010&access_uid=..&access_token=..&t=..&sign=..
```

实测响应（字段均为字符串；default 缺失 = 非默认夹）：

```json
{"code":"0","result":[{"id":"8","type":"2","name":"攻略","bytes":"144","length":"9","default":"1"}]}
```

| key | 类型 | 含义 |
| --- | --- | --- |
| `id` | string | 收藏夹 ID（增删改、入夹用） |
| `name` | string | 收藏夹名 |
| `type` | string | 类型位（`type & 1 == 0` → 隐私夹，官方 `isPrivacy()`） |
| `length` | string | 夹内主题数 |
| `default` | string | 非 0 → 默认夹（官方 `isDefault()` = defaultStatus != 0） |
| `bytes` | string | 实测返回、未消费 |

老封装 `__output=14` 形状（防御兼容）：`{"code":"0","result":[[{...}],"0"]}`。

### 2.2 新建收藏夹 `topic_favor_v2/new_folder`（`__output=14`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=new_folder
Body: name={name}&opt={0|1}&__output=14&...
```

实测响应（新夹 ID 为 number，`extractFavoriteFolderId` 提取）：

```json
{"code":"0","result":["操作成功",16270236]}
```

> **opt 取值（2026-08 双夹对照实测，与官方反编译字面相反）**：`"0"`=设为默认，
> `"1"`=不设默认。官方 `kt.c.g(name, check)` 字面传 `check ? 1 : 0`，但实测
> opt=1 并不设默认、opt=0 才设为默认——以实测为准。nga_oh 传
> `setDefault ? "0" : "1"`。

### 2.3 重命名收藏夹 `topic_favor_v2/modify_folder`（`__output=14`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=modify_folder
Body: folder={folderId}&name={name}&opt={0|1}&__output=14&...
```

实测响应：`{"code":"0","result":["操作成功"]}`。

> **opt 必须显式携带（实测）**：modify_folder 缺省 opt 会被服务端解释为
> **「设为默认」**（非默认夹改名后意外变默认）；opt="1" 则取消默认。nga_oh
> 重命名对话框无「设为默认」开关，按目标夹当前默认状态传 opt 以保持状态：
> 当前为默认夹 → `opt="0"`（设为默认=保持），否则 → `opt="1"`（不设=保持）。

### 2.4 设为默认收藏夹 `topic_favor_v2/modify_folder`（`__output=14`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=modify_folder
Body: folder={folderId}&name={name}&opt=0&__output=14&...
```

> **两个实测硬约束**：① 设为默认必须显式传 `opt="0"`（与官方反编译字面
> `opt=1` 相反）；② **name 必填**——缺 name（仅 folder+opt）时服务端返回
> "操作成功"但行为异常（实测会把目标夹的默认状态清空）。nga_oh 由
> FavoriteStore 快照提供当前夹名。响应同 2.3。

### 2.5 删除收藏夹 `topic_favor_v2/del_folder`（`__output=14`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=del_folder
Body: folder={folderId}&__output=14&...
```

实测响应：`{"code":"0","result":["操作成功"]}`（夹内收藏关系一并删除）。

### 2.6 主题入夹 `topic_favor_v2/add`（`__output=12`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=add
Body: folder={folderId}&tid={tid}&pid={pid|0}&__output=12&...
```

实测响应（result 为**字符串**）：`{"code":"0","result":"操作成功"}`。

> 官方新链路 `FavoriteRepository.addFavorite(id, tid, pid)` 恒带 `pid`（主楼为 0）；
> 旧网页版通道只传 tid。nga_oh 迁移后补传 `pid=0`。

### 2.7 主题出夹 `topic_favor_v2/del`（`__output=14`）

```
POST .../nuke.php?__lib=topic_favor_v2&__act=del
Body: folder={folderId}&del={tid 逗号分隔串}&__output=14&...
```

实测响应：`{"code":"0","result":["操作成功"]}`。

> 官方老封装 `kt.c.L0(folderId, subjects)` 用 `del` 参数（tid 逗号串，可批量移除）；
> 旧网页版通道的 `tidarray` 参数名已废弃，迁移后以官方 `del` 为准。

### 2.8 收藏夹内主题列表 `favor/all`（`__output=12`）

```
POST https://ngabbs.com/app_api.php?__lib=favor&__act=all
Body: folder={folderId}&uid={uid}&page={page}[&favkey={搜索词}]&__output=12&...
```

实测响应（result.data 直接为主题数组，分页字段在**响应顶层**，值可能为 string）：

```json
{"code":"0","msg":"操作成功","result":{"data":[{"tid":44627932,"fid":843,"author":"ShieldCannon",
  "authorid":67071786,"subject":"...","postdate":1758307501,"lastpost":1787217026,
  "lastposter":"树叶砖工","replies":50,"type":32,"forumname":""}]},
 "totalPage":"1","total":"9","currentPage":"1","perPage":"35"}
```

- 条目字段与 `app_api.php user/subjects` 同构（含 `titlefont_api`/`topic_misc_var_bit1` 等透传字段），解析复用 `parseAppUserTopicList`（result.data + 顶层 totalPage 形状已兼容）。
- 搜索参数为 `favkey`（官方老封装 `kt.c.P0` 的 keyword；thread.php 网页版用 `key`，参数名不同）。实测（2026-08）`favkey` 缺省与空串等价（均返回 8 条，与不带 favkey 相同）。
- **`folder='1'`（默认夹别名）实测有效**（2026-08）：favor/all folder='1' 与传真实默认夹 id 返回完全一致（total=9、8 条）；TopicListPanel 的 `favor || '1'` 回退语义成立。
- 官方接口无 thread.php 的 `__T/__U` 结构与 `recommend` 标记，UI 按既有主题行渲染。

### 2.9 错误形态

统一 `code!=0 + msg`（实测 `{"code":1,"msg":"参数错误"}`；`code` 可能为字符串）。
`extractFavoriteError` 另防御旧网页版 `{"error":{"0":"..."}}` 与 ngaRequest 的
`__parseError` 响应。

---

## 3. 行为变更点（迁移影响面）

| 项 | 旧（网页版通道） | 新（官方签名通道） | 影响 |
| --- | --- | --- | --- |
| 请求方式 | `postWithQueryAndBody`（`__output=8`） | `postSigned`（`__output=12/14`） | 全部收藏操作走签名通道，规避网页版接口限流 |
| `list_folder` 参数 | 仅 `page` | `uid` + `page`（官方必填 uid） | 无感（uid 取当前会话） |
| `new_folder`/`setDefault` 的 `opt` | 网页版 `2`=设默认 | 实测 `0`=设默认/`1`=不设（缺省 opt=设默认，与官方反编译字面相反） | 以实测为准；rename 必须显式带 opt 保持默认状态 |
| `modify_folder` 的 `name` | 可缺省 | **必填**（缺 name 时默认状态异常） | setDefault 由 Store 快照提供夹名 |
| 主题出夹参数 | `tidarray` | `del`（官方老封装） | 参数名变化，服务端按官方语义 |
| 主题入夹 | 仅 `tid` | `tid` + `pid=0` | 补传 pid |
| 收藏夹内主题列表 | `thread.php?favor=`（JSON+HTML 双通道） | `app_api.php favor/all`（唯一通道） | 移除 thread.php 依赖；失败即报错不再降级 |
| 收藏夹列表解析 | `data['0']` 数字键字典 | `result` 直接数组（字段全字符串） | 解析器重写；旧网页版字典形状已移除（官方 12/14 两种形状兼容） |
| 新建夹 ID 提取 | `data['1']`/`data['0']` | `result[1]`（number） | `extractFavoriteFolderId` 兼容多形状 |
| 收藏版面列表 | `forum_favor2/forum_favor`+`action=sync`（`__output=8`） | `forum_favor2/get`（`__output=12`） | 官方 ForumRepository 同款入口 |
| 收藏版面 stid | 旧实现 `stid=item['id']`（=fid，语义错误） | 官方实测无 stid 字段 → `stid=0` | 修复性变更；当前消费方（CommunityPanel/SocialListSettings）不消费 stid，无回归 |
| 写操作成功判定 | `parseNgaError`（error 对象） | `extractFavoriteError`：code=0 即成功（写操作响应 result 形态多样，不做 result 形状校验，与 FollowApi 一致） | 实测写操作恒带 result；`__parseError` 已挡解析失败 |

## 4. 相关文件

| 文件 | 职责 |
| --- | --- |
| `entry/src/main/ets/service/api/FavoriteApi.ets` | 收藏夹管理接口（list_folder/new_folder/modify_folder×2/del_folder/add/del）+ 收藏版面列表（forum_favor2/get） |
| `entry/src/main/ets/service/api/ForumApi.ets` | `getTopicList` favor 分支 → `favor/all`（收藏夹内主题列表） |
| `entry/src/main/ets/parser/FavoriteParser.ets` | `parseFavoriteTopicFolders` / `extractFavoriteFolderId` / `extractFavoriteError` / `parseForumFavoriteBoards` |
| `entry/src/main/ets/parser/AppUserTopicParser.ets` | `parseAppUserTopicList`（favor/all 复用） |
| `entry/src/main/ets/store/FavoriteStore.ets` | 收藏夹快照 + 成员关系提示缓存（调用方不变） |
| `entry/src/test/FavoriteUnit.test.ets` | 收藏夹解析/ID 提取/错误提取/版块收藏解析单测（官方形状 fixtures） |
| `entry/src/test/AppFavoriteTopicUnit.test.ets` | favor/all 解析单测 |

## 5. 风险与边界

- **协议无官方文档**：形状以本文实测为准；服务端结构变化由解析层集中容错。
- **写操作幂等**：add/del/modify 等写操作 UI 需防重复提交（Store 已按 folderId+tid
  去重 pending mutation）。
- **限流**：官方签名通道为 APP 同款认证，规避网页版通道限流；列表分页仍不宜过密。
- **收藏版面写操作**（收藏/取消收藏板块）为鸿蒙端本地管理（`SettingsState.favorites`
  本地增删），仅列表拉取走官方 `forum_favor2/get`；如需服务端同步可后续接入
  `favorforum/sync`（app_api.php）。
