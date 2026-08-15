import { motion } from '@kit.MultimodalAwarenessKit'
import { BusinessError } from '@kit.BasicServicesKit'
import { appStore } from '../../store/AppStore'
import { Logger, DOMAIN_UI } from '../utils/Logger'

/** 设备握持状态。 */
export enum HoldingHandStatus {
  /** 未检测到握持。 */
  NOT_HELD = 0,
  /** 左手握持。 */
  LEFT_HAND_HELD = 1,
  /** 右手握持。 */
  RIGHT_HAND_HELD = 2,
  /** 双手握持。 */
  BOTH_HANDS_HELD = 3,
  /** 无法识别的握持状态。 */
  UNKNOWN_STATUS = 16
}

const logger: Logger = new Logger(DOMAIN_UI, 'HoldingHandMonitor')

/**
 * 设备握持状态监测器。
 *
 * 封装 motion 'holdingHandChanged' 的注册/注销与智能持握开关判断；
 * 收到状态变化时先回调调用方更新 UI（动画），再把状态持久化到设置。
 * 页面在 aboutToAppear 调用 {@link start}、aboutToDisappear 调用 {@link stop}。
 */
export class HoldingHandMonitor {
  /** 当前已注册的握持回调；未注册时为 null。 */
  private callback: Callback<HoldingHandStatus> | null = null

  /**
   * 注册握持监测。
   *
   * 智能持握关闭时不注册；回调在每次状态变化时触发，顺序与原实现一致：
   * 先调用 owner 更新 UI，再持久化到设置。
   *
   * @param owner - 组件侧状态更新回调（持有 @State holdingStatus 的页面）
   */
  start(owner: (status: HoldingHandStatus) => void): void {
    if (!appStore.settings.smartGrip) {
      return
    }
    this.callback = (data: HoldingHandStatus): void => {
      owner(data)
      if (appStore.settings.holdingHand !== data) {
        appStore.settingsStore.setHoldingHand(data)
      }
    }
    try {
      motion.on('holdingHandChanged', this.callback)
    } catch (err) {
      logger.error('startHolding fail: %{public}d', (err as BusinessError).code)
    }
  }

  /**
   * 注销握持监测。
   */
  stop(): void {
    const callback: Callback<HoldingHandStatus> | null = this.callback
    this.callback = null
    if (callback === null) {
      return
    }
    try {
      motion.off('holdingHandChanged', callback)
    } catch (err) {
      logger.error('stopHolding fail: %{public}d', (err as BusinessError).code)
    }
  }
}
