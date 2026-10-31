import { describe, expect, it } from '@ohos/hypium'
import {
  MigrationDomainResult,
  MigrationDomainStatus,
  MigrationReport
} from '../main/ets/common/persistence/PersistenceTypes'

/**
 * 迁移「未完成域」统计回归测试（审计 DES-02 补充项）。
 *
 * 背景：导出只读 `v2.*` 新键，而迁移未完成的域其旧数据仍在旧键上 —— 数据管理页需要在
 * 导出/清空之前给出警示。本套用例锁定 `MigrationReport.countUnsettled()` 的统计口径：
 * - `FAILED` / `DEFERRED` 直接计入；
 * - `SKIPPED` 仅当 `legacyRetained=true`（旧键保留且新键无数据、登录/换号后可重试）才计入；
 * - 普通 `SKIPPED`（新键已存在 / 旧目录为空 / 旧数据不可解析）与 `MIGRATED` 不计入；
 * - `legacyRetained` 能随 meta 的 JSON 序列化/反序列化保真（旧 meta 缺失该字段按 false）。
 */
export default function migrationUnsettledTest(): void {
  describe('migrationUnsettled', (): void => {
    it('countsFailedDeferredAndRetainedSkipsOnly', 0, (): void => {
      const report: MigrationReport = new MigrationReport()
      report.domains.push(new MigrationDomainResult('a', MigrationDomainStatus.FAILED, 0, '写盘失败'))
      report.domains.push(new MigrationDomainResult('b', MigrationDomainStatus.DEFERRED, 0, '超出预算'))
      report.domains.push(new MigrationDomainResult('c', MigrationDomainStatus.SKIPPED, 0,
        '多账号设置旧键且无当前账号匹配（旧键保留，登录后重试）', true))
      report.domains.push(new MigrationDomainResult('d', MigrationDomainStatus.SKIPPED, 0, '新键已存在，保留现有数据'))
      report.domains.push(new MigrationDomainResult('e', MigrationDomainStatus.MIGRATED, 1, ''))

      expect(report.countUnsettled()).assertEqual(3)
      // 原有 count 口径不受影响
      expect(report.count(MigrationDomainStatus.SKIPPED)).assertEqual(2)
      expect(report.count(MigrationDomainStatus.FAILED)).assertEqual(1)
      expect(report.count(MigrationDomainStatus.MIGRATED)).assertEqual(1)
    })

    it('returnsZeroForSettledReport', 0, (): void => {
      const empty: MigrationReport = new MigrationReport()
      expect(empty.countUnsettled()).assertEqual(0)

      const settled: MigrationReport = new MigrationReport()
      settled.domains.push(new MigrationDomainResult('settings', MigrationDomainStatus.MIGRATED, 1, ''))
      settled.domains.push(new MigrationDomainResult('notifications', MigrationDomainStatus.SKIPPED, 0,
        '新键已存在，保留现有数据'))
      settled.domains.push(new MigrationDomainResult('drafts', MigrationDomainStatus.SKIPPED, 0, '旧目录为空'))
      expect(settled.countUnsettled()).assertEqual(0)
    })

    it('keepsLegacyRetainedThroughJsonRoundTrip', 0, (): void => {
      const report: MigrationReport = new MigrationReport()
      report.domains.push(new MigrationDomainResult('settings', MigrationDomainStatus.SKIPPED, 0, 'r', true))
      report.domains.push(new MigrationDomainResult('history', MigrationDomainStatus.SKIPPED, 0, 'n'))
      const json: string = JSON.stringify(report)
      const parsed: MigrationReport = JSON.parse(json) as MigrationReport
      expect(parsed.domains.length).assertEqual(2)
      expect(parsed.domains[0].legacyRetained).assertTrue()
      expect(parsed.domains[1].legacyRetained).assertFalse()
      expect(parsed.domains[0].reason).assertEqual('r')
    })
  })
}
