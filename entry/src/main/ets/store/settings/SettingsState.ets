import { ImageLoadStrategy, ThreadNavMode } from '../../common/constants/Constants'
import { FavBoard } from '../../model/SocialEntries'
import type { BlacklistEntry } from '../../model/SocialEntries'
import { FilterKeyword } from '../../model/FilterKeyword'
import type { UserNoteEntry } from '../../model/NoteInfo'
import type { AiProviderProfile } from '../../model/AiConfig'


/**
 * 用户设置持久化根状态。
 *
 * 设置字段由各域子 store 通过共享引用直接读写，保持 @Observed 响应式不断。
 */
@Observed
export class SettingsState {
  blacklist: BlacklistEntry[] = []
  filterKeywords: FilterKeyword[] = []
  favorites: FavBoard[] = []
  fontSize: number = 15
  topicFontSize: number = 15
  domainIndex: number = 0
  autoCheckin: boolean = false
  lastCheckinDate: string = ''
  notes: UserNoteEntry[] = []
  holdingHand: number = 2
  smartGrip: boolean = true
  showSignature: boolean = true
  ttsPerson: number = 13
  ttsSpeed: number = 1.0
  ttsVolume: number = 1.0
  ttsPitch: number = 1.0
  imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /**
   * 显示帖子预览图（主题列表卡片的首帖附件缩略图）。
   *
   * 默认关闭：升级后列表视觉与流量不变，由用户显式开启；生效仍受 `imageLoadStrategy`
   * 约束（手动 / 非 WiFi 的"仅 WiFi"模式下只显示占位）。
   * 设计见 docs/TOPIC_PREVIEW_DESIGN.md §8。
   */
  showTopicPreview: boolean = false
  threadNavMode: string = ThreadNavMode.SEAMLESS
  /** 预加载页数（0=关闭，1~5=向前预加载 N 页） */
  prefetchPageCount: number = 3
  /** 记录帖子阅读进度：开启后保存最近阅读位置，下次进入帖子时自动恢复 */
  recordReadingProgress: boolean = true
  /** 视频默认是否静音（全局开关，false=有声） */
  videoMuted: boolean = false
  /** 没有可用 App Linking 应用时，是否在应用内 WebView 打开 URL */
  useInternalWebView: boolean = true
  /** 调试模式（控制额外诊断信息输出）。 */
  debugMode: boolean = false
  /** 自定义 AI 提供方配置列表 */
  aiProfiles: AiProviderProfile[] = []
  /** 当前激活的自定义 AI 配置 ID */
  activeAiProfileId: string = ''
  /** 各场景自定义 system prompt（key=场景ID, value=用户自定义文本） */
  scenarioSystemPrompts: Record<string, string> = {}
}
