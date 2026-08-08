import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { normalizeFontFamily } from '../src/common/components/bbcode/bbcode-utils'

// ---------------------------------------------------------------------------
// normalizeFontFamily：常见字体名归类为衬线/无衬线/等宽三族 + 回退链
// ---------------------------------------------------------------------------

describe('normalizeFontFamily 字体归类与回退链', () => {
  it('拉丁衬线专名返回「规范名,serif」回退链', () => {
    assert.equal(normalizeFontFamily('Times New Roman'), 'Times New Roman,serif')
    assert.equal(normalizeFontFamily('georgia'), 'Georgia,serif')
    assert.equal(normalizeFontFamily('Book Antiqua'), 'Book Antiqua,serif')
  })

  it('拉丁无衬线专名返回「规范名,sans-serif」回退链', () => {
    assert.equal(normalizeFontFamily('Arial'), 'Arial,sans-serif')
    assert.equal(normalizeFontFamily('Tahoma'), 'Tahoma,sans-serif')
    assert.equal(normalizeFontFamily('Verdana'), 'Verdana,sans-serif')
    assert.equal(normalizeFontFamily('Trebuchet MS'), 'Trebuchet MS,sans-serif')
    assert.equal(normalizeFontFamily('Century Gothic'), 'Century Gothic,sans-serif')
    assert.equal(normalizeFontFamily('Comic Sans MS'), 'Comic Sans MS,sans-serif')
    assert.equal(normalizeFontFamily('Impact'), 'Impact,sans-serif')
    assert.equal(normalizeFontFamily('Script MT Bold'), 'Script MT Bold,sans-serif')
  })

  it('长名优先：Arial Black 不被 Arial 子串抢占', () => {
    assert.equal(normalizeFontFamily('Arial Black'), 'Arial Black,sans-serif')
  })

  it('等宽专名返回「规范名,monospace」回退链', () => {
    assert.equal(normalizeFontFamily('Courier New'), 'Courier New,monospace')
    assert.equal(normalizeFontFamily('Lucida Console'), 'Lucida Console,monospace')
    assert.equal(normalizeFontFamily('Consolas'), 'Consolas,monospace')
    assert.equal(normalizeFontFamily('Courier'), 'Courier,monospace')
  })

  it('中文/拼音别名直接返回保底族', () => {
    assert.equal(normalizeFontFamily('宋体'), 'serif')
    assert.equal(normalizeFontFamily('simsun'), 'serif')
    assert.equal(normalizeFontFamily('楷体'), 'serif')
    assert.equal(normalizeFontFamily('黑体'), 'sans-serif')
    assert.equal(normalizeFontFamily('simhei'), 'sans-serif')
    assert.equal(normalizeFontFamily('微软雅黑'), 'sans-serif')
    assert.equal(normalizeFontFamily('Microsoft YaHei'), 'sans-serif')
  })

  it('通用族名直接返回自身', () => {
    assert.equal(normalizeFontFamily('serif'), 'serif')
    assert.equal(normalizeFontFamily('sans-serif'), 'sans-serif')
    assert.equal(normalizeFontFamily('monospace'), 'monospace')
  })

  it('未知字体名原样返回', () => {
    assert.equal(normalizeFontFamily('Futura'), 'Futura')
    assert.equal(normalizeFontFamily('Noto Serif CJK SC'), 'Noto Serif CJK SC')
  })

  it('空值/纯空白/超长返回空串，引号剥离后仍归类', () => {
    assert.equal(normalizeFontFamily(''), '')
    assert.equal(normalizeFontFamily('   '), '')
    assert.equal(normalizeFontFamily('x'.repeat(65)), '')
    assert.equal(normalizeFontFamily('"宋体"'), 'serif')
    assert.equal(normalizeFontFamily(' "Times New Roman" '), 'Times New Roman,serif')
  })
})
