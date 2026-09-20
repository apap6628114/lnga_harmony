# 编辑器草稿持久化 × 附件本地副本 × 懒重传 实现方案 v1.0

> **实施状态（2026-09-20 回填）**：四个阶段**全部完成**，逐阶段 `assembleHap` 编译通过。
> 实施中偏离本计划的地方集中在 §8「实施偏差与订正」，其中三条是**计划本身写错**（复制 API、
> Picker URI 授权期、上传频控），已在原处加注。

> 缘起：间歇性「附件确认错误，请回报管理员」的修复（见 `REVIEW_POST_API_MIGRATION.md` §7）留了一条尾巴——
> `replyManager` / `newTopicManager` 只能在"同一会话目标"内保留服务端签发的附件凭证，因为**草稿里的图片
> 一旦失去凭证就再也绑不回来**。本方案把这条尾巴切掉：让编辑器像官方客户端一样，**把媒体副本留在本地，
> 需要时重新上传**，从而可以把凭证寿命压到最短、彻底对齐官方会话语义。
>
> 官方依据：`PostFragment` 的 `mAttachArray/mAttachCheckArray` 是页面对象状态；草稿经 `ActionCheck`
> （`@DatabaseField`）与 `PostCacheBean.imageInfo` **持久化**；恢复草稿时对每张有本地路径的图
> **重新上传**（`PostHelper.R0/S0`，失败日志「发布内容恢复草稿上传图片错误」）。即：官方 =
> 「页面级对象状态 + 草稿持久化 + 恢复时重传」三层，鸿蒙现在只有第一层的一半。

---

## 0. 结论摘要

1. **方案成立**，且是唯一能同时解决两件事的路子：① 附件凭证的时效/错配风险；② 草稿里的图片
   在跨进程后必然失联。
2. **必须先做草稿持久化**。工程里**没有任何 `PersistentStorage`**，草稿走的是
   `AppStorage.setOrCreate<string>(key, text)`——AppStorage 是**内存态**，进程结束即丢。
   也就是说现在的草稿**连正文都跨不了重启**；不先把它落盘，"本地媒体副本"没有对应物。
3. 媒体副本必须**落在 `filesDir`（持久区）而不是 `cacheDir`**：后者会被系统回收，草稿却要长期存活。
4. 重传之后**必须原地替换正文里的标签**（URL 变了）。官方在 `handleUploadComplete` 里用
   `indexOf(旧url)` 做替换；鸿蒙要替换的是**整个标签串**（静态图 `[img]./<url>.medium.jpg[/img]`、
   动态照片是三半标记），这是本方案最容易做漏的一步。
5. 重传时机选**提交前（懒重传）**，不学官方"打开草稿就传"：打开草稿看一眼又关掉很常见，没必要
   消耗流量与 NGA 上传配额（上传有门槛与频次限制，错误码 13 = 发帖数不足）。
6. 做完 1–3 之后，`beginSession` 可以**无条件清空**会话凭证，删掉现在那条"同目标保留"的例外——
   代码反而更简单，语义彻底对齐官方。

---

## 1. 现状取证（为什么不能只加本地副本）

| 事实 | 位置 | 影响 |
|---|---|---|
| 草稿是内存态 | `ReplyManager.saveDraft/loadDraft/clearDraft`、`NewTopicManager.saveDraft/loadDraft/clearDraft` 全部走 `AppStorage`；全工程 `PersistentStorage` **零命中** | 杀进程后草稿（正文）丢失 → 只加媒体副本没有意义 |
| 附件凭证是内存态 | `PendingAttachment[]` 挂在单例上（`PostAttachments.ets`） | 杀进程即丢；同进程内靠"同目标保留"兜住 |
| 图片**没有**本地副本 | `ReplyDialog.uploadStillImage` 直接 `fileIo.openSync(picked.uri)` 读 Picker 的临时授权 URI；上传完就结束 | 无法重传 |
| 动态照片的两半会被删掉 | `ReplyDialog.handleImagePick` 的 `finally` 调 `releaseExportedMovingPhoto(picked.movingPhoto)`，删除 `cacheDir/mphoto_upload/<ts>/` | 要留副本，必须在这之前复制出去 |
| 正文标签形态 | 静态图 `'[img]./' + url + '.medium.jpg[/img]'`；动态照片 `buildMovingPhotoTag(coverUrl, videoUrl)` | 替换粒度 = 整个标签串 |

现成可复用的范式（不必从零造）：

- `MovingPhotoExport`：沙箱导出目录 + `releaseExportedMovingPhoto` + `cleanupStaleExports`（超期清理）
- `MovingPhotoCache`：`filesDir` 持久目录 + 容量上限（256MB）+ 占用计数避让
- `SavedThreadStore`：`filesDir/<dir>/<id>.json` 的结构化落盘
- `SettingsPanel.clearCache`：多分区 `cacheDir` + 持久目录的清理清单

---

## 2. 目标形态

### 2.1 数据结构

```ts
/** 草稿里的一条媒体：本地副本 + 它在正文中的标签。 */
export class DraftMedia {
  /** 静态图（或动态照片封面）的沙箱副本绝对路径。 */
  localPath: string = ''
  /** 该媒体当前插入正文的完整标签（重传后据此原地替换）。 */
  tag: string = ''
  /** 动态照片的视频半边副本路径；静态图为空串。 */
  videoLocalPath: string = ''
  /** 动态照片的视频半边标签；静态图为空串。 */
  videoTag: string = ''
  /** 上传得到的 URL（诊断用；重传后覆盖）。 */
  url: string = ''
  /** 上传时使用的原始文件名。 */
  fileName: string = ''
}

/** 一份编辑器草稿（持久化）。 */
export class EditorDraft {
  /** 草稿键（沿用现有 draftKey 形态，文件名安全）。 */
  key: string = ''
  /** 正文（发帖另有标题）。 */
  content: string = ''
  /** 标题（仅发新主题使用）。 */
  subject: string = ''
  /** 媒体清单。 */
  media: DraftMedia[] = []
  /** 最后更新时间（epoch ms）。 */
  updatedAt: number = 0
}
```

落盘位置：

- 草稿 JSON：`filesDir/drafts/<key>.json`
- 媒体副本：`filesDir/draft_media/<key>/<n>_<原始文件名>`

### 2.2 生命周期

```
                   ┌─ 上传成功 ─→ 插标签进正文
选图 ─→ 复制副本 ──┤                    │
     (draft_media) └─ 上传失败 ─→ 副本成孤儿（由清理回收）
                                        │
关闭编辑器（正文非空）─→ 草稿落盘：正文 + 媒体清单（含标签与副本路径）
                                        │
                       ┌────────────────┴─────────────────┐
        （同进程重开）─┘                                  └─（杀进程后重开）
   凭证还在，直接用                                       凭证已丢 → 懒重传：
                                                          从副本重新上传 → 新标签替换正文
                                                          → 更新草稿记录 → 再提交
```

