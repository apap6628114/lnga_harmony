# NGA 动态照片（MPHOTO）× 鸿蒙动态照片（MovingPhoto）接入方案 v1.0

> 事实依据：本地 SDK 声明（API 26.0.0.105）、官方文档镜像（API 23）、NGA 现网实证（抓帖 + 浏览器实渲染）。
> 详细调研见 `MOVING_PHOTO_SDK_API.md`、`MOVING_PHOTO_GUIDE.md`；图片侧现网实测与遗留缺陷见
> `IMAGE_PIPELINE_AUDIT.md`（本次不再重复）。

---

## 0. 结论摘要

1. **NGA 已经支持动态照片**，且形态对客户端极友好：帖子里是**两个独立资源**——
   `[img]封面.jpg[/img]` + `[b]MPHOTO[/b]` + `[flash=video]视频.mp4[/flash]`（现网实证，见 §1）。
2. **鸿蒙的动态照片模型正好是"图片 + 短视频"两份资源**：`MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri)`
   可从**应用沙箱的两个文件**构造 `MovingPhoto`（**无需任何权限**），再交给 `MovingPhotoView` 播放
   （`@kit.MediaLibraryKit`，@since 12；API 20→26 无接口变化）。
   → **NGA 的数据形态与鸿蒙的能力刚好对上**，这是本次接入成立的根本原因。
3. **组件不吃网络 URL**：`MovingPhotoView` 只接收构造完成的 `MovingPhoto` 对象；网络/ArrayBuffer/单文件都不支持。
   所以必须**下载封面 + 视频到沙箱**再构造。
4. **项目当前的渲染是"三块并列"**（实证解析结果）：封面图 → 粗体文字 `MPHOTO` → 视频播放器。
   用户会看到多余的 `MPHOTO` 字样，且封面与视频互不关联 —— 这就是要接入的部分。
5. **官方网页也不合并**（实测 DOM：`<img>` + `<span style="font-weight:bold">MPHOTO</span>` + `<video preload=none muted onclick=autoplayVideo>`），
   而 **NGA 官方 App 是合并的**（用户反馈"点一下左上角的图标就能动"）—— 我们按 App 体验对齐。
6. 有一条**零新 API 的轻量路线**（封面 `Image` + 点击用现有 `MutedVideo`/`Video` 播 mp4），
   可在模拟器验证；系统动态照片路线（`MovingPhotoView`）**只能在真机验证**（官方明确不支持模拟器/Previewer）。

---

## 1. NGA 动态照片的现网实证

抓取帖子 `tid=47553967`（标题："鸿蒙ANGA加入动图了？！"）的楼层原文：

```
[img]./mon_202609/14/k2Q43-i6ydK2nT3cSyw-x5.jpg[/img]<br/><br/>试一试<br/>
[img]./mon_202609/14/k2Q43-ikqiK2jT3cSsg-lc.jpg[/img][b]MPHOTO[/b][flash=video]./mon_202609/14/k2Q43-2ul5Z27T6wS1hc-140.mp4[/flash]
[img]./mon_202609/14/k2Q43-jca4ZcT3cSsg-lc.jpg[/img][b]MPHOTO[/b][flash=video]./mon_202609/14/k2Q43-9wy5Z2rT6wS1hc-140.mp4[/flash]
```

**官方网页真实 DOM**（浏览器实渲染 `#postcontent0`）：

```html
<img data-srclazy="…k2Q43-ikqiK2jT3cSsg-lc.jpg" data-nw="1024" data-nh="768">   <!-- 封面（懒加载） -->
<span style="font-weight:bold">MPHOTO</span>                                    <!-- 标记：网页端就是粗体文字 -->
<video playsinline preload="none" muted="true"
       src="https://img.nga.cn/attachments/…-140.mp4"
       poster="https://img.nga.cn/attachments/…-140.mp4.medium.jpg"              <!-- 视频海报规律：<mp4url>.medium.jpg -->
       data-playlazy="1" style="background:#423d35; width:1920px; height:1440px;"
       onclick="ubbcode.autoplayVideo(event,this)"></video>
```

官方 `ubbcode.autoplayVideo` 源码（`js_bbscode_core.js` 实抓）：

