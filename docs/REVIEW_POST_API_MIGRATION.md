# 代码审查报告：NGA APP 官方 API 发帖/回帖/贴条/修改/引用/上传迁移

> 审查日期：2026-08-22（按工作区文件时间戳）
> 审查对象：`git diff HEAD` 未提交改动，8 个文件（ThreadWriteApi / NgaClient / CodecUtils / ReplyManager / NewTopicManager / ThreadResult / NgaUploader / ThreadPanel）
> 审查方式：纯静态（git diff + grep + 官方 jadx 源码对照），零线上 HTTP 请求；独立执行 `hvigorw assembleHap --rerun` 验证编译
> 协议权威：`C:\Users\ll\Desktop\nga-hack\nga-client\docs\cards\8-post-write.md`（v7.17.17 静态逆向）
> 官方源码：`C:\Users\ll\Desktop\nga-hack\jadx-out\sources\`（NetRequestWrapper / ArticleRepository / NetRequest / ActionCheck / ct.e / ct.k / NetProviderImpl / kt.c）

---

## 1. 总评

**结论：有条件通过（Conditional Pass）。**

迁移方向正确、协议对齐度高：主提交通道（`__output="" + __inchst=""` + `__ngaClientChecksum`）、签名串规则（new=`fid+subject+content`、reply/quote/tietiao/modify=`tid+content`）、post/check 五参数恒传与 output 分流、quote 服务端生成引用块、上传 multipart 字段与 boundary/响应解析，均与官方 v7.17.17 源码逐条一致（详见第 3 节核对表）。死代码清理（`get/post/postWithQuery` 及 GBK 发帖链）无残留引用，`postWithQueryAndBody` 正确保留。独立强制重编译 `BUILD SUCCESSFUL`，且 ArkTS 产物（`modules.abc` 23:15:30）晚于全部被审查源码（最新 23:15:10），证明当前工作区状态可编译。

未发现「严重（必须修复）」级协议错误，但有 **2 个「一般（建议修复）」级风险**需在合入前实测确认/修复，以及若干提示级差异：

1. **发新帖成功响应拿不到新帖 tid → 无法自动跳转**（output='' 通道 result 为字符串时）；
2. **简化回复通道（无 checksum）与「缺 checksum → code 15」实测结论的矛盾风险**——官方 comment 通道本身无 checksum 且活跃，需实测普通主题回复走简化通道是否触发 15。

放行条件：上述 G1/G2 经线上实测确认（或按建议修复）；其余提示项可择机处理。

---

## 2. 问题清单（按严重度）

### 严重（必须修复）

**无。** 经逐条对照官方源码，未发现会导致主链路（发帖/回帖/贴条/修改/引用/上传）失败的确定性协议错误。

### 一般（建议修复）

**G1. 发新帖成功后 `tid=0`，无法自动跳转新帖详情**
- 文件/位置：`entry/src/main/ets/service/api/ThreadWriteApi.ets` `submitPost`（L266-268）与 `postNewTopic`（L470-471，fallbackTid=0）；`entry/src/main/ets/pages/TopicListPanel.ets` L375（`result.tid > 0` 才跳转）
- 问题描述：output='' 通道实测成功响应为 `{"code":0,"msg":"操作成功","result":"发贴完毕 ..."}`，`result` 为**字符串**。`readPostPayload` 对非对象 result 回退到 `raw`，`payload['tid']` 取不到 → `postNewTopic` 的 `fallbackTid=0` 生效 → `result.tid=0` → 发帖成功但无法跳转新帖（回复场景有 `lastRepliedPid` 兜底，新帖无兜底）。旧 post.php 通道（`data.tid`）无此问题，属迁移引入的功能降级。
- 依据：用户提供的实测响应形态（B1）；`ThreadWriteApi.ets` L267 兜底链；`TopicListPanel.ets` L375 跳转门槛
- 建议：① 实测 new 场景下 output='' 通道是否在响应字符串/对象中携带新帖 tid；② 若字符串含 tid（如「发贴完毕」后跟 tid），在 `submitPost` 对 `action==='new'` 时从响应文本提取（正则 `/tid[=:](\d+)/`）；③ 或在 `TopicListPanel` 发帖成功且 tid=0 时改为「刷新列表定位新帖」兜底。

**G2. 简化回复通道（`submitSimpleReply` 无 checksum）与「缺 checksum → code 15」矛盾，需实测**
- 文件/位置：`entry/src/main/ets/service/api/ThreadWriteApi.ets` `submitSimpleReply`（L286-318，`includeClientChecksum=false`）；分流条件 L437-440
- 问题描述：普通主题回复（reply + pid<=0 + 不匿名 + 无附件）走无 checksum 的简化通道；而审查清单背景结论 2 为「`__ngaClientChecksum` 缺失时服务端返回 code 15（找不到帖子）」。若该结论在 output='' 通道同样成立，则**最常见的主题回复将全部失败**。但官方 `ArticleRepository.comment` 通道（同 URL、同 `__output=""`、同 `action=reply`）经 `NetProviderImpl.makeCommonParam` 确认**不注入 checksum** 且为活跃通道，两者矛盾。
- 依据：`ArticleRepository.java` `comment$lambda$4`（tid/content/action/__output=""/__inchst=""，无 checksum）；`NetProviderImpl.makeCommonParam`（只注入 app_id/access_uid/access_token/t/sign）；文档 §2.4「无 __ngaClientChecksum（官方即如此）」
- 建议：线上实测一次普通主题回复（走简化通道）确认是否 code 15；若触发，将 `includeClientChecksum` 改为 true（L0/K0 均带 checksum，服务端应容忍多余字段），或让主题回复统一走 `submitPost`。

**G3. 上传 `mvimg` 恒为 `"1"`，与官方条件传值不一致**
- 文件/位置：`entry/src/main/ets/service/api/NgaUploader.ets` L95
- 问题描述：官方 `ct.k.i()` / `UploadPublishFileTask` 中 `mvimg` 仅「有原图/动图（motionPhoto）」时为 `"1"`，普通单图为空；鸿蒙恒 `'1'`。可能影响服务端对图片类型/缩略图处理。
- 依据：`ct/k.java`（`r9.put("mvimg", r0)`，r0 条件值）；文档 §4.1 表、§6 #11（⚠️ 已标注）
- 建议：条件传值（当前调用方仅传图片二进制，无动图信息时传 `""`），或维持恒 `'1'` 但确认线上单图上传正常。

**G4. `attachments`/`attachments_check` 缺官方尾随 `\t`**
- 文件/位置：`entry/src/main/ets/service/api/ThreadWriteApi.ets` `buildPostFields`（L222-223，透传调用方值）；`entry/src/main/ets/common/managers/ReplyManager.ets` L299-305、`NewTopicManager.ets` L151-157（`'\t'` 元素间连接）
- 问题描述：官方 L0 构造为「每个非空元素后追加 `\t`」（`sb4.append(str12); sb4.append("\t")`，最终串**含尾 `\t`**）；鸿蒙为元素间 `\t`、无尾。服务端按 `\t` split 时两者等效，但严格对齐建议补尾。
- 依据：`NetRequestWrapper.java` L0 中 attachments/attachments_check 拼接（文档 §2.1/§4.4）
- 建议：可选——累积逻辑改为「元素后各加 `\t`」并去空值过滤，与官方逐字对齐。

### 提示（可选）

**P1. quote 预览与提交内容不一致（产品可接受，但格式有细微出入）**
- 位置：`ReplyManager.ets` `buildContent`（L203-208）与 `sendReply`（L350）；`ReplyDialog.ets` L506 预览
- 说明：预览展示客户端自构 `[quote][pid=..,..,page]...[/quote]`（`buildQuotePrefix`），提交仅发送用户输入，服务端按 pid 生成引用块。官方服务端格式为 `[quote][pid=..,..,1]Reply[/pid] <b>Post by ...</b><br/><br/>原文[/quote]`（`<br/><br/>` 分隔、无 postDate），客户端预览为 `\n` 分隔、含 `({postDate})`、Post by 前有空格——两者视觉近似但不逐字一致。文档 §3.3 已确认「客户端不构造块」的协议正确性，此处仅为预览近似度提示。
- 依据：文档 §3.3

**P2. `emojiToHtmlEntity` 仅转代理对（>0xFFFF），官方 `encodeEmoji` 转全部 emoji 码点**
- 位置：`CodecUtils.ets` L68-86（未改动，本次接入 `normalizePostContent`）；`ThreadWriteApi.ets` L88-91
- 说明：官方按码点扫描，BMP 内 emoji（☺ U+263A、❤ U+2764 等）也转 `&#N;`；鸿蒙只处理 surrogate pair。差异在 UTF-8 通道（output=''）下无实质损害：BMP emoji 直接 UTF-8 编码可正常落库，且实体（8 字节）反而比 UTF-8 码元（3 字节）更占 153 字节预算。仅当服务端对「原始 emoji 字符」有特殊策略（如长度/过滤）时才有差异。
- 依据：文档 §3.1（官方 encodeEmoji 逐码点）