提交成功 / 用户明确放弃草稿 / 超期 / 清缓存 → 删除草稿 JSON 与其媒体目录。

---

## 3. 分阶段实施

每阶段都能独立编译、独立验收，且不依赖下一阶段。

### 阶段 1：草稿持久化（不含媒体）—— ✅ 已完成

> **实施结果**：新增 `common/managers/DraftStore.ets`（`draftStore` 单例，随 `AppStore.init`
> 初始化）；`ReplyManager` / `NewTopicManager` 的 `saveDraft/loadDraft/clearDraft` 改走 `DraftStore`，
> 对外签名不变。`SettingsPanel.clearCache` 已接线（并改了对话框文案，见 §8）。
> 与计划的偏差：① 草稿键**加入 uid 短哈希**（见 §8.2）；② `DraftStore.init` **不做全量预热**、
> `cleanupStale` **分批执行并延后到启动之后**（见 §8.4）；③ 只有图片没有文字的草稿也会保存。

- 新增 `entry/src/main/ets/common/managers/DraftStore.ets`：
  `saveDraft(draft)` / `loadDraft(key)` / `clearDraft(key)` / `listDrafts()` /
  `cleanupStale(maxAgeDays)` / `totalBytes()` / `clearAll()`。
  实现照 `SavedThreadStore` 的 JSON 文件范式（`filesDir/drafts/`）。
- `ReplyManager`：`saveDraft/loadDraft/clearDraft` 改走 `DraftStore`（对外签名可保持不变，
  内部把 `content` 装进 `EditorDraft`）。
- `NewTopicManager`：同构（`subject` + `content` 分离存储现在是两个 AppStorage 键，合并进一份草稿）。
- `SettingsPanel.clearCache`：把 `filesDir/drafts` 加入清理清单（**否则"清除缓存"清不掉**，
  与 `MovingPhotoCache` 那条注释同一个坑）。
- 不做迁移：旧草稿本就在内存里，重启即丢，不存在需要搬迁的历史数据。

**验收**：回复框输入文字 → 关闭 → 杀进程 → 重开同一帖回复 → 正文恢复；
发帖框同理（标题 + 正文都恢复）。

### 阶段 2：媒体本地副本 —— ✅ 已完成

> **实施结果**：新增 `common/media/DraftMediaStore.ets`（`draftMediaStore` 单例，
> `saveCopy(key, data, fileName)` / `removeDraftMedia(key)` / `draftMediaBytes(key)` /
> `cleanupStale(liveKeys, maxAgeDays, maxBytes)`）。两个编辑器的图片入口都改走
> `uploadImageWithDraft` / `uploadMovingPhotoWithDraft`，复制发生在 `finally` 的
> `releaseExportedMovingPhoto` **之前**。
> **与计划的偏差（重要）**：计划 §5 写的「`fileIo.copy(srcUri, destUri)` 可直接用」**是错的**——
> 该接口两个参数都要求 URI（`destUri` 的注释为 "URI of the destination file or directory"），
> 裸沙箱路径不是合法入参。已改为**完全走 buffer 写盘**（调用方交出已在内存里的字节）。
> 另外计划里"Picker URI 跨进程不可用"这个理由也不成立（`photoUris` 有持久授权），
> 但"必须复制"的结论仍成立，理由已换（见 §8.1）。

- 新增 `entry/src/main/ets/common/media/DraftMediaStore.ets`：
  `saveCopy(context, key, srcPathOrUri, fileName): Promise<string>`（返回沙箱绝对路径）、
  `removeDraftMedia(key)`、`cleanupStale(context, maxAgeDays, maxBytes)`、
  `draftMediaBytes(key)`。写盘 API 以本地 SDK 声明为准（`fileIo.copyFile` 对 URI 的支持需先查证，
  退路是复用 `uploadStillImage` 的"读 buffer → 写文件"路径）。
- `ReplyDialog.handleImagePick` / `NewTopicDialog` 同构改动：
  - 静态图：上传**成功**后，把 `picked.uri` 复制进 `draft_media/<key>/`；
  - 动态照片：在 `finally` 的 `releaseExportedMovingPhoto` **之前**，把
    `exported.coverPath` / `exported.videoPath` 两半都复制过去。
- 复制成功后把 `DraftMedia` 追加进 manager 的**会话媒体清单**（`sessionMedia: DraftMedia[]`），
  关闭编辑器时随草稿一起落盘（阶段 1 的 `EditorDraft.media`）。
- 容量与超期：沿用 `MovingPhotoCache` 的思路，草稿媒体建议 **128MB 上限 + 7 天超期**
  （动态照片视频单条可达数十 MB，必须设上限）。

**验收**：传图 → 关闭 → 杀进程 → 重开 → 正文含 `[img]`，且 `filesDir/draft_media/<key>/` 下有副本；
"清除缓存"后该目录被清空。

### 阶段 3：懒重传 + 正文标签替换 —— ✅ 已完成

> **实施结果**：新增 `common/managers/DraftMediaUploader.ets`——重传逻辑**只此一份**，
> 两个 manager 通过实现 `DraftUploadHost` 接口（鉴权 + 上传能力 + 追加凭证 + 重传提示）
> 共用它。`ReplyDialog.doSend` / `NewTopicDialog.doSend` 在 `onSend` 之前 `await`
> `prepareSubmitContent()`，正文被替换时同步回写 `replyText` / `content`；失败停在编辑器并提示。
> 上传前弹一次「正在重新上传草稿中的图片...」，覆盖计划要求的"正在上传图片…"状态。
> 编辑（EDIT）场景不参与，保持 `attachArray` 回填语义不变。

- `ReplyManager.ensureDraftMedia(content: string): Promise<PreparedContent>`（`NewTopicManager` 同构）：
  1. 取草稿媒体清单里 `content.indexOf(tag) >= 0` 的项（正文仍然引用着它）；
  2. 若该项已经在本会话的 `pendingAttachments` 里（判据：`tag.indexOf(item.url) >= 0`，**不需要给
     `PendingAttachment` 加字段**）→ 跳过；
  3. 否则从 `localPath`（动态照片连 `videoLocalPath`）读 buffer → 走现有
     `uploadImage` / `uploadMovingPhoto` → 得到新标签；
  4. `content = content.replace(旧tag, 新tag)`，并同步更新草稿记录里的 `tag` / `url`。
  5. 任一项失败 → 返回失败结果（**不静默跳过**：正文里的 `[img]` 会变成未声明附件）。
