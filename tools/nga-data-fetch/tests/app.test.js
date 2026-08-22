/**
 * 官方 APP 签名请求层回归测试。
 */
'use strict'

const { describe, it } = require('node:test')
const assert = require('node:assert/strict')

const {
  buildAppFields,
  classifyAppJsonText,
  makeAppSign,
  parseAppCredential,
} = require('../lib/app.js')

describe('NGA APP 签名层', () => {
  it('签名与 nga-client 已知向量一致', () => {
    assert.equal(makeAppSign({
      accessUid: '123',
      accessToken: 'abc',
      signParams: '456',
      timestamp: '1700000000',
    }), 'ee748d9e20002ddbb2b4d3be109c9817')
  })

  it('Cookie 字段按首个等号安全切分', () => {
    assert.deepEqual(
      parseAppCredential('ngaPassportUid=123; ngaPassportCid=token=with=equals; foo=bar'),
      { uid: '123', token: 'token=with=equals' },
    )
  })

  it('公共字段与业务字段全部进入 POST body', () => {
    const fields = buildAppFields(
      { tid: '44191387', page: 2, __localres: 1 },
      { uid: '123', token: 'abc' },
      { output: '17', timestamp: '1700000000' },
    )
    assert.equal(fields.get('__output'), '17')
    assert.equal(fields.get('__inchst'), 'utf-8')
    assert.equal(fields.get('access_uid'), '123')
    assert.equal(fields.get('access_token'), 'abc')
    assert.equal(fields.get('tid'), '44191387')
    assert.equal(fields.get('page'), '2')
    assert.equal(fields.get('__localres'), '1')
    assert.ok(fields.get('sign'))
  })

  it('区分 APP 业务错误与 output=17 HTML 成功包', () => {
    const denied = classifyAppJsonText('{"code":403,"msg":"denied"}')
    assert.equal(denied.ok, false)
    assert.equal(denied.kind, 'app-error')
    assert.equal(denied.error, 'denied')

    const article = classifyAppJsonText('{"code":521,"html":"<html></html>"}')
    assert.equal(article.ok, true)
  })
})
