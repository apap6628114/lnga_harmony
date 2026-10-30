/**
 * 数据备份加密容器（统一导出/导入用）。
 *
 * ## 定位
 * 与账号凭证导出（`common/security/CredentialExportCrypto.ets`）**同算法参数、不同 AAD**：
 * - 相同：PBKDF2|SHA256、120000 次迭代、AES256|GCM|PKCS7、16B salt、12B IV、16B tag、32B key；
 * - 不同：AAD 为 {@link BACKUP_AAD}（`nga-oh-data-backup-v1`），凭证链路是
 *   `nga-oh-credential-export-v2`。两条链路互不认对方的密文，防止把凭证文件当数据包导入。
 *
 * ## 相对既有凭证实现的加固（本文件刻意修复的缺陷）
 * 1. 解密时 **`kdf` / `cipher` 白名单校验**（凭证实现写了字段却不校验）；
 * 2. 解密时 **`iterations` 区间校验** `[10000, 600000]`：恶意/损坏文件写入 `1e9` 会让 PBKDF2
 *    长时间占用线程（凭证实现直接信任文件内的值）；
 * 3. `salt` / `iv` / `tag` base64 解码后的**长度校验**，把"文件损坏"与"密码错误"分开报；
 * 4. `doFinal` 返回值**判空**（SDK 明确结果可能为 null）；
 * 5. 所有失败路径抛**中文明确错误**，不把底层 crypto 异常原文透给 UI。
 *
 * ## 安全边界
 * - 密码不落盘、不记忆；`trim()` 仅用于长度校验，派生密钥仍用原始字符串（与凭证导出一致，
 *   避免"输入前后空格导致打不开"的歧义）。
 * - 解密失败统一报「密码错误或备份文件已损坏」，**不区分**二者（避免 padding oracle 提示）。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6.1 / §6.2。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { stringToUint8Array, uint8ArrayToBase64 } from '../utils/CodecUtils'

/** 加密备份的 AAD（与凭证链路的 `nga-oh-credential-export-v2` 隔离）。 */
export const BACKUP_AAD: string = 'nga-oh-data-backup-v1'

/** 加密容器 magic。 */
const ENCRYPTED_MAGIC: string = 'NGA_OH_BACKUP_ENC'

/** 容器格式版本（与 `PersistenceTypes.BACKUP_FORMAT_VERSION` 对齐）。 */
const FORMAT_VERSION: number = 1

/** KDF 算法串（写入并校验）。 */
const KDF_ALG: string = 'PBKDF2|SHA256'

/** 加密算法串（写入并校验）。 */
const CIPHER_ALG: string = 'AES256|GCM|PKCS7'

/** 默认迭代次数（与凭证导出一致）。 */
const DEFAULT_ITERATIONS: number = 120000

/** 迭代次数下限（防恶意低值削弱 KDF）。 */
const MIN_ITERATIONS: number = 10000

/** 迭代次数上限（防恶意大值造成的长时间阻塞）。 */
const MAX_ITERATIONS: number = 600000

/** AES-256 密钥长度（字节）。 */
const KEY_SIZE: number = 32

/** salt 长度（字节）。 */
const SALT_SIZE: number = 16

/** IV 长度（字节，GCM 推荐 12）。 */
const IV_SIZE: number = 12

/** 认证标签长度（字节，GCM 固定 16）。 */
const TAG_SIZE: number = 16

/** 加密密码最短长度。 */
const MIN_PASSWORD_LENGTH: number = 8

/**
 * 加密备份容器（落盘/传输形态，全部字符串字段为 base64）。
 *
 * 与明文容器（`NGA_OH_BACKUP`）通过 magic 区分；`data` 是明文容器 JSON 的密文。
 */
class EncryptedBackupEnvelope {
  magic: string = ENCRYPTED_MAGIC
  formatVersion: number = FORMAT_VERSION
  kdf: string = KDF_ALG
  iterations: number = DEFAULT_ITERATIONS
  cipher: string = CIPHER_ALG
  salt: string = ''
  iv: string = ''
  tag: string = ''
  data: string = ''
}

/**
 * 构造 GCM 参数（AAD 固定为 {@link BACKUP_AAD}）。
 *
 * @param iv - 随机 IV
 * @param tag - 认证标签（加密时传空数组占位，解密时传文件内的 tag）
 * @returns GCM 参数
 */