- `ReplyDialog.doSend` / `NewTopicDialog.doSend`：在提交前 `await` 这一步，带"正在上传图片…"状态；
  正文被替换时**同步回写 `this.replyText`**，保证 UI 与提交内容一致；失败则停在编辑器让用户重试。
- 编辑（EDIT）场景不参与：正文里的图是服务端既有附件，本地没有副本，保持现在的
  `attachArray` 回填语义不变。

**验收**：传图 → 关闭 → 杀进程 → 重开 → 发送 → 图片在帖子中正常显示（新凭证有效）；
断开网络 → 发送 → 停在编辑器并有明确提示，恢复网络后可重试成功。

### 阶段 4：会话语义收紧 + 清理接线 —— ✅ 已完成

> **实施结果**：`ReplyManager.beginSession` 改为**无条件** `clearSession()`（`sessionTarget`
> 仅作为日志/诊断用途保留），"同目标保留凭证"的例外与 `action === 'modify'` 特判一并删除。
> `NewTopicManager.start` 同步收紧。清理接线四处全部到位：
> ① 提交成功（两个 manager 的 `send()` 内部，而非只靠对话框）；
> ② 用户明确放弃（编辑器的「放弃」按钮 → `discardDraft()`）；
> ③ 超期/超容量（`AppStore.initDraftCleanup`，分批延后）；
> ④ 设置→清除缓存（`SettingsPanel.clearCache` 的 dirs 清单 + 文案明示）。
> **与计划的偏差（重要）**：计划把媒体也按"7 天超期"独立淘汰——**这个口径会制造半损状态**
> （草稿 JSON 还在、副本没了 → 用户下次发送时懒重传硬失败）。已改为媒体寿命**绑定草稿**：
> 只做「孤儿 + 超容量」淘汰（见 §8.3）。

- `ReplyManager.beginSession` 改为**无条件** `clearSession()`（每次都重新 `post/check`），
  删掉"同一目标内保留凭证"的例外与 `sessionTarget` 的比较逻辑。理由：例外当初只为迁就
  "草稿图片没副本"，现在有重传能力，它的唯一作用就剩下延长凭证寿命。
- 清理时机集中接线：
  - 提交成功 → `clearDraft(key)` + `removeDraftMedia(key)`（现在是 `clearDraft` 的调用点，顺带做）
  - 用户明确放弃草稿（"放弃编辑"确认框 → 放弃）→ 同上
    > **订正（见 §9.3）**：该按钮的实际行为已改为"关掉编辑器、草稿保留"（与文案一致）。
    > 用户不再有"就地删草稿"的入口，"不要这份草稿了"的路径是**让它超期**（7 天）或
    > 设置 → 清除缓存。
  - 超期（7 天）/ 超容量 → `cleanupStale`
  - 设置 → 清除缓存 → 目录清单整目录删除（`drafts` + `draft_media`）
- 文档：更新 `REVIEW_POST_API_MIGRATION.md` §7.6，把"草稿重传缺失"从遗留清单里划掉。

**验收**：全链路回归（下面第 6 节）。

---

## 4. 关键设计决策与理由

| 决策 | 理由 |
|---|---|
| 草稿落盘用 JSON 文件而非 `PersistentStorage` | 媒体清单是结构化数组，`PersistentStorage` 只适合标量/简单对象；且文件形态便于按 key 增量清理与统计容量（`SavedThreadStore` 已验证） |
| 媒体副本放 `filesDir` 而非 `cacheDir` | `cacheDir` 会被系统回收，草稿却要跨会话甚至跨天存活 |
| 重传时机选"提交前"而非"打开草稿时" | 省流量、省上传配额；失败发生在"用户正要发送"的语境里，提示更自然 |
| 只对"正文仍引用"的媒体重传 | 用户可能已经删掉了某张图的标签，那就不该再为它花一次上传 |
| 重传失败不静默跳过 | 跳过会让正文的 `[img]` 失去附件声明——正是本次要消灭的那类不一致 |
| 动态照片两半一起复制、一起重传 | 服务端把它存成两个普通附件，只传一半会留下半个动态照片 |
| 阶段 4 才收紧会话语义 | 只有重传可用之后，"无条件清空"才是安全的；顺序颠倒会先制造一批"草稿图片失联" |

---

## 5. 风险、回退与边界

| 风险 | 处置 |
|---|---|
| 存储增长（动态照片视频可达数十 MB） | 128MB 上限 + 孤儿淘汰 + LRU；"清除缓存"入口接线（文案明示草稿也会被清） |
| ~~上传配额/频次限制（错误码 13 一类）~~ **（订正）** | ~~懒重传 + 只重传正文仍引用的项，把重传次数压到最低~~ → 见下方订正 |
| 重传后正文替换失败（标签已被用户手改） | 保留原标签 + 记 warn 日志，不阻塞发送；该附件码按未引用丢弃（现有 `buildAttachmentParams` 行为） |
| 副本文件缺失（用户清了缓存/文件被删） | 视为"无法重传"→ 明确提示"草稿中的图片需要重新插入"，让用户重选，而不是发出一条图片失联的回复 |
| Picker URI 跨进程不可用 | **（订正）** 该前提不成立（`photoUris` 有持久授权）；真实理由是「动态照片视频半边**根本没有持久 URI**（只由 `requestContent` 落在 `cacheDir`，调用方 upload 后整目录删）+ 资产可能被删/改名」。结论不变：必须复制 |
| 从 Picker URI 复制文件 | **（订正）** 计划称 `fileIo.copy(srcUri, destUri)` 可直接用是**错的**：该接口两个参数都要求是 URI（`destUri` 注释 "URI of the destination file or directory"），裸沙箱路径不是合法入参。已改为**调用方交出字节、本侧写盘**，整条链路不接触 URI 语义（见 §8.1） |

> **订正：上传"配额/频次限制"是不存在的**（2026-09-20 核查官方逆向源）。
> 官方上传错误码表（`nga-hack/jadx-out/classes2/sources/ct/k.java` 的 `c(String)` 分支，
> 输入是 `error_code` 字符串）共 13 项：1 附件上传关闭 / 2 附件上传版面错误 / 3 账号验证超时 /
> 4 文件上传错误 / 5 无上传文件 / 6 文件类型错误 / 7 附件名过长 / 8 附件说明过长 / 9 附件过大 /
> 10 无法创建临时文件 / 11 生成缩略图错误 / 12 操作超时 / 13 **发帖数超过 5 方可上传附件**。
> **没有任何频次/频率类错误**；每帖附件上限是 **10**（`PostHelper.java:1561-1581` 的 `/10`）。
> 因此懒重传的收益是**省流量与等待时间**，不是"避免触发频控"。
> 13 这一项对懒重传特别重要：它是用户**无法靠重试解决**的条件，所以它必须被翻译成人话
> （见 §8.5，本工程 `ErrorParser` 原先把它错写成"验证码错误"）。

