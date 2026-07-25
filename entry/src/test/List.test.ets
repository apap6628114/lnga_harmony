import localUnitTest from './LocalUnit.test';
import notificationUnitTest from './NotificationUnit.test';

export default function testsuite() {
  localUnitTest();
  notificationUnitTest();
}
