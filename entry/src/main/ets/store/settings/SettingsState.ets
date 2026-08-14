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
  theme: string = 'light'
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
  enableImageSizePrefetch: boolean = true
  threadNavMode: string = ThreadNavMode.SEAMLESS
  /** 预加载页数（0=关闭，1~5=向前预加载 N 页） */
  prefetchPageCount: number = 3
  /** 视频默认是否静音（全局开关，false=有声） */
  videoMuted: boolean = false
  /** 没有可用 App Linking 应用时，是否在应用内 WebView 打开 URL */
  useInternalWebView: boolean = true
  /** 调试模式（控制帖子更多菜单中的 HTML 模式请求等调试入口显示） */
  debugMode: boolean = false
  /** 自定义 AI 提供方配置列表 */
  aiProfiles: AiProviderProfile[] = []
  /** 当前激活的自定义 AI 配置 ID */
  activeAiProfileId: string = ''
  /** 各场景自定义 system prompt（key=场景ID, value=用户自定义文本） */
  scenarioSystemPrompts: Record<string, string> = {}
}
