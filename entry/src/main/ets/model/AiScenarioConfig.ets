/**
 * AI 场景与 System Prompt 配置数据模型。
 *
 * 定义两个内置 AI 场景（帖子内容总结、用户成分分析）的枚举、
 * 元数据、默认 system prompt 以及注入数据字段说明。
 */

/**
 * AI 场景枚举。
 *
 * 用于标识不同的 AI 功能场景，
 * 每个场景拥有独立的 system prompt 和注入数据。
 */
export enum AiScenario {
  /** 帖子内容总结 */
  POST_SUMMARY = 'post_summary',
  /** 用户成分分析 */
  USER_ANALYSIS = 'user_analysis'
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
    desc: '控制 AI 如何分析和总结帖子正文内容'
  },
  [AiScenario.USER_ANALYSIS]: {
    name: '用户成分分析',
    desc: '控制 AI 如何分析论坛用户的行为和倾向'
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
  [AiScenario.USER_ANALYSIS]: [
    '你是一个论坛用户行为分析专家。请根据用户提供的论坛活跃数据，分析并总结以下内容：',
    '',
    '1. 用户画像：推断该用户的身份、兴趣领域、在论坛中的角色',
    '2. 政治光谱：根据其讨论话题和立场倾向，判断其政治倾向',
    '3. 整体点评：以辛辣尖锐的语言风格对其用户画像进行一句话锐评'
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
  [AiScenario.USER_ANALYSIS]: [
    { label: '用户名', example: '用户昵称' },
    { label: 'UID', example: '12345678' },
    { label: '帖子数', example: '12 个帖子' },
    { label: '回复数', example: '45 条回复' },
    { label: '活跃版面', example: '水区、游戏区、数码区等' },
    { label: '发帖时段分布', example: '凌晨 3 帖 / 上午 8 帖 / 下午 15 帖 / 晚上 19 帖' },
    { label: '发表的帖子', example: '前若干条帖子标题列表' },
    { label: '回复内容', example: '前若干条回复片段' }
  ]
}
