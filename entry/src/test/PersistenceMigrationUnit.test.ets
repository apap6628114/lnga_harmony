import { describe, expect, it } from '@ohos/hypium'
import {
  convertDomainValues,
  isLegacyKey,
  isNewNamespaceKey,
  LegacyValue,
  MigrationContext,
  MigrationConvertResult,
  resolveLegacyRule
} from '../main/ets/common/persistence/DomainMigrators'
import { DomainIds } from '../main/ets/common/persistence/PersistenceCatalog'

/**
 * 旧数据迁移规则单元测试。
 *
 * `DomainMigrators` 是纯函数层（不读写磁盘），因此这些用例可以完整覆盖"旧键识别 + 格式转换"
 * 的核心语义，包括多份旧键合并、账号优先取舍、AI 会话 ownerUid 清洗等高风险路径。
 *
 * 注意：ArkTS 不支持嵌套的不可推断对象字面量，测试数据一律**逐层构造**（`new Object()` 起底
 * 再赋值）或经工厂函数生成。
 */

/**
 * 构造一条旧值。
 *
 * @param key - 旧键名
 * @param uid - 从键解析出的 uid（无则空串）
 * @param value - 旧值对象
 * @returns 旧值条目
 */
function legacy(key: string, uid: string, value: Object): LegacyValue {
  return new LegacyValue(key, uid, value)
}

/**
 * 构造测试上下文。
 *
 * @param currentUid - 当前 uid
 * @returns 上下文
 */
function contextOf(currentUid: string): MigrationContext {
  return new MigrationContext(currentUid, 1730000000000)
}

/**
 * 构造一条浏览历史条目。
 *
 * @param tid - 主题 ID
 * @param subject - 标题
 * @param ts - 时间戳
 * @returns 历史条目
 */
function historyEntry(tid: string, subject: string, ts: number): Record<string, Object> {
  const entry: Record<string, Object> = {}
  entry['tid'] = tid
  entry['subject'] = subject
  entry['ts'] = ts
  return entry
}

/**
 * 构造一条投票记录。
 *
 * @param upPids - 赞成楼层
 * @param downPids - 反对楼层
 * @param ts - 时间戳
 * @returns 投票记录
 */
function voteEntry(upPids: string[], downPids: string[], ts: number): Record<string, Object> {
  const record: Record<string, Object> = {}
  record['upPids'] = upPids
  record['downPids'] = downPids
  record['ts'] = ts
  return record
}

/**
 * 构造旧版账号镜像信封（`{schemaVersion, uid, items}`）。
 *
 * @param schemaVersion - 旧结构版本
 * @param uid - 归属账号
 * @param items - 条目数组
 * @returns 旧信封
 */
function mirrorEnvelope(schemaVersion: number, uid: string, items: Object[]): Record<string, Object> {
  const envelope: Record<string, Object> = {}
  envelope['schemaVersion'] = schemaVersion
  envelope['uid'] = uid
  envelope['items'] = items
  return envelope
}

/**
 * 注册迁移规则单元测试。
 */
