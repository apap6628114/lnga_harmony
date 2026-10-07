/**
 * AI 场景与 System Prompt 配置数据模型。
 *
 * 定义内置 AI 场景（帖子内容总结、全帖总结、用户成分分析、智能去水规则生成）的枚举、
 * 元数据、默认 system prompt 以及注入数据字段说明。其中「智能去水规则生成」是非对话
 * 场景：单次调用后由调用方解析 JSON，不进入 AiChatPage。
 */

/**
 * AI 场景枚举。
 *
 * 用于标识不同的 AI 功能场景，
 * 每个场景拥有独立的 system prompt 和注入数据。
 */
export enum AiScenario {
  /** 帖子内容总结（只覆盖单个楼层，动作栏 AI 图标入口） */
  POST_SUMMARY = 'post_summary',
  /** 全帖总结（跨楼层汇总，标题栏右上角 AI 图标入口） */
  THREAD_SUMMARY = 'thread_summary',
  /** 用户成分分析 */
  USER_ANALYSIS = 'user_analysis',
  /**
   * 智能去水的规则生成（非对话场景）。
   *
   * 与其它场景不同：本场景**不进入 AiChatPage 对话界面**，由
   * `service/WaterFilterAiRulesService` 单次调用后解析成规则列表。因此不需要
   * 注入数据预览以外的任何 UI 接线，但 system prompt 仍可被用户自定义。
   */
  WATER_RULE_GEN = 'water_rule_gen'
}

/** 场景元数据项。 */
interface ScenarioMeta {
  /** 用户可读的场景名称 */
  name: string
  /** 场景功能描述 */
  desc: string
}

/**
 * 各场景元数据。
 *
 * 用于 UI 展示场景卡片标题和描述。
 */
export const SCENARIO_META: Record<string, ScenarioMeta> = {
  [AiScenario.POST_SUMMARY]: {
    name: '帖子内容总结',
    desc: '控制 AI 如何分析和总结单个楼层的正文内容'
  },
  [AiScenario.THREAD_SUMMARY]: {
    name: '全帖总结',
    desc: '控制 AI 如何汇总整个帖子的全部楼层内容'
  },
  [AiScenario.USER_ANALYSIS]: {
    name: '用户成分分析',
    desc: '控制 AI 如何分析论坛用户的行为和倾向'
  },
  [AiScenario.WATER_RULE_GEN]: {
    name: '智能去水规则生成',
    desc: '控制 AI 如何按帖子主题推断灌水表达并输出过滤规则（输出必须是约定格式的 JSON）'
  }
}

/**
 * 各场景默认 system prompt。
 *
 * 当用户未自定义时使用此默认值。
 */
