/**
 * 相册发图：一个「图片」入口，**自适应动态照片**。
 *
 * ## 一个入口，两种结果
 * 用户在编辑器里只看到「图片」一个按钮（见 `EditorFormatBar`），选中什么就按什么规则发：
 *
 * - 选中**动态照片** → 自动导出「封面 + 视频」两半到沙箱，调用方按动态照片上传；
 * - 选中**普通图片**（或动态照片导出失败）→ 就地上传这一张静态图。
 *
 * ## 怎么判断是不是动态照片
 * 子类型是资产自身的属性，与封面/视频内容无关：
 *
 * ```
 * asset.get(PhotoKeys.PHOTO_SUBTYPE) === PhotoSubtype.MOVING_PHOTO   // 3
 * ```
 *
 * `PhotoAsset.get()` 的声明里写明：除 `'uri'` / `'media_type'` / `'subtype'` / `'display_name'`
 * 四个成员外，其余成员都必须先写进 `fetchColumns`。因此 `'subtype'` **免 fetchColumns**
 * 直接可取，判定不需要额外列、也不需要相册读取权限。
 *
 * 选择器另有一条 API 22+ 的角标通路（`PhotoSelectOptions.isMovingPhotoBadgeShown` +
 * `PhotoSelectResult.movingPhotoBadgeStates`）：本模块只把它当**视觉提示**（让用户选之前
 * 就能看出哪张是动态照片），判定仍以 `subtype` 为准——用户在系统相册里关掉「动态效果」
 * 时角标状态是 `MOVING_PHOTO_DISABLED`，那依然是一张动态照片。
 *
 * ## 为什么导出链路是这一串
 * Picker 只给一个 URI，而 `MediaAssetManager.requestMovingPhoto` 要的是 `PhotoAsset`。
 * 官方给出的免权限组合（三处接口说明都写了「通过 picker 的方式调用该接口，不需要申请
 * `ohos.permission.READ_IMAGEVIDEO`」）是：
 *
 * ```
 * PhotoViewPicker（MIMEType = image/*，含动态照片）
 *   → getAssets(URI 谓词) 反查 PhotoAsset
 *   → 判 subtype
 *   → MediaAssetManager.requestMovingPhoto(...)
 *   → MovingPhoto.requestContent(imageFileUri, videoFileUri)   // 两半落到沙箱
 * ```
 *
 * ## 产物
 * 落在 `cacheDir/mphoto_upload/<时间戳>/`，文件名 `upload.jpg` / `video.mp4` 与官方客户端
 * 上传时的原始名一致（真实动态照片帖的附件元数据里 `url_utf8_org_name` 正是这两个值）。
 * 调用方上传结束后必须调用 {@link releaseExportedMovingPhoto} 删除整个目录。
 */

import { photoAccessHelper } from '@kit.MediaLibraryKit'
import { fileIo } from '@kit.CoreFileKit'
import { dataSharePredicates } from '@kit.ArkData'
import { withTimeout } from '../utils/TimeoutUtils'
import { removeDirRecursively } from '../utils/FileUtils'
import { Logger, DOMAIN_UI, formatError } from '../utils/Logger'

const logger = new Logger(DOMAIN_UI, 'MovingPhotoExport')

/** 导出目录名（位于应用 `cacheDir` 下，上传结束即删）。 */
const EXPORT_DIR_NAME: string = 'mphoto_upload'

/** 封面导出文件名（与官方客户端上传时的原始名一致）。 */
export const EXPORT_COVER_NAME: string = 'upload.jpg'

/** 视频导出文件名（与官方客户端上传时的原始名一致）。 */
export const EXPORT_VIDEO_NAME: string = 'video.mp4'

/** 等待 `onDataPrepared` 的上限：超时视为该资产不是可用动态照片。 */
const REQUEST_TIMEOUT_MS: number = 10000

/**
 * 历史导出目录的判定阈值（秒）。
 *
 * 正常流程上传一结束就删目录，所以年龄超过这个值的残留必定来自异常退出（被系统回收 /
 * 崩溃）；清理时留足余量，不去碰本次刚建好的产物。
 */
const STALE_EXPORT_AGE_SECONDS: number = 600

/** 单次进入选择入口时最多清理的残留目录数（主线程同步 IO，分批消化）。 */
const MAX_PRUNE_PER_RUN: number = 8

/** 导出到沙箱的动态照片两半。 */
export class ExportedMovingPhoto {
  /** 封面（静态图）沙箱绝对路径。 */
  coverPath: string = ''
  /** 视频沙箱绝对路径。 */
  videoPath: string = ''
  /** 本次导出的临时目录（上传结束后整体删除）。 */
  dirPath: string = ''