```js
autoplayVideo = function(e, o) {
  if (e.type == 'play') { o._pl = (o._pl|0)+1;
    if (o._pl > 5 && window.__APPEMBED) { ubbcode.embedCallOpenPic(o.getAttribute('data-argi'), o.src, null); o.pause() } }
  else if (e.type == 'pause' || e.type == 'ended') { o._stopTime = performance.now();
    setTimeout(function(){ o.controls = 0 }, 2000) }          // 停 2 秒后隐藏控制条
  else if (e.type == 'click') { if (!o.controls) o.controls = 1;
    setTimeout(function(){ if (o._stopTime && (performance.now()-o._stopTime) > 120) o.play() }, 10) }
}
```

**项目解析器现状**（用真实内容跑 `parseBBCode`）：

| 节点 | 类型 | 内容 |
|---|---|---|
| `type=9` IMAGE | 封面 | `…k2Q43-ikqiK2jT3cSsg-lc.jpg` |
| `type=1` BOLD → `type=0` TEXT | **多余的 "MPHOTO" 文字** | 会原样渲染出来 |
| `type=21` VIDEO | 视频 | `…k2Q43-2ul5Z27T6wS1hc-140.mp4` |

→ 现状 = 封面图 + 文字噪音 + 独立视频播放器；**没有"动态照片"这个概念**。

---

## 2. 鸿蒙侧能力（已逐条核对本地 SDK）

| 能力 | 签名 | 出处 |
|---|---|---|
| 动态照片组件 | `MovingPhotoView({ movingPhoto, controller?, imageAIOptions? })` | `@ohos.multimedia.movingphotoview.d.ts:29-81`，@since 12 |
| 属性 | `muted` / `objectFit`（@12）；`autoPlayPeriod(s,e)` / `autoPlay(bool)` / `repeatPlay(bool)`（@13）；`enableAnalyzer`（@18） | 同上 :113/124/214/226/238/250 |
| 事件 | `onStart` / `onStop` / `onPause` / `onFinish` / `onError`（@12）、`onComplete`（@13）、`onPrepared`（@20） | 同上 :135-201 |
| 控制器 | `MovingPhotoViewController`：`startPlayback()` / `stopPlayback()` / `refreshMovingPhoto()`（@18） | 同上 :260-297 |
| **沙箱构造** | `MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri): Promise<MovingPhoto>` —— **无权限标注** | `@ohos.file.photoAccessHelper.d.ts:718-737`，@since 12 |
| 相册构造 | `MediaAssetManager.requestMovingPhoto(context, asset, options, handler)` —— 需 `READ_IMAGEVIDEO`（Picker 豁免） | 同上 :649-671 |
| 导出内容 | `MovingPhoto.requestContent(ResourceType.IMAGE_RESOURCE / VIDEO_RESOURCE)`（落盘或取 ArrayBuffer） | 同上 :5198/5220/5241 |
| 类型识别 | `PhotoSubtype.MOVING_PHOTO = 3`；MIME `'image/movingPhoto'` | 同上 :208 / :3590 |
| 拍摄端（背景） | `PhotoOutput.isMovingPhotoSupported()`、`enableMovingPhoto(bool)`、`setMovingPhotoVideoCodecType()` | `@ohos.multimedia.camera.d.ts:6129/6143/5760` |
| 导入 | `import { MovingPhotoView, MovingPhotoViewController, photoAccessHelper } from '@kit.MediaLibraryKit'` | `@kit.MediaLibraryKit.d.ts:21/25` |

**必须知道的约束**（官方原文/声明）：

- **只认沙箱两文件或相册资产**：网络 URL、ArrayBuffer、单文件（含 HEIC 私有封装）**都不支持**；
  官方原话「MovingPhoto 对象需要通过 photoAccessHelper 接口创建或获取，MovingPhotoView 只接收构造完成的 MovingPhoto 对象」。
- **HEIC 私有封装不可逆向**：华为开发者问答明确 `LIVE_` 尾标/私有 MP4 Box/`timed_metadata` 属系统实现细节，
  「仅靠逆向字节布局无法保证相册兼容性」→ **单文件动态照片只能当静态图**。