export const DEFAULT_SYSTEM_PROMPTS: Record<string, string> = {
  [AiScenario.POST_SUMMARY]: [
    '你是一个专业的帖子内容分析助手。请根据用户提供的帖子正文内容进行深度总结归纳。',
    '',
    '分析要点：',
    '1. 核心观点：提取帖子的主要论点和立场',
    '2. 关键信息：列出重要的事实、数据或论据',
    '3. 逻辑脉络：梳理帖子的行文结构和论证逻辑',
    '4. 一句话总结：用精炼的语言概括帖子的核心内容'
  ].join('\n'),
  [AiScenario.THREAD_SUMMARY]: [
    '你是一个论坛长帖分析助手。用户会提供同一个主题帖内多个楼层的内容，楼层按楼号顺序排列，请跨楼层对整帖做总结。',
    '',
    '注意：注入数据可能因页数或长度上限只覆盖了帖子的部分楼层（数据开头会说明覆盖范围）。',
    '覆盖不完整时，请如实说明本次结论只基于已提供的楼层，不要推断未提供楼层的内容。',
    '',
    '分析要点：',
    '1. 主题概述：这个帖子在讨论什么，楼主提出了什么',
    '2. 讨论脉络：讨论如何演进，出现了哪些分支话题',
    '3. 主要观点与分歧：各楼层的主要立场、共识与争议点',
    '4. 关键信息：值得记下的事实、数据、结论或资源',
    '5. 整体氛围：讨论氛围与倾向（如有明显特征）',
    '6. 一句话总结：用一句话概括整帖'
  ].join('\n'),
  [AiScenario.USER_ANALYSIS]: [
    '你是一个论坛用户行为分析专家。请根据用户提供的论坛活跃数据，分析并总结以下内容：',
    '',
    '1. 用户画像：推断该用户的身份、兴趣领域、在论坛中的角色',
    '2. 政治光谱：根据其讨论话题和立场倾向，判断其政治倾向',
    '3. 整体点评：以辛辣尖锐的语言风格对其用户画像进行一句话锐评'
  ].join('\n'),
  [AiScenario.WATER_RULE_GEN]: [
    '你是一个中文论坛灌水回复过滤器。用户会给你一个论坛帖子的标题和主楼正文，请据此推断这个帖子下哪些回复属于「不提供任何信息的灌水」，并输出一组过滤规则。',
    '',
    '输出要求（必须严格遵守）：',
    '1. 只输出一个 JSON 对象，不要输出任何解释文字，不要用 markdown 代码块包裹。',
    '2. 格式固定为：{"rules":[{"type":"contain","value":"示例词"},{"type":"max-length","value":"3"}]}',
    '3. type 只能是三种之一：',
    '   - contain：回复正文包含 value 就判为灌水，适合这个帖子里反复出现的口头禅、无意义应和；',
    '   - equals：回复正文完全等于 value 才判为灌水，适合明确的灌水标记词；',
    '   - max-length：value 是 1~500 的整数，表示回复正文不超过这么多字就判为灌水。',
    '4. value 必须是最短的关键词，一般 2~6 个字；不要带标点，不要写整句话。',
    '5. 最多 12 条。宁缺勿滥：只为这个帖子确实会出现的灌水表达写规则。',
    '6. 不要写通用灌水词：「mark」「插眼」「马克」「谢谢分享」「哈哈」这类常见灌水已由应用内置词表覆盖，你只需补充与本帖主题相关的。',
    '7. 严禁写会误伤正常讨论的词，尤其禁止 contain 规则使用单字（如「图」「求」「问」「顶」「好」）——它们会命中大量正经回复。宁可少给，不可误伤。',
    '8. 判定时引用的内容不计入正文长度，所以针对「引用 + 一句短评」的楼层，请用 contain 而不是 max-length。',
    '9. 如果从这个帖子看不出特有的灌水表达，就输出 {"rules":[]}。'
  ].join('\n')
}

/** 注入数据字段说明项。 */
export interface InjectedFieldInfo {
  /** 字段展示标签 */
  label: string
  /** 字段占位示例 */
  example: string
}

/**
 * 各场景注入数据字段说明。
 *
 * 仅供 UI 预览展示使用，字段不可编辑。
 * 展示给用户让其感知每次请求会注入哪些数据。
 */
export const SCENARIO_INJECTED_FIELDS: Record<string, InjectedFieldInfo[]> = {
  [AiScenario.POST_SUMMARY]: [
    { label: '帖子标题', example: '原标题文本' },
    { label: '楼层', example: '#1' },
    { label: '作者', example: '用户名' },
    { label: '正文内容', example: '帖子的纯文本内容' }
  ],
  [AiScenario.THREAD_SUMMARY]: [
    { label: '帖子标题', example: '原标题文本' },
    { label: '覆盖范围', example: '总页数、实际纳入的楼层数与截断说明' },
    { label: '楼层内容', example: '#1 作者名：该楼层的纯文本内容（按楼号顺序拼接）' }
  ],
  [AiScenario.USER_ANALYSIS]: [
    { label: '用户名', example: '用户昵称' },
    { label: 'UID', example: '12345678' },
    { label: '帖子数', example: '12 个帖子' },
    { label: '回复数', example: '45 条回复' },
    { label: '活跃版面', example: '水区、游戏区、数码区等' },
    { label: '发帖时段分布', example: '凌晨 3 帖 / 上午 8 帖 / 下午 15 帖 / 晚上 19 帖' },
    { label: '发表的帖子', example: '前若干条帖子标题列表' },
    { label: '回复内容', example: '前若干条回复片段' }
  ],
  [AiScenario.WATER_RULE_GEN]: [
    { label: '帖子标题', example: '原标题文本' },
    { label: '主楼正文', example: '楼主开帖内容的纯文本（超长时截断）' },
    { label: '预期输出', example: '{"rules":[{"type":"contain","value":"示例词"}]}' }
  ]
}
