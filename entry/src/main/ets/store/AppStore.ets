import { Context } from '@kit.AbilityKit'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { AuthStore } from './AuthStore'
import { SettingsStore } from './SettingsStore'
import { CategoryStore } from './CategoryStore'
import { ProfileStore } from './ProfileStore'
import { NotificationStore } from './NotificationStore'
import { FollowActivityStore } from './FollowActivityStore'
import { VoteStore } from './VoteStore'
import { HistoryStore } from './HistoryStore'
import { FavoriteStore } from './FavoriteStore'
import { SavedThreadStore } from './SavedThreadStore'
import { TrackedThreadStore, TrackRequest, TrackResult } from './TrackedThreadStore'
import { draftStore, DRAFT_RETENTION_DAYS } from '../common/managers/DraftStore'
import {
  draftMediaStore,
  DRAFT_MEDIA_MAX_BYTES,
  DraftMediaClaim,
  DraftMediaCleanupResult
} from '../common/media/DraftMediaStore'
import { ReadingProgressStore } from './ReadingProgressStore'
import { AiSessionStore } from './AiSessionStore'
import { AiToolCacheStore } from './AiToolCacheStore'
import { floatingLayerStore } from './FloatingLayerStore'
import { SessionGuard, sessionGuard as globalSessionGuard } from './SessionGuard'
import { setAuthFailureHandler, setWriteGuard } from '../service/NgaClient'
import { ToastManager } from '../common/feedback/ToastManager'
import { CredentialState } from './AuthStore'
import { KEY_CREDENTIAL_DEGRADED } from '../common/constants/AppStorageKeys'

import type { AuthState } from './AuthStore'
import type { Session } from './SessionRegistry'
import { routerStore } from './RouterStore'
import type { SettingsState } from './settings/SettingsState'
import type { BrowseHistoryEntry } from './HistoryStore'
import type { ReadingProgressEntry } from './ReadingProgressStore'
import type { ToastState } from '../common/feedback/ToastManager'
import type { ProfileData } from '../model/User'
import type { ThreadResult } from '../model/ThreadResult'
import type { AiSession } from '../model/AiSession'
import type { NgaNotification } from '../model/Notification'
import type { FollowedActivity } from '../model/Follow'
import type { TrackedThread, TrackStopNotice } from '../model/TrackedThread'
import { formatTrackStopNotice } from '../common/utils/ThreadTrackPolicy'
import type { Category } from '../model/Forum'

import { Logger, DOMAIN_APP, formatError } from '../common/utils/Logger'
import { shouldEnablePolling } from '../common/concurrency/PollingController'

/**
 * 前台轮询参与者（注册表项）：一对启停回调。
 * 由 AppStore 统一登记社交类 Store 的前台轮询启停。
 */
class PollingParticipant {
  readonly start: () => void
  readonly stop: () => void

  constructor(start: () => void, stop: () => void) {
    this.start = start
    this.stop = stop
  }
}

const logger = new Logger(DOMAIN_APP, 'AppStore')

/**
 * 草稿清理的启动延迟（ms）。
 *
 * 让出启动的前几帧：清理是纯维护动作，晚几百毫秒做完全不影响用户（草稿要 7 天才超期）。
 */
const DRAFT_CLEANUP_DELAY_MS: number = 800

/** 每批检查的草稿文件数（分批推进，避免一次性 statSync 大量文件阻塞主线程）。 */
const DRAFT_CLEANUP_BATCH: number = 8

/**
 * 单次启动最多推进的清理批数。
 *
 * 兜底上限：目录被异常路径撑到极大量时（例如反复写坏文件），也不让它无限占用主线程——
 * 剩下的留给下次启动继续消化。**游标在批次之间保留**（见 `DraftStore.cleanupStale`），
 * 所以"这次没跑完"不会像早先那样每批重复检查同一批文件。
 */
const DRAFT_CLEANUP_MAX_ROUNDS: number = 4

/**
 * 降级后自动复验的退避序列（ms）。
 *
 * 为什么不是"只探一次"：降级是"服务端暂时不认"，而 NGA 的异常通常以分钟计。若只探一次，
 * 用户在降级期间一直前台读帖时，**不存在任何自动触发点** —— 读请求成功不产生"未登录"
 * 信号，写操作被本地门禁拦下更不会产生（门禁直接返回、不经过网络层）。服务端早已恢复，
 * 横幅却会一直挂着，直到用户手动点「重试」或切后台再回来。
 *
 * 退避的意义：短时抖动靠前两次（3s / 15s）快速自愈；真失效时慢慢降频到 1 分钟一次，
 * 不会对服务端形成轮询压力。每次成功后由 `clearCredentialDegraded` 取消后续探针。
 */
const CREDENTIAL_RECHECK_DELAYS_MS: number[] = [3000, 15000, 30000, 60000]

/**
 * AppStore — 全局状态管理 Facade
 *
 * 各领域职责已拆分到独立 Store，AppStore 只做编排和委托。
 */
