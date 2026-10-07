/**
 * 「智能去水」判定引擎 —— 纯函数、无 IO、无状态。
 *
 * 判定是**本地规则**，不调用模型：输入楼层的原始 BBCode 正文与三个上下文事实
 * （是否主楼 / 是否带附件 / 是否带楼中楼），输出「是否水楼层 + 命中原因」。
 *
 * ## 判定顺序（先豁免，再判水）
 *
 * 1. **硬豁免**：主楼（lou=0）、带附件的楼层、带楼中楼/热评的楼层、正文（**引用之外**的
 *    部分）含「富内容标记」（`[tid=` / `[img` / `[url` / `[code` / `[table` / `[list` 等）
 *    的楼层一律**保留**。这些标记代表图片、代码、表格、外链——即「有信息量」，
 *    无论正文多短都不该被判水。
 * 2. **等级词表**：按严格等级套用内置词表（BASIC / AGGRESSIVE，见词表注释）。
 * 3. **自定义规则**：用户规则在任何等级下都追加生效（显式配置优先于预设）。
 *
 * ## 引用块整体不参与判定
 *
 * 判定前先把 `[quote]…[/quote]` 块**整段剥掉**，只看作者自己写的内容。理由：
 * - 引用里的 `[img]` / `[url]` 是**别人**帖子的富内容，不该让本层免于判水；
 * - 引用正文几十上百字的长度不该计入「本条回复有多长」——否则「引用一段长文 + 回一句
 *   ‘同求’」永远逃过长度类规则，而这类回复恰恰是最典型的灌水。
 *
 * 例外：**只带引用、自己没有半个字的楼层保留**（引用是作者刻意带出的上下文，
 * 删掉会让后续对话失去锚点）。判据是剥完引用后紧凑文本为空。
 *
 * ## 为什么判定对象是「纯文本」而不是原始 BBCode
 *
 * 原始正文里混着标签与表情码，直接做长度/包含判断会把「`[b]mark[/b]`」算长、
 * 把「`[s:1]`」当成内容。因此先把标记剥掉得到纯文本，再做判断：长度阈值、
 * 短闲聊上限、包含/等值匹配**全部基于剥标记后的紧凑文本**（空白被移除）。
 *
 * ## 保守性红线
 *
 * 去水是**破坏性**操作（生成的本地帖子不再包含被删楼层），宁可漏删不可误删：
 * 任何「疑似但不确凿」的楼层一律保留。具体体现为两处设计：
 * - 「是否含信息字符」采用**反向白名单**判定（见 {@link isSymbolCode}）：只有
 *   明确属于标点/符号/表情码点的字符才算「无信息」，**未知字符一律算信息**。
 *   这样泰文、西里尔文、数学式等任何没被枚举到的文字都不会被误判成纯标点。
 * - 内置标记词表要求**整条等值**而非包含（见 {@link MARK_TOKENS}）。
 */

import { WaterFilterLevel, clampWaterLevel, isWaterRuleType, WaterRuleType } from '../model/WaterFilterRule'
import { WaterFilterRule } from '../model/WaterFilterRule'

/**
 * 富内容标记：正文（引用之外的部分）出现任一即视为「有信息量」，直接保留。
 *
 * 一律用**开标记**匹配（且多数不加收尾的 `]`）：NGA 的图片/媒体/折叠标签普遍带参数
 * （`[img=100,100]`、`[collapse=标题]`），写死 `[img]` 会漏判。
 *
 * **刻意不含 `[quote`**：引用块在判定前已被 {@link stripQuoteBlocks} 整段剥掉，
 * 引用里的图片/外链是别人帖子的内容，不该让本层免于判水。
 */
const RICH_MARKERS: string[] = [
  '[tid=', '[pid=', '[uid=', '[img', '[attach', '[url', '[code', '[table',
  '[list', '[*]', '[media', '[video', '[flash', '[collapse', '[album', '[sound',
  '[sup', '[sub', '[sp', '[h]', '[hr]'
]

