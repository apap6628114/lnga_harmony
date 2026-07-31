import { checkin } from '../../../service/api/FavoriteApi'
import { AuthScope } from '../../AuthScope'
import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'

/**
 * 自动签到设置域子 store。
 *
 * 承载 autoCheckin 开关与 lastCheckinDate 字段，提供按天去重的自动签到逻辑。
 */
export class CheckinSettings {
  private ctx: SettingsContext

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  setAutoCheckin(enabled: boolean): void {
    this.ctx.state.autoCheckin = enabled
    this.ctx.persist()
  }

  /** 若启用自动签到且今日未签到，则执行签到并记录日期 */
  async autoCheckinIfNeeded(): Promise<boolean> {
    if (!this.ctx.auth!.isAuthenticated || !this.ctx.state.autoCheckin) {
      return false
    }
    const d: Date = new Date()
    const today: string = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    if (this.ctx.state.lastCheckinDate === today) {
      return false
    }
    const scope: AuthScope = AuthScope.capture(this.ctx.auth, 0)
    try {
      const result = await checkin(this.ctx.auth!.token)
      // 请求期间可能已退出/切换账号：不再记录签到日期（否则会阻塞新账号当日签到）
      if (!scope.isCurrent(this.ctx.auth, 0)) {
        return false
      }
      if (result.ok) {
        this.ctx.state.lastCheckinDate = today
        this.ctx.persist()
        return true
      }
    } catch (e) {
      // 自动签到失败静默
    }
    return false
  }

  /** 从持久化对象加载签到字段 */
  load(saved: SettingsState): void {
    if (saved.autoCheckin !== undefined) this.ctx.state.autoCheckin = saved.autoCheckin
    if (saved.lastCheckinDate) this.ctx.state.lastCheckinDate = saved.lastCheckinDate
  }
}