class AppStoreClass {
  // ---------- Infrastructure ----------
  private store: PreferencesStore = new PreferencesStore()
  private writeQueue: SerialQueue = new SerialQueue()
  private context?: Context
  /** AppStore 及用户相关 Store 是否完成初始化。 */
  private initialized: boolean = false
  /** AppStore 初始化流程是否已经结束。 */
  private initializationFinished: boolean = false
  /** Ability 当前是否处于前台。 */
  private foregroundActive: boolean = false
  /** 前台轮询参与者注册表（新增轮询 Store 时在此登记即可统一启停）。 */
  private pollingParticipants: PollingParticipant[] = []
  /** 草稿清理链是否在跑（`init` 可能被重入，见 `initDraftCleanup`）。 */
  private draftCleanupRunning: boolean = false
  /** 降级后的自动复验定时器（-1 = 无待执行）。 */
  private credentialRecheckTimer: number = -1
  /** 已排过的复验轮次（决定下一次的退避档位）。 */
  private credentialRecheckAttempt: number = 0

  constructor() {
    this.pollingParticipants = [
      new PollingParticipant(
        (): void => { this.notificationStore.startPolling() },
        (): void => { this.notificationStore.stopPolling() }
      ),
      new PollingParticipant(
        (): void => { this.followActivityStore.startPolling() },
        (): void => { this.followActivityStore.stopPolling() }
      ),
      new PollingParticipant(
        (): void => { this.trackedThreadStore.startPolling() },
        (): void => { this.trackedThreadStore.stopPolling() }
      )
    ]
    // 帖子失效 / 长期无新回复导致的自动停止跟踪统一在这里提示（用户主动移除不提示）
    this.trackedThreadStore.onStopNotice = (notice: TrackStopNotice): void => {
      const message: string = formatTrackStopNotice(notice)
      if (message.length > 0) {
        this.showToast(message)
      }
    }
  }

  // ---------- Sub Stores ----------
  readonly authStore: AuthStore = new AuthStore()
  readonly settingsStore: SettingsStore = new SettingsStore()
  readonly categoryStore: CategoryStore = new CategoryStore()
  readonly profileStore: ProfileStore = new ProfileStore()
  readonly notificationStore: NotificationStore = new NotificationStore()
  /** 关注动态缓存、已读与红点管理（机制与通知系统对齐）。 */
  readonly followActivityStore: FollowActivityStore = new FollowActivityStore()
  readonly voteStore: VoteStore = new VoteStore()
  readonly historyStore: HistoryStore = new HistoryStore()
  /** NGA 主题收藏夹与收藏关系状态。 */
  readonly favoriteStore: FavoriteStore = new FavoriteStore()
  /** 保存的帖子离线存档（文件系统持久化，不按账号区分）。 */
  readonly savedThreadStore: SavedThreadStore = new SavedThreadStore()
  /** 跟踪帖子更新（按账号隔离的本地跟踪任务 + 前台定时检查）。 */
  readonly trackedThreadStore: TrackedThreadStore = new TrackedThreadStore()
  /** 帖子阅读进度（按账号隔离，用于下次进入时恢复阅读位置）。 */
  readonly readingProgressStore: ReadingProgressStore = new ReadingProgressStore()
  /** AI 对话会话（按账号隔离，提供跨页面/跨启动的对话记忆）。 */
  readonly aiSessionStore: AiSessionStore = new AiSessionStore()
  /** AI 工具结果缓存（按账号隔离，跨启动复用读帖 / 资料 / 搜索结果）。 */
  readonly aiToolCacheStore: AiToolCacheStore = new AiToolCacheStore()
  readonly toastManager: ToastManager = new ToastManager()

  // ============== Init & Lifecycle ==============

  async init(context: Context): Promise<void> {
    this.initialized = false
    this.initializationFinished = false
    this.stopAllPolling()
    this.bindSessionGuard()
    try {
      this.context = context
      await this.store.init(context, 'nga_app_store')

      // 存档与登录态无关，随应用启动即初始化（不按账号区分）
      await this.savedThreadStore.init(context)

      // 编辑器草稿与草稿媒体副本（键内已含 uid 哈希，目录本身不按账号分）
      await draftStore.init(context)
      await draftMediaStore.init(context)
      // 超期/超容量清理**延后**到启动主流程之外：它要逐文件 statSync（主线程同步 IO），
      // 放在这里会拖慢冷启动。`initDraftCleanup` 用 setTimeout 让出当前帧并分批推进。
      this.initDraftCleanup()

      // 子 Store 中不依赖 uid 的先初始化（同步赋值引用）
      await this.voteStore.init(this.store, this.writeQueue)
      await this.historyStore.init(this.store, this.writeQueue)
      await this.readingProgressStore.init(this.store, this.writeQueue)

      // 认证 + 分类（部分依赖 uid）
      await this.authStore.init(this.store, this.writeQueue)
      await this.categoryStore.init(this.store, this.writeQueue, this.authStore.state)

      // 主题为全局设置（不随 uid 隔离）：无论登录与否都加载持久化主题，
      // 保证未登录用户冷启动后主题/状态栏样式正确（见 docs/THEME_DESIGN.md）
      await this.settingsStore.initTheme(this.store, this.writeQueue, this.context)

      // 用户数据（依赖 uid）
      if (this.authStore.state.uid) {
        await this.loadUserData()
      }
      this.settingsStore.applyCurrentTheme()
      this.initialized = true
      this.reconcilePolling()

      logger.info('AppStore initialized')
    } catch (e) {
      logger.error('AppStore init failed: %{public}s', formatError(e))
      throw new Error(formatError(e))
    } finally {
      this.initializationFinished = true
    }
  }

