/**
 * 数据管理面板（设置 → 数据管理）。
 *
 * 职责（只做 UI 编排，不碰持久化细节）：
 * 1. 展示数据版本/迁移状态与旧数据清理入口；
 * 2. 展示域健康问题（读取/写入失败、坏条目）；
 * 3. 展示各域存储占用估算；
 * 4. 导出：选择域 + 可选加密 → 生成容器文本 → 系统 picker 保存；
 * 5. 导入：选文件 → 解析（必要时口令）→ 导入计划确认 → 应用；
 * 6. 危险区：清空全部可清空数据（输入「清空」二次确认）。
 *
 * 数据来源全部走 `appStore.*` 门面：
 * - `appStore.migrationReport / migrationSettled / migrationFailedCount / retryMigration / cleanupLegacyData`
 * - `appStore.persistence.estimateAll / health.problems`
 * - `appStore.dataTransfer.exportBackup / parseBackup / buildImportPlan / applyImport`
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6.7；交互风格对齐
 * `FontSizeSettingsPanel`（标题栏滚动联动 + 92% 卡片）。
 */

import { appStore } from '../store/AppStore'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { UIMaterialManager } from '../common/managers/UIMaterialManager'
import { CredentialPasswordContent } from '../common/dialogs/Dialogs'
import { CustomContentDialog } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { DomainIds, PersistenceCatalog } from '../common/persistence/PersistenceCatalog'
import {
  BACKUP_FILE_SUFFIX,
  BACKUP_MAX_FILE_BYTES,
  DomainHealthSnapshot,
  DomainSpec,
  ExportPolicy,
  ImportPolicy,
  MigrationDomainResult,
  MigrationReport,
  MigrationStatus,
  PersistenceMeta,
  TransferHistoryEntry,
  TransferHistoryKind,
  isDomainOversized
} from '../common/persistence/PersistenceTypes'
import {
  BackupContainer,
  BackupExportOptions,
  BackupExportResult,
  ImportPlan,
  ImportPlanEntry,
  ImportResult,
  SkippedDomain
} from '../common/transfer/TransferTypes'
import { ParseOutcome } from '../common/transfer/DataTransferService'
import { TaskOutcome, TaskStatus } from '../common/scheduler/SchedulerTypes'
import {
  PickedDocument,
  ReadTextResult,
  pickDocumentToRead,
  pickDocumentToSave,
  readTextFromUri,
  readTextFromUriDetailed,
  writeTextToUri
} from '../common/utils/FilePickUtils'
import { resolveKeyboardAppearance } from '../common/utils/KeyboardAppearanceUtils'
import { Logger, DOMAIN_STORE, formatError } from '../common/utils/Logger'

const logger = new Logger(DOMAIN_STORE, 'DataManagementPanel')

/** 备份文件体积上限（与 `PersistenceTypes.BACKUP_MAX_FILE_BYTES` 一致，64MB）。 */
const MAX_BACKUP_BYTES: number = BACKUP_MAX_FILE_BYTES

/**
 * 备份文件后缀（不含点）。
 *
 * 统一取自 `PersistenceTypes.BACKUP_FILE_SUFFIX`（`.ngabackup`）——此前本页另有一份
 * `BACKUP_SUFFIX='ngabackup'` 字面量，两处定义会漂移（审计 EXP-10）。
 */
const BACKUP_SUFFIX: string = BACKUP_FILE_SUFFIX.startsWith('.')
  ? BACKUP_FILE_SUFFIX.substring(1) : BACKUP_FILE_SUFFIX

/** 清空确认词。 */
const CLEAR_CONFIRM_WORD: string = '清空'

/**
 * 导出弹窗分组定义（设计稿 §6.3「六组分类」）。
 */
class ExportGroupDef {
  /** 组标题。 */
  title: string = ''
  /** 组内域 ID（顺序即展示顺序）。 */
  domainIds: string[] = []

  /**
   * 构造分组定义。
   *
   * @param title - 组标题
   * @param domainIds - 组内域 ID
   */
  constructor(title: string, domainIds: string[]) {
    this.title = title
    this.domainIds = domainIds
  }
}

/**
 * 导出弹窗的分组顺序（仅可导出域；凭证/媒体域不在 `exportable()` 中）。
 */
const EXPORT_GROUPS: ExportGroupDef[] = [
  new ExportGroupDef('设置与主题', [DomainIds.SETTINGS, DomainIds.THEME]),
  new ExportGroupDef('阅读与进度', [DomainIds.HISTORY, DomainIds.READING_PROGRESS,
    DomainIds.VOTES, DomainIds.POLL_VOTED]),
  new ExportGroupDef('社交与跟踪', [DomainIds.TRACKED_THREADS]),
  new ExportGroupDef('AI', [DomainIds.AI_SESSIONS, DomainIds.AI_TOOL_CACHE]),
  new ExportGroupDef('离线存档与草稿', [DomainIds.SAVED_THREADS, DomainIds.DRAFTS]),
  new ExportGroupDef('缓存与镜像', [DomainIds.CATEGORIES, DomainIds.PROFILES,
    DomainIds.NOTIFICATIONS, DomainIds.ACTIVITIES, DomainIds.FAVORITE_MEMBERSHIP])
]

/**
 * 存储占用行（每域一行）。
 */
class DomainSizeRow {
  /** 域 ID（修复/诊断用）。 */
  domainId: string = ''
  /** 域名。 */
  label: string = ''
  /** 格式化后的体积文案。 */
  sizeText: string = ''
  /** 体积字节数（排序用）。 */
  sizeBytes: number = 0
  /** 是否超过 4MB 单域预警阈值。 */
  oversized: boolean = false
}

/**
 * 导出弹窗列表行（组标题 + 域行）。
 */
class ExportRow {
  /** 行类型：`group`（组标题）/ `domain`（域行）。 */
  kind: string = 'domain'
  /** 展示文本（组标题；域行不使用）。 */
  text: string = ''
  /** 域 ID（仅 domain 行）。 */
  domainId: string = ''
}

/**
 * 导入计划展示行（每域一行）。
 */
class ImportPlanLine {
  /** 域名。 */
  label: string = ''
  /** 变更/跳过说明。 */
  detail: string = ''
  /** 是否跳过。 */
  willSkip: boolean = false
}

/**
 * 数据管理面板。
 */
@Component
export struct DataManagementPanel {
  /** 状态栏高度。 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 当前生效明暗色模式（密码输入框键盘样式用）。 */
  @StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'
  /** 数据管理版本号（迁移/导入/清空后由 AppStore bump，触发本页刷新）。 */
  @StorageProp('dataManagementVersion') @Watch('onDataManagementVersionChange') dataManagementVersion: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 滚动容器当前视口高度。 */
  @State scrollViewportHeight: number = 1

  // ---- 数据版本 / 迁移 ----
  /** 迁移总体状态文案。 */
  @State migrationStatusText: string = '加载中…'
  /** 数据版本补充说明。 */
  @State migrationSubText: string = ''
  /** 各域迁移结果明细。 */
  @State migrationDomainLines: string[] = []
  /** 是否显示「重试升级」。 */
  @State canRetryMigration: boolean = false
  /** 是否正在重试升级。 */
  @State retryingMigration: boolean = false
  /** 旧数据清理说明。 */
  @State legacyCleanupText: string = ''
  /** 是否显示「立即清理」。 */
  @State canCleanupLegacy: boolean = false
  /** 是否正在清理旧数据。 */
  @State cleaningLegacy: boolean = false

  // ---- 数据健康 ----
  /** 存在问题的域说明（非空才显示健康卡片）。 */
  @State healthProblemLines: string[] = []
  /** 存在问题的域 ID（与 `healthProblemLines` 同下标，修复按钮用）。 */
  @State healthProblemDomains: string[] = []

  // ---- 存储占用 ----
  /** 各域占用行（按体积降序）。 */
  @State domainSizeRows: DomainSizeRow[] = []
  /** 合计占用文案。 */
  @State totalSizeText: string = '—'
  /** 是否正在刷新统计。 */
  @State loadingSizes: boolean = false

  // ---- 最近导出 / 导入历史 ----
  /** 历史记录展示行（最新在前）。 */
  @State transferHistoryLines: string[] = []

  // ---- 调度状态 ----
  /** 调度任务状态行。 */
  @State schedulerLines: string[] = []
  /** 调度状态折叠区是否展开。 */
  @State schedulerExpanded: boolean = false

  // ---- 导出 ----
  /** 可导出的域 ID（Catalog 顺序）。 */
  @State exportDomainIds: string[] = []
  /** 当前勾选的域 ID。 */
  @State exportSelectedIds: string[] = []
  /** 导出弹窗列表行（六组分类 + 域行）。 */
  @State exportRows: ExportRow[] = []
  /** 每域体积文案（导出弹窗展示，异步加载）。 */
  @State exportDomainSizes: Record<string, string> = {}
  /** 是否加密导出（默认加密）。 */
  @State exportEncrypt: boolean = true
  /** 加密口令。 */
  @State exportPassword: string = ''
  /** 是否正在导出。 */
  @State exportRunning: boolean = false
  /** 导出进度文案。 */
  @State exportProgressText: string = ''

