import { decodeHtmlEntities } from '../_shared/HtmlEntityCodec'

/**
 * 判断标签名是否属于可继承的内联文字样式。
 *
 * @param name 待校验的标签名
 * @returns 是否为受支持的内联样式标签
 */
export function isInlineStyleTagName(name: string): boolean {
  const normalized: string = name.toLowerCase()
  return normalized === 'b' || normalized === 'item' || normalized === 'i' || normalized === 'u' ||
    normalized === 'del' || normalized === 'color' || normalized === 'size' || normalized === 'font' ||
    normalized === 'sub' || normalized === 'sup'
}

/**
 * 按内联解析器的既有规则校验文字样式标签属性。
 *
 * @param name 已解析的标签名
 * @param rawAttribute 等号后的原始属性；无属性时为空字符串
 * @returns 标签名与属性组合是否有效
 */
export function isValidInlineStyleTag(name: string, rawAttribute: string): boolean {
  const normalized: string = name.toLowerCase()
  if (!isInlineStyleTagName(normalized)) return false
  const attribute: string = decodeHtmlEntities(rawAttribute).trim()
  if (normalized === 'color') return /^(?:#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/.test(attribute)
  if (normalized === 'size') return /^(\d+)%$/.test(attribute)
  if (normalized === 'font') return attribute.length > 0 && attribute.length <= 64
  return true
}