**P3. 文件名 URL 编码 `*`/`~` 与 Java `URLEncoder` 不同**
- 位置：`NgaUploader.ets` L84（`encodeURIComponent(...).replace(/%20/g, '+')`）
- 说明：Java URLEncoder 保留 `*`、编码 `~`→`%7E`；encodeURIComponent 编码 `*`→`%2A`、保留 `~`。服务端 `URLDecoder.decode` 还原后文件名一致（%XX 与字面均还原），实际等效；文档 §6 #12 已标注 ⚠️。
- 建议：如需逐字对齐可自行实现 URLEncoder 等价编码；多数场景（无空格/`*`/`~` 文件名）无影响。

**P4. 上传成功但响应缺 url/attachment/attach_url 时插入无效 `[img]./.medium.jpg[/img]`**
- 位置：`ThreadWriteApi.ets` `uploadAttachment`（L534-543）
- 说明：若响应仅含 `attachments`/`attachments_check` 而无 `url`/`attachment`/`attach_url`，`result.url` 为空串但 `result.ok=true`，`ReplyManager.uploadImage` 返回空 url，编辑器插入 `[img]./.medium.jpg[/img]` 无效标签。属边缘容错（官方响应一般含 url），建议 url 为空时视为失败。

**P5. 并发上传累积竞态（既有代码，非本次引入）**
- 位置：`ReplyManager.ets` `uploadImage`（L281-307）、`NewTopicManager.ets` `uploadImage`（L135-159）
- 说明：两次 `uploadImage` 并发（快速连选两张图）时，`pendingAttachments` 读-改-写无互斥，可能丢失一个附件参数。UI 层通常串行，风险低。

**P6. 主题回复走 comment 通道（无 fid），依赖服务端宽容**
- 位置：`ThreadWriteApi.ets` L437-440 分流
- 说明：普通主题回复（简化通道）不携带 fid，与官方 L0/K0（带 fid）不同，行为一致性依赖服务端对「reply 无 fid」的接受（用户实测「output='' 中文正常落库」背书）。匿名/带 pid/带附件回复走 `submitPost` 全字段，无此问题。

**P7. follow_push / newvote 系列参数未实现**
- 位置：`buildPostFields`（L209-230）
- 说明：官方 L0 在动态发布（isPublishDynamic）时加 `follow_push=1`、投票时加 `newvote` 系列；鸿蒙无动态/投票发布场景，不携带为合理裁剪，非缺失。

**P8. `readAppError` 对 `code` 缺失时的 `parseNgaError` 回退**
- 位置：`ThreadWriteApi.ets` L54-65
- 说明：ngaRequest 对 HTML 错误页返回 `{error:{'0':...}}` 结构，`readAppError` 无 code 字段时经 `parseNgaError` 提取，`__parseError` 时回退 fallback——错误透出链路合理，与 HTTP 非 200（ngaRequest 不显式检查 status，但 HTML/解析失败路径均能透出）配合无盲区。✅

---

## 3. 与 8-post-write.md 逐项一致性核对表（A1–A6）

| 项 | 审查点 | 鸿蒙实现 | 官方依据 | 结论 |
|---|---|---|---|---|
| **A1** | `submitPost` 通道语义 | `postSigned('/app_api.php','post',action,fields,…,signParams,'',true,'')`：output=''、inchst=''、`includeClientChecksum=true` | comment 通道显式 `__output=""`/`__inchst=""`（ArticleRepository.comment$lambda$4）；L0/K0 带 checksum；`buildEncodedBody` 对空串编码为 `__output=&__inchst=`（空值=无字段，用户实测等效） | ✅ 一致（checksum 取 L0 语义、output/inchst 取 comment 语义的组合通道，实测中文落库） |
| **A2** | signParams 规则 | postNewTopic=`fid+subject+normalizedContent`（L471）；postReply=`tid+normalizedContent`（L446）；postComment=`tid+normalizedContent`（L495）；均用 normalize 后内容 | L0：modify→`v0(tid,content)`、new→`v0(fid,subject,content)`、reply/quote/tietiao→`v0(tid,content)`，content 为 sb3 最终值 | ✅ 一致（subject 参与 new；signParams 用处理后 content，与官方同） |
| **A3** | getPostAuth | 五参数恒传（fid/stid/tid/pid/action 空值传空串，L379-385）；output new→'14' 其余→'12'（L392）；signParams=action；无 checksum | `kt.c.F0` 五参数 + `.a(action)` + `build()`=14；`ArticleRepository.getPost` 五参数 + `addSignParams(action)` + `buildNew()`=12 | ✅ 一致（'12' 对齐详情页 repository 通道，文档 §6 #9 已认可） |
| **A4** | buildPostFields 参数集 | fid/tid/pid/stid/action/content/anony/live/mention/attachments/attachments_check；tietiao 移除 subject/address；anony='0'/'1'；mention 正则 `\[@(.*?)\]` gi + `\t` 连接 + 尾 `\t` | L0：同参数集 + `hashMap.remove("subject")`/`remove("address")`（tietiao）；anony `z10?"1":"0"`；`o(replaceAll)` 同正则含尾 `\t` | ✅ 一致（attachments 尾 `\t` 差异见 G4；follow_push/newvote 裁剪见 P7） |
| **A5** | uploadAttachment/NgaUploader | 字段 v2/attachment_file1_watermark/_dscp/_url_utf8_name/fid/func=upload/_img=1/lite=js/auth/mvimg；boundary `-----------------------------7db1c5232222b`；Content-Type/Accept-Charset/Cookie；文件名 `encodeURIComponent().replace(/%20/g,'+')`；响应 JSON 优先 + JS 字面量提取（error_code/attachments/attachments_check/url） | `ct.e.q` 确认 boundary/Content-Type/Accept-Charset/UTF-8 解码；`ct.k.i()` 确认字段集与 `URLEncoder.encode(名,"utf-8")`；`UploadPublishFileTask.addToArray` 用 `attachments:'`/`attachments_check:'` 标记；`ct.k.a()`/`getErrorMsg` 用 `error_code:` split；错误码表 1-13 | ✅ 一致（mvimg 恒 '1' 差异见 G3；`*`/`~` 编码差异见 P3；官方错误码提取为 split 而鸿蒙为正则，更宽容，兼容） |
| **A6** | logout | `nuke.php?__lib=login&__act=logout&__output=1` GET，skipInchst=true（不注入 __inchst），无签名 | 官方 pswitch_683（文档权威）；登录系接口无 access_uid/access_token/t/sign（makeCommonParam 仅对签名接口） | ✅ 一致（旧 `__lib=logout` 为错误映射，本次修正；`__output=1` 网页 JSON 标志符合登录系惯例） |

---

## 4. 审查清单逐项结论（B/C/D）

### B. 逻辑正确性与边界

