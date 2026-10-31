import { Context } from '@kit.AbilityKit'
import { bundleManager } from '@kit.AbilityKit'
import { PreferencesStore } from '../common/infra/PreferencesStore'
import { SerialQueue } from '../common/infra/SerialQueue'
import { persistenceHub, PersistenceHub } from '../common/persistence/PersistenceHub'
import { MigrationEngine, MigrationInspection, MigrationPlan } from '../common/persistence/MigrationEngine'
import { PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import {
  MigrationDomainStatus,
  MigrationReport,
  MigrationStatus,
  PersistenceMeta
} from '../common/persistence/PersistenceTypes'
import { dataTransferService, DataTransferService } from '../common/transfer/DataTransferService'
import { AppScheduler } from '../common/scheduler/AppScheduler'
import { SchedulerTrigger } from '../common/scheduler/SchedulerTypes'
import { BuiltinTaskHost, registerBuiltinTasks } from '../common/scheduler/BuiltinTasks'
import { KEY_DATA_MANAGEMENT_VERSION, KEY_MIGRATION_STATUS } from '../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../common/utils/AppStorageVersion'
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
  /** 迁移引擎（init 后可用；数据管理页「重试升级」与旧数据清理经此调用）。 */
  private migrationEngine: MigrationEngine | null = null
  /** 本次启动的迁移报告（真实源副本，UI/日志可查）。 */
  private startupMigrationReport: MigrationReport | null = null
  /** 本次启动是否有待展示的迁移提醒（见 migrationNoticePending 注释）。 */
  private migrationNoticePendingFlag: boolean = false
  /** 应用版本信息（迁移/导出容器的诊断字段）。 */
  private appVersionName: string = ''
  private appVersionCode: number = 0
  /**
   * 应用内调度器（统一时机任务的唯一入口）。
   *
   * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §7：把原本散落在 EntryAbility 与各
   * PollingController 的时机任务收敛到一张注册表；本类只提供宿主回调与生命周期事件。
   *
   * **非 final 字段**：Ability 在进程存活期间被重建 / init 重入时，旧实例可能已 shutdown
   * （disposed 后不可恢复），必须能整体替换（见 `recreateScheduler`）。
   */
  scheduler: AppScheduler = new AppScheduler()

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
    // 调度器实例在 `init` 中创建/重建（见 recreateScheduler），此处不再注册
    // 帖子失效 / 长期无新回复导致的自动停止跟踪统一在这里提示（用户主动移除不提示）
    this.trackedThreadStore.onStopNotice = (notice: TrackStopNotice): void => {
      const message: string = formatTrackStopNotice(notice)
      if (message.length > 0) {
        this.showToast(message)
      }
    }
  }

  /**
   * 创建（或重建）调度器并注册内置任务。
   *
   * 为什么每次 init 都重建：`AppScheduler.shutdown()` 后实例进入 disposed 状态且不可恢复；
   * Ability 在进程存活期间被重建、或 `init` 被重入时，若不重建，签到/会话校验/轮询等任务
   * 会**永久静默失效**（start/notify 全部被忽略且无报错）。
   */
  private recreateScheduler(): void {
    try {
      this.scheduler.shutdown()
    } catch (e) {
      // 旧实例可能从未启动，shutdown 幂等
    }
    this.scheduler = new AppScheduler()
    this.scheduler.bindForegroundProbe((): boolean => this.foregroundActive)
    this.scheduler.bindAuthProbe((): boolean => this.auth.isAuthenticated)
    registerBuiltinTasks(this.scheduler, this.createBuiltinTaskHost())
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
    this.recreateScheduler()
    this.bindSessionGuard()
    try {
      this.context = context
      await this.store.init(context, 'nga_app_store')

      /*
       * 持久化统一治理（PERSISTENCE_UNIFICATION_DESIGN.md §5.3）：
       * 1) Hub 初始化（清 pending、打开双后端）；
       * 2) 启动迁移检测 + 执行——必须早于任何 Store init，否则改读新键的 Store 会
       *    在旧数据尚未搬移时读到空、表现为"升级后数据全丢"；
       * 3) 之后各 Store 按新键加载。
       */
      await persistenceHub.init(this.store, this.writeQueue, context.filesDir)
      await this.runStartupMigration()

      // 存档与登录态无关，随应用启动即初始化（不按账号区分）
      await this.savedThreadStore.init(context)

      // 编辑器草稿与草稿媒体副本（键内已含 uid 哈希，目录本身不按账号分）
      await draftStore.init(context)
      await draftMediaStore.init(context)
      // 超期/超容量清理由调度器任务 `draft.cleanup`（STARTUP + 800ms 延迟）驱动，
      // 这里不再直接 setTimeout：见 docs/PERSISTENCE_UNIFICATION_DESIGN.md §7.4。

      // 子 Store 中不依赖 uid 的先初始化（同步赋值引用）
      await this.voteStore.init(this.store, this.writeQueue)
      await this.historyStore.init(this.store, this.writeQueue)
      await this.readingProgressStore.init(this.store, this.writeQueue)

      // 认证 + 分类（分类为设备级缓存，不再依赖 uid）
      await this.authStore.init(this.store, this.writeQueue)
      await this.categoryStore.init(this.store, this.writeQueue, this.authStore.state)

      // 主题为全局设置（不随 uid 隔离）：无论登录与否都加载持久化主题，
      // 保证未登录用户冷启动后主题/状态栏样式正确（见 docs/THEME_DESIGN.md）
      await this.settingsStore.initTheme(this.store, this.writeQueue, this.context)

      // 用户数据（设备级域无论登录与否都加载；账号镜像域仅在已登录时加载）
      await this.loadUserData()
      this.settingsStore.applyCurrentTheme()
      this.initialized = true
      // 调度器：解除 STARTUP 门禁 → 启动心跳 → 派发启动任务（签到/轮询/草稿清理/旧数据清理）
      this.scheduler.setStartupComplete()
      this.scheduler.start()
      this.scheduler.notify(SchedulerTrigger.STARTUP)
      this.reconcilePolling()

      logger.info('AppStore initialized')
    } catch (e) {
      logger.error('AppStore init failed: %{public}s', formatError(e))
      throw new Error(formatError(e))
    } finally {
      this.initializationFinished = true
    }
  }

  /**
   * 启动迁移：检测旧数据并转换为统一格式。
   *
   * 三条来源共用同一引擎（设计文档 §5.2）：版本升级、系统备份恢复、用户导入。
   * 失败不阻塞启动：报告发布到 AppStorage，MainPage 展示一次提醒，数据管理页可重试。
   */
  private async runStartupMigration(): Promise<void> {
    this.readAppVersion()
    const engine: MigrationEngine = new MigrationEngine(
      persistenceHub, this.store, this.appVersionName, this.appVersionCode)
    this.migrationEngine = engine
    try {
      const currentUid: string = await this.readCurrentUidForMigration()
      const inspection: MigrationInspection = await engine.inspect(currentUid)
      let report: MigrationReport
      if (inspection.pending) {
        const plan: MigrationPlan = await engine.buildPlan(currentUid, await persistenceHub.metaStore.load())
        report = await engine.run(plan, currentUid)
        /*
         * 只有本次启动真正执行了迁移、且产生了用户关心的结果（成功转换/失败），
         * 才需要提醒；且 meta 里已提示过的永不再弹。旧数据"已迁移"的报告会长期留在 meta，
         * 不能拿它当提示依据（否则每次冷启动都弹"本地数据已升级"，真机实测问题）。
         */
        const metaAfter: PersistenceMeta | null = await persistenceHub.metaStore.load()
        const acknowledged: boolean = metaAfter !== null && metaAfter.migrationNoticeAcknowledged
        const hasOutcome: boolean = report.count(MigrationDomainStatus.MIGRATED) > 0 ||
          report.count(MigrationDomainStatus.FAILED) > 0
        this.migrationNoticePendingFlag = hasOutcome && !acknowledged
      } else {
        const meta = await persistenceHub.metaStore.load()
        if (meta === null) {
          // 首次安装：直接落锚点，不迁移
          const fresh = await persistenceHub.metaStore.createFresh(
            this.appVersionName, this.appVersionCode)
          report = fresh.migration
        } else {
          report = meta.migration
        }
      }
      this.publishMigrationReport(report)
    } catch (e) {
      // 迁移异常不得让应用停在"初始化失败"：记录并继续用现有数据启动
      logger.error('启动迁移异常: %{public}s', formatError(e))
      const failed: MigrationReport = new MigrationReport()
      failed.status = MigrationStatus.FAILED
      failed.finishedAt = Date.now()
      this.publishMigrationReport(failed)
    }
    /*
     * 导入/导出服务必须**独立于迁移成败**初始化（审计 EXP-04）：迁移抛异常时用户恰恰最需要
     * 先导出一份现有数据；放在 catch 之后保证任何路径下「数据管理」都可用。
     * 旧版 undo 明文快照的清理同理，不能因为迁移异常而跳过（隐私残留）。
     */
    this.initDataTransferService()
    await dataTransferService.clearLegacyUndoSnapshots()
  }

  /**
   * 注入导入/导出服务依赖（幂等：启动迁移后与「重试升级」成功后各调用一次）。
   */
  private initDataTransferService(): void {
    dataTransferService.init(persistenceHub, this.store, this.appVersionName, this.appVersionCode,
      (): string => this.authStore.state.uid)
  }

  /**
   * 读取应用版本信息（迁移报告与导出容器的诊断字段）。
   */
  private readAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      this.appVersionName = info.versionName
      this.appVersionCode = info.versionCode
    } catch (e) {
      logger.warn('读取应用版本失败: %{public}s', formatError(e))
      this.appVersionName = ''
      this.appVersionCode = 0
    }
  }

  /**
   * 迁移取舍用的当前 uid：优先新键 `v2.auth`，回退旧键 `auth`。
   *
   * 迁移发生在 authStore.init 之前（此时新键可能还不存在），因此不能依赖 authStore。
   *
   * @returns 当前登录 uid；未登录/无凭证返回空串
   */
  private async readCurrentUidForMigration(): Promise<string> {
    const authSpec = PersistenceCatalog.byId('auth')
    if (authSpec !== null) {
      const uid: string = await this.readUidFromAuthKey(authSpec.fullKey())
      if (uid.length > 0) {
        return uid
      }
    }
    return await this.readUidFromAuthKey('auth')
  }

  /**
   * 从指定 auth 键解析 uid。
   *
   * @param key - `v2.auth` 或旧键 `auth`
   * @returns uid；键不存在/解析失败返回空串
   */
  private async readUidFromAuthKey(key: string): Promise<string> {
    const raw: string = await this.store.getString(key, '')
    if (raw.length === 0) {
      return ''
    }
    try {
      const parsed: Object = JSON.parse(raw)
      if (parsed === null || parsed === undefined || Array.isArray(parsed) || typeof parsed !== 'object') {
        return ''
      }
      const record: Record<string, Object> = parsed as Record<string, Object>
      const uid: Object | undefined = record['uid']
      return typeof uid === 'string' ? uid as string : ''
    } catch (e) {
      return ''
    }
  }

  /**
   * 发布迁移报告到内存与 AppStorage（MainPage 据此弹一次性提醒）。
   *
   * @param report - 迁移报告
   */
  private publishMigrationReport(report: MigrationReport): void {
    this.startupMigrationReport = report
    AppStorage.setOrCreate(KEY_MIGRATION_STATUS, report.status)
    bumpAppStorageVersion(KEY_DATA_MANAGEMENT_VERSION)
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

  /**
   * 构造调度任务宿主（把调度器的业务动作回接到本 Store 与各领域 Store）。
   *
   * 所有回调都自行容错：调度器会兜底 catch，但正常失败不应污染任务状态。
   *
   * @returns 任务宿主
   */
  private createBuiltinTaskHost(): BuiltinTaskHost {
    const host: BuiltinTaskHost = new BuiltinTaskHost()
    host.verifySession = async (): Promise<void> => {
      // SessionGuard 内部有 10 分钟节流 + 降级态 1 分钟，任务层的 minInterval 只是第一道闸
      await this.sessionGuard.verifyOnForeground()
    }
    host.autoCheckin = async (): Promise<void> => {
      await this.autoCheckinIfNeeded()
    }
    host.pollNotifications = async (): Promise<void> => {
      await this.refreshNotifications(false)
    }
    host.pollActivities = async (): Promise<void> => {
      await this.refreshActivities(false)
    }
    host.checkTracked = async (): Promise<void> => {
      await this.trackedThreadStore.refresh(false)
    }
    host.cleanupDrafts = (): void => {
      this.initDraftCleanup()
    }
    host.cleanupLegacy = async (): Promise<void> => {
      await this.cleanupLegacyData(false)
    }
    return host
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

  /**
   * 加载数据。
   *
   * 改造后（取消账号隔离）分两类：
   * - **设备级域**：无论是否登录都加载（设置/主题/分类/资料/跟踪/AI/历史/进度/投票）；
   * - **账号镜像域**：仅在已登录时加载，Store 内部按 ownerUid 判定有效性（通知/动态/收藏关系）。
   */
  private async loadUserData(): Promise<void> {
    // 设备级域（不依赖 uid）
    await this.settingsStore.init(this.store, this.writeQueue, this.authStore.state, this.context)
    await this.profileStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.trackedThreadStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.aiSessionStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.aiToolCacheStore.init(this.store, this.writeQueue, this.authStore.state)
    // 账号镜像域（仅已登录）
    await this.loadMirrorData()
    /* 浏览历史兼作主题列表的已读台账（看过 / 有更新标记的数据源），随用户数据一并预载：
       它是懒加载的，不在这里拉起的话列表会先按"全部没看过"渲染一遍再刷新（见 HistoryStore.preload） */
    await this.historyStore.preload(this.authStore.state.uid)
  }

  /**
   * 只加载/重载账号镜像域（通知 / 关注动态 / 收藏成员关系）。
   *
   * 登录成功与切换账号时调用；设备级域不重复加载（同一份数据，取消隔离后的预期行为）。
   */
  private async loadMirrorData(): Promise<void> {
    if (this.authStore.state.uid.length === 0) {
      return
    }
    await this.notificationStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.followActivityStore.init(this.store, this.writeQueue, this.authStore.state)
    await this.favoriteStore.init(this.store, this.writeQueue, this.authStore.state)
  }

  /** 后台时刷盘 */
  async flushAll(): Promise<void> {
    /* 工具缓存是节流写的：后台/退出前补一次，避免进程被杀丢掉最近 800ms 的命中结果 */
    this.aiToolCacheStore.flush()
    await this.writeQueue.enqueue(async (): Promise<void> => {})
    await this.store.flush()
    /* 统一治理层再兜一次（含 .pending 清理的时序安全）：Hub 内部同样排空写队列后 flush */
    await persistenceHub.flush()
  }

  // ---------- Facade: Auth ----------

  get auth(): AuthState {
    return this.authStore.state
  }

  async setAuth(token: string, uid: string, nickName: string, avatarUrl: string): Promise<void> {
    this.stopAllPolling()
    const uidChanged = await this.authStore.setAuth(token, uid, nickName, avatarUrl)
    if (uidChanged) {
      /*
       * 只重载账号镜像域。设备级域（设置/历史/进度/AI 会话等）在取消账号隔离后是同一份
       * 设备数据，不需要也不能因为换号而重载（设计文档 ADR-001 §3.4）。
       */
      await this.loadMirrorData()
      this.settingsStore.applyCurrentTheme()
    }
    // 新会话：复位"未登录信号"去抖窗口与降级标记，避免登录后立刻失效被上一轮窗口吞掉，
    // 也避免上一个账号的降级结论跟到新账号上
    globalSessionGuard.resetForNewSession()
    this.resetCredentialState()
    this.reconcilePolling()
    // 登录事件：签到 / 会话校验 / 镜像域轮询由调度器任务表统一响应
    this.scheduler.notify(SchedulerTrigger.LOGIN)
  }

  clearAuth(): void {
    this.stopAllPolling()
    /*
     * ⚠️ 顺序依赖：cancel/reset 必须在 authStore.clearAuth() 之前，否则后者 enqueue 的
     * persistAuth 写入任务会被取消。
     *
     * 但要诚实说明现状（盘点已确认，见设计文档 §0.1.1 第 2 条）：`SerialQueue.cancel()`
     * 后紧随 `reset()` 会把 cancelled 标志清回 false，**已入队的闭包仍会执行**——这里的
     * cancel 并不真正取消在途写。磁盘一致性由随后的 `authStore.clearAuth()` 把空凭证
     * 排到新链上写盘来保证；不要在此基础上叠加"取消在途写入"的假设。
     */
    this.writeQueue.cancel()
    this.writeQueue.reset()
    // 再清空认证状态（会 enqueue 写入空 auth，此时 queue 已重置为干净状态）
    this.authStore.clearAuth()
    /*
     * 取消账号隔离后的退出语义（设计文档 ADR-001 / §8.2）：
     * - **账号镜像域**：清内存（磁盘保留；下次登录同账号仍可见，换账号后 ownerUid 不符自动作废）；
     * - **设备级域**：不 reset（设置/主题/分类/资料/历史/进度/投票/跟踪/AI/草稿/存档保留），
     *   未登录状态下继续可用——这是本次治理最核心的用户可见变化。
     *
     * 注意：此处移除 `settingsStore.reset()` / `categoryStore.reset()` / `profileStore.reset()` /
     * `voteStore.reset()` / `historyStore.reset()` / `readingProgressStore.reset()` /
     * `trackedThreadStore.reset()` / `aiSessionStore.reset()` / `aiToolCacheStore.reset()` 是
     * **刻意**的，不是遗漏；这些数据属于设备，不属于账号。真正需要"清空一切"的入口是
     * 数据管理页的「清空本地数据」。
     */
    this.notificationStore.reset()
    this.followActivityStore.reset()
    this.favoriteStore.reset()
    floatingLayerStore.clear()
    routerStore.reset()
    // 真未登录：降级态失去意义，顺带取消待执行的自动复验
    this.resetCredentialState()
    // 与 setAuth 对称：退出后统一协调轮询状态（此时未认证 → 停止轮询，幂等无害）
    this.reconcilePolling()
    this.scheduler.notify(SchedulerTrigger.LOGOUT)
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
  autoCheckinIfNeeded(): Promise<void> {
    const requestUid: string = this.auth.uid
    return this.settingsStore.autoCheckinIfNeeded().then((checked: boolean): void => {
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
    if (this.initialized) {
      if (!active) {
        // 回后台：停止前台派发并通知后台任务（当前任务表仅前台任务，后台任务预留）
        this.scheduler.notify(SchedulerTrigger.BACKGROUND)
      }
      this.reconcilePolling()
    }
    if (active && this.auth.credentialState === CredentialState.DEGRADED) {
      this.scheduleCredentialRecheck()
    }
  }

  /**
   * 关闭调度器（Ability onDestroy 调用）。
   *
   * 清理心跳与待执行定时器；进程销毁后不应再有任何调度回调。
   */
  shutdownScheduler(): void {
    this.scheduler.shutdown()
  }
  /**
   * 根据初始化、认证与前台状态协调前台任务。
   *
   * 调度器接管后：条件满足时派发 `FOREGROUND`（由任务表按节流/单飞执行），条件不满足时
   * 停止旧的 `PollingController` 实例（它们在本版本中不再被启动，保留停机调用只为兜底）。
   */
  private reconcilePolling(): void {
    if (shouldEnablePolling(
      this.foregroundActive,
      this.initialized,
      this.auth.isAuthenticated
    )) {
      this.scheduler.notify(SchedulerTrigger.FOREGROUND)
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

  // ---------- Facade: Persistence / Data Management ----------

  /** 本次启动的迁移报告（无则 null）。 */
  get migrationReport(): MigrationReport | null {
    return this.startupMigrationReport
  }

  /**
   * 是否需要向用户展示"本地数据已升级"提醒。
   *
   * 只有**本次启动真正执行了迁移且产生了结果**（成功转换或失败）才为 true，
   * 且 meta 中未标记已提示——迁移报告会长期留在 meta 里，不能拿它当"是否提示"的依据，
   * 否则每次冷启动都会重复弹（真机实测问题）。
   */
  get migrationNoticePending(): boolean {
    return this.migrationNoticePendingFlag
  }

  /**
   * 标记迁移提醒已展示（持久化到 meta，保证只提示一次）。
   */
  async acknowledgeMigrationNotice(): Promise<void> {
    if (!this.migrationNoticePendingFlag) {
      return
    }
    this.migrationNoticePendingFlag = false
    try {
      const meta: PersistenceMeta | null = await persistenceHub.metaStore.load()
      if (meta === null) {
        return
      }
      meta.migrationNoticeAcknowledged = true
      await persistenceHub.metaStore.save(meta)
    } catch (e) {
      logger.warn('acknowledge migration notice failed: %{public}s', formatError(e))
    }
  }

  /** 迁移是否已完成（含"无需迁移"）。 */
  get migrationSettled(): boolean {
    const report: MigrationReport | null = this.startupMigrationReport
    if (report === null) {
      return false
    }
    return report.status === MigrationStatus.COMPLETED ||
      report.status === MigrationStatus.NOT_REQUIRED
  }

  /** 迁移失败域数量。 */
  get migrationFailedCount(): number {
    const report: MigrationReport | null = this.startupMigrationReport
    return report === null ? 0 : report.count(MigrationDomainStatus.FAILED)
  }

  /**
   * 升级未完成的域数量（FAILED + DEFERRED）。
   *
   * 这些域的旧键数据仍留在磁盘上、尚未搬进 `v2.*` —— 导出只读新键，因此备份会缺这些域；
   * 数据管理页在导出/清空前据此提示用户（审计 EXP-03 / DES-02）。
   *
   * @returns 未完成域数量
   */
  get migrationUnsettledCount(): number {
    const report: MigrationReport | null = this.startupMigrationReport
    if (report === null) {
      return 0
    }
    return report.count(MigrationDomainStatus.FAILED) + report.count(MigrationDomainStatus.DEFERRED)
  }

  /** 持久化中心（数据管理页读取域体积/健康用）。 */
  get persistence(): PersistenceHub {
    return persistenceHub
  }

  /** 数据导入导出服务。 */
  get dataTransfer(): DataTransferService {
    return dataTransferService
  }

  /**
   * 重试迁移（数据管理页「重试升级」）。
   *
   * 幂等：已完成域会被 `SKIPPED`，不会重复转换。
   *
   * @returns 最新迁移报告
   */
  async retryMigration(): Promise<MigrationReport> {
    const engine: MigrationEngine | null = this.migrationEngine
    if (engine === null) {
      throw new Error('迁移引擎未就绪')
    }
    const currentUid: string = this.auth.uid
    const plan: MigrationPlan = await engine.buildPlan(currentUid, await persistenceHub.metaStore.load())
    const report: MigrationReport = await engine.run(plan, currentUid)
    this.publishMigrationReport(report)
    /*
     * 重试成功后重新注入导入/导出服务：启动迁移异常时它可能从未初始化过，
     * 不重新注入会让用户重试成功后仍需重启才能导出（审计 EXP-04）。
     */
    this.initDataTransferService()
    return report
  }

  /**
   * 清理到期的旧格式数据（默认要求已到保留期；force=true 为「立即清理」）。
   *
   * @param force - 是否忽略保留期
   * @returns 清理条目数
   */
  async cleanupLegacyData(force: boolean): Promise<number> {
    const engine: MigrationEngine | null = this.migrationEngine
    const report: MigrationReport | null = this.startupMigrationReport
    if (engine === null || report === null) {
      return 0
    }
    const removed: number = await engine.cleanupLegacy(report, force)
    if (removed > 0) {
      /*
       * 清理成功后必须回写 meta：否则 `v2.meta.migration.legacyKeys` 仍留着已删除的键，
       * 数据管理页会永久显示"N 项待清理"，下次启动还会再扫一遍。
       */
      report.legacyKeys = []
      report.legacyCleanupAt = 0
      this.startupMigrationReport = report
      const meta: PersistenceMeta | null = await persistenceHub.metaStore.load()
      if (meta !== null) {
        meta.migration = report
        await persistenceHub.metaStore.save(meta)
      }
      bumpAppStorageVersion(KEY_DATA_MANAGEMENT_VERSION)
    }
    return removed
  }

  /**
   * 清空全部可清空的本地数据（数据管理页危险操作）。
   *
   * 凭证、多会话表与 meta 锚点不在清空范围（`clearable=false`），避免"清数据把自己登出"
   * 与"锚点丢失触发全量迁移"。
   *
   * @returns 清空的域数量
   */
  async clearAllLocalData(): Promise<number> {
    const specs = PersistenceCatalog.clearable()
    let cleared: number = 0
    for (let i: number = 0; i < specs.length; i++) {
      await persistenceHub.removeDomain(specs[i])
      cleared++
    }
    /*
     * 旧格式数据要一并清除：否则下次启动的迁移检测会把旧草稿/存档/旧键重新迁回来，
     * 用户看到"清空后又出现"（文件域检测还依赖 meta 报告，但旧键检测总会命中）。
     */
    await persistenceHub.removeLegacyKeys()
    persistenceHub.removeLegacyFileDirs()
    /*
     * 清盘后必须同步重置内存态：各 Store 的内存快照若继续存活，页面会显示"已删除的数据"
     * 直到进程重启。这里复用既有 `reset()`（各 Store 已实现"清内存 + 恢复默认"语义），
     * 文件域用各自的重新扫描入口。
     */
    this.settingsStore.reset()
    /*
     * 主题清空后回到默认（跟随系统）：`settingsStore.reset()` 内部的 restoreGlobal 会把
     * 清空前内存里的旧主题重新持久化写回 `v2.theme`，不显式改回默认等于"没清掉主题"。
     */
    this.settingsStore.setTheme('system')
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
    draftStore.reloadAfterClear()
    this.savedThreadStore.reload()
    /* 旧版撤销快照（`v2.<domain>.undo`）含明文隐私内容，清空本地数据时一并清理 */
    await dataTransferService.clearLegacyUndoSnapshots()
    /* 旧键/旧目录已删除：同步把「待清理旧数据」清单清空，否则数据管理页会一直显示可清理（DES-09） */
    await this.resetMigrationLegacyReport()
    await persistenceHub.flush()
    bumpAppStorageVersion(KEY_DATA_MANAGEMENT_VERSION)
    return cleared
  }

  /**
   * 清空迁移报告里的「待清理旧数据」清单（清空本地数据后调用）。
   *
   * 旧键/旧目录已被 `clearAllLocalData` 一并删除，若不同步清报告，数据管理页会长期显示
   * 「N 项旧格式数据已到期，可立即清理」，点「立即清理」又因键不存在而无效（审计 DES-09）。
   */
  private async resetMigrationLegacyReport(): Promise<void> {
    try {
      const report: MigrationReport | null = this.startupMigrationReport
      if (report !== null) {
        report.legacyKeys = []
        report.legacyCleanupAt = 0
        this.startupMigrationReport = report
      }
      const meta: PersistenceMeta | null = await persistenceHub.metaStore.load()
      if (meta !== null) {
        meta.migration.legacyKeys = []
        meta.migration.legacyCleanupAt = 0
        await persistenceHub.metaStore.save(meta)
      }
    } catch (e) {
      logger.warn('reset migration legacy report failed: %{public}s', formatError(e))
    }
  }

  /**
   * 导入完成后重载各域内存（数据管理页在 applyImport 成功后调用）。
   *
   * 导入写的是磁盘键，而各 Store 持有内存快照；不重载的话，用户要重启应用才能看到导入的数据。
   * 这里按"设备级域重新 init + 懒加载域 reset 后按需重读 + 文件域重扫"的顺序刷新，
   * 账号镜像域由 `loadMirrorData` 重新加载。
   *
   * **逐域独立容错**：任一 Store 重载抛异常不得中断后续域（审计 IMP-07）——否则部分域会停在
   * 旧内存快照，用户随后改任一设置就把旧快照整体写回磁盘，静默覆盖刚导入的数据。
   *
   * 注意：不做 `clearAuth` 式的全量 reset——那会清掉正在编辑的会话态。
   *
   * @returns 重载失败的域/组件标识（空数组表示全部成功；调用方据此提示用户）
   */
  async reloadAfterImport(): Promise<string[]> {
    const failed: string[] = []
    await this.reloadImportStep(failed, 'settings', async (): Promise<void> => {
      await this.settingsStore.init(this.store, this.writeQueue, this.authStore.state, this.context)
    })
    /* 主题是独立全局域（v2.theme），导入可能写了它：必须重新加载内存真源 */
    await this.reloadImportStep(failed, 'theme', async (): Promise<void> => {
      await this.settingsStore.initTheme(this.store, this.writeQueue, this.context)
    })
    await this.reloadImportStep(failed, 'categories', async (): Promise<void> => {
      await this.categoryStore.init(this.store, this.writeQueue, this.authStore.state)
    })
    await this.reloadImportStep(failed, 'profiles', async (): Promise<void> => {
      await this.profileStore.init(this.store, this.writeQueue, this.authStore.state)
    })
    await this.reloadImportStep(failed, 'tracked_threads', async (): Promise<void> => {
      await this.trackedThreadStore.init(this.store, this.writeQueue, this.authStore.state)
    })
    await this.reloadImportStep(failed, 'ai_sessions', async (): Promise<void> => {
      await this.aiSessionStore.init(this.store, this.writeQueue, this.authStore.state)
    })
    await this.reloadImportStep(failed, 'ai_tool_cache', async (): Promise<void> => {
      await this.aiToolCacheStore.init(this.store, this.writeQueue, this.authStore.state)
    })
    await this.reloadImportStep(failed, 'mirror', async (): Promise<void> => {
      await this.loadMirrorData()
    })
    // 懒加载域：清内存后由下一次访问重新读盘（历史额外预载，保证列表首帧已读标记正确）
    await this.reloadImportStep(failed, 'votes', async (): Promise<void> => {
      this.voteStore.reset()
    })
    await this.reloadImportStep(failed, 'reading_progress', async (): Promise<void> => {
      this.readingProgressStore.reset()
    })
    await this.reloadImportStep(failed, 'history', async (): Promise<void> => {
      this.historyStore.reset()
      await this.historyStore.preload(this.authStore.state.uid)
    })
    // 文件域重新扫描磁盘
    await this.reloadImportStep(failed, 'saved_threads', async (): Promise<void> => {
      this.savedThreadStore.reload()
    })
    await this.reloadImportStep(failed, 'drafts', async (): Promise<void> => {
      draftStore.reloadAfterClear()
    })
    await this.reloadImportStep(failed, 'apply_theme', async (): Promise<void> => {
      this.settingsStore.applyCurrentTheme()
    })
    bumpAppStorageVersion(KEY_DATA_MANAGEMENT_VERSION)
    logger.info('reloaded after data import failedSteps=%{public}d', failed.length)
    return failed
  }

  /**
   * 执行一个导入后重载步骤；失败只记录并把步骤名加入 `failed`，不中断后续步骤。
   *
   * @param failed - 失败步骤名收集数组
   * @param name - 步骤/域标识
   * @param step - 步骤实现
   */
  private async reloadImportStep(failed: string[], name: string,
    step: () => Promise<void>): Promise<void> {
    try {
      await step()
    } catch (e) {
      failed.push(name)
      logger.warn('reloadAfterImport step failed step=%{public}s: %{public}s', name, formatError(e))
    }
  }

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