  /** 返回 AppStore 及全部用户 Store 是否完成初始化。 */
  get isInitialized(): boolean {
    return this.initialized
  }

  /**
   * 启动后的草稿清理（分批、延后）。
   *
   * 两件事：① 删掉超过**保留期**的草稿 JSON；② 媒体副本按「孤儿即时回收 + 有主豁免」淘汰
   * （草稿先清、媒体后清，这样被清掉草稿的那些媒体目录正好成为孤儿一并回收）。
   *
   * 分批的粒度是 `DRAFT_CLEANUP_BATCH`（草稿文件数），每批之间用 `setTimeout(0)` 让出主线程：
   * 正常情况下草稿只有 0 到几个、第一批就结束；只有目录被异常路径撑大时才会连续跑几批。
   * **媒体清理只在最后一批之后跑一次**：它要遍历 `draft_media` 下每个键目录的每个文件，
   * 逐批重复调用会把同一棵树扫很多遍。
   *
   * 重入守卫：`init` 在账号切换 / 前后台切换路径上可能被再次调用，没有守卫就会同时存在两条
   * 清理链（各自计轮次、各自 statSync 同一批文件）。守卫在链条真正结束时释放
   * （用 `finally` 兜住任何意外异常，否则一次抛错会让后续启动的清理永久静默跳过）。
   *
   * 清理失败不抛错——它是后台维护动作，不该影响应用可用性。
   */
  private initDraftCleanup(): void {
    if (this.draftCleanupRunning) {
      logger.verbose('draft cleanup already running, skip')
      return
    }
    this.draftCleanupRunning = true
    let rounds: number = 0
    const runBatch: () => void = (): void => {
      let keepRunning: boolean = false
      try {
        rounds++
        const batch = draftStore.cleanupStale(DRAFT_RETENTION_DAYS, DRAFT_CLEANUP_BATCH)
        if (batch.hasMore && rounds < DRAFT_CLEANUP_MAX_ROUNDS) {
          keepRunning = true
          setTimeout(runBatch, 0)
          return
        }
        this.cleanupDraftMedia()
      } catch (e) {
        logger.warn('draft cleanup batch failed: %{public}s', formatError(e))
      } finally {
        // 只有链条真正结束才释放守卫：`setTimeout` 排下一批时保持持有
        if (!keepRunning) {
          this.draftCleanupRunning = false
        }
      }
    }
    setTimeout(runBatch, DRAFT_CLEANUP_DELAY_MS)
  }

  /**
   * 媒体副本清理（草稿批次跑完之后调用一次）。
   *
   * 归属判定用 `DraftMediaClaim`：**实时**确认草稿文件是否还在（`hasDraftFile`），
   * 并附带启动快照与当前活跃会话键两个兜底判据。这样"清理开始后 800ms 内用户新存的草稿"
   * 也不会被当成孤儿删掉（A7 的第二道防线）。
   */
  private cleanupDraftMedia(): void {
    const claim: DraftMediaClaim = new DraftMediaClaim()
    claim.liveKeys = draftStore.listKeys()
    claim.activeKeys = draftStore.activeKeyList()
    claim.isClaimed = (key: string): boolean => draftStore.hasDraftFile(key)
    const result: DraftMediaCleanupResult = draftMediaStore.cleanupStale(claim, DRAFT_MEDIA_MAX_BYTES)
    if (result.overLimit) {
      logger.warn('draft media still over %{public}d bytes after orphan reclaim ' +
        '(claimed dirs=%{public}d kept)', DRAFT_MEDIA_MAX_BYTES, result.protectedCount)
    }
  }

  /** 返回 AppStore 初始化流程是否已经成功或失败地结束。 */
  get isInitializationFinished(): boolean {
    return this.initializationFinished
  }