  /**
   * @param coverPath 封面沙箱绝对路径
   * @param videoPath 视频沙箱绝对路径
   * @param dirPath 临时目录绝对路径
   */
  constructor(coverPath: string, videoPath: string, dirPath: string) {
    this.coverPath = coverPath
    this.videoPath = videoPath
    this.dirPath = dirPath
  }
}

/**
 * 一次「图片」入口的选择结果。
 *
 * 调用方拿到它之后只有两条路：`movingPhoto !== null` 走动态照片上传，否则按普通图片上传
 * （此时 {@link uri} 指向该资产的静态图——动态照片时它就是封面图，普通图片时就是它本身）。
 */
export class PickedImage {
  /** Picker 返回的资产 URI；普通图片上传与动态照片降级上传都用它读字节。 */
  uri: string = ''

  /** 资产文件名（含扩展名），作为上传时的原始文件名。 */
  fileName: string = ''

  /** 动态照片导出产物；`null` 表示按普通图片发送。 */
  movingPhoto: ExportedMovingPhoto | null = null

  /**
   * 所选资产**是动态照片、但两半没能导出**。
   *
   * 与「本来就是普通图片」区分开：这种情况用户预期发动态照片，结果只会发出去一张静态图，
   * 调用方必须提示，不能静默降级。
   */
  movingPhotoExportFailed: boolean = false

  /**
   * @param uri 资产 URI
   * @param fileName 资产文件名
   */
  constructor(uri: string, fileName: string) {
    this.uri = uri
    this.fileName = fileName
  }
}

/**
 * 动态照片数据处理器：把 `requestMovingPhoto` 的回调桥接成一次性 Promise。
 *
 * 官方示例同样是「class + 箭头函数属性」实现 `MediaAssetDataHandler`（箭头函数保证
 * 回调里 `this` 不丢）。
 */
class MovingPhotoDataHandler implements photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> {
  /** 一次性兑现函数（`onDataPrepared` 正常情况下只触发一次）。 */
  private resolver: ((photo: photoAccessHelper.MovingPhoto) => void) | undefined = undefined

  /**
   * 注入兑现函数。
   *
   * @param resolver 兑现函数
   */
  setResolver(resolver: (photo: photoAccessHelper.MovingPhoto) => void): void {
    this.resolver = resolver
  }

  /**
   * 系统在动态照片就绪时回调。
   *
   * @param data 动态照片对象
   */
  onDataPrepared = (data: photoAccessHelper.MovingPhoto): void => {
    const resolver: ((photo: photoAccessHelper.MovingPhoto) => void) | undefined = this.resolver
    this.resolver = undefined
    if (resolver !== undefined && data !== undefined) {
      resolver(data)
    }
  }
}

/**
 * 打开相册选择一张图片（`image/*`，动态照片混在其中）。
 *
 * `isMovingPhotoBadgeShown` 打开选择器里的动态照片角标（API 22+，本工程 API 26 可用）：
 * 用户在点选之前就能看出哪张是动态照片，避免「以为发的是静态图、结果发出动态照片」这类
 * 预期错位。它只影响展示，判定仍走 {@link isMovingPhotoAsset}。
 *
 * @returns 所选资产的 URI；用户取消时返回空串
 */
async function pickImageUri(): Promise<string> {
  const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker()
  const result: photoAccessHelper.PhotoSelectResult = await picker.select({
    MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
    maxSelectNumber: 1,
    isMovingPhotoBadgeShown: true
  })
  const uris: string[] = result.photoUris
  return uris.length > 0 ? uris[0] : ''
}

/**
 * 按 URI 反查媒体库资产。
 *
 * 走 Picker 授权的 URI 反查，不需要相册读取权限（官方「指定 URI 获取图片或视频资源」的写法）。
 *
 * @param ctx 应用上下文
 * @param uri Picker 返回的资产 URI
 * @returns 资产；反查不到时返回 undefined
 */
