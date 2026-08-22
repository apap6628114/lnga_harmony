import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { parseHtmlToRawJson } from '../src/parser/nga/html-thread/index'

/**
 * 构造 APP `__output=17 + __localres=1` 的最小帖子 HTML。
 *
 * 样本刻意包含 `_pid` 贴条 postArg，且 setDefault 省略网页模式最后的 pageSize，
 * 用于防止贴条覆盖主楼与分页参数错位回归。
 *
 * @returns 最小 APP HTML
 */
function createAppHtmlFixture(): string {
  return `
    <script>
      __CURRENT_TID=44191387;
      __CURRENT_FID=-7;
      __CURRENT_PAGE=1;
      __CURRENT_PAGE_POSTS=20;
      commonui.userInfo.setAll({"205511":{"uid":205511,"username":"gerraerd"}});
      commonui.postArg.setDefault(-7,0,44191387,205511,33,"","","","",null,0,540,1787358664);
    </script>
    <h2 id='currentForumName'>网事杂谈</h2>
    <h1 id='currentTopicName'>测试主题</h1>
    <span id='postdate0'>2025-05-26 17:27</span>
    <h3 id='postsubject0'>测试主题</h3>
    <span id='postcontent0'>主楼正文</span>
    <script>
      commonui.postArg.proc(0,null,null,null,null,null,null,null,null,null,0,33554432,null,'205511',1748251672,'0,0,0','4','','','7 iOS','',null);
      commonui.postArg.proc('_824921555',null,null,null,null,null,null,null,null,null,824921555,1,null,'205511',1748252378,'0,0,0',null,'','',null,'',null,0,0);
    </script>
  `
}

/**
 * APP HTML 页面解释回归。
 */
describe('APP output=17 HTML 解释', () => {
  it('贴条伪楼号不覆盖主楼元数据', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlFixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const rows: Record<string, Object> = data['__R'] as Record<string, Object>
    const main: Record<string, Object> = rows['0'] as Record<string, Object>
    assert.equal(main['pid'], 0)
    assert.equal(main['authorid'], '205511')
    assert.equal(main['postdatetimestamp'], 1748251672)
    assert.equal(main['from_client'], '7 iOS')
  })

  it('无 pageSize 的 setDefault 仍按固定位置解释分页', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlFixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const topic: Record<string, Object> = data['__T'] as Record<string, Object>
    assert.equal(data['__ROWS'], 541)
    assert.equal(data['__R__ROWS_PAGE'], 20)
    assert.equal(topic['lastpost'], 1787358664)
  })
})
