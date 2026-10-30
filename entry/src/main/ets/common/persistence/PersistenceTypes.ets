/**
 * 持久化数据统一治理 — 类型与常量。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md`。本文件只放**跨模块共享的纯类型与常量**，
 * 不依赖任何 store / UI / 服务层代码，保证可以被 Catalog / Hub / 迁移器 / 导出器 / 测试同时引用
 * 而不产生循环依赖。
 */

/**
 * 存储介质。
 *
 * - `PREFERENCES`：`preferences` 键值库中的单个键（整包 JSON），适合中小体积、需频繁写的域；
 * - `JSON_FILES`：沙箱文件目录，一文件一条，适合大块数据与天然按条组织的域（存档、草稿）。
 */
export enum StorageKind {
  PREFERENCES = 0,
  JSON_FILES = 1,
}

/**
 * 域的账号语义。
 *
 * - `DEVICE`：设备级，与账号无关，登出/切号不重置（本次治理的主要目标）；
 * - `ACCOUNT_MIRROR`：服务端账号状态的本地镜像（通知/动态/收藏成员关系），物理单份但保留
 *   `ownerUid` 做软隔离，切号后按当前账号判定有效性与重建；
 * - `SECRET`：凭证类，不导出、不参与统一导入，生命周期仍跟随会话。
 */
export enum DomainScope {
  DEVICE = 0,
  ACCOUNT_MIRROR = 1,
  SECRET = 2,
}

/**
 * 导出策略。
 *
 * - `INCLUDE`：默认勾选；
 * - `OPTIONAL`：默认不勾选（缓存/可重建数据，或隐私敏感但用户可能想带走）；
 * - `NEVER`：不出现在导出列表（凭证、内部元数据）。
 */
export enum ExportPolicy {
  INCLUDE = 0,
  OPTIONAL = 1,
  NEVER = 2,
}

/**
 * 导入策略（导出文件 → 本机）。
 *
 * - `MERGE_FIELDS`：字段级合并（设置类，导入值优先，本机独有条目保留）；
 * - `MERGE_BY_KEY`：按业务键去重合并，冲突取较新（历史/进度/投票/跟踪/AI 会话）；
 * - `REPLACE_BY_KEY`：按业务键覆盖（草稿/离线存档）；
 * - `SKIP`：不导入（缓存/账号镜像，服务端可重建）；
 * - `SPECIAL`：由域自行实现（如 `settings` 内数组字段的并集语义）；
 * - `NEVER`：硬拒绝（凭证）。
 */
export enum ImportPolicy {
  MERGE_FIELDS = 0,
  MERGE_BY_KEY = 1,
  REPLACE_BY_KEY = 2,
  SKIP = 3,
  SPECIAL = 4,
  NEVER = 5,
}

/** 迁移状态（写进 `v2.meta`，同时发布到 AppStorage 供 UI 消费）。 */
export enum MigrationStatus {
  /** 尚未检测（首次启动前的初始值）。 */
  UNKNOWN = 'unknown',
  /** 无旧数据，无需迁移（首次安装）。 */
  NOT_REQUIRED = 'not-required',
  /** 全部完成。 */
  COMPLETED = 'completed',
  /** 部分域完成，存在失败/延后域。 */
  PARTIAL = 'partial',
  /** 所有域都失败（极罕见）。 */
  FAILED = 'failed',
}

/** 单域迁移结果状态。 */
export enum MigrationDomainStatus {
  /** 完成转换并写入新键。 */
  MIGRATED = 'migrated',
  /** 新键已存在且不旧于旧数据，无需转换。 */
  SKIPPED = 'skipped',
  /** 转换或写入失败（保留旧数据，下次重试）。 */
  FAILED = 'failed',
  /** 超出启动迁移预算，留待下次（不算失败，不打扰用户）。 */
  DEFERRED = 'deferred',
}

/** 新版 Preferences 键的命名空间前缀（与全局数据版本对齐）。 */
export const PERSISTENCE_KEY_NAMESPACE: string = 'v2.'

