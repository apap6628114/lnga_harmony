/**
 * 文件选择器（picker）封装 + URI 读写 + 原子写工具。
 *
 * ## 为什么需要封装
 * 工程内已有三处 picker 调用（凭证导出 `SettingsPanel.exportEncryptedCredential`、凭证导入
 * `LoginPage.handleImport`、离线存档 `FavoriteSavedPanel.exportThreads/handleImport`），
 * 各自重复「取 UIAbilityContext → new Options → new DocumentViewPicker(context) → await →
 * 判空数组」的样板，且写文件路径分「带 try/finally」与「裸线性写法」两派（后者会在写失败时
 * 泄漏 fd，并在系统 picker 预创建的空文件里留下 0 字节残留）。本文件统一这两件事。
 *
 * ## 关键约束（详见调研文档 `docs/research/EXPORT_IMPORT_RESEARCH.md`）
 * - **picker 免权限**：`module.json5` 未声明任何文件读写权限，访问授权来自系统 Picker 返回的
 *   URI；本文件不新增权限。
 * - **正确 API 是 `picker.DocumentViewPicker`**：SDK `@ohos.file.picker.d.ts:679/721` 只有
 *   `select()` / `save()`，**不存在** `DocumentSavePicker`。
 * - `DocumentSaveOptions.pickerMode` 必须保持 `DEFAULT`：设为 `DOWNLOAD` 时
 *   `newFileNames` / `fileSuffixChoices` 不生效（SDK 声明 `:599-600`）。
 * - 写入必须 `try/finally` 关闭 fd（修复既有凭证导出链路的缺陷）。
 * - 读取前先 `statSync` 校验大小上限，避免一次性分配超大 `ArrayBuffer` 拖垮内存。
 *
 * 所有失败路径都不抛"裸异常"给 UI：读取/写入返回 `null`/`false`，选择器异常向上抛由调用方提示。
 */

import { picker, fileIo } from '@kit.CoreFileKit'
import { Context } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'

/**
 * 选择器返回的文档。
 */
export class PickedDocument {
  /** 文档 URI（系统 Picker 授权，可直接作为 `fileIo` 入参）。 */
  uri: string = ''
  /** 文档显示名（从 URI 末段解码；解码失败保留原串）。 */
  name: string = ''
  /** 文档大小（字节；无法读取时为 -1）。 */
  size: number = 0
}

/**
 * 从 URI 中取末段文件名（百分号解码，失败保留原串）。
 *
 * @param uri - 文档 URI
 * @returns 文件名
 */
function fileNameOfUri(uri: string): string {
  const slashIndex: number = uri.lastIndexOf('/')
  const raw: string = slashIndex >= 0 && slashIndex + 1 < uri.length ?
    uri.substring(slashIndex + 1) : uri
  if (raw.length === 0) {
    return uri
  }
  try {
    return decodeURIComponent(raw)
  } catch (e) {
    return raw
  }
}

/**
 * 规范化保存对话框的后缀选项。
 *
 * SDK 的 `fileSuffixChoices` 每项形如「描述|.后缀」或「.后缀」（`@ohos.file.picker.d.ts:584-595`）。
 * 调用方常传不带点的纯后缀（如 `ngabackup`），这里补成 `描述|.后缀` 形式；
 * 已带 `.` 或已含 `|` 的值原样使用。
 *
 * @param suffix - 调用方传入的后缀
 * @returns 规范化后的选项；空串表示不限制
 */
function normalizeSuffixChoice(suffix: string): string {
  const trimmed: string = suffix.trim()
  if (trimmed.length === 0) {
    return ''
  }
  if (trimmed.indexOf('|') >= 0) {
    return trimmed
  }
  if (trimmed.startsWith('.')) {
    return trimmed
  }
  return '备份文件|.' + trimmed
}

/**
 * 打开系统文档选择器，选择若干文件用于读取。
 *
 * @param context - UIAbility 上下文（必须是 UIAbilityContext 才能拉起 Picker）
 * @param maxCount - 最多可选文件数（<= 0 时按 1 处理）
 * @returns 选中的文档列表；用户取消时为空数组
 */
export async function pickDocumentToRead(context: Context,
  maxCount: number): Promise<PickedDocument[]> {
  const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
  options.maxSelectNumber = maxCount > 0 ? maxCount : 1
  const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
  const uris: string[] = await documentPicker.select(options)
  const result: PickedDocument[] = []
  for (let i: number = 0; i < uris.length; i++) {
    const uri: string = uris[i]
    if (uri.length === 0) {
      continue
    }
    const document: PickedDocument = new PickedDocument()
    document.uri = uri
    document.name = fileNameOfUri(uri)
    document.size = fileSizeOfUri(uri)
    result.push(document)
  }
  return result
}

