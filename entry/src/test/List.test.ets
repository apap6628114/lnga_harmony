import localUnitTest from './LocalUnit.test';
import notificationUnitTest from './NotificationUnit.test';
import blacklistUnitTest from './BlacklistUnit.test';
import subforumUnitTest from './SubforumUnit.test';

/**
 * 注册全部本地单元测试。
 */
export default function testsuite(): void {
  localUnitTest();
  notificationUnitTest();
  blacklistUnitTest();
  subforumUnitTest();
}
