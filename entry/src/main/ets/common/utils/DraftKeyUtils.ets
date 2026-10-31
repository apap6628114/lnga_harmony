/**
 * 草稿键的账号片段工具（无依赖纯函数）。
 *
 * 为什么单独成文件：草稿键里的 uid 短哈希既要被 `DraftStore`（生成键）使用，也要被
 * `DataTransferService`（导入时把备份里的旧账号哈希**改写为当前账号哈希**）使用。
 * 放进 `DraftStore` 会让 `DataTransferService` 引入 Store/AppStore 依赖链（存在循环依赖风险），
 * 因此抽成零依赖工具模块。同理，导入侧的草稿键合法性校验（`isValidDraftKey`）也放在这里，
 * 由 `DraftStore` 与导入器共用同一份实现。
 *
 * ⚠️ 算法变更会改变既有草稿的键归属（旧草稿将读不到），**不要修改**：
 * FNV-1a 32 位 + 36 进制（非负）。
 */

/** 草稿键最大长度（文件名安全上界，与 `DraftStore`/`DraftMediaStore` 一致）。 */
const MAX_DRAFT_KEY_LENGTH: number = 96

/**
 * 校验草稿键是否可安全用于文件名。
 *
 * 键由内部生成（`draft_` + 数字 + 动作 + uid 哈希），只允许字母/数字/下划线；
 * 必须拒绝路径分隔符、`..` 与其它字符，防止上游改动把路径穿越带进草稿目录。
 *
 * @param key - 待校验的草稿键
 * @returns 是否合法
 */
export function isValidDraftKey(key: string): boolean {
  if (key.length === 0 || key.length > MAX_DRAFT_KEY_LENGTH) {
    return false
  }
  for (let i: number = 0; i < key.length; i++) {
    const c: string = key.charAt(i)
    const isDigit: boolean = c >= '0' && c <= '9'
    const isLower: boolean = c >= 'a' && c <= 'z'
    const isUpper: boolean = c >= 'A' && c <= 'Z'
    if (!isDigit && !isLower && !isUpper && c !== '_') {
      return false
    }
  }
  return true
}

/**
 * FNV-1a 32 位短哈希（36 进制）。
 *
 * @param value - 原始字符串（如 uid）
 * @returns 36 进制短哈希（非负）
 */
export function shortHash36(value: string): string {
  let hash: number = 0x811c9dc5
  for (let i: number = 0; i < value.length; i++) {
    hash = hash ^ value.charCodeAt(i)
    hash = (hash * 0x01000193) | 0
  }
  return (hash >>> 0).toString(36)
}

/**
 * 草稿键里的账号片段（登录用 uid 短哈希，未登录用 `anon`）。
 *
 * @param uid - 当前登录 uid（空串表示未登录）
 * @returns 文件名安全的账号片段
 */
export function draftUidPart(uid: string): string {
  return uid.length > 0 ? shortHash36(uid) : 'anon'
}

/**
 * 把草稿键末尾的账号片段替换为指定值。
 *
 * 草稿键形态固定为 `draft_..._<uidPart>`（回复：`draft_<tid>_edit_<pid>_<uidPart>`、
 * 发帖：`draft_newtopic_<fid>[_stid<stid>]_<uidPart>`），账号片段是**最后一段**。
 * 导入备份到另一个账号时，备份里的键带的是导出账号的哈希，按当前账号键查找会读不到草稿；
 * 导入时用本函数改写为当前账号片段即可"找回"草稿。
 *
 * @param key - 备份中的草稿键
 * @param uidPart - 当前账号的账号片段
 * @returns 改写后的键；无法识别时返回原键
 */
export function rewriteDraftKeyUidPart(key: string, uidPart: string): string {
  const index: number = key.lastIndexOf('_')
  if (index <= 0 || index + 1 >= key.length) {
    return key
  }
  const prefix: string = key.substring(0, index + 1)
  const tail: string = key.substring(index + 1)
  if (tail.length === 0 || tail === uidPart) {
    return key
  }
  return prefix + uidPart
}
