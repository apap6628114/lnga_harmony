# 鸿蒙动态照片（MovingPhoto / Live Photo）本地 SDK 声明全链路 API 报告

> **调研对象**：鸿蒙动态照片（MovingPhoto / Live Photo，「拍摄时记录快门前后的短视频」）。
> **明确排除**：GIF / WebP 动图与多帧图片（另有报告，本报告不重复，仅在必须交叉处点名）。
> **唯一权威依据**：本地 DevEco SDK 声明文件。逐条给「文件路径:行号」+ **签名原文照抄**。
> 记忆知识只作为待验证候选，验证不到的一律标注 **「本地声明未见」**。
>
> 工程：NGA 论坛鸿蒙客户端 `C:\Users\ll\Desktop\nga_oh`，stage 模型，
> `build-profile.json5:22` `"targetSdkVersion": "26.0.0"`、`:23` `"compatibleSdkVersion": "26.0.0"`、
> `:24` `"runtimeOS": "HarmonyOS"`。

## 0. SDK 版本锚点与检索基线

**SDK 根**：`C:\Program Files\Huawei\DevEco Studio\sdk\default`（下称 `<SDK>`）

`<SDK>\openharmony\ets\oh-uni-package.json`（原文，节选）：

```json
{
  "apiVersion": "26",
  "displayName": "Ets",
  "path": "ets",
  "platformVersion": "26.0.0",
  "releaseType": "Release",
  "version": "26.0.0.105"
}
```

→ 本地 SDK = **API 26 / HarmonyOS 26.0.0 Release（26.0.0.105）**，高于工程 target 26.0.0 的要求，
本报告中所有 `@since ≤ 26` 的动态照片 API 在本工程**均处于可用版本区间**。

**全量检索命令与结果**（`grep -i movingphoto`，覆盖 `<SDK>\openharmony\ets` 与 `<SDK>\hms\ets` 的全部
`.d.ts` / `.d.ets`）：命中且含符号定义的文件只有 **4 个**：

| 文件（相对 `<SDK>`） | 角色 |
|---|---|
| `openharmony\ets\api\@ohos.multimedia.movingphotoview.d.ts` | **ArkUI 组件 `MovingPhotoView` 唯一声明处（316 行，全文已逐行核对）** |
| `openharmony\ets\api\@ohos.file.photoAccessHelper.d.ts` | **`MovingPhoto` 数据对象 + 取数入口（5583 行）** |
| `openharmony\ets\api\@ohos.multimedia.camera.d.ts` | 动态照片**拍摄**能力（7604 行） |
| `openharmony\ets\kits\@kit.MediaLibraryKit.d.ts` | 组件与类型再导出（import 路径） |

另有 `<SDK>\openharmony\ets\build-tools\ets-loader\kit_configs\@kit.MediaLibraryKit.json` 的符号绑定表可作交叉验证。

> ⚠️ **关键否证（HMS 侧）**：`<SDK>\hms\ets\api` 与 `<SDK>\hms\ets\kits` 下**没有任何动态照片符号**。
> 任务前提中「动态照片很可能只在 HMS 侧」**不成立** —— 动态照片能力全部在 **OpenHarmony（AOSP 基线）ETS API** 中，
> HMS 侧既无 `@hms.*` 动态照片模块，也无华为专有扩展。这反而是**好消息**：能力对全部应用开放，不依赖 HMS Core。

**关键否证汇总（全部为「本地声明未见」，且已用 grep 全 SDK 复核）**：

| 候选符号 | 结果 |
|---|---|
| `camera.PhotoOutput.confirmMovingPhotoCapture` | **本地声明未见** |
| `camera.MovingPhotoStatus` | **本地声明未见** |
| `photoAccessHelper.MovingPhoto.readMovingPhotoVideo` | **本地声明未见** |
| `photoAccessHelper.MovingPhoto.getMovingPhotoImageUri` / `getVideoUri` | **本地声明未见** |
| `photoAccessHelper.PhotoAsset.getMovingPhoto` | **本地声明未见** |
| `image.MovingPhoto` / `image.MovingPhotoView` | **本地声明未见** |
| 网络 URL 起播动态照片的任何 API（`MovingPhotoViewOptions` 无 url 字段） | **本地声明未见** |
| `OpenHarmony js` 侧同名 API 是否是另一套 | `openharmony\js\api\@ohos.multimedia.movingphotoview.d.ts` 与 ets 版 **逐字节同构**（均 316 行，`Compare-Object` 零差异）；工程用 ets，后文只述 ets |

全 SDK 范围内动态照片「动词型」API 穷举（共 **6** 个，无遗漏）：

```
@ohos.file.photoAccessHelper.d.ts:671   static requestMovingPhoto(...): Promise<string>;
@ohos.file.photoAccessHelper.d.ts:737   static loadMovingPhoto(...): Promise<MovingPhoto>;
@ohos.multimedia.camera.d.ts:5750       getSupportedMovingPhotoVideoCodecTypes(): Array<VideoCodecType>;
@ohos.multimedia.camera.d.ts:5760       setMovingPhotoVideoCodecType(codecType: VideoCodecType): void;
@ohos.multimedia.camera.d.ts:6129       isMovingPhotoSupported(): boolean;
@ohos.multimedia.camera.d.ts:6143       enableMovingPhoto(enabled: boolean): void;
```

---

## 1. `@ohos.multimedia.movingphotoview.d.ts` —— ArkUI 组件（最核心产出）

**文件**：`<SDK>\openharmony\ets\api\@ohos.multimedia.movingphotoview.d.ts`（316 行）

文件头（`:15-19` 原文）：

```ts
/**
 * @file A component which support applications to show moving photo data
 * @kit MediaLibraryKit
 */
import photoAccessHelper from './@ohos.file.photoAccessHelper';
```

> 注意：该文件**没有** `export default`，也**没有** `declare namespace movingPhoto`。
> 只有 `MovingPhotoViewController` 是 `export class`（`:260`），其余全部是**全局声明**（`declare interface` /
> `declare class` / `declare const`），因此 `import movingPhotoView from '@ohos.multimedia.movingphotoview'`
> 在 ArkTS 中**取不到组件**；正确写法见 §6。

### 1.1 `MovingPhotoViewOptions`（构造参数，`:20-60`）

```ts
29: declare interface MovingPhotoViewOptions {
39:     movingPhoto: photoAccessHelper.MovingPhoto;
49:     controller?: MovingPhotoViewController;
59:     imageAIOptions?: ImageAIOptions;
60: }
```

| 行 | 成员原文 | @since | 其它标注 |
|---|---|---|---|
| `:29` | `declare interface MovingPhotoViewOptions {` | 12 | `@syscap SystemCapability.FileManagement.PhotoAccessHelper.Core`、`@crossplatform`、`@atomicservice`（`:24-27`） |
| `:39` | `movingPhoto: photoAccessHelper.MovingPhoto;` | 12 | 同上（`:34-37`）；**必填，类型是 `photoAccessHelper.MovingPhoto` 对象，不是 string/URI** |
| `:49` | `controller?: MovingPhotoViewController;` | 12 | 同上（`:44-47`） |
| `:59` | `imageAIOptions?: ImageAIOptions;` | 18 | 同上（`:54-57`） |

> `ImageAIOptions` 来自 **ArkUI 组件层**（`<SDK>\openharmony\ets\component\image.d.ts:542,551,559,564`、
> `component\canvas.d.ts:3441,3482,3484,3491`），不是 image kit 类型；全局可用。

### 1.2 `MovingPhotoViewInterface`（`:61-82`）

```ts
70: interface MovingPhotoViewInterface {
81:     (options: MovingPhotoViewOptions): MovingPhotoViewAttribute;
82: }
```

| 行 | 原文 | @since | 标注 |
|---|---|---|---|
| `:70` | `interface MovingPhotoViewInterface {` | 12 | `@crossplatform`、`@atomicservice`（`:65-68`） |
| `:81` | `(options: MovingPhotoViewOptions): MovingPhotoViewAttribute;` | 12 | `@crossplatform`、`@atomicservice`（`:76-79`） |

### 1.3 事件回调类型 `MovingPhotoViewEventCallback`（`:83-92`）

```ts
92: declare type MovingPhotoViewEventCallback = () => void;
```

`@since 12`（`:90`）、`@crossplatform`、`@atomicservice`（`:87-89`）。
**注意：回调不带任何参数**（无 error 对象、无进度）——`onError` 也不例外，只能知道「失败了」，拿不到错误码。

### 1.4 `MovingPhotoViewAttribute` 完整成员清单（`:93-251`）