function buildGcmParams(iv: Uint8Array, tag: Uint8Array): cryptoFramework.GcmParamsSpec {
  return {
    iv: { data: iv },
    aad: { data: stringToUint8Array(BACKUP_AAD) },
    authTag: { data: tag },
    algName: 'GcmParamsSpec',
  }
}

/**
 * 由口令派生 AES-256 密钥。
 *
 * @param password - 用户口令（原始字符串）
 * @param salt - 随机盐
 * @param iterations - 迭代次数
 * @returns AES 对称密钥
 */
async function deriveKey(password: string, salt: Uint8Array,
  iterations: number): Promise<cryptoFramework.SymKey> {
  const spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: password,
    salt: salt,
    iterations: iterations,
    keySize: KEY_SIZE,
  }
  const kdf = cryptoFramework.createKdf(KDF_ALG)
  const secret = await kdf.generateSecret(spec)
  if (secret === null || secret === undefined || secret.data === null ||
    secret.data === undefined || secret.data.length === 0) {
    throw new Error('密钥派生失败，请重试')
  }
  const generator = cryptoFramework.createSymKeyGenerator('AES256')
  return generator.convertKey({ data: secret.data })
}

/**
 * 生成指定长度的安全随机字节（CTR_DRBG）。
 *
 * @param length - 字节数
 * @returns 随机字节
 */
function generateRandom(length: number): Uint8Array {
  const random = cryptoFramework.createRandom()
  const blob: cryptoFramework.DataBlob = random.generateRandomSync(length)
  if (blob === null || blob === undefined || blob.data === null ||
    blob.data === undefined || blob.data.length !== length) {
    throw new Error('安全随机数生成失败')
  }
  return blob.data
}

/**
 * base64 解码（失败抛「备份文件已损坏」）。
 *
 * @param value - base64 字符串
 * @param fieldName - 字段名（用于错误提示）
 * @returns 解码后的字节
 */
function decodeBase64(value: string, fieldName: string): Uint8Array {
  if (value.length === 0) {
    throw new Error('备份文件已损坏：缺少 ' + fieldName)
  }
  try {
    const helper = new util.Base64Helper()
    return helper.decodeSync(value)
  } catch (e) {
    throw new Error('备份文件已损坏：' + fieldName + ' 不是合法的 base64')
  }
}

/**
 * 判断文本是否为**加密**备份容器。
 *
 * 只校验 magic，不校验版本：版本过高时也应识别为"加密备份"，由解密函数给出准确提示。
 *
 * @param content - 文件文本
 * @returns 是否为加密备份
 */
export function isEncryptedBackup(content: string): boolean {
  if (content.length === 0) {
    return false
  }
  let parsed: Record<string, Object>
  try {
    parsed = JSON.parse(content) as Record<string, Object>
  } catch (e) {
    return false
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return false
  }
  return String(parsed['magic'] ?? '') === ENCRYPTED_MAGIC
}

/**
 * 加密备份明文。
 *
 * @param plaintext - 明文容器 JSON（不允许为空）
 * @param password - 加密口令（至少 8 位）
 * @returns 加密容器 JSON 文本（美化输出）
 * @throws Error 口令过短 / 明文为空 / 加密过程失败
 */
export async function encryptBackup(plaintext: string, password: string): Promise<string> {
  if (password.trim().length < MIN_PASSWORD_LENGTH) {
    throw new Error('加密密码至少需要 8 位')
  }
  if (plaintext.length === 0) {
    throw new Error('备份内容为空，无法加密')
  }
  const salt: Uint8Array = generateRandom(SALT_SIZE)
  const iv: Uint8Array = generateRandom(IV_SIZE)
  const key: cryptoFramework.SymKey = await deriveKey(password, salt, DEFAULT_ITERATIONS)
  const cipher = cryptoFramework.createCipher(CIPHER_ALG)
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key,
    buildGcmParams(iv, new Uint8Array(TAG_SIZE)))
  const encrypted: cryptoFramework.DataBlob =
    await cipher.update({ data: stringToUint8Array(plaintext) })
  const tagBlob: cryptoFramework.DataBlob = await cipher.doFinal(null)
  if (encrypted === null || encrypted === undefined || encrypted.data === null ||
    encrypted.data === undefined || encrypted.data.length === 0) {
    throw new Error('加密失败：密文为空')
  }
  if (tagBlob === null || tagBlob === undefined || tagBlob.data === null ||
    tagBlob.data === undefined || tagBlob.data.length !== TAG_SIZE) {
    throw new Error('加密失败：认证标签异常')
  }
  const output: EncryptedBackupEnvelope = new EncryptedBackupEnvelope()
  output.salt = uint8ArrayToBase64(salt)
  output.iv = uint8ArrayToBase64(iv)
  output.tag = uint8ArrayToBase64(tagBlob.data)
  output.data = uint8ArrayToBase64(encrypted.data)
  return JSON.stringify(output, null, 2)
}

