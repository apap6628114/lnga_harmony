import { describe, expect, it } from '@ohos/hypium'
import { extractAppUser, extractAppUserError } from '../main/ets/parser/AppUserParser'

/**
 * NGA 用户 APP 接口解析单元测试。
 */
export default function appUserUnitTest(): void {
  describe('appUserResponse', (): void => {
    it('extractsResultUser', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"result":{"uid":"123","username":"tester"}}')
      const user = extractAppUser(raw)
      expect(user !== null).assertTrue()
      if (user !== null) {
        expect(String(user['uid'])).assertEqual('123')
        expect(String(user['username'])).assertEqual('tester')
      }
    })

    it('extractsDataZeroUser', 0, (): void => {
      const raw: object = JSON.parse('{"code":0,"data":{"0":{"uid":"456","username":"demo"}}}')
      const user = extractAppUser(raw)
      expect(user !== null).assertTrue()
      if (user !== null) {
        expect(String(user['uid'])).assertEqual('456')
      }
    })

    it('readsAppErrorMessage', 0, (): void => {
      const raw: object = JSON.parse('{"code":1,"msg":"会话失效"}')
      expect(extractAppUserError(raw, '获取失败')).assertEqual('会话失效')
    })
  })
}