**回退**：四个阶段各自独立，任一阶段出问题就把该阶段的分支退回（例如阶段 3 失败 → 保留本地副本
但停用懒重传，行为回到今天的状态），不会让编辑器不可用。

---

## 6. 验收清单（真机）

> **本节已按 §9 的修复更新**（2026-09-21）：新增条目覆盖本轮修的每一类缺陷，
> 原 1–9 条保持不变（能力不许降级）。标记 `[A*]`/`[B*]` 的条目对应该节编号。

1. 存草稿 → 杀进程 → 重开 → 正文恢复（阶段 1）
2. 传图 → 关闭 → 杀进程 → 重开 → 正文含 `[img]`，副本存在于 `draft_media/<key>/`（阶段 2）
3. 承上继续发送 → 帖子里的图片**正常显示**，且服务端附件区有这张图（阶段 3：新凭证有效）
4. 传一张动态照片 → 关闭 → 杀进程 → 重开 → 发送 → 动态照片在帖子中仍是动态照片
5. 传两张图，手工删掉其中一张的 `[img]` 标签 → 发送 → 只提交另一张（现有正文过滤 + 不浪费重传）
6. 断网状态点发送 → 停在编辑器、有明确提示；恢复网络重试成功（阶段 3 失败路径）
7. "放弃编辑" → **草稿与媒体目录都被保留**（§9.3 改了行为：主按钮是"关掉编辑器"）；
   要清掉草稿走 设置 → 清除缓存
8. 设置 → 清除缓存 → `drafts` 与 `draft_media` 都被清空，且徽标里的"草稿 xx KB"归零（阶段 1/2 接线）
9. 回归 `REVIEW_POST_API_MIGRATION.md` §7.5 的四条原路径（尤其"回复模式传图 → 切贴条 → 切回回复 → 发送"）

本轮新增：

10. `[A1]` 传一张大图/动态照片（重传耗时明显）→ 点发送 → 重传进行中下拉关闭 → 确认框选「放弃」
    → **帖子不得发出**，`drafts/<key>.json` 里的正文与媒体清单保持重传前状态
11. `[A4]` 同上场景，但在重传进行中往输入框里再打一段字 → 重传结束后（若失败，看提示）
    那段字**必须还在**；重传期间新插入的图片标签也不得被回退
12. `[A3]` 制造"部分失败"：动态照片草稿 → 手工删掉视频副本文件（`rm draft_media/<key>/*video*`）
    → 发送 → 明确提示需要重新插入 → 此时再关一次编辑器 → 重启 App →
    磁盘草稿里的 `url` 与正文标签**必须指向同一个地址**（不出现"新 URL + 旧标签"）
13. `[A5]` 同一楼层：回复里插张图 → 切「贴条」→ 切回「回复」→ 关闭 → 重开 →
    正文与图片都在，且 `draft_media` 下**只有一个**该目标的目录（无 `_floor_`/`_comment_` 孤儿）
14. `[A6]` 造两个草稿目录，让总量超过 128MB（可临时调小 `DRAFT_MEDIA_MAX_BYTES`）→
    重启 App → **有草稿 JSON 的那一份副本不能被删**；日志里出现 over limit + protected 计数
15. `[A7]` 删除某个草稿的 JSON 文件（模拟"放弃/超期"）→ 重启 → 它的媒体目录**当场**被回收
    （不必等 7 天）；反向：打开编辑器传图但**不关闭**，同时在另一处触发清理 → 目录必须还在
16. `[A8]` 造 20 份超期草稿（`touch` 改 mtime 到 8 天前）→ 重启 → 分 4 批后
    **前 8 份之外也应有被删的**（旧实现只反复检查前 8 份）
17. `[B1]` 手工把某份草稿 JSON 的 `media` 改坏（元素缺 `url`、或 `media` 写成对象）→
    打开编辑器 → 正文恢复且**不报 TypeError**；`media` 写成对象的那份被 warn 并删掉
18. `[B4]` 同一张图的 URL 在正文里出现两次 → 杀进程后重开 → 发送 → **两处都换成新地址**
19. `[B6]` 服务端响应缺 `attachments` 时（可临时 mock）→ 提示上传失败，
    **正文里不得留下指向该地址的 `[img]`**
20. `[B7]` 动态照片草稿：手工只删掉正文里的 `[flash=video]...[/flash]` 段 → 发送 →
    封面不重复上传，日志里 `video=false`
21. `[B8]` 上面每一条失败路径都应在 hilog 里出现一条
    `reupload failed half=... kind=... file=... retryable=... reason=...`
22. `[B9]` 图片上传进行中下拉关闭编辑器 → 确认框出现（不直接关掉）→ 选「继续编辑」→
    上传完成后图片仍插进了正文
23. `[B12]` 传一张图 → 把 `[img]` 从正文删掉 → 清空正文 → 关闭 → **不弹确认框**、不留空草稿；
    再次打开编辑器时是干净的
24. `[B13]` **编辑**一个已有楼层 → 插一张图 → 关闭编辑器 → 再进入同一楼层的编辑面板 →
    新插的 `[img]./<url>.medium.jpg[/img]` **仍在正文里**（修复前会被服务端原文覆盖掉）→
    保存 → 帖子里的新图正常显示；日志里出现一条
    `[REPLY] draft media re-uploaded count=1`（凭证在重进时已作废，靠副本重传重建）。
    反向：不做任何修改直接关闭 → 不得把草稿正文改成"不含 `[img]`"的版本

---

## 7. 不做什么

- **不做删图/删附件**（官方 `removeFromUploadedList` + 服务端 `del_attach`）：与草稿无关，
  是独立功能，避免把这次改动摊大。
- **不做"上传中互斥"以外的并发治理**：现有 `uploadingImage` 重入守卫已够。
- **不改上传协议本身**（字段、boundary、auth 语义）：本方案只在客户端侧增加副本与重传。
- **不动编辑（EDIT）场景的附件回填**：服务端 `attachArray` 语义未变。

---

## 8. 实施偏差与订正（2026-09-20）

### 8.1 媒体副本改为"调用方交出字节"（计划写错了复制 API）

计划 §5 断言 `fileIo.copy(srcUri, destUri, options?)` 可以直接拿 Picker URI 当 `src`、沙箱路径当
`dest`。核对本地 SDK 声明（`@ohos.file.fs.d.ts`）：

- `copy(srcUri, destUri, options?)`（@since 11）——**两个参数都是 URI**（`destUri` 注释
  "URI of the destination file or directory"）；
- `copyFile(src, dest, mode?)` / `copyFileSync`——参数是 **Path or FD**，不吃 URI。