- **B1（readAppError/readPostPayload 对 result 字符串响应）**：✅ 正确。`asRecord` 用 `typeof==='object'` 排除字符串 result → 回退 raw → `payload['tid']` 缺失时兜底 fallbackTid/''。回复场景 fallbackTid=tid、pid='' 由 `lastRepliedPid` 兜底；**新帖场景 fallbackTid=0 见 G1**。
- **B2（parseAttachArrayValue）**：✅ 正确。覆盖 JSON 数组串（官方 ActionCheck.attachArray 为 String，Gson 序列化）、直接数组、空串、非 JSON 单值透传；`Array.isArray` 在项目 58 处使用，ArkTS 合规（编译通过背书）。JSON.parse 成功但结果非数组（对象）时落入 `return ''` 丢值，属可接受的边缘（官方形态为数组串）。
- **B3（编辑附件回填）**：✅ 正确。时序分析：startEdit 清空 cachedAuth/pendingAttachments → 首次 getOrFetchAuth（无论来自 uploadImage 还是 send）回填旧附件（守卫 `pendingAttachments.length===0` 成立）→ 上传成功后在旧附件基础上累积（`'\t'` 追加）。不存在「pendingAttachments 非空而 cachedAuth 失效」的 EDIT 状态（两者只在 startEdit/reset 同时清空），守卫无覆盖用户新附件的窗口。上传失败抛异常时累积不执行，回填结果保留，正确。
- **B4（quote 官方化）**：✅ 成立。官方 `checkPrePost` 不构造 `[quote]` 块（文档 §3.3）；服务端按 pid 生成。`sendReply` 提交 userText（不拼 quotePrefix）、FLOOR 模式 action='quote'、pid=targetPost.pid。shouldQuote 路径允许空内容提交（ReplyDialog L220/L582），符合官方「content 通常为空」语义。预览/提交不一致见 P1。
- **B5（submitSimpleReply 分流）**：✅ 参数形态与官方 comment 完全一致（tid/content/action=reply，无 fid、无 checksum，output=''/inchst=''，signParams=tid+content）；分流条件（reply+pid<=0+anony=0+无附件）合理，匿名/带 pid/带附件走 submitPost 全字段（含 fid/checksum/anony）。**checksum 矛盾风险见 G2**。
- **B6（NgaClient 死代码清理）**：✅ 确认。`ngaClient.get/post/postWithQuery` 及 `ngaGet/ngaPost/ngaPostWithQuery` 无任何调用方（grep 全库 0 命中）；`postWithQueryAndBody` 仍被 `ForumApi.ets` L337（setSubforumFilter）使用，正确保留；`ngaRequest` 的 skipInchst/utf8Response/baseUrl 分支均仍被使用（ngaPostSignedCore、logout、loginPassword）；logout 传 skipInchst=true 使 query 不含 `__inchst`（官方登录系接口无此参数），参数正确。
- **B7（CodecUtils）**：✅ 确认。`buildEncodedBody` 单参化后仅 NgaClient L259/L341/L410 三处调用（L341 覆盖 ngaPostSignedCore 两条路径），全部单参；`emojiToHtmlEntity` 仍被 ThreadWriteApi（normalizePostContent）使用，正确保留；`gbkPercentEncode` 删除后全库无引用。
- **B8（ThreadPanel 乐观更新与 pid 兜底）**：✅ 一致。编辑提交 content 为 `\n`（用户输入原样，服务端存储 `\n` 渲染转 `<br/>`），乐观更新 `text.replace(/\n/g,'<br/>')` 与服务端渲染形态一致；`lastRepliedPid` 仅 THREAD/FLOOR 静默刷新追加时记录（EDIT/COMMENT 不污染，L1617 注释明确）；`goToRepliedPost` 解析链 candidate→lastRepliedPid→末页兜底，覆盖 output='' 响应无 pid 场景（L1705-1712）。

### C. ArkTS 语法与工程质量

- **C1（ArkTS 合规）**：✅ 通过。独立 `hvigorw assembleHap --rerun` BUILD SUCCESSFUL；产物时间戳（modules.abc 23:15:30）晚于全部被审查源码（最新 NgaClient.ets 23:15:10），证明当前工作区状态真实编译通过。关键语法点：`Record<string,Object>` 索引访问与赋值（AGENTS.md 允许，`rec[index]` 类型为 `V|undefined`）、`Array.isArray` 收窄、`as Record` 收窄、`??` 链、`RegExp.exec` 循环、catch 无类型标注——均合规（编译器为最终门禁）。
- **C2（未使用项/注释/魔法数）**：✅。ThreadWriteApi 全部导入使用（parseNgaError→readAppError、logger→uploadAttachment、emojiToHtmlEntity→normalizePostContent）；注释与实现相符（output 分流注释、comment 通道注释、checksum 注释、attachArray 注释均与实际一致）；魔法数 '14'/'12'/'1010'/boundary 均为官方常量且带注释。
- **C3（错误路径）**：✅ 合理。提交层：服务端 code!=0 → msg（无 msg 时 fallback+错误码）；网络异常/超时 → `readThrownError` 透出 message；ngaRequest 不显式检查 HTTP status，但 HTML 错误页（msginfo 提取）与 JSON 解析失败（`__parseError`→fallback）均能透出可读错误。上传层：HTTP 非 200 显式 reject、error_code!=0 → error 字段/错误码文案、缺附件字段 → 「上传响应缺少附件字段」。

### D. 死代码与残留

- **D1**：✅ ThreadWriteApi 无未使用函数/导入；所有导出（getPostAuth/postReply/postNewTopic/postComment/uploadAttachment）均被 ReplyManager/NewTopicManager 使用。
- **D2**：✅ 全局无 post.php 发帖通道残留——grep `/post.php` 与 `__output: '8'` 发帖相关仅命中注释（ThreadWriteApi L253 解释性注释、CodecUtils L91、ForumApi L329 为子版块筛选 `__output='8'` 的**非发帖**接口、FollowApi/FavoriteApi/FavoriteParser/MuteParser 的迁移说明注释）。
- **D3**：✅ NgaClient 清理后无指向已删函数的注释——顶部工具函数注释已更新（移除 gbkPercentEncode）；`buildSignedFields`/`ngaPostSigned` 的 JSDoc 已补充 inchst/includeClientChecksum 参数；INgaClient 接口定义与实现同步删除 get/post/postWithQuery。

---

## 5. 验证过的编译/引用结论

| 验证项 | 方法 | 结果 |
|---|---|---|
| ArkTS 编译 | `hvigorw assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon --rerun`（DevEco 工具链） | `BUILD SUCCESSFUL`；`entry/build/default/intermediates/loader_out/default/ets/modules.abc` 时间戳 23:15:30 > 全部源码最新 23:15:10 → 当前改动已真实编译 |
| `ngaClient.get/post/postWithQuery` 无调用方 | grep 全库 | 0 命中（死代码删除正确） |
| `postWithQueryAndBody` 保留 | grep | ForumApi.ets L337 使用（子版块筛选） |
| `buildEncodedBody` 调用方 | grep | NgaClient L259/L341/L410，全部单参 |
| `gbkPercentEncode` 无残留 | grep | 仅 CodecUtils L91 注释提及 |
| post.php 发帖残留 | grep `/post.php`、`__output: '8'` | 仅注释；ForumApi 的 `__output='8'` 为子版块筛选非发帖 |
| 官方 comment 无 checksum | ArticleRepository.java `comment$lambda$4` + NetProviderImpl.makeCommonParam | 确认只注入 app_id/access_uid/access_token/t/sign |
| 官方 post/check 五参数+signParams=action | kt.c.F0、ArticleRepository.getPost | 确认 |
| L0 signParams 规则 | NetRequestWrapper.L0 尾部 v0 调用 | 确认 new/reply/quote/tietiao/modify 规则 |
| 官方 multipart 字段/boundary | ct.e.java、ct.k.java、UploadPublishFileTask.java | boundary `-----------------------------7db1c5232222b`、Accept-Charset utf-8、UTF-8 解码、字段集、error_code split 解析均确认 |
| NetRequest build/buildNew | NetRequest.java | build()=14、buildNew()=12、显式 setOutput 覆盖 |

---

## 6. 附：审查范围外观察（供参考）

- `ReplyDialog.doSend` 以 `this.replyText.trim()` 提交（L231），官方新版 L0 不 trim（`getText().toString()`）、旧版 K0 trim——鸿蒙取 trim 语义，属可接受差异（与 K0 一致）。
- `getPostAuth` 对 tietiao 用 output='12'（对齐详情页 getPost 通道）；官方旧版贴条 check 走 volley 无 output——无 content 提交，12/14/无均无 153 风险，可接受。
- `NgaUploader` 未手工设 Content-Length（官方 `ct.e.q` 手工计算）：鸿蒙 http 库对 ArrayBuffer extraData 自动按实际字节填充，等效安全。

---

## 7. 追加记录（2026-09-20）：间歇性「附件确认错误，请回报管理员」

> 现象来源：用户在**没有插入任何附件**的回复上，间歇性收到服务端提示「附件确认错误，请回报管理员」。
> 结论：本报告第 2 节的审查**漏掉了「非 EDIT 入口的会话状态清理」这一维度**（B3 只分析了 EDIT 场景）。

