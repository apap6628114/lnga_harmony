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
 * 读取 URI 的文本内容（UTF-8）。
 *
 * @param uri - 文档 URI（picker 返回值或沙箱路径）
 * @param maxBytes - 大小上限（字节；<= 0 表示不限制）
 * @returns 文本；读取失败或超过上限时返回 null
 */
export function readTextFromUri(uri: string, maxBytes: number): string | null {
  const size: number = fileSizeOfUri(uri)
  if (size < 0) {
    return null
  }
  if (maxBytes > 0 && size > maxBytes) {
    return null
  }
  if (size === 0) {
    return ''
  }
  let file: fileIo.File | null = null
  try {
    file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY)
    const buffer: ArrayBuffer = new ArrayBuffer(size)
    const readLen: number = fileIo.readSync(file.fd, buffer)
    if (readLen <= 0) {
      return ''
    }
    const decoder = util.TextDecoder.create('utf-8')
    return decoder.decodeToString(new Uint8Array(buffer, 0, readLen))
  } catch (e) {
    return null
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file)
      } catch (e) {
        // 关闭失败不影响已读出的内容
      }
    }
  }
}

/**
 * 把文本写入 URI 指向的文件（覆盖写）。
 *
 * 修复既有凭证导出链路的 fd 泄漏：无论写入是否成功都 `finally` 关闭句柄。
 * 系统 Picker 默认会预创建目标文件（`DocumentSaveOptions.autoCreateEmptyFile` 默认 true），
 * 因此这里用 `CREATE|TRUNC` 兼容"未预创建"的情况，写失败时文件可能被截断为 0 字节——
 * 调用方应先完成内容生成再写入，避免把加密/序列化失败留成空文件。
 *
 * @param uri - 目标文档 URI
 * @param content - 待写入文本（UTF-8）
 * @returns 是否写入成功
 */
export async function writeTextToUri(uri: string, content: string): Promise<boolean> {
  if (uri.length === 0) {
    return false
  }
  let file: fileIo.File | null = null
  try {
    file = fileIo.openSync(uri,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    fileIo.writeSync(file.fd, content)
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