  /**
   * 绑定会话守卫的依赖与信号通道。
   *
   * 幂等：`init` 可能被重入（账号切换/前后台路径），重复绑定覆盖同一组回调
   * （闭包捕获 `this`，始终读取当前 auth 状态）。
   */
  private bindSessionGuard(): void {
    globalSessionGuard.bindSessionResolver((): Session | null => this.getSession(this.auth.token))
    globalSessionGuard.bindDegradedHandler((reason: string): void => {
      this.markCredentialDegraded(reason)
    })
    globalSessionGuard.bindRecoveredHandler((): void => {
      this.clearCredentialDegraded()
    })
    setAuthFailureHandler((message: string): void => {
      // 网络层只上报；确认与处置都在 SessionGuard 内完成（60s 去抖 + 单飞 + iflogin 复核 +
      // 静默复验），避免单个业务错误（如 code=1 的"未定义服务"）把用户踢下线。
      globalSessionGuard.onUnauthorizedSignal(message).catch((): void => {})
    })
    setWriteGuard((): string | null => {
      // 写操作本地门禁：未登录 / 降级态一律不发写请求。
      // 读请求故意不拦 —— NGA 各接口的会话校验强度不一致，服务端异常期间读能力可能仍然可用，
      // 由服务端自己回答；写操作失败会留下副作用，必须先本地兜住。
      if (!this.auth.isAuthenticated) {
        return '请先登录后再操作'
      }
      if (this.auth.credentialState === CredentialState.DEGRADED) {
        // 文案不绑定具体控件：横幅在 MainPage 底部，而用户很可能是在回复/发帖编辑器
        // （半模态或全屏浮层）里撞到这条拦截，那里看不到横幅
        return '登录状态异常，发帖回复等操作已暂停，可稍后重试或回到主界面重新登录'
      }
      return null
    })
  }

  // ============== 凭证降级态 ==============

  /**
   * 把凭证标记为降级态：服务端明确拒绝，但**本地凭证与全部 Store 原样保留**。
   *
   * 这是本方案的核心取舍。现状是"确认失效 → `clearAuth()` → 清空 15 个数据域 + 跳登录页"，
   * 而实测 NGA 各接口的会话校验强度并不一致（`read.php` 弱于 `nuke.php`）：服务端局部异常
   * 期间完全可能「帖子能读、iflogin 报失效」。用最严格接口的结论清空一切，会把用户的浏览
   * 位置、已加载内容、草稿上下文一并抹掉，而这份凭证往往下一秒就又能用了。
   *
   * 降级只做两件事：① 把状态同步给 UI（顶部横幅 + 写操作门禁）；② 安排一次延迟自动复验。
   * **不清态、不清 Store、不导航** —— 这三件事只在用户主动退出登录时发生。
   *
   * @param reason - 诊断文案（写入日志，不直接展示给用户）
   */
  markCredentialDegraded(reason: string): void {
    if (!this.auth.isAuthenticated) {
      // 真未登录（本地无凭证）：降级没有对象，交给登录流程处理
      return
    }
    if (this.sessionGuard.isCredentialMismatched()) {
      /*
       * 凭证与账号错配：服务端把这个 cid 解析成了**另一个 uid**。
       *
       * 这与"服务端暂时不认这份凭证"性质不同，不能降级保留 —— 读接口一旦继续放行，
       * 私信 / 通知 / 收藏都会以别人的身份返回数据，显示在当前账号下。
       * 必须清态重登；调用方（启动页 / 主页面）据 `isAuthenticated` 变为 false 决定跳登录页。
       */
      logger.warn('凭证与账号错配，清登录态：%{public}s', reason)
      this.clearAuthAndFlush().catch((): void => {})
      this.showToast('登录凭证异常，请重新登录')
      return
    }
    if (this.auth.credentialState === CredentialState.DEGRADED) {
      // 已降级：确保探针仍在跑。探针在后台会被跳过，回到前台后靠这条路径重新拉起。
      this.scheduleCredentialRecheck()
      return
    }
    this.auth.credentialState = CredentialState.DEGRADED
    // 同步守卫内部的降级标志：它决定前台恢复探针的节流间隔（降级态 1 分钟 / 正常态 10 分钟）。
    // 启动页与主页面是直接调用本方法的（不经过守卫的 notifyDegraded），不同步会让恢复白白变慢。
    this.sessionGuard.markDegraded()
    this.publishCredentialState()
    logger.warn('凭证进入降级态（服务端拒绝，本地凭证保留）：%{public}s', reason)
    this.showToast('登录状态异常，发帖回复等操作已暂停')
    this.credentialRecheckAttempt = 0
    this.scheduleCredentialRecheck()
  }

  /**
   * 清除降级态（服务端重新认可当前凭证）。
   *
   * 由会话守卫在任意一次通过校验时回调，也由用户点横幅「重试」成功时触发。
   */
  clearCredentialDegraded(): void {
    if (this.auth.credentialState !== CredentialState.DEGRADED) {
      return
    }
    this.auth.credentialState = CredentialState.VALID
    this.publishCredentialState()
    logger.info('凭证已从降级态恢复')
    this.showToast('登录状态已恢复')
  }

  /**
   * 强制复验当前凭证（横幅「重试」）。
   *
   * 走 `SessionGuard.reverify()`：不复用旧结论，成功会经恢复回调自动清掉降级态。
   */
  async retryCredential(): Promise<void> {
    await this.sessionGuard.reverify()
  }

