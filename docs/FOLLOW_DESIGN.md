# NGA 关注系统设计文档（Follow）

> **2026-08 迁移说明**：本文 2/3 节记录的网页版通道（`__output=3` 的
> `raw.data` 序号字典 / `script_muti_get_var_store` 包裹）已随「关注功能全面接入
> 官方 APP 签名接口」迁移**移除**，不再降级。现行实现只走官方签名通道
> （POST form + sign，`__lib/__act` 放 URL query，`signParams` 恒为空串）：
>
> - 关注/取关：`nuke.php?__lib=follow_v2&__act=follow`，body `id` + `type`(1/8)，`__output=14`
> - 我的关注：`nuke.php?__lib=follow_v2&__act=get_follow`，body `page`，`__output=12`
> - 我的粉丝：`nuke.php?__lib=follow_v2&__act=get_follow_by`，body `page` + `uid`，`__output=12`
> - 关注动态：`nuke.php?__lib=follow_v2&__act=get_push_list`，body `page`，`__output=12`
>
> 官方通道响应形状（ngabbs.com 实测）：成功 `{code:0,result:[...]}`；follow 写操作
> `{code:0,result:["操作成功"]}`（重复操作服务端幂等）；业务失败 `code!=0 + msg`。
> 关注/粉丝列表的 `result` 为用户数组 `{uid,username,groupid,bit_data,avatar}`（uid 为
> 数字），解析见 `parser/FollowParser.ets`（`parseFollowedUsers`/`extractFollowError`），
> 请求构造见 `service/api/FollowApi.ets`。协议情报完整来源：nga-hack
> `nga-client/docs/cards/3-nuke-user.md`（卡片 9/10）。
>
> 本文其余章节（位掩码废弃结论、生态现状、MNGA 对照、落地建议）仍可作为
> 功能语义与 UI 行为的历史参考。

本文汇总 NGA 关注（关注用户）功能的完整情报，作为 nga_oh 开发关注系统的设计依据与契约。
文中所有接口协议均通过**真实登录账号在 bbs.nga.cn 上抓包实测验证**（关注 → 查列表 → 查动态 → 取消关注全流程闭环），并交叉核对了 NGA 前端源码（`js_commonui.js` / `js_ucp.js`）与 MNGA 参考实现（`bz/enormous-pike` 分支）。

> 本文是开发前的设计与情报文档，不是功能介绍页。文中的"必须"表示与 NGA 服务端协议的硬约束；"建议"表示 nga_oh 内部实现选择。

---

## 1. 关注的效果（语义定义）

在 NGA 网页端，关注一个用户后：

- **关注动态流**（`follow_v2.get_push_list`）：该用户**发布新主题、发布新回复、收藏主题/回复**时，会在你的"关注动态"里生成一条时间线动态（类型 1/2/3），可翻页，点条目可跳转原帖。
- **我关注的用户**（`follow_v2.get_follow`）：管理你关注了谁，可取消关注。
- **用户主页**：被关注用户的资料里显示"已关注/关注"按钮；接口返回 `follow`（当前账号是否已关注该用户）与 `follow_by_num`（该用户被多少人关注）字段。

一句话：**关注 = 订阅 TA 的发帖/回帖/收藏行为，在"关注动态"里聚合呈现**（类似微博关注时间线）。nga_oh 当前已展示 `follow_by_num`（被关注数，见 `ProfilePanel.ets` / `ProfileCardPopup.ets`），但尚无关注操作与动态流。

---

## 2. 接口协议（实测验证）

所有接口基于 `POST https://bbs.nga.cn/nuke.php`，认证靠登录 cookie（`ngaPassportUid` / `ngaPassportCid` / `ngacn0comUserInfo*` 等），与 nga_oh 现有 `ngaClient` 的 `{ uid, cid }` 会话体系兼容。

### 2.1 关注 / 取消关注用户

```
POST /nuke.php?
Body: __lib=follow_v2&__act=follow&id={uid}&type={type}&raw=3
```

