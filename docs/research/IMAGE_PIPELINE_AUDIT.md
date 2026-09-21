# 图片链路盘点（帖子图片 / 图片查看器）

> 盘点时间：2026-09 · 工程 API 26.0.0（HarmonyOS 26.0.0 Beta2）
> 本文只记录**已核实的事实**（本地 SDK 声明 / 本仓库源码 / 官方文档镜像原文），不含推断。
> 说明：本线（GIF/静态图优化）的汇总方案随需求转向「鸿蒙动态照片（MovingPhoto）」而作废，
> 同期的检索报告已删除；本文保留的现网实测事实与**尚未落地的缺陷清单**仍有参考价值。

---

## 1. 链路总览

```
NGA JSON (read.php __output=8)
  └─ BBCode 解析：handleImg.ets            [img]URL[/img] / [img]./mon_xxx[/img]
       ├─ guessMediaTypeFromExt()          按扩展名判 VIDEO/AUDIO/IMAGE（gif 归 IMAGE）
       └─ resolveImgTag()  AttachUrl.ets   官方判定 + 域归一化 + stripImageSuffix() → **原图 URL**
                                           （不可渲染时按官方退化为纯文本，不产出 IMAGE 节点）
  └─ HTML 降级解析：parser/nga/html-thread/*
  ▼
BBNode[] (type=IMAGE, src=绝对 URL)
  ▼
BBCodeContentView.RenderImageContent()    帖子正文图片
  ├─ 主动式：Image(src) + aspectRatio(占位比例) + LoadingProgress
  │    ├─ onComplete → onImageLoaded() → 进程内尺寸 LRU（ImageSizeUtil，容量 500）
  │    └─ onError    → markImageFailed()
  └─ 被动式（MANUAL / 非 WiFi）："点击查看图片" 占位条
  ▼ onImageClick(urls, index)
openImageViewer()  LinkUtils.ets → FloatingLayerStore → FloatingLayerComponent.ImageViewerCover()
  ▼ bindContentCover
ImageViewer.ets                            全屏查看器（前/中/后三张 Image）
  ├─ 缩放 1~8x、双击 2.5x、左右滑动切图、边缘 clamp
  ├─ 保存：http 重新下载 → filesDir 临时文件 → photoAccessHelper 存相册
  └─ 分享：http 重新下载 → filesDir 临时文件 → systemShare
```

其它图片位点：

| 位点 | 文件 | 现状 |
|---|---|---|
| 帖子附件区缩略图（100×100 网格） | `post-item/PostAttachments.ets:119` | `Image(att.attachurl)` 直连 |
| 头像 | `common/components/Avatar.ets` | `Image(url)` 直连（被动策略时显示首字母） |
| 资料卡头像 | `ProfileCardPopup.ets:261` | 点击进查看器 |
| 表情 | `common/media/EmotionResources.ets` | 本地 `$rawfile('emotions/**/*.png')`，**无动图** |
| 视频 | `common/media/MutedVideo.ets` | 内置 `Video` 组件（`posterOptions.showFirstFrame`，API 18+） |
| 图片加载策略 | `common/utils/NetworkUtil.ets:33` | ALWAYS / MANUAL / WIFI_ONLY |

---

## 2. 现状能力与缺口

### 2.1 已具备

- 帖子正文图片：加载占位（LoadingProgress）、宽高比占位（先按 16/9，onComplete 回填真实比例）、
  失败隐藏（`hideFailedImages`）、点击进查看器（正文全部图片一次性收集为可滑动列表）。
- 被动加载策略（省流量）与全局网络变化响应（`networkChangeVersion`）。
- 进程内图片尺寸缓存（`ImageSizeUtil`，LRU 500，仅尺寸不缓存位图）。
- 查看器：双指缩放 / 双击缩放 / 边界 clamp / 惯性 / 滑动切图 / 保存相册 / 系统分享。

### 2.2 缺口（按影响排序）