/**
 * 解密加密备份容器。
 *
 * @param content - 加密容器 JSON 文本
 * @param password - 解密口令
 * @returns 明文容器 JSON 文本
 * @throws Error 非加密容器 / 版本不支持 / 参数越界 / 文件损坏 / 密码错误
 */
export async function decryptBackup(content: string, password: string): Promise<string> {
  if (content.length === 0) {
    throw new Error('备份文件为空')
  }
  if (password.trim().length < MIN_PASSWORD_LENGTH) {
    throw new Error('密码至少需要 8 位')
  }
  let parsed: Record<string, Object>
  try {
    parsed = JSON.parse(content) as Record<string, Object>
  } catch (e) {
    throw new Error('备份文件不是有效的 JSON')
  }
  if (parsed === null || parsed === undefined || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('备份文件不是有效的加密容器')
  }
  if (String(parsed['magic'] ?? '') !== ENCRYPTED_MAGIC) {
    throw new Error('这不是加密备份文件')
  }
  const formatVersion: number = Number(parsed['formatVersion'] ?? 0)
  if (!Number.isInteger(formatVersion) || formatVersion !== FORMAT_VERSION) {
    throw new Error('备份文件格式版本不受支持，请升级应用')
  }
  if (String(parsed['kdf'] ?? '') !== KDF_ALG) {
    throw new Error('备份文件使用了不支持的密钥派生算法')
  }
  if (String(parsed['cipher'] ?? '') !== CIPHER_ALG) {
    throw new Error('备份文件使用了不支持的加密算法')
  }
  const iterations: number = Number(parsed['iterations'] ?? 0)
  if (!Number.isInteger(iterations) || iterations < MIN_ITERATIONS ||
    iterations > MAX_ITERATIONS) {
    throw new Error('备份文件密钥派生参数超出允许范围')
  }
  const salt: Uint8Array = decodeBase64(String(parsed['salt'] ?? ''), 'salt')
  const iv: Uint8Array = decodeBase64(String(parsed['iv'] ?? ''), 'iv')
  const tag: Uint8Array = decodeBase64(String(parsed['tag'] ?? ''), 'tag')
  const data: Uint8Array = decodeBase64(String(parsed['data'] ?? ''), 'data')
  if (salt.length !== SALT_SIZE) {
    throw new Error('备份文件已损坏：salt 长度异常')
  }
  if (iv.length !== IV_SIZE) {
    throw new Error('备份文件已损坏：iv 长度异常')
  }
  if (tag.length !== TAG_SIZE) {
    throw new Error('备份文件已损坏：认证标签长度异常')
  }
  if (data.length === 0) {
    throw new Error('备份文件已损坏：密文为空')
  }

  const key: cryptoFramework.SymKey = await deriveKey(password, salt, iterations)
  let decrypted: cryptoFramework.DataBlob | null = null
  try {
    const cipher = cryptoFramework.createCipher(CIPHER_ALG)
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, buildGcmParams(iv, tag))
    decrypted = await cipher.update({ data: data })
    // 解密路径的 doFinal 返回 null 属正常（GCM 下 data 为 null 时返回 null，SDK 声明原文），
    // 它的作用是触发认证标签校验；校验失败会抛异常。
    await cipher.doFinal(null)
  } catch (e) {
    throw new Error('密码错误或备份文件已损坏')
  }
  if (decrypted === null || decrypted === undefined || decrypted.data === null ||
    decrypted.data === undefined || decrypted.data.length === 0) {
    throw new Error('密码错误或备份文件已损坏')
  }
  const decoder = util.TextDecoder.create('utf-8')
  const plaintext: string = decoder.decodeToString(decrypted.data)
  if (plaintext.length === 0) {
    throw new Error('备份内容为空')
  }
  return plaintext
}
