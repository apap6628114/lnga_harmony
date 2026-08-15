import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { stringToUint8Array, uint8ArrayToBase64 } from '../utils/CodecUtils';

/**
 * NGA 登录密码 RSA 加密。
 *
 * 对应官方客户端登录流程：使用内置 RSA2048 公钥对密码做 PKCS1 加密，
 * 输出 Base64 供登录表单提交。
 */

const NGA_RSA_PUBLIC_KEY =
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyKzZWDimCN1OCprqWUhF' +
  'UPhcwxDE62/BFVP6LtQHJu+65dm4YNmDvzitmcfaXW9YbhXnd4oP7j+6vpcgJQ+p' +
  '3ucySo1ZnqO0Bb2JKEtxpCmxe7IYXhFEkJqHpFYBTiAxQz2n2mX4JZy/ehBUSMjz' +
  'gzd0NdG6Ai1C42oCzYltUOjNWZUNHn1nqpElSWHnUWqkdN8+5ISP/ZMKiQdFANkE' +
  'qDGw3/34qyF+E/hVgrGF4/CcWNP/LJCdB6DYtx7VPlQZF0tP1s+q/++rC4rQ2wmV' +
  'l2V8zGh1j7ojZbt62hVjy6byK1E/2XYo97ZtL4KDW7F5jJMvSDRFR7901UR8hCdf' +
  '4wIDAQAB';

/**
 * 使用内置 RSA2048 公钥加密登录密码。
 *
 * @param password - 明文密码
 * @returns Base64 编码的密文
 */
export async function encryptPassword(password: string): Promise<string> {
  // convertKey 需要 DER 编码的二进制数据，即 Base64 解码后的原始字节
  const base64 = new util.Base64Helper();
  const pubKeyData: cryptoFramework.DataBlob = {
    data: base64.decodeSync(NGA_RSA_PUBLIC_KEY),
  };

  let keyGenerator: cryptoFramework.AsyKeyGenerator
  try {
    keyGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048')
  } catch (e) {
    throw new Error('RSA密钥生成器创建失败')
  }
  let keyPair: cryptoFramework.KeyPair
  try {
    keyPair = await keyGenerator.convertKey(pubKeyData, null)
  } catch (e) {
    throw new Error('RSA密钥转换失败')
  }
  let cipher: cryptoFramework.Cipher
  try {
    cipher = cryptoFramework.createCipher('RSA2048|PKCS1')
  } catch (e) {
    throw new Error('RSA密码器创建失败')
  }
  try {
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, keyPair.pubKey, null);
  } catch (e) {
    throw new Error('RSA加密初始化失败');
  }
  const inputData: cryptoFramework.DataBlob = {
    data: stringToUint8Array(password),
  };
  let output: cryptoFramework.DataBlob;
  try {
    output = await cipher.doFinal(inputData);
  } catch (e) {
    throw new Error('RSA加密失败');
  }
  return uint8ArrayToBase64(output.data);
}
