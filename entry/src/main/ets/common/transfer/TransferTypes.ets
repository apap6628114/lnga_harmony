/**
 * 数据导入导出 — 容器类型与结果类型。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6。容器分两级：
 * - **容器层**：magic / formatVersion / dataVersion / checksum / 可选加密封装；
 * - **域层**：每个域一段 `{id, schemaVersion, updatedAt, payload}`，payload 形状由域自己决定。
 *
 * 加密逻辑在 `TransferCrypto.ets`，合并逻辑在 `DomainMergers.ets`，本目录的
 * `DataTransferService.ets` 负责编排（读域 → 打包 → 解析 → 计划 → 应用）。
 */

import { ImportPolicy } from '../persistence/PersistenceTypes'

/**
 * 被跳过（未包含 / 未导入）的数据域及原因。
 *
 * 「不允许静默丢弃」是导出导入闭环的红线：
 * - 导出侧：用户勾选了某域，但该域无数据 / 读取失败 / 单域超限 / 账号归属不符 → 记入
 *   `BackupExportResult.omitted`，UI 必须展示；
 * - 导入侧：备份里出现的域，但解析阶段被丢弃（载荷超限 / 结构非法 / 重复）或策略/归属校验
 *   跳过 → 记入 `ParseOutcome.droppedDomains`，再由导入计划生成「跳过」条目展示原因。
 */
export class SkippedDomain {
  /** 域 ID（未知域时可能是备份里的原始 id）。 */
  domainId: string = ''
  /** 域名（展示用；可能为空串，UI 回退到 domainId）。 */
  label: string = ''
  /** 跳过原因（中文短句，直接展示给用户）。 */
  reason: string = ''

  /**
   * 构造跳过条目。
   *
   * @param domainId - 域 ID
   * @param reason - 跳过原因
   * @param label - 域名
   */
  constructor(domainId: string = '', reason: string = '', label: string = '') {
    this.domainId = domainId
    this.reason = reason
    this.label = label
  }
}

/**
 * 导出容器中的一个域片段。
 */
export class BackupDomainEntry {
  /** 域 ID（与 PersistenceCatalog 一致）。 */
  id: string = ''
  /** 域名。 */
  label: string = ''
  /** 域 schema 版本。 */
  schemaVersion: number = 1
  /** 域最后写入时间（毫秒；RAW 域为 0，见 `DataTransferService.buildDomainEntry`）。 */
  updatedAt: number = 0
  /**
   * 域归属账号（仅 ACCOUNT_MIRROR 域填充；导出时写入，导入时用于跨账号串号防护）。
   *
   * 旧版备份没有该字段（空串）：导入侧按「归属未知」宽容处理（仍恢复，但计划页会提示）。
   */
  ownerUid: string = ''
  /** 域载荷。 */
  payload: Object = new Object()
}

/**
 * 明文导出容器（`NGA_OH_BACKUP`）。
 */
export class BackupContainer {
  /** 固定 magic。 */
  magic: string = ''
  /** 容器格式版本。 */
  formatVersion: number = 0
  /** 导出时的全局数据版本。 */
  dataVersion: number = 0
  /** 导出时间戳（毫秒）。 */
  exportedAt: number = 0
  /** 导出时的应用版本名（诊断）。 */
  appVersionName: string = ''
  /** 导出时的应用版本号（诊断）。 */
  appVersionCode: number = 0
  /** 设备类型标签（诊断，不参与校验）。 */
  deviceTag: string = ''
  /** 域片段数组（顺序稳定：按 Catalog 声明顺序）。 */
  domains: BackupDomainEntry[] = []
  /** `domains` 序列化结果的 SHA-256（`sha256:<hex>`；空串表示旧文件无校验和）。 */
  checksum: string = ''
}

/**
 * 导出选项。
 */
export class BackupExportOptions {
  /** 勾选的域 ID。 */
  domainIds: string[] = []
  /** 是否加密。 */
  encrypt: boolean = false
  /** 加密口令（encrypt=true 时必填，至少 8 位）。 */
  password: string = ''
}

/**
 * 导出结果。
 */
export class BackupExportResult {
  /** 是否成功。 */
  ok: boolean = false
  /** 明文/加密后的文件文本。 */
  content: string = ''
  /** 是否加密。 */
  encrypted: boolean = false
  /** 包含的域数量。 */
  domainCount: number = 0
  /** 文本体积（UTF-8 近似字节数）。 */
  bytes: number = 0
  /** 错误信息（ok=false 时）。 */
  error: string = ''
  /**
   * 用户勾选但**未包含**在备份中的域（无数据/读取失败/单域超限/账号归属不符）。
   *
   * 空数组表示勾选的域全部写入容器；非空时 UI 必须展示清单与原因（禁止静默省略）。
   */
  omitted: SkippedDomain[] = []
}

/**
 * 导入计划中的一个域条目。
 */
export class ImportPlanEntry {
  /** 域 ID。 */
  domainId: string = ''
  /** 域名。 */
  label: string = ''
  /** 导入策略（ImportPolicy 的数值）。 */
  policy: ImportPolicy = ImportPolicy.SKIP
  /** 是否跳过（策略跳过 / 不兼容 / 无数据）。 */
  willSkip: boolean = false
  /** 跳过原因。 */
  reason: string = ''
  /** 预计新增条数。 */
  added: number = 0
  /** 预计更新条数。 */
  updated: number = 0
  /** 合并后总条数。 */
  total: number = 0
  /** 合并后的载荷（应用阶段直接使用，避免重复合并）。 */
  mergedPayload: Object = new Object()
}

/**
 * 导入计划（供用户确认）。
 */
export class ImportPlan {
  /** 是否可执行（至少一个域有变更）。 */
  ok: boolean = false
  /** 容器版本信息。 */
  formatVersion: number = 0
  dataVersion: number = 0
  exportedAt: number = 0
  appVersionName: string = ''
  /** 各域条目。 */
  entries: ImportPlanEntry[] = []
  /** 不可执行的错误信息（文件损坏/版本过高/全部跳过等）。 */
  error: string = ''

  /**
   * 统计有实际变更的域数量。
   *
   * @returns 域数量
   */
  changedDomainCount(): number {
    let total: number = 0
    for (let i: number = 0; i < this.entries.length; i++) {
      const entry: ImportPlanEntry = this.entries[i]
      if (!entry.willSkip && (entry.added > 0 || entry.updated > 0)) {
        total++;
      }
    }
    return total
  }
}

/**
 * 导入执行结果。
 */
export class ImportResult {
  /** 是否成功（全部有变更的域都写入成功）。 */
  ok: boolean = false
  /** 实际写入的域数量。 */
  appliedDomains: number = 0
  /** 新增条目总数。 */
  added: number = 0
  /** 更新条目总数。 */
  updated: number = 0
  /** 跳过的域数量。 */
  skippedDomains: number = 0
  /** 失败信息（首个错误）。 */
  error: string = ''
  /** 写入失败的域 ID 列表（`error` 只保留首个错误，明细靠这里）。 */
  failedDomains: string[] = []

  /**
   * 构造导入结果。
   */
  constructor() {
  }
}