  // ---- 导入 ----
  /** 是否正在导入/解析。 */
  @State importing: boolean = false
  /** 导入阶段文案。 */
  @State importStageText: string = ''
  /** 导入计划展示行。 */
  @State importPlanLines: ImportPlanLine[] = []
  /** 导入计划摘要。 */
  @State importPlanSummary: string = ''
  /** 导入口令。 */
  @State importPassword: string = ''
  /**
   * 是否恢复缓存类数据（通知/动态/资料/分类/收藏关系/工具缓存）。
   *
   * **默认开启（跟随导出选择）**：备份里出现某个域，说明用户导出时主动勾选了它，
   * 导入就应当恢复；关闭后这些域按策略跳过（显示跳过原因）。
   * 每次开始一次新的导入（解析成功、生成计划前）都会重置为 true，避免上一次关闭的状态
   * 静默影响下一次导入（审计 IMP-06）。
   */
  @State restoreCacheDomains: boolean = true
  /** 导入计划是否可执行（全部跳过时仍展示原因，但禁用「确认导入」）。 */
  @State importPlanApplicable: boolean = true

  // ---- 清空 ----
  /** 清空确认输入。 */
  @State clearInput: string = ''
  /** 是否正在清空。 */
  @State clearingData: boolean = false

  /** 滚动控制器。 */
  private scroller: Scroller = new Scroller()
  /** 待解密的备份文件内容（密码弹窗往返用）。 */
  private pendingContent: string = ''
  /** 待确认的导入计划（计划确认弹窗 → 应用）。 */
  private pendingPlan: ImportPlan | null = null
  /** 最近解析成功的容器（切换「恢复缓存类数据」时重新构建计划用）。 */
  private pendingContainer: BackupContainer | null = null
  /** 解析阶段被丢弃的域（重新构建计划时要一并传入，保证跳过原因可见）。 */
  private pendingDroppedDomains: SkippedDomain[] = []

  /** 导出弹窗控制器。 */
  exportDialogController?: CustomDialogController
  /** 导入口令弹窗控制器。 */
  importPasswordController?: CustomDialogController
  /** 导入计划确认弹窗控制器。 */
  importPlanController?: CustomDialogController
  /** 清空确认弹窗控制器。 */
  clearDialogController?: CustomDialogController

  /** 页面出现：刷新全部统计。 */
  aboutToAppear(): void {
    this.refreshAll()
  }

  /** 页面销毁：释放弹窗控制器。 */
  aboutToDisappear(): void {
    this.exportDialogController = undefined
    this.importPasswordController = undefined
    this.importPlanController = undefined
    this.clearDialogController = undefined
  }

  /** 数据管理版本变化（迁移/导入/清空后）：刷新整页。 */
  onDataManagementVersionChange(): void {
    this.refreshAll()
  }

  /** 按滚动容器绝对偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /**
   * 取当前 UIAbility 上下文。
   *
   * @returns 上下文；取不到时返回 null
   */
  private currentContext(): common.UIAbilityContext | null {
    try {
      return this.getUIContext().getHostContext() as common.UIAbilityContext
    } catch (e) {
      return null
    }
  }

  // ============== 刷新 ==============

  /** 刷新整页数据（迁移状态 / 健康 / 存储 / 传输历史 / 调度状态）。 */
  private refreshAll(): void {
    this.refreshMigration()
    this.refreshHealth()
    this.refreshStorage()
    this.refreshTransferHistory()
    this.refreshScheduler()
  }

  /**
   * 刷新最近导出/导入历史（`v2.meta.transferHistory`）。
   */
  private async refreshTransferHistory(): Promise<void> {
    try {
      const meta: PersistenceMeta | null = await appStore.persistence.metaStore.load()
      const history: TransferHistoryEntry[] = meta === null ? [] : meta.transferHistory
      const lines: string[] = []
      for (let i: number = 0; i < history.length; i++) {
        const entry: TransferHistoryEntry = history[i]
        const isExport: boolean = entry.kind === TransferHistoryKind.EXPORT
        let line: string = this.formatDate(entry.at) + ' · ' + (isExport ? '导出' : '导入')
        if (isExport) {
          line += ' · ' + String(entry.domainCount) + ' 域 · ' + this.formatSize(entry.bytes)
          if (entry.encrypted) {
            line += '（已加密）'
          }
        } else {
          line += ' · ' + String(entry.domainCount) + ' 域 · 新增 '
            + String(entry.added) + ' · 更新 ' + String(entry.updated)
        }
        if (!entry.ok) {
          line += ' · 未全部成功'
        }
        if (entry.note.length > 0) {
          line += ' · ' + entry.note
        }
        lines.push(line)
      }
      this.transferHistoryLines = lines
    } catch (e) {
      this.transferHistoryLines = []
    }
  }

  /**
   * 刷新后台任务调度状态（`AppScheduler.snapshot()`）。
   */
  private refreshScheduler(): void {
    try {
      const statuses: TaskStatus[] = appStore.scheduler.snapshot()
      const lines: string[] = []
      for (let i: number = 0; i < statuses.length; i++) {
        const status: TaskStatus = statuses[i]
        let outcome: string = '未运行'
        if (status.running) {
          outcome = '执行中'
        } else if (status.lastRunAt === 0 && status.lastOutcome === TaskOutcome.SKIPPED) {
          /*
           * `TaskStatus.lastOutcome` 的默认值就是 SKIPPED：不能把"从未执行过"的任务显示成
           * "跳过"（评审 R-A09）；只有真正执行过（lastRunAt > 0）才按结果归类。
           */
          outcome = '未运行'
        } else if (status.lastOutcome === TaskOutcome.OK) {
          outcome = '成功'
        } else if (status.lastOutcome === TaskOutcome.FAILED) {
          outcome = '失败'
        } else if (status.lastOutcome === TaskOutcome.SKIPPED) {
          outcome = '跳过'
        }
        let line: string = status.id + '：' + outcome
        if (status.lastRunAt > 0) {
          line += ' · ' + this.formatDate(status.lastRunAt)
        }
        if (status.failureCount > 0) {
          line += ' · 连续失败 ' + String(status.failureCount)
        }
        if (status.lastError.length > 0) {
          line += '（' + status.lastError + '）'
        }
        lines.push(line)
      }
      this.schedulerLines = lines
    } catch (e) {
      this.schedulerLines = []
    }
  }

  /** 刷新迁移状态与旧数据清理信息。 */
  private refreshMigration(): void {
    const report: MigrationReport | null = appStore.migrationReport
    if (report === null) {
      this.migrationStatusText = '尚未执行迁移'
      this.migrationSubText = '首次启动完成后会在此显示数据版本与迁移结果。'
      this.migrationDomainLines = []
      this.legacyCleanupText = ''
      this.canCleanupLegacy = false
      this.canRetryMigration = false
      return
    }
    this.migrationStatusText = this.migrationStatusLabel(report.status)
    const fromVersion: string = report.fromDataVersion > 0 ? String(report.fromDataVersion) : '未知'
    this.migrationSubText = '全局数据版本 v2（迁移前 v' + fromVersion + '）'
      + (report.finishedAt > 0 ? ' · 完成于 ' + this.formatDate(report.finishedAt) : '')
    const lines: string[] = []
    const domains: MigrationDomainResult[] = report.domains
    for (let i: number = 0; i < domains.length; i++) {
      const result: MigrationDomainResult = domains[i]
      const spec: DomainSpec | null = PersistenceCatalog.byId(result.domain)
      const label: string = spec !== null ? spec.label : result.domain
      let detail: string = this.migrationDomainStatusLabel(result.status)
      if (result.items > 0) {
        detail += ' · ' + String(result.items) + ' 条'
      }
      if (result.reason.length > 0) {
        detail += ' · ' + result.reason
      }
      lines.push(label + '：' + detail)
    }
    this.migrationDomainLines = lines
    /*
     * 可重试条件：存在失败域 / 整体 partial 或 failed，**或**仍有"旧键保留且新键无数据"的域
     * （如未登录时跳过的账号镜像域）——后者可在登录后手动重试迁移，不能只依赖下次冷启动。
     */
    this.canRetryMigration = appStore.migrationFailedCount > 0 ||
      report.status === MigrationStatus.PARTIAL || report.status === MigrationStatus.FAILED ||
      appStore.migrationUnsettledCount > 0
    // 旧数据清理
    const legacyCount: number = report.legacyKeys.length
    if (legacyCount === 0) {
      this.legacyCleanupText = '无待清理的旧格式数据'
      this.canCleanupLegacy = false
    } else if (report.legacyCleanupAt <= 0) {
      this.legacyCleanupText = String(legacyCount) + ' 项旧格式数据待清理'
      this.canCleanupLegacy = true
    } else {
      const remainMs: number = report.legacyCleanupAt - Date.now()
      if (remainMs > 0) {
        const remainDays: number = Math.max(1, Math.ceil(remainMs / 86400000))
        this.legacyCleanupText = String(legacyCount) + ' 项旧格式数据将于 '
          + this.formatDate(report.legacyCleanupAt) + ' 自动清理（约 ' + String(remainDays) + ' 天后）'
      } else {
        this.legacyCleanupText = String(legacyCount) + ' 项旧格式数据已到期，可立即清理'
      }
      this.canCleanupLegacy = true
    }
  }