- `autoPlay` **默认 false** → 默认只显示静态封面（低功耗默认，正好适合列表）。
- `repeatPlay` 与 `autoPlay`/长按播放**互斥**；`controller.stopPlayback()` 停止后**从头播**（没有 pause）。
- 事件回调**不带任何参数**（没有进度/错误码/时长）。
- 内部用 AVPlayer，官方**不建议同时开启超过 3 个**；**不支持预览器**、**不支持 expandSafeArea**、**不支持动态属性设置**；
  长按播放时组件区域放大 **1.1 倍**。
- 动态照片的视频时长官方限 **≤ 10s**。

---

## 3. 两条实现路线

### 路线 A：系统动态照片（`MovingPhotoView`）——"真·鸿蒙动态照片"

```
帖子节点（封面 URL + 视频 URL）
  └─ 用户点击"动态照片"角标 / 在查看器打开
       ├─ 下载封面 jpg + 视频 mp4 到 cacheDir（懒加载 + 磁盘缓存复用）
       ├─ MediaAssetManager.loadMovingPhoto(ctx, 'file://'+coverPath, 'file://'+videoPath)
       └─ MovingPhotoView({ movingPhoto, controller })
            .muted(true)  .autoPlay(true)  .objectFit(ImageFit.Contain)  .repeatPlay(false)
```

- ✅ 与系统相册一致的动态照片体验（长按播放、1.1 倍放大、播完回静态帧）
- ⚠️ 每次播放需**下载两份资源**并落盘（流量/存储成本），必须做缓存与清理
- ⚠️ **仅真机可验证**（不支持模拟器/Previewer）
- ⚠️ 同屏 AVPlayer 实例 ≤3 → 帖子列表**不能**用它，只用于查看器 / 单个详情位

### 路线 B：轻量播放（封面 `Image` + `Video` 播 mp4）

```
帖子节点：Image(封面) + 左上角"动态照片"图标（点击）
  └─ 查看器 / 就地：MutedVideo 或 Video 组件播放 mp4（现有能力，零新 API）
```

- ✅ 零新 API、复用 `MutedVideo`（`posterOptions.showFirstFrame` 已有）、模拟器可验证
- ✅ 视频按需加载，不必强制下载封面（封面本来就要显示）
- ⚠️ 不是系统动态照片组件（但**与 NGA 官方网页的行为一致**：就是 img + video）

### 推荐组合（分层）

| 位置 | 做法 |
|---|---|
| 帖子列表 / 正文 | 封面 `Image` + 左上角"动图/动态照片"角标；**不自动播放**（对齐官方 App"点一下才动"） |
| 点击角标或图片 | 进查看器；查看器内按 **路线 A** 播放（真机），A 不可用时降级 **路线 B** |
| 缩略图 | 一律静态封面（避免同时多个 AVPlayer） |

---

## 4. 改动点清单

### 4.1 识别动态照片（解析层聚合，推荐）

`[img]封面[/img]` + `[b]MPHOTO[/b]` + `[flash=video]视频[/flash]` 三元组折叠为一个节点：

- `tools/bbcode-ts/src/model/BBCodeNode.ts`：`BBNode` 新增字段 `videoSrc: string`（默认 `''`）
- `tools/bbcode-ts/src/parser/bbcode/`：块级解析完成后新增一个 **MPHOTO 折叠 pass**
  （容忍中间空白文本；`MPHOTO` 大小写不敏感；**不匹配就原样保留**，安全降级）
- 快照基线更新（`npm run snapshot` → 人工审查 diff）
- **必须走镜像门禁**：`npm test` → `npm run sync` → `sync-to-ets.mjs --dry` 为 0 修改
- HTML 降级解析路径需同步（`parser/nga/html-thread/*`，确认是否复用同一解析器）

> 备选（不动镜像）：在渲染层 `BBCodeContentView` 里做三元组折叠。缺点是要跨 `NodeGroup`
> （`BOLD(TEXT)` 属 inline 组、前后是 block 组）处理，复杂度并不更低，且 JSON/HTML 两条路径各改一次。

### 4.2 渲染