| # | 缺口 | 证据 / 位置 |
|---|---|---|
| G1 | **缓存不可观测、白块时间长**：`Image(src)` 直连网络 URL，虽由 Image 组件自带缓存（机制上依赖 cacheDownload，落在应用 `cache` 目录）承担二次加载，但官方明示该缓存"无法获取当前缓存占用信息/策略不可定制"，接口"后续不再继续演进"；且官方建议"下载的网络图片大于10MB或一次下载的网络图片数量较多时，用 HTTP 工具提前下载" | `guides/.../显示图片 (Image).md:47-61`（官方原文） |
| G2 | **无缩略图分级（服务端能力可用，客户端未用）**：解析时 `stripImageSuffix()` 把 `xxx.medium.jpg` 归一成**原图**；正文渲染与查看器用同一 URL。⚠️ **2026-09 复测更正**：服务端**确实**按后缀提供多档缩略图（`名字.原扩展名.thumb.jpg` / `.thumb_s.jpg` / `.thumb_ss.jpg` 均 200），此前"CDN 不提供缩略图"的结论源于当时只测了**不带 `.jpg` 的裸后缀**（见 §5.1）。主题列表预览图已按此实现，正文/查看器的分级仍是后续可选项 | `common/utils/Utils.ets:147`；`parser/_shared/AttachUrl.ets` 的 `resolveImgTag`；`docs/TOPIC_PREVIEW_DESIGN.md` §5 |
| G3 | **动图无任何专门处理**：无角标、无自动播放开关、查看器不能暂停/播放；依赖 Image 组件的默认行为 | `ImageViewer.ets`、`BBCodeContentView.ets:751` |
| G4 | 查看器保存/分享**重复下载**（http 全量拉取），且临时文件写在 `filesDir`（持久目录，无清理） | `ImageViewer.ets:84-167` |
| G5 | 查看器无加载进度/失败重试；长图（超高）无专门交互 | `ImageViewer.ets` |
| G6 | 大图无降采样：未使用 `sourceSize`，大图按原尺寸解码。**注意：动图救不了** —— 官方解码内存优化的格式表明确 `.gif .webp` **不支持下采样解码**，`sourceSize` 只对 `.jpg .png .heic` 有效 | `component/image.d.ts:1110`；`guides/媒体/.../图片解码内存优化(ArkTS).md:150-155` |

---

## 3. 官方能力对照（本地 SDK 已核实的原文证据）

### 3.1 Image 组件（`openharmony/ets/component/image.d.ts`）

- 行 368-372 / 1747-1751（类文档）：
  > Supported image formats include PNG, JPG, JPEG, BMP, SVG, WEBP, GIF, HEIF, and TIFF.
  > Note that the APNG and SVGA formats are not supported.
- 行 388-394 / 1767-1773（动图语义，原文）：
  > For animated images, animation playback is disabled by default and depends on the visibility of the
  > **Image** component. When the component is visible, the animation is started through the callback. When
  > the component is invisible, the animation is stopped. The visibility status of the Image component can be
  > identified through the onVisibleAreaChange event.
  对应中文镜像 `api/.../Image/Image.md:37-39`：
  > 动图的播放依赖于Image节点的可见性变化，其默认行为是不播放的。当节点可见时，通过回调启动动画，
  > 当节点不可见时，停止动画。
  → 语义为「不可见时不播放，可见时自动播放」，**动图无需额外代码即可播放**；离屏自动停止。
- `ImageErrorCallback` 行 1814-1817：**参数为 `AnimatedDrawableDescriptor` 时不触发 `onError`**（坑）。
- 可用属性：`alt`（行 785/818）、`sourceSize`（行 1110，解码尺寸，可降采样）、`syncLoad`（行 1136）、
  `interpolation`（行 1086）、`onFinish`（行 1577，SVG 动画 / descriptor 动画播放完成后触发）。
- `ImageCompleteCallback` 字段含 `componentWidth/componentHeight/contentWidth/contentHeight/loadingStatus`（行 1370/1448/1470）。

### 3.2 动图播放的三条官方通路

