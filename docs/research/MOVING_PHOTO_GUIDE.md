# 鸿蒙动态照片（MovingPhoto / Live Photo）官方文档调研报告

> 调研对象：**动态照片（MovingPhoto，拍摄时记录快门前后的短视频）**，**不含 GIF/WebP 动图**（GIF 另有报告）。
>
> 调研工程：NGA 论坛鸿蒙客户端（`C:\Users\ll\Desktop\nga_oh`），`targetSdkVersion` / `compatibleSdkVersion` = **26.0.0**（见 `build-profile.json5`）。
>
> 文档来源：本地技能镜像 `C:\Users\ll\Desktop\nga_oh\.dsh\skills\harmonyos-docs`（下称"技能根目录"，**镜像 API 级别 = API 23 / HarmonyOS 6.0**）。
>
> 本地 SDK 对照：`C:\Program Files\Huawei\DevEco Studio\sdk\default`，`sdk-pkg.json` 声明 `apiVersion: "26"`、`displayName: "HarmonyOS 26.0.0"`、`version: "26.0.0.105"`、`releaseType: "Release"`。

---

## 0. 版本滞后声明与校验方法（必读）

| 项 | 值 |
|---|---|
| 技能镜像 API 级别 | **API 23**（HarmonyOS 6.0 / 6.1.0(23)），页面头部均标注 `API级别: API 23 (HarmonyOS 6.0)` |
| 本工程 target/compatible SDK | **26.0.0** |
| releases 分区覆盖范围 | **仅 HarmonyOS 6.1.0(23)** 一个版本（`releases/版本说明/HarmonyOS 6.1.0(23)/...`），**镜像中不存在 API 24 / 25 / 26 的版本说明或 API 变更清单** → 因此第 8 节无法从离线镜像给出 API 24–26 的动态照片变更条目，只能给出 API 23 条目 + 本地 SDK 26 声明比对结论 |
| 冲突处理 | 凡"镜像说 A、本地 SDK 说 B"处，**以本地 SDK 声明（API 26.0.0）为准并标注** |

**本地 SDK 关键校验（结论：API 21–26 期间 MovingPhotoView 无新增接口）**

对照文件：`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.multimedia.movingphotoview.d.ts`（全文 316 行）。

- `MovingPhotoViewOptions.movingPhoto` → `@since 12`；`controller` → `@since 12`；`imageAIOptions` → `@since 18`
- 属性：`muted` 12、`objectFit` 12、`autoPlayPeriod` 13、`autoPlay` 13、`repeatPlay` 13、`enableAnalyzer` 18
- 事件：`onStart`/`onStop`/`onPause`/`onFinish`/`onError` 12、`onComplete` 13、`onPrepared` 20
- 控制器：`constructor` 12、`startPlayback` 12、`stopPlayback` 12、`refreshMovingPhoto` 18
- **全文没有任何 `@since 21/22/23/24/25/26` 标记** → 组件自 API 20 之后**到 API 26 未再新增属性/事件/控制器方法**。镜像 API 23 文档所列能力 = API 26 可用能力（此项为**本地 SDK 声明直接证明**，非推断）。

另有 API 23 新增的"相册侧"（非组件侧）动态照片相关能力，见第 8 节。

---

## 1. 动态照片总览 / 开发指南

### 1.1 动态照片是什么（官方明确说明）

**路径**：`guides/媒体/Media Library Kit（媒体文件管理服务）/动态照片/访问和管理动态照片资源/访问和管理动态照片资源.md`

原文（第 9 行）：

> 动态照片是一种结合了图片和视频的照片形式，可以显示一小段时间的动态画面和声音。可以帮助用户捕捉精彩的动态瞬间，提升创作空间，同时令拍照的容错率更高。

原文（第 19 行）：

> 拍摄动态照片的能力由 Camera Kit 提供，可参考[动态照片拍摄(ArkTS)]。

**文件结构 = 图片 + 短视频**（官方明确说明）：

同文件第 38 行（保存动态照片资源步骤）：

> 调用 `MediaAssetChangeRequest.addResource` 接口指定动态照片的图片和视频内容，**动态照片的视频时长不能超过 10s**。

同文件第 40 行：

> 以下示例以从应用沙箱的[应用文件] fileUri 指定动态照片的图片和视频内容为例。

同文件第 11–17 行，媒体库提供的动态照片能力清单（官方原文）：

