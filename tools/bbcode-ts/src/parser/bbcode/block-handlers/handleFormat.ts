import { BBNode, BBNodeType } from '../../../model/BBCodeNode'
import { createBBNode, indexOfIgnoreCase, ParseState } from '../lexer'
import { parseBlockNodes, parseBBCode } from '../parser'

/** [hr] 水平分隔线标签正则。 */
const P_HR: RegExp = /\[hr\s*\/?\]/iy

/** [h] 标题开始标签正则。 */
const P_H_OPEN: RegExp = /\[h\]/iy

/** [h] 标题闭合标签集合。 */
const CLOSE_H_TAGS: string[] = ['[/h]']

/** [p] 段落开始标签正则。 */
const P_P_OPEN: RegExp = /\[p\]/iy

/** [p] 段落闭合标签集合。 */
const CLOSE_P_TAGS: string[] = ['[/p]']

/** [dice] 骰子标签正则（含惰性匹配内容捕获）。 */
const P_DICE: RegExp = /\[dice\](.*?)\[\/dice\]/iy

/** [l] 左浮动开始标签正则。 */
const P_L_OPEN: RegExp = /\[l\]/iy

/** [l] 左浮动闭合标签集合。 */
const CLOSE_L_TAGS: string[] = ['[/l]']

/** [r] 右浮动开始标签正则。 */
const P_R_OPEN: RegExp = /\[r\]/iy

/** [r] 右浮动闭合标签集合。 */
const CLOSE_R_TAGS: string[] = ['[/r]']

/** [align=...] 对齐开始标签正则。 */
const P_ALIGN: RegExp = /\[align=(\w+)\]/iy

/** [align] 对齐闭合标签集合。 */
const CLOSE_ALIGN_TAGS: string[] = ['[/align]']

/** [style ...] 样式块开始标签正则。 */
const P_STYLE: RegExp = /\[style(?:\s+|=)([^\]]*)\]/iy

/** [style] 样式块闭合标签集合。 */
const CLOSE_STYLE_TAGS: string[] = ['[/style]']

/** [hip] 高亮提示标签正则。 */
const P_HIP: RegExp = /\[hip\]/iy

/** [comment...] 注释标签正则。 */
const P_COMMENT: RegExp = /\[comment[^\]]*\]/iy

/** [randomblock] 随机块标签正则。 */
const P_RANDOM: RegExp = /\[randomblock\]/iy

/**
 * [hr] 水平分隔线处理器。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了水平分隔线
 */
export const handleHorizontalRule = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos: number = state.pos
  P_HR.lastIndex = state.pos
  const match: RegExpExecArray | null = P_HR.exec(state.content)
  if (match && match.index === state.pos) {
    state.pos = P_HR.lastIndex
    const node = createBBNode()
    node.type = BBNodeType.HR
    result.push(node)
    return true
  }
  state.pos = savedPos
  return false
}

/**
 * `[h]...[/h]` 四级标题块处理器。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了标题块
 */
export const handleHeading = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos: number = state.pos
  P_H_OPEN.lastIndex = state.pos
  const match: RegExpExecArray | null = P_H_OPEN.exec(state.content)
  if (match && match.index === state.pos) {
    state.pos = P_H_OPEN.lastIndex
    const node: BBNode = createBBNode()
    node.type = BBNodeType.HEADING
    node.children = parseBlockNodes(state, CLOSE_H_TAGS)
    result.push(node)
    return true
  }
  state.pos = savedPos
  return false
}

/**
 * [p] 段落块处理器。
 *
 * @param state 解析游标
 * @param result 当前块级节点输出数组
 * @returns 是否匹配并消费了段落块
 */
export const handleParagraph = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos: number = state.pos
  P_P_OPEN.lastIndex = state.pos
  const match: RegExpExecArray | null = P_P_OPEN.exec(state.content)
  if (match && match.index === state.pos) {
    state.pos = P_P_OPEN.lastIndex
    const node = createBBNode()
    node.type = BBNodeType.PARAGRAPH
    node.children = parseBlockNodes(state, CLOSE_P_TAGS)
    result.push(node)
    return true
  }
  state.pos = savedPos
  return false
}

