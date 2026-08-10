import localUnitTest from './LocalUnit.test';
import notificationUnitTest from './NotificationUnit.test';
import blacklistUnitTest from './BlacklistUnit.test';
import subforumUnitTest from './SubforumUnit.test';
import favoriteUnitTest from './FavoriteUnit.test';
import bbcodeUnitTest from './BBCodeUnit.test';
import hotReplyUnitTest from './HotReplyUnit.test';
import threadPaginationUnitTest from './ThreadPaginationUnit.test';
import voteUnitTest from './VoteUnit.test';

/**
 * 注册全部本地单元测试。
 */
export default function testsuite(): void {
  localUnitTest();
  notificationUnitTest();
  blacklistUnitTest();
  subforumUnitTest();
  favoriteUnitTest();
  bbcodeUnitTest();
  hotReplyUnitTest();
  threadPaginationUnitTest();
  voteUnitTest();
}
