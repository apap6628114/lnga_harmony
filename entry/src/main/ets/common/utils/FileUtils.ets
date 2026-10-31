/**
 * 文件系统通用工具。
 */

import { fileIo } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { Logger, DOMAIN_UI, formatError } from './Logger'

const logger = new Logger(DOMAIN_UI, 'FileUtils')

/**
 * 把文本按 UTF-8 编码分块写入已打开的 fd，直到全部写完。
 *
 * 为什么必须分块并校验返回值：`fileIo.writeSync(fd, content)` 的返回值是**实际写入的字节数**，
 * 单次调用**不保证写完整个字符串**（本工程真机实测过凭证/备份导出被截断，见设计稿 §13.3）。
 * 文件域治理写入（草稿/存档/迁移复制/导入写盘）此前都是"单次 writeSync 且不校验返回值"，
 * 大文件/磁盘压力下会产生**静默截断**的坏文件（之后读取解析失败、数据被当作损坏丢弃）。
 *
 * 本函数不做打开/关闭，只负责"写满"；异常（含写入不完整）返回 false，由调用方按失败处理
 * （清理临时文件并保留旧文件）。
 *
 * @param fd - 已打开的可写文件描述符
 * @param content - 待写入文本（UTF-8）
 * @returns 是否完整写入
 */
export function writeTextFully(fd: number, content: string): boolean {
  try {
    const bytes: Uint8Array = util.TextEncoder.create().encodeInto(content)
    const chunkSize: number = 64 * 1024
    let offset: number = 0
    while (offset < bytes.length) {
      const end: number = Math.min(offset + chunkSize, bytes.length)
      const chunk: Uint8Array = bytes.slice(offset, end)
      const written: number = fileIo.writeSync(fd, chunk.buffer)
      if (written <= 0) {
        return false
      }
      offset += written
    }
    return true
  } catch (err) {
    logger.verbose('[FileUtils] writeTextFully failed: %{public}s', formatError(err))
    return false
  }
}

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