  /** 刷新域健康问题。 */
  private refreshHealth(): void {
    const problems: DomainHealthSnapshot[] = appStore.persistence.health.problems()
    const lines: string[] = []
    const domains: string[] = []
    for (let i: number = 0; i < problems.length; i++) {
      const snapshot: DomainHealthSnapshot = problems[i]
      const spec: DomainSpec | null = PersistenceCatalog.byId(snapshot.domain)
      const label: string = spec !== null ? spec.label : snapshot.domain
      const reasons: string[] = []
      if (snapshot.loadFailed) {
        reasons.push('读取失败')
      }
      if (snapshot.writeFailed) {
        reasons.push('写入失败')
      }
      if (snapshot.droppedItems > 0) {
        reasons.push('跳过 ' + String(snapshot.droppedItems) + ' 条坏数据')
      }
      let text: string = label + '：' + reasons.join('、')
      if (snapshot.lastError.length > 0) {
        text += '（' + snapshot.lastError + '）'
      }
      lines.push(text)
      domains.push(snapshot.domain)
    }
    this.healthProblemLines = lines
    this.healthProblemDomains = domains
  }

  /** 刷新各域存储占用估算。 */
  private async refreshStorage(): Promise<void> {
    if (this.loadingSizes) {
      return
    }
    this.loadingSizes = true
    try {
      const sizes: Record<string, number> = await appStore.persistence.estimateAll()
      const specs: DomainSpec[] = PersistenceCatalog.all()
      const rows: DomainSizeRow[] = []
      let total: number = 0
      for (let i: number = 0; i < specs.length; i++) {
        const spec: DomainSpec = specs[i]
        const bytes: number = sizes[spec.id] ?? 0
        if (bytes <= 0) {
          continue
        }
        total += bytes
        const row: DomainSizeRow = new DomainSizeRow()
        row.domainId = spec.id
        row.label = spec.label
        row.sizeBytes = bytes
        row.sizeText = this.formatSize(bytes)
        /*
         * 4MB 单域预警（设计稿 §4.4/§4.5）：Preferences 单值上限 16MB 的前哨。
         * 页面红字提示用户优先清理该域；同时记一条 warn 日志便于排障。
         */
        row.oversized = isDomainOversized(bytes)
        if (row.oversized) {
          logger.warn('domain exceeds size warn threshold domain=%{public}s bytes=%{public}d',
            spec.id, bytes)
        }
        rows.push(row)
      }
      rows.sort((a: DomainSizeRow, b: DomainSizeRow): number => b.sizeBytes - a.sizeBytes)
      this.domainSizeRows = rows
      this.totalSizeText = this.formatSize(total)
    } catch (e) {
      this.totalSizeText = '统计失败'
    } finally {
      this.loadingSizes = false
    }
  }

  /**
   * 确认修复异常域（会清空该域本地数据，必须二次确认）。
   *
   * @param index - 健康问题行下标（与 `healthProblemDomains` 同序）
   */
  private confirmRepairDomain(index: number): void {
    if (index < 0 || index >= this.healthProblemDomains.length) {
      return
    }
    const domainId: string = this.healthProblemDomains[index]
    const spec: DomainSpec | null = PersistenceCatalog.byId(domainId)
    const label: string = spec !== null ? spec.label : domainId
    const cacheLike: boolean = spec !== null && spec.rebuildable
    /*
     * 文案按域语义区分（评审 R-A11）：缓存/镜像域是"清空后由服务端重建"，用户数据域是
     * "删除本地数据"（不会被重建），不能统一写"重建"误导用户。
     */
    const message: string = cacheLike
      ? '将清空「' + label + '」的本地缓存（不可撤销）；之后由服务端重新获取/重建。'
      : '将删除「' + label + '」的全部本地数据（不可撤销，不会自动重建），请确认。'
    try {
      this.getUIContext().showAlertDialog({
        title: '修复「' + label + '」？',
        message: message,
        primaryButton: {
          value: '清空',
          action: (): void => {
            this.repairDomain(domainId)
          }
        },
        secondaryButton: {
          value: '取消',
          action: (): void => {
          }
        }
      })
    } catch (e) {
      /*
       * 弹窗不可用时**不得**直接执行清盘（评审 R-A11）：清空是破坏性操作，必须经过确认。
       * 这里只提示用户稍后重试。
       */
      appStore.showToast('无法打开确认弹窗，请稍后重试')
    }
  }

  /**
   * 执行修复：清空该域磁盘数据 → 重载内存 → 清健康标记。
   *
   * @param domainId - 域 ID
   */
  private async repairDomain(domainId: string): Promise<void> {
    try {
      const message: string = await appStore.repairDomain(domainId)
      // 空串=成功；非空是失败/提示原因（刷新失败/未登录镜像域/不可修复）
      appStore.showToast(message.length === 0 ? '已修复该数据域' : message)
      this.refreshAll()
    } catch (e) {
      appStore.showToast('修复失败：' + formatError(e))
    }
  }

  // ============== 迁移操作 ==============

  /** 重试迁移（幂等，已完成域会跳过）。 */
  private async retryMigration(): Promise<void> {
    if (this.retryingMigration) {
      return
    }
    this.retryingMigration = true
    appStore.showToast('正在重试升级…')
    try {
      await appStore.retryMigration()
      appStore.showToast('升级重试完成')
      this.refreshAll()
    } catch (e) {
      appStore.showToast('重试失败：' + formatError(e))
    } finally {
      this.retryingMigration = false
    }
  }

  /** 立即清理旧格式数据。 */
  private async cleanupLegacy(): Promise<void> {
    if (this.cleaningLegacy) {
      return
    }
    this.cleaningLegacy = true
    try {
      const removed: number = await appStore.cleanupLegacyData(true)
      appStore.showToast(removed > 0 ? '已清理 ' + String(removed) + ' 项旧数据' : '没有可清理的旧数据')
      this.refreshAll()
    } catch (e) {
      appStore.showToast('清理失败：' + formatError(e))
    } finally {
      this.cleaningLegacy = false
    }
  }

  // ============== 导出 ==============

  /**
   * 导出弹窗副标题。
   *
   * 迁移未完成（FAILED/DEFERRED）时追加警示：这些域的旧键数据尚未搬进新命名空间，
   * 导出只读新键 → 备份会缺这些域；若随后清空数据，旧键数据会被删除（审计 EXP-03/DES-02）。
   *
   * @returns 副标题文案
   */
  private exportSecondaryTitle(): string {
    const base: string = '选择要导出的数据域。未加密文件包含浏览历史、AI 对话等隐私内容，建议保持加密。'
    const unsettled: number = appStore.migrationUnsettledCount
    if (unsettled > 0) {
      return '有 ' + String(unsettled) + ' 个数据域尚未完成升级，其旧数据不会包含在备份中'
        + '（建议先到上方「重试升级」）。\n' + base
    }
    return base
  }

