/**
 * 颜色和常量定义
 *
 * 使用 HarmonyOS 资源限定词实现亮/暗色切换：
 * - base/element/color.json → 亮色（原味主题）
 * - dark/element/color.json  → 暗色主题
 * - AppColors 通过 $r 引用资源，setColorMode 自动切换
 */

// 当前激活的主题色（通过 $r 引用资源，setColorMode 自动切换）
export class AppColors {
  static primary: Resource = $r('app.color.primary')
  static primaryLight: Resource = $r('app.color.primary_light')
  static destructive: Resource = $r('app.color.destructive')
  static warning: Resource = $r('app.color.warning')
  static success: Resource = $r('app.color.success')
  static bg: Resource = $r('app.color.bg')
  static bgSecondary: Resource = $r('app.color.bg_secondary')
  static bgTertiary: Resource = $r('app.color.bg_tertiary')
  static textPrimary: Resource = $r('app.color.text_primary')
  static textSecondary: Resource = $r('app.color.text_secondary')
  static textTertiary: Resource = $r('app.color.text_tertiary')
  static separator: Resource = $r('app.color.separator')
  static dividerStrong: Resource = $r('app.color.divider_strong')
  static white: Resource = $r('app.color.white')
  static black: Resource = $r('app.color.black')
  static overlay: Resource = $r('app.color.overlay')
  static overlayStrong: Resource = $r('app.color.overlay_strong')
  static shadow: Resource = $r('app.color.shadow')
  static shadowLight: Resource = $r('app.color.shadow_light')
  static toastBg: Resource = $r('app.color.toast_bg')
  static imageViewerBg: Resource = $r('app.color.image_viewer_bg')
  static imageViewerButtonBg: Resource = $r('app.color.image_viewer_button_bg')
  static frostGlass: Resource = $r('app.color.frost_glass')
  static frostGlassStrong: Resource = $r('app.color.frost_glass_strong')
  static warnBg: Resource = $r('app.color.warn_bg')
  static warnBorder: Resource = $r('app.color.warn_border')
  static warnText: Resource = $r('app.color.warn_text')
  static chevron: Resource = $r('app.color.chevron')
  static sheetIndicator: Resource = $r('app.color.sheet_indicator')
  static quoteBorders: Resource[] = [
    $r('app.color.quote_border_1'),
    $r('app.color.quote_border_2'),
    $r('app.color.quote_border_3'),
  ]
}

// 主题元数据（预览色块用字符串色值，不随主题变化）
export interface ThemeOption {
  name: string
  label: string
  primaryColor: string
  bgColor: string
  textColor: string
}

export const THEME_OPTIONS: ThemeOption[] = [
  { name: 'system', label: '跟随系统', primaryColor: '#8E8E93', bgColor: '#FFFFFF', textColor: '#000000' },
  { name: 'light', label: '原味主题', primaryColor: '#C08A4A', bgColor: '#FEFAF6', textColor: '#3E2A1D' },
  { name: 'dark', label: '暗色主题', primaryColor: '#D4A85A', bgColor: '#1A1A1E', textColor: '#EAE2D8' },
]

// 品牌图标背景色（不随主题变化）
export class IconColors {
  static readonly mail: string = '#007AFF'
  static readonly bell: string = '#FF3B30'
  static readonly star: string = '#FF9500'
  static readonly clock: string = '#8E8E93'
  static readonly checkin: string = '#34C759'
  static readonly settings: string = '#5856D6'
  static readonly moon: string = '#5856D6'
  static readonly textFields: string = '#FF2D55'
  static readonly globe: string = '#5AC8FA'
  static readonly block: string = '#8E8E93'
  static readonly hand: string = '#FF9500'
  static readonly signature: string = '#5AC8FA'
  static readonly ai: string = '#6366F1'
}

/**
 * 设置中心专用图标色板。
 *
 * 同一功能分组使用相邻色相，并为危险操作保留独立的警示色。
 */
export class SettingsIconColors {
  /** 黑名单管理的中性石板色。 */
  static readonly blacklist: string = '#64748B'
  /** 用户备注的柔和玫红色。 */
  static readonly userNotes: string = '#DB2777'
  /** 关键词屏蔽的警示橙色。 */
  static readonly keywordFilter: string = '#D97706'
  /** 自动签到的成功绿色。 */
  static readonly autoCheckin: string = '#16A34A'
  /** AI 配置的智能紫色。 */
  static readonly aiConfig: string = '#7C3AED'
  /** 智感握姿的感知靛蓝色。 */
  static readonly smartGrip: string = '#4F46E5'
  /** 语音朗读的清晰天蓝色。 */
  static readonly tts: string = '#0284C7'
  /** 显示签名的书写青绿色。 */
  static readonly signature: string = '#0D9488'
  /** 图片加载模式的媒体蓝色。 */
  static readonly imageLoading: string = '#3B82F6'
  /** 图片尺寸预取的信息青色。 */
  static readonly imagePrefetch: string = '#0891B2'
  /** 字体大小的排版紫红色。 */
  static readonly fontSize: string = '#A21CAF'
  /** 帖子楼层导航的路径橙色。 */
  static readonly threadNavigation: string = '#EA580C'
  /** 页面预加载的效率绿色。 */
  static readonly pagePrefetch: string = '#059669'
  /** 内置网页浏览的浏览器蓝色。 */
  static readonly internalBrowser: string = '#1D4ED8'
  /** 账号凭证导出的安全青色。 */
  static readonly credentialExport: string = '#0F766E'
  /** 清除缓存的维护琥珀色。 */
  static readonly clearCache: string = '#B45309'
}