/** 引用块开标记（小写比较）。 */
const QUOTE_OPEN: string = '[quote'
/** 引用块闭标记（小写比较）。 */
const QUOTE_CLOSE: string = '[/quote]'

/**
 * BASIC 档标记类词表：**整条正文等于**其中一项（或只多一个尾部语气符）才判水。
 *
 * 之所以要求等值而不是包含：这些词多数是常用字（如 `眼`、`顶`、`好`），包含
 * 匹配会误伤「顶楼的图挂了」这类正常回复。等值匹配的代价是「mark 一下，谢谢
 * 楼主」这类组合形式漏删，但它带语气、可能有人味，交给 AGGRESSIVE 档更合适。
 */
const MARK_TOKENS: string[] = [
  'mark', 'mk', 'ma', 'make', '马克', '马克一下', '马克一记', '马克吐温', 'mark一下',
  '留名', '留个名', '留个脚印', '留爪', '插眼', '插个眼', '眼', '标记', '标记一下',
  '记号', '作个记号', '收藏', '收藏了', '先收藏', '绑定', '绑', '前排', '沙发',
  '板凳', '地板', '地下室', '占楼', '占位', '路过', '飘过', '打酱油', '顶', '帮顶',
  '顶一下', 'up', 'upup', '看看', '看一下', '好', '很好', '不错', '收了', '拿走'
]

/**
 * AGGRESSIVE 档简短闲聊词表：剥标记后的紧凑文本**包含**其中一项，
 * 且长度不超过 {@link SMALL_TALK_MAX_LEN} 时判水。
 *
 * 长度上限是这里的关键约束：它把「感谢分享」判水，但保留「感谢分享，不过
 * 第 3 张图的参数好像写反了」这类带实质内容的回复。
 */
const SMALL_TALK_TOKENS: string[] = [
  '谢谢分享', '感谢分享', '多谢分享', '谢谢楼主', '感谢楼主', '谢谢', '多谢', '感谢',
  '辛苦了', '支持', '支持一下', '好帖', '好贴', '好文', '厉害', '牛', '牛逼', '牛b',
  'nb', '太强了', '强贴', '哈哈哈哈', '哈哈', '笑死', '笑死我了', '呵呵',
  '同求', '求资源', '求链接', '求地址', '同上', '同问', '同感', '学习', '学习了',
  '受教', '受教了', '关注', '围观', '涨知识', '涨姿势', '有道理', '确实', '确实如此',
  '同意', '赞同', '附议', '打卡', '签到', '真实', '有趣', '有意思', '第一个'
]

/** AGGRESSIVE 档短闲聊的长度上限（紧凑文本字符数）。 */
const SMALL_TALK_MAX_LEN: number = 12

/** BASIC 档「纯数字回复」的长度上限。 */
const PURE_DIGIT_MAX_LEN: number = 10

/** 纯笑声字符集（整条只有这些字符即视为笑）。 */
const LAUGH_CHARS: string = '哈嘿嘻呵~'

/** 尾部语气符容忍集：'mark了' / '插眼~' / '马克!' 这类只多一个尾巴的写法。 */
const TAIL_CHARS: string = '了~!！。的呀啊'

/**
 * 判定输入。
 */
export class WaterJudgeInput {
  /** 楼层原始正文（BBCode）。 */
  content: string = ''
  /** 是否主楼（lou === 0）。 */
  isOp: boolean = false
  /** 该楼层是否带附件（图片/文件）。 */
  hasAttach: boolean = false
  /** 该楼层是否有楼中楼或热评（代表存在讨论）。 */
  hasDiscussion: boolean = false
}

/**
 * 判定结果。
 */
export class WaterVerdict {
  /** 是否判为水楼层（true = 去水时移除）。 */
  water: boolean = false
  /** 命中原因（空串表示保留且未命中任何规则）。 */
  reason: string = ''
}