  /** 打开导出弹窗（重置勾选、口令与分组列表）。 */
  private openExportDialog(): void {
    const specs: DomainSpec[] = PersistenceCatalog.exportable()
    const ids: string[] = []
    const selected: string[] = []
    for (let i: number = 0; i < specs.length; i++) {
      const spec: DomainSpec = specs[i]
      ids.push(spec.id)
      if (spec.exportPolicy === ExportPolicy.INCLUDE) {
        selected.push(spec.id)
      }
    }
    this.exportDomainIds = ids
    this.exportSelectedIds = selected
    this.exportRows = this.buildExportRows(specs)
    this.exportDomainSizes = {}
    this.exportEncrypt = true
    this.exportPassword = ''
    this.exportRunning = false
    this.exportProgressText = ''
    this.exportDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '导出数据',
        secondaryTitle: this.exportSecondaryTitle(),
        contentBuilder: (): void => {
          this.ExportDialogContent()
        }
      }),
      autoCancel: true
    })
    this.exportDialogController.open()
    // 体积统计较慢（逐域读盘估价），异步填充，不阻塞弹窗打开
    this.loadExportDomainSizes()
  }

  /**
   * 构建导出弹窗列表（六组分类 + 未分组兜底）。
   *
   * @param specs - 可导出域
   * @returns 列表行（组标题 + 域行）
   */
  private buildExportRows(specs: DomainSpec[]): ExportRow[] {
    const rows: ExportRow[] = []
    const groupedIds: string[] = []
    for (let g: number = 0; g < EXPORT_GROUPS.length; g++) {
      const def: ExportGroupDef = EXPORT_GROUPS[g]
      const domainRows: ExportRow[] = []
      for (let i: number = 0; i < def.domainIds.length; i++) {
        const domainId: string = def.domainIds[i]
        let exists: boolean = false
        for (let s: number = 0; s < specs.length; s++) {
          if (specs[s].id === domainId) {
            exists = true
            break
          }
        }
        if (!exists) {
          continue
        }
        groupedIds.push(domainId)
        const row: ExportRow = new ExportRow()
        row.kind = 'domain'
        row.domainId = domainId
        domainRows.push(row)
      }
      if (domainRows.length === 0) {
        continue
      }
      const header: ExportRow = new ExportRow()
      header.kind = 'group'
      header.text = def.title
      rows.push(header)
      for (let r: number = 0; r < domainRows.length; r++) {
        rows.push(domainRows[r])
      }
    }
    // 兜底：新增域忘记登记分组时也不能从列表里消失（域对等性红线）
    const others: ExportRow[] = []
    for (let s: number = 0; s < specs.length; s++) {
      if (groupedIds.indexOf(specs[s].id) >= 0) {
        continue
      }
      const row: ExportRow = new ExportRow()
      row.kind = 'domain'
      row.domainId = specs[s].id
      others.push(row)
    }
    if (others.length > 0) {
      const header: ExportRow = new ExportRow()
      header.kind = 'group'
      header.text = '其它'
      rows.push(header)
      for (let r: number = 0; r < others.length; r++) {
        rows.push(others[r])
      }
    }
    return rows
  }

  /**
   * 异步加载导出弹窗的每域体积文案（不阻塞弹窗打开）。
   */
  private async loadExportDomainSizes(): Promise<void> {
    try {
      const sizes: Record<string, number> = await appStore.persistence.estimateAll()
      const text: Record<string, string> = {}
      const specs: DomainSpec[] = PersistenceCatalog.all()
      for (let i: number = 0; i < specs.length; i++) {
        const spec: DomainSpec = specs[i]
        const bytes: number = sizes[spec.id] ?? 0
        text[spec.id] = bytes > 0 ? this.formatSize(bytes) : '无数据'
      }
      this.exportDomainSizes = text
    } catch (e) {
      this.exportDomainSizes = {}
    }
  }

  /**
   * 判断域是否被勾选。
   *
   * @param id - 域 ID
   * @returns 是否勾选
   */
  private isExportDomainSelected(id: string): boolean {
    return this.exportSelectedIds.indexOf(id) >= 0
  }

  /**
   * 切换域勾选。
   *
   * @param id - 域 ID
   * @param selected - 是否勾选
   */
  private toggleExportDomain(id: string, selected: boolean): void {
    const next: string[] = []
    for (let i: number = 0; i < this.exportSelectedIds.length; i++) {
      if (this.exportSelectedIds[i] !== id) {
        next.push(this.exportSelectedIds[i])
      }
    }
    if (selected) {
      next.push(id)
    }
    this.exportSelectedIds = next
  }

  /**
   * 取域显示名。
   *
   * @param id - 域 ID
   * @returns 域名
   */
  private exportLabelOf(id: string): string {
    const spec: DomainSpec | null = PersistenceCatalog.byId(id)
    return spec !== null ? spec.label : id
  }

  /**
   * 取域说明（导出弹窗副标题）。
   *
   * @param id - 域 ID
   * @returns 说明
   */
  private exportNoteOf(id: string): string {
    const spec: DomainSpec | null = PersistenceCatalog.byId(id)
    return spec !== null ? spec.note : ''
  }

  /** 判断导出按钮可用：至少一个域且加密口令合法。 */
  private isExportReady(): boolean {
    if (this.exportRunning) {
      return false
    }
    if (this.exportSelectedIds.length === 0) {
      return false
    }
    if (this.exportEncrypt && this.exportPassword.trim().length < 8) {
      return false
    }
    return true
  }

  /**
   * 当前勾选是否包含敏感数据域（AI 对话历史 / 浏览历史）。
   *
   * @returns 是否包含敏感域
   */
  private hasSensitiveSelection(): boolean {
    return this.exportSelectedIds.indexOf(DomainIds.AI_SESSIONS) >= 0 ||
      this.exportSelectedIds.indexOf(DomainIds.HISTORY) >= 0
  }

  /** 执行导出：生成容器文本 → 选择保存位置 → 写文件。 */
  private async runExport(): Promise<void> {
    if (!this.isExportReady()) {
      return
    }
    this.exportRunning = true
    this.exportProgressText = '正在收集数据…'
    try {
      const options: BackupExportOptions = new BackupExportOptions()
      options.domainIds = this.exportSelectedIds.slice()
      options.encrypt = this.exportEncrypt
      options.password = this.exportPassword
      const result: BackupExportResult = await appStore.dataTransfer.exportBackup(options,
        (done: number, total: number, domainId: string): void => {
          // 域级进度（设计稿 §6.3）：逐域更新，避免大备份长时间无反馈
          this.exportProgressText = '正在收集：' + this.exportLabelOf(domainId)
            + '（' + String(done) + '/' + String(total) + '）'
        })
      if (!result.ok) {
        appStore.showToast(result.error.length > 0 ? result.error : '导出失败')
        return
      }
      this.exportProgressText = '请选择保存位置…'
      const context: common.UIAbilityContext | null = this.currentContext()
      if (context === null) {
        appStore.showToast('无法获取文件保存器')
        return
      }
      const fileName: string = 'nga-backup-' + this.timestampForFileName() + '.' + BACKUP_SUFFIX
      const uri: string = await pickDocumentToSave(context, fileName, BACKUP_SUFFIX)
      if (uri.length === 0) {
        appStore.showToast('已取消保存')
        return
      }
      this.exportProgressText = '正在写入文件…'
      const written: boolean = await writeTextToUri(uri, result.content)
      if (!written) {
        appStore.showToast('写入文件失败，请重试')
        return
      }
      /*
       * 写入后立即回读校验：真机曾出现"写入返回成功但文件内容不完整"，
       * 若不做回读，用户会拿到一个无法导入的备份文件（且原数据可能已清空）。
       */
      this.exportProgressText = '正在校验文件…'
      const readBack: string | null = readTextFromUri(uri, 0)
      if (readBack === null || readBack !== result.content) {
        appStore.showToast('备份文件写入不完整（校验失败），请重试或更换保存位置')
        return
      }
      this.exportDialogController?.close()
      appStore.showToast('已导出 ' + String(result.domainCount) + ' 个数据域'
        + (result.encrypted ? '（已加密）' : '（未加密）') + ' · ' + this.formatSize(result.bytes))
      // 记录导出历史（只记元数据；写入文件并回读校验通过后才算一次成功导出）
      const exportHistory: TransferHistoryEntry = new TransferHistoryEntry()
      exportHistory.kind = TransferHistoryKind.EXPORT
      exportHistory.at = Date.now()
      exportHistory.encrypted = result.encrypted
      exportHistory.domainCount = result.domainCount
      exportHistory.bytes = result.bytes
      exportHistory.skippedDomains = result.omitted.length
      exportHistory.ok = true
      exportHistory.note = result.omitted.length > 0
        ? String(result.omitted.length) + ' 个域未包含'
        : ''
      await appStore.dataTransfer.recordTransferHistory(exportHistory)
      this.refreshTransferHistory()
      /*
       * 勾选了但没进备份的域必须让用户看见（审计 EXP-01/EXP-02）：无数据、读取失败、
       * 单域超 8MB 被截断、镜像域属于其他账号……此前的实现全部静默省略，
       * 用户会误以为备份是完整的，随后清空数据才发现丢域。
       */
      if (result.omitted.length > 0) {
        this.showOmittedDomains(result.omitted)
      }
    } catch (e) {
      appStore.showToast('导出失败：' + formatError(e))
    } finally {
      this.exportRunning = false
      this.exportProgressText = ''
    }
  }

  /**
   * 展示「勾选但未包含在备份中」的域清单。
   *
   * @param omitted - 未包含的域列表（含原因）
   */
  private showOmittedDomains(omitted: SkippedDomain[]): void {
    const lines: string[] = []
    for (let i: number = 0; i < omitted.length; i++) {
      const item: SkippedDomain = omitted[i]
      const name: string = item.label.length > 0 ? item.label : item.domainId
      lines.push('· ' + name + '：' + item.reason)
    }
    try {
      this.getUIContext().showAlertDialog({
        title: '以下 ' + String(omitted.length) + ' 个数据域未包含在备份中',
        message: lines.join('\n'),
        primaryButton: {
          value: '知道了',
          action: (): void => {
          }
        }
      })
    } catch (e) {
      appStore.showToast('有 ' + String(omitted.length) + ' 个数据域未包含在备份中（详见日志）')
    }
  }

  // ============== 导入 ==============

  /** 选择备份文件并解析。 */
  private async handleImport(): Promise<void> {
    if (this.importing) {
      return
    }
    const context: common.UIAbilityContext | null = this.currentContext()
    if (context === null) {
      appStore.showToast('无法获取文件选择器')
      return
    }
    try {
      const picked: PickedDocument[] = await pickDocumentToRead(context, 1)
      if (picked.length === 0) {
        return
      }
      const readResult: ReadTextResult =
        readTextFromUriDetailed(picked[0].uri, MAX_BACKUP_BYTES, context.cacheDir)
      if (!readResult.ok) {
        appStore.showToast('读取文件失败：' + readResult.error)
        return
      }
      const content: string = readResult.content
      if (content.length === 0) {
        appStore.showToast('文件为空')
        return
      }
      this.importing = true
      this.importStageText = '正在解析备份文件…'
      this.pendingContent = content
      const outcome: ParseOutcome = await appStore.dataTransfer.parseBackup(content, '')
      if (outcome.ok && outcome.container !== null) {
        if (outcome.warning.length > 0) {
          // 非阻断警告（如 checksum 不一致/超大域被跳过）：提示后继续走导入计划
          appStore.showToast(outcome.warning)
        }
        await this.buildPlanAndShow(outcome.container, outcome.droppedDomains)
        return
      }
      if (outcome.needPassword) {
        this.openImportPasswordDialog()
        return
      }
      appStore.showToast(outcome.error.length > 0 ? outcome.error : '解析失败')
    } catch (e) {
      appStore.showToast('导入失败：' + formatError(e))
    } finally {
      this.importing = false
      this.importStageText = ''
    }
  }

  /** 打开导入口令弹窗（加密备份）。 */
  private openImportPasswordDialog(): void {
    this.importPassword = ''
    this.importPasswordController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '输入解密密码',
        secondaryTitle: '这是导出时设置的加密密码（至少 8 位）。',
        contentBuilder: (): void => {
          this.ImportPasswordContent()
        }
      }),
      autoCancel: true
    })
    this.importPasswordController.open()
  }

  /**
   * 用口令继续解析加密备份。
   *
   * @param password - 用户输入口令
   */
  private async continueImportWithPassword(password: string): Promise<void> {
    this.importPasswordController?.close()
    this.importing = true
    this.importStageText = '正在解析备份文件…'
    try {
      const outcome: ParseOutcome = await appStore.dataTransfer.parseBackup(this.pendingContent, password)
      if (!outcome.ok || outcome.container === null) {
        appStore.showToast(outcome.error.length > 0 ? outcome.error : '解密失败')
        return
      }
      if (outcome.warning.length > 0) {
        appStore.showToast(outcome.warning)
      }
      await this.buildPlanAndShow(outcome.container, outcome.droppedDomains)
    } catch (e) {
      appStore.showToast('解密失败：' + formatError(e))
    } finally {
      this.importing = false
      this.importStageText = ''
    }
  }

  /**
   * 生成导入计划并打开确认弹窗。
   *
   * @param container - 解析出的明文容器
   * @param droppedDomains - 解析阶段被丢弃的域（必须在计划里可见）
   */
  private async buildPlanAndShow(container: BackupContainer,
    droppedDomains: SkippedDomain[]): Promise<void> {
    this.pendingContainer = container
    this.pendingDroppedDomains = droppedDomains
    /* 每次新的导入都从「默认恢复缓存」开始，避免上一次关闭开关静默影响本次（审计 IMP-06） */
    this.restoreCacheDomains = true
    const plan: ImportPlan = await appStore.dataTransfer.buildImportPlan(container,
      this.restoreCacheDomains, droppedDomains)
    this.applyPlanToDialog(plan)
    /*
     * 即使没有可执行的变更（备份中的域全部被跳过/无变化），也要打开计划弹窗展示原因：
     * 否则用户只看到笼统的「没有可导入的新数据」，看不到「未登录请先登录」「缓存默认跳过」
     * 等可操作的原因（审计 IMP-04）。
     */
    this.openImportPlanDialog()
  }

  /**
   * 把计划写入弹窗状态（摘要 / 行 / 是否可执行 / 待执行计划）。
   *
   * @param plan - 导入计划
   */
  private applyPlanToDialog(plan: ImportPlan): void {
    this.importPlanSummary = this.buildPlanSummary(plan)
    this.importPlanLines = this.buildPlanLines(plan)
    this.importPlanApplicable = plan.ok
    this.pendingPlan = plan.ok ? plan : null
  }

  /**
   * 切换「恢复缓存类数据」后重新构建导入计划（不关闭弹窗）。
   */
  private async rebuildImportPlan(): Promise<void> {
    const container: BackupContainer | null = this.pendingContainer
    if (container === null) {
      return
    }
    try {
      const plan: ImportPlan = await appStore.dataTransfer.buildImportPlan(container,
        this.restoreCacheDomains, this.pendingDroppedDomains)
      this.applyPlanToDialog(plan)
      // 计划是否可执行由 applyPlanToDialog 写入；不可执行时确认按钮自动置灰，
      // 不能保留旧计划（否则用户关掉缓存恢复后点确认仍会执行旧计划，审计 IMP-05）。
    } catch (e) {
      // 重建失败：清空待执行计划，避免「显示旧计划 + 执行旧计划」
      this.pendingPlan = null
      this.importPlanApplicable = false
      this.importPlanLines = []
      this.importPlanSummary = ''
      appStore.showToast('重建导入计划失败：' + formatError(e))
    }
  }

  /** 计划摘要文案。 */
  private buildPlanSummary(plan: ImportPlan): string {
    const changed: number = plan.changedDomainCount()
    if (changed === 0) {
      return plan.error.length > 0 ? plan.error
        : '备份导出于 ' + this.formatDate(plan.exportedAt) + ' · 没有可应用的数据域（原因见列表）'
    }
    return '备份导出于 ' + this.formatDate(plan.exportedAt)
      + ' · 应用版本 ' + (plan.appVersionName.length > 0 ? plan.appVersionName : '未知')
      + ' · 可导入域 ' + String(changed) + ' 个'
  }

  /** 把计划条目转成展示行。 */
  private buildPlanLines(plan: ImportPlan): ImportPlanLine[] {
    const lines: ImportPlanLine[] = []
    const entries: ImportPlanEntry[] = plan.entries
    for (let i: number = 0; i < entries.length; i++) {
      const entry: ImportPlanEntry = entries[i]
      const line: ImportPlanLine = new ImportPlanLine()
      line.label = entry.label.length > 0 ? entry.label : entry.domainId
      if (entry.willSkip) {
        line.willSkip = true
        line.detail = entry.reason.length > 0 ? entry.reason : '跳过（缓存或策略不允许）'
      } else if (entry.added === 0 && entry.updated === 0) {
        line.willSkip = true
        line.detail = '无变化（不会写入）'
      } else if (entry.policy === ImportPolicy.SKIP) {
        // 缓存/镜像域：按备份内容整体覆盖恢复，没有「新增/更新」的合并语义
        line.detail = '覆盖恢复 ' + String(entry.added) + ' 条（整体替换本机该缓存）'
      } else {
        line.detail = '新增 ' + String(entry.added) + ' 条 · 更新 ' + String(entry.updated) + ' 条'
      }
      // 非跳过条目也可能带提示（如「来源账号未知，将按当前账号恢复」）
      if (!line.willSkip && entry.reason.length > 0) {
        line.detail = line.detail + '（' + entry.reason + '）'
      }
      lines.push(line)
    }
    return lines
  }

  /** 打开导入计划确认弹窗。 */
  private openImportPlanDialog(): void {
    this.importPlanController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '确认导入',
        secondaryTitle: this.importPlanSummary,
        contentBuilder: (): void => {
          this.ImportPlanContent()
        }
      }),
      autoCancel: true
    })
    this.importPlanController.open()
  }

  /** 应用导入计划。 */
  private async applyPendingImport(): Promise<void> {
    const plan: ImportPlan | null = this.pendingPlan
    if (plan === null) {
      return
    }
    this.importPlanController?.close()
    this.pendingPlan = null
    this.importing = true
    this.importStageText = '正在导入…'
    try {
      const result: ImportResult = await appStore.dataTransfer.applyImport(plan)
      /*
       * 只要**有域写入成功**就必须重载内存：部分失败时若只提示不重载，已写入的域仍是旧内存快照，
       * 用户随后改任一设置会把旧快照整体写回磁盘，静默覆盖刚导入的数据。
       */
      let reloadFailed: string[] = []
      if (result.appliedDomains > 0) {
        reloadFailed = await appStore.reloadAfterImport()
      }
      if (result.ok && reloadFailed.length === 0) {
        appStore.showToast('导入完成：应用 ' + String(result.appliedDomains) + ' 个域，新增 '
          + String(result.added) + ' 条，更新 ' + String(result.updated) + ' 条')
      } else if (result.ok) {
        // 写盘成功但部分 Store 内存重载失败：提示重启，避免用户以为界面数据"没变"
        appStore.showToast('数据已导入，但 ' + String(reloadFailed.length)
          + ' 个模块刷新失败（' + reloadFailed.join('/') + '），建议重启应用后查看')
      } else {
        const failedList: string = result.failedDomains.length > 0
          ? '（失败域：' + result.failedDomains.join('、') + '）' : ''
        appStore.showToast('导入未全部成功：' + (result.error.length > 0 ? result.error : '未知错误')
          + failedList)
      }
      // 记录导入历史（只记元数据：域数/新增/更新/跳过/结果）
      const importHistory: TransferHistoryEntry = new TransferHistoryEntry()
      importHistory.kind = TransferHistoryKind.IMPORT
      importHistory.at = Date.now()
      importHistory.domainCount = plan.entries.length
      importHistory.bytes = this.pendingContent.length
      importHistory.added = result.added
      importHistory.updated = result.updated
      importHistory.skippedDomains = result.skippedDomains
      importHistory.ok = result.ok && reloadFailed.length === 0
      importHistory.note = result.ok
        ? (reloadFailed.length > 0 ? '部分模块刷新失败' : '')
        : (result.error.length > 0 ? result.error : '部分失败')
      await appStore.dataTransfer.recordTransferHistory(importHistory)
      this.refreshAll()
    } catch (e) {
      appStore.showToast('导入失败：' + formatError(e))
    } finally {
      this.importing = false
      this.importStageText = ''
    }
  }

  // ============== 清空 ==============

  /**
   * 清空弹窗副标题。
   *
   * 迁移未完成时明确告警：旧键里的数据尚未迁移，清空会删除旧键且不在任何备份中
   * （审计 DES-02）。同时补充媒体缓存也会被删除的口径（DES-14）。
   *
   * @returns 副标题文案
   */
  private clearSecondaryTitle(): string {
    const base: string = '此操作不可恢复。登录凭证不受影响，但设置、浏览历史、阅读进度、AI 会话、'
      + '草稿、离线存档、草稿图片/视频副本与动态照片缓存将全部删除。'
    const unsettled: number = appStore.migrationUnsettledCount
    if (unsettled > 0) {
      return '⚠️ 有 ' + String(unsettled) + ' 个数据域尚未完成升级：清空会连同它们的旧数据一起删除，'
        + '且这些数据不在任何备份中。建议先「重试升级」或先导出数据。\n' + base
    }
    return base
  }

  /** 打开清空确认弹窗。 */
  private openClearDialog(): void {
    this.clearInput = ''
    this.clearDialogController = new CustomDialogController({
      backgroundColor: Color.Transparent,
      systemMaterial: UIMaterialManager.dialogMaterial,
      maskColor: UIMaterialManager.scrim,
      builder: CustomContentDialog({
        primaryTitle: '清空本地数据',
        secondaryTitle: this.clearSecondaryTitle(),
        contentBuilder: (): void => {
          this.ClearDataContent()
        }
      }),
      autoCancel: true
    })
    this.clearDialogController.open()
  }

  /** 执行清空全部可清空数据。 */
  private async runClearAll(): Promise<void> {
    if (this.clearInput !== CLEAR_CONFIRM_WORD || this.clearingData) {
      return
    }
    this.clearDialogController?.close()
    this.clearingData = true
    try {
      const count: number = await appStore.clearAllLocalData()
      appStore.showToast('已清空 ' + String(count) + ' 个数据域')
      this.clearInput = ''
      this.refreshAll()
    } catch (e) {
      appStore.showToast('清空失败：' + formatError(e))
    } finally {
      this.clearingData = false
    }
  }

  // ============== 工具方法 ==============

  /**
   * 迁移总体状态文案。
   *
   * @param status - MigrationStatus 值
   * @returns 中文文案
   */
  private migrationStatusLabel(status: string): string {
    if (status === MigrationStatus.COMPLETED) {
      return '升级完成'
    }
    if (status === MigrationStatus.NOT_REQUIRED) {
      return '无需升级（全新安装）'
    }
    if (status === MigrationStatus.PARTIAL) {
      return '部分完成（存在失败/延迟域）'
    }
    if (status === MigrationStatus.FAILED) {
      return '升级失败'
    }
    return '尚未执行'
  }

  /**
   * 单域迁移状态文案。
   *
   * @param status - MigrationDomainStatus 值
   * @returns 中文文案
   */
  private migrationDomainStatusLabel(status: string): string {
    if (status === 'migrated') {
      return '已升级'
    }
    if (status === 'skipped') {
      return '已跳过'
    }
    if (status === 'failed') {
      return '失败'
    }
    if (status === 'deferred') {
      return '延后处理'
    }
    return status.length > 0 ? status : '未知'
  }

  /**
   * 格式化字节数。
   *
   * @param bytes - 字节数
   * @returns 可读文案
   */
  private formatSize(bytes: number): string {
    if (bytes <= 0) {
      return '0 B'
    }
    if (bytes < 1024) {
      return String(bytes) + ' B'
    }
    const kb: number = bytes / 1024
    if (kb < 1024) {
      return kb.toFixed(1) + ' KB'
    }
    const mb: number = kb / 1024
    if (mb < 1024) {
      return mb.toFixed(1) + ' MB'
    }
    return (mb / 1024).toFixed(2) + ' GB'
  }

  /**
   * 格式化日期（YYYY-MM-DD）。
   *
   * @param timestamp - 毫秒时间戳
   * @returns 日期文案；非法值返回「—」
   */
  private formatDate(timestamp: number): string {
    if (timestamp <= 0) {
      return '—'
    }
    const date: Date = new Date(timestamp)
    return String(date.getFullYear()) + '-' + this.pad2(date.getMonth() + 1) + '-'
      + this.pad2(date.getDate())
  }

  /**
   * 生成导出文件名用的时间戳（YYYYMMDD-HHmmss）。
   *
   * @returns 时间戳文本
   */
  private timestampForFileName(): string {
    const date: Date = new Date()
    return String(date.getFullYear()) + this.pad2(date.getMonth() + 1) + this.pad2(date.getDate())
      + '-' + this.pad2(date.getHours()) + this.pad2(date.getMinutes()) + this.pad2(date.getSeconds())
  }

  /**
   * 两位补零。
   *
   * @param value - 数值
   * @returns 两位字符串
   */
  private pad2(value: number): string {
    return value < 10 ? '0' + String(value) : String(value)
  }

  // ============== 页面结构 ==============

  /**
   * 构建数据管理页。
   */
  build() {
    Stack() {
      Column() {
        Scroll(this.scroller) {
          Column() {
            this.MigrationSection()
            if (this.healthProblemLines.length > 0) {
              this.HealthSection()
            }
            this.StorageSection()
            this.HistorySection()
            this.ActionSection()
            this.SchedulerSection()
            this.DangerSection()
          }
          .width('100%').alignItems(HorizontalAlign.Center).padding({ bottom: 32 })
        }
        .layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
          {
            fractionStops: TitleScrollEffect.getBlurStops(this.scrollViewportHeight, this.statusBarHeight),
            direction: GradientDirection.Bottom
          }
        )
        .onAreaChange((oldValue: Area, newValue: Area): void => {
          if (typeof newValue.height === 'number' && newValue.height !== this.scrollViewportHeight) {
            this.scrollViewportHeight = newValue.height
          }
        })
        .onDidScroll((): void => {
          this.syncTitleScrollEffect()
        })
        .onAppear((): void => {
          this.syncTitleScrollEffect()
        })
      }
      .width('100%').height('100%').backgroundColor(AppColors.bg)

      PanelNavBar({ title: '数据管理', scrollEffectProgress: this.titleScrollEffectProgress })
        .width('100%').position({ x: 0, y: 0 })
    }
    .width('100%').height('100%')
  }

  // ============== 区块：数据版本与迁移 ==============

  @Builder
  MigrationSection() {
    Column() {
      Text('数据版本与迁移').fontSize(15).fontColor(AppColors.textSecondary)
        .width('100%').padding({ bottom: 10 })

      Row() {
        Text('整体状态').fontSize(15).fontColor(AppColors.textPrimary).layoutWeight(1)
        Text(this.migrationStatusText).fontSize(14).fontColor(AppColors.textSecondary)
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 4 })
      .alignItems(VerticalAlign.Center)

      if (this.migrationSubText.length > 0) {
        Text(this.migrationSubText).fontSize(12).fontColor(AppColors.textTertiary)
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
          .lineHeight(17)
      }

      if (this.migrationDomainLines.length > 0) {
        Divider().margin({ left: 16, right: 16 }).color(AppColors.separator)
        ForEach(this.migrationDomainLines, (line: string) => {
          Text(line).fontSize(12).fontColor(AppColors.textTertiary)
            .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .lineHeight(17)
        }, (line: string, index: number): string => line + '#' + String(index))
      }

      if (this.migrationDomainLines.length > 0) {
        Divider().margin({ left: 16, right: 16 }).color(AppColors.separator)
      }

      if (this.legacyCleanupText.length > 0) {
        Text(this.legacyCleanupText).fontSize(12).fontColor(AppColors.textTertiary)
          .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })
          .lineHeight(17)
      }

      if (this.canCleanupLegacy || this.canRetryMigration) {
        Row() {
          if (this.canRetryMigration) {
            Button(this.retryingMigration ? '重试中…' : '重试升级')
              .fontSize(14).height(36).layoutWeight(1)
              .backgroundColor(AppColors.primary).fontColor(AppColors.white)
              .enabled(!this.retryingMigration && !this.cleaningLegacy)
              .onClick((): void => {
                this.retryMigration()
              })
          }
          if (this.canCleanupLegacy) {
            Button(this.cleaningLegacy ? '清理中…' : '立即清理')
              .fontSize(14).height(36).layoutWeight(1)
              .backgroundColor(AppColors.bgSecondary).fontColor(AppColors.textPrimary)
              .enabled(!this.cleaningLegacy && !this.retryingMigration)
              .margin({ left: this.canRetryMigration ? 12 : 0 })
              .onClick((): void => {
                this.cleanupLegacy()
              })
          }
        }
        .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 14 })
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：数据健康 ==============

  @Builder
  HealthSection() {
    Column() {
      Text('数据健康').fontSize(15).fontColor(AppColors.textSecondary)
        .width('100%').padding({ bottom: 10 })

      Text('以下数据域最近出现读写异常，可尝试「修复」（清空该域并重建）或重新进入页面。')
        .fontSize(12).fontColor(AppColors.warning).width('100%').lineHeight(17)

      ForEach(this.healthProblemLines, (line: string, index: number) => {
        Column() {
          Text(line).fontSize(12).fontColor(AppColors.destructive)
            .width('100%').lineHeight(17)
          Row() {
            Button('修复')
              .fontSize(12).height(28).padding({ left: 14, right: 14 })
              .backgroundColor(AppColors.bgSecondary).fontColor(AppColors.textPrimary)
              .onClick((): void => {
                this.confirmRepairDomain(index)
              })
          }
          .width('100%').justifyContent(FlexAlign.End).padding({ top: 6 })
        }
        .width('100%').padding({ top: 6, bottom: 6 })
      }, (line: string, index: number): string => line + '#' + String(index))
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：最近导出 / 导入 ==============

  @Builder
  HistorySection() {
    Column() {
      Text('最近导出 / 导入').fontSize(15).fontColor(AppColors.textSecondary)
        .width('100%').padding({ bottom: 8 })

      if (this.transferHistoryLines.length === 0) {
        Text('暂无记录（只保留最近 10 次，不记录任何数据内容）').fontSize(12)
          .fontColor(AppColors.textTertiary).width('100%').lineHeight(17)
      } else {
        ForEach(this.transferHistoryLines, (line: string) => {
          Text(line).fontSize(12).fontColor(AppColors.textTertiary)
            .width('100%').padding({ top: 4, bottom: 4 }).lineHeight(17)
        }, (line: string, index: number): string => line + '#' + String(index))
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：后台任务调度 ==============

  @Builder
  SchedulerSection() {
    Column() {
      Row() {
        Text('后台任务调度').fontSize(15).fontColor(AppColors.textSecondary).layoutWeight(1)
        Text(this.schedulerExpanded ? '收起' : '展开').fontSize(13).fontColor(AppColors.primary)
          .onClick((): void => {
            this.schedulerExpanded = !this.schedulerExpanded
          })
      }
      .width('100%').padding({ bottom: 6 }).alignItems(VerticalAlign.Center)

      if (this.schedulerExpanded) {
        if (this.schedulerLines.length === 0) {
          Text('暂无任务状态').fontSize(12).fontColor(AppColors.textTertiary).width('100%')
        } else {
          ForEach(this.schedulerLines, (line: string) => {
            Text(line).fontSize(12).fontColor(AppColors.textTertiary)
              .width('100%').padding({ top: 3, bottom: 3 }).lineHeight(16)
          }, (line: string, index: number): string => line + '#' + String(index))
        }
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：存储占用 ==============

  @Builder
  StorageSection() {
    Column() {
      Row() {
        Text('存储占用').fontSize(15).fontColor(AppColors.textSecondary).layoutWeight(1)
        Text(this.loadingSizes ? '统计中…' : '刷新统计').fontSize(13).fontColor(AppColors.primary)
          .onClick((): void => {
            this.refreshStorage()
          })
      }
      .width('100%').padding({ bottom: 6 })

      if (this.domainSizeRows.length === 0) {
        Text(this.loadingSizes ? '正在统计…' : '暂无本地数据').fontSize(13)
          .fontColor(AppColors.textTertiary).width('100%').padding({ top: 6, bottom: 6 })
      } else {
        ForEach(this.domainSizeRows, (row: DomainSizeRow) => {
          Row() {
            Column() {
              Text(row.label).fontSize(14)
                .fontColor(row.oversized ? AppColors.warning : AppColors.textPrimary)
                .width('100%')
              if (row.oversized) {
                Text('⚠ 超过 4MB 单域预警阈值（可在「清除缓存」或「清空本地数据」中处理）').fontSize(11)
                  .fontColor(AppColors.warning).width('100%').margin({ top: 1 })
              }
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(row.sizeText).fontSize(13)
              .fontColor(row.oversized ? AppColors.warning : AppColors.textSecondary)
          }
          .width('100%').padding({ top: 6, bottom: 6 }).alignItems(VerticalAlign.Center)
        }, (row: DomainSizeRow): string => row.domainId + '|' + String(row.sizeBytes))

        Divider().color(AppColors.separator).margin({ top: 4, bottom: 4 })
        Row() {
          Text('合计').fontSize(14).fontColor(AppColors.textPrimary).fontWeight(FontWeight.Medium).layoutWeight(1)
          Text(this.totalSizeText).fontSize(13).fontColor(AppColors.textSecondary)
        }
        .width('100%').padding({ top: 4, bottom: 4 })
      }
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：导出 / 导入 ==============

  @Builder
  ActionSection() {
    Column() {
      Row() {
        Column() {
          Text('导出数据').fontSize(15).fontColor(AppColors.textPrimary)
          Text('选择数据域导出为备份文件，可加密').fontSize(12).fontColor(AppColors.textTertiary)
            .margin({ top: 2 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('导出').fontSize(14).fontColor(AppColors.primary).fontWeight(FontWeight.Medium)
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.openExportDialog()
      })

      Divider().margin({ left: 16, right: 16 }).color(AppColors.separator)

      Row() {
        Column() {
          Text('导入数据').fontSize(15).fontColor(AppColors.textPrimary)
          Text(this.importing ? this.importStageText : '从备份文件恢复，冲突按较新合并').fontSize(12)
            .fontColor(AppColors.textTertiary).margin({ top: 2 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Text('导入').fontSize(14)
          .fontColor(this.importing ? AppColors.textTertiary : AppColors.primary)
          .fontWeight(FontWeight.Medium)
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        if (!this.importing) {
          this.handleImport()
        }
      })
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding({ top: 2, bottom: 2 })
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 区块：危险区 ==============

  @Builder
  DangerSection() {
    Column() {
      Text('危险操作').fontSize(15).fontColor(AppColors.textSecondary)
        .width('100%').padding({ bottom: 6 })

      Row() {
        Column() {
          Text('清空本地数据').fontSize(15).fontColor(AppColors.destructive)
          Text('删除本机全部可清空数据（保留登录凭证）').fontSize(12)
            .fontColor(AppColors.textTertiary).margin({ top: 2 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick((): void => {
        this.openClearDialog()
      })
    }
    .width('92%')
    .backgroundColor(AppColors.bgTertiary)
    .borderRadius(12)
    .padding(12)
    .margin({ top: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  // ============== 弹窗内容 ==============

  /** 导出弹窗内容（域勾选 + 加密开关 + 口令 + 自绘按钮）。 */
  @Builder
  ExportDialogContent() {
    Column() {
      Row() {
        Text('已选 ' + String(this.exportSelectedIds.length) + ' / '
          + String(this.exportDomainIds.length) + ' 个数据域')
          .fontSize(12).fontColor(UIMaterialManager.adaptiveSecondaryForeground).layoutWeight(1)
        Text('全选').fontSize(13).fontColor(AppColors.primary)
          .onClick((): void => {
            this.exportSelectedIds = this.exportDomainIds.slice()
          })
        Text('全不选').fontSize(13).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .margin({ left: 12 })
          .onClick((): void => {
            this.exportSelectedIds = []
          })
      }
      .width('100%').padding({ top: 4, bottom: 8 }).alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          ForEach(this.exportRows, (row: ExportRow) => {
            if (row.kind === 'group') {
              Text(row.text).fontSize(12)
                .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                .width('100%').padding({ top: 10, bottom: 4 })
            } else {
              Row() {
                Checkbox({ name: row.domainId })
                  .select(this.isExportDomainSelected(row.domainId))
                  .selectedColor(AppColors.primary)
                  .width(20).height(20)
                  .onChange((value: boolean): void => {
                    this.toggleExportDomain(row.domainId, value)
                  })

                Column() {
                  Row() {
                    Text(this.exportLabelOf(row.domainId)).fontSize(14)
                      .fontColor(UIMaterialManager.adaptiveForeground).layoutWeight(1)
                    Text(this.exportDomainSizes[row.domainId] ?? '')
                      .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                  }
                  .width('100%').alignItems(VerticalAlign.Center)

                  Text(this.exportNoteOf(row.domainId)).fontSize(11)
                    .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                    .width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 1 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 8 })
              }
              .width('100%').padding({ top: 6, bottom: 6 }).alignItems(VerticalAlign.Top)
            }
          }, (row: ExportRow): string => row.kind + '|' + row.text + '|' + row.domainId)
        }
        .width('100%')
      }
      .height(280).width('100%').scrollBar(BarState.Off).align(Alignment.Top)

      Divider().color(AppColors.separator).margin({ top: 6, bottom: 6 })

      Row() {
        Column() {
          Text('加密导出').fontSize(14).fontColor(UIMaterialManager.adaptiveForeground)
          Text('未加密文件包含隐私内容（浏览历史、AI 对话、AI API Key 等），建议保持加密')
            .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground).margin({ top: 1 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.exportEncrypt })
          .selectedColor(AppColors.primary)
          .onChange((isOn: boolean): void => {
            if (isOn) {
              this.exportEncrypt = true
              return
            }
            /*
             * 关闭加密导出需要二次确认：未加密的备份文件包含浏览历史、AI 对话、便签等隐私内容，
             * 一旦落盘被分享/上传即等于泄露（设计文档 §6.2 / §6.6 的默认加密承诺）。
             */
            try {
              this.getUIContext().showAlertDialog({
                title: '关闭加密导出？',
                message: '未加密的备份文件包含浏览历史、AI 对话、便签等隐私内容，'
                  + '任何拿到文件的人都能直接查看。确定不加密吗？',
                primaryButton: {
                  value: '仍不加密',
                  action: (): void => {
                    this.exportEncrypt = false
                  }
                },
                secondaryButton: {
                  value: '保持加密',
                  action: (): void => {
                    this.exportEncrypt = true
                  }
                }
              })
            } catch (e) {
              // 弹窗不可用（极端场景）：保守保持加密
              this.exportEncrypt = true
            }
          })
      }
      .width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center)

      if (this.exportEncrypt) {
        TextInput({ text: this.exportPassword, placeholder: '设置加密密码（至少 8 位）' })
          .width('100%').height(44).fontSize(15)
          .type(InputType.Password)
          .fontColor(UIMaterialManager.inputForeground)
          .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
          .caretColor(UIMaterialManager.inputForeground)
          .borderRadius(12)
          .attributeModifier(UIMaterialManager.dialogFieldMaterial)
          .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
          .onChange((value: string): void => {
            this.exportPassword = value
          })
          .margin({ top: 8 })
      }

      if (this.exportProgressText.length > 0) {
        Text(this.exportProgressText).fontSize(12)
          .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
          .width('100%').margin({ top: 8 })
      }

      /*
       * 按勾选动态提示敏感域（设计稿 §6.6 #2）：固定在底部的笼统提示不足以让用户意识到
       * 「AI 对话历史」被勾选且未加密时的暴露面（审计 EXP-09）。
       */
      if (this.hasSensitiveSelection() && !this.exportEncrypt) {
        Text('⚠️ 已勾选敏感数据域（AI 对话历史/浏览历史），未加密导出会暴露这些内容。')
          .fontSize(11).fontColor(AppColors.destructive)
          .width('100%').margin({ top: 6 })
      }

      Text('注：草稿中的图片/视频副本不包含在备份内（体积大、路径不可移植）；导出时会移除草稿里的媒体引用，恢复后需在编辑器中重新选择。')
        .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .width('100%').margin({ top: 6 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).fontSize(16)
          .backgroundColor(Color.Transparent).fontColor(AppColors.primary)
          .onClick((): void => {
            this.exportDialogController?.close()
          })

        Button(this.exportRunning ? '导出中…' : '导出')
          .layoutWeight(1).height(44).fontSize(16)
          .margin({ left: 12 })
          .backgroundColor(AppColors.primary).fontColor(AppColors.white)
          .fontWeight(FontWeight.Bold)
          .opacity(this.isExportReady() ? 1 : 0.45)
          .enabled(this.isExportReady())
          .onClick((): void => {
            this.runExport()
          })
      }
      .width('100%').margin({ top: 12 })
    }
    .width('100%')
  }

  /** 导入口令弹窗内容（复用凭证链路的密码输入组件）。 */
  @Builder
  ImportPasswordContent() {
    CredentialPasswordContent({
      password: this.importPassword,
      minLength: 8,
      confirmLabel: '解密',
      onPasswordChange: (value: string): void => {
        this.importPassword = value
      },
      onConfirm: (password: string): void => {
        this.continueImportWithPassword(password)
      },
      onCancel: (): void => {
        this.importPasswordController?.close()
      }
    })
  }

  /** 导入计划确认弹窗内容。 */
  @Builder
  ImportPlanContent() {
    Column() {
      Row() {
        Column() {
          Text('恢复备份中的缓存类数据')
            .fontSize(14).fontColor(UIMaterialManager.adaptiveForeground)
          Text('通知/动态/资料/分类/收藏关系/工具缓存（默认恢复，关闭则跳过这些域）')
            .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground).margin({ top: 1 })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.restoreCacheDomains })
          .selectedColor(AppColors.primary)
          .onChange((isOn: boolean): void => {
            this.restoreCacheDomains = isOn
            this.rebuildImportPlan()
          })
      }
      .width('100%').padding({ top: 4, bottom: 4 }).alignItems(VerticalAlign.Center)

      Divider().color(AppColors.separator).margin({ top: 2, bottom: 6 })

      Scroll() {
        Column() {
          ForEach(this.importPlanLines, (line: ImportPlanLine) => {
            Row() {
              Column() {
                Text(line.label).fontSize(14)
                  .fontColor(line.willSkip ? UIMaterialManager.adaptiveSecondaryForeground :
                    UIMaterialManager.adaptiveForeground)
                  .width('100%')
                Text(line.detail).fontSize(11)
                  .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
                  .width('100%').margin({ top: 1 })
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
            }
            .width('100%').padding({ top: 8, bottom: 8 })
          }, (line: ImportPlanLine, index: number): string =>
            line.label + '#' + line.detail + '#' + String(index))
        }
        .width('100%')
      }
      .height(236).width('100%').scrollBar(BarState.Off).align(Alignment.Top)

      Divider().color(AppColors.separator).margin({ top: 6, bottom: 6 })

      Text('提示：草稿中的图片/视频副本不随备份恢复，导入后需在编辑器中重新选择；'
        + '账号镜像缓存需在登录状态下恢复。')
        .fontSize(11).fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .width('100%').margin({ top: 2, bottom: 2 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).fontSize(16)
          .backgroundColor(Color.Transparent).fontColor(AppColors.primary)
          .onClick((): void => {
            this.pendingPlan = null
            this.importPlanController?.close()
          })

        Button(this.importPlanApplicable ? '确认导入' : '无可导入数据')
          .layoutWeight(1).height(44).fontSize(16)
          .margin({ left: 12 })
          .backgroundColor(AppColors.primary).fontColor(AppColors.white)
          .fontWeight(FontWeight.Bold)
          .opacity(this.importPlanApplicable ? 1 : 0.45)
          .enabled(this.importPlanApplicable)
          .onClick((): void => {
            this.applyPendingImport()
          })
      }
      .width('100%').margin({ top: 12 })
    }
    .width('100%')
  }

  /** 清空确认弹窗内容（输入「清空」二字才可执行）。 */
  @Builder
  ClearDataContent() {
    Column() {
      TextInput({ text: this.clearInput, placeholder: '输入「' + CLEAR_CONFIRM_WORD + '」以确认' })
        .width('100%').height(44).fontSize(15)
        .fontColor(UIMaterialManager.inputForeground)
        .placeholderColor(UIMaterialManager.adaptiveSecondaryForeground)
        .caretColor(UIMaterialManager.inputForeground)
        .borderRadius(12)
        .attributeModifier(UIMaterialManager.dialogFieldMaterial)
        .keyboardAppearance(resolveKeyboardAppearance(this.effectiveColorMode))
        .onChange((value: string): void => {
          this.clearInput = value
        })

      Text('该操作不可撤销，请确认后执行。').fontSize(11)
        .fontColor(UIMaterialManager.adaptiveSecondaryForeground)
        .margin({ top: 6 })
        .alignSelf(ItemAlign.Start)

      Divider().color(AppColors.separator).margin({ top: 12 })

      Row() {
        Button('取消')
          .layoutWeight(1).height(44).fontSize(16)
          .backgroundColor(Color.Transparent).fontColor(AppColors.primary)
          .onClick((): void => {
            this.clearDialogController?.close()
          })

        Button(this.clearingData ? '清空中…' : '清空')
          .layoutWeight(1).height(44).fontSize(16)
          .margin({ left: 12 })
          .backgroundColor(AppColors.destructive).fontColor(AppColors.white)
          .fontWeight(FontWeight.Bold)
          .opacity(this.clearInput === CLEAR_CONFIRM_WORD ? 1 : 0.45)
          .enabled(this.clearInput === CLEAR_CONFIRM_WORD && !this.clearingData)
          .onClick((): void => {
            this.runClearAll()
          })
      }
      .width('100%').margin({ top: 12 })
    }
    .width('100%')
  }
}
