/**
 * NGA API 返回 JSON 的净化 / 修复预处理。
 *
 * NGA 的 JSON 响应非标准，本函数在 `JSON.parse` 前修复以下问题：
 * - 去除 `window.script_muti_get_var_store=` 前缀；
 * - 去除 NGA 插入的 `/* ... * /` 风格非法注释（如 `$js$`、`error fill content`）；
 * - 修复 `"content":+123` / `"subject":+123` 形式的数字字面量为字符串；
 * - 修复 `"content"` / `"subject"` / `"author"` 字段中前导零数字（如 `0123`、
 *   `0123.5`，含对象末尾无逗号场景）为字符串；
 * - 转义字符串字面量内的控制字符（制表符、换行等 < 0x20）。
 *
 * @param text NGA 返回的原始文本
 * @returns 可被 `JSON.parse` 接受的合法 JSON 字符串
 */
export function preprocessJson(text: string): string {
  let t = text;
  t = t.replace('window.script_muti_get_var_store=', '');
  t = t.replace(/\/\*\$js\$\*\//g, '');
  t = t.replace(/\/\*error fill content\*\//g, '');
  t = t.replace(/"content":\+(\d+),/g, '"content":"+$1",');
  t = t.replace(/"subject":\+(\d+),/g, '"subject":"+$1",');
  t = t.replace(/"content":(0\d+(?:\.\d+)?)([,\]}])/g, '"content":"$1"$2');
  t = t.replace(/"subject":(0\d+(?:\.\d+)?)([,\]}])/g, '"subject":"$1"$2');
  t = t.replace(/"author":(0\d+(?:\.\d+)?)([,\]}])/g, '"author":"$1"$2');

  let inString = false;
  let escaped = false;
  let result = '';
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    const code = t.charCodeAt(i);
    if (escaped) {
      result += ch;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      result += ch;
      escaped = true;
      continue;
    }
    if (ch === '"') {
      inString = !inString;
      result += ch;
      continue;
    }
    if (inString && code < 0x20) {
      if (code === 0x09) result += '\\t';
      else if (code === 0x0a) result += '\\n';
      else if (code === 0x0d) result += '\\r';
      else result += '\\u' + code.toString(16).padStart(4, '0');
      continue;
    }
    result += ch;
  }
  return result;
}