| 通路 | 声明位置 | 能力 | 网络 URL |
|---|---|---|---|
| A. `Image(url)` 直接播放 | `component/image.d.ts` | 自动播放、离屏自动停，**不可控制播放/暂停** | ✅ 支持 |
| B. `AnimatedDrawableDescriptor` + `Image(desc)` | `api/@ohos.arkui.drawableDescriptor.d.ts:489-539` | 可 `getAnimationController()` 控制 `start/stop/pause/resume`；`AnimationOptions{ duration, iterations, frameDurations(21+), autoPlay(21+), stopMode(24+) }` | ❌ `src` 仅支持应用资源 / 沙箱 `file://<bundleName>/<sandboxPath>` / Base64；PixelMap 数组需自行解码 |
| C. `ImageAnimator` + `ImageFrameInfo[]` | `component/image_animator.d.ts:73/183` | 逐帧播放，`src: string \| Resource \| PixelMap`（PixelMap 自 API 12），state/duration/fillMode/iterations 可控 | ❌ 需先把帧拿到本地/解码 |

关键补充：
- `Image` 加载 **PixelMap 时动图退化为静态图**（官方 `Image.md:2701` 原文："加载gif到PixelMap时，gif显示为静态图"），
  所以"自己解码再显示"必须配 B/C 通路，否则动图会静止。
- **官方给动图的优先级是 A（Image 直显）**：`Interface (ImageSource).md:1514`「此接口会一次性解码全部帧，当帧数过多或单帧图像过大时，会占用较大内存……**推荐使用 Image组件显示动图，Image组件采用逐帧解码，占用内存比此接口少**」。
- **通路 B 的"不生效清单"**（`Image.md`）：`alt` / `sourceSize` / `autoResize` / `syncLoad` / `copyOption` / `resizable` /
  `dynamicRangeMode` / `enableAnalyzer` 设置不生效；`onComplete` / `onError` / `onFinish` **三个事件都不触发**
  （`component/image.d.ts:1814-1817` 亦证实 `onError` 不触发）→ descriptor 路径必须自己在 `Image` 外面补占位与错误态。
- `onFinish` 官方语义**仅 SVG 动效**（"仅支持SVG格式的图片"）→ **GIF/WebP 播完不会触发 onFinish**。
- **`ImageAnimator` 与 `AnimatedDrawableDescriptor` 不存在官方配合用法**（`ImageAnimator.md` 全文不含该类型），二者并列选一；
  若用 `ImageAnimator`，必须显式 `.monitorInvisibleArea(true)`（默认 false，@since 17），
  否则会被官方功耗检测判为"前台不可见动效"（`Node skip` > 5 次/秒即异常，属上架审核扣分项）。
- **动图不支持下采样解码**：官方《图片解码内存优化》格式表列出的可降采样格式为 `.jpg .png .heic`，
  明确**不含 `.gif .webp`** → 动图内存无法用 `sourceSize` / `desiredSize` / `autoResize` 降低。

### 3.3 Image 组件的内建网络缓存（决定"要不要自己写缓存"）

`guides/应用框架/ArkUI（方舟UI框架）/UI开发 (ArkTS声明式开发范式)/媒体展示/显示图片 (Image)/显示图片 (Image).md:45-61` 官方原文：

- 「当前Image组件仅支持加载简单网络图片。」
- 「首次加载网络图片时，Image组件需要请求网络资源；**非首次加载时，默认从缓存中直接读取图片**。」
- 「Image组件目前**不支持查询磁盘缓存的实时状态**，包括文件总大小和文件数量。」「**缓存策略不可定制**，缺乏缓存状态观测能力……」
- 「网络图片**必须支持RFC 9113标准**，否则会导致加载失败。如果下载的网络图片**大于10MB**或一次下载的网络图片数量较多，**建议使用HTTP工具提前下载**。」
- 「在显示网络图片时，Image组件在机制上**依赖缓存下载模块**……缓存下载模块提供独立的预下载接口，允许应用开发者在创建Image组件前预下载所需图片。组件创建后，Image组件可直接从缓存下载模块中获取已下载的图片数据，从而加快图片的显示速度……**网络缓存的位置位于应用根目录下的cache目录中**。」
- 「对于复杂情况，推荐使用 ImageKnife（三方库）。」