/**
 * 编译后的规则集：把配置解析结果缓存下来，避免在逐层循环里反复遍历规则表
 * 与做类型判断（上千页帖子的判定循环会跑几万次）。
 */
export class WaterRuleSet {
  /** 生效等级。 */
  level: number = WaterFilterLevel.BASIC
  /** 自定义「包含」关键词。 */
  contains: string[] = []
  /** 自定义「完全等于」关键词（已归一化：去空白 + 转小写）。 */
  equals: string[] = []
  /** 自定义「长度不超过」上限。 */
  maxLengths: number[] = []

  constructor(level: number) {
    this.level = clampWaterLevel(level)
  }

  /** 是否启用 AGGRESSIVE 档词表。 */
  get aggressive(): boolean {
    return this.level >= WaterFilterLevel.AGGRESSIVE
  }
}

/**
 * 把等级与自定义规则编译为规则集。
 *
 * @param level - 严格等级
 * @param rules - 自定义规则（未启用项被忽略）
 * @returns 编译后的规则集
 */
export function compileRuleSet(level: number, rules: WaterFilterRule[]): WaterRuleSet {
  const set: WaterRuleSet = new WaterRuleSet(level)
  for (let i = 0; i < rules.length; i++) {
    const rule: WaterFilterRule = rules[i]
    if (!rule || !rule.enabled || !isWaterRuleType(rule.type)) {
      continue
    }
    const value: string = rule.value.trim()
    if (value.length === 0) {
      continue
    }
    if (rule.type === WaterRuleType.CONTAINS) {
      // 与判定侧同一口径：比对的是紧凑文本，规则值必须先去空白，
      // 否则「同 求」这类带空格的规则永远匹配不上（用户看不出来为什么无效）
      set.contains.push(compactText(value))
    } else if (rule.type === WaterRuleType.EQUALS) {
      set.equals.push(normalizeForCompare(value))
    } else {
      const limit: number = Number(value)
      if (Number.isFinite(limit) && limit >= 1) {
        set.maxLengths.push(Math.round(limit))
      }
    }
  }
  return set
}

/**
 * 剥掉引用块，只留作者自己写的内容。
 *
 * 支持**嵌套引用**（引用里再引用）：从每个开标记开始配对闭标记，按深度计数，
 * 整段（含嵌套）一起丢掉。两类异常形状都按「到文末都算引用」处理——宁可少判一层水，
 * 也不要把别人的话当成作者的正文：
 * - 开标记本身被截断（找不到 `]`）；
 * - 没有配对的 `[/quote]`。
 *
 * 只有孤立的 `[/quote]`（开标记被裁掉）不在此处理：那种情况下引用正文会留在文本里，
 * 使长度偏长、判定偏保守，方向是安全的。
 *
 * @param content - 原始 BBCode 正文
 * @returns 剥掉引用块后的正文
 */
export function stripQuoteBlocks(content: string): string {
  const lower: string = content.toLowerCase()
  const len: number = content.length
  let text: string = ''
  let i: number = 0
  while (i < len) {
    const open: number = lower.indexOf(QUOTE_OPEN, i)
    if (open < 0) {
      text += content.substring(i)
      break
    }
    // 引用块之前的正文属于作者，保留
    text += content.substring(i, open)
    // 从该开标记起配对闭标记（按深度计数以支持嵌套）
    let depth: number = 0
    let cursor: number = open
    let end: number = len
    while (cursor < len) {
      const nextOpen: number = lower.indexOf(QUOTE_OPEN, cursor)
      const nextClose: number = lower.indexOf(QUOTE_CLOSE, cursor)
      if (nextClose < 0) {
        break
      }
      if (nextOpen >= 0 && nextOpen < nextClose) {
        depth++
        cursor = nextOpen + QUOTE_OPEN.length
        continue
      }
      depth--
      cursor = nextClose + QUOTE_CLOSE.length
      if (depth <= 0) {
        end = cursor
        break
      }
    }
    i = end
  }
  return text
}