/** 文件域命名空间目录名（相对 filesDir；不带点，与键前缀 `v2.` 区分）。 */
export const FILE_NAMESPACE_DIR: string = 'v2'

/** 当前全局数据版本（跨代升级时递增；见设计文档 §5.1）。 */
export const PERSISTENCE_DATA_VERSION: number = 2

/** 全局数据版本锚点键（不属于任何业务域）。 */
export const PERSISTENCE_META_KEY: string = 'v2.meta'

/** 迁移完成后的旧数据保留期（天）。 */
export const LEGACY_RETENTION_DAYS: number = 30

/** 启动迁移总预算（毫秒）；超出的域标记 DEFERRED。文件域逐文件检查该 deadline。 */
export const MIGRATION_BUDGET_MS: number = 3000

/** 导出容器版本（与 dataVersion 相互独立）。 */
export const BACKUP_FORMAT_VERSION: number = 1

/** 导出文件 magic（明文容器）。 */
export const BACKUP_MAGIC: string = 'NGA_OH_BACKUP'

/** 导出文件 magic（加密容器）。 */
export const BACKUP_ENCRYPTED_MAGIC: string = 'NGA_OH_BACKUP_ENC'

/** 导出文件后缀。 */
export const BACKUP_FILE_SUFFIX: string = '.ngabackup'

/** 导入文件体积上限（字节）：超过直接拒绝，防止超大/恶意文件拖垮内存。 */
export const BACKUP_MAX_FILE_BYTES: number = 64 * 1024 * 1024

/** 单域体积告警阈值（字节）。 */
export const DOMAIN_SIZE_WARN_BYTES: number = 4 * 1024 * 1024

/**
 * 域元数据 — 数据域的静态声明。
 *
 * 全工程所有持久化数据的治理口径以 `PersistenceCatalog` 中的实例为准：
 * 键名、版本、账号语义、导出/导入策略、是否可清空都从这里读取。
 */
export class DomainSpec {
  /** 域 ID（稳定标识，导出文件与状态记录都用它）。 */
  readonly id: string
  /** 人类可读名（导出勾选、数据管理页）。 */
  readonly label: string
  /** 存储介质。 */
  readonly storage: StorageKind
  /** Preferences 键（不含命名空间，构造时统一加 `v2.`）；文件域为空串。 */
  readonly key: string
  /**
   * JSON 文件域相对 `filesDir` 的目录名；Preferences 域为空串。
   *
   * 约定：以 `/` 结尾的正常目录名会落在 `filesDir/v2/<dirName>`；以 `!` 开头表示**沿用旧布局**
   * （`filesDir/<去掉!的名称>`），用于草稿媒体与动态照片缓存——它们的目录名与既有文件引用绑定，
   * 不可搬移（搬移会让磁盘上已登记的绝对路径失效）。
   */
  readonly dirName: string
  /** 当前域 schema 版本。 */
  readonly schemaVersion: number
  /** 账号语义。 */
  readonly scope: DomainScope
  /** 导出策略。 */
  readonly exportPolicy: ExportPolicy
  /** 导入策略。 */
  readonly importPolicy: ImportPolicy
  /** 是否参与「清空本地数据」。 */
  readonly clearable: boolean
  /** 是否为可重建缓存（迁移/导入可整体丢弃）。 */
  readonly rebuildable: boolean
  /** 单条平均字节数（仅用于 UI 体积量级估算，不要求精确）。 */
  readonly avgItemBytes: number
  /** 说明（写进导出清单/数据管理页）。 */
  readonly note: string
  /**
   * 载荷封装模式：`false`（默认）= 统一域信封；`true` = **裸载荷**（payload 直接落盘，不套信封）。
   *
   * 为什么需要两种：本工程既有 15 个 Store 已经把裸 JSON 直接写进 Preferences（如 `settings_<uid>`
   * 存的就是 `SettingsState` 序列化结果）。治理阶段把它们改成信封会牵动每个 Store 的读写与所有
   * 历史数据的兼容。`RAW` 模式让这些域**只换键、不动载荷结构**即可接入统一治理（迁移=搬键+升级），
   * 而新域与文件域使用信封/文件格式。导出容器会把 RAW 载荷包装成统一的域对象，对外无差异。
   *
   * 该字段在 `PersistenceCatalog` 构建后以写时赋值方式设置（其余字段构造后不可变），
   * 运行期只读不改。
   */
  rawPayload: boolean = false