async function findAssetByUri(ctx: Context, uri: string): Promise<photoAccessHelper.PhotoAsset | undefined> {
  const helper = photoAccessHelper.getPhotoAccessHelper(ctx)
  const predicates: dataSharePredicates.DataSharePredicates = new dataSharePredicates.DataSharePredicates()
  predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri)
  const options: photoAccessHelper.FetchOptions = {
    fetchColumns: [photoAccessHelper.PhotoKeys.TITLE],
    predicates: predicates
  }
  const fetchResult: photoAccessHelper.FetchResult<photoAccessHelper.PhotoAsset> =
    await helper.getAssets(options)
  try {
    const asset: photoAccessHelper.PhotoAsset = await fetchResult.getFirstObject()
    return asset
  } catch (err) {
    /* 结果集为空时 getFirstObject 抛错：按"没找到"处理。 */
    logger.verbose('[MovingPhotoExport] no asset for uri: %{public}s', formatError(err))
    return undefined
  } finally {
    fetchResult.close()
  }
}

/**
 * 判断资产是不是动态照片（见文件头「怎么判断是不是动态照片」）。
 *
 * @param asset 媒体库资产
 * @returns 是否动态照片
 */
function isMovingPhotoAsset(asset: photoAccessHelper.PhotoAsset): boolean {
  try {
    const subtype: number = asset.get(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE) as number
    return subtype === photoAccessHelper.PhotoSubtype.MOVING_PHOTO
  } catch (err) {
    /* 取不到 subtype 时按普通图片处理：宁可发一张静态图，也不要卡住整条发送流程 */
    logger.warn('[MovingPhotoExport] read subtype failed: %{public}s', formatError(err))
    return false
  }
}

/**
 * 请求动态照片对象。
 *
 * `requestMovingPhoto` 通过 dataHandler 异步交付，因此这里用一次性的 resolver 桥接，
 * 并加超时兜底（资产不是动态照片时回调可能永不到达）。
 *
 * @param ctx 应用上下文
 * @param asset 媒体库资产
 * @returns 动态照片对象
 */
async function requestMovingPhoto(ctx: Context, asset: photoAccessHelper.PhotoAsset): Promise<photoAccessHelper.MovingPhoto> {
  const handler: MovingPhotoDataHandler = new MovingPhotoDataHandler()
  const delivered: Promise<photoAccessHelper.MovingPhoto> =
    new Promise<photoAccessHelper.MovingPhoto>((resolve: (photo: photoAccessHelper.MovingPhoto) => void): void => {
      handler.setResolver(resolve)
    })
  const options: photoAccessHelper.RequestOptions = {
    deliveryMode: photoAccessHelper.DeliveryMode.HIGH_QUALITY_MODE
  }
  await photoAccessHelper.MediaAssetManager.requestMovingPhoto(ctx, asset, options, handler)
  return withTimeout(delivered, REQUEST_TIMEOUT_MS)
}

/**
 * 判断文件是否存在且非空。
 *
 * @param filePath 沙箱绝对路径
 * @returns 是否可用
 */
function isUsableFile(filePath: string): boolean {
  try {
    return fileIo.accessSync(filePath) && fileIo.statSync(filePath).size > 0
  } catch (err) {
    return false
  }
}

/**
 * 把一张已判定为动态照片的资产导出成沙箱里的两半。
 *
 * **目录一旦建出来，任何一步失败都必须把它删掉**：不能只把 `requestContent` 包起来——
 * 末尾的 `statSync`（乃至以后在此追加的逻辑）抛出去，调用方只会看到"降级成静态图"，
 * 而目录会永久留在 `cacheDir` 里（视频可达数十 MB）。
 *
 * @param ctx 应用上下文
 * @param asset 媒体库资产
 * @returns 导出结果（失败抛错，由 {@link pickImage} 转成降级）
 */
async function exportMovingPhoto(ctx: Context, asset: photoAccessHelper.PhotoAsset): Promise<ExportedMovingPhoto> {
  const photo: photoAccessHelper.MovingPhoto = await requestMovingPhoto(ctx, asset)
  const dirPath: string = `${ctx.cacheDir}/${EXPORT_DIR_NAME}/${Date.now()}`
  fileIo.mkdirSync(dirPath, true)
  try {
    const coverPath: string = `${dirPath}/${EXPORT_COVER_NAME}`
    const videoPath: string = `${dirPath}/${EXPORT_VIDEO_NAME}`
    await photo.requestContent(`file://${coverPath}`, `file://${videoPath}`)
    if (!isUsableFile(coverPath) || !isUsableFile(videoPath)) {
      throw new Error('导出动态照片失败（内容为空）')
    }
    logger.info('[MovingPhotoExport] exported cover=%{public}d video=%{public}d',
      fileIo.statSync(coverPath).size, fileIo.statSync(videoPath).size)
    return new ExportedMovingPhoto(coverPath, videoPath, dirPath)
  } catch (err) {
    logger.warn('[MovingPhotoExport] export failed: %{public}s', formatError(err))
    removeDirRecursively(dirPath)
    throw err instanceof Error ? err : new Error('导出动态照片失败')
  }
}