/**
 * 剥掉 BBCode 标记，得到纯文本。
 *
 * 只把**短标签**（不含换行、长度 ≤ 32）当标记剥掉：正文里天然出现的方括号
 * （长引用、含换行的中括号）保持原样，避免把正常内容吃掉之后误判为「纯标点」。
 *
 * @param content - 原始 BBCode 正文
 * @returns 剥标记后的文本（保留空白与标点）
 */
export function stripMarkup(content: string): string {
  let text: string = ''
  let i: number = 0
  const len: number = content.length
  while (i < len) {
    const ch: string = content.charAt(i)
    if (ch === '[') {
      const close: number = content.indexOf(']', i + 1)
      if (close > i && close - i <= 32 && content.substring(i + 1, close).indexOf('\n') < 0) {
        i = close + 1
        continue
      }
    }
    text += ch
    i++
  }
  return text
}

/**
 * 移除所有空白字符（长度判定与等值比较都基于紧凑文本）。
 *
 * @param text - 输入文本
 * @returns 去掉空白后的文本
 */
export function compactText(text: string): string {
  let out: string = ''
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i)
    if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r' && c !== '\u3000') {
      out += c
    }
  }
  return out
}

/**
 * 归一化用于「完全等于」比较：去空白 + 转小写。
 *
 * @param text - 输入文本
 * @returns 归一化后的文本
 */
export function normalizeForCompare(text: string): string {
  return compactText(text).toLowerCase()
}

/**
 * 该码点是否明确属于「标点 / 符号 / 表情」（即不含信息）。
 *
 * **反向白名单**：只把枚举到的符号区段判为「无信息」，其余一律视为有信息。
 * 这样任何没被枚举到的文字系统（泰文、西里尔文、阿拉伯文、各类扩展汉字…）
 * 都不会被误判成「纯标点灌水」——这是去水不可误删的前提。
 *
 * @param cp - 字符码点
 * @returns 是否为符号类码点
 */
function isSymbolCode(cp: number): boolean {
  // 零宽连接符 / 变体选择符 / 键帽组合符（emoji 序列的组成部分）
  if (cp === 0x200D || cp === 0xFE0F || cp === 0x20E3) {
    return true
  }
  // ASCII 标点（! " # ... / : ; < = ... [ \ ] ^ _ ` { | } ~）
  if (cp >= 0x21 && cp <= 0x2F) return true
  if (cp >= 0x3A && cp <= 0x40) return true
  if (cp >= 0x5B && cp <= 0x60) return true
  if (cp >= 0x7B && cp <= 0x7E) return true
  // 通用标点（— … “ ” 等）
  if (cp >= 0x2000 && cp <= 0x206F) return true
  // 货币符号
  if (cp >= 0x20A0 && cp <= 0x20CF) return true
  // 箭头 / 杂项技术符号 / 带圈数字 / 制表符 / 几何图形
  if (cp >= 0x2190 && cp <= 0x21FF) return true
  if (cp >= 0x2300 && cp <= 0x23FF) return true
  if (cp >= 0x2460 && cp <= 0x24FF) return true
  if (cp >= 0x2500 && cp <= 0x25FF) return true
  // 杂项符号 + 装饰符号（含 ☀ ★ ✓ 与 emoji 主区段）
  if (cp >= 0x2600 && cp <= 0x27BF) return true
  if (cp >= 0x2B00 && cp <= 0x2BFF) return true
  // CJK 符号与标点（、。〈〉《》「」【】等）
  if (cp >= 0x3000 && cp <= 0x303F) return true
  // CJK 兼容形式 / 竖排标点
  if (cp >= 0xFE30 && cp <= 0xFE4F) return true
  // 全角标点（！＂＃ … ／：；＜＝…［＼］＾＿｀｛｜｝～）
  if (cp >= 0xFF01 && cp <= 0xFF0F) return true
  if (cp >= 0xFF1A && cp <= 0xFF20) return true
  if (cp >= 0xFF3B && cp <= 0xFF40) return true
  if (cp >= 0xFF5B && cp <= 0xFF65) return true
  // emoji 补充平面（含表情、图形、扩展 pictograph）
  if (cp >= 0x1F000 && cp <= 0x1FAFF) return true
  return false
}