| 文件 | 改动 |
|---|---|
| `common/components/BBCodeContentView.ets` | `IMAGE` 节点带 `videoSrc` → 渲染"封面 + 动态照片角标"；点击把 `(封面, 视频)` 一起交给查看器 |
| `common/components/ImageViewer.ets` | 接收 `(cover, video)` 配对；显示播放按钮；播放实现按 §3 路线 A/B |
| `common/media/MovingPhotoPlayer.ets`（新增） | 下载两份到 `cacheDir` → `loadMovingPhoto` → `MovingPhotoView` 封装；含去重、缓存命中、失败降级、`stopPlayback()` 生命周期 |
| `common/media/ImageSizeUtil.ets` / `Utils.ets` | 视频海报 URL 规律 `<mp4url>.medium.jpg` 可用于占位（可选） |
| `resources/*/element/string.json` + `media` | "动态照片"文案与角标图标（两种语言/深浅色） |

### 4.3 测试

- `tools/bbcode-ts/tests/`：MPHOTO 折叠的单元测试（正例、缺视频、大小写、夹空白、伪 MPHOTO 文本）
- `entry/src/test/*.test.ets`：Hypium 回归（折叠语义 + 降级）
- 新样本：把 `tid=47553967` 该楼固化为样本（真实数据）

---

## 5. 风险与验证计划

| 风险 | 说明 | 处置 |
|---|---|---|
| 只能真机验证 | `MovingPhotoView` 不支持模拟器/Previewer | 路线 B 保底；路线 A 用真机验收 |
| 下载成本翻倍 | 播放动态照片需同时下载封面 + 视频 | 懒加载：仅查看器打开时下载；`cacheDir` 复用 + 过期清理 |
| AVPlayer 实例上限 | 官方不建议 >3 | 列表不用 A；查看器同一时刻只保留 1 个 |
| 长按放大 1.1 倍 | 布局需留空间 | 查看器居中留白，或改用角标点击播放 |
| `expandSafeArea` 不支持 | 查看器全屏沉浸布局可能受影响 | 实测；必要时用 `Image` 垫底 + 组件内嵌 |
| MPHOTO 语义变化 | NGA 可能调整标记 | 折叠失败即降级为"封面 + 视频"两块（现状行为） |

**验证顺序**：解析折叠（Node 侧可验证）→ 编译 → 模拟器验证路线 B（封面/角标/视频播放）→
真机验证路线 A（`loadMovingPhoto` + `MovingPhotoView`）。

---

## 6. 待用户决策

| # | 问题 | 选项 |
|---|---|---|
| D1 | 播放实现 | **(a) 路线 A 系统动态照片**（真机体验最佳，需下载两份、只能真机验证）<br>**(b) 路线 B 轻量视频播放**（零新 API、模拟器可验、与官方网页一致）<br>**(c) 两者都做**：查看器优先 A，A 失败降级 B |
| D2 | 帖子内交互 | **(a) 封面 + 角标，点击进查看器播放**（推荐，对齐官方 App"点一下才动"）<br>**(b) 帖子内就地播放**（点击直接在原位播放视频） |
| D3 | 解析实现位置 | **(a) 解析层折叠**（走镜像门禁，JSON/HTML 一致，推荐）<br>**(b) 渲染层折叠**（不动镜像真源） |
| D4 | 实测 | 是否允许构建 + 装模拟器验证路线 B；路线 A 是否需要连真机 |

---

## 7. 实现记录（v1.0 已落地，真机验证通过）

### 7.1 数据链路（含一次真实事故）

```
解析 tools/bbcode-ts/src/parser/bbcode/moving-photo.ts
  └─ foldMovingPhotos：IMAGE(封面) + BOLD(MPHOTO) + VIDEO(视频) → IMAGE{src, videoSrc}
       ├─ 挂载点：parser.ts::parseBlockNodes（顶层与所有嵌套块级层级的公共出口）
       └─ 容错：三元组不完整 → 原样保留（退化为"封面图 + 文字 + 视频"）
  ▼ taskpool（解析预热在工作线程）
BBCodeParseTask.BBNodeJSON  ← **事故点**：契约漏字段 → videoSrc 丢失 → 图标/播放全失效
  ▼ 主线程
BBCodeCache.jsonToBBNode    ← 逐字段重建，必须同步新字段（同类点：PostComments.filterBBTags）
  ▼
BBCodeContentView.collectUrls → MovingPhotoRegistry.registerMovingPhoto(封面 → 视频)
  ▼
渲染：IMAGE{videoSrc≠''} → 左上角图标；点击 → 就地 MovingPhotoPlayer
  ▼
ImageViewer：按当前封面地址 getMovingPhotoVideo() 反查 → MovingPhotoPlayer（进入自动播一次）
```

