import { describe, expect, it } from '@ohos/hypium'
import {
  extractScriptStoreJson,
  preprocessJson,
} from '../main/ets/parser/NgaJsonSanitizer'

/**
 * NGA JSON 净化/提取工具单元测试。
 * 覆盖 follow_v2 等接口返回 HTML 包裹 script 存储时的提取逻辑（ngaClient 修复）。
 */
export default function sanitizerUnitTest(): void {
  describe('scriptStoreExtraction', (): void => {
    it('extractsHtmlWrappedScriptStore', 0, (): void => {
      const text: string = "<html><head><meta http-equiv='Content-Type' content='text/html; charset=GBK'>" +
        "</head><body><script>window.script_muti_get_var_store={\"data\":{\"0\":{},\"1\":\"\",\"2\":\"\",\"3\":\"\",\"4\":\"\"},\"time\":1786816016}" +
        '</script></body></html>'
      const json: string | null = extractScriptStoreJson(text)
      expect(json !== null).assertTrue()
      if (json !== null) {
        const parsed: Record<string, Object> = JSON.parse(preprocessJson(json)) as Record<string, Object>
        const data: Object | undefined = parsed['data']
        expect(data !== undefined).assertTrue()
      }
    })

    it('extractsStoreEndingWithSemicolon', 0, (): void => {
      const text: string = '<script>window.script_muti_get_var_store={"data":{"0":"操作成功"}};</script>'
      const json: string | null = extractScriptStoreJson(text)
      expect(json !== null).assertTrue()
      if (json !== null) {
        const parsed: Record<string, Object> = JSON.parse(preprocessJson(json)) as Record<string, Object>
        const data: Record<string, Object> = parsed['data'] as Record<string, Object>
        expect(String(data['0'])).assertEqual('操作成功')
      }
    })

    it('extractsErrorShapedStore', 0, (): void => {
      const text: string = '<script>window.script_muti_get_var_store={"error":{"0":"你已经关注这个用户了"},"time":1}</script>'
      const json: string | null = extractScriptStoreJson(text)
      expect(json !== null).assertTrue()
      if (json !== null) {
        const parsed: Record<string, Object> = JSON.parse(preprocessJson(json)) as Record<string, Object>
        const error: Record<string, Object> = parsed['error'] as Record<string, Object>
        expect(String(error['0'])).assertEqual('你已经关注这个用户了')
      }
    })

    it('returnsNullForPlainJsonWithoutWrapper', 0, (): void => {
      const text: string = 'window.script_muti_get_var_store={"data":{}}'
      const json: string | null = extractScriptStoreJson(text)
      expect(json).assertNull()
    })

    it('returnsNullWhenNoStoreAssignment', 0, (): void => {
      const text: string = '<html><title>未登录</title></html>'
      const json: string | null = extractScriptStoreJson(text)
      expect(json).assertNull()
    })
  })
}