/**
 * 个人主页操作列表专用图标色板。
 *
 * 按消息、提醒、内容、记录、签到和设置六类语义建立稳定配色。
 */
export class ProfileActionIconColors {
  /** 私信入口的通信蓝色。 */
  static readonly messages: string = '#2563EB'
  /** 通知入口的提醒红色。 */
  static readonly notifications: string = '#DC2626'
  /** 收藏主题的暖金色。 */
  static readonly favorites: string = '#D97706'
  /** 浏览历史的中性深灰色。 */
  static readonly history: string = '#475569'
  /** 每日签到的成功绿色。 */
  static readonly checkin: string = '#16A34A'
  /** 设置入口的中心紫色。 */
  static readonly settings: string = '#6D28D9'
}

// 字号选项
export interface FontOption {
  label: string
  value: number
}

export const FONT_OPTIONS: FontOption[] = [
  { label: '小', value: 13 },
  { label: '中', value: 15 },
  { label: '大', value: 17 },
  { label: '特大', value: 19 },
]

// 域名选项
export interface DomainOption {
  label: string
  value: number
}

export const DOMAIN_OPTIONS: DomainOption[] = [
  { label: 'bbs.nga.cn', value: 0 },
  { label: 'ngabbs.com', value: 1 },
  { label: 'nga.178.com', value: 2 },
]

// 标题字体颜色映射
export const FONT_COLORS: Record<number, string> = {
  1: '#FF3B30',  // red
  2: '#C08A4A',  // gold
  4: '#34C759',  // green
  8: '#FF9500',  // orange
  16: '#8E8E93', // gray
}

// ============== 图片加载策略 ==============

export class ImageLoadStrategy {
  /** 始终加载（主动式） */
  static readonly ALWAYS: string = '0'
  /** 手动加载（被动式） */
  static readonly MANUAL: string = '1'
  /** 仅在 WiFi 下加载 */
  static readonly WIFI_ONLY: string = '2'
}

// ============== 帖子楼层导航模式 ==============

export class ThreadNavMode {
  /** 无缝加载（滚动到底自动加载下一页） */
  static readonly SEAMLESS: string = '0'
  /** 传统翻页（通过页面跳转器切换） */
  static readonly PAGE: string = '1'
}

// 排序模式
export interface SortMode {
  key: string
  label: string
}

export const SORT_MODES: SortMode[] = [
  { key: 'latest', label: '最新' },
  { key: 'recommend', label: '推荐' },
  { key: 'hot', label: '24h热门' },
]

// ============== 响应式断点 ==============

export class BreakpointConstants {
  static readonly BREAKPOINT_SM: string = 'sm'
  static readonly BREAKPOINT_MD: string = 'md'
  static readonly BREAKPOINT_LG: string = 'lg'
  static readonly CURRENT_BREAKPOINT: string = 'currentBreakpoint'
}

// 断点值工具类，根据当前断点返回不同值
export class BreakpointType<T> {
  readonly sm: T
  readonly md: T
  readonly lg: T

  constructor(sm: T, md: T, lg: T) {
    this.sm = sm
    this.md = md
    this.lg = lg
  }

  getValue(breakpoint: string): T {
    if (breakpoint === 'md') {
      return this.md
    }
    if (breakpoint === 'lg') {
      return this.lg
    }
    return this.sm
  }
}

// 通知类型映射
export interface NotiTypeInfo {
  label: string
  category: string // 'thread' | 'message'
}

export const NOTI_TYPE_MAP: Record<number, NotiTypeInfo> = {
  1: { label: '回复了你的主题', category: 'thread' },
  2: { label: '回复了你的回复', category: 'thread' },
  3: { label: '评论了你的主题', category: 'thread' },
  4: { label: '评论了你的回复', category: 'thread' },
  7: { label: '在主题中提到了你', category: 'thread' },
  8: { label: '在回复中提到了你', category: 'thread' },
  10: { label: '发起了新的对话', category: 'message' },
  11: { label: '回复了对话', category: 'message' },
  12: { label: '邀请了新用户加入对话', category: 'message' },
  15: { label: '评价了你的发言', category: 'thread' },
  17: { label: '获得了支持或反对', category: 'thread' },
}

export function getNotiIcon(type: number): Resource {
  const map: Record<number, Resource> = {
    1: $r('app.media.icon_chat_bubble'),
    2: $r('app.media.icon_chat_bubble'),
    3: $r('app.media.icon_chat_bubble'),
    4: $r('app.media.icon_chat_bubble'),
    7: $r('app.media.icon_at'),
    8: $r('app.media.icon_at'),
    10: $r('app.media.icon_mail'),
    11: $r('app.media.icon_mail'),
    12: $r('app.media.icon_mail'),
    15: $r('app.media.icon_thumb_up'),
  }
  return map[type] || $r('app.media.icon_clipboard')
}