| type | 含义 | 实测状态（2026-08 逐位验证） |
| --- | --- | --- |
| `1` | 关注用户 | ✅ **唯一真实有效的关注位**：关注列表、被关注数、动态流全链路生效 |
| `8` | 取消关注用户 | ✅ 有效 |
| `2` / `4` | 关注主题 / 关注回复 | ⚠️ **假成功**：返回"操作成功"但不产生任何可见状态（重复发送无"已关注"幂等提示，`get_follow`/`get_push_list` 均无变化） |
| `16` / `32` | 取消关注主题 / 取消关注回复 | ❌ **参数错误**（服务端未实现） |
| `64` / `128` | 关注 / 取消关注"用户的回复" | ❌ **参数错误**（服务端未实现） |
| `256` | 移除粉丝（un_follow_fans） | ✅ **有效**（第三方关注脚本在使用；官方网页端无入口） |

实测响应（关注与取消关注均返回）：

```json
{"data":{"0":"操作成功"},"time":1786814599}
```

已关注状态下重复发 `type=1`，服务端拒绝：

```json
{"error":{"0":"你已经关注这个用户了"}}
```

> ⚠️ 上述「重复发 type=1 被拒」与「响应 `{"data":{"0":"操作成功"}}`」均为**网页版通道**（`raw=3`）实测行为。**官方 APP 签名通道**（现行通道，见头部迁移说明）对重复操作**幂等**返回 `{code:0,result:["操作成功"]}`（2026-08 实测：重复取消同样返回成功），错误形态为 `code!=0 + msg`。

> **位掩码废弃结论（重要）**：`js_commonui.js` 中的位掩码注释（`1fo用户 2fo主题 4fo回复 ... 128取消fo用户的回复`）是**历史设计文档**，但服务端 `follow_v2.follow` **只实现了 `1`/`8`/`256`**：
>
> - `2`/`4`：服务端宽容的静默忽略（接受请求、返回成功、什么都不做）；
> - `16`/`32`/`64`/`128`：直接"参数错误"，从未上线；
> - 网页端全站 JS 也只有 `1`/`8` 两处调用点（ucp 用户主页按钮），与实测一致。
>
> **本系统只使用 `1`/`8`**，与服务器真实能力完全吻合；不要实现 `2`/`4`/`16`/`32`/`64`/`128`（做了也是假成功）。`256`（移除粉丝）可作为粉丝列表的扩展操作（官方无入口、第三方脚本在用，服务端有效）。

### 2.2 我关注的用户（get_follow）

```
POST /nuke.php?__lib=follow_v2&__act=get_follow&page={page}
Body: __output=3
```

实测响应（关注了 uid=41417929 之后）：

```json
{
  "data": {
    "0": {
      "0": {
        "uid": "41417929",
        "username": "BugenZhao",
        "groupid": -1,
        "bit_data": 135537153,
        "avatar": "https://img.nga.178.com/avatars/2002/cc9/77f/002/41417929_0.jpg?57"
      }
    }
  },
  "time": 1786814599
}
```

- `data[0]`：关注列表，元素为「序号 → 用户对象」，字段至少含 `uid` / `username` / `groupid` / `bit_data` / `avatar`。
- 无关注时返回 `{"data":{"0":{}}}`（空对象，非数组）。
- 分页：`page` 从 1 开始，未观测到返回总页数字段；建议按"当前页非空即请求下一页"策略分页（与 MNGA `PagingDataSource` 行为一致）。

### 2.3 关注动态（get_push_list）—— 关注效果的核心落点

```
POST /nuke.php?__lib=follow_v2&__act=get_push_list&page={page}
Body: __output=3
```

响应四段结构：

```json
{
  "data": {
    "0": 活动列表,   // 核心
    "1": 用户表,     // key = uid
    "2": 最大页数,
    "3": 当前页数,
    "4": 主题表      // key = tid
  },
  "time": 服务器时间戳
}
```

**`data[0]` 每条活动的字段（数组下标，源自 `js_ucp.js` 解析代码注释，与实测一致）：**

| 下标 | 含义 | 说明 |
| --- | --- | --- |
| `v[0]` | 动态 ID | 本条动态唯一标识 |
| `v[1]` | 活动类型 | `1`=关注用户发新主题，`2`=关注用户发回复，`3`=关注用户收藏了主题/回复 |
| `v[2]` | 行为者 uid | 类型 1/2 为发帖者，类型 3 为收藏者 |
| `v[3]` | `tid` | 涉及的帖子 |
| `v[4]` | `pid` | `0` 表示动态主体是主题；非 0 表示是某条回复 |
| `v[5]` | 回复对象 / 被收藏帖作者 | 类型 2 为"这条回复回复的 pid"；类型 3 为被收藏帖的作者 uid |
| `v[6]` | 时间戳 | unix 秒 |
| `v[7]` | 收藏表 ID | 仅类型 3 有意义 |
| `summary` | 摘要文本 | 服务端生成的 UBB 可读描述（可选） |

