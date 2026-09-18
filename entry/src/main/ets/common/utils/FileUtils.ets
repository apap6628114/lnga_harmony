/**
 * 文件系统通用工具。
 */

import { fileIo } from '@kit.CoreFileKit'
import { Logger, DOMAIN_UI, formatError } from './Logger'

const logger = new Logger(DOMAIN_UI, 'FileUtils')

/**
 * 递归删除目录（连同其中的全部文件与子目录），失败只记日志、不抛错。
 *
 * **不要用 `fileIo.rmdirSync` 直接删非空目录**：据它的声明错误码推断（列出
 * `13900032 - Directory not empty`），它只删空目录。拿它清缓存目录/导出目录会**静默失败**：
 * 异常被 `catch` 吞掉后日志之外没有任何迹象，目录原地不动，调用方却以为已经清干净
 * （本工程的 `SettingsPanel.clearCache` 与动态照片导出目录都踩过这一点）。
 * 因此这里先递归清空内容，最后再删目录本身——即便 `rmdirSync` 实际支持非空删除，
 * 这个写法也仍然正确，只是多几次系统调用。
 *
 * 子项类型一律用 **`lstatSync`** 判断，不能用 `statSync`：后者会跟随符号链接，
 * 一个指向目录的软链会被判成目录、于是递归**清空链接目标的内容**并越过本目录边界
 * （随后的 `rmdirSync` 还会因目标不是空目录而失败，留下链接本身）。
 * `lstat` 不解引用，软链按"链接文件"处理，直接 `unlinkSync` 删链接即可。
 *
 * @param dirPath 沙箱目录绝对路径
 */
export function removeDirRecursively(dirPath: string): void {
  try {
    if (!fileIo.accessSync(dirPath)) {
      return
    }
    const names: string[] = fileIo.listFileSync(dirPath)
    for (let i = 0; i < names.length; i++) {
      const childPath: string = `${dirPath}/${names[i]}`
      try {
        if (fileIo.lstatSync(childPath).isDirectory()) {
          removeDirRecursively(childPath)
        } else {
          /* 普通文件与符号链接都走这里：`unlinkSync` 删的是链接本身，不会波及目标 */
          fileIo.unlinkSync(childPath)
        }
      } catch (err) {
        logger.verbose('[FileUtils] remove child failed: %{public}s', formatError(err))
      }
    }
    fileIo.rmdirSync(dirPath)
  } catch (err) {
    logger.verbose('[FileUtils] remove dir failed: %{public}s', formatError(err))
  }
}