> 媒体库提供访问和管理动态照片资源的能力，包括：
> - [使用安全控件保存动态照片资源](#保存动态照片资源)
> - [获取动态照片对象（MovingPhoto）](#获取动态照片对象)
> - [使用MovingPhotoView播放动态照片]
> - [读取动态照片资源](#读取动态照片资源)

**动态照片总览页（`guides/媒体/Media Library Kit（媒体文件管理服务）/动态照片/动态照片.md`）只是一张导航页**，全文仅两行链接（第 10–11 行）：

> **[访问和管理动态照片资源]**
> **[使用MovingPhotoView播放动态照片]**

→ **官方没有单独的"动态照片格式/容器规范"文档页**：镜像中不存在说明"动态照片是否为单一文件容器（如 JPEG+MP4 合封）"的章节。所有官方文档一律把它描述为**两个资源（图片 + 视频）的配对**。

### 1.2 支持哪些格式

**官方明确说明**：只有枚举层面的格式标识与示例中的文件扩展名，**没有"支持格式列表"章节**。

| 官方条目 | 出处 | 原文 |
|---|---|---|
| 动态照片类型 MIME 枚举 | `api/媒体/Media Library Kit（媒体文件管理服务）/ArkTS API/@ohos.file.photoAccessHelper (相册管理模块)/Enums.md` 第 242 行 | `MOVING_PHOTO_IMAGE_TYPE12+` = `'image/movingPhoto'`，说明"动态照片类型。" |
| 子类型枚举 | 同上 第 32 行 | `PhotoSubtype`：`DEFAULT`=0 默认照片类型、`MOVING_PHOTO`=3 **动态照片文件类型**、`BURST`=4 连拍照片文件类型 |
| 创建示例用的扩展名 | 动态照片资源指南 第 83、88–89 行 | `createAssetRequest(context, PhotoType.IMAGE, 'jpg', {..., subtype: PhotoSubtype.MOVING_PHOTO})` + IMAGE_RESOURCE(.jpg) + VIDEO_RESOURCE(.mp4) |
| 沙箱加载示例用的扩展名 | 同上 第 255–256 行 | `local_moving_photo.jpg` + `local_moving_photo.mp4` |
| 动态范围枚举 | Enums.md 第 38 行 | `DynamicRangeType`：`SDR`=0、`HDR`=1（HDR 动态照片拍摄自 API 23 起，见 §8） |

**推断**（非官方明确）：动态照片的图片资源以 JPEG 为载体、视频资源以 MP4 为载体（官方示例固定用 `.jpg`/`.mp4`，且 Camera 输出为 HDR 时视频为 P010 格式，见 §2）。官方未声明"仅支持 jpg/mp4"，也未提供格式白名单。

### 1.3 与普通图片 / 视频的关系

**官方明确说明**：

- 动态照片在媒体库中是 **PhotoType.IMAGE**（图片）+ **PhotoSubtype.MOVING_PHOTO**（值为 3）的资产 —— 即它不是"第三种媒体类型"，而是**图片的一个子类型**（出处：动态照片资源指南 第 82–86 行原文 `photoAccessHelper.PhotoType.IMAGE, 'jpg', { title: 'moving_photo', subtype: photoAccessHelper.PhotoSubtype.MOVING_PHOTO }`）。
- 可用谓词按子类型筛选（`api/.../Interface (MovingPhoto)/Interface (MovingPhoto).md` 第 88 行原文）：
  `predicates.equalTo(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE, photoAccessHelper.PhotoSubtype.MOVING_PHOTO);`
- Picker 里可用专门类型过滤（动态照片资源指南 第 169 行原文）：
  `photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE;`
- 也可用 `IMAGE_VIDEO_TYPE`（`'*/*'`）混选（`api/.../@ohos.multimedia.movingphotoview (动态照片)/@ohos.multimedia.movingphotoview (动态照片).md` 第 682 行原文：`photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE`）。
- 图库侧另有"动态照片效果开关"概念（`api/.../Classes (其他).md` 第 111、135 行）：`isMovingPhotoBadgeShown`、`PhotoSelectOptions.globalMovingPhotoState`（API 23 新增，见 §8），官方注意项原文：
  > **注意：** 必须同时使用 isMovingPhotoBadgeShown 和 MovingPhotoBadgeStateType 判断照片是否是动态照片。

---

## 2. 拍摄动态照片（Camera Kit 指南）

**路径**：`guides/媒体/Camera Kit（相机服务）/开发相机应用基础能力(ArkTS)/动态照片拍摄(ArkTS)/动态照片拍摄(ArkTS).md`

### 2.1 官方流程原文（第 11–17 行）

> 应用开发动态照片主要分为以下步骤：
> - 应用开发动态照片前，请参考[申请相机开发的权限]、[相机管理]、[设备输入]、[会话管理]等流程完成相机应用开发必选能力配置。
> - 查询当前设备的当前模式是否支持拍摄动态照片。
> - 如果支持动态照片，可以调用相机框架提供的使能接口**使能**动态照片能力。
> - 监听照片回调，将照片存入媒体库。可参考[MediaLibrary Kit-访问和管理动态照片资源]。

### 2.2 前置条件（官方明确说明）

第 24 行原文：

> - 拍摄动态照片需要麦克风权限 `ohos.permission.MICROPHONE`，权限申请和校验的方式请参考[开发准备]。否则拍摄的照片没有声音。

第 61 行原文：

> 查询是否支持动态照片前需要先完成相机会话配置、提交和启动会话，详细开发步骤请参考[会话管理]。

第 78 行原文：

> 使能动态照片前需要使能[分段式拍照]能力。

**API 参考对应**：`api/媒体/Camera Kit（相机服务）/ArkTS API/@ohos.multimedia.camera (相机管理)/Interface (PhotoOutput)/Interface (PhotoOutput).md`
- `isMovingPhotoSupported`（12+，第 542–563 行）："查询是否支持动态照片拍摄。"返回 `true` 支持 / `false` 不支持 / **"若接口调用失败，返回 undefined"**；错误码 `7400201`。
- `enableMovingPhoto`（12+，第 595–603 行）："使能动态照片拍照。"，**需要权限 `ohos.permission.MICROPHONE`**；错误码 `201 permission denied.` / `7400101` / `7400201`。

### 2.3 官方示例代码（原样摘录）

查询设备是否支持（源文件第 63–75 行）：

```ts
function isMovingPhotoSupported(photoOutput: camera.PhotoOutput): boolean {
  let isSupported: boolean = false;
  try {
    isSupported = photoOutput.isMovingPhotoSupported();
  } catch (error) {
    // 失败返回错误码error.code并处理。
    let err = error as BusinessError;
    console.error(`The isMovingPhotoSupported call failed. error code: ${err.code}`);
  }
  return isSupported;
}
```

使能动态照片拍摄（源文件第 80–90 行）：

```ts
function enableMovingPhoto(photoOutput: camera.PhotoOutput): void {
  try {
    photoOutput.enableMovingPhoto(true);
  } catch (error) {
    // 失败返回错误码error.code并处理。
    let err = error as BusinessError;
   console.error(`The enableMovingPhoto call failed. error code: ${err.code}`);
  }
}
```

保存到相册的形态（源文件第 98–127 行，"状态监听"节）：

```ts
function getPhotoAccessHelper(context: Context): photoAccessHelper.PhotoAccessHelper {
  let phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
  return phAccessHelper;
}

async function mediaLibSavePhoto(photoAsset: photoAccessHelper.PhotoAsset,
  phAccessHelper: photoAccessHelper.PhotoAccessHelper): Promise<void> {
  try {
    let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest = new photoAccessHelper.MediaAssetChangeRequest(photoAsset);
    assetChangeRequest.saveCameraPhoto();
    await phAccessHelper.applyChanges(assetChangeRequest);
    console.info('apply saveCameraPhoto successfully');
  } catch (err) {
    console.error(`apply saveCameraPhoto failed with error: ${err.code}, ${err.message}`);
  }
}

function onPhotoOutputPhotoAssetAvailable(photoOutput: camera.PhotoOutput, context: Context): void {
  photoOutput.on('photoAssetAvailable', (err: BusinessError, photoAsset: photoAccessHelper.PhotoAsset): void => {
    if (err) {
      console.error(`photoAssetAvailable error: ${err}.`);
      return;
    }
    console.info('photoOutPutCallBack photoAssetAvailable');
    // 调用媒体库落盘接口保存一阶段图和动态照片视频。
    mediaLibSavePhoto(photoAsset, getPhotoAccessHelper(context));
  });
}
```

官方注释明确：落盘的是"**一阶段图和动态照片视频**" → 相册里最终是**图片资产 + 关联视频**的动态照片子类型资产。

### 2.4 HDR 动态照片（API 23 起，官方明确说明）

第 130 行原文：

> 从 API version 23 开始，相机提供 HDR 动态照片拍摄能力，即组成动态照片的静态图片与动态短视频均为高动态范围（HDR）内容，能够在高光与暗部细节、色彩层次和整体质感方面优于 SDR 成片效果。

组合关系表（原文表格）：

| 静图动态范围 | 短视频动态范围 | 预览输出格式 | 色彩空间 |
|---|---|---|---|
| SDR | SDR | `CAMERA_FORMAT_YUV_420_SP` | `SRGB` |
| HDR | SDR | `CAMERA_FORMAT_YUV_420_SP` | `DISPLAY_P3` |
| HDR | HDR | `CAMERA_FORMAT_YCRCB_P010`、`CAMERA_FORMAT_YCBCR_P010` | `BT2020_HLG` |

**对本工程无关**（NGA 客户端不拍摄动态照片），仅作能力边界记录。

---

## 3. 读取 / 播放动态照片（Media Library Kit + ArkUI）

### 3.1 完整链路（官方明确说明，三条来源通路）

**路径**：`guides/媒体/Media Library Kit（媒体文件管理服务）/动态照片/访问和管理动态照片资源/访问和管理动态照片资源.md`

第 118–120 行原文：

> 应用可以通过 Picker 的方式获取用户媒体库里的动态照片对象，后续可用于在应用内播放动态照片，或是读取动态照片资源进行其他操作（**如上传到应用共享给他人浏览等**）。
>
> **应用也可以通过传入应用沙箱的[应用文件]图片和视频 fileUri 的方式构造应用本地的动态照片对象。**

→ 官方明确支持**两条来源**：① 媒体库 PhotoAsset（Picker 授权）；② 应用沙箱 fileUri 对。**没有第三条"网络 URL"通路**（详见 §5）。

### 3.2 通路 A：相册 → MovingPhoto（官方示例原样摘录）

步骤原文（第 128–130 行）：

> - 通过 Picker 选择动态照片的[媒体文件URI]。
> - 调用 `PhotoAccessHelper.getAssets` 和 `FetchResult.getFirstObject` 接口获取 URI 对应的 PhotoAsset 资产。
> - 调用 `MediaAssetManager.requestMovingPhoto` 获取 PhotoAsset 对应的动态照片对象（MovingPhoto）。

完整示例（源文件第 165–212 行，原样摘录）：

```ts
async function example(phAccessHelper: photoAccessHelper.PhotoAccessHelper, context: Context): Promise<string> {
  try {
    // Use Picker to select the URI of the moving photo.
    let photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
    photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE;
    photoSelectOptions.maxSelectNumber = 9;
    let photoViewPicker = new photoAccessHelper.PhotoViewPicker();
    let photoSelectResult = await photoViewPicker.select(photoSelectOptions);
    let uris = photoSelectResult.photoUris;

    let resultMessage = 'Selected ' + uris.length + ' moving photo(s)\n\n';

    for (let i = 0; i < uris.length; i++) {
      // Obtain the photo asset corresponding to the URI.
      let predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
      predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uris[i]);
      let fetchOption: photoAccessHelper.FetchOptions = {
        fetchColumns: [],
        predicates: predicates
      };
      let fetchResult: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> =
        await phAccessHelper.getAssets(fetchOption);
      let photoAsset: photoAccessHelper.PhotoAsset = await fetchResult.getFirstObject();

      let movingPhotoUri = await new Promise<string>((resolve) => {
        // Obtain the moving photo object corresponding to the photo asset.
        photoAccessHelper.MediaAssetManager.requestMovingPhoto(context, photoAsset, {
          deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE
        }, {
          async onDataPrepared(movingPhoto: photoAccessHelper.MovingPhoto) {
            if (movingPhoto !== undefined) {
              // Customize the logic for processing the moving photo.
              console.info('request moving photo successfully, uri: ' + movingPhoto.getUri());
              resolve(movingPhoto.getUri());
            }
          }
        })
      });

      resultMessage += (i + 1) + '. request moving photo successfully, uri: ' + movingPhotoUri + '\n';
    }

    return resultMessage;
  } catch (err) {
    console.error(`request moving photo failed with error: ${err.code}, ${err.message}`);
    return `request moving photo failed with error: ${err.code}, ${err.message}`;
  }
}
```

**权限（官方明确说明）**，`api/.../Class (MediaAssetManager)/Class (MediaAssetManager).md` 第 311–325 行：

> `static requestMovingPhoto(context: Context, asset: PhotoAsset, requestOptions: RequestOptions, dataHandler: MediaAssetDataHandler<MovingPhoto>): Promise<string>`
> 根据不同的策略模式，请求动态照片对象（动态照片对象可用于请求动态照片的资源数据）。使用 Promise 异步回调。
> 需要权限：`ohos.permission.READ_IMAGEVIDEO`
> **通过 picker 的方式调用该接口来请求动态照片对象，不需要申请 'ohos.permission.READ_IMAGEVIDEO' 权限**
> 对于本应用保存到媒体库的动态照片资源，应用无需额外申请 'ohos.permission.READ_IMAGEVIDEO' 权限即可访问。

错误码（同文件第 392–410 行）：`201` Permission denied、`401`、`801` Capability not supported（本地 SDK `.d.ts` 第 666 行标注 `@throws { BusinessError } 801 - Capability not supported. [since 18]`）、`14000011`。

**关键限制**：`asset: PhotoAsset` 必须是**媒体库资产**（`phAccessHelper.getAssets(...)` 的返回值）。**无法把任意 URI 字符串直接变成 PhotoAsset** —— 这是 NGA"网络动态照片"路线的核心卡点（见 §5、§9）。

### 3.3 通路 B：沙箱 → MovingPhoto（官方示例原样摘录）

官方原文（第 216 行）：

> 调用 `MediaAssetManager.loadMovingPhoto` 加载应用沙箱的动态照片对象（MovingPhoto）。

完整示例（源文件第 253–264 行，原样摘录）：

```ts
async function example(context: Context): Promise<string> {
  try {
    let imageFileUri = 'file://' + context.filesDir + '/local_moving_photo.jpg';
    let videoFileUri = 'file://' + context.filesDir + '/local_moving_photo.mp4';
    let movingPhoto = await photoAccessHelper.MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri);
    console.info('load moving photo successfully');
    return 'load moving photo successfully';
  } catch (err) {
    console.error(`load moving photo failed with error: ${err.code}, ${err.message}`);
    return `load moving photo failed with error: ${err.code}, ${err.message}`;
  }
}
```

API 签名与说明原文（`api/.../Class (MediaAssetManager)/Class (MediaAssetManager).md` 第 685–746 行）：

> `loadMovingPhoto` 12+
> `static loadMovingPhoto(context: Context, imageFileUri: string, videoFileUri: string): Promise<MovingPhoto>`
> **加载应用沙箱的动态照片。**使用 Promise 异步回调。
> 元服务API： 从 API version 14 开始，该接口支持在元服务中使用。
> 系统能力：`SystemCapability.FileManagement.PhotoAccessHelper.Core`
> `context`：传入 AbilityContext 或者 UIExtensionContext 的实例。
> `imageFileUri`：**应用沙箱动态照片的图片 uri**。示例：`'file://com.example.temptest/data/storage/el2/base/haps/ImageFile.jpg'`
> `videoFileUri`：**应用沙箱动态照片的视频 uri**。示例：`'file://com.example.temptest/data/storage/el2/base/haps/VideoFile.mp4'`
> 返回值：`Promise<MovingPhoto>`，Promise 对象，返回 MovingPhoto 实例。
> 错误码：`401`、`14000011` Internal system error.

**注意（官方此处不要求任何权限）**：`loadMovingPhoto` 的 API 文档**没有"需要权限"行** —— 与 `requestMovingPhoto`（需 `READ_IMAGEVIDEO`）形成对比。→ **从沙箱 fileUri 构造 MovingPhoto 不需要相册权限**（官方明确，来源于 API 参考页"需要权限"字段的缺失 + 本地 `.d.ts` 无 `@permission` 标注）。

**fileUri 写法（官方两处写法等价）**：
- 指南写法：`'file://' + context.filesDir + '/local_moving_photo.jpg'`
- 组件 API 示例写法：`'file://{bundleName}/data/storage/el2/base/haps/entry/files/xxx.jpg'`（`api/.../@ohos.multimedia.movingphotoview (动态照片)...md` 第 797–798 行）—— **文档中是占位符 `{bundleName}`，实际必须替换为真实 bundleName**。

### 3.4 通路 C：读取动态照片资源（导出图片/视频，官方示例原样摘录）

官方原文（第 268 行）：

> 对于一个动态照片对象，应用可以通过 `MovingPhoto.requestContent` 导出图片和视频到应用沙箱，或者读取图片或视频的 ArrayBuffer 内容。

示例（源文件第 306–319 行，原样摘录）：

```ts
async function example(movingPhoto: photoAccessHelper.MovingPhoto, context: Context): Promise<string> {
  try {
    let imageFileUri = context.filesDir + '/request_moving_photo.jpg';
    let videoFileUri = context.filesDir + '/request_moving_photo.mp4';
    await movingPhoto.requestContent(imageFileUri, videoFileUri);
    let imageData = await movingPhoto.requestContent(photoAccessHelper.ResourceType.IMAGE_RESOURCE);
    let videoData = await movingPhoto.requestContent(photoAccessHelper.ResourceType.VIDEO_RESOURCE);

    return 'Exported to:\n' + imageFileUri + '\n' + videoFileUri + '\n\nImage data size: ' + imageData.byteLength + ' bytes\nVideo data size: ' + videoData.byteLength + ' bytes';
  } catch (err) {
    console.error(`request content of moving photo failed with error: ${err.code}, ${err.message}`);
    return `request content of moving photo failed with error: ${err.code}, ${err.message}`;
  }
}
```

**注意**：此示例导出到沙箱时用的是 `context.filesDir + '/xxx.jpg'`（**没有 `file://` 前缀**），与 `loadMovingPhoto` 要求的 `file://` 前缀写法不同 —— 官方两个示例写法不一致，属于文档瑕疵；在 API 26 上建议统一用 `'file://' + context.filesDir + '/xxx'`。

### 3.5 MovingPhotoView 官方用法示例

**指南页**：`guides/媒体/Media Library Kit（媒体文件管理服务）/动态照片/使用MovingPhotoView播放动态照片/使用MovingPhotoView播放动态照片.md`

约束与限制（第 13–19 行，官方原文全量）：

> - 当前不支持动态属性设置。
> - 当前不支持设置 ArkUI 通用属性 [expandSafeArea]。
> - 该组件长按触发播放时组件区域放大为 1.1 倍。
> - 该组件使用 [AVPlayer] 进行播放，**同时开启的 AVPlayer 个数不建议超过 3 个，超过 3 个可能会出现视频播放卡顿现象。**

开发步骤原文（第 24–44 行）：

> 1. 导入动态照片模块。
>    - `MovingPhotoViewAttribute` 是用于配置 MovingPhotoView 组件属性的关键接口。**API version 21 及之前版本，导入 MovingPhotoView 组件后需要开发者手动导入 MovingPhotoViewAttribute，否则会编译报错。从 API version 22 开始，编译工具链识别到导入 MovingPhotoView 组件后，会自动导入 MovingPhotoViewAttribute，无需开发者手动导入。**
>    - `MovingPhotoViewAttribute` 导入后，DevEco Studio 会将其显示置灰，不影响开发者使用。
> 2. 获取动态照片对象（MovingPhoto）。
>    **MovingPhoto 对象需要通过 photoAccessHelper 接口创建或获取，MovingPhotoView 只接收构造完成的 MovingPhoto 对象。**
> 3. 创建动态照片控制器（MovingPhotoViewController），用于控制动态照片的播放状态（如播放、停止）。
> 4. 创建动态照片组件。

**指南页示例代码（原样摘录，第 46–104 行）**：

```ts
// API version 21及之前版本导入方式：import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController, MovingPhotoViewAttribute } from '@kit.MediaLibraryKit';
// API version 22及之后版本导入方式如下：
import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit';

@Entry
@Component
struct Index {
  @State src: photoAccessHelper.MovingPhoto | undefined = undefined
  @State isMuted: boolean = false
  controller: MovingPhotoViewController = new MovingPhotoViewController();
  build() {
    Column() {
      MovingPhotoView({
        movingPhoto: this.src,
        controller: this.controller
      })
        // 是否静音播放，此处由按钮控制，默认值为false非静音播放。
        .muted(this.isMuted)
        // 视频显示模式，默认值为Cover。
        .objectFit(ImageFit.Cover)
        // 播放时触发。
        .onStart(() => {
          console.info('onStart');
        })
        // 播放结束触发。
        .onFinish(() => {
          console.info('onFinish');
        })
        // 播放停止触发。
        .onStop(() => {
          console.info('onStop')
        })
        // 出现错误触发。
        .onError(() => {
          console.error('onError');
        })

      Row() {
        // 按钮：开始播放。
        Button('start')
          .onClick(() => {
            this.controller.startPlayback()
          })
          .margin(5)
        // 按钮：停止播放。
        Button('stop')
          .onClick(() => {
            this.controller.stopPlayback()
          })
          .margin(5)
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .height('15%')
    }
  }
}
```

**API 参考页完整示例（含 Picker 取相册动态照片 → MovingPhotoView 播放，原样摘录，`api/.../@ohos.multimedia.movingphotoview (动态照片)/@ohos.multimedia.movingphotoview (动态照片).md` 第 642–784 行）**：

```ts
// xxx.ets
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { emitter } from '@kit.BasicServicesKit';
import { dataSharePredicates } from '@kit.ArkData';
// API version 21及之前版本导入方式：import { MovingPhotoView, MovingPhotoViewController, MovingPhotoViewAttribute } from '@kit.MediaLibraryKit';
// API version 22及之后版本导入方式如下：
import { MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit';

const PHOTO_SELECT_EVENT_ID: number = 80001

@Entry
@Component
struct MovingPhotoViewDemo {
 @State src: photoAccessHelper.MovingPhoto | undefined = undefined
 @State isMuted: boolean = false
 controller: MovingPhotoViewController = new MovingPhotoViewController()
 private uiContext: UIContext = this.getUIContext()

 aboutToAppear(): void {
 emitter.on({
 eventId: PHOTO_SELECT_EVENT_ID,
 priority: emitter.EventPriority.IMMEDIATE,
 }, (eventData: emitter.EventData) => {
 this.src = AppStorage.get<photoAccessHelper.MovingPhoto>('mv_data') as photoAccessHelper.MovingPhoto
 })
 }

 aboutToDisappear(): void {
 emitter.off(PHOTO_SELECT_EVENT_ID)
 }

 build() {
 Column() {
 Row() {
 Button('PICK')
 .margin(5)
 .onClick(async () => {
 try {
 let uris: Array<string> = []
 const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions()
 photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE
 photoSelectOptions.maxSelectNumber = 2
 const photoViewPicker = new photoAccessHelper.PhotoViewPicker()
 let photoSelectResult: photoAccessHelper.PhotoSelectResult = await photoViewPicker.select(photoSelectOptions)
 uris = photoSelectResult.photoUris
 if (uris[0]) {
 this.handlePickerResult(this.uiContext.getHostContext()!, uris[0], new MediaDataHandlerMovingPhoto())
 }
 } catch (e) {
 console.error(`pick file failed`)
 }
 })
 }
 .alignItems(VerticalAlign.Center)
 .justifyContent(FlexAlign.Center)
 .height('15%')

 Row() {
 Column() {
 MovingPhotoView({
 movingPhoto: this.src,
 controller: this.controller
 })
 .width('100%')
 .height('100%')
 .muted(this.isMuted)
 .autoPlay(true)
 .repeatPlay(false)
 .autoPlayPeriod(0, 600)
 .objectFit(ImageFit.Cover)
 .onComplete(() => {
 console.info('Completed');
 })
 .onStart(() => {
 console.info('onStart')
 })
 .onFinish(() => {
 console.info('onFinish')
 })
 .onStop(() => {
 console.info('onStop')
 })
 .onError(() => {
 console.error('onError')
 })
 }
 }
 .height('70%')

 Row() {
 Button('start')
 .onClick(() => {
 this.controller.startPlayback()
 })
 .margin(5)
 Button('stop')
 .onClick(() => {
 this.controller.stopPlayback()
 })
 .margin(5)
 Button('mute')
 .onClick(() => {
 this.isMuted = !this.isMuted
 })
 .margin(5)
 }
 .alignItems(VerticalAlign.Center)
 .justifyContent(FlexAlign.Center)
 .height('15%')
 }
 }

 async handlePickerResult(context: Context, uri: string, handler: photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto>): Promise<void> {
 let uriPredicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates();
 uriPredicates.equalTo('uri', uri)
 let fetchOptions: photoAccessHelper.FetchOptions = {
 fetchColumns: [],
 predicates: uriPredicates
 };
 let phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context)
 let assetResult = await phAccessHelper.getAssets(fetchOptions)
 let asset = await assetResult.getFirstObject()
 let requestOptions: photoAccessHelper.RequestOptions = {
 deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE,
 }
 try {
 photoAccessHelper.MediaAssetManager.requestMovingPhoto(context, asset, requestOptions, handler)
 } catch (err) {
 console.error("request error: ", err)
 }
 }
}

class MediaDataHandlerMovingPhoto implements photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> {
 async onDataPrepared(movingPhoto: photoAccessHelper.MovingPhoto) {
 AppStorage.setOrCreate('mv_data', movingPhoto)
 emitter.emit({
 eventId: PHOTO_SELECT_EVENT_ID,
 priority: emitter.EventPriority.IMMEDIATE,
 }, {
 })
 }
}
```

**API 参考页示例 2：沙箱加载 + 元服务场景（第 786–876 行，原样摘录核心部分）**：

```ts
// API version 21及之前版本导入方式：import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController, MovingPhotoViewAttribute } from '@kit.MediaLibraryKit';
// API version 22及之后版本导入方式如下：
import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit';

let data: photoAccessHelper.MovingPhoto
async function loading(context: Context) {
 try {
 // 需要确保imageFileUri和videoFileUri对应的资源在应用沙箱存在。
 let imageFileUri = 'file://{bundleName}/data/storage/el2/base/haps/entry/files/xxx.jpg';
 let videoFileUri = 'file://{bundleName}/data/storage/el2/base/haps/entry/files/xxx.mp4';
 data = await photoAccessHelper.MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri);
 console.info('load moving photo successfully');
 } catch (err) {
 console.error(`load moving photo failed with error: ${err.code}, ${err.message}`);
 }
}
```

其上绑定属性（同示例第 824–852 行原样）：

```ts
MovingPhotoView({
 movingPhoto: data,
 controller: this.controller
})
.width(300)
.height(400)
.muted(this.flag)
.objectFit(this.ImageFit)
.autoPlay(this.autoPlayFlag)
.autoPlayPeriod(this.autoPlayPeriodStart, this.autoPlayPeriodEnd)
.repeatPlay(this.repeatPlayFlag)
.onComplete(() => {
 console.info('onComplete')
})
.onStart(() => {
 console.info('onStart')
})
.onStop(() => {
 console.info('onStop')
})
.onPause(() => {
 console.info('onPause')
})
.onFinish(() => {
 console.info('onFinish')
})
.onError(() => {
 console.info('onError')
})
```

**最佳实践里的社交场景用法**（`best/行业场景解决方案/社交通讯/AI辅助图文内容编创/AI辅助图文内容编创.md` 第 190、291–297 行）：

> （3）使用 MovingPhotoView 视图预览 Moving Photo 图片，**长按可播放**。

```ts
MovingPhotoView({
  movingPhoto: this.src,
  controller: this.controller
})
  .width($r('app.string.full_screen'))
  .objectFit(ImageFit.Contain)
  .muted(this.isMuted)
```

→ 官方交互默认：**不自动播放时长按播放；开了 `autoPlay(true)` 则加载完成后自动播一遍**（`autoPlay` 文档原文见 §4）。

### 3.6 是否需要先复制到沙箱？能否直接播放相册 URI？

**官方明确说明**：

- **相册动态照片不需要先复制到沙箱**：`requestMovingPhoto` 直接接收 `PhotoAsset`（媒体库资产），回调里拿到 `MovingPhoto` 即可交给 `MovingPhotoView` 播放。官方示例 1（Picker → `getAssets` → `requestMovingPhoto` → `MovingPhotoView`）全程未落盘。
- **但 MovingPhotoView 不接受"裸 URI"**：官方明确（使用MovingPhotoView指南 第 36 行）——
  > MovingPhoto 对象需要通过 photoAccessHelper 接口创建或获取，**MovingPhotoView 只接收构造完成的 MovingPhoto 对象**。
- `RequestOptions.deliveryMode`：官方示例统一使用 `photoAccessHelper.DeliveryMode.FAST_MODE`。**官方文档未给出"是否必须 FAST_MODE"的说明**（属未明确项）。

**推断**：需要在列表里快速展示很多动态照片时，`requestMovingPhoto` 会触发媒体库解码/准备回调，官方未提供"仅取封面"的低成本接口；封面帧应走 `PhotoAsset.getThumbnail()` 或 `PhotoAsset` 图片资源通路（见 §6）。

---

## 4. `MovingPhotoView` API 参考页（全量整理）

**路径**：`api/媒体/Media Library Kit（媒体文件管理服务）/ArkTS组件/@ohos.multimedia.movingphotoview (动态照片)/@ohos.multimedia.movingphotoview (动态照片).md`（共 1031 行）

### 4.1 组件头信息（官方原文）

> 用于播放动态照片文件并控制其播放状态的组件。
> 该组件从 **API version 12** 开始支持。后续版本如有新增内容，则采用上角标单独标记该内容的起始版本。
> **当前不支持在预览器中使用 MovingPhotoView 组件。**
> 当前不支持动态属性设置。
> 当前不支持 ArkUI 通用属性 `ComponentOptions` 中 `expandSafeArea` 属性设置。
> 该组件长按触发播放时组件区域放大为 1.1 倍。
> 该组件使用 AVPlayer 进行播放，同时开启的 AVPlayer 个数不建议超过 3 个，超过 3 个可能会出现视频播放卡顿现象。

**系统能力**：`SystemCapability.FileManagement.PhotoAccessHelper.Core`（全部属性/事件/控制器方法一致）
**元服务 API**：属性 `muted`/`objectFit` 自 API 12 起、`autoPlayPeriod`/`autoPlay`/`repeatPlay` 自 API 13 起、`enableAnalyzer` 自 API 18 起；事件 `onStart`/`onStop`/`onPause`/`onFinish`/`onError` 自 API 12 起、`onComplete` 自 API 13 起、`onPrepared` 自 API 20 起；控制器全部方法自 API 12 起（`refreshMovingPhoto` 自 API 18 起）。

### 4.2 构造参数 `MovingPhotoViewOptions`

| 参数名 | 类型 | 只读 | 可选 | 起始版本 | 说明（官方原文） |
|---|---|---|---|---|---|
| `movingPhoto` | `photoAccessHelper.MovingPhoto` | 否 | 否（**必填**） | 12 | "支持媒体库 MovingPhoto 数据源，具体信息详见 MovingPhoto 说明。" |
| `controller` | `MovingPhotoViewController` | 否 | 是 | 12 | "设置动态照片控制器，可以控制动态照片的播放状态。" |
| `imageAIOptions` | `ImageAIOptions` | 否 | 是 | 18 | "设置动态照片 AI 分析选项，可配置分析类型或绑定一个分析控制器。" |

> **本地 SDK 补充（API 26）**：`movingPhoto: photoAccessHelper.MovingPhoto`（**非可选，无 `?`**，`.d.ts` 第 39 行）。但**指南与 API 示例均把 `undefined` 传给该字段**（`@State src: photoAccessHelper.MovingPhoto | undefined = undefined`）。
> → **这是官方文档自身的不一致**：严格类型下 `MovingPhotoView({ movingPhoto: this.src })` 中 `this.src` 为 `undefined` 时应用 `!` 断言或初值兜底。**在 API 26 上直接编译官方示例，若开启严格空值检查可能报类型错误**（标注为"官方示例与本地声明不一致"，非官方说明）。

### 4.3 属性（全部）

| 属性 | 签名 | 起始 | 默认 | 官方原文说明 |
|---|---|---|---|---|
| `muted` | `muted(isMuted: boolean)` | 12 | `false` | "设置是否静音。… false：非静音。true：静音。" |
| `objectFit` | `objectFit(value: ImageFit)` | 12 | `Cover` | "设置动态照片显示模式。… 视频显示模式。" |
| `autoPlayPeriod` | `autoPlayPeriod(startTime: number, endTime: number)` | 13 | — | "设置自动播放区间，附属于 autoPlay 的子配置项。**在调用此方法前，需将 autoPlay 设置为 true，设置自动播放，否则指定的视频区间 (startTime, endTime) 无法生效。**" 参数：`startTime` 单位 ms、取值 ≥0；`endTime` 单位 ms、取值 > startTime |
| `autoPlay` | `autoPlay(isAutoPlay: boolean)` | 13 | `false` | "设置自动播放，**自动播放一遍视频**。动态照片加载完成后，准备播放时可以调用，**播放完成后显示静态图**。" |
| `repeatPlay` | `repeatPlay(isRepeatPlay: boolean)` | 13 | `false` | "设置循环播放，重复播放视频。**repeatPlay 与 autoPlay 及长按播放互斥，repeatPlay 设置时，autoPlay 和长按播放均不生效。**" |
| `enableAnalyzer` | `enableAnalyzer(enabled: boolean)` | 18 | `true` | "设置该图片是否支持 AI 分析，当前支持主体识别、文字识别和对象查找等功能。" |

其他通用能力（官方明确）：
- "除支持[通用属性]外，还支持以下属性" → 通用属性可用，**但"当前不支持动态属性设置"**（即不支持在 `@Component` 内用状态动态改变本组件属性？—— 官方原文如此描述，**未见进一步解释，属未明确项**）。
- **不支持** `expandSafeArea`。
- **不支持预览器**。

### 4.4 事件（全部）

| 事件 | 签名 | 起始 | 官方原文说明 |
|---|---|---|---|
| `onStart` | `onStart(callback: MovingPhotoViewEventCallback)` | 12 | "播放时触发该事件。使用 callback 异步回调。" |
| `onPause` | `onPause(callback: MovingPhotoViewEventCallback)` | 12 | "播放暂停时触发该事件。" |
| `onFinish` | `onFinish(callback: MovingPhotoViewEventCallback)` | 12 | "播放结束时触发该事件。" |
| `onStop` | `onStop(callback: MovingPhotoViewEventCallback)` | 12 | "播放停止时触发该事件（**当 stop() 方法被调用后触发**）。" |
| `onError` | `onError(callback: MovingPhotoViewEventCallback)` | 12 | "播放失败时触发该事件。" |
| `onComplete` | `onComplete(callback: MovingPhotoViewEventCallback)` | 13 | "**动态照片加载完成图片时**触发该事件。" |
| `onPrepared` | `onPrepared(callback: MovingPhotoViewEventCallback)` | 20 | "动态照片准备播放时触发该事件。" |

回调类型（官方原文）：

```ts
declare type MovingPhotoViewEventCallback = () => void
```

→ **回调不带任何参数**（无进度、无错误码、无时长），官方说明为"动态照片播放状态发生变化时触发的回调"。

### 4.5 控制器 `MovingPhotoViewController`

官方原文（第 587–589 行）：

> 一个 MovingPhotoViewController 对象可以控制一个 MovingPhotoView，可用视频播放实例请参考 @ohos.multimedia.media。

| 成员 | 签名 | 起始 | 官方原文说明 |
|---|---|---|---|
| `constructor` | `constructor()` | 12 | 构造函数 |
| `startPlayback` | `startPlayback()` | 12 | "开始播放，**动态照片加载完成后，在播放准备，暂停，完成时调用**。" |
| `stopPlayback` | `stopPlayback()` | 12 | "停止播放，**再次播放时从头开始播放**。" |
| `refreshMovingPhoto` | `refreshMovingPhoto()` | 18 | "强制刷新动态照片组件加载的视频和图片资源，**会打断组件当前的行为，使用时要谨慎**。" |

**无 `pausePlayback` / `seek` / `setVolume` 等接口**（`MovingPhotoViewController` 仅上述 4 个成员，API 26 `.d.ts` 亦同）→ "暂停"只能靠 `stopPlayback()`（会重置到开头）或组件自动化行为。

### 4.6 权限与限制（汇总）

| 项 | 结论 | 依据 |
|---|---|---|
| 组件本身权限 | **不需要权限**（属性/事件/控制器均无"需要权限"字段） | API 参考页各节 |
| 获取 MovingPhoto（相册） | 需 `ohos.permission.READ_IMAGEVIDEO`；**Picker 方式豁免** | `Class (MediaAssetManager).md` 第 318–325 行 |
| 获取 MovingPhoto（沙箱） | **无权限要求** | `Class (MediaAssetManager).md` 第 695–737 行无权限行 |
| 读取内容 | `requestContent` 需 `ohos.permission.READ_IMAGEVIDEO`（Picker 方式豁免；本应用保存的资源豁免） | `Interface (MovingPhoto).md` 第 125–132、263–270、396–403 行 |
| 并发限制 | 同时开启的 AVPlayer **不建议超过 3 个** | 组件头信息 + 指南约束 |
| 预览器 | **不支持** | 组件头信息 |
| `expandSafeArea` | **不支持** | 组件头信息 |
| 运动效果 | 长按播放时**组件区域放大 1.1 倍** | 组件头信息 |
| 视频时长 | 动态照片视频**不能超过 10s**（保存/创建侧约束） | 动态照片资源指南 第 38 行 |

---

## 5. 能否播放"非相册来源"的动态照片？（本报告核心结论）

### 5.1 三条通路对照

| 来源 | 官方是否支持 | 官方构造接口 | 权限 | 依据 |
|---|---|---|---|---|
| **相册 asset**（媒体库 PhotoAsset） | ✅ 官方明确支持 | `MediaAssetManager.requestMovingPhoto(context, asset, requestOptions, dataHandler)` | 需 `READ_IMAGEVIDEO`；**Picker 方式豁免** | `Class (MediaAssetManager).md` 第 308–325 行；指南"获取媒体库动态照片对象"节 |
| **应用沙箱 `file://` 图片 + 视频** | ✅ 官方明确支持 | `MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri)`（**两个 fileUri，必须是沙箱文件**） | **无权限要求** | `Class (MediaAssetManager).md` 第 685–737 行；指南"获取应用沙箱动态照片对象"节 |
| **网络 URL（http/https）** | ❌ **官方完全不支持**（无任何接口/示例） | 无 | — | 全镜像检索 `loadMovingPhoto` / `requestMovingPhoto` / `MovingPhotoView` 均无网络 URL 用法；`loadMovingPhoto` 参数被明确限定为"**应用沙箱**动态照片的图片/视频 uri" |
| **任意 `datashare://` / 非媒体库 URI** | ❌ 不支持（`requestMovingPhoto` 只吃 `PhotoAsset`） | 无 | — | 同上 |
| **从 `ArrayBuffer` 构造 MovingPhoto** | ❌ **没有该接口** | 无 | — | `MediaAssetManager` 只有 `loadMovingPhoto(context, imageFileUri: string, videoFileUri: string)` 一种构造方式；`requestContent(resourceType): Promise<ArrayBuffer>` 是**读取**方向，不是构造方向 |

### 5.2 结论（官方明确说明）

1. **`MovingPhotoView` 只接收构造完成的 `MovingPhoto` 对象**（指南 第 36 行原文），**没有任何"从 URL / ArrayBuffer / 单文件构造"的官方入口**。
2. 官方仅提供 **两个** MovingPhoto 构造入口：相册 `PhotoAsset`（`requestMovingPhoto`）与**沙箱 fileUri 对**（`loadMovingPhoto`）。
3. **"只有一个文件"无法构造动态照片**：`loadMovingPhoto` 必须同时给图片 uri 和视频 uri。若服务端把动态照片作为单文件分发（例如仅一个 `.jpg` 或某个自定义容器），**官方能力无法直接构造 MovingPhoto**。
4. **`loadMovingPhoto` 不接受网络 URL**：参数说明限定为"应用沙箱"路径（示例形如 `'file://com.example.temptest/data/storage/el2/base/haps/ImageFile.jpg'`）。→ 网络资源**必须先下载落盘到沙箱**，再用 `loadMovingPhoto` 构造。

---

## 6. 动态照片与普通图片的相互转换 / 降级

### 6.1 动态照片当作静态图显示（降级为封面帧）

**官方明确说明**：

- `autoPlay(false)`（默认值）时不自动播放，"**播放完成后显示静态图**"（`autoPlay` 文档原文）；长按才播放 → **默认形态就是静态封面**。出处：`api/.../@ohos.multimedia.movingphotoview (动态照片).md` 第 249 行。
- 组件"长按触发播放时组件区域放大为 1.1 倍" → 静态展示时无放大。

**推荐降级路径（推断 + 官方 API 支撑）**：
1. **列表/九宫格缩略图**：用 `PhotoAsset` 的图片通路（`PhotoAsset.getThumbnail()`，见 `best/行业场景解决方案/社交通讯/AI辅助图文内容编创/AI辅助图文内容编创.md` 第 226–237 行官方代码 `this.currentImg = await photoAsset.getThumbnail();`）→ 拿到 `PixelMap` 交给 `Image` 组件。**这是官方示例做法**。
2. **详情页**：用 `MovingPhotoView` + `autoPlay(false)` + `muted(true)`，仅在用户长按/点击时 `controller.startPlayback()`。**这是官方推荐的社交场景做法**（"使用 MovingPhotoView 视图预览 Moving Photo 图片，长按可播放"）。
3. **要"确定能拿到封面图"**：`movingPhoto.requestContent(photoAccessHelper.ResourceType.IMAGE_RESOURCE)` → `Promise<ArrayBuffer>`，写入沙箱后按普通图片加载（官方 API 明确支持，见 §3.4）。

### 6.2 提取内嵌视频

**官方明确说明**：`MovingPhoto.requestContent` 可导出/读取视频资源：

- `requestContent(imageFileUri, videoFileUri): Promise<void>` —— 同时导出图片与视频到指定 uri
- `requestContent(resourceType: ResourceType, fileUri: string): Promise<void>` —— 导出指定类型
- `requestContent(resourceType: ResourceType): Promise<ArrayBuffer>` —— 返回 ArrayBuffer（VIDEO_RESOURCE 即内嵌短视频）

→ **导出后的 mp4 就是普通视频文件**，可交给 `AVPlayer` / `Video` 组件按普通视频播放（官方未针对这条链路写"动态照片转视频"的专门指南，属**推断**：导出的 `VIDEO_RESOURCE` 文件扩展名为 `.mp4`、且 `MovingPhotoView` 内部用 AVPlayer 播放同一视频）。

### 6.3 有无官方"动态照片转静态/视频"的指导？

**结论：没有专门的转换指南页。** 官方只有：
- "读取动态照片资源"（`requestContent` 导出图片/视频）；
- 创建方向的 `MediaAssetChangeRequest.createAssetRequest` + `addResource(IMAGE_RESOURCE/VIDEO_RESOURCE)`（图片 + 视频 → 动态照片资产）。

**推断**：官方语义是"**动态照片 = 图片 + 视频的配对**"，因此"转静态"= 取 IMAGE_RESOURCE，"转视频"= 取 VIDEO_RESOURCE，**不需要专门的转换 API**。反向（图片 + 视频 → 动态照片）在沙箱侧由 `loadMovingPhoto` 完成，在媒体库侧由 `createAssetRequest(... subtype: MOVING_PHOTO)` + `addResource` 完成。

### 6.4 官方创建示例（可用于反向校验：图片+视频 → 动态照片）

`guides/.../访问和管理动态照片资源.md` 第 74–93 行（原样摘录核心）：

```ts
let context: Context = this.getUIContext().getHostContext() as common.UIAbilityContext;
let phAccessHelper = photoAccessHelper.getPhotoAccessHelper(context);
// Ensure that the assets specified by imageFileUri and videoFileUri exist.
let imageFileUri = 'file://' + context.filesDir + '/create_moving_photo.jpg';
let videoFileUri = 'file://' + context.filesDir + '/create_moving_photo.mp4';

let assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
  photoAccessHelper.MediaAssetChangeRequest.createAssetRequest(context,
    photoAccessHelper.PhotoType.IMAGE, 'jpg', {
      title: 'moving_photo',
      subtype: photoAccessHelper.PhotoSubtype.MOVING_PHOTO
    });

assetChangeRequest.addResource(photoAccessHelper.ResourceType.IMAGE_RESOURCE, imageFileUri);
assetChangeRequest.addResource(photoAccessHelper.ResourceType.VIDEO_RESOURCE, videoFileUri);

await phAccessHelper.applyChanges(assetChangeRequest);
```

> 该示例用 `SaveButton`（安全控件）触发，因此**无需申请 `ohos.permission.WRITE_IMAGEVIDEO`**（官方原文第 25 行："使用安全控件保存动态照片资源，无需申请相册管理模块权限 'ohos.permission.WRITE_IMAGEVIDEO'，允许用户通过点击按钮临时获取存储权限"）。

---

## 7. 功耗 / 性能 / 内存注意

### 7.1 官方明确说明（动态照片直接相关）

1. **AVPlayer 并发 ≤ 3**（组件头信息 + 指南约束原文）：
   > 该组件使用 AVPlayer 进行播放，同时开启的 AVPlayer 个数不建议超过 3 个，超过 3 个可能会出现视频播放卡顿现象。
   → **列表/瀑布流里不要同时挂多个播放中的 MovingPhotoView**。
2. **`repeatPlay` 与 `autoPlay`、长按播放互斥**：`repeatPlay` 设置时另两者均不生效（避免无限循环带来的持续解码）。
3. **`refreshMovingPhoto()` 会打断当前行为，"使用时要谨慎"**（API 参考原文）。
4. **默认不自动播放**（`autoPlay` 默认 `false`）→ 静态封面展示是默认低功耗形态。
5. **后台/析构兜底**：`best/功耗/应用功耗优化/前台任务低功耗/前台资源合理使用/不可见组件低功耗建议/不可见组件低功耗建议.md` 第 19 行原文：
   > 在 HarmonyOS 中已对一些常见的不可见组件刷新问题进行兜底，例如组件在应用切后台（onBackground()）、组件析构（aboutToDisappear()）等生命周期事件中，**会终止组件的各种行为来保证功耗**。但在另一些情况下，当组件已经实际不在屏幕上显示后，组件仍可能继续产生绘制任务…
6. **系统不抑制"划出屏幕的动效组件"**（同文件第 22–25 行原文）：
   > 开发者使用 ImageAnimator、Canvas、XComponent、Video 等组件，由于这些组件的绘制效果通常由开发者所配置的控制器来控制，当系统感知到该组件并非可见时，三方实现的自定义控制器以及与该组件相关自定义绘制进程任务无法被系统兜底停止。
   > 一个正常的动效组件不可见后，但仍挂载在组件树上，组件并未被析构。**例如一个长列表滚动场景，当一个动效组件短暂被划出屏幕外时，该组件仍有在下一个时机重新绘制刷新的可能**…此情况下，系统不会抑制组件的刷新行为。
7. **审核会检测"前台不可见动效"空跑**（`best/功耗/应用功耗分析/前台不可见动效问题分析/前台不可见动效问题分析.md` 第 9、13–17、21 行原文）：
   > 在应用提交至应用市场上架审核时，会检测动效在不可见时是否存在空刷的问题。
   > 以动图组件为例，当动图进入不可见状态但组件缺乏回调机制，或回调后未能成功停止，动图可能在软件全场景下空跑，导致严重的功耗异常和发热问题。

### 7.2 可见性自动暂停（重要：官方**没有**"MovingPhotoView 自动暂停"的说明）

- **官方未在任何文档中声明"MovingPhotoView 在不可见时自动暂停播放"**（全镜像检索无此表述）。
- 官方给的是**通用感知能力** + **通用低功耗要求**：
  - 指南：`guides/应用框架/ArkUI（方舟UI框架）/UI开发 (ArkTS声明式开发范式)/UI系统场景化能力/感知组件可见性/感知组件可见性.md` 第 15 行原文：
    > 资源按需加载与释放（例如，组件不可见时，释放组件使用的图片、视频等资源）
  - API：`api/应用框架/ArkUI（方舟UI框架）/ArkTS组件/通用事件/组件变化事件/组件可见区域变化事件/组件可见区域变化事件.md`（`onVisibleAreaChange`）

**推断（实现建议，非官方指导）**：在列表场景应自行用 `onVisibleAreaChange`（或 `LazyForEach` 回收）配合 `controller.stopPlayback()` 控制，并把 `autoPlay` 保持 `false`，只在用户主动交互时 `startPlayback()`。
> 注意：`MovingPhotoView` **不支持 `expandSafeArea`**、**不支持动态属性设置**（官方明确），所以"按可见性动态改属性"这条路本身也受限，应以控制器方法（`startPlayback`/`stopPlayback`）为主。

### 7.3 相关通用功耗规则（非动态照片专属）

- `best/功耗/应用功耗优化/前台任务低功耗/前台资源合理使用/视频场景编解码低功耗规则/视频场景编解码低功耗规则.md` 第 12–13 行原文：
  > - 视频应用需使用视频硬件编解码器。
  > - 视频场景应使用专用硬件解码器(VDEC)，其功耗效率显著优于 CPU 软解码。
  （MovingPhotoView 内部是 AVPlayer，硬解由系统承担 —— **推断**）
- 检索结果：**镜像中没有"动态照片功耗/性能"专属最佳实践页**（`best/_index/功耗.md`、`best/_index/性能.md`、`best/_index/媒体.md` 全文检索 `动态照片`/`MovingPhoto` 仅命中医美场景文档与相机文档）。

---

## 8. API 变更（镜像 releases 分区 + 本地 SDK 对照）

### 8.1 镜像覆盖范围（重要）

`releases/` 分区**仅有 HarmonyOS 6.1.0(23)**：
`releases/版本说明/HarmonyOS 6.1.0(23)/{版本概览.md, OS平台能力/OS新增和增强特性.md, OS平台能力/API变更清单/6.1.0(23) Beta1引入的变更/*, .../Beta2引入的变更/*, OS平台能力/OS平台行为变更说明/*}`

→ **镜像中不存在 API 24 / 25 / 26 的版本说明或 API 变更清单**。以下为 API 23 相关条目。

### 8.2 API 23（6.1.0(23) Beta1）动态照片相关变更

**路径**：`releases/版本说明/HarmonyOS 6.1.0(23)/OS平台能力/API变更清单/6.1.0(23) Beta1引入的变更/Media Library Kit.md`

| 变更类型 | 条目（原文摘录） | 行号 |
|---|---|---|
| 新增 API | 类名：`PickerController`；`setMovingPhotoState(movingPhotoState: photoAccessHelper.MovingPhotoBadgeStateType): Promise<void>;` | 87–91 |
| 新增 API | 类名：`BaseSelectOptions`；`globalMovingPhotoState?: MovingPhotoBadgeStateType;` | 430–434 |
| 新增 API | 类名：`photoAccessHelper`；`class AutoPlayScene`（`sceneType: SceneType;` / `playMode: PlayMode;`） | 528–539 |
| 新增 API | 类名：`BaseSelectOptions`；`autoPlayScenes?: Array<AutoPlayScene>;` | 416–420 |
| 新增（导出面） | `export { photoAccessHelper, sendablePhotoAccessHelper, MovingPhotoView, MovingPhotoViewController, MovingPhotoViewAttribute, ... }` 多次出现（属 `.d.ts` 导出清单整体刷新，**非组件新增接口**） | 639–745 |

**枚举来源（API 23 新增）**：`api/.../Enums.md` 第 405–413 行原文：
> `#### MovingPhotoBadgeStateType22+`：`NOT_MOVING_PHOTO`=0 非动态照片、`MOVING_PHOTO_ENABLED`=1 打开动态照片效果、`MOVING_PHOTO_DISABLED`=2 关闭动态照片效果。
> `#### SceneType23+`

**官方相机侧增强（API 23）**：`releases/OS新增和增强特性-610.md` 第 130 行原文：
> 新增支持 HDR 动态照片拍摄能力，即组成动态照片的静态照片与动态短视频均为高动态范围（HDR）内容。（[指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/camera-moving-photo#hdr动态照片)）

### 8.3 6.1.0(23) Beta2 动态照片相关变更

**路径**：`releases/.../6.1.0(23) Beta2引入的变更/Media Library Kit.md` 存在，但按关键词检索 **未发现 `MovingPhoto`/动态照片条目**（Beta2 的 Media Library Kit 变更集中在 Picker 组件回调等，未见动态照片相关）。全 releases 目录检索 `MovingPhotoView` 仅命中 Beta1 的导出清单条目（第 639–745 行），**未见任何"废弃 / 删除 API"涉及动态照片**。

### 8.4 API 26（本地 SDK）对照结论

对照 `@ohos.multimedia.movingphotoview.d.ts`（API 26.0.0）与镜像 API 23 文档：

- **组件层面：完全一致，无新增、无废弃。** 最大 `@since` = 20（`onPrepared`）；`MovingPhotoViewOptions.movingPhoto` 在 API 26 声明中仍是**必填**（无 `?`）。
- 相册侧：`MediaAssetManager.requestMovingPhoto`（12+，`801 Capability not supported [since 18]`）、`loadMovingPhoto`（12+，`@atomicservice [since 14]`）签名与角色在 API 26 未变。
- `MovingPhoto` 接口在 API 26 仍只有 `requestContent`×3 + `getUri()`（`@since 12`）。
- API 23 新增的 `AutoPlayScene` / `SceneType` / `GridPinchModeType` / `GridLevel` 等在 API 26 `.d.ts` 中均在（`@since 23`），属**图库/Picker 场景**的自动播放策略，与 App 内 `MovingPhotoView` 播放无关。

---

## 9. 对 NGA 论坛客户端（网络动态照片展示）的可行性判定

> 本节为**基于官方能力的推断与结论**，非官方文档原文；推断所依据的官方条文均在上文标注。

### 9.1 问题定义

NGA 帖子里可能存在"动态照片"（用户 iPhone/鸿蒙手机拍摄的 Live Photo 上传到服务端）。客户端要"把网络上的动态照片显示出来"。

### 9.2 场景逐项判定

| 场景 | 是否可行 | 可行程度 / 前提 |
|---|---|---|
| **A. 展示静态封面**（帖内缩略图、列表） | ✅ **完全可行** | 只要服务端能给出**封面图 URL**（或帖内 attachment 的 jpg），按普通 `Image` + 网络加载即可。**与动态照片能力无关**，是既有的图片链路。 |
| **B. 播放"相册来源"的动态照片** | ✅ **完全可行** | ① 用户从图库插入/选取（`PhotoViewPicker` + `MOVING_PHOTO_IMAGE_TYPE`）→ `getAssets` → `requestMovingPhoto` → `MovingPhotoView`。Picker 路径**豁免 `READ_IMAGEVIDEO` 权限**。② 官方对该路径有完整示例（§3.5）。 |
| **C. 播放"网络下载的动态照片"** | ⚠️ **有条件可行** | **前提：服务端必须能分别提供封面图与短视频两个独立文件**（或客户端能从单一容器中解出两者）。流程：下载 jpg + mp4 到应用沙箱 → `MediaAssetManager.loadMovingPhoto(context, 'file://'+filesDir+'/x.jpg', 'file://'+filesDir+'/x.mp4')` → `MovingPhotoView`。该接口**不需要相册权限**、**不写相册**，是纯内存/沙箱对象。**官方无此场景示例，属能力组合推断**。 |
| **D. 直接把网络 URL 交给 MovingPhotoView / loadMovingPhoto** | ❌ **不可行** | `loadMovingPhoto` 参数被官方限定为"**应用沙箱**动态照片的图片/视频 uri"；组件"只接收构造完成的 MovingPhoto 对象"。**没有 URL / ArrayBuffer → MovingPhoto 的接口**（§5）。 |
| **E. 只有单一"动态照片文件"（合封），无独立视频** | ❌ **官方能力下不可行** | 官方无"从单文件/自定义容器解析动态照片"的接口；`loadMovingPhoto` 必须图片 + 视频两个 uri（§5.2）。需要自行解封装（**超出本报告范围，官方文档未提供方案**）。 |
| **F. 端上把"图片 + 视频"合成新的动态照片并入库** | ✅ 可行（但会写相册） | `MediaAssetChangeRequest.createAssetRequest(..., subtype: MOVING_PHOTO)` + `addResource(IMAGE_RESOURCE/VIDEO_RESOURCE)` + `applyChanges`（§6.4）。**需 `SaveButton` 安全控件（免 `WRITE_IMAGEVIDEO`）或申请写权限** —— 论坛客户端一般不应擅自写用户相册。**不需要入库时优先走 C（`loadMovingPhoto`）**。 |
| **G. 网络动态照片降级为静态图** | ✅ 完全可行 | 用服务端封面图（最简单）；若有 mp4 无封面，可用系统视频缩略图能力（`AVImageGenerator`，见 `guides/媒体/媒体开发概览/媒体开发概览.md` 第 701–703 行指向的"使用AVImageGenerator提取视频指定时间图像"）或自行取首帧。 |
| **H. 播放效果完全对齐系统图库（长按播放 + 1.1 倍放大 + 自动播放）** | ✅ 组件原生具备 | 长按播放是组件内置行为；1.1 倍放大是组件内置行为（官方明确）。**但"组件不可见自动暂停"官方未声明**，需要自行控制（§7.2）。 |

### 9.3 关键工程风险（推断）

1. **服务端是否分离存储图片与视频**：这是 C 方案成立与否的**唯一决定因素**。若 NGA 服务端只存单个合封文件，官方能力无法直接播放（E）。
2. **`loadMovingPhoto` 只接受 `file://<bundleName>/data/storage/...` 形态的沙箱路径**：官方示例给的是 `context.filesDir`（即 `.../haps/<module>/files`）拼接；`{bundleName}` 占位符必须替换为真实 bundleName。
3. **不缓存会反复落盘**：每次播放都要把 jpg + mp4 落到沙箱（官方无"从内存构造"接口），列表场景必须做**播放级/查看级的懒加载 + 缓存 + 清理**。
4. **`MovingPhotoView` 不能用于预览器**，且**不支持 `expandSafeArea` / 动态属性设置** → 详情页沉浸式全屏布局需要避开该组件或调整结构。
5. **并发 ≤ 3 个 AVPlayer**：列表内不可多个同时播放。
6. **类型不一致坑**：官方示例把 `undefined` 传给必填的 `movingPhoto` 字段（§4.2），在 API 26 严格类型下需自行兜底。

### 9.4 一句话结论

> **"把网络上的动态照片显示出来"在官方能力下是"有条件可行的"：**
> - **静态封面**：完全可行，且是官方默认形态（`autoPlay` 默认 false、长按才播）。
> - **真播放动态效果**：只有当服务端**分别提供封面图与短视频**（或客户端能自行解出两者）时可行 —— 下载到沙箱后用 `MediaAssetManager.loadMovingPhoto(context, imageFileUri, videoFileUri)` 构造 `MovingPhoto`（**无需相册权限**）再交给 `MovingPhotoView`。
> - **官方不支持**：直接喂网络 URL、从 `ArrayBuffer` 构造、从单一合封文件解析动态照片。

---

## 附录 A：代码骨架（面向本工程 API 26，可直接套用的最小实现）

> 以下为本报告**综合官方示例改写**的骨架（非官方原文逐字摘录），标注为"改写"。

```ts
import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit';

@Entry
@Component
struct MovingPhotoDemo {
  @State movingPhoto: photoAccessHelper.MovingPhoto | undefined = undefined;
  // 官方：controller 用于控制播放状态；一个 controller 对应一个 MovingPhotoView
  private controller: MovingPhotoViewController = new MovingPhotoViewController();

  // 通路 C：网络下载到沙箱后构造 MovingPhoto（官方 loadMovingPhoto 用法）
  private async loadFromSandbox(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as Context;
    const imageUri = 'file://' + ctx.filesDir + '/mv_cover.jpg';
    const videoUri = 'file://' + ctx.filesDir + '/mv_clip.mp4';
    try {
      this.movingPhoto =
        await photoAccessHelper.MediaAssetManager.loadMovingPhoto(ctx, imageUri, videoUri);
    } catch (err) {
      console.error(`loadMovingPhoto failed: ${err.code}, ${err.message}`);
    }
  }

  build() {
    Column() {
      if (this.movingPhoto !== undefined) {
        MovingPhotoView({
          // 注意：本地 SDK 声明该字段必填（非可选），官方示例却传 undefined，此处做兜底
          movingPhoto: this.movingPhoto!,
          controller: this.controller
        })
          .width('100%')
          .height(240)
          .objectFit(ImageFit.Cover)   // 默认 Cover
          .muted(true)                 // 默认 false
          .autoPlay(false)             // 默认 false：静态封面，长按才播（低功耗默认）
          .repeatPlay(false)           // 与 autoPlay / 长按播放互斥
          .onPrepared(() => { console.info('onPrepared'); })
          .onStart(() => { console.info('onStart'); })
          .onPause(() => { console.info('onPause'); })
          .onFinish(() => { console.info('onFinish'); })
          .onStop(() => { console.info('onStop'); })
          .onComplete(() => { console.info('onComplete'); })
          .onError(() => { console.error('onError'); })
      } else {
        // 降级：静态封面（官方推荐用 PhotoAsset.getThumbnail 或直接 Image 加载封面 URL）
        Image($r('app.media.placeholder')).width('100%').height(240).objectFit(ImageFit.Cover)
      }
    }
  }
}
```

**可否直接用于 API 26**：
- ✅ `import { photoAccessHelper, MovingPhotoView, MovingPhotoViewController } from '@kit.MediaLibraryKit';` —— **API 22 及之后版本的官方推荐写法**，API 26 适用（本地 `.d.ts` 无 `MovingPhotoViewAttribute` 强制导入要求）。
- ⚠️ `movingPhoto: this.movingPhoto!` 的 `!` 断言：官方示例直接传 `undefined`；本地声明为必填，是否报错取决于工程严格空值设置。
- ⚠️ `ctx.filesDir` 拼接需保证文件真实存在；官方示例注释原文："需要确保 imageFileUri 和 videoFileUri 对应的资源在应用沙箱存在。"
- ⚠️ 若走相册通路，需 `photoAccessHelper.MediaAssetManager.requestMovingPhoto(...)`，Picker 方式豁免 `ohos.permission.READ_IMAGEVIDEO`。

---

## 附录 B：结论可信度标注

| 结论 | 等级 |
|---|---|
| 动态照片 = 图片 + 短视频，视频 ≤ 10s | **官方明确说明** |
| 三条来源通路：相册 asset / 沙箱 fileUri 对 / 无网络 URL | **官方明确说明**（"无网络 URL"由接口参数限定 + 全量检索缺失共同证明） |
| `MovingPhotoView` 只接收构造完成的 MovingPhoto | **官方明确说明**（指南原文） |
| `loadMovingPhoto` 不需要相册权限 | **官方明确说明**（API 参考页无"需要权限"字段 + 本地 `.d.ts` 无 `@permission`） |
| `requestMovingPhoto` 需 `READ_IMAGEVIDEO`，Picker 豁免 | **官方明确说明** |
| 属性/事件/控制器全清单与起始版本 | **官方明确说明**（API 参考页 + 本地 API 26 `.d.ts` 双重印证） |
| 并发 AVPlayer ≤ 3 / 不支持预览器 / 不支持 expandSafeArea / 长按 1.1 倍 | **官方明确说明** |
| API 21–26 组件无新增接口 | **官方明确说明**（本地 API 26 `.d.ts` 声明直接证明） |
| 镜像缺 API 24/25/26 变更条目 | **事实陈述**（镜像 releases 仅含 6.1.0(23)） |
| 服务端需分离图片与视频才能播放网络动态照片 | **推断**（由官方接口参数限定推导） |
| 列表场景应自行用可见性 + `stopPlayback` 控制（组件不会自动暂停） | **推断**（官方无 MovingPhotoView 自动暂停说明，但通用低功耗文档要求停止空跑） |
| 导出的 VIDEO_RESOURCE 可直接当普通 mp4 播放 | **推断**（依据扩展名示例与组件内部 AVPlayer 实现说明） |
| `RequestOptions.deliveryMode` 是否必须 `FAST_MODE` | **官方未明确**（官方示例统一用 `FAST_MODE`，无强制说明） |
| `MovingPhotoViewAttribute` 自动导入机制 | **官方明确说明**（API 22 起编译工具链自动导入，无需手动导入） |

---

*报告生成：基于技能镜像 API 23 + 本地 SDK 26.0.0.105 声明交叉校验。所有官方示例代码均为文档原文摘录（缩进可能与原文渲染有细微差异，内容未改动）。*