→ 结论：**Image 组件本身已有磁盘缓存，不要自建一整套缓存**；但它不可观测、不可定制，
预下载（cacheDownload）是官方指定的增强手段，价值集中在"消除白块 / 控制瞬时并发 / 大图提前落地"。

### 3.4 官方缓存下载 `cacheDownload`（`api/@ohos.request.cacheDownload.d.ts`，@since 18，API 26 可用的 23/26 增量已有）

- `download(url, options): void`：**同步返回、不阻塞**；HTTP(S)，下载后存**内存缓存 + 文件缓存**；
  权限 `ohos.permission.INTERNET`；URL ≤ 8192 字节。
- **硬限制（行 382-383）**：解压后资源 > **20971520 字节（20 MB）** 则无法写入缓存。
- `CacheDownloadOptions`：`headers`、`sslType`、`caPath`、`cacheStrategy`（`FORCE` 默认 / `LAZY`，@since 23）、
  `retry`、`timeout`（后两者 @since 26.0.0）。
- 容量控制：`setMemoryCacheSize`（默认 0）、`setFileCacheSize`（默认 100 MB，上限 4 GB），均 LRU。
- 观测：`getDownloadInfo(url)`（需 `ohos.permission.GET_NETWORK_INFO`；`resource.size` 为 `-1` 表示下载失败）、
  `onDownloadSuccess` / `onDownloadError`（@since 23）、`clearMemoryCache` / `clearFileCache`（@since 23）。
- **与 Image 的联动（官方 `Image.md:2764-2805` 示例 3「下载与显示网络 gif 图片」）**：
  > 若src指定的是网络图片且已成功下载并缓存，则本次显示无需重复下载。
  即：先 `cacheDownload.download(url)` 预热，再 `Image(url)` 直接命中缓存（**GIF 走这条链路仍是动图**）。

本工程权限现状（`entry/src/main/module.json5`）：已声明 `ohos.permission.INTERNET` 与
`ohos.permission.GET_NETWORK_INFO`，**无需新增权限**。

### 3.5 Image Kit 解码（`api/@ohos.multimedia.image.d.ts`）

- `ImageSource`：`createPixelMap` / `createPixelMapSync` / `createPixelMapList`（行 12021/12066/12112）、
  `getDelayTimeList`（行 12131/12152）、`getFrameCount`（行 12186/12208）。
- **本地 SDK 全量检索未见 `createPixelMapAnimator` / `PixelMapAnimator`**（`PixelMapAnimator` 仅出现在
  `@ohos.arkui.drawableDescriptor.d.ts`、`component/image.d.ts`、`component/tab_content.d.ts`、`@kit.ArkUI.d.ts`），
  即 API 26 下"官方动图播放器对象"走的是 `AnimatedDrawableDescriptor`，不是 `ImageSource.createPixelMapAnimator`。

---

## 4. 待验证项（需真机/模拟器实测）

1. `Image(url)` 对**网络 GIF** 的实际表现：是否自动播放、首帧时机、离屏是否真的停止（官方文本语义已明确，但社区存在相反反馈）。
2. `Image(url)` 对 **animated WebP** 的表现（官方格式列表含 WEBP，但未区分静态/动图）。
3. `cacheDownload` 预热后 `Image(url)` 是否确实零重复下载（判断方式：抓包 / 服务端日志 / 断网复现）。
4. NGA **20 MB 以上图片**占比（超出 `cacheDownload` 缓存上限的降级路径）。
5. 动图在 `List`/`LazyForEach` 滚动场景下的 CPU/内存表现（一屏多张 GIF）。

---

## 5. 数据侧事实（已抓取核实）

- 真实帖子样本（`tools/bbcode-ts/samples/*.json`）中 `[img]` 扩展名分布：`jpg` 209 / `gif` 119 / `png` 116 /
  `mp4` 8 / `webp` 7（`gif` 计数含勋章等小图标 URL）。
