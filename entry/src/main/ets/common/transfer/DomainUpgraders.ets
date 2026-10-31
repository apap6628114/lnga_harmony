/**
 * 导入域升级器（旧 `schemaVersion` → 当前 `schemaVersion`）。
 *
 * ## 为什么需要它
 * 导出容器里每个域带 `schemaVersion`。导入时若发现某域的 `schemaVersion` **低于**当前
 * `DomainSpec.schemaVersion`，说明备份来自旧版本应用，载荷结构可能不同——必须经过显式
 * 升级才能按当前结构写入；直接按新结构落盘会被 Store 误读（甚至读成空域，静默丢数据）。
 *
 * ## 当前状态（2026-10-31）
 * 所有域 `schemaVersion = 1`，尚无历史版本，因此**没有已注册的升级规则**。
 * 本模块先落地「升级器入口 + 默认拒绝语义」：
 * - 有规则：转换为当前结构并返回 `ok=true`；
 * - 无规则（含全部现有域）：返回 `ok=false` + 原因，由导入计划生成「跳过」条目，
 *   用户可见地知道该域未被导入，而不是按新结构误写。
 *
 * ## 未来如何扩展
 * 在 {@link upgradeDomainPayload} 中按 `domainId` + `fromVersion` 增加分支（例如
 * `if (domainId === DomainIds.SETTINGS && fromVersion < 2)`），把实现放在本文件内独立函数里，
 * 并补 Hypium 用例。**提升 `DomainSpec.schemaVersion` 前必须先注册对应升级规则**，
 * 否则旧备份该域会被拒绝导入（设计稿 §6.4 / §13.5）。
 */

/**
 * 单域升级结果。
 */
export class DomainUpgradeResult {
  /** 是否升级成功（false 表示没有可用规则，调用方应跳过该域）。 */
  ok: boolean = false
  /** 升级后的载荷（`ok=false` 时等于入参）。 */
  payload: Object = new Object()
  /** 说明：成功时描述做了什么；失败时是**用户可见**的跳过原因。 */
  note: string = ''
}

/**
 * 把旧版本的域载荷升级到当前版本。
 *
 * 纯函数（不读写磁盘、不依赖 Hub），便于单测。
 *
 * @param domainId - 域 ID（`DomainIds`）
 * @param fromVersion - 备份中该域的 schemaVersion
 * @param payload - 备份中该域的载荷
 * @returns 升级结果；无规则时 `ok=false` 且 `note` 说明原因
 */
export function upgradeDomainPayload(domainId: string, fromVersion: number,
  payload: Object): DomainUpgradeResult {
  const result: DomainUpgradeResult = new DomainUpgradeResult()
  result.payload = payload
  /*
   * 升级规则分派处。当前没有域需要升级（全部 schemaVersion = 1），故直接走默认拒绝。
   * 未来示例：
   *   if (domainId === DomainIds.SETTINGS && fromVersion < 2) {
   *     return upgradeSettingsV1ToV2(payload)
   *   }
   */
  const fromLabel: string = fromVersion > 0 ? String(fromVersion) : '未知'
  result.ok = false
  result.note = '该数据域的格式版本较低（v' + fromLabel
    + '），当前版本没有对应的升级规则，已跳过（请用新版应用重新导出后导入）'
  return result
}