草稿媒体的两个来源恰好一个 URI（Picker 的 `file://media/...`）、一个路径（动态照片的
`cacheDir/mphoto_upload/<ts>/...`），要用某一个 API 同时吃下两者就得引入
`fileUri.getUriFromPath` 一类的转换。**改为完全绕开 URI 语义**：
`DraftMediaStore.saveCopy(key, data: ArrayBuffer, fileName)` 只接收字节——静态图用
`uploadStillImage` 已经读到的那份 buffer，动态照片两半用现成的 `readExportedFile`。
既省一次 IO，也不再把"复制"这件小事绑到 URI 契约上。

### 8.2 草稿键加入 uid 短哈希（计划未提，但会串账号）

计划的草稿键形态沿用现有 `draft_<tid>_reply` 一类，不含账号维度；而工程里"退出登录"走的是
`appStore.clearAuth()`，碰不到草稿目录。结果是**换账号后在同一个帖子/版块打开编辑器，会读到
上一个账号的草稿正文与媒体清单**。已按官方 `ActionCheck.buildActionId = uid + "/" + fid + ...`
的同构思路，把 uid 的 FNV-1a 短哈希并入键（`draft_<tid>_reply_<uidHash>`），未登录用 `anon`。

### 8.3 媒体寿命绑定草稿，不独立按 7 天淘汰（计划口径会制造半损状态）

计划写「128MB 上限 + 7 天超期 + LRU」。但草稿 JSON 与媒体副本是**两份独立文件**：
若媒体满 7 天先走一步而草稿还在，用户下次（可能是离线）发送时懒重传就会撞上
"本地副本已不存在"的硬失败——**比不清理更糟**。

已改为：**孤儿 + 超容量**两种淘汰；草稿自身满 7 天由 `DraftStore.cleanupStale` 删除，
随后它的媒体目录自动成为孤儿被回收。

> **订正（2026-09-21，见 §9）**：本节初版的实现把"孤儿"判成
> `!liveKeys.has(key) && entry.mtime < now - 7d`，于是**刚产生的孤儿必然不满足条件**、
> 而孤儿又不计入 `totalBytes` —— 128MB 上限形同虚设、磁盘占用无上界（§9.6）。
> 现在的口径是：**孤儿即时回收**（没有草稿认领就删，不看时间），容量淘汰**只从孤儿里挑**、
> 有主（有草稿 JSON 或编辑器会话活跃）一律豁免（§9.5/§9.6）。
> `maxAgeDays` 参数已从媒体清理的签名里删掉，它现在只有一个语义——
> `DRAFT_RETENTION_DAYS`（草稿 JSON 的保留期，7 天），定义在 `DraftStore` 里。

### 8.4 冷启动不做同步清理

计划把 `cleanupStale` 与 `init` 并列。但它是 `listFileSync` + 逐文件 `statSync` 的**主线程同步
IO**，放在冷启动主路径上会拖慢启动（`MovingPhotoExport.pruneStaleExports` 早就为此设了
`MAX_PRUNE_PER_RUN`）。已改为：`DraftStore.init` 只建目录（两次 `accessSync`），**不预热草稿
内容**（`loadDraft` 按需读单一文件）；清理用 `setTimeout(800ms)` 延后，分批（每批 8 个、
最多 4 轮）推进；媒体目录清理只在最后一批之后跑一次（它要遍历整棵 `draft_media` 树）。

### 8.5 顺手修正：上传错误码表错位（含 13）

`ErrorParser.ets` 的 `error_code` 映射原为 `{9:附件过大, 10:权限不足, 11:未登录, 12:内容为空,
13:验证码错误, 14:用户名或密码错误, 15:频率限制}`——按官方表 13 应是**「发帖数超过5方可上传
附件」**，10/11/12 也全错（分别是"无法创建临时文件"/"生成缩略图错误"/"操作超时"）。
一张图都传不上去的用户看到"验证码错误"只会反复重试。

> **订正（2026-09-21）**：本节初版写「已按官方表 1–13 全部改正」，**与实际改动不符**。
> 实际改的是**新增一张上传专用表**（上传错误码与 `error_code` 是两套编号：
> `post`/`reply` 那条通用表的 9–15 原本就对，动它会砸掉发帖/回复的既有提示）。
> 即：上传响应的错误码走新增的上传表翻译，通用表保持原样，两张表各自独立。
> `ThreadWriteApi.fillUploadResult` 在服务端未给 `error` 文案时用上传表翻译。

### 8.6 「清除缓存」的处理方式（有意保留的取舍）

`drafts` 是**不可再生的用户数据**（还没发出去的正文），性质与 `MovingPhotoCache` 那种
"能重新下载"的缓存不同。但原方案没有任何草稿管理入口，而媒体副本最多 128MB 长期占持久区，
"清除缓存"是用户唯一可用的"我不需要了"出口。取舍：**接入清缓存，但先改对话框文案**明说
「未发送的草稿与草稿中的图片也会被删除」，并同步重置 `draftStore` 的内存缓存
（`reloadAfterClear`，否则本次进程内还会"复活"已删草稿）。

已知瑕疵（本次不新增入口）：`refreshCacheSize()` 读的 `bundleStats.cacheSize` **只统计
cache 目录**，清掉 `filesDir` 下的草稿后界面数字不会变。

> **订正（2026-09-21，见 §9.10）**：徽标已把草稿占用并进来
> （`bundleStats.cacheSize + draftStore.totalBytes() + draftMediaStore.totalBytes()`，
> 有草稿时显示为 `「12.3 MB · 草稿 120 KB」`）。清缓存后两个 `reloadAfterClear()`
> 一起跑（`draftStore` 清内存缓存、`draftMediaStore` 重建被整目录删掉的 `draft_media` 根目录）。

### 8.7 系统备份：不排除

`module.json5` 的 `backup_config.json` 目前是 `{"allowToBackupRestore": true}`，草稿 JSON 与
媒体副本会进系统备份/换机迁移。**决定不排除**：草稿本就是"还没发出去的内容"，跨设备恢复对
用户是正向的，且体量有 128MB 上限兜底。若后续要收紧，需先查证 `backup_config.json` 的排除
字段 schema——本地 SDK 只声明了 `@ohos.application.BackupExtensionAbility.d.ts` 的方法，
**没有该配置文件的字段声明**，无法按本工程"API 查询门禁"验证格式，故本次不动。

### 8.8 其他保持一致的地方

- **`send()` 签名与调用方零改动**：`ThreadPanel.handleReplySend` / `handleEditSend`、
  `TopicListPanel.handleNewTopicSend` 的调用形态与错误分支未动。
- **提交成功后的清理放在 manager 的 `send()` 内**（而不是只靠对话框）：`TopicListPanel` 等
  调用方直接调 `newTopicManager.send()`，只挂在编辑器上会漏。
