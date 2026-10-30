import { describe, expect, it } from '@ohos/hypium'
import { draftUidPart, rewriteDraftKeyUidPart, shortHash36 } from '../main/ets/common/utils/DraftKeyUtils'

/**
 * 草稿键账号片段工具（跨账号导入找回草稿的纯函数层）。
 *
 * 回归背景：草稿键末尾是 uid 短哈希；导入到另一个账号时键上的哈希是导出账号的，
 * 编辑器按当前账号哈希查找会"丢失草稿"。导入器用 `rewriteDraftKeyUidPart` 改写为当前账号片段。
 */
export default function draftKeyUtilsUnitTest(): void {
  describe('draftKeyUtils', (): void => {
    it('shortHash36KeepsKnownValues', 0, (): void => {
      // 算法不可变（变了既有草稿键全部失效），锁定已知值
      expect(shortHash36('u1')).assertEqual('16k06r')
      expect(shortHash36('42023922')).assertEqual('2jceso')
    })

    it('shortHash36IsStableAndUnsigned', 0, (): void => {
      expect(shortHash36('uid-abc')).assertEqual(shortHash36('uid-abc'))
      expect(shortHash36('uid-abc').indexOf('-')).assertEqual(-1)
      expect(shortHash36('uid-abc') !== shortHash36('uid-abd')).assertTrue()
    })

    it('draftUidPartFallsBackToAnon', 0, (): void => {
      expect(draftUidPart('')).assertEqual('anon')
      expect(draftUidPart('u1')).assertEqual('16k06r')
    })

    it('rewritesReplyDraftKeyTail', 0, (): void => {
      // 回复草稿：draft_<tid>_edit_<pid>_<uidPart>
      const rewritten: string = rewriteDraftKeyUidPart('draft_123_edit_456_oldhash', 'newhash')
      expect(rewritten).assertEqual('draft_123_edit_456_newhash')
    })

    it('rewritesNewTopicDraftKeyTail', 0, (): void => {
      // 发帖草稿：draft_newtopic_<fid>[_stid<stid>]_<uidPart>
      expect(rewriteDraftKeyUidPart('draft_newtopic_7_oldhash', 'newhash'))
        .assertEqual('draft_newtopic_7_newhash')
      expect(rewriteDraftKeyUidPart('draft_newtopic_7_stid9_oldhash', 'newhash'))
        .assertEqual('draft_newtopic_7_stid9_newhash')
    })

    it('keepsKeyWhenAlreadyCurrentOrUnrecognized', 0, (): void => {
      // 已经是当前账号片段：不变
      expect(rewriteDraftKeyUidPart('draft_1_2_newhash', 'newhash')).assertEqual('draft_1_2_newhash')
      // 无法识别（无分隔符）：原样返回，避免把非法键改得更坏
      expect(rewriteDraftKeyUidPart('draftkey', 'newhash')).assertEqual('draftkey')
    })
  })
}