### 7.1 取证：文案来自服务端，两条通路都能产生它

- 该文案**不在 APK 里**。协议核对方对 `apktool-out` 的 11 个 dex + `resources.arsc` + assets + lib
  做了字节级扫描：「附件确认」**零命中**；含「回报管理员」的串只有 3 条，全部是 `ct/k.java`
  的上传错误码文案（error_code 4/10/11）。→ 该提示由**服务端下发**。
- 因此有两条通路都能让用户看到它：
  1. **上传通路**：`ThreadWriteApi.fillUploadResult` 在 `error_code != 0` 时**优先显示服务端
     返回的 `error` 字段**——"照抄服务端文案"这条显示通路是鸿蒙独有的（官方 `ct/k.java`
     只按 error_code 映射自己的文案，从不显示服务端文本）。上传被拒的结果，正是用户描述的
     「这次回复没有添加附件」+「附件确认错误」。
  2. **提交通路**：`post` 返回的 `msg`（`readAppError` → toast），即请求里带了服务端不认的
     附件码。
- 两条通路的上游是**同一个缺陷家族**：`replyManager` 是进程级单例，它持有的鉴权缓存与
  附件参数缺少会话边界。
- 需要留一句诚实的话：**「服务端为何拒」这一环静态不可证**，本文的因果链是从"文案只可能来自
  服务端"+"客户端状态确实跨会话存活"两条硬事实推出来的；7.5 给了真机判别器。

### 7.2 根因：单例上的会话状态跨编辑器存活

`replyManager`（`ReplyManager.ets` 末尾 `export const replyManager = new ReplyManagerClass()`）
是进程级单例；修复前它的 `cachedAuth` / `cachedAuthAction` / `pendingAttachments` /
`pendingAttachmentsCheck` **只在 `startEdit()` 与 `reset()` 里清空**，而 `reset()` 全库零调用方
（`ThreadPanel` / `TopicListPanel` 里的 `this.mgr.reset()` 属于 `ThreadPaginationManager`），
`startThreadReply()` / `startFloorReply()` / `startComment()` 三个入口**一个都不清**。两个后果：

- **上传被拒（通路 1）**：`cachedAuth` 只按 action 区分，跨帖复用同一 action 时会拿
  **A 帖的 `auth` / `attach_url`** 去为 B 帖上传（`uploadAttachment` 传的是
  `authResult.auth` + `this.ctx.fid`）→ 服务端校验目标不符 → 上传报错、图片插不进来。
  这条正好对应"回复没有添加附件"的字面现象。
- **提交带脏参数（通路 2）**：上一次会话累积的附件码残留在单例上，被后续"没插图的回复"
  一并提交——`ThreadWriteApi.postReply` 的简化通道分流要求两个附件串**同时**为空，
  只要有一个残留，请求就会切到带 `attachments` 的完整 `post` 通道。

次生问题：`getOrFetchAuth` 的缓存只按 action 失效，跨帖不失效；`pendingAttachments` 是
两个 tab 拼接串，无法核对"正文里到底还引用着哪几张图"。

### 7.3 官方对照（jadx 逐条取证）

| 项 | 官方 v7.17.17 | 鸿蒙端（修复前） |
|---|---|---|
| 附件参数载体 | `PostFragment.mAttachArray` / `mAttachCheckArray` 是 **Fragment 实例 List**（`PostFragment.java:36-37`）；新 UI 为 `PublishParams` 实例 List | 进程级单例上的两个 `string` |
| 会话身份 | `ActionCheck.buildActionId = uid + "/" + fid + "/" + tid + "/" + pid`（`ActionCheck.java:478-496`），`makeActionCheck` 写入 `currentUid` | 无 |
| 每次开编辑器 | `PostActivity.newIntent` → 每次 `new PostFragment()`，`onActivityCreated` 重新取 `ActionCheck`（`PostActivity.java:119,180`；`PostFragment.java:784,795-810`） | 同 action 复用 `cachedAuth` |
| 上传完成 | **成对 `remove(旧码)` + `add(新码)`**（`PostFragment.java:461-470`，替换语义） | 只成对 append（鸿蒙无重传同一张图的入口，影响小） |
| 删图 / 删附件 | 成对 `remove` + 从正文摘掉 `[img]`/`[flash]` 标签（`PostFragment.java:1043-1061`）；无本地文件时走服务端 `del_attach` | 无删图入口，正文删标签也不回收 |
| tietiao 的附件 | **带**（只 `remove("subject")` / `remove("address")`，`NetRequestWrapper.java:1113-1121` / `1221-1225`） | `postComment` 硬编码 `'', ''`，且贴条模式下图片按钮仍可用 |
| 提交拼接 | 两个 List **同一个循环**、各自跳过空元素后 `\t` 连接（`NetRequestWrapper.java:1186-1209`） | 一致（含尾 `\t`） |
| 客户端配对校验 | **没有**：`PublishActivityPresenter.addAttachArray` 两个 `add` 共用同一个"非空"条件，`attachmentsCheck` 为 null 时塞空串 → 官方自身就能发出两串数量不等的请求 | 初版修复加了硬闸（见 7.4 的"已删除"） |
| 草稿 | 附件码入 `ActionCheck`（`@DatabaseField`，`ActionCheck.java:85-91`）并在**恢复草稿时重新上传本地图片**（`PostHelper.java:1530-1559`） | 草稿只存正文文本 |
| 提交成功后 | 不清 List，靠 `finishResult()` 销毁页面 + `deleteDraft()` + `isSend` 互斥 | 需要单例自己清（本次补） |

`NewTopicManager.start()` 在这一点上**本来就是对的**（`TopicListPanel.openNewTopic()` 每次都调，
清 `cachedAuth` 与附件），回复链路缺的正是这一步；uid 进会话键也与官方 `buildActionId` 同构。

### 7.4 修复（含两轮独立审查后的修正）

两个编辑器（`ReplyDialog.ets` / `NewTopicDialog.ets`）本身不持有附件状态，它们只调各自
manager 的 `uploadImage` / `send`；两条链路是**两个独立 manager**。

**新增共享模块 `entry/src/main/ets/common/managers/PostAttachments.ets`**
（两条链路共用，避免同一套逻辑抄两份）：

- `PendingAttachment`：`attachment` / `check` / `url` **三元组**。多出的 `url` 是为了在提交前
  核对"正文里是否真的还引用着这张图"——官方靠 List 与正文标签成对维护来保证一致，
  鸿蒙端正文是自由文本框，只能在提交时反查。
- `appendPendingAttachment`（累积）、`restoreServerAttachments`（编辑回填，`url` 留空）、
  `buildAttachmentParams`（按 `content.indexOf(url)` 过滤后拼串，`url` 为空的项一律保留）、
  `splitNonEmpty`。

**`ReplyManager.ets`（回复 / 引用 / 贴条 / 编辑）**

1. 新增 `beginSession(action)` / `clearSession()`，四个 `start*` 入口统一调用：会话目标
   `action|uid|fid|tid|pid` 变化即作废 `cachedAuth` + 附件（uid 进键与官方
   `ActionCheck.buildActionId` 同构；登出只走 `appStore.clearAuth()`，碰不到本单例，
   不含 uid 时"换账号后在同一个帖子回复"会被判为同一会话）。**`modify` 每次进入都作废**
   （官方每次进编辑器都重新取 `ActionCheck` 回填）。初版在同一目标内**保留**凭证，是为了让
   「上传图片 → 放弃 → 重开同一回复框」时草稿里的图片仍能绑定。
   —— 这是本次线上问题的**主修**。
   > **2026-09-20 收紧**：那条"同目标保留"的例外**已删除**，`beginSession` 现在无条件作废
   > 凭证（对齐官方"每次进编辑器重新 check"）。原例外的作用已由草稿媒体副本 + 提交前懒重传
   > 取代，方案见 [`docs/research/DRAFT_MEDIA_PLAN.md`](research/DRAFT_MEDIA_PLAN.md)。
2. 附件累积改三元组；提交前按正文引用过滤（`collectAttachmentParams`），未被正文引用的
   附件码不再随请求发出。
