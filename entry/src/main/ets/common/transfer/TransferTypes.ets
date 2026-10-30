/**
 * 数据导入导出 — 容器类型与结果类型。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6。容器分两级：
 * - **容器层**：magic / formatVersion / dataVersion / checksum / 可选加密封装；
 * - **域层**：每个域一段 `{id, schemaVersion, updatedAt, payload}`，payload 形状由域自己决定。
 *
 * 加密逻辑在 `TransferCrypto.ets`，合并逻辑在 `DomainMergers.ets`，本目录的
 * `DataTransferService.ets` 负责编排（读域 → 打包 → 解析 → 计划 → 应用 → 撤销）。
 */

import { ImportPolicy } from '../persistence/PersistenceTypes'

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
  /** 域最后写入时间（毫秒）。 */
  updatedAt: number = 0
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

  /**
   * 构造导入结果。
   */
  constructor() {
  }
}