**教训**：解析层新增字段时，必须同时更新**所有跨线程序列化契约与逐字段重建点**；
Node 门禁（`npm test`）直接调 `parseBBCode()`，会绕过 taskpool 往返，
"Node 通过"不等于"端到端生效"。

### 7.2 交互契约（播放状态机）

```
loading ──成功──▶ ready ──onPrepared 后播放──▶ playing ──播完──▶ ready
   └──失败──▶ failed（保留静态封面，不显示图标）
```

**核心约定：播放入口只有左上角图标；图片本体的长按不注册操作。**

| 阶段 | 图标 | 点击图标 | 点击图片 | 长按 |
|---|---|---|---|---|
| loading | 常驻，半透明 0.55 | 排队（就绪后播放一次） | 帖子内 → 收起播放器并打开查看器；查看器内 → 无操作 | 无操作 |
| ready | 常驻，白色 | **播放一次** | 同上 | 无操作 |
| playing | 常驻，**琥珀色高亮** | **忽略**（不重播、不终止） | 同上 | 无操作 |
| failed | 不显示 | 忽略 | 同上 | 无操作 |

实现要点：

- **★ 播放必须等 `onPrepared`**：事件顺序是 `onComplete`（**图片**就绪）→ `onPrepared`（**播放器**就绪），
  真机实测相差约 **150ms**；在 `onComplete` 里调 `controller.startPlayback()` 会**静默打空**
  （图标进入"播放中"、画面不动、`onFinish` 永不到达）。自动播放与"加载中点击"都只置
  `pendingAutoPlay`，由 `onPrepared` 消费，另配 1200ms 兜底定时器防"点击永久失效"。
- **★ `startPlayback()` 之后要等 `onStart` 确认**：打空是静默的，因此 `playRequested` 只在收到
  `onStart` 后才转为 `phase = playing`；`PLAYBACK_START_TIMEOUT_MS`（2.5s）内没等到就复位为
  ready，避免"假播放中"长时间挂着；播放中另有 `PLAYBACK_TIMEOUT_MS`（15s）看门狗兜底复位。
- **同一时刻只有一个播放器实例**：`MovingPhotoView` 内部是 AVPlayer（官方建议同时 ≤3），
  而楼层列表用 `LazyForEach + cachedCount`、滚出屏幕的组件不会销毁 —— 模块级 `PlaybackArbiter`
  让新实例抢占旧实例（旧实例停播并收起），`onVisibleAreaChange` 不可见即停播收起。
- **播放只由图标触发**：查看器不自动播放（`autoPlayOnce` 仅帖子内使用——点图标展开播放器并立即播放一次）。
- **图片长按不注册操作**：`MovingPhotoView` 自带"长按播放"，用 `.hitTestBehavior(HitTestMode.None)`
  屏蔽组件自身手势（事件穿透给父容器，查看器左右滑动切图不受影响）；所有图片 `Image` 加
  `.draggable(false)`（Image 自 API 10 起 `draggable` 默认 `true`，长按会被系统当成拖拽图片）。
- **图片点击透传**：内部图片不绑定点击，事件穿透到根 `Stack`，由 `onBodyClick` 交给父组件
  （帖子内 ＝ 收起播放器并打开查看器；查看器内不传回调 ＝ 无操作）。
- **播放一次** = `autoPlay(false)` + `repeatPlay(false)` + `startPlayback()`（官方语义：播完回静态帧）。
- **沙箱缓存**：`filesDir/mphoto/`（`MovingPhotoCache.ets` 单源；官方指南的 `loadMovingPhoto`
  示例也用 `filesDir`）。并发下载按目标路径去重、写 `.part` 后 `renameSync` 原子替换、
  缓存命中校验 `size > 0`；超过 120 个文件按 mtime 淘汰最旧一半；该目录已接入设置页「清除缓存」。
- 图标位置与尺寸：帖子内贴图片左上角 `position(6,6)`、**40vp**；查看器贴内容区左上角 `position(16,12)`、**44vp**。

### 7.3 图标