3. 提交**成功后**立即丢弃附件（单例必须自己等价官方的 `finishResult()`）。
4. 日志：`[REPLY] submit type=… pending=…`、`[REPLY] reply|modify|tietiao attachments kept=…`、
   未被引用项丢弃时另有 `dropped`。

**`NewTopicManager.ets`（发新主题）**：改用同一共享模块（`start()` 原本就每次清空），
补上"成功后丢弃"与 `[NEWTOPIC]` 日志。

**`ThreadWriteApi.ets`**

5. `postComment` 增加 `attachments` / `attachmentsCheck` 参数：官方 `tietiao` 是带附件的
   （只去掉 `subject`/`address`），鸿蒙原先硬编码 `'', ''` 会让"贴条模式里传的图"变成
   正文有 `[img]`、参数为空——**这是审查发现的既有协议偏差，与本次 bug 同源**。
6. `parseAttachArrayValue` 的非 JSON 分支补尾 `\t`：该串后续还会被追加（编辑时再传图），
   缺尾 `\t` 会让两个元素粘连成一个（`"a1\ta2"` + `"a3\t"` → `"a1\ta2a3\t"`）。

**审查后删除的三处初版改动**（都属"鸿蒙有而官方没有"的多余行为，且方向有害）：

| 初版改动 | 为什么删 |
|---|---|
| "重新 check 拿到不同 `auth` 即作废附件码" | 提交请求**根本不含 `auth` 字段**（`buildPostFields` 的字段集里没有），服务端无从按 auth 校验附件码，这条推断没有依据；唯一触发路径是编辑器内切换"回复/贴条"（换 action 即换 auth），结果是**把正文里已经插好的图片附件码清掉**——一处真实回归（正文有 `[img]`、`attachments` 为空） |
| 提交前"两侧元素个数必须相等"的硬闸 | 官方 `L0` 对两个参数是**各自**跳过空元素拼接的（长度允许不等），官方自身就能发出数量不等的请求；"数量不等即拒"无静态依据。且该闸只返错不清状态，一旦 EDIT 回填到半对状态就会**永久锁死**该楼层（重开对话框还会回填同一坏状态） |
| 上传响应缺 `attachments_check` 即 `throw` | 同一理由（官方语义允许半对）；抛出会让"这种响应形态下所有插图都发不出去"，比原来的间歇性报错更重 |

### 7.5 验证

- 编译：`hvigorw assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon`
  → `BUILD SUCCESSFUL`。
- 真机复现/回归路径（修复前应报错、修复后应正常）：
  1. 在任意帖回复并插入一张图，发送成功 → 立刻**再回复一次纯文字**；
  2. 在帖子 A 上传图片但**放弃**（草稿保存）→ 到帖子 B 回复纯文字；
  3. 打开某带附件楼层的「编辑」→ 放弃 → 在任意帖回复纯文字；
  4. **回复模式传图 → 切贴条 → 再传一张 → 切回回复 → 发送**（初版回归的复现路径，现应正常）；
  5. 贴条模式下传图 → 发贴条（现在附件会随贴条提交，与官方一致）。
- **日志判别器**（这是本次唯一能在真机分清"错误到底来自哪条通路"的手段）：
  - `[REPLY] submit type=… pending=N`：纯文字回复若打出 `N>0`，说明状态又被污染。
  - `[REPLY] reply|modify|tietiao attachments kept=M` / `[NEWTOPIC] submit … keepAttachments=M`：
    本次真正发出的附件项数。
  - **F1（证伪残留假说）** 冷启动后、本进程从未上传过附件的**第一次**回复若仍报该错 ⇒
    "进程级残留"不成立。
  - **F2（转移通路）** 修复后仍偶发该错、且 `pending=0` ⇒ 错**不来自 `post` 提交**。
    此时对齐同一时刻的 `[NGA][UPLOAD] raw: …`（`uploadAttachment` 的 verbose 日志）：
    上传通路是鸿蒙唯一会**原样显示服务端 `error` 文案**的地方，最该优先排除。
  - **F3（支持残留假说）** 报错总是紧跟在"上一次会话刚传过图 / 刚编辑过带附件楼层"之后出现。

### 7.6 遗留观察

- **官方有、鸿蒙仍缺**（都不是本次 bug 的成因，但同属附件链路，按价值排序）：
  1. ~~**草稿持久化附件**：官方把 `attachArray`/`attachCheckArray` 写进 `ActionCheck` 库表，
     恢复草稿时对每张有本地路径的图**重新上传**（`PostHelper.java:1530-1559`）；鸿蒙草稿只存
     正文文本 → 草稿里的 `[img]` 跨会话（或跨目标）必然失去附件绑定。要补得先把附件三元组
     按 `(uid, fid, tid, pid, action)` 持久化（键可直接用官方 `buildActionId` 的形态）。~~
     **✅ 已实现（2026-09-20）**，方案与实施记录见
     [`docs/research/DRAFT_MEDIA_PLAN.md`](research/DRAFT_MEDIA_PLAN.md)（阶段 1–4 全部完成，
     逐阶段编译通过）：草稿落 `filesDir/drafts/<key>.json`（键含 uid 短哈希），媒体副本落
     `filesDir/draft_media/<key>/`，提交前对"正文仍引用、但本会话已无凭证"的项用副本懒重传
     并替换正文标签。**连带效果**：7.4 那条"同一目标内保留凭证"的例外已删除
     （`beginSession` 现在**无条件**作废凭证），也就是把下面第 3 条的窗口一起关掉了。
     > **四角度审查修复（2026-09-21）**：首版实现跑了四轮独立审查（正确性/竞态、数据生命周期、
     > 协议一致性、体验/工程质量），命中 30+ 条问题、其中 8 条高危，已全部修复（A 组 8 条 +
     > B 组 12 条 + C 组清理 8 项）。其中会改变**可观察行为**的三条，引用本节其它结论时要一并注意：
     > ① 「放弃编辑」确认框的主按钮不再是"删草稿"，而是"关掉编辑器、草稿保留"（与文案一致）；
     > ② 草稿键改为**按目标划分、不含模式**（回复/贴条共用 `draft_<tid>_p<pid>_<uid>`），
     > 因此 7.5 那条"回复模式传图 → 切贴条 → 切回回复 → 发送"的回归现在**不会**再产生两个键
     > 或孤儿媒体目录；③ 媒体副本改为**孤儿即时回收 + 有主一律豁免**，容量淘汰不再动活跃草稿。
     > 逐条清单与状态见该文档 §9。
  2. **删图 / 删附件**：官方成对 `remove` + 从正文摘标签 + 需要时调 `del_attach`；鸿蒙没有
     删图入口，用户只能在正文里手删 `[img]`——那种情况下附件码现在会被 7.4 的正文过滤丢掉
     （不再随请求发出），但服务端那份临时附件仍留在上传区，直到被服务端清理。
  3. ~~**每次开编辑器重新 check**：官方 `PostActivity.newIntent` 每次都 `new PostFragment` 并取
     新的 `ActionCheck`；鸿蒙在"同一会话目标"内仍复用 `cachedAuth`。若 `post/check` 的 `auth`
     在服务端有有效期，这条复用就是超期上传的窗口（官方对此免疫）。~~
     **✅ 已收紧（2026-09-20）**：`ReplyManager.beginSession` 与 `NewTopicManager.start` 现在
     每次都作废 `cachedAuth` + 附件参数，等价官方"每次进编辑器重新取 `ActionCheck`"。
     原先保留复用是为了迁就"草稿图片没副本"，该前提已由草稿媒体副本 + 懒重传取代。
  4. 提交中互斥：官方有 `isSend` 防重复提交；鸿蒙靠 `ReplyDialog.sending` / `NewTopicDialog.sending`
     的按钮态兜住，语义接近（重传阶段另有 `uploadingImage` 作二次闸门）。重传在途时关面板的
     两条缝也已补上：保稿条件把 `uploadingImage` 计入（不再走 `clearDraft`），
     `doSend` 在 `await` 之后补 `disposed` 检查（销毁后不再提交）——见
     [`docs/research/DRAFT_MEDIA_PLAN.md`](research/DRAFT_MEDIA_PLAN.md) §9.2 / §9.9。
- **口径差异（有意保留）**：官方 `onActivityCreated` 回填 `attachArray` **不限 action**
  （`PostFragment.java:832-837`）；鸿蒙只在 `EDIT` 回填。保守一侧更安全（reply/quote 的 check
  若意外回传附件，鸿蒙不会把帖子已有附件塞进新回复），但严格说与官方不等价。
