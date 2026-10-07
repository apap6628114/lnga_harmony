import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { parseHtmlToRawJson } from '../src/parser/nga/html-thread/index'
import { extractPostAuthorKey, extractTopicAuthorKey } from '../src/parser/nga/html-thread/PostArgScanner'

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
 * 构造 APP `__output=17 + __localres=1` 的第 2 页帖子 HTML。
 *
 * 跨页视图下楼主（lou=0）不在当前页楼层中，页面仅凭 setDefault 的 tAid
 * （index 3）提供主题作者；当前页首楼 authorid 不得冒充主题作者，
 * 主题创建时间（__T.postdate）页面未提供。
 *
 * @returns 最小跨页 APP HTML
 */
function createAppHtmlPage2Fixture(): string {
  return `
    <script>
      __CURRENT_TID=44191387;
      __CURRENT_FID=-7;
      __CURRENT_PAGE=2;
      __CURRENT_PAGE_POSTS=20;
      commonui.userInfo.setAll({"999999":{"uid":999999,"username":"page2user"}});
      commonui.postArg.setDefault(-7,0,44191387,205511,33,"","","","",null,0,540,1787358664);
    </script>
    <h2 id='currentForumName'>网事杂谈</h2>
    <h1 id='currentTopicName'>测试主题</h1>
    <span id='postdate20'>2025-05-27 10:00</span>
    <span id='postcontent20'>第 2 页首楼正文</span>
    <script>
      commonui.postArg.proc(20,null,null,null,null,null,null,null,null,null,880000001,0,null,'999999',1748350800,'0,0,0',null,'','','8 Android','',null);
    </script>
  `
}

/**
 * 构造匿名帖（`__output=17`）的首页 HTML 样本。
 *
 * 真实形态（实测 tid=46151001）：匿名楼层的 `proc` 第 13 参是**页内局部**负数
 * （`-1`/`-2`…），同一匿名用户在 `userInfo.setAll` 里的 `username` 才是稳定身份
 * （`#anony_<32 位十六进制>`，同帖稳定）；主题作者 tAid 也是另一个局部负数。
 * 样本里 lou=0/1 为楼主匿名楼（局部 -1/-2），lou=2 为另一匿名用户（局部 -3）。
 *
 * @returns 最小匿名帖 APP HTML
 */
function createAppHtmlAnonymousFixture(): string {
  return `
    <script>
      __CURRENT_TID=46151001;
      __CURRENT_FID=-7;
      __CURRENT_PAGE=1;
      __CURRENT_PAGE_POSTS=20;
      commonui.userInfo.setAll({"63017029":{"uid":63017029,"username":"伏夏雪子"},"-1":{"uid":0,"username":"#anony_181a8ac0faf810510ae311cd2b044594"},"-2":{"uid":0,"username":"#anony_181a8ac0faf810510ae311cd2b044594"},"-3":{"uid":0,"username":"#anony_7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f"}});
      commonui.postArg.setDefault(-7,0,46151001,-4,0,"","","","",null,262144,4,1770376766);
    </script>
    <h2 id='currentForumName'>网事杂谈</h2>
    <h1 id='currentTopicName'>试试匿名</h1>
    <span id='postdate0'>2026-02-06 17:17</span>
    <span id='postcontent0'>主楼正文</span>
    <span id='postdate1'>2026-02-06 17:17</span>
    <span id='postcontent1'>楼主匿名再回一楼</span>
    <span id='postdate2'>2026-02-06 19:14</span>
    <span id='postcontent2'>另一个匿名用户的回复</span>
    <script>
      commonui.postArg.proc( 0,null,null,null,null,null,null,null,null,null,33816576,262144,null,'-1',1770369426,'0,0,0','6','','','8 Android','',null,0 );
      commonui.postArg.proc( 1,null,null,null,null,null,null,null,null,null,857247116,262144,null,'-2',1770369450,'0,0,0','8','','','8 Android','',null,0 );
      commonui.postArg.proc( 2,null,null,null,null,null,null,null,null,null,857260603,0,null,'-3',1770376448,'0,0,0','8','','','8 Android','',null,0 );
    </script>
  `
}