  /**
   * 构造域元数据。
   *
   * @param id - 域 ID
   * @param label - 人类可读名
   * @param storage - 存储介质
   * @param key - Preferences 键（不含命名空间）
   * @param dirName - 文件域目录名
   * @param schemaVersion - 域 schema 版本
   * @param scope - 账号语义
   * @param exportPolicy - 导出策略
   * @param importPolicy - 导入策略
   * @param clearable - 是否可清空
   * @param rebuildable - 是否可重建缓存
   * @param avgItemBytes - 单条平均字节数（估算用）
   * @param note - 说明
   */
  constructor(
    id: string,
    label: string,
    storage: StorageKind,
    key: string,
    dirName: string,
    schemaVersion: number,
    scope: DomainScope,
    exportPolicy: ExportPolicy,
    importPolicy: ImportPolicy,
    clearable: boolean,
    rebuildable: boolean,
    avgItemBytes: number,
    note: string
  ) {
    this.id = id
    this.label = label
    this.storage = storage
    this.key = key
    this.dirName = dirName
    this.schemaVersion = schemaVersion
    this.scope = scope
    this.exportPolicy = exportPolicy
    this.importPolicy = importPolicy
    this.clearable = clearable
    this.rebuildable = rebuildable
    this.avgItemBytes = avgItemBytes
    this.note = note
  }

  /**
   * 返回该域的完整 Preferences 键（带命名空间）。
   *
   * @returns 完整键；文件域返回空串
   */
  fullKey(): string {
    return this.storage === StorageKind.PREFERENCES ? PERSISTENCE_KEY_NAMESPACE + this.key : ''
  }

  /**
   * 返回该域的文件目录绝对路径。
   *
   * @param filesDir - 应用沙箱 filesDir
   * @returns 绝对路径；Preferences 域返回空串
   */
  dirPath(filesDir: string): string {
    if (this.storage !== StorageKind.JSON_FILES) {
      return ''
    }
    if (this.dirName.startsWith('!')) {
      // 沿用旧布局：filesDir/<名称>（见 dirName 字段注释）
      return filesDir + '/' + this.dirName.substring(1)
    }
    /*
     * 文件域根目录固定为 `filesDir/v2/`：命名空间目录名是 `v2`（不带点），
     * 与 Preferences 键前缀 `v2.`（带点）刻意区分。
     *
     * ⚠️ 历史 bug 回归点：早期实现是 `filesDir + '/' + PERSISTENCE_KEY_NAMESPACE + dirName`
     * （`v2.` 带点）→ 生成 `filesDir/v2.drafts/`，而迁移器写的是 `filesDir/v2/drafts/`，
     * 两边路径不一致导致迁移后的草稿/存档读不到。Store 与迁移器现在都以本方法为准。
     */
    return filesDir + '/' + FILE_NAMESPACE_DIR + '/' + this.dirName
  }
}

/**
 * 统一域信封 — 所有 Preferences 域的落盘结构。
 *
 * `payload` 由各域自定义（数组/对象皆可）；公共字段只承担版本、身份与时间戳。
 */
export class DomainEnvelope {
  /** 域 schema 版本。 */
  schemaVersion: number = 1
  /** 域 ID（键/内容错配自检）。 */
  domain: string = ''
  /** 最后一次成功写入时间（毫秒）。 */
  updatedAt: number = 0
  /** 账号镜像域的归属账号（其余域为空串）。 */
  ownerUid: string = ''
  /** 域自定义数据。 */
  payload: Object = new Object()
}

/**
 * 单域迁移结果。
 */