```ts
102: declare class MovingPhotoViewAttribute extends CommonMethod<MovingPhotoViewAttribute> {
```

`@extends CommonMethod<MovingPhotoViewAttribute>`、`@since 12`、`@crossplatform`、`@atomicservice`（`:96-100`）。
**继承 `CommonMethod` → 全部通用属性（`.width/.height/.borderRadius/...`）与通用事件可用。**

| # | 行 | 签名原文 | @since | 语义（注释原文摘要） |
|---|---|---|---|---|
| 1 | `:113` | `muted(isMuted: boolean): MovingPhotoViewAttribute;` | 12 | 是否静音（`:104` "judging whether the video is muted"） |
| 2 | `:124` | `objectFit(value: ImageFit): MovingPhotoViewAttribute;` | 12 | 缩放模式（`:115` "determining the zoom type of the view"） |
| 3 | `:135` | `onComplete(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | **13** | 图片加载完成（`:126` "the image load completed"） |
| 4 | `:146` | `onStart(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | 12 | 视频开始播放（`:137`） |
| 5 | `:157` | `onStop(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | 12 | 播放停止（`:148`） |
| 6 | `:168` | `onPause(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | 12 | 播放暂停（`:159`） |
| 7 | `:179` | `onFinish(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | 12 | 播放结束（`:170`） |
| 8 | `:190` | `onError(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | 12 | 播放失败（`:181`，**无错误参数**） |
| 9 | `:201` | `onPrepared(callback: MovingPhotoViewEventCallback): MovingPhotoViewAttribute;` | **20** | 播放准备完成（`:192`） |
| 10 | `:214` | `autoPlayPeriod(startTime: number, endTime: number): MovingPhotoViewAttribute;` | **13** | 自动播放区间；不设则播全片（`:203-204`） |
| 11 | `:226` | `autoPlay(isAutoPlay: boolean): MovingPhotoViewAttribute;` | **13** | 资源加载完自动起播（`:216-217`） |
| 12 | `:238` | `repeatPlay(isRepeatPlay: boolean): MovingPhotoViewAttribute;` | **13** | 循环播放（`:228-229`） |
| 13 | `:250` | `enableAnalyzer(enabled: boolean): MovingPhotoViewAttribute;` | **18** | 允许 AI 分析（`:240-241`） |

**成员总数 13**，全部标 `@syscap SystemCapability.FileManagement.PhotoAccessHelper.Core` + `@crossplatform` + `@atomicservice`。
**全文无 `@systemapi`、无 `@deprecated`、无 `@permission`、无 `@stagemodelonly`**（已 grep 复核，命中 0）。

### 1.5 `MovingPhotoViewController`（`:252-297`）

```ts
260: export class MovingPhotoViewController {
269:     constructor();
278:     startPlayback();
287:     stopPlayback();
296:     refreshMovingPhoto();
297: }
```

| 行 | 原文 | @since | 标注 |
|---|---|---|---|
| `:260` | `export class MovingPhotoViewController {` | 12 | `@crossplatform`、`@atomicservice`（`:255-258`） |
| `:269` | `constructor();` | 12 | 同上 |
| `:278` | `startPlayback();` | 12 | 手动起播（`:271` "Start play moving photo"） |
| `:287` | `stopPlayback();` | 12 | 手动停播（`:280`） |
| `:296` | `refreshMovingPhoto();` | **18** | 刷新动态照片数据（`:289` "refresh moving photo data"） |

> 无返回类型、无参数、无 `Promise`（即**同步 void**）。`refreshMovingPhoto()` 用于同一 controller 换数据后重载。

### 1.6 组件常量（`:298-316`）

```ts
307: declare const MovingPhotoView: MovingPhotoViewInterface;
316: declare const MovingPhotoViewInstance: MovingPhotoViewAttribute;
```

| 行 | 原文 | @since | 标注 |
|---|---|---|---|
| `:307` | `declare const MovingPhotoView: MovingPhotoViewInterface;` | 12 | `@uicomponent`（`:304`）、`@crossplatform`、`@atomicservice`（`:301-305`） |
| `:316` | `declare const MovingPhotoViewInstance: MovingPhotoViewAttribute;` | 12 | `@crossplatform`、`@atomicservice`（`:311-314`） |

> `@uicomponent` 标记确证这是**真正的 ArkUI 声明式组件**（可 `MovingPhotoView({...}).muted(true)` 链式调用）。

### 1.7 版本推进一览（`@since` 分布）

- **API 12**（首发）：`MovingPhotoView` 组件本体、`MovingPhotoViewOptions{movingPhoto, controller}`、`muted`、`objectFit`、`onStart/onStop/onPause/onFinish/onError`、controller 三方法中两个。
- **API 13**：`onComplete`、`autoPlayPeriod`、`autoPlay`、`repeatPlay`。
- **API 18**：`imageAIOptions`、`enableAnalyzer`、`refreshMovingPhoto`。
- **API 20**：`onPrepared`。
- **API 21–26：该文件零新增**（全文无 `@since 21/22/23/24/25/26`）→ 组件能力自 API 20 起冻结至 API 26。

---

## 2. `photoAccessHelper`（`@ohos.file.photoAccessHelper.d.ts`）中的 MovingPhoto

**文件**：`<SDK>\openharmony\ets\api\@ohos.file.photoAccessHelper.d.ts`（5583 行）
模块头 `:15-18` 原文：`@file Helper functions to access image and video assets` / `@kit MediaLibraryKit`；
`:32` `declare namespace photoAccessHelper {`（`@since 10`，`@crossplatform [since 12]`，`@atomicservice [since 11]`）。

### 2.1 `interface MovingPhoto` —— 全部成员（只有 4 个，`:5167-5255`）

```ts
5167:     /**
5168:      * MovingPhoto provides APIs for managing a moving photo instance.
5169:      *
5170:      * @syscap SystemCapability.FileManagement.PhotoAccessHelper.Core
5171:      * @atomicservice
5172:      * @since 12
5173:      */
5174:     interface MovingPhoto {
5198:         requestContent(imageFileUri: string, videoFileUri: string): Promise<void>;
5220:         requestContent(resourceType: ResourceType, fileUri: string): Promise<void>;
5241:         requestContent(resourceType: ResourceType): Promise<ArrayBuffer>;
5254:         getUri(): string;
5255:     }
```

| 行 | 签名原文 | @since | 权限 / 异常 |
|---|---|---|---|
| `:5174` | `interface MovingPhoto {` | 12 | `@atomicservice`；**无 `@stagemodelonly`**（`:5170-5171`） |
| `:5198` | `requestContent(imageFileUri: string, videoFileUri: string): Promise<void>;` | 12 | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5179`）；`201 Permission denied`、`401 Parameter error`、`14000011 System inner fail`（`:5185-5193`） |
| `:5220` | `requestContent(resourceType: ResourceType, fileUri: string): Promise<void>;` | 12 | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5203`）；同上异常（`:5207-5215`） |
| `:5241` | `requestContent(resourceType: ResourceType): Promise<ArrayBuffer>;` | 12 | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5225`）；同上异常（`:5228-5236`） |
| `:5254` | `getUri(): string;` | 12 | **无权限标注**；异常仅 `401`、`14000011`（`:5246-5249`） |

**参数语义（注释原文关键句）**：

- `:5176` `Requests the image data and video data of this moving photo and writes them to the specified URIs, respectively.`
- `:5181` 图片示例 `"file://com.example.temptest/data/storage/el2/base/haps/ImageFile.jpg"`
- `:5183` 视频示例 `"file://com.example.temptest/data/storage/el2/base/haps/VideoFile.mp4"`

→ **动态照片 = 「一张 JPEG/HEIF 图 + 一个 MP4 视频」两个资源**，不是单一文件。这是本节最重要的结构结论，
并由 native 声明交叉证实（`<SDK>\openharmony\native\sysroot\usr\include\multimedia\media_library\moving_photo_capi.h:61-66`：
`Requests the image data and video data of a moving photo and writes them to the specified URIs, respectively.` /
`@param imageUri ... to which the image data is written.` / `@param videoUri ... to which the video data is written.`）

**`ResourceType`（写哪一半）** —— `<同文件>:4537-4554`：

```ts
4537:     enum ResourceType {
4545:         IMAGE_RESOURCE = 1,
4553:         VIDEO_RESOURCE = 2
4554:     }
```

（`:4537` `@since 11`、`@atomicservice`；两个取值各自 `@since 11`）

> 于是「取一帧封面」= `requestContent(ResourceType.IMAGE_RESOURCE): Promise<ArrayBuffer>`
> → 交给 `image.createImageSource(arrayBuffer)` 即可（image kit 侧，见 §4）。
> 「取视频」= `requestContent(ResourceType.VIDEO_RESOURCE): Promise<ArrayBuffer>`（MP4 字节）。
> 这两条让**无权限依赖的封面渲染**成为可能（`getUri()` 与 `Image(movingPhoto.getUri())` 亦可，见 §7）。

### 2.2 `MediaAssetManager`：动态照片的两个**入口**（唯二构造 `MovingPhoto` 的途径）

`:579` `class MediaAssetManager {`（`@since 11`，`@atomicservice [since 14]`，`:575-577`）

```ts
671:         static requestMovingPhoto(context: Context, asset: PhotoAsset, requestOptions: RequestOptions, dataHandler: MediaAssetDataHandler<MovingPhoto>): Promise<string>;
737:         static loadMovingPhoto(context: Context, imageFileUri: string, videoFileUri: string): Promise<MovingPhoto>;
```

| 行 | 签名原文 | @since | 权限 / 异常 / 标注 |
|---|---|---|---|
| `:671` | `static requestMovingPhoto(context: Context, asset: PhotoAsset, requestOptions: RequestOptions, dataHandler: MediaAssetDataHandler<MovingPhoto>): Promise<string>;` | 12 | `@permission ohos.permission.READ_IMAGEVIDEO`（`:653`）；`201`、`401`、`801 Capability not supported. [since 18]`（`:666`）、`14000011`；**入参是 `PhotoAsset`（媒体库资产）** |
| `:737` | `static loadMovingPhoto(context: Context, imageFileUri: string, videoFileUri: string): Promise<MovingPhoto>;` | 12（`@atomicservice [since 14]`，`:734`） | **无 `@permission` 标注**；异常仅 `401`、`14000011 Internal system error`（`:728-732`）；注释 `:719` `Loads a moving photo in the application sandbox.` |

**`loadMovingPhoto` 的两条 URI 语义（注释原文 `:721-727`）**：

```
721:          * @param { Context } context - AbilityContext or UIExtensionContext instance.
722:          * @param { string } imageFileUri - URI of the image file of the moving photo in the application sandbox.
723:          *     <br>Example: **'file://com.example.temptest/data/storage/el2/base/haps/ImageFile.jpg'**.
724:          * @param { string } videoFileUri - URI of the video file of the moving photo in the application sandbox.
725:          *     <br>Example: 'file://com.example.temptest/data/storage/el2/base/haps/VideoFile.mp4'.
726:          * @returns { Promise<MovingPhoto> } Promise used to return the
727:          *     [MovingPhoto]{@link @ohos.file.photoAccessHelper:photoAccessHelper} instance.
```

→ **沙箱播放的唯一通路，且要求「两个沙箱文件 URL」**（不是 http/https URL，也不是单个文件）。
这条是 §7(b) 与 §7(a) 的分水岭。

**`MediaAssetDataHandler<T>`（回调形状，`:511-544`）**

```ts
518:     interface MediaAssetDataHandler<T> {
543:         onDataPrepared(data: T, map?: Map<string, string>): void;
544:     }
```

`:523-527` 原文明确列出 `T` 支持的类型：

```
523:          * T supports the following data types: ArrayBuffer, [ImageSource]{@link @ohos.multimedia.image:image.ImageSource},
524:          * [MovingPhoto]{@link @ohos.file.photoAccessHelper:photoAccessHelper}, and boolean. ArrayBuffer indicates the image
525:          * or video asset data, [ImageSource]{@link @ohos.multimedia.image:image.ImageSource} indicates the image source,
526:          * [MovingPhoto]{@link @ohos.file.photoAccessHelper:photoAccessHelper} indicates a moving photo object, and boolean
527:          *          * indicates whether the image or video is successfully written to the application sandbox directory.
```

`map` 目前只保证 `'quality'` 键（`:531-533`）。

**`RequestOptions`** —— `:486-510`，**全部字段仅 3 个**：

```ts
486:     interface RequestOptions {
493:         deliveryMode: DeliveryMode;
502:         compatibleMode?: CompatibleMode;
509:         mediaAssetProgressHandler?: MediaAssetProgressHandler;
510:     }
```

→ **没有任何 URL / 网络字段**（`@since 11` / `15` / `15`）。请求对象只能来自媒体库资产，不能来自远端。

### 2.3 `PhotoAsset` 上与动态照片有关的成员（结论：**没有专用成员**）

`:769` `interface PhotoAsset {` 的**全部自身成员**（用正则扫过 `:769-1412` 区间，共 15 条）：

```
779:  readonly uri: string;
788:  readonly photoType: PhotoType;
797:  readonly displayName: string;
813:  get(member: string): MemberType;
837:  set(member: string, value: string): void;
857:  commitModify(callback: AsyncCallback<void>): void;
875:  commitModify(): Promise<void>;
898:  getReadOnlyFd(callback: AsyncCallback<number>): void;
920:  getReadOnlyFd(): Promise<number>;
938:  close(fd: number, callback: AsyncCallback<void>): void;
955:  close(fd: number): Promise<void>;
973:  getThumbnail(callback: AsyncCallback<image.PixelMap>): void;
993:  getThumbnail(size: image.Size, callback: AsyncCallback<image.PixelMap>): void;
1011: getThumbnail(size?: image.Size): Promise<image.PixelMap>;
1037: clone(title: string): Promise<PhotoAsset>;
```

- **`getMovingPhoto` / `getMovingPhotoImageUri` / `getVideoUri`：本地声明未见**（grep `MovingPhoto` 在 `PhotoAsset` 体内零命中）。
- 动态照片属性只能走**泛型 `get()`**（`:813` `get(member: string): MemberType;`），键名来自 `PhotoKeys`：

```ts
1071:  PHOTO_TYPE = 'media_type',
1121:  DURATION = 'duration',
1216:  PHOTO_SUBTYPE = 'subtype',
1224:  DYNAMIC_RANGE_TYPE = 'dynamic_range_type',
1240:  BURST_KEY = 'burst_key',
1287:  MEDIA_SUFFIX = 'media_suffix',
```
（`<同文件>:1041` `interface PhotoKeys {` 起；`:1210` 注释 `Subtype of the media file.`）

**`mediaType` 是否含 `MOVING_PHOTO`？→ 否。** `PhotoType`（`:165-184`）只有两个值：

```ts
165:     enum PhotoType {
174:         IMAGE = 1,
183:         VIDEO = 2
184:     }
```

**动态照片是「图片的一个 subtype」，不是第三种 PhotoType** —— `PhotoSubtype`（`:192-217`）：

```ts
192:     export enum PhotoSubtype {
200:         DEFAULT = 0,
208:         MOVING_PHOTO = 3,
216:         BURST = 4
217:     }
```

（`:192` `@since 12`、`@atomicservice`；`MOVING_PHOTO = 3` 对应 `:208`，`:201-207` 注释 `Moving photo.`）

→ **判定某个资产是不是动态照片的官方姿势**：`asset.get(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE)` 返回
`PhotoSubtype.MOVING_PHOTO`(=3)（`MemberType = number | string | boolean`，`:753`）。

**MIME 常量（可用于过滤/判定）** —— `PhotoViewMIMETypes`（`:3547-3591`）：

```ts
3555:     export enum PhotoViewMIMETypes {
3564:         IMAGE_TYPE = 'image/*',
3573:         VIDEO_TYPE = 'video/*',
3582:         IMAGE_VIDEO_TYPE = '*/*',
3590:         MOVING_PHOTO_IMAGE_TYPE = 'image/movingPhoto'
3591:     }
```

`:3590` `MOVING_PHOTO_IMAGE_TYPE = 'image/movingPhoto'`，`@since 12`、`@atomicservice`（`:3586-3589`）。
经全 SDK grep，**`'image/movingPhoto'` 字面量在整个 ets api 目录仅此 1 处定义** —— 它是动态照片的
**事实标准 MIME**，但注意它标的是「动态照片里的那一半图片」，不是独立文件类型。

### 2.4 `PhotoCreationConfig` / `CreationSetting` / `CreateOptions` 中的动态照片字段

```ts
1412:     interface PhotoCreationConfig {
1426:         title?: string;
1434:         fileNameExtension: string;
1443:         photoType: PhotoType;
1452:         subtype?: PhotoSubtype;
1453:     }
```

| 行 | 原文 | @since | 说明 |
|---|---|---|---|
| `:1412` | `interface PhotoCreationConfig {` | 12 | `@atomicservice`（`:1408-1410`） |
| `:1434` | `fileNameExtension: string;` | 12 | 注释 `:1428` `File name extension, for example, 'jpg'.` |
| `:1443` | `photoType: PhotoType;` | 12 | 注释 `:1436-1437` `Type of the file to create, which can be IMAGE or VIDEO.` |
| `:1452` | `subtype?: PhotoSubtype;` | 12 | 注释 `:1444-1446` `Image or video file subtype. The default value is DEFAULT.` → **`subtype: PhotoSubtype.MOVING_PHOTO` 即把新资产建成动态照片** |

**`CreationSetting`（API 23 的新版创建配置）—— 注意它 *没有* subtype 字段**：

```ts
1463:     export interface CreationSetting {
1479:         title?: string;
1488:         fileNameExtension: string;
1498:         photoType: PhotoType;
1499:     }
```

（`:1463` `@stagemodelonly`、`@atomicservice`、`@since 23`，`:1458-1461`）→ 新版创建配置**丢失了 `subtype`**，
所以「把沙箱里的一对图文写成动态照片」目前只能走 `PhotoCreationConfig`（`:1412`）+ `MediaAssetChangeRequest.addResource`。

**`CreateOptions`** —— `:1513-1531`：`title?: string;`（`:1522`）、`subtype?: PhotoSubtype;`（`:1530`，`@since 12`）。

### 2.5 `MediaAssetChangeRequest` 中与动态照片有关的签名

`:4761` `class MediaAssetChangeRequest implements MediaChangeRequest {`（`@since 11`、`@atomicservice`，`:4755-4760`）

```ts
4976:         addResource(type: ResourceType, fileUri: string): void;
4997:         addResource(type: ResourceType, data: ArrayBuffer): void;
5006:         saveCameraPhoto(): void;
```

| 行 | 签名原文 | @since | 动态照片注释原文 |
|---|---|---|---|
| `:4976` | `addResource(type: ResourceType, fileUri: string): void;` | 11 | `:4959` `> For a moving photo, you can call this API twice to add the image and video resources.`（`:4956-4959` 整段 NOTE） |
| `:4997` | `addResource(type: ResourceType, data: ArrayBuffer): void;` | 11 | `:4983` `> For a moving photo, you can call this API twice to add the image and video resources.` |
| `:5006` | `saveCameraPhoto(): void;` | 12 | 注释 `:4999` `Saves the photo taken by the camera.`（`:5007` 另有 `saveCameraPhoto(imageFileType: ImageFileType)` 重载，见 kit 元数据） |

创建请求的工厂（`kit` 元数据列出，同文件 `MediaAssetChangeRequest` 静态段）：
`static createAssetRequest(context, photoType, extension, options?): MediaAssetChangeRequest`、
`static createImageAssetRequest(context, fileUri)`、`static createVideoAssetRequest(context, fileUri)`。

**`ImageFileType`（`:4561-4576`）**：`JPEG = 1`（`:4568`）、`HEIF = 2`（`:4575`），`@since 13`。

### 2.6 媒体库侧「动态照片」辅助能力（API 22/23 新增，非播放链路，但涉及选择器行为）

```ts
3854:         isMovingPhotoBadgeShown?: boolean;
3899:         globalMovingPhotoState?: MovingPhotoBadgeStateType;
3937:     export enum MovingPhotoBadgeStateType {
3946:         NOT_MOVING_PHOTO = 0,
3955:         MOVING_PHOTO_ENABLED = 1,
3964:         MOVING_PHOTO_DISABLED = 2
3965:     }
4432:         movingPhotoBadgeStates: Array<MovingPhotoBadgeStateType>;
3827:         combinedMediaTypeFilter?: Array<string>;
3880:         autoPlayScenes?: Array<AutoPlayScene>;
```

| 行 | 原文 | @since | 归属 / 说明 |
|---|---|---|---|
| `:3854` | `isMovingPhotoBadgeShown?: boolean;` | 22 | `BaseSelectOptions`；`:3846-3847` `Note: Use both isMovingPhotoBadgeShown and MovingPhotoBadgeStateType to determine whether a photo is a moving photo.` |
| `:3899` | `globalMovingPhotoState?: MovingPhotoBadgeStateType;` | 23 | `BaseSelectOptions`；`:3891-3892` `Global effect of the moving photo. Currently, only MOVING_PHOTO_ENABLED and MOVING_PHOTO_DISABLED are supported. The default value is MOVING_PHOTO_ENABLED.` |
| `:3937` | `export enum MovingPhotoBadgeStateType {` | 22 | 三种状态见上，`:3939` 注释 `The media file is not a moving photo.` |
| `:3964` | `MOVING_PHOTO_DISABLED = 2` | 22 | `The moving photo effect is disabled.` |
| `:4432` | `movingPhotoBadgeStates: Array<MovingPhotoBadgeStateType>;` | 22 | `PhotoSelectResult`；`@atomicservice`，`:4425-4426` 仅当 `isMovingPhotoBadgeShown=true` 才非空 |
| `:3827` | `combinedMediaTypeFilter?: Array<string>;` | 20 | `:3807` 格式 `photoType | photoSubType1,photoSubType2, ... | mimeType1,mimeType2, ...`；`:3811` **`Options include movingPhoto or "*" (ignore).`** → 可按 `"image\|movingPhoto\|*"` 精准筛动态照片 |
| `:3880` | `autoPlayScenes?: Array<AutoPlayScene>;` | 23 | `:4264-4283` `export class AutoPlayScene { sceneType: SceneType; playMode: PlayMode; }`；`SceneType`（`:5293-5312`）`GRID_TO_PHOTO_BROWSER = 0` / `PHOTO_BROWSER_SWIPE = 1`；`PlayMode`（`:5380-5399`）`DEFAULT = 0` / `AUTO_PLAY = 1` —— **影响的是系统相册/选择器场景的自动播放，不是 `MovingPhotoView`** |

`MediaLibraryKit` 的 `PhotoPickerComponent.d.ets` 侧还有（用于选择器集成）：
`:147` `onMovingPhotoBadgeStateChanged?: MovingPhotoBadgeStateChangedCallback;`（`@since 22`，`:142`）、
`:379` `setMovingPhotoState(movingPhotoState: photoAccessHelper.MovingPhotoBadgeStateType): Promise<void>;`（`PickerController`，`@since 23`）、
`:744` `movingPhotoBadgeState?: photoAccessHelper.MovingPhotoBadgeStateType;`（`@since 22`）、
`:1238` `movingPhotoBadgeStates: Array<photoAccessHelper.MovingPhotoBadgeStateType>;`（`@since 26.0.0`）、
`:1717` `export type MovingPhotoBadgeStateChangedCallback = (uri: string, state: photoAccessHelper.MovingPhotoBadgeStateType) => void;`（`@since 22`）。

---

## 3. Camera Kit（`@ohos.multimedia.camera.d.ts`）动态照片**拍摄**

**文件**：`<SDK>\openharmony\ets\api\@ohos.multimedia.camera.d.ts`（7604 行）
动态照片相关符号**共 4 个**，全部在 `PhotoOutput` 或其邻域：

```ts
5684:     interface PhotoOutput extends CameraOutput {
5750:         getSupportedMovingPhotoVideoCodecTypes(): Array<VideoCodecType>;
5760:         setMovingPhotoVideoCodecType(codecType: VideoCodecType): void;
6129:         isMovingPhotoSupported(): boolean;
6143:         enableMovingPhoto(enabled: boolean): void;
```

| 行 | 签名原文 | @since | 标注 / 异常 |
|---|---|---|---|
| `:5684` | `interface PhotoOutput extends CameraOutput {` | 10 | `@atomicservice [since 19]`、`@syscap SystemCapability.Multimedia.Camera.Core`（`:5680-5683`） |
| `:5750` | `getSupportedMovingPhotoVideoCodecTypes(): Array<VideoCodecType>;` | **13** | `@atomicservice [since 19]`（`:5747`）；`@returns` 注释 `:5743-5744` `Array holding the supported video codec types. If the API call fails, undefined is returned.`；`@throws 7400201`（`:5745`） |
| `:5760` | `setMovingPhotoVideoCodecType(codecType: VideoCodecType): void;` | **13** | `@atomicservice [since 19]`（`:5757`）；`@throws 7400201`（`:5755`）；**无权限** |
| `:6129` | `isMovingPhotoSupported(): boolean;` | **12** | `@atomicservice [since 19]`（`:6126`）；注释 `:6122-6123` `**true** if supported, **false** otherwise. If the API call fails, undefined is returned.`；`@throws 7400201`（`:6124`） |
| `:6143` | `enableMovingPhoto(enabled: boolean): void;` | **12** | **`@permission ohos.permission.MICROPHONE`（`:6133`）** ← 唯一被要求权限的动态照片 API；`@throws 201 permission denied.`（`:6136`）、`7400101`、`7400201`（`:6137-6138`）；`@atomicservice [since 19]`（`:6140`） |

**`VideoCodecType`（动态照片视频编码，`:5651-5675`）**：

```ts
5658:     enum VideoCodecType {
5666:         AVC = 0,
5674:         HEVC = 1
5675:     }
```

（`:5658` `@since 13`、`@atomicservice [since 19]`；`AVC` = H.264，`HEVC` = H.265）

**`PhotoCaptureSetting`（`:5540-5584`）—— 与动态照片**无**专用字段**：

```ts
5540:     interface PhotoCaptureSetting {
5548:         quality?: QualityLevel;
5556:         rotation?: ImageRotation;
5564:         location?: Location;
5574:         mirror?: boolean;
5583:         compressionQuality?: number;
5584:     }
```

→ **动态照片不是通过 `capture(setting)` 的参数开启的**，而是通过 `PhotoOutput.enableMovingPhoto(true)` 开启输出模式
（`:6143`），之后照常 `capture()`（`:5725` / `:5739`）。全文 grep `confirmMovingPhoto`、`MovingPhotoStatus` 均
**0 命中**；`:5853` 仅在 `isMirrorSupported` 的注释里提到 `isMovingPhotoSupported`。

**格式相关（供参考，非动态照片专有）** `CameraFormat`（`:1598-1663`）：`CAMERA_FORMAT_JPEG = 2000`（`:1630`）、
`CAMERA_FORMAT_HEIC = 2003`（`:1654`，`@since 13`）、`CAMERA_FORMAT_YUV_420_SP = 1003`（`:1622`）、
`CAMERA_FORMAT_YCBCR_P010`（`:1638`）等。`cameraPicker`（`@ohos.multimedia.cameraPicker.d.ts`）**无任何动态照片符号**（grep 0 命中）。

---

## 4. Image Kit（`@ohos.multimedia.image.d.ts`）与动态照片 / HEIF

> 本节由子调研员独立复核（grep 大小写不敏感 `moving.?photo` / `live.?photo`），结论如下。

### 4.1 动态照片符号：**基本没有，只有 1 个元数据常量**

```ts
9820:      * Capture mode: moving photos.The value is 20.
9826:     const CAPTURE_MODE_MOVING_PHOTO: number;
```

（所在段落 `:9762-9858` 全为 `const CAPTURE_MODE_*: number;`，均 `@stagemodelonly @since 23`）
关联字段：`:728-736` `enum PropertyKey` 的 `CAPTURE_MODE = 'HwMnoteCaptureMode',`（`@since 10`）、
`:10166-10174` `captureMode?: number;`（`MakerNoteHuaweiMetadata`，`@stagemodelonly @since 23`）。

→ **`image.MovingPhoto` 类型本地声明未见；`image` 无任何 `movingPhoto` 成员/方法；无 `livePhoto`/`LivePhoto` 符号。**
`CAPTURE_MODE_MOVING_PHOTO` 只是**华为 XMAGE 拍摄模式元数据**（`@stagemodelonly`），不是播放/解码动态照片的能力。

### 4.2 「区分动图/多帧」的可用抓手（**不能识别动态照片**）

`interface ImageSource`（`:11724-12743`）中与多帧有关的成员：

| 行 | 签名原文 | 注释要点 |
|---|---|---|
| `:12186` | `getFrameCount(): Promise<number>;` | `@since 10` |
| `:12208` | `getFrameCount(callback: AsyncCallback<number>): void;` | `@since 10` |
| `:12021` | `createPixelMapList(options?: DecodingOptions): Promise<Array<PixelMap>>;` | `:11982-11983` 原文 `For dynamic images such as GIF and WebP images, this API returns the data of each frame of the image.` |
| `:12131` | `getDelayTimeList(): Promise<Array<number>>;` | `@since 10`，注释限定 **GIF 或 WebP** |
| `:12166` | `getDisposalTypeList(): Promise<Array<number>>;` | `@since 12`，注释限定 **GIF** |
| `:12571` | `createPictureAtIndex(index: number): Promise<Picture>;` | `@since 20`，注释 `:12552` `only GIF and HEIF<sup>23+</sup> images currently` |
| `:12583` | `readonly supportedFormats: Array<string>;` | `@since 6` |
| `:12632` | `readImageMetadata(propertyKeys?: string[], index?: number): Promise<ImageMetadata>;` | `@since 23`、`@stagemodelonly` |

`ImageInfo` 字段（`:2846-2924`）：`size: Size`（`:2856`）、`density: number`（`:2866`）、`stride: number`（`:2876`）、
`pixelFormat: PixelMapFormat`（`:2886`）、`alphaType: AlphaType`（`:2896`）、`mimeType: string`（`:2913`）、
`isHdr: boolean`（`:2923`）。**`isAnimated` 之类字段本地声明未见。**

→ **Image Kit 无法回答「这是不是一个动态照片」**。`getFrameCount()` 对「一张 JPEG 封面」必然返回 1
（因为动态照片的图片半边就是普通静图 + 元数据），所以**用 ImageSource 判定动态照片在声明层面不成立**。
判定必须回到 §2.3 的 `PhotoSubtype.MOVING_PHOTO` / `MovingPhotoBadgeStateType`。

### 4.3 HEIF / HEIC 支持（`ImageSource` 解码）

模块头注释（`:76-81`）：解码侧原文 `include png, jpeg, bmp, gif, webp, dng, and heic<sup>12+</sup>.`；
编码侧原文 `include jpeg, webp, png, heic<sup>12+</sup>, and gif<sup>18+</sup>.`

`:12573-12583`：

```
 * Supported image formats, include PNG, JPEG, BMP, GIF, WEBP, DNG, HEIC<sup>12+</sup>, WBMP<sup>23+</sup>,
 * HEIFS<sup>23+</sup>, and TIFF<sup>23+</sup>. Decoding support for certain formats depends on the specific device hardware.
```

`createImageSource(uri)` 注释（`:4173`、`:4192`）：`.heic<sup>12+</sup> (depending on the hardware)`。

**`ImagePacker` / `PackingOption.format`**（`:3017-3029`）：

```
 * Currently, only the following formats are supported: image/jpeg, image/webp, image/png,
 * image/heic (or image/heif)<sup>12+</sup>, image/sdr_astc_4x4<sup>18+</sup>, ...
```

→ **`image/heic` 与 `image/heif` 两种写法都出现；`image/heif-sequence` 本地声明未见**（编码序列仅 GIF：
`:3131` `interface PackingOptionsForSequence` / `:3133` `Number of frames specified in GIF encoding.`）。

**HEIF 序列专项**：`MetadataType.HEIFS_METADATA = 15`（`:6475-6481`）、`enum HeifsPropertyKey`
（`:6733` `HEIFS_DELAY_TIME = 'HeifsDelayTime',`、`:6741`、`:6755`、`:6762`）、
`class HeifsMetadata implements Metadata`（`:7849`，成员 `heifsDelayTime?`/`heifsCanvasHeight?`/`heifsCanvasWidth?`/`heifsUnclampedDelayTime?`）、
`ImageMetadata.heifsMetadata?: HeifsMetadata;`（`:11505`）。

**`AuxiliaryPictureType`（`:6379-6445`）**：`GAINMAP = 1`（`:6391`）、`DEPTH_MAP = 2`（`:6402`）、
`UNREFOCUS_MAP = 3`（`:6413`）、`LINEAR_MAP = 4`（`:6424`）、`FRAGMENT_MAP = 5`（`:6436`）、
`LHDR_GAINMAP = 10`（`:6444`，`@stagemodelonly @since 26.0.0`）。
→ **无动态照片相关辅助图类型**；与「实况/Live」概念最接近的是 HDR 的 GAINMAP。

**`PixelMap.readPixelsToBuffer`**：`:4570` `readPixelsToBuffer(dst: ArrayBuffer): Promise<void>;`（`@since 7`；
`:4559` 注释 `Starting from API 26.0.0, it is recommended to use {@link readAllPixelsToBuffer} instead`）、
`:4587` callback 版、`:4605` `readPixelsToBufferSync(dst: ArrayBuffer): void;`（`@since 12`）。

**Image Kit 结论**：HEIF/HEIC **静图**解码/编码没问题；但 **Image Kit 完全不认识「动态照片」这一概念**，
动态照片的一切都归 MediaLibraryKit。image 侧唯一可复用的是：把 `MovingPhoto.requestContent(IMAGE_RESOURCE)`
拿到的 JPEG/HEIF 字节喂给 `image.createImageSource(buffer)` 当封面。

---

## 5. 权限与约束（逐条）

### 5.1 权限标注清单（全 SDK 动态照片 API 穷举）

| API | 行 | 权限 |
|---|---|---|
| `MovingPhoto.requestContent(imageFileUri, videoFileUri)` | `photoAccessHelper.d.ts:5198` | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5179`） |
| `MovingPhoto.requestContent(resourceType, fileUri)` | `:5220` | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5203`） |
| `MovingPhoto.requestContent(resourceType)` | `:5241` | `@permission ohos.permission.READ_IMAGEVIDEO`（`:5225`） |
| `MovingPhoto.getUri()` | `:5254` | **无权限标注**（`:5243-5253` 只有 `@throws 401 / 14000011`） |
| `MediaAssetManager.requestMovingPhoto` | `:671` | `@permission ohos.permission.READ_IMAGEVIDEO`（`:653`） |
| `MediaAssetManager.loadMovingPhoto` | `:737` | **无权限标注** |
| `PhotoOutput.enableMovingPhoto` | `camera.d.ts:6143` | **`@permission ohos.permission.MICROPHONE`**（`:6133`） |
| `PhotoOutput.isMovingPhotoSupported` | `camera.d.ts:6129` | 无 |
| `PhotoOutput.getSupportedMovingPhotoVideoCodecTypes` | `camera.d.ts:5750` | 无 |
| `PhotoOutput.setMovingPhotoVideoCodecType` | `camera.d.ts:5760` | 无 |
| `MovingPhotoView` 全部属性/事件/controller | `movingphotoview.d.ts:29-316` | **全文件 0 条权限标注** |

**本工程现状（关键风险）**：`C:\Users\ll\Desktop\nga_oh\entry\src\main\module.json5:15-26` 的
`requestPermissions` 只有 4 项 —— `ohos.permission.INTERNET`（`:17`）、`ohos.permission.DETECT_GESTURE`（`:20`）、
`ohos.permission.GET_NETWORK_INFO`（`:23`）、`ohos.permission.KEEP_BACKGROUND_RUNNING`（`:26`）。
**`ohos.permission.READ_IMAGEVIDEO` 未声明。**

→ 结论：**凡是从「相册资产」取动态照片数据（`requestMovingPhoto` / `requestContent`）都需要新增该权限
（user_grant 类型），且需运行时授权**；而 `loadMovingPhoto`（沙箱，无权限）与 `MovingPhotoView` 渲染本身不需要权限。
这使「沙箱两文件 → `loadMovingPhoto` → `MovingPhotoView`」成为**唯一零权限的动态照片播放链路**。

### 5.2 `@systemapi` / 系统应用限制

**动态照片 API **没有任何** `@systemapi` 标注。** 已对本机全部动态照片符号做两路交叉验证：

1. grep `@systemapi` 于 `openharmony\ets\api\@ohos.multimedia.movingphotoview.d.ts` → **0 命中**；
2. `<SDK>\hms\ets\api\device-define\api-version\MediaLibraryKit.json` / `CameraKit.json` 的 API 元数据中，
   逐条读取所有 `MovingPhoto` 相关条目，**每条都是 `"isSystemApi": false`**，且 `"OS"` 多为 `"OpenHarmony"`
   （示例原文：`apiText=export class MovingPhotoViewController | apiType=class | isSystemApi=false | since=12 | OS=OpenHarmony | kit=MediaLibraryKit`）。

→ **第三方普通应用（含本工程）可用，无需系统签名、无需特殊 APL。**

### 5.3 `@stagemodelonly` / `@atomicservice` / `@crossplatform`

| 对象 | `@stagemodelonly` | `@atomicservice` | `@crossplatform` |
|---|---|---|---|
| `MovingPhotoView` 全文件（`movingphotoview.d.ts`） | **无** | **有**（全部成员） | **有**（全部成员） |
| `interface MovingPhoto`（`:5167-5174`） | **无** | 有 | 无 |
| `MovingPhoto.requestContent` / `getUri` | 无 | 有 | 无 |
| `MediaAssetManager.requestMovingPhoto`（`:649-671`） | 无 | 有（`:576` `@atomicservice [since 14]`） | 无 |
| `MediaAssetManager.loadMovingPhoto`（`:718-737`） | 无 | 有（`:734` `@atomicservice [since 14]`） | 无 |
| `MediaAssetChangeRequest.addResource`（`:4976` / `:4997`） | 无（类上 `:4755-4760` 也无） | 有 | 无 |
| `MovingPhotoBadgeStateType`（`:3937`） | 无 | 有 | 无 |
| `AutoPlayScene` / `SceneType` / `PlayMode`（`:5264` / `:5293` / `:5380`） | **有**（`:5260`/`:5289`/`:5376`） | 有 | 无 |
| `CreationSetting`（`:1463`） | **有**（`:1459`） | 有 | 无 |
| `PhotoCaptureSetting.compressionQuality`（`:5583`） | **有**（`:5579`） | 有 | 无 |
| `PhotoOutput` 上 4 个动态照片方法 | 无 | 有（`[since 19]`） | 无 |

→ 动态照片**播放/数据链路全部不限制 stage 模型**（本工程是 stage 模型，本来也不受影响）；
仅「选择器自动播放场景（API 23）」「新版创建配置（API 23）」「拍摄压缩质量（API 26）」等外围项带 `@stagemodelonly`。

### 5.4 错误码（动态照片相关 API 会抛的 BusinessError）

- `201 Permission denied` — 缺 `READ_IMAGEVIDEO`（`photoAccessHelper.d.ts:5185/5207/5228/661`）或 `MICROPHONE`（`camera.d.ts:6136`）
- `401 Parameter error` — 参数缺失/类型错/校验失败（`:5186-5189` 等）
- `801 Capability not supported` — `requestMovingPhoto` **自 API 18 起**可抛（`:666` `@throws { BusinessError } 801 - Capability not supported. [since 18]`）
  → **`requestMovingPhoto` 不是所有设备都支持，必须 try/catch 兜底**
- `14000011 System inner fail` / `Internal system error`（`:5190-5193`、`:732`）
- `7400101 Parameter missing or parameter type incorrect`、`7400201 Camera service fatal error`（`camera.d.ts:6137-6138`）
- `13900002 The file corresponding to the URI is not in the app sandbox`（`addResource`，`:4969`）

---

## 6. Kit 导出清单与 import 写法

### 6.1 `@kit.MediaLibraryKit.d.ts`（**动态照片唯一 import 入口**）

`<SDK>\openharmony\ets\kits\@kit.MediaLibraryKit.d.ts:25` 单行导出（原文节选，动态照片相关符号已加粗标注）：

```ts
export { photoAccessHelper, sendablePhotoAccessHelper, MovingPhotoView, MovingPhotoViewController, MovingPhotoViewAttribute, PhotoPickerComponent, PickerController, PickerOptions, DataType, BaseItemInfo, ItemInfo, PhotoBrowserInfo, AnimatorParams, MaxSelected, ItemType, ClickType, PickerOrientation, SelectMode, PickerColorMode, ReminderMode, MaxCountType, PhotoBrowserRange, AlbumPickerComponent, AlbumPickerOptions, AlbumInfo, EmptyAreaClickCallback, AlbumPickerController, RecentPhotoComponent, RecentPhotoCheckResultCallback, RecentPhotoInfo, RecentPhotoCheckInfoCallback, RecentPhotoClickCallback, RecentPhotoOptions, PhotoSource, PhotoBrowserUIElement, ItemsDeletedCallback, ExceedMaxSelectedCallback, CurrentAlbumDeletedCallback, videoPlayStateChangedCallback, MovingPhotoBadgeStateChangedCallback, UpdatablePickerConfigs, SingleLineConfig, BadgeConfig, PreselectedInfo, SaveMode, BadgeType, VideoPlayerState, ItemDisplayRatio, ScrollStopAtStartCallback, ItemClickedNotifyCallback, ScrollStopAtEndCallback, PhotoBrowserChangeStartCallback, PinchGridSwitchedCallback, ErrorCallback, ClickResult, PickerError };
```

→ **`MovingPhotoView`、`MovingPhotoViewController`、`MovingPhotoViewAttribute`、`MovingPhotoBadgeStateChangedCallback`
四个符号由本 kit 导出；`photoAccessHelper` 命名空间导出（含 `MovingPhoto`、`MediaAssetManager`、`PhotoSubtype` 等）。**

**交叉验证**：`<SDK>\openharmony\ets\build-tools\ets-loader\kit_configs\@kit.MediaLibraryKit.json` 的 symbol 绑定表原文：

```json
"MovingPhotoView": { "source": "@ohos.multimedia.movingphotoview.d.ts", "bindings": "MovingPhotoView" },
"MovingPhotoViewController": { "source": "@ohos.multimedia.movingphotoview.d.ts", "bindings": "MovingPhotoViewController" },
"MovingPhotoViewAttribute": { "source": "@ohos.multimedia.movingphotoview.d.ts", "bindings": "MovingPhotoViewAttribute" }
```

→ 编译期真实解析路径确认：**从 `@kit.MediaLibraryKit` 取组件，源文件是 `@ohos.multimedia.movingphotoview.d.ts` 的全局声明**。

**✅ 推荐 import 写法（本工程可用）**：

```ts
import { MovingPhotoView, MovingPhotoViewController, photoAccessHelper } from '@kit.MediaLibraryKit';
// MovingPhotoView 是 ArkUI 组件（@uicomponent）
// photoAccessHelper.MovingPhoto / photoAccessHelper.MediaAssetManager / photoAccessHelper.PhotoSubtype / photoAccessHelper.ResourceType
```

### 6.2 `@kit.CameraKit.d.ts`

`<SDK>\openharmony\ets\kits\@kit.CameraKit.d.ts:21`：

```ts
export { camera, cameraPicker };
```

→ 动态照片拍摄的 4 个方法都在 `camera.PhotoOutput` 上：`import { camera } from '@kit.CameraKit';`

### 6.3 `@kit.ImageKit.d.ts`

`<SDK>\openharmony\ets\kits\@kit.ImageKit.d.ts:19-22`：

```ts
import image from '@ohos.multimedia.image';
import sendableImage from '@ohos.multimedia.sendableImage';
import videoProcessingEngine from '@ohos.multimedia.videoProcessingEngine';
export { image, sendableImage, videoProcessingEngine };
```

→ `import { image } from '@kit.ImageKit';` 可行；**无 `MovingPhoto`、无 `movingPhotoView` 导出**。

### 6.4 组件是否在 `ets\component\*.d.ts` 中？

grep `<SDK>\openharmony\ets\component` 全目录 `MovingPhoto` → **0 命中**。
→ `MovingPhotoView` **不是 ArkUI 全局内置组件**，**必须显式 import**（与 `Image`/`Video`/`Web` 不同）。
这是本工程最容易踩的坑：直接写 `MovingPhotoView({...})` 会编译报「找不到名称」。

---

## 7. 动态照片在本工程可用的结论

前置事实（全部来自上文行号，不再重复引用）：动态照片在声明层面
= **`photoAccessHelper.MovingPhoto` 对象**（`movingphotoview.d.ts:39` 是唯一入参类型），
而该对象的**唯一两个构造入口**是 `MediaAssetManager.requestMovingPhoto`（媒体库资产 `PhotoAsset`，`:671`）
与 `MediaAssetManager.loadMovingPhoto`（沙箱成对 URI，`:737`）。

### (a) 播放一个来自**网络**的动态照片 —— ❌ **根本不支持**

**这是硬性架构限制，不是权限或版本问题。** 证据链：

1. `MovingPhotoViewOptions.movingPhoto` 的类型是 `photoAccessHelper.MovingPhoto`（`movingphotoview.d.ts:39`），
   **不是 `string` / `ResourceStr` / `PixelMap` / `Resource`**；`MovingPhotoViewOptions` 只有 3 个字段
   （`:39 :49 :59`），**没有任何 URL/网络字段**。
2. `MovingPhoto` 是 `interface`（`photoAccessHelper.d.ts:5174`），**不能 new、不能字面量构造**
   （只有 4 个方法，无构造签名）。在 ArkTS 里无法凭空造一个。
3. 两个构造入口都对网络封闭：
   - `requestMovingPhoto(context, asset: PhotoAsset, ...)`（`:671`）—— `PhotoAsset` 只能来自
     `photoAccessHelper.getAssets()` / 选择器，即**本机媒体库**；
   - `loadMovingPhoto(context, imageFileUri, videoFileUri)`（`:737`）—— 注释 `:722-725` 明确
     `in the application sandbox`，示例是 `file://com.example.temptest/...`，**不接受 http(s) URL**。
4. `MediaAssetManager` 家族**没有任何「按 URL 请求」的 API**：`cancelRequest`(`:689`)、`requestImage`(`:603`)、
   `requestImageData`(`:648`)、`requestVideoFile`(`:717`)、`quickRequestImage`(`:624`)、
   `requestMovingPhoto`(`:671`)、`loadMovingPhoto`(`:737`) —— 入参全是 `PhotoAsset` 或沙箱 URI。
5. `RequestOptions`（`:486-510`）只有 `deliveryMode` / `compatibleMode` / `mediaAssetProgressHandler` 三个字段，
   **无 URL 字段**。
6. NGA 场景下「网络动态照片」只能是：远端下发的一对 URL（封面图 + MP4），或一个容器文件。
   **本地声明中不存在把「URL/字节流」直接变成 `MovingPhoto` 的 API。**

**唯一变通（不等于支持）**：先用 `@ohos.request`/`http` 把封面图与 MP4 下到沙箱，
再 `loadMovingPhoto(context, 沙箱图片uri, 沙箱视频uri)` → `MovingPhotoView`。这是「下载后本地播放」，
**不是「播放网络动态照片」**，且需要 NGA 服务端额外提供「封面 + 视频」两份资源。

### (b) 播放**沙箱**里的动态照片文件 —— ⚠️ **可以，但有一个严格前提：必须是「两个文件」而非一个**

- ✅ 通路：`MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri)`（`:737`，**无权限要求**）
  → `MovingPhoto` → `MovingPhotoView({ movingPhoto })`（`movingphotoview.d.ts:39`）。
- ⚠️ 前提：要求**成对的沙箱文件 URI**（图片半边 + 视频半边）。注释原文 `:721-725` 已明确
  `imageFileUri` = 图片文件、`videoFileUri` = 视频文件，且都是 `in the application sandbox`。
  native 侧同义（`moving_photo_capi.h:61-66`）。
- ❌ **「单个动态照片文件」的 API 本地声明未见**：全 SDK 没有任何
  「`loadMovingPhoto(context, singleFileUri)`」重载，也没有「解析 `.movingPhoto` 容器」的 API。
  若网络侧只有一个封装文件，**声明层面无法直接喂给 `MovingPhotoView`**。
- 另注：`loadMovingPhoto` 会抛 `14000011 Internal system error`（`:732`），无 `801` —— 但仍应 try/catch。

### (c) 播放**相册**里的动态照片 —— ✅ 可以，但必须补权限

- ✅ 通路：`photoAccessHelper.getAssets()` 拿到 `PhotoAsset`
  → `MediaAssetManager.requestMovingPhoto(context, asset, requestOptions, dataHandler)`（`:671`）
  → `dataHandler.onDataPrepared(data: MovingPhoto, map?)`（`:543`）
  → `MovingPhotoView({ movingPhoto: data })`。
- ⚠️ **必须**在 `module.json5` 增加 `ohos.permission.READ_IMAGEVIDEO`（`:653` `@permission`），
  否则 `201 Permission denied`（`:661`）。**本工程当前未声明该权限**（`entry\src\main\module.json5:15-26` 仅 4 项）。
- ⚠️ `801 Capability not supported`（`:666`，`[since 18]`）→ 需按设备能力降级。
- 💡 封面兜底：`MovingPhoto.getUri()`（`:5254`，**无权限标注**）可交给 `Image()` 直接显示首帧；
  或用 `requestContent(ResourceType.IMAGE_RESOURCE)`（`:5241`）取字节走 `image.createImageSource`。

### (d) 判断某个文件 / URL 是不是动态照片 —— ⚠️ 分情况：本地资产可判，原始文件/URL 不可判

**可判（媒体库资产 `PhotoAsset`）**，四种官方姿势：

| 姿势 | 证据行 | 说明 |
|---|---|---|
| `asset.get(PhotoKeys.PHOTO_SUBTYPE) === PhotoSubtype.MOVING_PHOTO` | `:813`（`get`）、`:1216`（`PHOTO_SUBTYPE = 'subtype'`）、`:208`（`MOVING_PHOTO = 3`） | **最直接**；`MediaLibraryKit.json` 元数据亦确认 `MOVING_PHOTO = 3` |
| `MovingPhotoBadgeStateType` 三态 | `:3946`（`NOT_MOVING_PHOTO = 0`）、`:3955`、`:3964` | `:3846-3847` 原文要求**同时**用 `isMovingPhotoBadgeShown`（`:3854`）+ `MovingPhotoBadgeStateType` 判定 |
| `photoViewMimeType: PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE` | `:3590` + `:3591` | 选择器按 `'image/movingPhoto'` 过滤 |
| `combinedMediaTypeFilter: ['image\|movingPhoto\|*']` | `:3827` + `:3811` | `:3811` 原文 `Options include movingPhoto or "*" (ignore).` |

**不可判（沙箱裸文件 / 网络 URL / 字节流）**：

- ❌ **Image Kit 判不出来**：`ImageSource` 无「动态照片」成员（§4.1），`getFrameCount()` 对封面静图返回 1，
  无 `isAnimated`（§4.2）。**只有 GIF/WebP 的多帧才可能被 `getFrameCount()>1` 误命中，正常动态照片不会被命中。**
- ❌ `ImageInfo.mimeType` 即便返回 `image/movingPhoto`，也**只是媒体库侧的 MIME 约定**，
  而 `'image/movingPhoto'` 字面量全 SDK 仅在 `photoAccessHelper.d.ts:3590` 定义一处；
  沙箱里实际的封面文件是普通 `.jpg`/`.heic`。
- ❌ 对**网络 URL**：无任何 API（同上 (a)），只能靠 NGA 服务端自己标注（如接口字段/BBCode 标记）。

### (e) 拍摄动态照片 —— 技术上可行，**本项目不需要**

- ✅ 能力齐备：`camera.PhotoOutput.isMovingPhotoSupported()`（`camera.d.ts:6129`，`@since 12`）
  → `enableMovingPhoto(true)`（`:6143`，`@since 12`，**需 `ohos.permission.MICROPHONE`**）
  → `capture(setting)`（`:5739`）+ 编码选择 `setMovingPhotoVideoCodecType(VideoCodecType.HEVC|AVC)`（`:5760`，`@since 13`）。
- ❌ **本项目不需要**：NGA 论坛客户端是「浏览/发帖」工具，无拍照入口，也没有 `ohos.permission.CAMERA` /
  `ohos.permission.MICROPHONE`（`entry\src\main\module.json5:15-26` 未声明）。
  **明确结论：不需要引入 Camera Kit 动态照片拍摄能力。**
- 附带结论：**也不需要「把沙箱一对图文写成动态照片」的写入链路**（`MediaAssetChangeRequest.addResource` ×2，`:4976`/`:4997`）——
  除非产品要做「把网络动态照片存进系统相册」，那才需要它 + `READ_IMAGEVIDEO`。

### 汇总表

| 能力 | 结论 | 关键证据行 | 阻塞点 |
|---|---|---|---|
| (a) 网络来源动态照片 | ❌ **根本不支持** | `movingphotoview.d.ts:39`（入参是 `MovingPhoto` 对象）、`photoAccessHelper.d.ts:5174`（interface 不可构造）、`:671`/`:737`（两个入口只吃 `PhotoAsset`/沙箱 URI）、`:486-510`（`RequestOptions` 无 URL） | 架构性：无「URL→MovingPhoto」通路 |
| (b) 沙箱文件 | ⚠️ 可以（须**成对**两文件） | `:737`（`loadMovingPhoto`，无权限）、`:721-725`（注释要求 imageFileUri + videoFileUri）、`moving_photo_capi.h:61-66`（native 同义） | 单文件容器无 API |
| (c) 相册资产 | ✅ 可以 | `:671`（`requestMovingPhoto`）、`:543`（`onDataPrepared`）、`movingphotoview.d.ts:39` | 需新增 `ohos.permission.READ_IMAGEVIDEO` + `801` 降级 |
| (d) 判定是否动态照片 | ⚠️ 资产可判 / 文件·URL 不可判 | 可判：`:813`+`:1216`+`:208`、`:3946`、`:3590`、`:3827`；不可判：image 侧 §4.1/§4.2 | 裸文件/URL 无任何判定 API |
| (e) 拍摄 | 可用但**不需要** | `camera.d.ts:6129`、`:6143`、`:5760` | 无 CAMERA/MICROPHONE 权限，无业务入口 |

### 落地建议（若产品要做「网络动态照片」）

1. **服务端必须提供两份资源**（封面图 + MP4），或客户端无法播放（见 (a)）。
2. 客户端流程：`http` 下载两份 → 沙箱 → `loadMovingPhoto(context, imgUri, videoUri)`（**无需权限**）
   → `MovingPhotoView({ movingPhoto, controller })`
   → `.muted(true).objectFit(ImageFit.Contain).autoPlay(false)`，
   用户点击时 `controller.startPlayback()`（`movingphotoview.d.ts:278`）。
3. 若走相册路径，`module.json5` 增 `ohos.permission.READ_IMAGEVIDEO`，并对 `801` 做降级（回退静态封面图）。
4. import 必须是 `import { MovingPhotoView, MovingPhotoViewController, photoAccessHelper } from '@kit.MediaLibraryKit';`
   —— 组件**不是** ArkUI 内置全局组件（§6.4）。

---

## 8. 不确定点 / 未验证项

1. **`MovingPhotoView` 是否支持 `ImageFit` 之外的缩放语义、是否支持手势（缩放/拖拽）**：声明层面只给
   `objectFit(value: ImageFit)`（`:124`）+ 继承的 `CommonMethod`（`:102`）；**实际交互行为未在声明中体现**，
   需真机验证。
2. **`autoPlay` 与 `controller.startPlayback()` 的优先级/冲突语义**：注释各自独立（`:216-217`、`:271-272`），
   **声明未定义二者同时使用时的行为**。
3. **`onError` 无参数**（`MovingPhotoViewEventCallback = () => void`，`:92`）：**无法从回调获取失败原因**，
   排障只能靠 `requestMovingPhoto`/`loadMovingPhoto` 的 Promise rejection。
4. **`loadMovingPhoto` 对「视频半边编码格式」的要求**（是否必须 H.264/H.265、是否有时长上限）：
   声明与注释**均未给出**（native 侧同样未给）。官方指导文档另称「动态照片视频时长不能超过 10s」
   （见工程已有 `docs/research/MOVING_PHOTO_GUIDE.md`），但**该约束在本地声明文件中未见**，需真机确认。
5. **`image/movingPhoto` 在 `ImageInfo.mimeType` 中是否真会返回**：`'image/movingPhoto'` 只在
   `photoAccessHelper.d.ts:3590` 作为**选择器过滤 MIME** 定义；**声明未说明**媒体库读出的 `ImageInfo.mimeType`
   会是什么 —— 若计划靠它判定，必须先真机验证。
6. **`requestMovingPhoto` 的 `801 Capability not supported`（`:666`，`[since 18]`）具体触发条件**
   （设备机型？系统版本？分辨率？）：**声明未说明**，只能运行时兜底。
7. **`MovingPhotoViewController.refreshMovingPhoto()`（`:296`）在 `movingPhoto` 变更后的确切时机语义**：
   注释仅 `refresh moving photo data`（`:289`），**未说明是否必须与组件属性更新配合**。
8. **HMS 侧确实无动态照片能力**，但**未验证华为是否有未在本 SDK 暴露的私有扩展**（本报告只对本地声明负责）。
9. **`openharmony\js\api\@ohos.multimedia.movingphotoview.d.ts` 与 ets 版逐字节同构**（均 316 行，`Compare-Object` 零差异），
   因此**不存在「ets 有而 js 无」的差异能力**；工程用 ets，此点仅作完整性记录。

---

## 附：本报告所用证据文件清单（绝对路径）

| 别名 | 绝对路径 | 行数 |
|---|---|---|
| MPV | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.multimedia.movingphotoview.d.ts` | 316 |
| PAH | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.file.photoAccessHelper.d.ts` | 5583 |
| CAM | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.multimedia.camera.d.ts` | 7604 |
| IMG | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.multimedia.image.d.ts` | 13651 |
| KIT-ML | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\kits\@kit.MediaLibraryKit.d.ts` | 25 |
| KIT-CAM | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\kits\@kit.CameraKit.d.ts` | 21 |
| KIT-IMG | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\kits\@kit.ImageKit.d.ts` | 22 |
| KITCFG | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\build-tools\ets-loader\kit_configs\@kit.MediaLibraryKit.json` | — |
| APIMETA | `C:\Program Files\Huawei\DevEco Studio\sdk\default\hms\ets\api\device-define\api-version\MediaLibraryKit.json` | — |
| NATIVE | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native\sysroot\usr\include\multimedia\media_library\moving_photo_capi.h` | 140 |
| PICKER | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.file.PhotoPickerComponent.d.ets` | — |
| PKGVER | `C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\oh-uni-package.json` | — |
| PROJ | `C:\Users\ll\Desktop\nga_oh\build-profile.json5` / `entry\src\main\module.json5` | — |
