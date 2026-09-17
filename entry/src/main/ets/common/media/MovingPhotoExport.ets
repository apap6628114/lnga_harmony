/**
 * 发送动态照片：从相册选择一张动态照片，并把「封面 + 视频」两半导出到应用沙箱。
 *
 * ## 为什么是这条链路
 * Picker 只给一个 URI，而 `MediaAssetManager.requestMovingPhoto` 要的是 `PhotoAsset`。
 * 官方给出的免权限组合（三处接口说明都写了「通过 picker 的方式调用该接口，不需要申请
 * `ohos.permission.READ_IMAGEVIDEO`」）是：
 *
 * ```
 * PhotoViewPicker（MIMEType = image/movingPhoto）
 *   → getAssets(URI 谓词) 反查 PhotoAsset
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
 * 打开相册选择一张动态照片（Picker 已按 `image/movingPhoto` 过滤）。
 *
 * @returns 所选资产的 URI；用户取消时返回空串
 */
async function pickMovingPhotoUri(): Promise<string> {
  const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker()
  const result: photoAccessHelper.PhotoSelectResult = await picker.select({
    MIMEType: photoAccessHelper.PhotoViewMIMETypes.MOVING_PHOTO_IMAGE_TYPE,
    maxSelectNumber: 1
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
 * 递归删除导出目录（忽略失败）。
 *
 * @param dirPath 目录绝对路径
 */
function removeDir(dirPath: string): void {
  try {
    if (fileIo.accessSync(dirPath)) {
      fileIo.rmdirSync(dirPath)
    }
  } catch (err) {
    logger.verbose('[MovingPhotoExport] remove dir failed: %{public}s', formatError(err))
  }
}

/**
 * 选择并导出一张动态照片。
 *
 * @param ctx 应用上下文
 * @returns 导出结果；用户取消时返回 null（其余失败抛错，由调用方提示）
 */
export async function pickAndExportMovingPhoto(ctx: Context): Promise<ExportedMovingPhoto | null> {
  const uri: string = await pickMovingPhotoUri()
  if (uri.length === 0) {
    return null
  }
  const asset: photoAccessHelper.PhotoAsset | undefined = await findAssetByUri(ctx, uri)
  if (asset === undefined) {
    throw new Error('未找到所选的动态照片')
  }
  const photo: photoAccessHelper.MovingPhoto = await requestMovingPhoto(ctx, asset)
  const dirPath: string = `${ctx.cacheDir}/${EXPORT_DIR_NAME}/${Date.now()}`
  fileIo.mkdirSync(dirPath, true)
  const coverPath: string = `${dirPath}/${EXPORT_COVER_NAME}`
  const videoPath: string = `${dirPath}/${EXPORT_VIDEO_NAME}`
  try {
    await photo.requestContent(`file://${coverPath}`, `file://${videoPath}`)
  } catch (err) {
    logger.warn('[MovingPhotoExport] requestContent failed: %{public}s', formatError(err))
    removeDir(dirPath)
    throw new Error('导出动态照片失败')
  }
  if (!isUsableFile(coverPath) || !isUsableFile(videoPath)) {
    removeDir(dirPath)
    throw new Error('导出动态照片失败（内容为空）')
  }
  logger.info('[MovingPhotoExport] exported cover=%{public}d video=%{public}d',
    fileIo.statSync(coverPath).size, fileIo.statSync(videoPath).size)
  return new ExportedMovingPhoto(coverPath, videoPath, dirPath)
}

/**
 * 删除导出产物（上传结束后必须调用，成功失败都要清）。
 *
 * @param exported 导出结果
 */
export function releaseExportedMovingPhoto(exported: ExportedMovingPhoto): void {
  removeDir(exported.dirPath)
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
