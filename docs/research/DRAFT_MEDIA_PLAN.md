# 编辑器草稿持久化 × 附件本地副本 × 懒重传 实现方案 v1.0

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

### 阶段 1：草稿持久化（不含媒体）

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

### 阶段 2：媒体本地副本

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

### 阶段 3：懒重传 + 正文标签替换

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

### 阶段 4：会话语义收紧 + 清理接线

- `ReplyManager.beginSession` 改为**无条件** `clearSession()`（每次都重新 `post/check`），
  删掉"同一目标内保留凭证"的例外与 `sessionTarget` 的比较逻辑。理由：例外当初只为迁就
  "草稿图片没副本"，现在有重传能力，它的唯一作用就剩下延长凭证寿命。
- 清理时机集中接线：
  - 提交成功 → `clearDraft(key)` + `removeDraftMedia(key)`（现在是 `clearDraft` 的调用点，顺带做）
  - 用户明确放弃草稿（"放弃编辑"确认框 → 放弃）→ 同上
  - 超期（7 天）/ 超容量 → `cleanupStale`
  - 设置 → 清除缓存 → `DraftStore.clearAll()` + 媒体目录
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
| 存储增长（动态照片视频可达数十 MB） | 128MB 上限 + 7 天超期 + LRU；"清除缓存"入口接线 |
| 上传配额/频次限制（错误码 13 一类） | 懒重传 + 只重传正文仍引用的项，把重传次数压到最低 |
| 重传后正文替换失败（标签已被用户手改） | 保留原标签 + 记 warn 日志，不阻塞发送；该附件码按未引用丢弃（现有 `buildAttachmentParams` 行为） |
| 副本文件缺失（用户清了缓存/文件被删） | 视为"无法重传"→ 明确提示"草稿中的图片需要重新插入"，让用户重选，而不是发出一条图片失联的回复 |
| Picker URI 跨进程不可用 | 这正是"必须复制"的原因；复制发生在上传成功的同一会话内，此时 URI 授权仍然有效 |
| 从 Picker URI 复制文件 | 已查证本地 SDK（API 26）：`fileIo.copy(srcUri, destUri, options?)`（@since 11，面向 URI）与 `fileIo.copyFile(src, dest, mode?)` 均存在，无需退路；仍保留"读 buffer → 写文件"作为兜底 |

**回退**：四个阶段各自独立，任一阶段出问题就把该阶段的分支退回（例如阶段 3 失败 → 保留本地副本
但停用懒重传，行为回到今天的状态），不会让编辑器不可用。

---

## 6. 验收清单（真机）

1. 存草稿 → 杀进程 → 重开 → 正文恢复（阶段 1）
2. 传图 → 关闭 → 杀进程 → 重开 → 正文含 `[img]`，副本存在于 `draft_media/<key>/`（阶段 2）
3. 承上继续发送 → 帖子里的图片**正常显示**，且服务端附件区有这张图（阶段 3：新凭证有效）
4. 传一张动态照片 → 关闭 → 杀进程 → 重开 → 发送 → 动态照片在帖子中仍是动态照片
5. 传两张图，手工删掉其中一张的 `[img]` 标签 → 发送 → 只提交另一张（现有正文过滤 + 不浪费重传）
6. 断网状态点发送 → 停在编辑器、有明确提示；恢复网络重试成功（阶段 3 失败路径）
7. "放弃编辑" → 草稿与媒体目录都被清掉（阶段 4）
8. 设置 → 清除缓存 → `drafts` 与 `draft_media` 都被清空（阶段 1/2 接线）
9. 回归 `REVIEW_POST_API_MIGRATION.md` §7.5 的四条原路径（尤其"回复模式传图 → 切贴条 → 切回回复 → 发送"）

---

## 7. 不做什么

- **不做删图/删附件**（官方 `removeFromUploadedList` + 服务端 `del_attach`）：与草稿无关，
  是独立功能，避免把这次改动摊大。
- **不做"上传中互斥"以外的并发治理**：现有 `uploadingImage` 重入守卫已够。
- **不改上传协议本身**（字段、boundary、auth 语义）：本方案只在客户端侧增加副本与重传。
- **不动编辑（EDIT）场景的附件回填**：服务端 `attachArray` 语义未变。
