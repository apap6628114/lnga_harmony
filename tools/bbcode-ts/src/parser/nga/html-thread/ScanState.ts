/**
 * 平衡扫描状态机 — 处理 NGA HTML 中 JS 调用字面量的括号/字符串/数组提取。
 *
 * 本文件包含三类扫描原语，它们逻辑并不完全同构，故分别独立实现：
 * - `extractBalancedBraces`：JSON 对象字面量专用。只认 `"` 为字符串引号，
 *   转义仅对 `"`/`\\`/`/`/`b`/`f`/`n`/`r`/`t` 跳过（JSON 标准转义集）。
 *   若改用通用扫描会改变 NGA JS 对象（含 `'` 包裹字符串）的解析行为，**不可统一**。
 * - `scanBalanced`：通用平衡括号扫描。认 `'` 与 `"` 为字符串引号，`\` 跳过下一字符。
 *   用于 `()` 与 `[]` 的参数体提取（postArg.proc / setDefault / attach.load）。
 *
 * `BraceMatchResult` 用 class 而非元组返回，规避 ArkTS 不支持解构的约束。
 */

/**
 * 平衡扫描结果。
 *
 * @value 含外层 delimiter 的子串（如 `(a, b)` 或 `[1, 2]`）
 * @endPos 闭括号之后的位置（供调用方继续扫描）
 */
class BraceMatchResult {
  value: string = '';
  endPos: number = 0;
}

/**
 * 提取以 `{` 开头、`{}` 平衡的 JSON 对象字面量子串（含外层 `{}`）。
 *
 * 与通用扫描的差异：
 * - 仅 `"` 视为字符串引号（NGA JS 对象常含 `'` 包裹的字符串，按 JSON 语义处理）
 * - 转义仅对 JSON 标准字符集跳过，其余 `\x` 不跳过
 * - 起始处跳过前导空白再匹配 `{`
 *
 * @param html 源字符串
 * @param startPos 开始扫描位置（跳过前导空白后须命中 `{`）
 * @returns 含外层 `{}` 的子串；未匹配到平衡的 `{}` 时返回空串
 */
function extractBalancedBraces(html: string, startPos: number): string {
  let pos: number = startPos;
  while (pos < html.length && (html[pos] === ' ' || html[pos] === '\n' ||
    html[pos] === '\r' || html[pos] === '\t')) {
    pos++;
  }
  if (pos >= html.length || html[pos] !== '{') {
    return '';
  }
  let depth: number = 1;
  const jsonStart: number = pos;
  pos++;
  let inString: boolean = false;
  let stringChar: string = '';
  while (pos < html.length && depth > 0) {
    const ch: string = html[pos];
    if (inString) {
      if (ch === '\\') {
        if (pos + 1 < html.length && (html[pos + 1] === '"' || html[pos + 1] === '\\' ||
          html[pos + 1] === '/' || html[pos + 1] === 'b' ||
          html[pos + 1] === 'f' || html[pos + 1] === 'n' ||
          html[pos + 1] === 'r' || html[pos + 1] === 't')) {
          pos += 2;
          continue;
        }
      }
      if (ch === stringChar) {
        inString = false;
      }
    } else {
      if (ch === '"') {
        inString = true;
        stringChar = ch;
      } else if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
      }
    }
    pos++;
  }
  if (depth !== 0) {
    return '';
  }
  return html.substring(jsonStart, pos);
}

/**
 * 通用平衡括号扫描。从指向开括号字符的位置开始，扫描到匹配的闭括号。
 *
 * 字符串引号认 `'` 与 `"`，转义用通用规则（`\` 跳过下一字符）。
 * 用于统一 postArg.proc / setDefault 的 `()` 与 attach.load 的 `[]` 参数体提取。
 *
 * 约定：
 * - startPos 必须指向开括号字符（`(` 或 `[`）本身
 * - depth 初值为 1（已计入起始开括号），随后 pos++ 消费开括号
 * - 返回 value 含外层 delimiter；调用方按需 `substring(1, len-1)` 去外层
 *
 * @param s 源字符串
 * @param startPos 开括号字符位置
 * @param openChar 开括号字符（`(` 或 `[`）
 * @param closeChar 闭括号字符（`)` 或 `]`）
 * @returns 扫描结果；未匹配到平衡括号时 value 为空、endPos 为扫描结束位置
 */
function scanBalanced(s: string, startPos: number, openChar: string, closeChar: string): BraceMatchResult {
  const result: BraceMatchResult = new BraceMatchResult();
  let pos: number = startPos;
  if (pos >= s.length || s[pos] !== openChar) {
    result.value = '';
    result.endPos = pos;
    return result;
  }
  let depth: number = 1;
  const segStart: number = pos;
  pos++;
  let inString: boolean = false;
  let stringChar: string = '';
  while (pos < s.length && depth > 0) {
    const ch: string = s[pos];
    if (inString) {
      if (ch === '\\') {
        pos += 2;
        continue;
      }
      if (ch === stringChar) {
        inString = false;
      }
    } else {
      if (ch === "'" || ch === '"') {
        inString = true;
        stringChar = ch;
      } else if (ch === openChar) {
        depth++;
      } else if (ch === closeChar) {
        depth--;
      }
    }
    pos++;
  }
  if (depth !== 0) {
    result.value = '';
    result.endPos = pos;
    return result;
  }
  result.value = s.substring(segStart, pos);
  result.endPos = pos;
  return result;
}

export { BraceMatchResult, extractBalancedBraces, scanBalanced };
