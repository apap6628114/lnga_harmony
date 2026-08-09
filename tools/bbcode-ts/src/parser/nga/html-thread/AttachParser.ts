/**
 * 附件数据解析 — 从 NGA 帖子页 ubbcode.attach.load() 调用中提取附件元信息。
 *
 * `[]` 数组体的平衡扫描统一走 `scanBalanced`（见 ScanState.ets）。
 * 数组内单个 `{}` 对象的扫描保留独立实现（原样），因为其语义为遍历提取多个对象、
 * 且 `}` 闭合判断与顶层平衡扫描不同（遇到 brDepth 归零即记录 itemEnd）。
 */

import { scanBalanced } from './ScanState';

/**
 * 从 HTML 中解析 ubbcode.attach.load() 调用的附件数据（优先方案）。
 *
 * 定位 `ubbcode.attach.load('postattach${lou}', ..., 'postcontent${lou}', [...])` 调用，
 * 扫描最后的 `[...]` 数组体，逐个提取对象中的 url/name/type/thumb/size/dscp 等字段。
 *
 * @param html 源 HTML
 * @param lou 楼层号
 * @returns 附件元信息数组；无附件或解析失败时返回 null
 */
function tryParseAttachLoad(html: string, lou: number): Record<string, Object>[] | null {
  const marker: string = `ubbcode.attach.load('postattach${lou}'`;
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) return null;

  const afterMarker: string = html.substring(startIdx + marker.length);
  const contentMarker: string = `'postcontent${lou}'`;
  const contentIdx: number = afterMarker.indexOf(contentMarker);
  if (contentIdx < 0) return null;

  let pos: number = contentIdx + contentMarker.length;
  while (pos < afterMarker.length && (afterMarker[pos] === ',' || afterMarker[pos] === ' ' ||
    afterMarker[pos] === '\n' || afterMarker[pos] === '\r')) {
    pos++;
  }
  if (pos >= afterMarker.length || afterMarker[pos] !== '[') return null;

  const matched = scanBalanced(afterMarker, pos, '[', ']');
  if (!matched.value) return null;
  const raw: string = matched.value;

  const attachs: Record<string, Object>[] = [];
  let itemStart: number = raw.indexOf('{');
  let itemIdx: number = 0;

  while (itemStart >= 0) {
    let itemEnd: number = -1;
    let brDepth: number = 0;
    let inStr: boolean = false;
    let strChar: string = '';
    for (let si: number = itemStart; si < raw.length; si++) {
      const sc: string = raw[si];
      if (inStr) {
        if (sc === '\\') { si++; continue; }
        if (sc === strChar) inStr = false;
      } else {
        if (sc === "'" || sc === '"') { inStr = true; strChar = sc; }
        else if (sc === '{') brDepth++;
        else if (sc === '}') { brDepth--; if (brDepth === 0) { itemEnd = si + 1; break; } }
      }
    }
    if (itemEnd < 0) break;

    const itemBody: string = raw.substring(itemStart, itemEnd);
    itemStart = raw.indexOf('{', itemEnd);

    const urlMatch: RegExpExecArray | null = /url\s*:\s*'([^']*)'/i.exec(itemBody);
    const nameMatch: RegExpExecArray | null = /name\s*:\s*'([^']*)'/i.exec(itemBody);
    const typeMatch: RegExpExecArray | null = /type\s*:\s*'([^']*)'/i.exec(itemBody);
    const thumbMatch: RegExpExecArray | null = /thumb\s*:\s*'([^']*)'/i.exec(itemBody);
    const sizeMatch: RegExpExecArray | null = /size\s*:\s*'([^']*)'/i.exec(itemBody);
    const dscpMatch: RegExpExecArray | null = /dscp\s*:\s*'([^']*)'/i.exec(itemBody);
    const orgNameMatch: RegExpExecArray | null = /url_utf8_org_name\s*:\s*'([^']*)'/i.exec(itemBody);
    const aidMatch: RegExpExecArray | null = /aid\s*:\s*'([^']*)'/i.exec(itemBody);

    const url: string = urlMatch ? urlMatch[1] : '';
    const fileExtMatch: RegExpExecArray | null = /\.(\w+)$/.exec(url);
    const fileExt: string = fileExtMatch ? fileExtMatch[1].toLowerCase() : '';

    attachs.push({
      'aid': aidMatch ? aidMatch[1] : '',
      'attachurl': url,
      'url_utf8_org_name': orgNameMatch ? orgNameMatch[1] : '',
      'name': nameMatch ? nameMatch[1] : '',
      'ext': fileExt,
      'type': typeMatch ? typeMatch[1] : 'img',
      'size': Number(sizeMatch ? sizeMatch[1] : '0') || 0,
      'thumb': Number(thumbMatch ? thumbMatch[1] : '0') || 0,
      'dscp': dscpMatch ? dscpMatch[1] : '',
      'subid': itemIdx,
    });
    itemIdx++;
  }

  return attachs.length > 0 ? attachs : null;
}

export { tryParseAttachLoad };