- 本报告 G4 所述的「尾随 `\t` 差异」现在**只剩一处历史例外**：`parseAttachArrayValue` 的非
  JSON 分支原本直接 `return text`（无尾 `\t`），本次补成"补尾 `\t`"；`appendPendingAttachment`
  与 `buildAttachmentParams` 均按官方 L0「每个非空元素后追加 `\t`」拼接。
- `startComment()` 全库无调用方（COMMENT 只能从 `toggleMode()` 进入），`reset()` 也仍无调用方
  ——两者留着是为了语义完整，不是活代码。
- 横向排查：全工程 7 个模块级单例（`appStore` / `routerStore` / `floatingLayerStore` /
  `logoutOrchestrator` / `ngaThrottler` / `replyManager` / `newTopicManager`）中，
  **只有后两个持有服务端签发的临时凭证**（`auth` / `attach_url` / `attachments` /
  `attachments_check`）；上传接口的调用方也只有这两个 manager，没有旁路。
- 仍属**未验证假设**的一条：服务端拒绝附件的具体规则（数量不等？会话绑定？正文引用？）。
  APK 里没有该文案，静态不可证；7.5 的 F1–F3 是把它落到真机上的最小实验，**不需要任何
  额外的线上请求**。

---

## 8. 追加记录（2026-09）：编辑自己的主题时「标题过短 / 帖子不存在」

> 现象来源：用户报告**编辑自己以前发的主帖**（不是回复）时，提示「标题过短…」或
> 「帖子不存在」。
> 结论：**编辑（modify）提交丢掉了帖子标题**——官方协议要求 modify 携带 `subject`
> （逐行证据见 8.1 第 1、2 条），而鸿蒙端把它硬编码为空串。已修复。
> 因果边界要说清：**「带标题」是协议事实；「空标题正是那两句报错的原因」是推断**，
> 逐字复现需要一次写提交（本报告不做），只能由 8.4 的真机回归确认。
> 与帖子是否真的存在、账号是否有权限无关——这两点在只读实测中都已被单独复现并排除
> （8.1 第 4、5 条）。本次记录的是**第四个**同族缺陷
> （前三个：会话状态跨编辑器存活 §7、贴条丢附件 §7.4、尾随 `\t` §2 G4）。

### 8.1 取证（全部只读，零写操作）

1. **官方 APK：modify 必带 subject**。`NetRequestWrapper.java` 的 L0/K0 只在 **tietiao**
   分支 `hashMap.remove(ft.k.X)`（X=`subject`：L0 `:1223`、K0 `:1119`，都在与
   `POST_TIETIAO` 同一个 else 分支内）；**modify 分支不删**（L0 `:1210-1212`、
   K0 `:1105-1107`），且 L0 在 `:1159` 无条件 `put(ft.k.X, str6)`。
   → 官方**所有非贴条提交都携带标题**，modify 在内。
2. **服务端：modify 鉴权响应回传标题**。只读实测（命令见 8.5）：
   `post/check`（`action=modify`，output=12）响应 `result` 含 `subject`（本主题原标题）、
   `content`（编辑回显正文）、`auth`、`attach_url`、`__F`、`force_titletype` 等。
   官方 `ActionCheck.java:54-56` 正是 `@SerializedName(ft.k.X) String subject`。
3. **官方编辑页闭环（独立审查复核后补齐的关键一段）**：编辑主帖的真实链路是
   `ArticleDetailFragment.doPostCheck`（`:1081-1095`，`actionCheck.fromDraft(...)`）→
   `PostActivity.newIntent` → **`PostFragment`（K0 通道）** →
   - `PostFragment.java:537-540`：`if (!d1.k(actionCheck.getSubject())) binding.j.setText(...)`
     ——把服务端 `subject` 回填进标题框（`binding.j`）；
   - `PostFragment.java:634` 取标题框文本 → `:690 K0(subject, content, mActionCheck, …)` →
     `NetRequestWrapper.java:1054 hashMap.put(ft.k.X, subject)`。
   → 官方把"服务端给的标题"原样带回。**注意卡片 §2.2 把 K0/`PostFragment` 标为「旧版」是误导**：
   它正是编辑主帖在用的通道（L0 那条是 `PublishActivity` 新版发帖页）。
   同一个 if 里还有一条对本次判断很重要的边界：`PostFragment.java:548-556` 的 modify 分支在
   `subject` 为空时**隐藏标题框、照样提交空串** —— 说明官方预期并接受"服务端没给标题"这种形态，
   空 `subject` 至少对**非首帖**不致命。
4. **鸿蒙端丢掉了它**。`getPostAuth` 只解析 `content`（`ThreadWriteApi.ets` 的
   `result.content = payload['content']`），不解析 `subject`；
   编辑提交 `ReplyManager.sendEdit` → `postReply(..., 'modify', pid, '')`
   第 11 个参数（`postSubject`）**硬编码空串**。即：服务端把标题送回来，客户端当面丢掉，
   再提交一个空标题回去。
5. **签名不受影响（本次改动正确性的一条硬证据）**：官方 modify 的 signParams 是
   `v0(hashMap, tid, content)` = `tid + content`，**不含 subject**（L0 `:1210-1212`）；
   只有 `new` 是 `fid + subject + content`（`:1215`）。鸿蒙端 `postReply` 的
   `String(tid) + normalizedContent` 因此无需改动。
6. **「帖子不存在」与「标题过短」的文案出处**：两句都**不在鸿蒙端**（全项目 grep 无此文案，
   只出现在本次新增的注释里），只能来自服务端 `msg`（`ThreadWriteApi.ets:54-65` 的
   `readAppError` 原样透出）。「帖子不存在」的触发已实测定位：服务端 `code=15` →
   `msg="找不到帖子"`（`post/check(action=modify)` 带不存在的 pid 时返回的正是它，见 8.5）。
   项目内另有一处相近文案（`SaveThreadDialogs.ets` 的「帖子不存在或已被删除」，离线存档校验用），
   与本次报错不是同一处。
7. **顺带核实「首帖 pid」不是嫌疑项**（曾被列为疑似根因，已排除）：
   - 服务端 `post/check(action=modify)` 用 `pid=0` 才返回 `code=0` + 原标题；
     用非 0 pid 时按"改某楼层"判定，实测得到 `code=54 只有作者或版主可以修改内容`。
   - 帖子 HTML（APP `read.php __output=17`）里首帖的锚点就是
     **`<a id='pid0Anchor'>` / `<a name='l0'>`**（同页其它楼层是 `pid<真实pid>Anchor` / `l1…`），
     即**首帖的 pid 在服务端表示法里就是 0**；解析侧 `PostArgScanner.ts:134` 取
     `commonui.postArg.proc` 的第 [10] 参作为 pid，样本中 `lou=0` 一律 `pid=0`。
   - 鸿蒙端编辑提交的 pid 取自 `targetPost.pid`（`ThreadPanel.ets:2045` →
     `replyManager.startEdit(p, …)`），与官方 `Edit.pid` 同源，首帖因此同为 `0`。
   → **pid 一致，不是本次故障的成因**；排除它之后，差别只剩 `subject`。

> 因果边界（**必须与上面的协议事实分开读**）：
> - **已证实**：官方 modify 携带 `subject`，且它来自服务端 check 回传的标题（第 1–3、5 条）。
> - **未证实**：服务端在提交阶段"因为 subject 为空"而回「标题过短」。第 3 条末尾那条边界
>   （官方对无 subject 的 modify 照常提交）说明这句话不能推而广之；逐字复现需要一次
>   `post` 写提交，本报告按约束不做，交给 8.4 的真机回归。
> - 另一条与 subject 无关、同样会报 `code=15`「找不到帖子」的可能：提交缺
>   `__ngaClientChecksum`（见 `ThreadWriteApi.ets:256` 的注释）。鸿蒙端主提交一直带该字段
>   （`includeClientChecksum=true`），故本次不列为嫌疑，但排查时值得一并核对。

### 8.2 根因

`modify` 是**唯一**被漏掉标题语义的 action：`postNewTopic` 一直带 subject、
`postComment`（tietiao）本就该去掉 subject，只有编辑提交把 subject 写死为空。
编辑链路另外两处同源缺口：