`resources/base/media/icon_live_photo.svg`：**点状环（10 段短线）+ 中心播放三角**（24 网格，纯 `fill` path，
保证 `fillColor` 运行时着色）。白色 = 可播放，琥珀色（`AppColors.primary`）= 播放中。

**底板不画进 SVG，改在渲染层做**：`fillColor` 会替换 SVG 内**所有**可绘制元素的 `fill`，
底圆若画进资源里会被一起染成前景色（撑成一块不透的白盘、把图形吃掉）。因此底板由图标外的 `Stack` 承担
—— 圆形实底（`moving_photo_badge_bg`，50% 黑、深浅色同值，因为它永远叠在图片而非应用底色上）
+ 一圈 1vp 细描边（`moving_photo_badge_border`，33% 白）。描边是"按钮感"的关键：底板是**半透明**黑，
压在暗色或杂乱画面上时边界会糊掉、只剩一团脏影；细白线负责在任何底图上都框出按钮轮廓，
与视频右上角静音按钮（`rgba(0,0,0,0.5)` 圆底）同款。静态角标与 `MovingPhotoPlayer` 的图标
共用同一套底板参数（尺寸随 `iconSize`），保证播放器接管前后不跳动。

**播放态切换禁止换枝（防闪烁契约）**：正文的静态 `Image(src)` 与播放器内部的封面
`Image(coverUrl)` 都必须**常驻**，播放器（`MovingPhotoPlayer` / 其内的 `MovingPhotoView`）
只以**叠层**方式按条件叠加。原因：ArkUI 的 `if/else` 换枝是销毁 + 新建节点，新 `Image`
节点要重新解码，解码完成前那一两帧空白就是"未播放 ↔ 播放互相切换时闪一下"。
因叠层与封面同为 `ImageFit.Contain` 且覆盖同一区域，播放时封面被完全盖住；
播放器尚未出帧时露出的正是下面那张已解码的封面，两端都无空帧。
契约同时写在 `BBCodeContentView.RenderImageContent` 与 `MovingPhotoPlayer` 类头，
**改动其一必须同步另一处**。另注：`MovingPhotoView`「当前不支持动态属性设置」（官方约束），
因此**不要**用 `opacity` 之类的动态属性给它做显示闸门——真机会直接不生效。

### 7.4 落地文件

| 文件 | 说明 |
|---|---|
| `tools/bbcode-ts/src/parser/bbcode/moving-photo.ts` | 折叠真源（镜像同步为 `.ets`） |
| `tools/bbcode-ts/src/model/BBCodeNode.ts` | `BBNode.videoSrc` 字段 |
| `tools/bbcode-ts/src/parser/bbcode/parser.ts` | `parseBlockNodes` 出口接入折叠 |
| `entry/src/main/ets/parser/task/BBCodeParseTask.ets` | taskpool 传输契约补字段 |
| `entry/src/main/ets/parser/bbcode/BBCodeCache.ets` | 重建时拷贝字段 |
| `entry/src/main/ets/common/media/MovingPhotoRegistry.ets` | 封面 → 视频 进程内注册表 |
| `entry/src/main/ets/common/media/MovingPhotoPlayer.ets` | 下载 → `loadMovingPhoto` → `MovingPhotoView` + 状态机 |
| `entry/src/main/ets/common/components/BBCodeContentView.ets` | 正文图标 + 就地播放 |
| `entry/src/main/ets/common/components/ImageViewer.ets` | 查看器播放（自动一次 + 图标常驻） |

### 7.5 测试与门禁

- `tools/bbcode-ts/tests/invariants.test.ts`：7 个折叠用例（真实样本、相邻形式不受影响、不完整降级、大小写与空白、伪标记不误判、列表项内折叠）；`npm test` **208 通过 / 0 失败**
- `entry/src/test/BBCodeUnit.test.ets`：3 个 Hypium 用例（`foldsMovingPhotoTriple` / `keepsIncompleteTripleUnfolded` /
  `foldsMovingPhotoInsideListItem`）；`hvigorw test` 汇总 **Tests run 327 / Pass 327 / Failure 0 / Error 0**
- 样本 `samples/tid47553967-lou0-mphoto.txt`（真实帖）+ 快照；快照仅两张动态照片带 `videoSrc`
- 镜像门禁：`npm test` → `npm run sync` → `sync-to-ets.mjs --dry` = 0 修改；`check-eol.mjs` OK
- DevEco `assembleHap` 成功 + 真机安装/启动验证

