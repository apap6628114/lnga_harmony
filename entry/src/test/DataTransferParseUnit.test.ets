import { describe, expect, it } from '@ohos/hypium'
import { DataTransferService } from '../main/ets/common/transfer/DataTransferService'

/**
 * 备份解析回归（`parseBackup`）。
 *
 * 真机事故回归点：`normalizeContainer` 成功时不会设置 `outcome.ok`，而调用方曾用
 * `container === null || !outcome.ok` 判断 → 所有明文备份被误判为"容器非法"，
 * 用户只能看到笼统的"解析失败"（读取成功、JSON 合法，却永远导不进来）。
 */
const PLAINTEXT_CONTAINER: string = '{' +
  '"magic":"NGA_OH_BACKUP",' +
  '"formatVersion":1,' +
  '"dataVersion":2,' +
  '"exportedAt":1,' +
  '"appVersionName":"1.0",' +
  '"appVersionCode":1,' +
  '"deviceTag":"phone",' +
  '"domains":[{"id":"theme","label":"主题","schemaVersion":1,"updatedAt":1,' +
  '"payload":{"theme":"dark"}}],' +
  '"checksum":""' +
  '}'

/** 加密容器的 magic 前缀（识别到 magic 会先要求口令，不会触碰 crypto）。 */
const ENCRYPTED_CONTAINER: string = '{"magic":"NGA_OH_BACKUP_ENC"}'

/**
 * 注册备份解析回归测试。
 */
export default function dataTransferParseUnitTest(): void {
  describe('dataTransferParse', (): void => {
    it('acceptsValidPlaintextContainer', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(PLAINTEXT_CONTAINER, '')
      // 回归：合法明文容器必须 ok=true（此前被 !outcome.ok 误判为失败）
      expect(outcome.ok).assertTrue()
      expect(outcome.container === null).assertFalse()
      expect(outcome.error.length).assertEqual(0)
    })

    it('repairsTruncatedContainerTail', 0, async (): Promise<void> => {
      // 备份文件尾部缺失（导出写入未完成）：提取完整域恢复，并给出警告
      const cutIndex: number = PLAINTEXT_CONTAINER.lastIndexOf('"checksum"')
      const truncated: string = PLAINTEXT_CONTAINER.substring(0, cutIndex)
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(truncated, '')
      expect(outcome.ok).assertTrue()
      expect(outcome.warning.length > 0).assertTrue()
      expect(outcome.container === null).assertFalse()
    })

    it('rejectsNonBackupJson', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup('{"foo":1}', '')
      expect(outcome.ok).assertFalse()
      expect(outcome.error.length > 0).assertTrue()
    })

    it('asksPasswordForEncryptedContainer', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup(ENCRYPTED_CONTAINER, '')
      expect(outcome.ok).assertFalse()
      expect(outcome.needPassword).assertTrue()
    })

    it('rejectsEmptyContent', 0, async (): Promise<void> => {
      const service: DataTransferService = new DataTransferService()
      const outcome = await service.parseBackup('', '')
      expect(outcome.ok).assertFalse()
      expect(outcome.error.length > 0).assertTrue()
    })
  })
}
