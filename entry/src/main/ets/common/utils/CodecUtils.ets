/**
 * 编解码工具集 - 纯函数，无副作用。
 * 提供 UTF-8/Base64/GB18030 编解码、HTML 实体转义、GBK 百分号编码、表单/分段体构造。
 */

import { util } from '@kit.ArkTS';

/**
 * multipart 构造结果。
 */
export interface MultipartResult {
  /** 分段体内容 */
  body: string;
  /** Content-Type 头值（含 boundary） */
  contentType: string;
}

/**
 * 将字符串按 UTF-8 编码为 Uint8Array。
 * @param str - 待编码字符串
 * @returns UTF-8 字节序列
 */
export function stringToUint8Array(str: string): Uint8Array {
  const textEncoder = util.TextEncoder.create();
  return textEncoder.encodeInto(str);
}

/**
 * 将 Uint8Array 编码为 Base64 字符串。
 * @param data - 原始字节
 * @returns Base64 编码结果
 */
export function uint8ArrayToBase64(data: Uint8Array): string {
  const base64 = new util.Base64Helper();
  return base64.encodeToStringSync(data);
}

/**
 * 将 ArrayBuffer 按 GB18030 解码为字符串。
 * @param buffer - GB18030 编码的字节缓冲
 * @returns 解码后的字符串
 */
export function decodeGb18030(buffer: ArrayBuffer): string {
  const decoder = util.TextDecoder.create('gb18030');
  return decoder.decodeToString(new Uint8Array(buffer));
}

/**
 * 将 ArrayBuffer 按 UTF-8 解码为字符串。
 *
 * 官方 APP 签名接口通过 __inchst=utf-8 声明响应编码；该解码器与网页版
 * GB18030 解码分开，避免 output=17 的 HTML 正文出现中文乱码。
 *
 * @param buffer - UTF-8 编码的字节缓冲
 * @returns 解码后的字符串
 */
export function decodeUtf8(buffer: ArrayBuffer): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(new Uint8Array(buffer));
}

/**
 * 将字符串中的 emoji（代理对）转换为 HTML 数字实体（&#codepoint;），
 * 以便后续按 GBK 编码时 emoji 不会被错误拆分。
 * @param str - 原始字符串
 * @returns emoji 已转义后的字符串
 */
export function emojiToHtmlEntity(str: string): string {
  let result = '';
  for (let i = 0; i < str.length; i++) {
    const code = str.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < str.length) {
      const nextCode = str.charCodeAt(i + 1);
      if (nextCode >= 0xDC00 && nextCode <= 0xDFFF) {
        const fullCodepoint = (code - 0xD800) * 0x400 + (nextCode - 0xDC00) + 0x10000;
        result += '&#' + String(fullCodepoint) + ';';
        i++;
      } else {
        result += str[i];
      }
    } else {
      result += str[i];
    }
  }
  return result;
}

/**
 * 按 GBK 编码并对结果做百分号编码，emoji 先转 HTML 实体避免拆分。
 * 用于发帖/回复等含中文与 emoji 的表单字段。
 * @param str - 待编码字符串
 * @returns GBK 百分号编码结果
 */
export function gbkPercentEncode(str: string): string {
  const cleaned = emojiToHtmlEntity(str);
  const encoder = util.TextEncoder.create('gbk');
  const bytes = encoder.encodeInto(cleaned);
  let result = '';
  for (let i = 0; i < bytes.length; i++) {
    const byteVal = bytes[i];
    if ((byteVal >= 0x41 && byteVal <= 0x5A) ||
        (byteVal >= 0x61 && byteVal <= 0x7A) ||
        (byteVal >= 0x30 && byteVal <= 0x39) ||
        byteVal === 0x2D || byteVal === 0x5F || byteVal === 0x2E || byteVal === 0x7E) {
      result += String.fromCharCode(byteVal);
    } else {
      const hex = byteVal.toString(16).toUpperCase();
      result += '%' + (hex.length === 1 ? '0' + hex : hex);
    }
  }
  return result;
}

/**
 * 构造 application/x-www-form-urlencoded 请求体。
 * 普通字段按 UTF-8 百分号编码，gbkFieldKeys 列出的字段按 GBK 百分号编码。
 * @param fields - 字段名到值的映射
 * @param gbkFieldKeys - 需按 GBK 编码的字段名列表（可选）
 * @returns 拼接后的请求体字符串
 */
export function buildEncodedBody(fields: Record<string, string>, gbkFieldKeys?: string[]): string {
  const parts: string[] = [];
  const keys = Object.keys(fields);
  const gbkSet: Record<string, boolean> = {};
  if (gbkFieldKeys) {
    for (let i = 0; i < gbkFieldKeys.length; i++) {
      gbkSet[gbkFieldKeys[i]] = true;
    }
  }
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    if (gbkSet[key]) {
      parts.push(`${encodeURIComponent(key)}=${gbkPercentEncode(fields[key])}`);
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(fields[key])}`);
    }
  }
  return parts.join('&');
}

/**
 * 构造 multipart/form-data 请求体（纯文本字段）。
 * @param fields - 字段名到值的映射
 * @returns 分段体与 Content-Type
 */
export function buildMultipart(fields: Record<string, string>): MultipartResult {
  const boundary = `----FormBoundary${Math.random().toString(36).slice(2)}`;
  const parts: string[] = [];
  const keys = Object.keys(fields);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${fields[key]}\r\n`);
  }
  parts.push(`--${boundary}--\r\n`);
  const result: MultipartResult = {
    body: parts.join(''),
    contentType: `multipart/form-data; boundary=${boundary}`,
  };
  return result;
}

/**
 * 返回一个空的 Record<string, string>，便于显式类型标注场景。
 * @returns 空映射
 */
export function emptyStringRecord(): Record<string, string> {
  const result: Record<string, string> = {};
  return result;
}
