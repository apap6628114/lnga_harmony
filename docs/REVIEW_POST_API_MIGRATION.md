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