/**
 * 打开系统文档保存对话框，为导出文件获取目标 URI。
 *
 * @param context - UIAbility 上下文
 * @param fileName - 建议文件名（含扩展名；不含扩展名时由后缀选项补全）
 * @param suffix - 后缀（如 `ngabackup` / `.ngabackup` / `备份文件|.ngabackup`）
 * @returns 目标文件 URI；用户取消时为空串
 */
export async function pickDocumentToSave(context: Context, fileName: string,
  suffix: string): Promise<string> {
  const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions()
  options.newFileNames = [fileName]
  // 注意：不要设置 `options.pickerMode`（`DocumentPickerMode.DEFAULT` 在 tablet/2in1 上不可用，
  // 且默认行为本就是 DEFAULT；设置它只会引入设备兼容告警）。
  const choice: string = normalizeSuffixChoice(suffix)
  if (choice.length > 0) {
    options.fileSuffixChoices = [choice]
  }
  const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
  const uris: string[] = await documentPicker.save(options)
  if (uris.length === 0) {
    return ''
  }
  return uris[0]
}

/**
 * 读取 URI 文本的结果（带可诊断错误）。
 */
export class ReadTextResult {
  /** 是否读取成功。 */
  ok: boolean = false
  /** 读取到的文本。 */
  content: string = ''
  /** 失败原因（用户可见，含底层错误信息）。 */
  error: string = ''
}

/**
 * 读取 URI 的文本内容（UTF-8），失败时返回 null。
 *
 * @param uri - 文档 URI（picker 返回值或沙箱路径）
 * @param maxBytes - 大小上限（字节；<= 0 表示不限制）
 * @returns 文本；读取失败或超过上限时返回 null
 */
export function readTextFromUri(uri: string, maxBytes: number): string | null {
  const result: ReadTextResult = readTextFromUriDetailed(uri, maxBytes)
  return result.ok ? result.content : null
}

/**
 * 读取 URI 的文本内容（UTF-8），带可诊断错误。
 *
 * ## 为什么不用 `statSync(uri)` / `readTextSync(uri)`
 *
 * 真机实测反馈：导出成功的备份（200KB 量级）导入时提示"读取文件失败"。
 * 前一版实现先 `statSync(uri)` 判断大小（真机对 picker 的 document URI 可能抛错/返回 0），
 * 改用 `readTextSync(uri)` 后同样失败。最终采用与**写入侧完全同源**的
 * `openSync(uri, READ_ONLY)` + 分块 `readSync` 循环——写入侧正是用 `openSync(uri)` 成功的，
 * 因此这条路径对 picker URI 的兼容性最好；同时不依赖任何 `stat` 结果。
 *
 * @param uri - 文档 URI
 * @param maxBytes - 大小上限（字节；<= 0 表示不限制）
 * @returns 读取结果（成功文本或失败原因）
 */
export function readTextFromUriDetailed(uri: string, maxBytes: number,
  cacheDir: string = ''): ReadTextResult {
  const result: ReadTextResult = new ReadTextResult()
  if (uri.length === 0) {
    result.error = '文件 URI 为空'
    return result
  }
  let file: fileIo.File | null = null
  try {
    file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
  } catch (e) {
    result.error = '无法打开文件（' + describeError(e) + '）'
    // 兜底 1：某些 URI 只支持封装 API
    try {
      const fallback: string = fileIo.readTextSync(uri)
      if (maxBytes > 0 && utf8ByteLength(fallback) > maxBytes) {
        result.error = '文件超过大小上限'
        return result
      }
      result.ok = true
      result.content = fallback
      return result
    } catch (e2) {
      // 兜底 2：复制到应用缓存（沙箱路径必定可读）
      if (cacheDir.length > 0) {
        const copied: ReadTextResult = readViaCacheCopy(uri, maxBytes, cacheDir)
        if (copied.ok) {
          return copied
        }
        result.error = result.error + '；' + copied.error
      }
      return result
    }
  }
  try {
    const chunks: Uint8Array[] = []
    let total: number = 0
    const chunkSize: number = 64 * 1024
    const buffer: ArrayBuffer = new ArrayBuffer(chunkSize)
    while (true) {
      const readLen: number = fileIo.readSync(file.fd, buffer)
      if (readLen <= 0) {
        break
      }
      // 复制出本块数据（buffer 会被下一次 readSync 覆盖）
      const copy: Uint8Array = new Uint8Array(readLen)
      const view: Uint8Array = new Uint8Array(buffer, 0, readLen)
      for (let i: number = 0; i < readLen; i++) {
        copy[i] = view[i]
      }
      chunks.push(copy)
      total += readLen
      if (maxBytes > 0 && total > maxBytes) {
        result.error = '文件超过大小上限'
        return result
      }
    }
    if (total === 0) {
      result.ok = true
      result.content = ''
      return result
    }
    const merged: Uint8Array = new Uint8Array(total)
    let offset: number = 0
    for (let i: number = 0; i < chunks.length; i++) {
      merged.set(chunks[i], offset)
      offset += chunks[i].length
    }
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8')
    result.content = decoder.decodeToString(merged)
    result.ok = true
    return result
  } catch (e) {
    result.error = '读取文件失败（' + describeError(e) + '）'
    return result
  } finally {
    try {
      fileIo.closeSync(file)
    } catch (e) {
      // 关闭失败不影响已读出的内容
    }
  }
}