/**
 * 构造同一匿名帖第 2 页 HTML（主楼不在页内，局部 uid 逐页重排）。
 *
 * 形态取自**真实抓包**（tid=47680877 page=2，`read.php __output=17`）：该页 `__U`
 * 里**没有任何负键、也没有 `#anony_`**，tAid 与页内 uid 是两套局部号，页面的
 * `__T.author`/首楼 authorid 是当页首楼那位**普通用户**（实测 41976057 幸运D的yby），
 * 与匿名楼主完全无关。故主题作者稳定键在本页**无法判定**，必须置空串。
 *
 * @returns 最小匿名帖第 2 页 APP HTML
 */
function createAppHtmlAnonymousPage2Fixture(): string {
  return `
    <script>
      __CURRENT_TID=46151001;
      __CURRENT_FID=-7;
      __CURRENT_PAGE=2;
      __CURRENT_PAGE_POSTS=20;
      commonui.userInfo.setAll({"41976057":{"uid":41976057,"username":"幸运D的yby"},"450870":{"uid":450870,"username":"fortheall"}});
      commonui.postArg.setDefault(-7,0,46151001,-1,0,"","","","",null,262144,4,1770376766);
    </script>
    <h2 id='currentForumName'>网事杂谈</h2>
    <h1 id='currentTopicName'>试试匿名</h1>
    <span id='postdate20'>2026-02-07 09:00</span>
    <span id='postcontent20'>第 2 页首楼（普通用户）</span>
    <span id='postdate21'>2026-02-07 09:10</span>
    <span id='postcontent21'>第 2 页第二楼（普通用户）</span>
    <script>
      commonui.postArg.proc( 20,null,null,null,null,null,null,null,null,null,900000001,0,null,'41976057',1770426000,'0,0,0','8','','','8 Android','',null,0 );
      commonui.postArg.proc( 21,null,null,null,null,null,null,null,null,null,900000002,0,null,'450870',1770426600,'0,0,0','8','','','8 Android','',null,0 );
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

  it('主题作者以 setDefault tAid 为准，含主楼页恢复作者名与主题时间', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlFixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const topic: Record<string, Object> = data['__T'] as Record<string, Object>
    assert.equal(topic['authorid'], 205511)
    assert.equal(topic['author'], 'gerraerd')
    assert.equal(topic['postdate'], 1748251672)
  })

  it('跨页视图不把首楼作者冒充主题作者，页面未提供的字段置空', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlPage2Fixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const topic: Record<string, Object> = data['__T'] as Record<string, Object>
    // tAid（setDefault index 3）与 JSON __T.authorid 同源，跨页仍可恢复
    assert.equal(topic['authorid'], 205511)
    // 楼主不在当前页 __U，页面未提供主题作者名，不得取首楼作者 page2user
    assert.equal(topic['author'], '')
    // 主题创建时间仅含主楼页可恢复；跨页置 0 而非取首楼时间
    assert.equal(topic['postdate'], 0)
    // 当前页楼层行不受影响
    const rows: Record<string, Object> = data['__R'] as Record<string, Object>
    const first: Record<string, Object> = rows['20'] as Record<string, Object>
    assert.equal(first['authorid'], '999999')
    assert.equal(first['postdatetimestamp'], 1748350800)
  })

  it('匿名楼层的稳定作者标识取 __U 的 #anony_ 名，而非页内局部负数 uid', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlAnonymousFixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const rows: Record<string, Object> = data['__R'] as Record<string, Object>
    // 楼层元数据仍是页面局部负数 uid（保持既有数字语义，引用/资料卡等沿用）
    assert.equal((rows['0'] as Record<string, Object>)['authorid'], '-1')
    assert.equal((rows['1'] as Record<string, Object>)['authorid'], '-2')
    assert.equal((rows['2'] as Record<string, Object>)['authorid'], '-3')
    // authorKey 才是可跨页比较的稳定身份：楼主两楼同键，别的匿名用户不同键
    assert.equal((rows['0'] as Record<string, Object>)['authorKey'], '#anony_181a8ac0faf810510ae311cd2b044594')
    assert.equal((rows['1'] as Record<string, Object>)['authorKey'], '#anony_181a8ac0faf810510ae311cd2b044594')
    assert.equal((rows['2'] as Record<string, Object>)['authorKey'], '#anony_7c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f')
    // 普通用户楼层回落为 uid 数字串，与既有的数字判据等价
    assert.equal((rows['2'] as Record<string, Object>)['authorid'], '-3')
  })

  it('匿名主题作者：tAid 是其页内局部号且不在 __U 时，取主楼稳定键', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlAnonymousFixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const topic: Record<string, Object> = data['__T'] as Record<string, Object>
    const rows: Record<string, Object> = data['__R'] as Record<string, Object>
    // tAid=-4 是页内局部号：extractTopicAuthorId 不接受非正数（匿名时为负），
    // 数字语义下回落到当前页首楼 uid（既有行为，保持不破坏）
    assert.equal(topic['authorid'], -1)
    // 稳定键必须与主楼一致，否则「楼主」标记无从判定
    assert.equal(topic['authorKey'], (rows['0'] as Record<string, Object>)['authorKey'])
    // 旧判据（拿 __T.authorid 比楼层 authorid）在匿名帖下必然认不出楼主后续楼层
    assert.notEqual(String((rows['1'] as Record<string, Object>)['authorid']), String(topic['authorid']))
  })

  it('匿名帖非首页：tAid 与匿名条目都不在本页时主题键为未知，绝不拿首楼作者冒充楼主', () => {
    const parsed: Record<string, Object> = parseHtmlToRawJson(createAppHtmlAnonymousPage2Fixture()) as Record<string, Object>
    const data: Record<string, Object> = parsed['data'] as Record<string, Object>
    const topic: Record<string, Object> = data['__T'] as Record<string, Object>
    const rows: Record<string, Object> = data['__R'] as Record<string, Object>
    // 真实形态：本页无 #anony_ 条目，tAid(-1) 也不在 __U → 主题键未知（空串）
    assert.equal(topic['authorKey'], '')
    // 数字语义字段仍是当页首楼作者（既有行为），但绝不能升格成"楼主身份"
    assert.equal(topic['authorid'], 41976057)
    assert.equal(String((rows['20'] as Record<string, Object>)['authorKey']), '41976057')
    assert.notEqual(String((rows['20'] as Record<string, Object>)['authorKey']), String(topic['authorKey']))
    // 普通楼层键 = uid 数字串，与既有的数字判据等价
    assert.equal(String((rows['21'] as Record<string, Object>)['authorKey']), '450870')
  })

  it('匿名帖跨页：非首页无法判定主题键，客户端须跳过标记而不是标错人', () => {
    const page1: Record<string, Object> = parseHtmlToRawJson(createAppHtmlAnonymousFixture()) as Record<string, Object>
    const page2: Record<string, Object> = parseHtmlToRawJson(createAppHtmlAnonymousPage2Fixture()) as Record<string, Object>
    const rows1: Record<string, Object> = (page1['data'] as Record<string, Object>)['__R'] as Record<string, Object>
    const topicKey1: string = String(((page1['data'] as Record<string, Object>)['__T'] as Record<string, Object>)['authorKey'])
    const topicKey2: string = String(((page2['data'] as Record<string, Object>)['__T'] as Record<string, Object>)['authorKey'])
    // 首页能认出匿名楼主
    assert.equal(topicKey1, '#anony_181a8ac0faf810510ae311cd2b044594')
    assert.equal(String((rows1['0'] as Record<string, Object>)['authorKey']), topicKey1)
    // 非首页判不出：空串（未知）而不是当页首楼作者——否则会把陌生人标成楼主
    assert.equal(topicKey2, '')
    assert.notEqual(String(((page2['data'] as Record<string, Object>)['__T'] as Record<string, Object>)['authorid']), topicKey2)
  })
})

/**
 * `extractPostAuthorKey` 纯函数回归（匿名身份判定的唯一入口）。
 */
describe('匿名稳定作者标识推导', () => {
  const userInfo: Record<string, Object> = {
    '205511': { uid: 205511, username: 'gerraerd' } as Object,
    '-1': { uid: 0, username: '#anony_181a8ac0faf810510ae311cd2b044594' } as Object,
    '-4': { uid: 0, username: '#anony_181a8ac0faf810510ae311cd2b044594' } as Object,
  }

  it('匿名条目取 __U 的 #anony_ 编码名（页内局部 uid 不入键）', () => {
    assert.equal(extractPostAuthorKey(userInfo, '-1'),
      '#anony_181a8ac0faf810510ae311cd2b044594')
    // 同一匿名用户换到别的局部号（下一页重排）仍是同一个键
    assert.equal(extractPostAuthorKey(userInfo, '-1'), extractPostAuthorKey(userInfo, '-4'))
  })

  it('普通条目回落 uid 数字串，与旧判据等价', () => {
    assert.equal(extractPostAuthorKey(userInfo, '205511'), '205511')
    assert.equal(extractPostAuthorKey(userInfo, "'205511'"), '205511')
    // 用户表缺失（跨页、贴条等）也按 uid 数字串回落
    assert.equal(extractPostAuthorKey({}, '63017029'), '63017029')
  })

  it('uid 原串本身就是 #anony_ 编码名时直接用（无用户表也能判匿名）', () => {
    assert.equal(extractPostAuthorKey({}, '#anony_181a8ac0faf810510ae311cd2b044594'),
      '#anony_181a8ac0faf810510ae311cd2b044594')
  })

  it('无法判定返回空串（不产生可误判为楼主的键）', () => {
    assert.equal(extractPostAuthorKey(userInfo, ''), '')
    assert.equal(extractPostAuthorKey(userInfo, 'abc'), '')
  })
})

/**
 * `extractTopicAuthorKey` 纯函数回归：主题作者（楼主）稳定标识的判定边界。
 */
describe('主题作者稳定标识推导', () => {
  const userInfo: Record<string, Object> = {
    '205511': { uid: 205511, username: 'gerraerd' } as Object,
    '-1': { uid: 0, username: '#anony_181a8ac0faf810510ae311cd2b044594' } as Object,
  }

  it('主楼在页内时直接取主楼键（最可靠，与 tAid 是否可解析无关）', () => {
    // 实测首页：tAid=-4 不在 __U，但主楼在页内 → 仍能拿到匿名楼主的编码名
    assert.equal(extractTopicAuthorKey(userInfo, '-4', true,
      '#anony_181a8ac0faf810510ae311cd2b044594'), '#anony_181a8ac0faf810510ae311cd2b044594')
    // 普通帖：主楼键即 uid 数字串
    assert.equal(extractTopicAuthorKey(userInfo, '205511', true, '205511'), '205511')
  })

  it('主楼不在页内时只信 tAid 命中的正数 uid（普通帖跨页场景）', () => {
    assert.equal(extractTopicAuthorKey(userInfo, '205511', false, ''), '205511')
  })

  it('主楼不在页内时，tAid 命中匿名条目也不采用（可能是另一个匿名用户）', () => {
    // 页内局部号逐页重排：非首页拿局部负号去 __U 撞，撞到的可能是别的匿名用户
    assert.equal(extractTopicAuthorKey(userInfo, '-1', false, ''), '')
  })

  it('主楼不在页内且 tAid 条目缺席时返回空串（未知），不猜当页首楼作者', () => {
    // 实测 tid=47680877 p2/p3：__U 无负键、无 #anony_，tAid（局部号 -1）不在表内 →
    // 若在这里回落"当页首楼作者"，客户端就会把该陌生人标成楼主
    assert.equal(extractTopicAuthorKey(userInfo, '41976057', false, ''), '')
    assert.equal(extractTopicAuthorKey(userInfo, '', false, ''), '')
    // 即便调用方误传了首楼的 key，只要没有可信来源就不采用
    assert.equal(extractTopicAuthorKey(userInfo, '', false, '41976057'), '')
  })
})
