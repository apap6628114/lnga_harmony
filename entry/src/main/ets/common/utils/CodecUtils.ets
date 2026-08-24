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
 * HTML 命名实体表（官方 `ft.c1.a` 实体表的常用子集）。
 *
 * 与官方语义对齐：未知实体名保留原文（`&name;` 原样输出）。
 */
const HTML_NAMED_ENTITIES: Record<string, string> = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'cent': '¢',
  'pound': '£',
  'yen': '¥',
  'euro': '€',
  'sect': '§',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
  'plusmn': '±',
  'middot': '·',
  'times': '×',
  'divide': '÷',
  'frac12': '½',
  'frac14': '¼',
  'frac34': '¾',
  'sup1': '¹',
  'sup2': '²',
  'sup3': '³',
  'micro': 'µ',
  'para': '¶',
  'hellip': '…',
  'ndash': '–',
  'mdash': '—',
  'lsquo': '‘',
  'rsquo': '’',
  'sbquo': '‚',
  'ldquo': '“',
  'rdquo': '”',
  'bdquo': '„',
  'bull': '•',
  'dagger': '†',
  'Dagger': '‡',
  'permil': '‰',
  'laquo': '«',
  'raquo': '»',
  'iquest': '¿',
  'szlig': 'ß',
  'AElig': 'Æ',
  'aelig': 'æ',
  'Oslash': 'Ø',
  'oslash': 'ø',
  'Aring': 'Å',
  'aring': 'å',
  'agrave': 'à',
  'aacute': 'á',
  'acirc': 'â',
  'atilde': 'ã',
  'auml': 'ä',
  'ccedil': 'ç',
  'egrave': 'è',
  'eacute': 'é',
  'ecirc': 'ê',
  'euml': 'ë',
  'igrave': 'ì',
  'iacute': 'í',
  'icirc': 'î',
  'iuml': 'ï',
  'ntilde': 'ñ',
  'ograve': 'ò',
  'oacute': 'ó',
  'ocirc': 'ô',
  'otilde': 'õ',
  'ouml': 'ö',
  'ugrave': 'ù',
  'uacute': 'ú',
  'ucirc': 'û',
  'uuml': 'ü',
  'yacute': 'ý',
  'yuml': 'ÿ',
  'Agrave': 'À',
  'Aacute': 'Á',
  'Acirc': 'Â',
  'Atilde': 'Ã',
  'Auml': 'Ä',
  'Ccedil': 'Ç',
  'Egrave': 'È',
  'Eacute': 'É',
  'Ecirc': 'Ê',
  'Euml': 'Ë',
  'Igrave': 'Ì',
  'Iacute': 'Í',
  'Icirc': 'Î',
  'Iuml': 'Ï',
  'Ntilde': 'Ñ',
  'Ograve': 'Ò',
  'Oacute': 'Ó',
  'Ocirc': 'Ô',
  'Otilde': 'Õ',
  'Ouml': 'Ö',
  'Ugrave': 'Ù',
  'Uacute': 'Ú',
  'Ucirc': 'Û',
  'Uuml': 'Ü',
  'Yacute': 'Ý',
  'THORN': 'Þ',
  'thorn': 'þ',
  'ETH': 'Ð',
  'eth': 'ð',
  'OElig': 'Œ',
  'oelig': 'œ',
  'Scaron': 'Š',
  'scaron': 'š',
  'Yuml': 'Ÿ',
  'fnof': 'ƒ',
  'Alpha': 'Α',
  'Beta': 'Β',
  'Gamma': 'Γ',
  'Delta': 'Δ',
  'Epsilon': 'Ε',
  'Zeta': 'Ζ',
  'Eta': 'Η',
  'Theta': 'Θ',
  'Iota': 'Ι',
  'Kappa': 'Κ',
  'Lambda': 'Λ',
  'Mu': 'Μ',
  'Nu': 'Ν',
  'Xi': 'Ξ',
  'Omicron': 'Ο',
  'Pi': 'Π',
  'Rho': 'Ρ',
  'Sigma': 'Σ',
  'Tau': 'Τ',
  'Upsilon': 'Υ',
  'Phi': 'Φ',
  'Chi': 'Χ',
  'Psi': 'Ψ',
  'Omega': 'Ω',
  'alpha': 'α',
  'beta': 'β',
  'gamma': 'γ',
  'delta': 'δ',
  'epsilon': 'ε',
  'zeta': 'ζ',
  'eta': 'η',
  'theta': 'θ',
  'iota': 'ι',
  'kappa': 'κ',
  'lambda': 'λ',
  'mu': 'μ',
  'nu': 'ν',
  'xi': 'ξ',
  'omicron': 'ο',
  'pi': 'π',
  'rho': 'ρ',
  'sigmaf': 'ς',
  'sigma': 'σ',
  'tau': 'τ',
  'upsilon': 'υ',
  'phi': 'φ',
  'chi': 'χ',
  'psi': 'ψ',
  'omega': 'ω',
  'thetasym': 'ϑ',
  'upsih': 'ϒ',
  'piv': 'ϖ',
  'ensp': ' ',
  'emsp': ' ',
  'thinsp': ' ',
  'zwnj': '‌',
  'zwj': '‍',
  'lrm': '‎',
  'rlm': '‏',
  'prime': '′',
  'Prime': '″',
  'oline': '‾',
  'frasl': '⁄',
  'weierp': '℘',
  'image': 'ℑ',
  'real': 'ℜ',
  'alefsym': 'ℵ',
  'larr': '←',
  'uarr': '↑',
  'rarr': '→',
  'darr': '↓',
  'harr': '↔',
  'crarr': '↵',
  'lArr': '⇐',
  'uArr': '⇑',
  'rArr': '⇒',
  'dArr': '⇓',
  'hArr': '⇔',
  'forall': '∀',
  'part': '∂',
  'exist': '∃',
  'empty': '∅',
  'nabla': '∇',
  'isin': '∈',
  'notin': '∉',
  'ni': '∋',
  'prod': '∏',
  'sum': '∑',
  'minus': '−',
  'lowast': '∗',
  'radic': '√',
  'prop': '∝',
  'infin': '∞',
  'ang': '∠',
  'and': '∧',
  'or': '∨',
  'cap': '∩',
  'cup': '∪',
  'int': '∫',
  'there4': '∴',
  'sim': '∼',
  'cong': '≅',
  'asymp': '≈',
  'ne': '≠',
  'equiv': '≡',
  'le': '≤',
  'ge': '≥',
  'sub': '⊂',
  'sup': '⊃',
  'nsub': '⊄',
  'sube': '⊆',
  'supe': '⊇',
  'oplus': '⊕',
  'otimes': '⊗',
  'perp': '⊥',
  'sdot': '⋅',
  'lceil': '⌈',
  'rceil': '⌉',
  'lfloor': '⌊',
  'rfloor': '⌋',
  'lang': '〈',
  'rang': '〉',
  'loz': '◊',
  'spades': '♠',
  'clubs': '♣',
  'hearts': '♥',
  'diams': '♦',
};