/**
 * 把异常转成简短可读文案。
 *
 * @param e - 捕获的异常
 * @returns 错误描述
 */
function describeError(e: Object): string {
  const record: Record<string, Object> = e as Record<string, Object>
  const rawMessage: Object | undefined = record['message']
  const message: string = typeof rawMessage === 'string' ? rawMessage as string : String(e)
  const rawCode: Object | undefined = record['code']
  if (typeof rawCode === 'number') {
    return 'code=' + String(rawCode as number) + ' ' + message
  }
  return message
}

/**
 * 兜底读取：把 URI 复制到应用缓存目录（沙箱路径），再从沙箱读取。
 *
 * 用于 picker URI 无法直接 open 的机型/位置（如部分文件管理器的 provider URI）。
 *
 * @param uri - 源文档 URI
 * @param maxBytes - 大小上限（字节；<= 0 不限制）
 * @param cacheDir - 应用缓存目录（`context.cacheDir`）
 * @returns 读取结果
 */
function readViaCacheCopy(uri: string, maxBytes: number, cacheDir: string): ReadTextResult {
  const result: ReadTextResult = new ReadTextResult()
  const tmpPath: string = cacheDir + '/import_backup_' + String(Date.now()) + '.tmp'
  try {
    fileIo.copyFileSync(uri, tmpPath)
  } catch (e) {
    result.error = '复制文件到缓存失败（' + describeError(e) + '）'
    return result
  }
  try {
    const content: string = fileIo.readTextSync(tmpPath)
    if (maxBytes > 0 && utf8ByteLength(content) > maxBytes) {
      result.error = '文件超过大小上限'
      return result
    }
    result.ok = true
    result.content = content
    return result
  } catch (e) {
    result.error = '从缓存读取文件失败（' + describeError(e) + '）'
    return result
  } finally {
    try {
      fileIo.unlinkSync(tmpPath)
    } catch (e) {
      // 临时文件清理失败不影响已读出的内容
    }
  }
}

/**
 * 计算字符串的 UTF-8 字节数。
 *
 * @param text - 文本
 * @returns 字节数（编码失败时按 3 倍长度保守估算）
 */
function utf8ByteLength(text: string): number {
  try {
    return util.TextEncoder.create().encodeInto(text).length
  } catch (e) {
    return text.length * 3
  }
}

/**
 * 把文本写入 URI 指向的文件（覆盖写）。
 *
 * ## 为什么必须分块循环写
 *
 * `fileIo.writeSync(fd, content)` 的返回值是**实际写入的字节数**，单次调用不保证写完整个字符串；
 * 真机导出较大的备份（数 MB）时未写完就返回，文件尾部被截断——随后导入必然解析失败。
 * 这里先把文本编码为 UTF-8 字节，再按 64KB 分块循环写，直到全部写完，任何一块写失败立即返回 false。
 *
 * 修复既有凭证导出链路的 fd 泄漏：无论写入是否成功都 `finally` 关闭句柄。
 * 系统 Picker 默认会预创建目标文件，因此这里用 `CREATE|TRUNC` 兼容"未预创建"的情况。
 *
 * @param uri - 目标文档 URI
 * @param content - 待写入文本（UTF-8）
 * @returns 是否完整写入成功
 */
export async function writeTextToUri(uri: string, content: string): Promise<boolean> {
  if (uri.length === 0) {
    return false
  }
  let file: fileIo.File | null = null
  try {
    file = fileIo.openSync(uri,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    const bytes: Uint8Array = util.TextEncoder.create().encodeInto(content)
    const chunkSize: number = 64 * 1024
    let offset: number = 0
    while (offset < bytes.length) {
      const end: number = Math.min(offset + chunkSize, bytes.length)
      const chunk: Uint8Array = bytes.slice(offset, end)
      const written: number = fileIo.writeSync(file.fd, chunk.buffer)
      if (written <= 0) {
        return false
      }
      offset += written
    }
    return true
  } catch (e) {
    return false
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file)
      } catch (e) {
        // 关闭失败不改变"写入已发生"的事实
      }
    }
  }
}

/**
 * 读取 URI 指向文件的大小。
 *
 * 仅用于展示/统计；**不要**用它作为"能否读取"的前置判断（见 {@link readTextFromUri} 说明）。
 *
 * @param uri - 文档 URI
 * @returns 字节数；无法读取时返回 -1
 */
export function fileSizeOfUri(uri: string): number {
  try {
    const stat: fileIo.Stat = fileIo.statSync(uri)
    const size: number = stat.size
    return isFinite(size) ? size : -1
  } catch (e) {
    return -1
  }
}