export default function persistenceMigrationUnitTest(): void {
  describe('persistenceMigrationRules', (): void => {
    it('matchesLegacyKeysByExactAndPrefix', 0, (): void => {
      const exactKeys: string[] = [
        'auth', 'sessions', 'nga_theme', 'cached_categories'
      ]
      for (let i: number = 0; i < exactKeys.length; i++) {
        expect(resolveLegacyRule(exactKeys[i]) !== null).assertTrue()
      }
      const prefixedKeys: string[] = [
        'settings_12345', 'history_12345', 'reading_progress_12345', 'votes_12345',
        'pollVoted_12345', 'tracked_threads_12345', 'ai_sessions_12345', 'ai_tool_cache_12345',
        'cached_notifications_12345', 'cached_activities_12345',
        'favorite_topic_membership_v1_12345', 'cached_profiles_v2_12345'
      ]
      for (let i: number = 0; i < prefixedKeys.length; i++) {
        expect(resolveLegacyRule(prefixedKeys[i]) !== null).assertTrue()
      }
    })

    it('rejectsNonLegacyAndNewKeys', 0, (): void => {
      expect(resolveLegacyRule('v2.settings') === null).assertTrue()
      expect(resolveLegacyRule('some_unknown_key') === null).assertTrue()
      expect(isLegacyKey('v2.history')).assertFalse()
      expect(isNewNamespaceKey('v2.history')).assertTrue()
      expect(isNewNamespaceKey('history_1')).assertFalse()
    })

    it('extractsUidFromPrefixedKey', 0, (): void => {
      const rule = resolveLegacyRule('history_12345')
      expect(rule !== null).assertTrue()
      if (rule !== null) {
        expect(rule.uidOf('history_12345')).assertEqual('12345')
        expect(rule.domainId).assertEqual(DomainIds.HISTORY)
      }
    })

    it('returnsSkippedWhenNoLegacyValues', 0, (): void => {
      const result: MigrationConvertResult = convertDomainValues(DomainIds.HISTORY, [], contextOf(''))

      expect(result.ok).assertFalse()
      expect(result.skippedReason.length > 0).assertTrue()
    })

    it('mergesHistoryByTidKeepingNewer', 0, (): void => {
      const older: Record<string, Object> = historyEntry('100', 'old', 1000)
      const newer: Record<string, Object> = historyEntry('100', 'new', 2000)
      const other: Record<string, Object> = historyEntry('200', 'other', 1500)
      const firstList: Object[] = []
      firstList.push(older)
      firstList.push(other)
      const secondList: Object[] = []
      secondList.push(newer)
      const values: LegacyValue[] = [
        legacy('history_u1', 'u1', firstList),
        legacy('history_u2', 'u2', secondList)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.HISTORY, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const merged: Object[] = result.payload as Object[]
      expect(merged.length).assertEqual(2)
      const first: Record<string, Object> = merged[0] as Record<string, Object>
      expect(String(first['subject'])).assertEqual('new')
    })

    it('capsHistoryAtMaximum', 0, (): void => {
      const items: Object[] = []
      for (let i: number = 0; i < 600; i++) {
        items.push(historyEntry(String(i), 's' + String(i), i))
      }
      const values: LegacyValue[] = [legacy('history_u1', 'u1', items)]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.HISTORY, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      expect((result.payload as Object[]).length).assertEqual(500)
    })

    it('mergesVotesKeepingNewerTimestamp', 0, (): void => {
      const first: Record<string, Object> = {}
      first['100'] = voteEntry(['a'], [], 1000)
      const second: Record<string, Object> = {}
      second['100'] = voteEntry(['a', 'b'], [], 2000)
      second['200'] = voteEntry(['c'], [], 500)
      const values: LegacyValue[] = [
        legacy('votes_u1', 'u1', first),
        legacy('votes_u2', 'u2', second)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.VOTES, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const merged: Record<string, Object> = result.payload as Record<string, Object>
      const record: Record<string, Object> = merged['100'] as Record<string, Object>
      expect((record['upPids'] as string[]).length).assertEqual(2)
    })

    it('prefersCurrentUidSettings', 0, (): void => {
      const settingsA: Record<string, Object> = {}
      settingsA['fontSize'] = 15
      settingsA['debugMode'] = false
      const settingsB: Record<string, Object> = {}
      settingsB['fontSize'] = 18
      settingsB['debugMode'] = true
      const values: LegacyValue[] = [
        legacy('settings_u1', 'u1', settingsA),
        legacy('settings_u2', 'u2', settingsB)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.SETTINGS, values, contextOf('u2'))

      expect(result.ok).assertTrue()
      const record: Record<string, Object> = result.payload as Record<string, Object>
      expect(Number(record['fontSize'])).assertEqual(18)
    })

    it('convertsMirrorEnvelopeToItemsPayload', 0, (): void => {
      const notification: Record<string, Object> = {}
      notification['notificationId'] = 'n1'
      const items: Object[] = [notification]
      const envelope: Record<string, Object> = mirrorEnvelope(3, 'u1', items)
      envelope['updatedAt'] = 1000
      const values: LegacyValue[] = [legacy('cached_notifications_u1', 'u1', envelope)]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.NOTIFICATIONS, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const payload: Record<string, Object> = result.payload as Record<string, Object>
      const converted: Object[] = payload['items'] as Object[]
      expect(converted.length).assertEqual(1)
    })

    it('clearsAiSessionOwnerUid', 0, (): void => {
      const session: Record<string, Object> = {}
      session['id'] = 's1'
      session['ownerUid'] = 'u1'
      session['messages'] = new Array<Object>()
      const items: Object[] = [session]
      const envelope: Record<string, Object> = mirrorEnvelope(1, 'u1', items)
      const values: LegacyValue[] = [legacy('ai_sessions_u1', 'u1', envelope)]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.AI_SESSIONS, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const payload: Record<string, Object> = result.payload as Record<string, Object>
      const sessions: Object[] = payload['items'] as Object[]
      const converted: Record<string, Object> = sessions[0] as Record<string, Object>
      // 取消账号隔离后会话是设备级数据：旧 owner 必须清空，否则重载时会被归属校验丢弃
      expect(String(converted['ownerUid'])).assertEqual('')
    })

    it('dropsAiToolCache', 0, (): void => {
      const emptyItems: Object[] = []
      const envelope: Record<string, Object> = mirrorEnvelope(1, 'u1', emptyItems)
      const values: LegacyValue[] = [legacy('ai_tool_cache_u1', 'u1', envelope)]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.AI_TOOL_CACHE, values, contextOf('u1'))

      expect(result.ok).assertFalse()
      expect(result.skippedReason.length > 0).assertTrue()
    })

    it('passesThroughThemePayload', 0, (): void => {
      const theme: Record<string, Object> = {}
      theme['theme'] = 'dark'
      const values: LegacyValue[] = [legacy('nga_theme', '', theme)]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.THEME, values, contextOf(''))

      expect(result.ok).assertTrue()
      const record: Record<string, Object> = result.payload as Record<string, Object>
      expect(String(record['theme'])).assertEqual('dark')
    })

    it('mergesPollVotedKeepingMaxTimestamp', 0, (): void => {
      const first: Record<string, Object> = {}
      first['100'] = 1000
      first['200'] = 500
      const second: Record<string, Object> = {}
      second['100'] = 2000
      const values: LegacyValue[] = [
        legacy('pollVoted_u1', 'u1', first),
        legacy('pollVoted_u2', 'u2', second)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.POLL_VOTED, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const merged: Record<string, Object> = result.payload as Record<string, Object>
      expect(merged['100']).assertEqual(2000)
    })

    it('mergesProfileRecords', 0, (): void => {
      const profileA: Record<string, Object> = {}
      profileA['userName'] = 'A'
      const profileB: Record<string, Object> = {}
      profileB['userName'] = 'B'
      const first: Record<string, Object> = {}
      first['u1'] = profileA
      const second: Record<string, Object> = {}
      second['u2'] = profileB
      const values: LegacyValue[] = [
        legacy('cached_profiles_v2_1', '1', first),
        legacy('cached_profiles_v2_2', '2', second)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.PROFILES, values, contextOf('1'))

      expect(result.ok).assertTrue()
      const merged: Record<string, Object> = result.payload as Record<string, Object>
      expect(Object.keys(merged).length).assertEqual(2)
    })

    it('mergesOnlyCurrentAccountMirrorValues', 0, (): void => {
      // 回归：账号镜像域不能把其它账号 uid 的旧缓存并进当前账号（否则 A 看到 B 的私信/动态）
      const mine: Record<string, Object> = {}
      mine['notificationId'] = 'n-mine'
      const other: Record<string, Object> = {}
      other['notificationId'] = 'n-other'
      const myItems: Object[] = [mine]
      const otherItems: Object[] = [other]
      const values: LegacyValue[] = [
        legacy('cached_notifications_u1', 'u1', mirrorEnvelope(3, 'u1', myItems)),
        legacy('cached_notifications_u2', 'u2', mirrorEnvelope(3, 'u2', otherItems))
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.NOTIFICATIONS, values, contextOf('u1'))

      expect(result.ok).assertTrue()
      const payload: Record<string, Object> = result.payload as Record<string, Object>
      const items: Object[] = payload['items'] as Object[]
      expect(items.length).assertEqual(1)
      const only: Record<string, Object> = items[0] as Record<string, Object>
      expect(String(only['notificationId'])).assertEqual('n-mine')
    })

    it('skipsMirrorDomainWithoutCurrentAccountValues', 0, (): void => {
      // 当前账号没有旧键时不得 fallback 到他人缓存：SKIPPED（旧键保留，登录后重试）
      const other: Record<string, Object> = {}
      other['notificationId'] = 'n-other'
      const otherItems: Object[] = [other]
      const values: LegacyValue[] = [
        legacy('cached_notifications_u2', 'u2', mirrorEnvelope(3, 'u2', otherItems))
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.NOTIFICATIONS, values, contextOf('u1'))

      expect(result.ok).assertFalse()
      expect(result.skippedReason.length > 0).assertTrue()
    })

    it('skipsMultiAccountSettingsWithoutCurrentAccountMatch', 0, (): void => {
      // 未登录且存在多份设置：不能任选一份（可能属于别的账号，含 AI Key/备注）
      const settingsA: Record<string, Object> = {}
      settingsA['fontSize'] = 15
      const settingsB: Record<string, Object> = {}
      settingsB['fontSize'] = 18
      const values: LegacyValue[] = [
        legacy('settings_u1', 'u1', settingsA),
        legacy('settings_u2', 'u2', settingsB)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.SETTINGS, values, contextOf(''))

      expect(result.ok).assertFalse()
      expect(result.skippedReason.length > 0).assertTrue()
    })

    it('skipsFavoriteMembershipWithoutCurrentAccountValues', 0, (): void => {
      // 收藏关系是账号镜像：无当前账号旧键时不得 fallback 到他人缓存
      const other: Record<string, Object> = {}
      const favored: Record<string, Object> = {}
      favored['100'] = new Array<string>()
      const known: Record<string, Object> = {}
      other['favoredFolderIds'] = favored
      other['knownFolderIds'] = known
      const values: LegacyValue[] = [
        legacy('favorite_topic_membership_v1_u2', 'u2', other)
      ]

      const result: MigrationConvertResult = convertDomainValues(
        DomainIds.FAVORITE_MEMBERSHIP, values, contextOf('u1'))

      expect(result.ok).assertFalse()
      expect(result.skippedReason.length > 0).assertTrue()
    })
  })
}
