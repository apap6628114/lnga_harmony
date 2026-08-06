import { BBNode, BBNodeType } from '../../model/BBCodeNode'
import { decodeHtmlEntities } from '../_shared/HtmlEntityCodec'
import { createBBNode, isSafeUrl, pushTextNode } from './lexer'
import { isInlineStyleTagName, isValidInlineStyleTag } from './inline-tag-policy'

/** 可作为视频播放的常见文件扩展名。 */
const MEDIA_VIDEO_EXTS: string[] = ['mp4', 'webm', 'ogg', 'mov', '3gp']

/** 可作为音频播放的常见文件扩展名。 */
const MEDIA_AUDIO_EXTS: string[] = ['mp3', 'wav', 'flac', 'aac', 'm4a']

/** 单个内联样式标签允许的最大字符数。 */
const MAX_INLINE_TAG_LENGTH: number = 512

/**
 * 单个内联链接标签（url/pid/uid/tid）允许的最大字符数。
 *
 * 官方网页对 `[url=]` 属性长度不设限（实测渲染 1349 字符的 text fragment
 * 链接完整保留），链接属性是纯数据而非样式声明；放开上限的同时保留
 * 极端超长标签的防护。
 */
const MAX_INLINE_LINK_TAG_LENGTH: number = 8192

/** 内联格式允许的最大嵌套层数。 */
const MAX_INLINE_DEPTH: number = 64

/**
 * 内联标签词法单元。
 */
class InlineTagToken {
  /** 标签原文。 */
  raw: string = ''
  /** 规范化后的小写标签名。 */
  name: string = ''
  /** 等号后的原始属性。 */
  attribute: string = ''
  /** 是否为闭合标签。 */
  closing: boolean = false
  /** 标签结束后的字符位置。 */
  end: number = 0
}

/**
 * 尚未闭合的内联节点栈帧。
 */
class InlineFrame {
  /** 与闭合标签配对的小写标签名。 */
  tagName: string = ''
  /** 当前标签对应的语义节点。 */
  node: BBNode = new BBNode()
  /** 无属性 URL 是否需要从显示文字推导地址。 */
  deriveUrlFromText: boolean = false
}

/**
 * 根据文件扩展名推测媒体类型。
 *
 * @param rawUrl 原始媒体地址
 * @returns 图片、视频或音频节点类型
 */
function guessMediaTypeFromExt(rawUrl: string): BBNodeType {
  const extMatch: RegExpExecArray | null = /\.(\w+)(\?.*)?$/.exec(rawUrl)
  if (!extMatch) return BBNodeType.IMAGE
  const ext: string = extMatch[1].toLowerCase()
  if (MEDIA_VIDEO_EXTS.indexOf(ext) >= 0) return BBNodeType.VIDEO
  if (MEDIA_AUDIO_EXTS.indexOf(ext) >= 0) return BBNodeType.AUDIO
  return BBNodeType.IMAGE
}

/**
 * 从指定位置读取完整的方括号标签。
 *
 * @param segment 内联原始片段
 * @param start 左中括号位置
 * @returns 可识别标签；普通方括号文本返回 null
 */
function readInlineTag(segment: string, start: number): InlineTagToken | null {
  const closeBracket: number = segment.indexOf(']', start + 1)
  if (closeBracket < 0) return null
  let body: string = segment.substring(start + 1, closeBracket).trim()
  if (body.length === 0) return null

  let closing: boolean = false
  if (body.startsWith('/')) {
    closing = true
    body = body.substring(1).trim()
  }

  const equalIndex: number = body.indexOf('=')
  const name: string = (equalIndex >= 0 ? body.substring(0, equalIndex) : body).trim()
  if (!/^[a-z]+$/i.test(name)) return null
  // 链接类标签属性是数据而非样式（官方对 URL 长度不设限），按类别选择长度上限
  const limit: number = isInlineLinkTag(name.toLowerCase()) ?
    MAX_INLINE_LINK_TAG_LENGTH : MAX_INLINE_TAG_LENGTH
  if (closeBracket - start + 1 > limit) return null

  const raw: string = segment.substring(start, closeBracket + 1)
  const token = new InlineTagToken()
  token.raw = raw
  token.end = closeBracket + 1
  token.closing = closing
  token.name = name.toLowerCase()
  token.attribute = equalIndex >= 0 ? body.substring(equalIndex + 1).trim() : ''
  return token
}

/**
 * 判断标签是否属于内联链接。
 *
 * @param name 小写标签名
 * @returns 是否为链接标签
 */
function isInlineLinkTag(name: string): boolean {
  return name === 'url' || name === 'pid' || name === 'uid' || name === 'tid'
}

/**
 * 返回栈顶节点的子节点数组，空栈时返回根节点数组。
 *
 * @param root 当前片段根节点
 * @param frames 开放标签栈
 * @returns 新节点应追加到的数组
 */