**`data[1]` 用户表：** `uid → { uid, username, groupid, memberid, medal, reputation, postnum, money, thisvisit, bit_data, ... }`

**`data[4]` 主题表：** `tid → { tid, fid, author, authorid, subject, postdate, lastpost, lastposter, replies, content, tpcurl, parent{版块}, ... }`

**空数据实测形态（关注对象近期无动态时）：**

```json
{"data":{"0":{},"1":"","2":"","3":"","4":""},"time":1786814599}
```

> 注意：`data[1]`/`data[4]` 空时为**空字符串 `""`** 而非空对象，解析必须容错（`""`、`{}`、`null`、缺字段四种形态都要处理）。

**网页端渲染逻辑（对齐语义）：** 每条动态 = `users[uid].username` + `发布/收藏了` + (`回复`/`主题`) + `topics[tid].subject`，点击跳 `read.php?tid=xxx`（回复另加 `&pid=xxx&opt=128` 定位楼层）。

### 2.4 用户资料中的关注状态（ucp get）

现有 `UserApi.getUserProfile` 已调用 `ucp.get` 并解析 `follow_by_num`（见 `UserApi.ets` 第 210 行）。补充确认的字段：

- `follow: 1` —— **当前登录用户是否已关注该用户**，**条件返回**：已关注时才存在（值为 1），未关注时字段完全缺席（不是 0）。
- `follow_by_num: 18` —— 该用户被多少人关注（nga_oh 已解析为 `ProfileData.followByNum`）。

### 2.5 粉丝列表（get_follow_by）

```
POST /nuke.php?__lib=follow_v2&__act=get_follow_by&page={page}[&uid={uid}]
Body: __output=3
```

- **不带 `uid`**：查当前登录账号自己的粉丝；**带 `uid`**：查任意用户的粉丝（实测 uid=41417929 返回 18 条，与 ucp 的 `follow_by_num: 18` 完全一致）。
- 响应结构与 `get_follow` 完全同构：`data[0]` 为「序号 → 用户对象」（`uid/username/groupid/bit_data/avatar`），解析可直接复用 `parseFollowedUsers`。
- 无粉丝时返回 `{"data":{"0":{}}}`；分页策略同 `get_follow`（无总页数字段，按"当前页非空即下一页"）。
- 生态：网页端 `commonui.myfollow.get_follow_by` 是空函数（未实现 UI），但服务端有效——第三方脚本 `nga_follow_support.user.js` 正在使用（`follow_by_list(page)` 调用同款接口），nga_oh `fetchFollowers` 的 `uid` 可选参数即对应本节的 `&uid=` 形态（实测通过）。

### 2.6 请求硬约束

| 约束 | 说明 |
| --- | --- |
| **必须 POST** | `get_follow` / `get_push_list` 用 GET 会返回 `{"error":{"0":"请求错误"}}`（实测踩坑）；网页端实际走表单 iframe POST。`follow` 动作本身也是 POST。 |
| 参数位置 | `__lib`/`__act`/`page` 在 URL query，`__output`/`raw` 在 form body（与 nga_oh `postWithQueryAndBody` 天然对应）。 |
| 输出格式 | `__output=3`（JSON，`script_muti_get_var_store` 包装）；NGA 另有 `lite=xml` 变体（MNGA 用它），nga_oh 统一用 JSON。 |
| 编码 | 响应 `charset=GBK`。nga_oh 的 `ngaClient` 对 JSON 已做解码处理（与现有接口一致），若直接透传原始字节需按 GBK 解码，中文用户名/标题才有意义。 |
| 认证 | 需登录态；未登录返回"未登录"错误。 |

---

## 3. 网页端已知缺陷与生态现状（开发时规避，可做得比官方更好）

### 3.1 网页端已知缺陷