export class MigrationDomainResult {
  /** 域 ID。 */
  domain: string = ''
  /** 结果状态（MigrationDomainStatus 的字符串值）。 */
  status: string = ''
  /** 转换成功的条目数（0 表示整包）。 */
  items: number = 0
  /** 失败/跳过原因（截断到 200 字符）。 */
  reason: string = ''

  /**
   * 构造单域迁移结果。
   *
   * @param domain - 域 ID
   * @param status - 结果状态
   * @param items - 条目数
   * @param reason - 原因
   */
  constructor(domain: string = '', status: string = '', items: number = 0, reason: string = '') {
    this.domain = domain
    this.status = status
    this.items = items
    this.reason = reason
  }
}

/**
 * 迁移报告 — 写进 `v2.meta.migration`，并发布到 AppStorage 供 UI 消费。
 */
export class MigrationReport {
  /** 总体状态。 */
  status: string = MigrationStatus.UNKNOWN
  /** 迁移前数据版本（0 = 无锚点）。 */
  fromDataVersion: number = 0
  /** 开始时间（毫秒）。 */
  startedAt: number = 0
  /** 结束时间（毫秒）。 */
  finishedAt: number = 0
  /** 各域结果。 */
  domains: MigrationDomainResult[] = []
  /** 已处理的旧键（30 天后清理）。 */
  legacyKeys: string[] = []
  /** 旧数据清理时间点（毫秒）。 */
  legacyCleanupAt: number = 0

  /**
   * 统计指定状态的域数量。
   *
   * @param status - MigrationDomainStatus 字符串值
   * @returns 域数量
   */
  count(status: string): number {
    let total: number = 0
    for (let i: number = 0; i < this.domains.length; i++) {
      if (this.domains[i].status === status) {
        total++;
      }
    }
    return total;
  }
}

/**
 * 全局数据版本锚点（`v2.meta` 的 payload 结构）。
 */
export class PersistenceMeta {
  /** 全局数据版本。 */
  dataVersion: number = PERSISTENCE_DATA_VERSION
  /** 锚点创建时间（首次安装/首次启动）。 */
  createdAt: number = 0
  /** 最近一次迁移完成时间（0 = 从未迁移）。 */
  migratedAt: number = 0
  /** 迁移时的应用版本名（诊断用）。 */
  appVersionName: string = ''
  /** 迁移时的应用版本号（诊断用）。 */
  appVersionCode: number = 0
  /** 最近一次迁移报告（可能为空报告）。 */
  migration: MigrationReport = new MigrationReport()
  /**
   * 迁移完成提醒是否已向用户展示（只提示一次的持久化标记）。
   *
   * 迁移报告本身会长期留在 meta 里（数据管理页展示用），不能作为"是否提示"的依据——
   * 否则每次冷启动都会重复弹"本地数据已升级"，真机实测已确认该体验问题。
   */
  migrationNoticeAcknowledged: boolean = false
}

/**
 * 域健康快照（内存态，数据管理页展示）。
 */
export class DomainHealthSnapshot {
  /** 域 ID。 */
  domain: string = ''
  /** 最近一次读取是否失败。 */
  loadFailed: boolean = false
  /** 最近一次写入是否失败。 */
  writeFailed: boolean = false
  /** 最近一次错误（截断）。 */
  lastError: string = ''
  /** 跳过的坏条目数（最近一次读取）。 */
  droppedItems: number = 0
  /** 内存中条目数（估算）。 */
  itemCount: number = 0
  /** 估算体积（字节）。 */
  estimatedBytes: number = 0
  /** 最近一次成功写入时间（毫秒）。 */
  lastWriteAt: number = 0

  /**
   * 构造域健康快照。
   *
   * @param domain - 域 ID
   */
  constructor(domain: string = '') {
    this.domain = domain
  }
}

/**
 * 把错误对象转为短字符串（截断，供 UI 与 meta 使用）。
 *
 * @param error - 捕获的异常
 * @returns 截断后的错误描述
 */
export function shortError(error: Object): string {
  const text: string = error instanceof Error ? error.message : JSON.stringify(error)
  return text.length > 200 ? text.substring(0, 200) : text
}