  /**
   * 把凭证状态同步到 AppStorage。
   *
   * 只维护**一个**键：横幅是唯一的消费方，`@StorageProp` 订阅它即可。
   * （不要额外维护一个"状态版本号"：没有订阅者的版本键只是看似有刷新信号的死代码。）
   */
  private publishCredentialState(): void {
    AppStorage.setOrCreate(KEY_CREDENTIAL_DEGRADED, this.auth.credentialState === CredentialState.DEGRADED)
  }

  /**
   * 降级后的自动复验（有界退避，见 `CREDENTIAL_RECHECK_DELAYS_MS`）。
   *
   * 三条约束：
   * - **幂等**：已有在途定时器时直接返回，不打断 —— 否则每次失效信号都会把倒计时清零，
   *   退避探针永远等不到触发；
   * - **只在前台跑**：后台不发请求（定时器可能被系统挂起，行为不确定），回到前台由
   *   `setForegroundActive` / `verifyOnForeground` 重新拉起；
   * - **成功后自停**：`clearCredentialDegraded` 会经 `resetCredentialState` 取消定时器。
   */
  private scheduleCredentialRecheck(): void {
    if (this.credentialRecheckTimer !== -1) {
      return
    }
    const attempt: number = this.credentialRecheckAttempt
    const index: number = Math.min(attempt, CREDENTIAL_RECHECK_DELAYS_MS.length - 1)
    this.credentialRecheckTimer = setTimeout((): void => {
      this.credentialRecheckTimer = -1
      if (!this.auth.isAuthenticated || this.auth.credentialState !== CredentialState.DEGRADED) {
        return
      }
      if (!this.foregroundActive) {
        // 后台不发：回到前台会重新拉起（见 setForegroundActive 与 markCredentialDegraded）
        return
      }
      this.credentialRecheckAttempt = attempt + 1
      this.sessionGuard.reverify().then((): void => {
        if (this.auth.credentialState === CredentialState.DEGRADED) {
          this.scheduleCredentialRecheck()
        }
      }).catch((): void => {
        if (this.auth.credentialState === CredentialState.DEGRADED) {
          this.scheduleCredentialRecheck()
        }
      })
    }, CREDENTIAL_RECHECK_DELAYS_MS[index])
  }

  /**
   * 重置凭证状态（新登录 / 退出登录时调用）：取消待执行的复验并清掉降级标记。
   *
   * **同时复位会话守卫**：守卫内部还留着一份 `degraded` 标志（决定前台探针的节流间隔）。
   * 不复位的话，退出登录后它仍是 true，登录页期间的前台探针会一直按 1 分钟空转，
   * 直到下一次 `setAuth` 才恢复 —— 双真源就必须在任何一处状态转换上同时改两边。
   *
   * **不弹 Toast**：退出登录时提示"已恢复"是噪音，新登录时横幅本就不该出现。
   */
  private resetCredentialState(): void {
    if (this.credentialRecheckTimer !== -1) {
      clearTimeout(this.credentialRecheckTimer)
      this.credentialRecheckTimer = -1
    }
    this.credentialRecheckAttempt = 0
    this.authStore.state.credentialState = CredentialState.VALID
    this.sessionGuard.resetForNewSession()
    AppStorage.setOrCreate(KEY_CREDENTIAL_DEGRADED, false)
  }

  /**
   * 清登录态并**等待落盘完成**（退出登录等用户主动动作必须用它）。
   *
   * `clearAuth()` 是同步方法，内部只把清态写入排进队列；进程在写入前被杀，
   * 磁盘上仍是旧的 auth/sessions，下次冷启动会把"用户主动退出"回滚成已登录。
   *
   * @returns 落盘完成时 resolve
   */
  async clearAuthAndFlush(): Promise<void> {
    this.clearAuth()
    await this.flushAll()
  }

  /** 会话守卫（启动页/主页面用于主动校验与前台恢复）。 */
  get sessionGuard(): SessionGuard {
    return globalSessionGuard
  }

  private async loadUserData(): Promise<void> {
    await this.settingsStore.init(this.store, this.writeQueue, this.authStore.state, this.context)
    await this.profileStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.notificationStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.followActivityStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.favoriteStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.trackedThreadStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.aiSessionStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.aiToolCacheStore.init(this.store, this.writeQueue, this.authStore.state)
    /* 浏览历史兼作主题列表的已读台账（看过 / 有更新标记的数据源），随用户数据一并预载：
       它是懒加载的，不在这里拉起的话列表会先按"全部没看过"渲染一遍再刷新（见 HistoryStore.preload） */
    await this.historyStore.preload(this.authStore.state.uid)
  }

  /** 后台时刷盘 */
  async flushAll(): Promise<void> {
    /* 工具缓存是节流写的：后台/退出前补一次，避免进程被杀丢掉最近 800ms 的命中结果 */
    this.aiToolCacheStore.flush()
    await this.writeQueue.enqueue(async (): Promise<void> => {})
    await this.store.flush()
  }

  // ---------- Facade: Auth ----------