1. **状态字段名 bug**：`js_ucp.js` 渲染按钮判断 `_U.followed`，但接口实际返回字段名是 `follow` → 已关注后按钮仍显示"关注"，再点发 `type=1` 被拒"你已经关注这个用户了"。nga_oh 必须读 `follow` 字段（或 `follow === 1`）。
2. **`myfollow.unfollow` 是空函数**（仅 `console.log`）→ 网页端"我关注的用户"列表的 [取消关注] 按钮实际无效。nga_oh 直接调 `type=8` 即可正确取消。
3. **`myfollow.get_follow_by`（谁关注了我）是空函数** → 网页端未实现"粉丝列表" UI。

### 3.2 生态现状：官方客户端是关注功能的主阵地

- **网页端原生关注 UI 长期残缺**：第三方油猴脚本 [NGA Follow Support](https://greasyfork.org/zh-CN/scripts/422270-nga-follow-support)（v1.3.5）自我描述即"**同步客户端关注功能**"——把官方 App 的关注按钮复刻注入网页端 ucp 用户信息区，并补全关注列表 / 粉丝列表 / 关注动态三个管理面板（调用 `get_follow` / `get_follow_by` / `get_push_list`，与 nga_oh 实现一致）。
- 脚本作者记录的环境恶化史：NGA 2022-03-18 调整帖子数据接口（返回数据一定几率截断）、2024-03-29 调整用户信息接口（登录态短时 >5 次请求返回 503）——第三方生态持续受压，但 `follow_v2` 关注接口仍稳定可用。
- 脚本源码已下载存档：`C:\Users\ll\AppData\Local\Temp\nga-js\nga_follow_support.user.js`（其 `follow=type 1`、`un_follow=type 8`、`un_follow_fans=type 256`、三个列表接口的调用可作参考）。

> 启示：nga_oh 的关注实现（1/8 + 动态 + 关注/粉丝列表）与官方客户端能力及第三方脚本行为一致，是"官方同款"而非边缘能力；`type=256`（移除粉丝）是官方网页端缺失、但服务端有效的能力，可作粉丝列表的差异化功能。

---

## 4. MNGA 参考实现对照

MNGA 的 `bz/enormous-pike` 分支（未合并 main）已实现"关注动态"只读页，是现成参考：

| MNGA 实现 | 说明 | nga_oh 对应建议 |
| --- | --- | --- |
| `logic/service/src/activity.rs` | Rust 解析 `get_push_list`（`lite=xml` 变体），XPath `/root/data/item[1]`=活动、`item[2]`=users、`item[5]`=topics（1-based 与 JSON 0-based 对应：JSON `data[0]`=XML `item[1]`，`data[4]`=`item[5]`） | nga_oh 用 JSON 解析，下标按 2.3 节 |
| `protos/DataModel.proto` `Activity` | `id / type / actor / topic / post_id / timestamp / summary`；`Activity_Type`：`POST_TOPIC=1 / POST_REPLY=2 / FAVOR=3` | 模型字段见 5.2 节 |
| `FollowedActivityListView` / `RowView` | 动态列表：主题标题 + 行为者 + 类型描述 + 时间；`pid==0` 跳主题详情，否则定位楼层 | 见 5.4 节 |
| 入口：UserMenuView → Followed Activity（Plus 付费功能） | MNGA 将动态页设为付费功能 | nga_oh 可先免费开放 |
| `docs/nga-follow_v2-get_push_list.md` | MNGA 的接口逆向笔记 | 已并入本文 2.3 节并实测校正 |

MNGA 分支**没有**实现"关注/取消关注"操作接口（只有只读动态页）；操作接口协议来自本文 2.1 节的网页端实测。

---

## 5. nga_oh 落地设计建议

### 5.1 API 层（新增 `entry/src/main/ets/service/api/FollowApi.ets`）

对齐现有风格（`FavoriteApi.ets` / `UserApi.ets`：`ApiResult` 子类 + `sessionRegistry.getSession` + `parseNgaError` + `logger.warn`）：

```typescript
// 关注 / 取消关注用户
// POST /nuke.php?  body: __lib=follow_v2&__act=follow&id={uid}&type={1|8}&raw=3
export async function followUser(token: string, uid: string, follow: boolean): Promise<ApiResult>

// 我关注的用户（分页）
// POST /nuke.php?__lib=follow_v2&__act=get_follow&page={page}  body: __output=3
export async function fetchFollowedUsers(token: string, page: number): Promise<FollowedUserListResult>

// 关注动态（分页）
// POST /nuke.php?__lib=follow_v2&__act=get_push_list&page={page}  body: __output=3
export async function fetchFollowedActivity(token: string, page: number): Promise<FollowedActivityListResult>
```

请求构造要点：

- `followUser`：`ngaClient.post('/nuke.php', { '__lib': 'follow_v2', '__act': 'follow', 'id': uid, 'type': follow ? '1' : '8', 'raw': '3' }, { uid, cid })`；成功后若本端缓存了该用户资料（`ProfileStore`），同步更新 `follow` 字段。
- 两个列表：`ngaClient.postWithQueryAndBody('/nuke.php', { '__lib': 'follow_v2', '__act': 'get_follow' | 'get_push_list', 'page': String(page) }, { '__output': '3' }, { uid, cid })`。**禁止改成 GET**（见 2.5 节）。
- 错误：`parseNgaError(raw)` 已能解析 `{"error":{"0":"..."}}` 形态（"你已经关注这个用户了"等直接透出）。

### 5.2 模型（`model/NgaApiResults.ets` 或新建 `model/Follow.ets`）

```typescript
export class FollowedUser {
  uid: string = '';
  username: string = '';
  avatarUrl: string = '';
  // groupid / bit_data 可视需要保留
}

export class FollowedActivity {
  id: string = '';          // v[0]
  type: number = 0;         // v[1]：1 发主题 / 2 发回复 / 3 收藏
  actorUid: string = '';    // v[2]
  tid: string = '';         // v[3]
  pid: string = '';         // v[4]，'0' 表示主题
  timestamp: number = 0;    // v[6]，unix 秒
  summary: string = '';
  // 展示期补充（来自 data[1] / data[4]）：
  actorName: string = '';
  subject: string = '';
  fid: string = '';
}
```

Result 类：`FollowedUserListResult extends ApiResult { data: FollowedUser[] }`、`FollowedActivityListResult extends ApiResult { data: FollowedActivity[]; pages: number }`（`pages` 取 `data[2]`，注意空数据时为 `""`，需 `Number()` 兜底）。

### 5.3 解析要点

- `data[0]` 空/缺省：`{}`、`""`、`null`、缺字段都要视为空列表，**不能抛异常**（实测空数据形态见 2.3 节）。
- `data[0]` 是「序号字符串 → 活动数组」的映射（`"0": [v0, v1, ...]`），按**数组下标**取值，不要按对象 key。
- `data[1]` / `data[4]` 是 `uid/tid → 对象`，解析 `data[0]` 时先建 map 再回填 `actorName` / `subject`；缺失时展示兜底（uid/tid 原文或空）。
- 时间用现有 `formatTime` / `formatTimestampCST`（`common/utils/Utils.ts`）。
- 类型 3（收藏）的展示文案：`收藏了`；1/2：`发布了主题/回复`。

### 5.4 UI 建议

| 位置 | 内容 |
| --- | --- |
| 用户资料页 `ProfilePanel.ets` / 用户卡片 `ProfileCardPopup.ets` | 在"被关注"行附近加"关注 / 已关注"按钮（读 `profile.follow`，**不是** `followed`）；点击调 `followUser` 后本地翻转状态 + 乐观更新，失败回滚并 toast 错误（"你已经关注这个用户了"等） |
| 新页面 `FollowedActivityPanel.ets`（列表页） | 展示动态流：`[类型图标] 主题标题` / `行为者 + 发布/收藏了 主题/回复` / 时间；点击：`pid==0` 进主题详情，否则定位楼层（参考现有 `ThreadPanel` 的定位能力）；分页复用现有 `PagingDataSource` 类似物（关注动态用 `data[2]` 总页数或"非空即下一页"） |
| 入口 | 「我的」页/菜单加"关注动态"入口；被关注用户资料页按钮即关注入口 |
| 匿名用户 | `uid` 为空或匿名（`#anony_`）用户不显示关注按钮（NGA 网页端同样隐藏） |

### 5.5 测试建议

- 解析单测（`entry/src/test/`）：用 2.2 / 2.3 节的实测响应 JSON 做 fixtures，覆盖：正常列表、空 `{}`、空 `""`、缺 `data[1]`/`data[4]`、类型 1/2/3、`summary` 含 UBB 转义字符。
- 接口冒烟（需真实账号）：关注 → `get_follow` 出现该用户 → `get_push_list` 出现动态（若有）→ 取消关注 → `get_follow` 消失；重复关注断言"你已经关注这个用户了"。

---

## 6. 风险与边界

- **协议无官方文档**：字段以本文实测与 NGA 前端源码为准；上游改动可能导致结构变化，解析层需集中、容错（5.3 节）。
- **位掩码废弃（已实测定论）**：`follow_v2.follow` 只实现 `1`/`8`/`256`；`2`/`4` 假成功、`16`/`32`/`64`/`128` 参数错误。切勿基于 `js_commonui.js` 注释实现未实测的位。
- **分页上限**：`get_follow` / `get_follow_by` 未观测到总页数字段；`get_push_list` 的 `data[2]` 在空数据时为 `""`。均按容错处理。
- **关注数上限**：未实测；若服务端有上限，错误信息会经 `parseNgaError` 透出，UI 直接展示即可。
- **请求频率**：关注/取关属写操作，UI 需防重复提交（按钮禁用至响应返回）；第三方脚本亦观察到 NGA 对用户信息接口的限流（短时 >5 次 → 503），列表分页请求不宜过密。
- **被关注通知**：网页端关注他人是否给对方发提醒未验证，与 nga_oh 无关，不做。

---

## 7. 附录：实测抓包原文与参考文件

**抓包样例**（存于侦察会话临时目录 `C:\Users\ll\AppData\Local\Temp\nga-js\`）：

- `follow_request.network-request`：`__lib=follow_v2&__act=follow&id=41417929&type=1&raw=3` → 响应 `{"data":{"0":"操作成功"}}`
- `get_follow_request/response`：`POST nuke.php?__lib=follow_v2&__act=get_follow&page=1`，body `__output=3`
- `nga_follow_support.user.js`：第三方油猴脚本 [NGA Follow Support](https://greasyfork.org/zh-CN/scripts/422270-nga-follow-support) v1.3.5 完整源码（`follow=type 1` / `un_follow=type 8` / `un_follow_fans=type 256` 及三个列表接口调用）
- NGA 前端源码（GBK）：`js_commonui.js`（`commonui.follow`，type 位掩码注释）、`js_ucp.js`（`commonui.myfollow` 模块与活动字段注释）、`js_mainMenu.js`

**nga_oh 现状相关文件**：

| 文件 | 与本系统的关系 |
| --- | --- |
| `entry/src/main/ets/service/api/UserApi.ets` | 已解析 `follow_by_num`；`getUserProfile` 可补充解析 `follow` 字段 |
| `entry/src/main/ets/model/User.ets` | `ProfileData.followByNum` 已存在，需加 `follow` |
| `entry/src/main/ets/store/ProfileStore.ets` | 用户资料缓存；关注操作成功后需失效/更新 |
| `entry/src/main/ets/pages/ProfilePanel.ets`、`common/components/ProfileCardPopup.ets` | 关注按钮挂载点（现有"被关注"展示行附近） |
| `entry/src/main/ets/service/api/FavoriteApi.ets` | `postWithQueryAndBody` 用法范本（与 get_follow/get_push_list 同构） |
| `entry/src/main/ets/service/NgaClient.ets` | `INgaClient` 接口：`post` / `postWithQueryAndBody` / `postWithQuery` |

**MNGA 参考（外部仓库 `C:\Users\ll\Desktop\MNGA`）**：

- 分支 `origin/bz/enormous-pike`：`logic/service/src/activity.rs`、`app/Shared/Views/FollowedActivityListView.swift`、`docs/nga-follow_v2-get_push_list.md`

---

## 8. 关注动态缓存、红点与通知页迁移（nga_oh 落地补充）

本节记录关注动态从"打开才拉取的独立页"升级为"轮询 + 条件抓取 + 缓存 + 红点，并入通知页双筛选"的落地设计（2026-02 实施，编译门禁通过）。

### 8.1 数据层：FollowActivityStore（对齐 NotificationStore）

| 机制 | 参数 | 说明 |
| --- | --- | --- |
| 定时抓取 | 前台 60s 轮询（`ACTIVITY_POLL_INTERVAL`） | 与通知轮询同启同停（`AppStore.reconcileNotificationPolling`） |
| 条件抓取 | 非强制刷新 30s 最小成功间隔（`ACTIVITY_REFRESH_DELAY`） | `refreshActivities(force)` 并发复用同一 Promise |
| 持久化缓存 | 信封 `FollowActivityCacheEnvelope`（schemaVersion=2 / uid / items / updatedAt） | PreferencesStore 按 `cached_activities_{uid}` 隔离；**仅为 `displayActivities` 前 200 条窗口快照** |
| 内存真源 | `displayActivities`（上限 10000） | 首屏缓存 + 分页追加的全量列表；排序 timestamp 倒序 + **id 稳定第二键**（同秒条目不抖动） |
| 分页状态 | `loadedPages` / `totalPages` / `loadingMore` 收进 Store | 首屏=1；`totalPages`=0 表示未知/未确认 |
| 红点 | `unreadActivityCount` → AppStorage | 入口角标/徽章消费 |
| 版本信号 | `activityVersion` | 仅数据合并/分页追加时 bump，驱动列表增量刷新 |

**方案 C 数据流**（2026-02 实施，分页死锁/空洞修复）：

- `displayActivities` 是内存唯一真源，生命周期：`init`/`loadCachedActivities` 时以缓存窗口为起点（无分页）→ 轮询/首屏 `performRefresh`（page=1）用 `mergeActivities` 合并（新 id 未读、旧 id 保留 seen、去重、10000 截断）→ `loadMoreActivities` 用 `appendDedupe` 按分页顺序尾部追加（不重排）；
- `cachedActivities` 恒为 `displayActivities.slice(0, 200)`：每次成功的刷新/分页/已读操作都同步窗口并落盘（字段回填/截断也持久化，内存与磁盘一致）；
- 版本信号分工：**数据合并或分页追加 bump `activityVersion`**（面板增量同步：头部新增 `prependAll`、分页尾部追加 `appendAll`、其余 `replaceAll`，均按 id 序列比较，避免 LazyForEach 整体重建打断滚动）；**已读变化只更新未读数不 bump**（入口红点即时归零，列表行内 `updateAt` 局部刷新）；
- `loadMoreActivities`：store 内并发防护（`loadingMore`）+ 总页数边界 + 账号代际校验（`generationGuard`/uid/token 三重，与 `isRequestCurrent` 一致），失败静默返回 false，滚动到底部可再次触发；
- 已读操作（`markSeenByIds`/`markAllSeen`）作用于 `displayActivities`，面板快照元素与真源同引用，`updateAt` 无条件发局部刷新信号。

已读语义（服务端 get_push_list 无未读字段，全部本地判定）：

- 本地无记录的动态 id 一律视为**未读**（首次拉取的历史动态同样未读，红点/圆点如实反映「尚未点开」状态）；
- **已读规则与消息一致**：点开动态对应的帖子即标记该条已读（`markActivitySeen`）；右上角「全部已读」作用于**当前选中 Tab 的系统**（消息 tab = 通知中心全部已读；动态 tab = 动态全部已读）；
- 版本信号分工：**数据合并 bump `activityVersion`**（面板增量同步，无新数据不重建列表，避免打断滚动）；**已读变化只更新未读数不 bump**（入口红点即时归零，列表行内 `updateAt` 局部刷新）。

分页：分页状态与行为全部收进 Store（`loadMoreActivities`），后续页仅内存持有（`appendDedupe` 尾部追加进 `displayActivities`），不进缓存；持久化缓存恒为 `displayActivities` 前 200 条窗口。

### 8.2 UI 层：通知页双筛选

- `NotificationPanel` 升级为「通知」页：`PanelNavBar`（返回 + 标题"通知"）+ 原生 `SegmentButton` 筛选项（消息/动态）作为**列表首元素**，随内容滚动穿越标题区（`contentStartOffset` + `linearGradientBlur` + `scrollEffectProgress`，与帖子 UI 排序条同范式）；
- **消息 tab**：通知中心数据（回复/私信/点赞提醒），沿用点击已读 / 全部已读规则；
- **动态 tab**：关注动态流，动态行样式 = 未读圆点 + 类型图标（发主题/回帖/收藏）+ 两行布局（标题+时间 / **行为者·动作**），对齐通知中心行形态；
- 路由：`Screen.notifications(initialTab)`（0=消息 1=动态）；`FollowedActivityPanel` 与 `Screen.followedActivity` 移除；通知页仅由帖子 UI 铃铛进入；
- 入口红点：帖子 UI 铃铛角标 = 通知未读 + 动态未读（合并）；我的主页入口调整：删除「通知」「关注动态」行，「我的关注」提升至「我的回帖」之下（2026-02 用户决策）。