/**
 * 清理 `cacheDir/mphoto_upload` 下的历史残留。
 *
 * 正常流程上传结束即删（见文件头），残留只有一个来源：进程在导出后被系统回收或崩溃。
 * 清理放在选择入口（幂等，且同一时刻只可能有一次选择流程），只删**年龄超过阈值**的目录，
 * 避免误伤本次刚建好的产物。
 *
 * 这里全是**主线程同步 IO**，所以每次最多清 {@link MAX_PRUNE_PER_RUN} 个：正常情况残留是 0 个，
 * 一次 `accessSync` + 一次 `listFileSync` 就结束；只有在异常路径反复触发、残留堆积时才会分批消化，
 * 不至于让「点图片按钮」本身变成可感知的卡顿。
 *
 * @param ctx 应用上下文
 */
function pruneStaleExports(ctx: Context): void {
  const root: string = `${ctx.cacheDir}/${EXPORT_DIR_NAME}`
  try {
    if (!fileIo.accessSync(root)) {
      return
    }
    const names: string[] = fileIo.listFileSync(root)
    const nowSeconds: number = Date.now() / 1000
    let removed: number = 0
    for (let i = 0; i < names.length && removed < MAX_PRUNE_PER_RUN; i++) {
      const childPath: string = `${root}/${names[i]}`
      try {
        if (nowSeconds - fileIo.statSync(childPath).mtime > STALE_EXPORT_AGE_SECONDS) {
          removeDirRecursively(childPath)
          removed += 1
        }
      } catch (err) {
        logger.verbose('[MovingPhotoExport] prune entry failed: %{public}s', formatError(err))
      }
    }
  } catch (err) {
    logger.verbose('[MovingPhotoExport] prune failed: %{public}s', formatError(err))
  }
}

/**
 * 「图片」入口的唯一选择函数：选一张图，是动态照片就顺手导出两半。
 *
 * 导出失败不抛错、也不阻断流程，而是置 {@link PickedImage.movingPhotoExportFailed} 让调用方
 * 降级为普通图片上传——用户手里那张封面静态图仍然可读，重选一遍是白费操作。
 *
 * @param ctx 应用上下文
 * @returns 选择结果；用户取消时返回 null
 */
export async function pickImage(ctx: Context): Promise<PickedImage | null> {
  pruneStaleExports(ctx)
  const uri: string = await pickImageUri()
  if (uri.length === 0) {
    return null
  }
  const picked: PickedImage = new PickedImage(uri, uri.split('/').pop() ?? 'image.jpg')
  const asset: photoAccessHelper.PhotoAsset | undefined = await findAssetByUri(ctx, uri)
  if (asset === undefined) {
    /*
     * 反查不到资产（结果集为空 / 201 权限 / 系统内部错误）：只能按普通图片发。
     * 这条路径用户在界面上看不出区别，所以必须留下 **warn** 级痕迹——线上「选了动态照片
     * 却发出静态图」的第一现场就在这里。
     */
    logger.warn('[MovingPhotoExport] asset lookup failed, treat as still image')
    return picked
  }
  if (!isMovingPhotoAsset(asset)) {
    return picked
  }
  try {
    picked.movingPhoto = await exportMovingPhoto(ctx, asset)
  } catch (err) {
    logger.warn('[MovingPhotoExport] export failed, fallback to still image: %{public}s', formatError(err))
    picked.movingPhotoExportFailed = true
  }
  return picked
}

/**
 * 删除导出产物（上传结束后必须调用，成功失败都要清）。
 *
 * @param exported 导出结果
 */
export function releaseExportedMovingPhoto(exported: ExportedMovingPhoto): void {
  removeDirRecursively(exported.dirPath)
}

/**
 * 读取导出文件到内存。
 *
 * @param filePath 沙箱绝对路径
 * @returns 文件内容；读取失败时返回 0 字节缓冲
 */
export function readExportedFile(filePath: string): ArrayBuffer {
  try {
    const stat: fileIo.Stat = fileIo.statSync(filePath)
    const buffer: ArrayBuffer = new ArrayBuffer(stat.size)
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY)
    try {
      fileIo.readSync(file.fd, buffer)
    } finally {
      fileIo.closeSync(file)
    }
    return buffer
  } catch (err) {
    logger.warn('[MovingPhotoExport] read failed: %{public}s', formatError(err))
    return new ArrayBuffer(0)
  }
}