  get auth(): AuthState {
    return this.authStore.state
  }

  async setAuth(token: string, uid: string, nickName: string, avatarUrl: string): Promise<void> {
    this.stopAllPolling()
    const uidChanged = await this.authStore.setAuth(token, uid, nickName, avatarUrl)
    if (uidChanged) {
      await this.loadUserData()
      this.settingsStore.applyCurrentTheme()
    }
    // 新会话：复位"未登录信号"去抖窗口与降级标记，避免登录后立刻失效被上一轮窗口吞掉，
    // 也避免上一个账号的降级结论跟到新账号上
    globalSessionGuard.resetForNewSession()
    this.resetCredentialState()
    this.reconcilePolling()
  }

  clearAuth(): void {
    this.stopAllPolling()
    // ⚠️ 以下顺序有严格依赖：cancel/reset 必须在 authStore.clearAuth() 之前，
    // 否则后者 enqueue 的 persistAuth 写入任务会被取消。
    // 先取消队列中所有待执行的任务（如已入队的 history/vote 旧 uid 写入）
    this.writeQueue.cancel()
    this.writeQueue.reset()
    // 再清空认证状态（会 enqueue 写入空 auth，此时 queue 已重置为干净状态）
    this.authStore.clearAuth()
    this.settingsStore.reset()
    this.categoryStore.reset()
    this.profileStore.reset()
    this.notificationStore.reset()
    this.followActivityStore.reset()
    this.voteStore.reset()
    this.historyStore.reset()
    this.readingProgressStore.reset()
    this.favoriteStore.reset()
    this.trackedThreadStore.reset()
    this.aiSessionStore.reset()
    this.aiToolCacheStore.reset()
    floatingLayerStore.clear()
    routerStore.reset()
    // 真未登录：降级态失去意义，顺带取消待执行的自动复验
    this.resetCredentialState()
    // 与 setAuth 对称：退出后统一协调轮询状态（此时未认证 → 停止轮询，幂等无害）
    this.reconcilePolling()
  }

  createSession(uid: string, cid: string, nickName: string, avatarUrl: string): Promise<string> {
    return this.authStore.createSession(uid, cid, nickName, avatarUrl)
  }

  getSession(token: string): Session | null {
    return this.authStore.getSession(token)
  }

  updateSession(token: string, nickName?: string, avatarUrl?: string): Promise<void> {
    return this.authStore.updateSession(token, nickName, avatarUrl)
  }

  destroySession(token: string): Promise<void> {
    return this.authStore.destroySession(token)
  }

  // ---------- Facade: Settings ----------

  get settings(): SettingsState {
    return this.settingsStore.state
  }

  /** 若自动签到实际成功，则显示全局成功提示。 */
  autoCheckinIfNeeded(): void {
    const requestUid: string = this.auth.uid
    this.settingsStore.autoCheckinIfNeeded().then((checked: boolean): void => {
      // 签到请求期间可能已退出或切换账号：身份不一致时不再提示
      if (checked && this.auth.uid === requestUid && this.auth.isAuthenticated) {
        this.showToast('自动签到成功')
      }
    }).catch((): void => {})
  }

  // ---------- Facade: Categories ----------

  get cachedCategories(): Category[] {
    return this.categoryStore.cachedCategories
  }

  get categoriesLoaded(): boolean {
    return this.categoryStore.categoriesLoaded
  }

  get categoriesError(): string {
    return this.categoryStore.categoriesError
  }

  ensureCategories(): void { this.categoryStore.ensureCategories() }

  // ---------- Facade: Profile ----------

  getCachedProfile(uid: string): ProfileData | null { return this.profileStore.getCachedProfile(uid) }
  ensureProfile(uid: string): void { this.profileStore.ensureProfile(uid) }
  invalidateProfile(uid: string): void { this.profileStore.invalidateProfile(uid) }

  // ---------- Facade: Notifications ----------

  get unreadNotiCount(): number {
    return this.notificationStore.unreadNotiCount
  }

  /** 返回未查看私信通知数量。 */
  get unreadMessageCount(): number {
    return this.notificationStore.unreadMessageCount
  }

  refreshUnreadCount(): Promise<void> { return this.notificationStore.refreshUnreadCount() }
  /** 刷新通知并返回请求是否成功。 */
  refreshNotifications(force: boolean = false): Promise<boolean> {
    return this.notificationStore.refreshNotifications(force)
  }
  /**
   * 更新 Ability 前台状态并统一协调社交轮询（消息 / 动态）。
   *
   * 降级态下额外拉起凭证探针：定时探针在后台会被跳过（见 `scheduleCredentialRecheck`），
   * 回到前台必须有个明确的重新拉起点，否则用户切回来后就再也不会自愈。
   *
   * @param active - Ability 是否处于前台
   */
  setForegroundActive(active: boolean): void {
    this.foregroundActive = active
    this.reconcilePolling()
    if (active && this.auth.credentialState === CredentialState.DEGRADED) {
      this.scheduleCredentialRecheck()
    }
  }
  /**
   * 根据初始化、认证与前台状态启动或停止全部前台轮询参与者。
   */
  private reconcilePolling(): void {
    if (shouldEnablePolling(
      this.foregroundActive,
      this.initialized,
      this.auth.isAuthenticated
    )) {
      this.startAllPolling()
      return
    }
    this.stopAllPolling()
  }