/**
 * HTML 实体解码（对齐官方 `ft.c1.a` 语义）。
 *
 * 支持 `&name;` 命名实体（表内）与 `&#N;` 数字实体（十进制）；`&#xH;` 十六进制
 * 与未知实体名按官方行为保留原文。数字实体码点 > 0xFFFF 时保留 `&#N;` 原样。
 * 官方引用块（post/check 响应的 content）为 HTML 混合 BBCode 文本，提交前须
 * 先经本函数解码再拼接（对应官方 quote 提交链 `d1.r(d1.w(content))` 的 `w`）。
 *
 * @param str - 原始文本
 * @returns 实体解码后的文本
 */
export function decodeHtmlEntities(str: string): string {
  if (str.length === 0) {
    return '';
  }
  let result: string = '';
  let cursor: number = 0;
  while (cursor < str.length) {
    const ampIndex: number = str.indexOf('&', cursor);
    if (ampIndex < 0) {
      result += str.substring(cursor);
      break;
    }
    result += str.substring(cursor, ampIndex);
    const semiIndex: number = str.indexOf(';', ampIndex + 1);
    if (semiIndex < 0) {
      result += str.substring(ampIndex);
      break;
    }
    const nextAmp: number = str.indexOf('&', ampIndex + 1);
    if (nextAmp >= 0 && nextAmp < semiIndex) {
      // '&' 与最近的 ';' 之间又出现 '&'：按官方语义不构成实体，保留 '&' 继续扫描
      result += '&';
      cursor = ampIndex + 1;
      continue;
    }
    const name: string = str.substring(ampIndex + 1, semiIndex);
    let code: number = -1;
    if (name.startsWith('#')) {
      const parsed: number = Number(name.substring(1));
      if (!Number.isNaN(parsed)) {
        code = parsed;
      }
    } else {
      const mapped: string | undefined = HTML_NAMED_ENTITIES[name];
      if (mapped !== undefined) {
        code = mapped.charCodeAt(0);
      }
    }
    if (code >= 0 && code <= 0xFFFF) {
      result += String.fromCharCode(code);
    } else {
      result += '&' + name + ';';
    }
    cursor = semiIndex + 1;
  }
  return result;
}

/**
 * 构造 application/x-www-form-urlencoded 请求体。
 * 所有字段按 UTF-8 百分号编码（官方 APP 签名通道与网页版通道均为 UTF-8 body；
 * 旧网页发帖通道的 GBK 字段编码已随 post.php 迁移移除）。
 * @param fields - 字段名到值的映射
 * @returns 拼接后的请求体字符串
 */
export function buildEncodedBody(fields: Record<string, string>): string {
  const parts: string[] = [];
  const keys = Object.keys(fields);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(fields[key])}`);
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
