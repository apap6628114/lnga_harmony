import { describe, expect, it } from '@ohos/hypium'
import { md5Hex, makeSign } from '../main/ets/common/security/NgaSigner'

/**
 * NGA 主接口签名（NgaSigner）回归测试。
 *
 * 基准值取自 nga-hack/nga-client（Node 侧 makeSign/md5，官方客户端签名实现），
 * 用于验证 ArkTS 侧 MD5 与主签名字符串拼接与官方客户端一致。
 */
export default function ngaSignerUnitTest(): void {
  describe('ngaSigner', (): void => {
    it('md5HexMatchesKnownVectors', 0, (): void => {
      expect(md5Hex('')).assertEqual('d41d8cd98f00b204e9800998ecf8427e')
      expect(md5Hex('abc')).assertEqual('900150983cd24fb0d6963f7d28e17f72')
    })

    it('makeSignMatchesNgaClient', 0, (): void => {
      expect(makeSign({
        appId: '1010', accessUid: '123', accessToken: 'abc', signParams: '456', ts: '1700000000',
      })).assertEqual('ee748d9e20002ddbb2b4d3be109c9817')
      expect(makeSign({
        accessUid: '42023922', accessToken: 'cidTok', signParams: '42023922', ts: '1758307501',
      })).assertEqual('a37671e0ea676a632662bfae8e491378')
    })
  })
}