/**
 * 紧凑文本是否含有任何「信息字符」。
 *
 * 用来识别纯标点、纯符号、纯表情回复（「。。。」「？？？」「😂😂」）。
 * 表情码与 BBCode 标记在此之前已被剥离，残留的只有标点与符号本身。
 *
 * @param compact - 紧凑文本
 * @returns 是否含信息字符
 */
function hasInformationChar(compact: string): boolean {
  for (let i = 0; i < compact.length; i++) {
    if (!isSymbolCode(compact.charCodeAt(i))) {
      return true
    }
  }
  return false
}

/**
 * 紧凑文本是否整条由同一个字符重复构成（「。。。」「!!!!」「aaa」）。
 *
 * @param compact - 紧凑文本
 * @returns 是否为重复字符
 */
function isRepeatedChar(compact: string): boolean {
  if (compact.length < 2) {
    return false
  }
  const first: string = compact.charAt(0)
  for (let i = 1; i < compact.length; i++) {
    if (compact.charAt(i) !== first) {
      return false
    }
  }
  return true
}

/**
 * 紧凑文本是否整条只有半角数字。
 *
 * @param compact - 紧凑文本
 * @returns 是否为纯数字
 */
function isPureDigits(compact: string): boolean {
  if (compact.length === 0) {
    return false
  }
  for (let i = 0; i < compact.length; i++) {
    const c: string = compact.charAt(i)
    if (c < '0' || c > '9') {
      return false
    }
  }
  return true
}

/**
 * 紧凑文本是否整条只有笑声字符。
 *
 * @param compact - 紧凑文本
 * @returns 是否为纯笑声
 */
function isPureLaugh(compact: string): boolean {
  if (compact.length === 0) {
    return false
  }
  for (let i = 0; i < compact.length; i++) {
    if (LAUGH_CHARS.indexOf(compact.charAt(i)) < 0) {
      return false
    }
  }
  return true
}

/**
 * 紧凑文本是否整条等于某个标记类词（BASIC 档）。
 *
 * 先按整条等值判定；再放宽一个**尾部语气符**，覆盖「mark 了」「插眼~」
 * 「马克!」这类常见写法。不放宽多个字符：放宽越多，误伤正常短句的概率越高。
 *
 * @param compact - 紧凑文本
 * @returns 是否命中标记类词
 */
function hitMarkToken(compact: string): boolean {
  const lower: string = compact.toLowerCase()
  for (let i = 0; i < MARK_TOKENS.length; i++) {
    const token: string = MARK_TOKENS[i]
    if (lower === token) {
      return true
    }
    if (lower.length === token.length + 1 && lower.startsWith(token) &&
      TAIL_CHARS.indexOf(lower.charAt(lower.length - 1)) >= 0) {
      return true
    }
  }
  return false
}

/**
 * 判水：BASIC 档内置规则。
 *
 * @param compact - 剥标记后的紧凑文本
 * @returns 命中原因；空串表示未命中
 */
function judgeBasic(compact: string): string {
  if (compact.length === 0) {
    return '纯表情或纯标记'
  }
  if (!hasInformationChar(compact)) {
    return '纯标点符号'
  }
  if (isRepeatedChar(compact)) {
    return '重复字符灌水'
  }
  if (compact.length <= PURE_DIGIT_MAX_LEN && isPureDigits(compact)) {
    return '纯数字回复'
  }
  if (hitMarkToken(compact)) {
    return '标记类回复'
  }
  return ''
}