  /** 启动全部前台轮询参与者（幂等：各 Store 内部有启动守卫）。 */
  private startAllPolling(): void {
    for (let index: number = 0; index < this.pollingParticipants.length; index++) {
      this.pollingParticipants[index].start()
    }
  }

  /** 停止全部前台轮询参与者（幂等）。 */
  private stopAllPolling(): void {
    for (let index: number = 0; index < this.pollingParticipants.length; index++) {
      this.pollingParticipants[index].stop()
    }
  }
  getCachedNotifications(): NgaNotification[] { return this.notificationStore.getCachedNotifications() }
  /** 将指定通知标记为已查看。 */
  markNotificationSeen(notificationId: string): void { this.notificationStore.markSeen(notificationId) }
  /** 将全部非私信通知标记为已查看（消息 Tab 全部已读，不波及私信通知）。 */
  markNonMessageNotificationsSeen(): void { this.notificationStore.markNonMessageSeen() }
  /** 将私信通知标记为已查看。 */
  markMessageNotificationsSeen(): void { this.notificationStore.markMessagesSeen() }
  /** 将指定会话（mid）的私信通知标记为已查看（按可索引 ID 精确表达已读）。 */
  markMessageNotificationsSeenByMid(mid: string): void {
    this.notificationStore.markMessagesSeenByMid(mid)
  }
  /** 返回通知缓存中非私信通知的只读快照（消息 Tab 数据源）。 */
  getCachedNonMessageNotifications(): NgaNotification[] {
    return this.notificationStore.getCachedNonMessageNotifications()
  }

  // ---------- Facade: Follow Activities ----------

  /** 返回未读关注动态数量。 */
  get unreadActivityCount(): number {
    return this.followActivityStore.unreadActivityCount
  }

  /** 刷新关注动态并返回请求是否成功。 */
  refreshActivities(force: boolean = false): Promise<boolean> {
    return this.followActivityStore.refreshActivities(force)
  }
  /** 返回关注动态内存真源的只读数组快照（displayActivities 全量，含分页追加）。 */
  getDisplayActivities(): FollowedActivity[] {
    return this.followActivityStore.getDisplayActivities()
  }
  /** 返回关注动态缓存的只读数组快照（持久化窗口，兼容既有调用）。 */
  getCachedActivities(): FollowedActivity[] {
    return this.followActivityStore.getCachedActivities()
  }
  /** 加载关注动态下一页（store 内并发防护与账号代际校验）。 */
  loadMoreActivities(): Promise<boolean> {
    return this.followActivityStore.loadMoreActivities()
  }
  /** 返回关注动态服务端总页数（0=未知/未确认）。 */
  getActivityTotalPages(): number {
    return this.followActivityStore.getTotalPages()
  }
  /** 返回关注动态已加载页数（首屏=1）。 */
  getActivityLoadedPages(): number {
    return this.followActivityStore.getLoadedPages()
  }
  /** 返回关注动态分页是否加载中。 */
  getActivityLoadingMore(): boolean {
    return this.followActivityStore.isLoadingMoreState()
  }
  /** 将指定 id 集合的动态标记为已读（点开帖子即已读）。 */
  markActivitiesSeen(ids: Set<string>): void {
    this.followActivityStore.markSeenByIds(ids)
  }
  /** 将所有动态标记为已读。 */
  markAllActivitiesSeen(): void {
    this.followActivityStore.markAllSeen()
  }

  // ---------- Facade: Tracked Threads ----------

  /** 返回有未读更新的跟踪帖子数（「跟踪」Tab 角标与入口铃铛合并计数）。 */
  get unreadTrackCount(): number {
    return this.trackedThreadStore.unreadTrackCount
  }
  /** 返回跟踪任务快照（有未读的排前，其次按最后活动时间倒序）。 */
  getTrackedThreads(): TrackedThread[] {
    return this.trackedThreadStore.getItems()
  }
  /** 指定帖子是否正在跟踪。 */
  isThreadTracked(tid: string): boolean {
    return this.trackedThreadStore.isTracked(tid)
  }
  /** 取指定帖子的跟踪任务（未跟踪返回 null）。 */
  getTrackedThread(tid: string): TrackedThread | null {
    return this.trackedThreadStore.getByTid(tid)
  }
  /** 当前跟踪任务数是否已达上限。 */
  canTrackMoreThreads(): boolean {
    return this.trackedThreadStore.canTrackMore()
  }
  /** 新增或更新跟踪任务（已跟踪时只更新跟踪天数，不动已读基准）。 */
  trackThread(request: TrackRequest): Promise<TrackResult> {
    return this.trackedThreadStore.track(request)
  }
  /** 移除一个跟踪任务（用户主动移除，不提示）。 */
  untrackThread(tid: string): void {
    this.trackedThreadStore.untrack(tid)
  }
  /** 移除全部跟踪任务（用户主动移除，不提示）。 */
  untrackAllThreads(): void {
    this.trackedThreadStore.untrackAll()
  }
  /** 将指定跟踪任务标记为已读（返回是否命中未读）。 */
  markTrackedSeen(tid: string): boolean {
    return this.trackedThreadStore.markSeen(tid)
  }
  /** 将全部跟踪任务标记为已读（返回是否有变化）。 */
  markAllTrackedSeen(): boolean {
    return this.trackedThreadStore.markAllSeen()
  }
  /** 帖子页打开被跟踪的帖子时推进已读基准（先检查再置已读）。 */
  markTrackedSeenOnOpen(tid: string): Promise<void> {
    return this.trackedThreadStore.seenOnOpen(tid)
  }

