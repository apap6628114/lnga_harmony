import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { stringToUint8Array, uint8ArrayToBase64 } from '../utils/CodecUtils'

const FORMAT_MAGIC: string = 'NGA_CREDENTIAL_EXPORT'
const FORMAT_VERSION: number = 2
const KDF_ITERATIONS: number = 120000
/**
 * 解密时允许的 PBKDF2 迭代次数下限/上限。
 *
 * 文件头的 `iterations` 是**外部可控输入**：早期实现直接信任它并传给 KDF，
 * 恶意文件可以写一个极大值让解密卡死（`EXPORT_IMPORT_RESEARCH.md` F2）。
 * 上限取 60 万（本工程导出值 12 万的 5 倍，足够跨版本演进），下限取 1 万。
 */
const KDF_ITERATIONS_MIN: number = 10000
const KDF_ITERATIONS_MAX: number = 600000
const KEY_SIZE: number = 32
const SALT_SIZE: number = 16
const IV_SIZE: number = 12
const TAG_SIZE: number = 16
const AAD: Uint8Array = stringToUint8Array('nga-oh-credential-export-v2')

export interface ExportCredential {
  uid: string
  cid: string
}

class CredentialExportPayload {
  uid: string = ''
  cid: string = ''
  exportedAt: number = 0
}

class EncryptedCredentialExport {
  magic: string = FORMAT_MAGIC
  version: number = FORMAT_VERSION
  kdf: string = 'PBKDF2|SHA256'
  iterations: number = KDF_ITERATIONS
  cipher: string = 'AES256|GCM|PKCS7'
  salt: string = ''
  iv: string = ''
  tag: string = ''
  data: string = ''
}

function base64Decode(value: string): Uint8Array {
  const base64 = new util.Base64Helper()
  return base64.decodeSync(value)
}

function buildGcmParams(iv: Uint8Array, tag?: Uint8Array): cryptoFramework.GcmParamsSpec {
  const authTag = tag ?? new Uint8Array(TAG_SIZE)
  return {
    iv: { data: iv },
    aad: { data: AAD },
    authTag: { data: authTag },
    algName: 'GcmParamsSpec',
  }
}

async function deriveKey(password: string, salt: Uint8Array, iterations: number): Promise<cryptoFramework.SymKey> {
  const spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: password,
    salt: salt,
    iterations: iterations,
    keySize: KEY_SIZE,
  }
  const kdf = cryptoFramework.createKdf('PBKDF2|SHA256')
  const secret = await kdf.generateSecret(spec)
  const generator = cryptoFramework.createSymKeyGenerator('AES256')
  return generator.convertKey({ data: secret.data })
}

function generateRandom(length: number): Uint8Array {
  const random = cryptoFramework.createRandom()
  return random.generateRandomSync(length).data
}

export function isEncryptedCredentialExport(content: string): boolean {
  try {
    const parsed = JSON.parse(content) as Record<string, Object>
    return String(parsed['magic'] ?? '') === FORMAT_MAGIC
  } catch (e) {
    return false
  }
}

export async function serializeCredentialExport(credential: ExportCredential, password: string): Promise<string> {
  if (password.trim().length < 8) {
    throw new Error('加密密码至少需要 8 位')
  }

  const payload = new CredentialExportPayload()
  payload.uid = credential.uid
  payload.cid = credential.cid
  payload.exportedAt = Date.now()

  const salt = generateRandom(SALT_SIZE)
  const iv = generateRandom(IV_SIZE)
  const key = await deriveKey(password, salt, KDF_ITERATIONS)
  const params = buildGcmParams(iv)
  const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7')
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params)
  const encrypted = await cipher.update({ data: stringToUint8Array(JSON.stringify(payload)) })
  const tag = await cipher.doFinal(null)

  const output = new EncryptedCredentialExport()
  output.salt = uint8ArrayToBase64(salt)
  output.iv = uint8ArrayToBase64(iv)
  output.tag = uint8ArrayToBase64(tag.data)
  output.data = uint8ArrayToBase64(encrypted.data)
  return JSON.stringify(output, null, 2)
}

export async function deserializeCredentialExport(content: string, password: string): Promise<ExportCredential> {
  const parsed = JSON.parse(content) as Record<string, Object>
  if (String(parsed['magic'] ?? '') !== FORMAT_MAGIC || Number(parsed['version'] ?? 0) !== FORMAT_VERSION) {
    throw new Error('凭证文件格式不受支持')
  }

  const salt = base64Decode(String(parsed['salt'] ?? ''))
  const iv = base64Decode(String(parsed['iv'] ?? ''))
  const tag = base64Decode(String(parsed['tag'] ?? ''))
  const data = base64Decode(String(parsed['data'] ?? ''))
  const iterations = Number(parsed['iterations'] ?? KDF_ITERATIONS)
  // 防篡改：迭代次数是文件可控输入，必须在合理区间内（避免恶意大值卡死解密）
  if (!isFinite(iterations) || iterations < KDF_ITERATIONS_MIN || iterations > KDF_ITERATIONS_MAX) {
    throw new Error('凭证文件加密参数异常')
  }
  if (salt.length !== SALT_SIZE || iv.length !== IV_SIZE || tag.length !== TAG_SIZE || data.length === 0) {
    throw new Error('凭证文件内容不完整')
  }

  const key = await deriveKey(password, salt, iterations)
  const params = buildGcmParams(iv, tag)
  const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7')
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params)
  const decrypted = await cipher.update({ data: data })
  /*
   * 解密路径的 doFinal 返回 null 属**正常**，不能判空抛错：
   * SDK 原文（`@ohos.security.cryptoFramework.d.ts` 的 Cipher.doFinal NOTE #3）：
   * "For decryption in GCM, CCM, CFB, OFB, or CTR mode, if doFinal() passes in null,
   *  the returned result is null."
   * 它的作用是触发 GCM 认证标签校验，校验失败会抛异常；返回值本身恒为 null。
   * （早期版本的"判空修复"是错误回归：会让所有合法凭证导入失败。）
   */
  await cipher.doFinal(null)

  const decoder = util.TextDecoder.create('utf-8')
  const payload = JSON.parse(decoder.decodeToString(decrypted.data)) as Record<string, Object>
  const uid = String(payload['uid'] ?? '')
  const cid = String(payload['cid'] ?? '')
  if (!uid || !cid) {
    throw new Error('凭证文件内容不完整')
  }
  return { uid, cid }
}