- 编辑 UI 不回显标题（`ReplyDialog` 编辑模式只填正文），用户既看不到、也无从修正；
- 服务端把标题送回来（check 响应 `subject`）却没人接：`getPostAuth` 只解析了 `content`。

> 顺带记录一个**刻意没采用**的兜底源：本页 `PostInfo.subject` 确实有值（`ThreadParser.ets:107`
> 与 HTML 链路的 `extractPostSubject` 都填，首帖 `pid=0` 时就是主题标题），但官方
> `ActionCheck.fromDraft` 的兜底源是**本地草稿库**里存过的标题，官方从不把"当前页面数据"
> 当作提交标题（`ArticleDetailFragment.java:1098-1114` 只把 address/attachs/video 搬进
> `PostActivity` intent，**不搬 subject**）。用页面数据兜底意味着"服务端这次没给标题"时会拿
> 一个可能陈旧的值（版主改过标题、页面停留很久）去覆盖服务端标题——那是整条链路上唯一
> 可能**改坏服务端数据**的分支，因此第一版实现里的本地兜底在审查后已被移除（见 8.6 A1）。

### 8.3 修复（本次）

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/model/ThreadResult.ets` | `PostAuthResult` 新增 `subject`（post/check 回传的帖子标题，带契约注释） |
| `entry/src/main/ets/service/api/ThreadWriteApi.ets` | `getPostAuth` 解析 `result.subject`（modify 场景） |
| `entry/src/main/ets/common/managers/ReplyManager.ets` | 新增 `editSubject` + `ensureEditSubject()`：`startEdit` 时预取 post/check（与官方"每次进编辑器重新取 `ActionCheck`"同构，顺带把 `attachArray` 回填提前到打开时刻），预取失败按 `warn` 记录；`getOrFetchAuth` 在 EDIT 分支回填标题；`sendEdit` 提交前确保标题就位并把它交给 `postReply`；`beginSession` / `reset` 清空；新增 `sessionGeneration` 会话代数守卫（见 8.6：审查后已收紧到"返回值 + 迟到上传 + 附件登记"三处） |
| `entry/src/main/ets/common/components/ReplyDialog.ets` | 提交成功后按**提交前快照**的草稿键清理（`draftKeySnapshot`） |
| `entry/src/main/ets/service/LogoutOrchestrator.ets` | 登出时补 `replyManager.reset()`（该单例持有服务端签发的临时凭证与会话标题，`appStore.clearAuth()` 碰不到它，见 8.6 A4） |

口径说明：
- **不编造标题**——标题只有一个来源：服务端 check 回传值。没拿到就保持空串
  （与修复前一致，也与官方"modify 无 subject 时隐藏标题框、照样提交"的形态一致），
  绝不拿本地页面数据顶上（理由见 8.2 末段）。
- **也不假装成功**——没拿到标题仍然提交（让服务端给真实结论），但会把原因按 `warn` 记下来
  （见 8.6 A2/A3）。

### 8.4 真机回归（需用户执行，本报告不含任何线上写操作）

| # | 步骤 | 修复前 | 期望 |
|---|---|---|---|
| 1 | 打开自己发的主题 → 首帖「编辑」→ 改一个字 → 保存 | 提示「标题过短…」或「帖子不存在」 | 「编辑成功」+ 楼层正文更新 |
| 2 | 同上但**不改内容**直接保存 | 同上 | 成功（服务端容忍同内容 modify） |
| 3 | 编辑自己的**回复楼层**（非首帖） | 可能已成功 | 仍成功（不回归） |
| 4 | 编辑带图的首帖/回复 | 可能同上 | 附件不丢（`attachArray` 回填提前到打开时刻后更稳） |

判别日志（**warn 级，Release 也可见**）：

- 正常：`[REPLY] modify attachments kept=N`；
- 打开编辑器时：`[REPLY] edit subject prefetch: <原因>`（预取就没拿到标题，提前暴露）；
- 提交时仍未拿到：`[REPLY] modify without subject target=<action|uid|fid|tid|pid> authErr=<原因>`，
  其中 `authErr=server-returned-none` 表示**服务端确实没回传标题**（这时要留档该主题的
  `post/check` 原始响应，命令见 8.5），`编辑器会话已切换` 表示结果被会话代数守卫丢弃，
  其余文案是 check 本身的失败原因。注意提交路径上的"未登录"已被 `send()` 的鉴权门禁
  提前拦下（直接返回给用户），所以这里看到的多半是服务端拒绝或网络异常。

### 8.5 只读诊断命令（后续排查编辑类问题直接复用）

```bash
# 凭证门禁
node tools/nga-data-fetch/bin/nga-fetch.js verify

# modify 鉴权响应（只读；--out 指到临时目录，避免把帖子正文留在仓库里）
node tools/nga-data-fetch/bin/nga-fetch.js app-json app_api.php \
  fid= stid= tid=<tid> pid=<pid> action=modify \
  --output 12 --sign-params modify --query __lib=post --query __act=check --out /tmp/x.json