---

## 8. 独立审查与修复记录

真机验证通过后，两位独立审查者（一位查功能正确性、一位查工程规范，均不带本实现上下文、只读审查）
各自独立跑门禁并给出结论；五条硬纪律（镜像 / ArkTS / 行尾 / 解析契约 / 资源）全部达标、无阻断项。
以下是审查出的问题与处理：

| 问题 | 后果 | 处理 |
|---|---|---|
| 同一文件并发下载无去重（查看器相邻两张都是动态照片时 `@Watch` 触发两次；正文下载中打开查看器） | 后到者读到**未写完**的文件交给 `loadMovingPhoto` → 失败且坏文件被永久命中；失败分支还会删掉别人正在用的文件 | ✅ 按目标路径 `inFlightDownloads` 去重 + 写 `.part` 后 `renameSync` 原子替换 + 命中校验 `size > 0` + 失败只删自己的临时文件 |
| `prepare()` 缺代际守卫 | 快速切图时两次准备交错，旧结果覆盖新源（工程已有 `PageScope.isActive` 契约却只用了 `isAlive`） | ✅ 捕获 `begin()` 代际 + `isActive(generation)` |
| AVPlayer 实例可累积 | 楼层列表 `LazyForEach + cachedCount` 下滚出屏幕不销毁，逐个点开可超官方建议的 3 个 | ✅ 模块级 `PlaybackArbiter`（同一时刻只允许一个实例持有播放器，被抢占者停播并收起）+ `onVisibleAreaChange` 不可见即停播 |
| `[list]` 内三元组不折叠 | 列表项正文走 `parseBlockNodesUntil` 绕过折叠（实测确认） | ✅ `parseListItems` 补调用 + Node/Hypium 用例 |
| 加载中点击无兜底 | 兜底定时器只在 `autoPlayOnce` 分支注册，查看器若 `onPrepared` 不再到达则点击永久失效 | ✅ 统一到 `requestPendingAutoPlay()`（置标记即注册定时器） |
| "假播放中"最长 15s | `playOnce` 直接置 playing、不看 `onStart` 确认 | ✅ `playRequested` 只在 `onStart` 后转 playing；2.5s 启动看门狗超时即复位 |
| `onStop`/`onPause` 不回调 | 正文播放被中断后不收起播放器 | ✅ 均回调 `onPlaybackFinish` |
| 缓存目录不在"清除缓存"范围 | `filesDir/mphoto` 是持久目录，设置页清不掉 | ✅ 抽 `MovingPhotoCache.ets` 单源 + 接入 `SettingsPanel.clearCache` |
| `pruneCache` 全量清空 | 40 张即全清 → 反复重下载；且会删掉在用文件 | ✅ 按 mtime 淘汰最旧一半 + 跳过 in-flight |
| `hashUrl` 32 位截断 | 不同 URL 碰撞会静默串图 | ✅ FNV-1a + URL 长度前缀 |
| 缺 Hypium 回归 | 本次事故点（taskpool 契约）恰好只有 ArkTS 侧能覆盖 | ✅ 3 个用例（含列表内折叠） |
| `PostComments` 漏 `inheritedFormatTags` | 与 `videoSrc` 完全同模式的既有漏字段 | ✅ 一并补齐 |
| 文档与实现 3 处不一致 | 查看器自动播放、播放态点击图片、缓存目录 | ✅ §7.2 已重写 |
| 诊断日志噪音 | 7 个事件 info + `onAreaChange` | ✅ 降 `verbose` 并移除诊断日志 |

**记录待决策（未改）**：`docs/research` 文档是否收敛为 `docs/*_DESIGN.md` 并入索引；
`registerMovingPhoto` 目前挂在 `collectUrls()` 内（方法是查询语义却带登记副作用）；
`PHASE_*` 是否改为工程惯用的 `enum`；查看器「保存/分享」对动态照片只导出静态封面；
`draggable(false)` 属全量行为变更（本次按需求"长按不注册操作"施加到所有正文图与查看器图）。
另有既有隐患（非本次引入）：`BBCodeCache.preWarmBatchAwait` 在 `addTask` 失败时
`results` 与 `toParse` 索引错位，会串位写缓存。