- **重传逻辑只此一份**：`DraftMediaUploader.prepareDraftMedia`，两个 manager 通过实现
  `DraftUploadHost` 接口共用（`pendingUrls` + `appendPending()` + `onReuploadStart()`
  + 两个 upload 方法）。**不要**在接口里声明与宿主私有字段同名的成员——ArkTS 会报
  "Duplicate identifier" 而不是把它当接口实现（本次踩过）。

---

## 9. 四角度审查修复清单（2026-09-21）

首版实现上线前做了四轮独立审查（正确性/竞态、数据生命周期、协议一致性、体验/工程质量），
共命中 30+ 条问题、其中 8 条高危。本节记录**逐条状态**：哪些已修、怎么修的、哪些没修及原因。
按 A（高危）/B（中危）/C（清理）三组，A 组全部完成。

本轮**三轮编译全部通过**（命令均为 `assembleHap --mode module -p module=entry@default
-p buildMode=debug --no-daemon`，取日志里的 `BUILD SUCCESSFUL` 行为准）：

| 轮次 | 覆盖范围 | 结果 |
|---|---|---|
| 第 1 轮 | A 组（高危 8 条）+ B 组（中危 12 条） | `BUILD SUCCESSFUL in 33 s 733 ms` |
| 第 2 轮 | 追加 C 组清理项（死代码 / `.tmp` / uid 哈希 / 重入守卫 / 根目录 / 注释） | `BUILD SUCCESSFUL in 21 s 57 ms` |
| 第 3 轮 | 复查后的收口（游标注到"扫过的"名字、清理链 `finally` 释放守卫、失败文案与 `ErrorParser` 文案逐字对齐） | `BUILD SUCCESSFUL in 28 s 148 ms` |

`node scripts/check-eol.mjs` 每一轮之后都跑，违规只剩既有的 `oh-package-lock.json5` 一条。

### 9.1 状态总表

| 编号 | 问题 | 状态 |
|---|---|---|
| A1 | 重传期间关面板 → 帖子照样发出（幽灵发送） | ✅ 已修 |
| A2 | 确认框主按钮行为与文案相反（「放弃」删草稿） | ✅ 已修 |
| A3 | 部分失败导致持久化劈叉（新 URL + 正文旧标签） | ✅ 已修 |
| A4 | 重传完成后整串覆盖正文，用户输入被吞 | ✅ 已修 |
| A5 | 模式切换导致草稿键/媒体目录错配 | ✅ 已修 |
| A6 | 容量淘汰删掉活跃草稿的唯一副本 | ✅ 已修 |
| A7 | 孤儿副本要等 7 天才回收，128MB 上限失效 | ✅ 已修 |
| A8 | 分批清理无游标，第 9 个之后的超期草稿永不清理 | ✅ 已修 |
| B1 | `loadDraft` 不校验 `media` 元素 / 缺失时不 warn 不删 | ✅ 已修 |
| B2 | 缓存与调用方共享同一 `media` 数组 | ✅ 已修 |
| B3 | EDIT 不装回草稿媒体 | ✅ 已修 |
| B4 | 标签整串替换 → 改为按 URL 片段、全部替换、不走 `$` 语义 | ✅ 已修 |
| B5 | `isUrlPending` 用完整标签当判据 | ✅ 已修 |
| B6 | `attachments` 为空被当成功（静默路径） | ✅ 已修 |
| B7 | `replaced` 单布尔混代表封面/视频两半 | ✅ 已修 |
| B8 | 失败路径零日志、文案不可操作 | ✅ 已修 |
| B9 | 上传在途时关面板会 `clearDraft()` | ✅ 已修 |
| B10 | `ReplyManager` 未 `implements DraftUploadHost` | ✅ 已修 |
| B11 | `prepareSubmitContent` / `shortHash` / `isValidKey` 重复实现 | ✅ 已修 |
| B12 | 「只有图片没有文字」判定过宽 | ✅ 已修 |
| B13 | EDIT 模式不接回草稿正文（新插图重开后从正文消失） | ✅ 已修（§9.12） |
| C1–C9 | 死代码 / `.tmp` 残留 / uid 哈希 / 重入 / 根目录 / 注释 | ✅ 8 项已修，1 项不做（见 §9.10） |

### 9.2 A1 幽灵发送：`await` 之后的 `disposed` 检查

`ReplyDialog.doSend` / `NewTopicDialog.doSend` 在 `await this.prepareSubmitContent()` **之后、
任何状态写入之前**加 `if (this.disposed) { return }`。`prepareDraftContent` 内部（`await`
之后、写 `@State` 之前）也各自检查一次，因为那条路径同样会写 `replyText` / `content`。
提交回调的 `.then` 里只保留"清草稿"（manager 是进程级单例，与组件生命周期无关），
`onClose()` 用 `if (!this.disposed)` 包住。

### 9.3 A2 确认框：主按钮恢复为「关闭编辑器，草稿保留」

`abandonDialogController` 的主按钮 action 从 `discardDraft()` 改成 `this.onClose()`——
`requestClose` 已经先 `saveDraft` 了，这与文案「已保存为草稿，下次编辑可恢复」一致。
`discardDraft()` 因此没有调用方，两个 Dialog 里的这个方法都已删除。
真正"删草稿"的入口只剩设置里的「清除缓存」（文案已明示，见 §8.6，本次未改）。

### 9.4 A3 + A4 替换对机制（本轮最核心的改动）

**问题**：`reuploadOne` 先 `appendPending` + 就地改写 `item.url/tag`，之后才可能失败；
失败分支只返回一个字符串，不回写正文。用户随手再关一次面板，磁盘草稿就记下
"新 URL + 正文旧标签"，重启后 `isMediaReferenced` 三项全不匹配 → 静默跳过 →
正文 `[img]` 变成未声明附件（正是本方案要消灭的那类不一致）。
另一半问题是 `PreparedContent.content` 让调用方**整串覆盖** `replyText`，
等待期间的输入与新插入的图片标签被静默丢弃。

**修法**：契约从"给一份新正文"改成"给一串替换对"。

```ts
/** 一条正文替换：旧 URL 片段 → 新 URL 片段。 */
export class ContentReplacement { oldText: string = ''; newText: string = '' }

export class PreparedContent {
  replacements: ContentReplacement[] = []   // 不再是 content: string
  changed: boolean = false
  error: string = ''
  reuploaded: number = 0
}
```

- `prepareDraftMedia` **只做判定与上传**（`content` 入参只用于判引用），不再持有正文；
- 调用方 `this.replyText = manager.applyMediaReplacements(this.replyText, prepared)`，
  `applyContentReplacements` 拿的是**当前**正文，逐条替换，旧片段已不在文本里的跳过；
