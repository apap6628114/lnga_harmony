import localUnitTest from './LocalUnit.test';
import notificationUnitTest from './NotificationUnit.test';
import blacklistUnitTest from './BlacklistUnit.test';
import subforumUnitTest from './SubforumUnit.test';
import favoriteUnitTest from './FavoriteUnit.test';
import bbcodeUnitTest from './BBCodeUnit.test';
import hotReplyUnitTest from './HotReplyUnit.test';
import threadPaginationUnitTest from './ThreadPaginationUnit.test';
import voteUnitTest from './VoteUnit.test';
import muteUnitTest from './MuteUnit.test';
import followUnitTest from './FollowUnit.test';
import sanitizerUnitTest from './SanitizerUnit.test';
import guardedRefreshUnitTest from './GuardedRefreshUnit.test';
import cacheEnvelopeUnitTest from './CacheEnvelopeUnit.test';
import topicListHtmlUnitTest from './TopicListHtmlUnit.test';
import ngaSignerUnitTest from './NgaSignerUnit.test';
import appUserTopicUnitTest from './AppUserTopicUnit.test';

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
  muteUnitTest();
  followUnitTest();
  sanitizerUnitTest();
  guardedRefreshUnitTest();
  cacheEnvelopeUnitTest();
  topicListHtmlUnitTest();
  ngaSignerUnitTest();
  appUserTopicUnitTest();
}