- 真实抓取 7 个帖子（tid 44191387 / 47475364 / 47307683 / 47341103 / 47344482 / 46425481）中正文图片以 jpg 为主，
  唯一 webp 样本 `mon_202608/31/c4Q78-hxc3K22T3cSzj-134.webp` 经字节校验为 **VP8 静态 webp**（非动图，75 990 字节）。
- 结论：**动图（GIF/animated WebP）在真实帖子中占比不高但确实存在**，需要按"低频但不可缺"设计（不能因动图拖慢静态图主链路）。
- 样本中出现的 `.gif` 全部来自 `__MEDALS` 勋章图标表（如 `101.gif` 大漩涡、`442.gif` 二十周年），
  **不是帖子正文图片**；真正的帖子动图来自用户上传附件（`./mon_*/*.gif`）与外链图床。

### 5.1 NGA CDN 尺寸变体实测（2026-09，**同日复测更正**）

**首次记录（测法有偏差，保留备查）**：对 6 个真实附件 URL（新旧两种命名，jpg/png/webp）分别请求
`.medium` / `.thumb_s` / `.thumb_m` / `.thumb` 变体：

| 变体 | 结果 |
|---|---|
| 原图 | `206` + 正确 `content-type`（jpeg/png/webp） |
| `medium` / `thumb_s` / `thumb_m` / `thumb` | **全部 `404`**，响应体为 43 字节 GIF |

**复测更正**：有效性取决于**后缀写法**——档位后缀**必须带图片扩展名**
（`名字.原扩展名` + `.thumb.jpg`）。复测矩阵（真实附件，前缀 `https://img.nga.cn/attachments/`）：

| 请求 | 结果 |
|---|---|
| `…jpeg.thumb` / `…jpeg.medium` / `…jpeg.thumb_s` / `…jpeg.thumb_m`（**裸后缀**，即首次测法） | **404**（完全复现首次结论） |
| `…jpeg.thumb.jpg` | **200** 14 900 B（原图 292 164 B） |
| `…jpeg.thumb_s.jpg` / `…jpeg.thumb_ss.jpg` | 200 3 965 / 1 528 B |
| `…jpeg.medium.jpg` | 200 42 856 B |
| `…jpeg.thumb_m.jpg` | 404（该档位不存在） |
| 2020 年老 png + `.thumb.jpg` | 200 5 114 B（原图 108 379 B）→ **非近期上线** |

→ **更正**：**服务端按后缀提供多档缩略图**（`.thumb.jpg` / `.thumb_s.jpg` / `.thumb_ss.jpg` 对
jpg/jpeg/png/gif/webp/mp4 均有效；`.medium.jpg` 对 png/gif 会**回退原图**）。
`Utils.stripImageSuffix()` 的"去档位 → 原图"语义仍然正确且必要，但"服务端没有小图可取"不成立：
"列表用缩略图、查看器用原图"可以直接走服务端缩略图（客户端 `sourceSize` 仍是大图解码内存的正解）。
另两条实测禁用关系：`applyImageSuffix` 的 `name.thumb.ext`（尺寸词插在扩展名前）→ 404；
**裸后缀**（不带 `.jpg`）→ 404。完整数据与实现见 `docs/TOPIC_PREVIEW_DESIGN.md` §5。

### 5.2 图片失效时的真实表现（重要，已在现网验证）

对不存在的附件路径，CDN 返回 **HTTP 404 + `content-type: image/gif` + 43 字节 `GIF89a` 1×1 图**。

对 ArkUI `Image` 组件而言这**是一次成功的加载**：
- `onError` **不会触发** → `markImageFailed()` 永远不执行，`hideFailedImages` 形同虚设；
- `onComplete` 会以 `width=1, height=1` 回填 → `ImageSizeUtil` 尺寸缓存被污染，
  占位比例变成 `1:1`，帖子里出现一个**整行宽的方形空白块**。

→ 失效图判定必须增加"解码尺寸 ≤ 1px"这一条（或校验 HTTP 状态）才算完整，
这是当前帖子图片渲染的一个实际缺陷（与动图无关，但同属"帖子图片支持"范围）。

---

## 6. 已修复：两处图片闪烁（2026-09）