- **先验后改**：`item.url/tag/videoUrl/videoTag` 的改写推迟到"该媒体两半都有结果"之后，
  且只有成功的半边才写；
- **失败也回写**：视频半边失败时 `carryCoverOnly()` 把已成功封面的替换对带回
  （`item.url` 更新、`item.tag` **不**重建——视频地址还是旧的，重建会与正文不符）；
- 动态照片的 `item.tag` 只在**两半都成功**时用 `buildMovingPhotoTag` 重建，避免"草稿说视频已换、
  正文还是旧的"。

### 9.5 A5 新键规则：模式移出草稿键

| 目标 | 键 |
|---|---|
| 编辑某楼层 | `draft_<tid>_edit_<pid>_<uid>` |
| 楼层回复 **/** 贴条 | `draft_<tid>_p<pid>_<uid>` |
| 主题级回复 | `draft_<tid>_<uid>` |

发新主题仍是 `draft_newtopic_<fid>[_stid<N>]_<uid>`（本类没有模式开关）。
`toggleMode()` 只改 `ctx.type` 不重划会话，模式参与键时一次编辑会话会在两个键之间漂移，
而媒体目录绑在键上 → 目录要么共享、要么被对方整目录删掉、旧键还会留下无引用者的孤儿目录。
移出模式后 `draftKey()` 在 `toggleMode()` 前后恒定，`clearDraft()` 也只可能删到当前键的目录。
**旧键不兼容、不迁移**（用户明确不要旧草稿数据）。

### 9.6 A6 + A7 活跃键登记与清理语义

媒体的寿命**绑定草稿**，`DraftMediaStore` 没有独立的"按天淘汰"：

- **孤儿**（`DraftMediaClaim.isProtected` 为假）→ **即时删除**，不看时间；
- **有主** → 一律豁免，容量淘汰也不动；
- 容量超限 → **只在孤儿里挑**（A6 之前把有主目录一起按 mtime 升序删，
  **最旧的活跃草稿第一个被删**，而副本是唯一来源 → 用户发送时硬失败且无恢复路径）；
  孤儿清完仍超限 → 记 warn 并保持现状（删有主副本是数据丢失，比超容量严重）。

「有主」由三个判据取或（`DraftMediaClaim`）：

1. **实时** `draftStore.hasDraftFile(key)`——主判据，删除前当次确认，
   不用启动时的 `listKeys()` 快照（清理跑在启动后 800ms，期间用户完全可能刚存一份新草稿）；
2. 启动快照 `liveKeys`；
3. `draftStore.activeKeyList()`——**活跃键登记**：编辑器 `beginSession` / `start` 时登记、
   `clearDraft` / 提交成功时注销、`reset` 与 `reloadAfterClear` 清空。
   这条专门防"编辑器还开着、草稿 JSON 还没落盘（用户正在打字），
   但媒体副本已经写好"的那个窗口——此时该键既不在 `listKeys()` 里，也不该被判孤儿。

**`maxAgeDays` 语义重新定义**：它现在只有一个含义——
`DRAFT_RETENTION_DAYS`（**草稿 JSON 的保留期**，7 天，行为未变），定义在 `DraftStore` 里；
媒体清理的签名已不再收这个参数。早先的 `DRAFT_MEDIA_MAX_AGE_DAYS` 既被当"媒体兜底阈值"
又被当"草稿保留期"，名字与用途不符，已删除该常量。

`DraftMediaStore.cleanupStale(claim, maxBytes)` 现在返回 `DraftMediaCleanupResult`
（`removed` / `protectedCount` / `overLimit`）：线上日志能直接回答
「这 128MB 是被谁占的、为什么没降下来」。

### 9.7 A8 分批清理游标

`DraftStore` 加内存游标 `cleanupCursor`：每批在 `names.sort()` 之后从"上一批的下一个文件名"
继续，逐批向前推进；走完一整趟就重置（下次启动从干净的一趟开始，新草稿因此必被检查一次）。
`hasMore` 改成只按「本批是否因 `maxPerRun` 提前收手」判定——早先的
`names.length > examined` 把目录与 `.json.tmp` 也算进分母，于是空跑好几批。

### 9.8 B1–B8 数据与协议侧

- **B1**：新增 `normalizeMedia` / `normalizeMediaItem` 做**元素级**字段补全
  （缺字段/类型不符 → 空串，元素不是对象 → 丢弃该元素并 warn）；`media` 不是数组 →
  按损坏处理（warn + 删文件，不再留永久残渣）；老草稿没有 `media` 字段 → 按"没有媒体"处理。
  `content` / `subject` 类型不符同样补成空串。
- **B2**：`saveDraft` 的缓存改用 `cloneMedia()` **逐项深拷贝**（其余字段本来就是值拷贝）。
- **B3**：`beginSession` 不再排除 EDIT——编辑模式的图片按钮照常可用、
  `uploadImageWithDraft` 照常登记副本，不装回就会出现"编辑里插的图重开后无凭证"。
  编辑正文里原本就有的服务端既有附件没有副本，不在草稿清单里，`attachArray` 回填语义不受影响。
- **B4**：替换改为**按 URL 片段定位**（`extractUrlFragment`，与官方
  `PostFragment.handleUploadComplete` 的 `indexOf(去掉前缀的 url)` 同款），
  同一 URL 出现多次**全部替换**；替换实现是手写扫描 `replaceAllText`，不用 `String.replace`
  （替换串里的 `$&` / `$'` / `` $` `` 有特殊含义），也不用 `split/join`（省一次数组分配）。
- **B5**：`isUrlPending(urls, url)` 直接按 **url 相等**判定，不再看标签。
- **B6**：`appendPendingAttachment` 返回 `boolean`（`attachments` 为空时返回 false），
  三个上传入口（`uploadImage` / `uploadMovingPhoto` / 懒重传）全部据此判失败并给出可操作提示。
- **B7**：拆成 `coverDone` / `videoDone` 两半各自判定与记录。
- **B8**：每个失败返回点都走 `failMessage()`——一条 `logger.warn`
  带 `half`（封面/视频/鉴权）、`kind`（图片/动态照片）、`file`（原始文件名）、
  `retryable`、`reason`；用户文案区分「请重试」与「重试无用」，
  副本缺失时明说**哪一张**（带文件名）需要重新插入。

### 9.9 B9–B12 体验与工程

- **B9**：两个 Dialog 的 `requestClose` 保稿条件加 `this.uploadingImage`——
  上传/重传在途时关面板不再走 `clearDraft()` 分支（那会在上传完成后把媒体登记进已清空的会话）。
- **B10**：`ReplyManagerClass implements DraftUploadHost` 补齐（`NewTopicManagerClass` 已有）。
- **B11**：`shortHash` / `isValidDraftKey` 两份逐字实现合并到 `DraftStore`
  （导出 `shortHash36`、`draftUidPart`、`isValidDraftKey`，`DraftMediaStore` 直接复用校验函数）；
  替换对的应用合并为 `DraftMediaUploader.applyContentReplacements`，两个 manager 各暴露一个
  `applyMediaReplacements` 薄封装供各自 Dialog 调用。两个 `prepareSubmitContent` 本质是
  "不同 manager + 不同 @State"的编排，未强行合并（合并需要抽组件基类，代价大于收益）。
- **B12**：判定改成"正文里是否还引用着某个已登记的媒体"
  （`hasReferencedMedia`），不再用数组长度。用户把 `[img]` 从正文删掉再清空正文后，
  关闭编辑器不再弹确认框、也不再存一份空壳草稿。

### 9.10 C 组清理项

| 项 | 处置 |
|---|---|
| `DraftStore.clearAll()` | 已删（无调用方；"清除缓存"走整目录删除） |
| `DraftStore.totalBytes()` | **接上**：设置页容量徽标（§8.6 的已知瑕疵已订正） |
| `DraftMediaStore.draftMediaBytes()` | 保留：被新增的 `totalBytes()` 复用 |
| `DraftUploadHost.draftUploadFid` | 已删（接口成员 + 两个宿主实现） |
| `DraftMedia.tagIntact` | 已删（无读取方；`tag` 字段语义改为"URL 片段"并更新注释） |
| `ReplyManager.sessionTarget` | **接上**：`beginSession` 里记一条 verbose 日志（排查附件确认错误要用） |
| `NewTopicDraft.media` | 已删（媒体清单只在 `start()` 里装进会话，避免两条装回路径） |
| `DraftMediaCount` getter | 已删（唯一调用方 B12 已改判据） |
| `.tmp` 残留回收 | 已加：`sweepTempFiles()` 在每次 `cleanupStale` 开头扫掉 `.json.tmp` |
| uid 短哈希 | `(hash >>> 0).toString(36)`，不再 `if (hash < 0) hash = -hash`（后者把 `0x80000000` 映射到 0） |
| `initDraftCleanup` 重入守卫 | 已加（`draftCleanupRunning`，链条真正结束时释放） |
| 清缓存后重建 `draft_media` 根目录 | 已加（`DraftMediaStore.reloadAfterClear()`，SettingsPanel 调用） |
| `DraftStore` 与实现相反的注释 | 已订正：「缓存存副本」→「存深拷贝」、「诊断用」字段注释、`clearAll` 相关清理语义 |

**未做**：`DraftStore.clearAll()` 没有恢复，因此"清缓存"链路完全依赖
`SettingsPanel` 的目录清单 —— 这是有意的：草稿目录**必须**与 `draft_media` 一起清，
两条独立入口只会让二者漏掉一条。

### 9.11 本轮未修 / 需真机验证的遗留

- **`refreshCacheSize` 的草稿占用是同步目录扫描**：目录规模是"用户还没发出去的草稿"级别
  （0 到几个），且只在设置页出现与清缓存后各调一次，未做异步化。
- **`bundleStats.cacheSize` 本身不含 `filesDir`**：现在靠相加补上，数字口径是
  「系统缓存 + 草稿占用」，与系统设置里看到的"应用缓存"不会完全一致。
- **确认框文案「放弃编辑？」与主按钮「放弃」**：行为已恢复为"关掉编辑器、草稿保留"，
  文案保持原样（用户没有要求改文案）。
- **本轮改动无法在编译期验证的部分**：清理语义、竞态窗口、替换对的边界
  （同一 URL 出现多次、标签被手改、部分失败）都只有静态走查，必须真机验证，见 §10。

### 9.12 评审后追加（用户实测）：EDIT 模式不接回草稿正文（B13）

**现象**（用户实测报告）：修改已有楼层 → 插入附件 → 退出编辑器 → 再进入编辑器，
刚插入的 `[img]./<url>.medium.jpg[/img]` 从正文里消失。

**根因**（代码走查，未经真机复现）：`ReplyDialog.aboutToAppear` 的 `editMode` 分支只把
`initialContent`（`ThreadPanel.onEdit` 传的服务端楼层原文）赋给 `replyText`，**不读草稿**；
而新回复分支读（`replyManager.loadDraft()`）。于是 §9.8 的 **B3 只完成了一半**——
`beginSession` 把草稿媒体装回了 `sessionMedia`，正文里的标签却不在。

**后果链**：
1. `isMediaReferenced` 判不出引用 → 提交时该媒体既不重传、也不进 `buildAttachmentParams`
   → 图片**静默消失**（"正文没引用这条媒体"在过滤逻辑里是合法形态，不会报错、没有提示）；
2. `requestClose` 又把这份不含标签的正文 `saveDraft` 回草稿 → 磁盘上唯一记录着 `[img]`
   的正文被抹掉，媒体副本失去引用者，只能随草稿超期（7 天）被整目录回收。

**修法**：编辑分支改成与新回复分支同一判据——

```ts
const draft: string = replyManager.loadDraft()
this.replyText = draft.length > 0 ? draft : this.initialContent
```

`@Prop initialContent` 的语义随之明确为"**无草稿时的兜底**"（注释已同步）。

**代价（有意接受）**：服务端正文若在别处被改过（网页版 / 另一台设备），草稿会**盖住**它。
这正是「已保存为草稿，下次编辑可恢复」这句文案的语义（与 §9.3 的确认框行为一致）；
要以服务端为准，走设置里的「清除缓存」（文案已明示草稿会被删）。

**用户问到的「数据、凭证状态」，两处都没有丢**：

| 状态 | 位置 | 修复前的实际情况 |
|---|---|---|
| 草稿正文 + 媒体清单 | `filesDir/drafts/draft_<tid>_edit_<pid>_<uid>.json` | 退出那一刻 `content` 与 `media[]`（`localPath` / `url` / `tag` / 视频两半）都完整落盘；丢的是**再进入之后**：正文被 `initialContent` 覆盖，一关闭就把草稿 `content` 一起覆盖掉 |
| 服务端凭证 | `ReplyManager.pendingAttachments` | 每次 `beginSession` **无条件作废**（见该方法注释：凭证只对签发它的那次提交有效，不做同目标复用），靠草稿媒体副本在提交前懒重传重建——修复后这条链路才真正可达（修复前正文无标签，重传判定直接跳过） |
| 媒体副本 | `filesDir/draft_media/<key>/` | 修复前一直躺在磁盘上，只是没有任何正文引用它，不会进提交也不会被单独回收 |

**待办**：真机复验（编辑带图楼层 → 退出 → 重进 → 保存，检查正文标签、`[REPLY] draft media
re-uploaded` 日志与最终帖子），见 §6 验收清单第 24 条。