/**
 * 判水：AGGRESSIVE 档追加规则（纯笑声 + 短闲聊词表）。
 *
 * @param compact - 剥标记后的紧凑文本
 * @returns 命中原因；空串表示未命中
 */
function judgeAggressive(compact: string): string {
  if (isPureLaugh(compact)) {
    return '纯笑声'
  }
  if (compact.length > SMALL_TALK_MAX_LEN) {
    return ''
  }
  const lower: string = compact.toLowerCase()
  for (let i = 0; i < SMALL_TALK_TOKENS.length; i++) {
    if (lower.indexOf(SMALL_TALK_TOKENS[i]) >= 0) {
      return '简短闲聊'
    }
  }
  return ''
}

/**
 * 判水：用户自定义规则（任何等级下都生效）。
 *
 * 自定义规则在等级判定**之后**执行：用户显式配置的意图优先级高于预设词表，
 * 因此不受等级开关影响；硬豁免（主楼/附件/讨论/富标记）仍然最优先。
 *
 * @param compact - 剥标记后的紧凑文本
 * @param set - 编译后的规则集
 * @returns 命中原因；空串表示未命中
 */
function judgeCustom(compact: string, set: WaterRuleSet): string {
  for (let i = 0; i < set.contains.length; i++) {
    if (compact.indexOf(set.contains[i]) >= 0) {
      return '自定义规则：包含「' + set.contains[i] + '」'
    }
  }
  const normalized: string = compact.toLowerCase()
  for (let i = 0; i < set.equals.length; i++) {
    if (normalized === set.equals[i]) {
      return '自定义规则：完全等于「' + set.equals[i] + '」'
    }
  }
  const limitCount: number = set.maxLengths.length
  if (limitCount > 0) {
    // 多个长度规则取最宽松的那个：同时配 5 与 10 时，用户意图是「10 以内都算水」
    let widest: number = set.maxLengths[0]
    for (let i = 1; i < limitCount; i++) {
      if (set.maxLengths[i] > widest) {
        widest = set.maxLengths[i]
      }
    }
    if (compact.length <= widest) {
      return '自定义规则：长度不超过 ' + String(widest)
    }
  }
  return ''
}

/**
 * 判定单个楼层是否为水楼层。
 *
 * @param input - 楼层判定输入
 * @param set - 编译后的规则集
 * @returns 判定结果（是否水 + 命中原因）
 */
export function judgeFloor(input: WaterJudgeInput, set: WaterRuleSet): WaterVerdict {
  const verdict: WaterVerdict = new WaterVerdict()
  // 硬豁免：主楼、带附件、带讨论 —— 一律保留
  if (input.isOp || input.hasAttach || input.hasDiscussion) {
    return verdict
  }
  const content: string = input.content
  // 只看作者自己写的内容：引用块整段剥掉（引用里的富内容与引用正文都不算数）
  const body: string = stripQuoteBlocks(content)
  const compact: string = compactText(stripMarkup(body))
  if (compact.length === 0 && body !== content) {
    // 只带引用、自己没有文字的楼层：引用是作者刻意带出的上下文，保留
    return verdict
  }
  const lowerBody: string = body.toLowerCase()
  for (let i = 0; i < RICH_MARKERS.length; i++) {
    if (lowerBody.indexOf(RICH_MARKERS[i]) >= 0) {
      return verdict
    }
  }

  const basicReason: string = judgeBasic(compact)
  if (basicReason.length > 0) {
    verdict.water = true
    verdict.reason = basicReason
    return verdict
  }
  if (set.aggressive) {
    const aggressiveReason: string = judgeAggressive(compact)
    if (aggressiveReason.length > 0) {
      verdict.water = true
      verdict.reason = aggressiveReason
      return verdict
    }
  }
  const customReason: string = judgeCustom(compact, set)
  if (customReason.length > 0) {
    verdict.water = true
    verdict.reason = customReason
    return verdict
  }
  return verdict
}
