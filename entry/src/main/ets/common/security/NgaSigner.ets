/**
 * NGA APP 主接口签名。
 *
 * 对应官方客户端（nga.apk v7.17.17）：
 *   sign = MD5(app_id + access_uid + access_token + signParams + t + secret)
 *   app_id = "1010"，secret = "392e916a6d1d8b7523e2701470000c30bc2165a1"
 *   （ft.k.f116747a / ft.k.f116751b，见 nga-hack nga-client src/config.ts）
 *
 * access_uid = ngaPassportUid，access_token = ngaPassportCid（cookie 即完整 APP 凭证）。
 * signParams 由业务层 addSignParams(...) 按序拼接的参数值（未调用则为空串）。
 *
 * MD5 与 UTF-8 编码均为纯 ArkTS 实现（RFC 1321），不依赖 cryptoFramework 与
 * util.TextEncoder，保证签名在任意运行环境（Local Test / 真机）结果一致，
 * 且可被 Hypium 单测对照 nga-client 基准验证。
 */

export const NGA_APP_ID: string = '1010';
export const NGA_SECRET: string = '392e916a6d1d8b7523e2701470000c30bc2165a1';

/** MD5 常量表 K（64 个，RFC 1321）。 */
const MD5_K: number[] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

/** MD5 每步左移位数表 S（64 个，RFC 1321）。 */
const MD5_S: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

/** 将 32 位无符号数左移 shift 位（循环左移）。 */
function rotateLeft(x: number, shift: number): number {
  return ((x << shift) | (x >>> (32 - shift))) & 0xffffffff;
}

/** 把 32 位无符号整数转为 8 位小端 hex 串。 */
function hexWord(x: number): string {
  let hex: string = '';
  for (let i = 0; i < 4; i++) {
    const byte: number = (x >>> (8 * i)) & 0xff;
    hex += (byte < 16 ? '0' : '') + byte.toString(16);
  }
  return hex;
}

/** 将字符串按 UTF-8 编码为字节（纯 ArkTS，兼容代理对，与 util.TextEncoder 一致）。 */
function utf8Bytes(str: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < str.length; i++) {
    let code: number = str.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
      const low: number = str.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        const cp: number = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        out.push(0xf0 | (cp >> 18));
        out.push(0x80 | ((cp >> 12) & 0x3f));
        out.push(0x80 | ((cp >> 6) & 0x3f));
        out.push(0x80 | (cp & 0x3f));
        i++;
        continue;
      }
    }
    if (code <= 0x7f) {
      out.push(code);
    } else if (code <= 0x7ff) {
      out.push(0xc0 | (code >> 6));
      out.push(0x80 | (code & 0x3f));
    } else {
      out.push(0xe0 | (code >> 12));
      out.push(0x80 | ((code >> 6) & 0x3f));
      out.push(0x80 | (code & 0x3f));
    }
  }
  return new Uint8Array(out);
}

/** 标准 MD5（RFC 1321），输入 UTF-8 字节，返回 32 位小写 hex。 */
export function md5Hex(data: string): string {
  const input: Uint8Array = utf8Bytes(data);
  const inputLen: number = input.length;
  const paddedLen: number = (((inputLen + 8) >> 6) + 1) << 6;

  const block: Uint8Array = new Uint8Array(paddedLen);
  for (let i = 0; i < inputLen; i++) {
    block[i] = input[i];
  }
  block[inputLen] = 0x80;

  const bitLen: number = inputLen * 8;
  const p: number = paddedLen - 8;
  block[p] = bitLen & 0xff;
  block[p + 1] = (bitLen >>> 8) & 0xff;
  block[p + 2] = (bitLen >>> 16) & 0xff;
  block[p + 3] = (bitLen >>> 24) & 0xff;
  block[p + 4] = 0;
  block[p + 5] = 0;
  block[p + 6] = 0;
  block[p + 7] = 0;

  let a0: number = 0x67452301;
  let b0: number = 0xefcdab89;
  let c0: number = 0x98badcfe;
  let d0: number = 0x10325476;

  for (let off = 0; off < paddedLen; off += 64) {
    const m: number[] = [];
    for (let j = 0; j < 16; j++) {
      const idx: number = off + j * 4;
      m.push((block[idx] | (block[idx + 1] << 8) | (block[idx + 2] << 16) | (block[idx + 3] << 24)) >>> 0);
    }

    let a: number = a0;
    let b: number = b0;
    let c: number = c0;
    let d: number = d0;

    for (let i = 0; i < 64; i++) {
      let f: number;
      let g: number;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) & 15;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) & 15;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) & 15;
      }

      f = (f + a + MD5_K[i] + m[g]) & 0xffffffff;
      a = d;
      d = c;
      c = b;
      b = (b + rotateLeft(f, MD5_S[i])) >>> 0;
    }

    a0 = (a0 + a) & 0xffffffff;
    b0 = (b0 + b) & 0xffffffff;
    c0 = (c0 + c) & 0xffffffff;
    d0 = (d0 + d) & 0xffffffff;
  }

  return hexWord(a0) + hexWord(b0) + hexWord(c0) + hexWord(d0);
}

export interface MakeSignOptions {
  appId?: string;
  accessUid?: string;
  accessToken?: string;
  signParams?: string;
  ts?: string;
  secret?: string;
}

/**
 * 主接口签名。
 *
 * @param opts
 * @returns 小写 hex MD5
 */
export function makeSign(opts: MakeSignOptions): string {
  const appId: string = opts.appId ?? NGA_APP_ID;
  const accessUid: string = opts.accessUid ?? '';
  const accessToken: string = opts.accessToken ?? '';
  const signParams: string = opts.signParams ?? '';
  const ts: string = opts.ts ?? String(Math.floor(Date.now() / 1000));
  const secret: string = opts.secret ?? NGA_SECRET;
  return md5Hex(`${appId}${accessUid}${accessToken}${signParams}${ts}${secret}`);
}

export interface ClientChecksumOptions {
  uid?: string;
  ts?: string;
}

/**
 * __ngaClientChecksum（少数特殊接口：VIP 自动签到 / 微短剧等）。
 *   md51 = MD5(salt1 + ts)；md52 = MD5(md51 + salt2)
 *   checksum = MD5(uid + md52 + ts) + ts
 */
export function makeClientChecksum(opts: ClientChecksumOptions): string {
  const uid: string = opts.uid ?? '';
  const ts: string = opts.ts ?? String(Math.floor(Date.now() / 1000));
  const salt1: string = '161c8c015f912abf4434c3263279c296';
  const salt2: string = '12d6af9da0f1fe4e3c87f76ce0aec149';
  const md51: string = md5Hex(salt1 + ts);
  const md52: string = md5Hex(md51 + salt2);
  return `${md5Hex(uid + md52 + ts)}${ts}`;
}