症状与根因都已核实，两处都属"图片节点被重建/解码结果被丢弃后需要**重新解码**，
解码完成前那一两帧是空白"这一类，但触发机制不同。

### 6.1 动态照片「未播放 ↔ 播放」切换闪一下

**根因**：`BBCodeContentView.RenderImageContent` 用 `if / else if` 在
「静态 `Image(src)`」与「`MovingPhotoPlayer`」之间**换枝**。ArkUI 的 `if` 换枝是
**销毁 + 新建节点**，新 `Image` 节点必须重新解码，解码完成前的一两帧空白即所见闪烁。
开关播放（`playingMovingPhotoSrc` 置位/清空）都会走一次换枝，所以**进出两个方向都闪**。
`MovingPhotoPlayer` 内部同样是「封面 `Image` ↔ `MovingPhotoView`」换枝，是第二处同源问题。

**修法（防闪烁契约）**：**静态封面常驻，播放器叠层**——
- 正文：`Image(src)` 去掉互斥分支、始终渲染；`MovingPhotoPlayer` 改为在其之上按条件叠加。
- 播放器：内部封面 `Image(coverUrl)` 常驻，`MovingPhotoView` 叠在其上。
- 因两者都是 `ImageFit.Contain` 且覆盖同一区域，播放时画面被完全盖住；播放器尚未出帧时
  露出的正是下面那张**已解码的**封面，两端都不会有空帧。动态照片因此在正文中**恒用
  `Contain`**（引用块也不例外），否则叠层与封面几何不一致会出现画面大小跳变。

→ 契约写在两处源码里：`BBCodeContentView.RenderImageContent` 与
`MovingPhotoPlayer` 类头「交互契约」；**改动其一必须同步另一处**。

### 6.2 进出图片查看器后帖子图片偶发闪一下

**根因**：系统的**图片解码缓存默认关闭**。SDK 声明（`@ohos.arkui.UIContext.d.ts`，
API 23+）原文：

> `setImageCacheCount`：Set image cache capacity of decoded image count.
> **if not set, the application will not cache any decoded image.**
> `setImageRawDataCacheSize`：**if not set, the application will not cache any raw image data.**

工程此前两处接口都没有调用 → 解码缓存为 0。打开查看器要同时解码当前图与左右相邻两张
全屏大图（`ImageViewer` 预渲染三张），内存压力下正文已解码的位图被回收；退出查看器后
正文 `Image` **重新解码**，那一两帧空白即闪烁。这解释了症状为何是**偶发**（取决于图片
大小与当时内存压力）而非必现。

**修法**：`EntryAbility.onWindowStageCreate` 的 `loadContent` 回调内调
`UIContext.setImageCacheCount(20)` + `setImageRawDataCacheSize(64MB)`（见
`enableImageDecodeCache`）。取 20 的理由写在常量注释里：缓存是 **LRU**，被挤掉的总是最久
未用的，而本诉求只关心"刚看过的那几张"（正文可见图 + 查看器相邻三张），20 张足够覆盖并留
余量；且正文图片 `autoResize` 默认为 **false**（按原图尺寸解码，见 §2.2 G6），单张位图内存
成本高——这也是**不能**取更大值的原因。**这是"内存 ↔ 闪烁"的取舍旋钮**：真机发现内存压力
优先下调（如 10），仍偶发闪烁再上调；改值须同步常量注释与本节记录。

**仍待真机确认**：6.2 是从官方"默认不缓存"+ 查看器解码三张大图推得的最强解释，能解释
偶发性，但改后需在真机反复进出查看器复核。若仍偶发，需再查"正文 `Image` 是否被重新创建"。
另：6.1 的叠层方案依赖"`MovingPhotoView` 出帧前不遮挡下层"，若真机发现其出帧前画**不透明
黑块**，则闪烁会变成黑闪，届时应改用官方 `onComplete`（the image load completed）信号
做显示闸门——注意**不能**用 `opacity` 动态属性实现该闸门：官方明确
「`MovingPhotoView`」**当前不支持动态属性设置**。