  // ---------- Facade: Vote ----------

  loadVoteRecord(uid: string, tid: string): Promise<Set<string>[]> {
    return this.voteStore.loadVoteRecord(uid, tid)
  }
  saveVoteRecord(uid: string, tid: string, upPids: Set<string>, downPids: Set<string>): Promise<void> {
    return this.voteStore.saveVoteRecord(uid, tid, upPids, downPids)
  }
  removeVoteRecord(uid: string, tid: string): Promise<void> { return this.voteStore.removeVoteRecord(uid, tid) }
  clearVoteRecords(uid: string): Promise<void> { return this.voteStore.clearVoteRecords(uid) }
  loadPollVoted(uid: string): Promise<string[]> { return this.voteStore.loadPollVoted(uid) }
  markPollVoted(uid: string, tid: string): Promise<void> { return this.voteStore.markPollVoted(uid, tid) }

  // ---------- Facade: Browse History ----------

  getBrowseHistory(uid: string): Promise<BrowseHistoryEntry[]> { return this.historyStore.getBrowseHistory(uid) }
  addBrowseHistory(uid: string, entry: BrowseHistoryEntry): Promise<void> {
    return this.historyStore.addBrowseHistory(uid, entry)
  }
  addBrowseHistoryFromThread(uid: string, result: ThreadResult, tid: string): Promise<void> {
    return this.historyStore.addFromThreadResult(uid, result, tid)
  }
  removeBrowseHistory(uid: string, tid: string): Promise<void> { return this.historyStore.removeBrowseHistory(uid, tid) }
  clearBrowseHistory(uid: string): Promise<void> { return this.historyStore.clearBrowseHistory(uid) }

  // ---------- Facade: Reading Progress ----------

  /** 读取指定帖子的阅读进度（无记录返回 null）。 */
  getReadingProgress(uid: string, tid: string): Promise<ReadingProgressEntry | null> {
    return this.readingProgressStore.getProgress(uid, tid)
  }
  /** 写入（覆盖）指定帖子的阅读进度。 */
  saveReadingProgress(uid: string, entry: ReadingProgressEntry): Promise<void> {
    return this.readingProgressStore.setProgress(uid, entry)
  }

  // ---------- Facade: AI Sessions（对话记忆） ----------

  /** 全部 AI 会话（按最后更新倒序）。 */
  listAiSessions(): AiSession[] { return this.aiSessionStore.listSessions() }
  /** 按 ID 读取 AI 会话副本。 */
  getAiSession(id: string): AiSession | null { return this.aiSessionStore.getSession(id) }
  /** 创建一条新的 AI 会话（首次保存时才落盘）。 */
  createAiSession(presetId: string, presetName: string): AiSession {
    return this.aiSessionStore.createSession(presetId, presetName)
  }
  /** 保存（覆盖）AI 会话。 */
  saveAiSession(session: AiSession): void { this.aiSessionStore.saveSession(session) }
  /** 删除指定 AI 会话。 */
  deleteAiSession(id: string): void { this.aiSessionStore.deleteSession(id) }
  /** 清空当前账号的全部 AI 会话。 */
  clearAiSessions(): void { this.aiSessionStore.clearAllSessions() }

  // ---------- Facade: Toast ----------

  /**
   * 当前 Toast 状态快照（只读入口）。
   *
   * 展示由系统浮层承载（见 `ToastManager`），不再有页面内组件订阅本状态。
   */
  get toast(): ToastState {
    return this.toastManager.state
  }

  showToast(msg: string): void { this.toastManager.show(msg) }

  /**
   * 展示带动作按钮的 Toast（如回复成功后的「前往查看」）。
   *
   * @param msg - 主文案
   * @param actionText - 按钮文案
   * @param onAction - 点击回调；回调可能晚于 Toast 消失触发，闭包内不得依赖已销毁的组件实例
   */
  showToastAction(msg: string, actionText: string, onAction: () => void): void {
    this.toastManager.showAction(msg, actionText, onAction)
  }
}

export const appStore = new AppStoreClass()