function currentChildren(root: BBNode[], frames: InlineFrame[]): BBNode[] {
  if (frames.length === 0) return root
  return frames[frames.length - 1].node.children
}

/**
 * 把样式标签映射为语义节点类型。
 *
 * @param name 小写标签名
 * @returns 对应节点类型
 */
function styleNodeType(name: string): BBNodeType {
  if (name === 'b' || name === 'item') return BBNodeType.BOLD
  if (name === 'i') return BBNodeType.ITALIC
  if (name === 'u') return BBNodeType.UNDERLINE
  if (name === 'del') return BBNodeType.STRIKETHROUGH
  if (name === 'color') return BBNodeType.COLOR
  if (name === 'size') return BBNodeType.SIZE
  if (name === 'font') return BBNodeType.FONT
  if (name === 'sub') return BBNodeType.SUBSCRIPT
  return BBNodeType.SUPERSCRIPT
}

/**
 * 校验并写入样式标签属性。
 *
 * @param node 待填充样式节点
 * @param tag 标签词法单元
 * @returns 属性是否有效
 */
function applyStyleAttribute(node: BBNode, tag: InlineTagToken): boolean {
  if (node.type === BBNodeType.COLOR) {
    const color: string = decodeHtmlEntities(tag.attribute).trim()
    if (!/^(?:#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/.test(color)) return false
    node.color = color
  } else if (node.type === BBNodeType.SIZE) {
    const sizeMatch: RegExpExecArray | null = /^(\d+)%$/.exec(tag.attribute)
    if (!sizeMatch) return false
    node.size = Math.min(300, Math.max(50, parseInt(sizeMatch[1], 10)))
  } else if (node.type === BBNodeType.FONT) {
    const family: string = decodeHtmlEntities(tag.attribute).trim()
    if (family.length === 0 || family.length > 64) return false
    node.fontFamily = family
  }
  return true
}

/**
 * 把节点树中的可见文字追加到分片数组。
 *
 * @param nodes 内联节点树
 * @param parts 文字分片输出数组
 */
function appendInlineText(nodes: BBNode[], parts: string[]): void {
  for (let i: number = 0; i < nodes.length; i++) {
    const node: BBNode = nodes[i]
    if (node.text.length > 0) parts.push(node.text)
    if (node.children.length > 0) appendInlineText(node.children, parts)
  }
}

/**
 * 收集节点树的可见文字，供无属性 URL 推导跳转地址。
 *
 * @param nodes 内联节点树
 * @returns 拼接后的可见文字
 */
function collectInlineText(nodes: BBNode[]): string {
  const parts: string[] = []
  appendInlineText(nodes, parts)
  return parts.join('')
}

/**
 * 根据标签属性生成链接地址。
 *
 * @param tag 链接开始标签
 * @returns 应写入节点的安全地址
 */
function createLinkHref(tag: InlineTagToken): string {
  const attribute: string = decodeHtmlEntities(tag.attribute).trim()
  if (tag.name === 'url') return isSafeUrl(attribute) ? attribute : ''
  if (tag.name === 'uid') return attribute.length > 0 ? `#/profile?uid=${attribute}` : ''
  if (tag.name === 'pid') {
    const parts: string[] = attribute.split(',')
    return parts.length >= 2 && parts[0].length > 0 && parts[1].length > 0 ?
      `#/thread?tid=${parts[1]}&pid=${parts[0]}` : ''
  }
  const pageMarker: string = '&page='
  const pageIndex: number = attribute.toLowerCase().indexOf(pageMarker)
  const tid: string = pageIndex >= 0 ? attribute.substring(0, pageIndex) : attribute
  const page: string = pageIndex >= 0 ? attribute.substring(pageIndex + pageMarker.length) : ''
  return tid.length > 0 ? `#/thread?tid=${tid}${page.length > 0 ? '&page=' + page : ''}` : ''
}

/**
 * 打开一个样式或链接标签并压入栈。
 *
 * @param tag 开始标签
 * @param root 当前片段根节点
 * @param frames 开放标签栈
 * @returns 是否成功识别并打开
 */
function openInlineFrame(tag: InlineTagToken, root: BBNode[], frames: InlineFrame[]): boolean {
  if (!isInlineStyleTagName(tag.name) && !isInlineLinkTag(tag.name)) return false
  if (frames.length >= MAX_INLINE_DEPTH) return false
  const node = createBBNode()
  if (isInlineStyleTagName(tag.name)) {
    if (!isValidInlineStyleTag(tag.name, tag.attribute)) return false
    node.type = styleNodeType(tag.name)
    if (!applyStyleAttribute(node, tag)) return false
  } else {
    node.type = tag.name === 'url' ? BBNodeType.URL :
      tag.name === 'pid' ? BBNodeType.PID_LINK :
        tag.name === 'uid' ? BBNodeType.UID_LINK : BBNodeType.TID_LINK
    node.href = createLinkHref(tag)
  }

  currentChildren(root, frames).push(node)
  const frame = new InlineFrame()
  frame.tagName = tag.name
  frame.node = node
  frame.deriveUrlFromText = tag.name === 'url' && tag.attribute.length === 0
  frames.push(frame)
  return true
}

/**
 * 完成链接栈帧的派生字段。
 *
 * @param frame 即将关闭的栈帧
 */
function finalizeFrame(frame: InlineFrame): void {
  if (frame.deriveUrlFromText) {
    const href: string = collectInlineText(frame.node.children).trim()
    frame.node.href = isSafeUrl(href) ? href : ''
  }
}

/**
 * 闭合最近的同名标签；交叉标签按容错规则自动闭合其上的栈帧。
 *
 * @param name 小写闭合标签名
 * @param frames 开放标签栈
 * @returns 是否找到匹配的开始标签
 */
function closeInlineFrame(name: string, frames: InlineFrame[]): boolean {
  let matchIndex: number = -1
  for (let i: number = frames.length - 1; i >= 0; i--) {
    if (frames[i].tagName === name) {
      matchIndex = i
      break
    }
  }
  if (matchIndex < 0) return false
  for (let i: number = frames.length - 1; i >= matchIndex; i--) {
    finalizeFrame(frames[i])
    frames.pop()
  }
  return true
}

/**
 * 尝试解析提及或表情等单标签节点。
 *
 * @param rawBody 方括号内部原文
 * @param target 当前输出数组
 * @returns 是否成功识别
 */
function appendInlineAtom(rawBody: string, target: BBNode[]): boolean {
  const mention: RegExpExecArray | null = /^@(\d+)$/.exec(rawBody)
  if (mention) {
    const node = createBBNode()
    node.type = BBNodeType.MENTION
    node.href = `#/profile?uid=${mention[1]}`
    node.text = `@${mention[1]}`
    target.push(node)
    return true
  }

  const emotion: RegExpExecArray | null = /^s:(\w+):([^\]]+)$/.exec(rawBody)
  if (emotion) {
    const node = createBBNode()
    node.type = BBNodeType.EMOTION
    node.emotionCat = emotion[1]
    node.emotionCode = emotion[2]
    target.push(node)
    return true
  }

  const oldEmotion: RegExpExecArray | null = /^s:(\d+)$/.exec(rawBody)
  if (oldEmotion) {
    const node = createBBNode()
    node.type = BBNodeType.EMOTION
    node.emotionCat = 'old'
    node.emotionCode = oldEmotion[1]
    node.text = `[表情${oldEmotion[1]}]`
    target.push(node)
    return true
  }
  return false
}

/**
 * 使用显式标签栈解析一段不含块节点的 BBCode。
 *
 * @param segment 未解码的内联正文
 * @param into 节点输出数组
 */
function parseInlineInto(segment: string, into: BBNode[]): void {
  const frames: InlineFrame[] = []
  let index: number = 0
  while (index < segment.length) {
    const bracketIndex: number = segment.indexOf('[', index)
    if (bracketIndex < 0) {
      pushTextNode(currentChildren(into, frames), segment.substring(index))
      break
    }
    if (bracketIndex > index) {
      pushTextNode(currentChildren(into, frames), segment.substring(index, bracketIndex))
    }

    const closeBracket: number = segment.indexOf(']', bracketIndex + 1)
    if (closeBracket < 0) {
      pushTextNode(currentChildren(into, frames), segment.substring(bracketIndex))
      break
    }
    const rawBody: string = segment.substring(bracketIndex + 1, closeBracket).trim()
    if (appendInlineAtom(rawBody, currentChildren(into, frames))) {
      index = closeBracket + 1
      continue
    }

    const tag: InlineTagToken | null = readInlineTag(segment, bracketIndex)
    if (tag !== null) {
      const handled: boolean = tag.closing ? closeInlineFrame(tag.name, frames) : openInlineFrame(tag, into, frames)
      if (handled) {
        index = tag.end
        continue
      }
      pushTextNode(currentChildren(into, frames), tag.raw)
      index = tag.end
      continue
    }

    if (segment.charAt(bracketIndex + 1) === '[') {
      pushTextNode(currentChildren(into, frames), '[')
      index = bracketIndex + 1
    } else {
      pushTextNode(currentChildren(into, frames), segment.substring(bracketIndex, closeBracket + 1))
      index = closeBracket + 1
    }
  }

  for (let i: number = frames.length - 1; i >= 0; i--) {
    finalizeFrame(frames[i])
  }
}

export { parseInlineInto, guessMediaTypeFromExt, MAX_INLINE_DEPTH, MAX_INLINE_TAG_LENGTH, MAX_INLINE_LINK_TAG_LENGTH }