```

实测结论矩阵（本机凭证、两个本人主题，2026-09）：

| 请求 | 响应 |
|---|---|
| `tid=<本人主题>` `pid=0`（缺 / 空 subject，两种写法） | `code=0`，`result.subject` = 原标题、`result.content` = 编辑回显 |
| `tid=<本人主题>` `pid=<该帖真实楼层 pid>` | `code=54` `msg="只有作者或版主可以修改内容"`（该账号不是这些楼层的作者） |
| `pid=<不存在>`（四种 subject 写法） | `code=15` `msg="找不到帖子"` |
| `tid=<他人主题>` `pid=0` | `code=54` `msg="只有作者或版主可以修改内容"` |
| `tid=<他人主题>` `pid=<其楼层>` | `code=15` `msg="找不到帖子"`（pid 与 tid 不匹配时同样落这里） |

> 注意第 3、5 行：**「找不到帖子」也可能由 pid 与 tid 不匹配触发**，所以排查编辑失败时要
> 同时核对 `pid` 是不是当前主题的楼层 id（编辑提交用的是 `targetPost.pid`，首帖为 `pid=0`）。
>
> 附带观察：**拿不到"非本人楼层"的成功样本**——即 modify 鉴权在"帖子存在但无权"时给出的是
> `code=15` / `code=54`，而不是回传 `subject`。因此 §8.1 第 2 条的 `subject` 回传是在**本人主题**
> 上实测的；「编辑自己的回复楼层（非首帖）是否也回传 subject」尚未取到样本，
> 但本次修复对两种情形都带上标题（服务端给什么回什么，给不出来就保持空串），
> 不依赖该样本成立。
>
> 另一条只读命令（核对首帖 pid 的表示法，见 §8.1 第 5 条）：
> ```bash
> node tools/nga-data-fetch/bin/nga-fetch.js app-json read.php tid=<tid> page=1 --output 17 --out /tmp/t.json
> # 在返回的 html 中检索：首帖锚点是 <a id='pid0Anchor'>、<a name='l0'>
> ```

### 8.6 独立审查发现与二次修复（2026-09）

本节改动经过**两个独立审查 agent**（一个只审官方协议与逻辑正确性，一个只审 ArkTS 工程与
并发安全）复核。协议向结论未被推翻；并发向审查指出**首版 `sessionGeneration` 守卫只做了
一半**——它挡住了"写回状态"，没挡住"把上个会话的结果交回调用方"，以及另外几处 `await`
之后写会话状态的路径。逐条如下（均已修复）：

| # | 问题 | 触发序列（同一进程，`replyManager` 是单例） | 修法 |
|---|---|---|---|
| **S1**（本次引入） | 守卫失配时仍 `return authResult`，调用方拿到**上一个会话的 auth/attach_url** | 打开 A 帖编辑器（check 在途）→ 关面板 → 打开 B 帖编辑器（代数+1、清附件）→ A 的 check 返回 → `uploadImage` 用「A 的 auth + B 的 fid」上传，并把 A 的附件凭证追进 B 的 `pendingAttachments` | 失配即返回**显式失败**结果（`error='编辑器会话已切换，请重试'`），调用方走既有失败分支（上传抛错 / 提交报错） |
| **S2**（既有，本次声明要覆盖却漏了） | `uploadImageWithDraft` / `uploadMovingPhotoWithDraft` 在 `await` 之后才用**当前** `draftKey()` 落副本 | A 帖编辑器中上传图片（在途）→ 关面板 → 打开 B 帖编辑器 → A 的上传成功：A 的图片字节落进 **B 的 `draft_media/`**，幽灵记录 push 进 B 的 `sessionMedia` | 入口快照 `generation` + `draftKey`，`await` 后代数失配即返回（不落副本、不登记）；动态照片**两次落盘后各复查一次**（两半是两次独立 IO）。另在 `uploadImage` 的附件登记前加同一判定（避免 A 的凭证进 B 的 `pendingAttachments`） |
| **S3**（既有） | `reset()` 不自增代数，而它是唯一"整体作废会话"的公开出口；登出链路 `AppStore.clearAuth()` 也不碰 `replyManager` | 将来在登出接上 `reset()`：在途 check 会通过代际校验，把**上个账号/帖子**的标题写回已清空的会话 | `reset()` 末尾 `sessionGeneration++`；并在 `LogoutOrchestrator.logout` 本地清理段补 `replyManager.reset()`（该单例持有服务端临时凭证与会话标题，`clearAuth` 碰不到它） |
| **S4**（既有） | 提交成功后 `clearDraft()` 用**当前**键 | 编辑 A 点保存（在途）→ 关面板 → 打开 B 编辑器 → A 的响应返回：删掉 **B 的**草稿 JSON 与媒体副本目录（B 会话的 `sessionMedia` 仍指向被删文件，提交时撞"本地副本已不存在"） | `clearDraft(key?)` 增加可选键 + 新增只读 `draftKeySnapshot`；`send` 在提交前快照键、成功后按**快照键**清理（且只在清的是当前键时才清空 `sessionMedia`）；`ReplyDialog.doSend` 的成功分支同样改为用提交前快照（`replyManager.send` 内部虽已清理，这一处是幽灵发送路径下的第二道，必须用同一个键） |
| **A1**（协议向，**最实质**） | 第一版实现给标题加了"本地兜底"：check 没回传就用本页 `PostInfo.subject` | 服务端某次没回传 `subject` + 本页有值（首帖恒有）→ 提交一个**可能陈旧**的标题（版主改过标题、页面停留很久），服务端据此落库 → 标题被改回旧值 | **移除本地兜底**：标题只认服务端 check 回传值，没拿到就空串。依据：官方 `ActionCheck.fromDraft` 的兜底源是**本地草稿库**而非页面数据，`ArticleDetailFragment.java:1098-1114` 也从不把 post 的 subject 搬进发帖 intent。这是整条链路上唯一能改坏服务端数据的分支，宁可不兜 |
| **A2**（协议向） | 兜底分支把 `out.error` 清成 `''`，于是"取标题失败"的告警因为 `title` 被兜底填上而**永不打印**（G1 的修法在这一点上落空） | 断网/token 过期时点保存 | 移除兜底后该问题消失；`ensureEditSubject` 现在**总是**给出原因（失败文案 / `server-returned-none` / `编辑器会话已切换`），与 `title` 互不覆盖 |
| **A3**（协议向） | 预取失败仍然静默：`.catch()` 只在**抛异常**时触发，而 `getPostAuth` 内部 try/catch，网络/鉴权失败是**返回 `ok=false` 不抛** | 打开编辑器时断网 | 改成 `.then(...)` 也判定失败（`title` 为空即 `logger.warn`），异常另挂 `.catch` |
| **A4**（协议向） | `sendEdit` 用 `this.editSubject` 提交（与返回值恒等，属隐式状态耦合） | — | 改为直接消费 `subjectResult.title` |
| **G1**（并发向） | `ensureEditSubject` 不看 `authResult.error`，check 失败仍提交空标题，用户看到的是服务端"标题过短"，真实原因无处可查 | 断网/token 过期时点保存 | `EditSubjectResult` 分开表达"服务端没给"与"取标题失败"；失败原因进 warn 日志（仍提交，让服务端给真实结论——**不擅自中止**，见下） |
| **G2**（并发向） | 判别日志用 `verbose`（Release 被 `VERBOSE` 开关静默），且不区分三种根因、无上下文 | 真机排查时拿不到线索 | 改 `logger.warn` 并带 `target`（`sessionTarget`）与 `authErr`（`server-returned-none` / 会话已切换 / check 的失败原因） |
| **G3**（并发向） | `startEdit` 里 `.catch(() => {})` 是全工程唯一空函数体，可能命中 `no-empty-function` | — | 改成带参数 catch + `logger.warn`（与 A3 合并为同一个 `.then/.catch` 对） |

审查中**未采纳**的一条与理由：G1 的另一半建议"没标题就中止提交"被否——服务端对
**非首帖 modify** 是否回传 `subject` 尚无样本（8.5 末段），贸然中止会把"目前可能成功"的
场景变成失败；等 8.4 的 #1/#3 真机结果再决定要不要收紧。

协议向审查**独立复核**（自己读 jadx 源码 + 自己发只读请求）的结论：§8.1 第 1 条的行号全部
准确；第 2 条的 `subject` 回传被复测证实；第 6 条的文案出处被独立印证；首帖 `pid=0` 的
排除成立（`PostArgScanner.ts:134` + 样本 `lou=0 → pid=0`）。它还指出卡片
`nga-hack/nga-client/docs/cards/8-post-write.md` 里两处会误导后来者的表述，已随之修正
（见该文件 §2.1 逐行证据注释与 §2.2 的通道归属说明）。

审查同时确认的正面结论：`await ensureEditSubject()` **不会**引入新的可重复点击窗口
（`ReplyDialog.doSend` 的 `sending=true` 在 await 之前、按钮已禁用，重传期由
`uploadingImage` 兜住）；错误透出链（toast → rethrow → 保留草稿与面板）完好；
五条既有提交链路（new / reply / quote / tietiao / modify）参数形态不受影响；
`sendReply` 仍传空 subject（modify 之外的 action 本就不该带）✓。

代价要认：**每次打开编辑器都会无条件多一次 post/check**（哪怕只看一眼就关）。
正常编辑仍只多 0 次提交往返（标题随预取就位）；快速点保存最坏多 1 次 check。
另有一个已知的可选优化：`getOrFetchAuth` 只有"结果缓存"、没有"飞行中 Promise 合并"，
预取与提交在缓存未命中窗口内可能并发发出两次 check——危害有限（提交请求不含 `auth`，
附件回填有"本地非空不覆盖"守卫），暂不改。

### 8.7 遗留（本次未做，按价值排序）

1. **编辑首帖时把标题框显示出来**（官方编辑页有标题框，可改标题）。本次只做到"不改标题也
   能改正文"；要让用户改标题，需在 `ReplyDialog.ets` 编辑模式加一行标题输入（首帖才显示），
   并把标题纳入 `FloatingLayerStore.editInitialContent` 与草稿结构（草稿目前只存正文，
   见 `DRAFT_MEDIA_PLAN.md` §9.5 的键设计）。
2. **`modify_append` / `content_org` 未处理**：对 `tid=45159659` 的 check 响应额外回传了
   `content_org` 与 `modify_append`（服务端对较老主题可能只允许"追加修改"）。
   官方 APK 的 L0/K0 参数表里没有这两个字段（只有 post/check 读取），因此暂不实现；
   若真机上出现"改完没生效/被截断"，从这里查。
3. `attachArray` 在本次两个主题上均未下发（`undefined`）——与主题有无附件一致，
   但**带附件首帖的回归（8.4 #4）仍要跑**。
4. **`getOrFetchAuth` 无 in-flight 合并**（协议向审查提出）：预取与提交在"缓存未命中"窗口内
   可能并发发出两次 post/check。危害有限（提交请求不含 `auth`；`restoreServerAttachments`
   有"本地非空不覆盖"守卫），暂不改；要收紧就加一个 `authInFlight: Promise<PostAuthResult>`
   字段。
5. **`extractPostSubject` 不做 trim**（`DomMarkerExtractor.ts:52-64`，对照 `extractThreadSubject`
   有 `.trim()`）：标题来自 HTML 兜底链路时可能带首尾空白。本次已移除"本地兜底"（8.6 A1），
   该空白不会再进入提交标题，故只作记录；真要修要走 `bbcode-ts` 镜像流程（改 TS 真源 →
   `npm test` → `npm run sync` → 编译 + Hypium 门禁）。