/**
 * [dice]骰子块处理器。仅记录占位节点。
 */
export const handleDice = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_DICE.lastIndex = state.pos
  const dm = P_DICE.exec(state.content)
  if (dm && dm.index === state.pos) {
    state.pos = P_DICE.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.DICE
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [l]左浮动块处理器。递归解析到 [/l] 前的正文。
 */
export const handleFloatLeft = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_L_OPEN.lastIndex = state.pos
  const flm = P_L_OPEN.exec(state.content)
  if (flm && flm.index === state.pos) {
    state.pos = P_L_OPEN.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.FLOAT_LEFT
    n.children = parseBlockNodes(state, CLOSE_L_TAGS)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [r]右浮动块处理器。递归解析到 [/r] 前的正文。
 */
export const handleFloatRight = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_R_OPEN.lastIndex = state.pos
  const frm = P_R_OPEN.exec(state.content)
  if (frm && frm.index === state.pos) {
    state.pos = P_R_OPEN.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.FLOAT_RIGHT
    n.children = parseBlockNodes(state, CLOSE_R_TAGS)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [align=left|center|right]对齐块处理器。递归解析到 [/align] 前的正文。
 */
export const handleAlign = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_ALIGN.lastIndex = state.pos
  const alm = P_ALIGN.exec(state.content)
  if (alm && alm.index === state.pos) {
    const alignVal: string = alm[1].toLowerCase()
    state.pos = P_ALIGN.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.ALIGN
    n.align = alignVal
    n.children = parseBlockNodes(state, CLOSE_ALIGN_TAGS)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [style 属性]样式块处理器。保留原始样式串并递归解析到 [/style] 前的正文。
 */
export const handleStyle = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_STYLE.lastIndex = state.pos
  const sm = P_STYLE.exec(state.content)
  if (sm && sm.index === state.pos) {
    const styleVal = sm[1]
    state.pos = P_STYLE.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.STYLE_DIV
    n.text = styleVal
    n.children = parseBlockNodes(state, CLOSE_STYLE_TAGS)
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [hip]高亮提示块处理器。decode 后重新解析内部 BBCode，结果直接并入父输出。
 */
export const handleHip = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_HIP.lastIndex = state.pos
  const hipm = P_HIP.exec(state.content)
  if (hipm && hipm.index === state.pos) {
    state.pos = P_HIP.lastIndex
    let end = indexOfIgnoreCase(state.content, '[/hip]', state.pos)
    if (end < 0) end = state.len
    const body = state.content.substring(state.pos, end)
    state.pos = end < state.len ? end + 6 : state.len
    const innerNodes = parseBBCode(body)
    for (let k = 0; k < innerNodes.length; k++) {
      result.push(innerNodes[k])
    }
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [comment...]注释块处理器。直接吞咽，不产生节点。
 */
export const handleComment = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_COMMENT.lastIndex = state.pos
  const comt = P_COMMENT.exec(state.content)
  if (comt && comt.index === state.pos) {
    state.pos = P_COMMENT.lastIndex
    return true
  }

  state.pos = savedPos
  return false
}

/**
 * [randomblock]随机块处理器。产出带 nga-randomblock 标记的 STYLE_DIV 节点。
 */
export const handleRandomBlock = (state: ParseState, result: BBNode[]): boolean => {
  const savedPos = state.pos

  P_RANDOM.lastIndex = state.pos
  const rbm = P_RANDOM.exec(state.content)
  if (rbm && rbm.index === state.pos) {
    state.pos = P_RANDOM.lastIndex
    const n = createBBNode()
    n.type = BBNodeType.STYLE_DIV
    n.text = 'nga-randomblock'
    result.push(n)
    return true
  }

  state.pos = savedPos
  return false
}
