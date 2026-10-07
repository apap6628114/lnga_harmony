import { FilterListManager } from '../../../common/utils/FilterListManager'
import { WaterFilterRule, WaterFilterLevel, clampWaterLevel, validateWaterRule } from '../../../model/WaterFilterRule'
import { SettingsContext } from '../SettingsContext'
import { SettingsState } from '../SettingsState'
import { KEY_WATER_FILTER_VERSION } from '../../../common/constants/AppStorageKeys'
import { bumpAppStorageVersion } from '../../../common/utils/AppStorageVersion'

/**
 * 「智能去水」设置域子 store。
 *
 * 承载两项配置：
 * - **严格等级**（`waterFilterLevel`）：只影响内置词表的取用范围（见模型注释）；
 * - **自定义规则**（`waterFilterRules`）：任何等级下都生效，用户在设置页自行增删改。
 *
 * 判定本身不在这里，而在 `service/WaterFilterEngine`：本域只负责「配置」，
 * 引擎只负责「判定」，去水任务（`service/ThreadWaterFilterService`）把两者接起来。
 * 这样把配置改回默认值不可能影响判定逻辑本身。
 */
export class WaterFilterSettings {
  private ctx: SettingsContext
  private manager: FilterListManager<WaterFilterRule> = new FilterListManager<WaterFilterRule>()
  /** 规则标识自增序号（同一毫秒内连点新增也不撞键）。 */
  private seq: number = 0

  constructor(ctx: SettingsContext) {
    this.ctx = ctx
  }

  /**
   * 当前严格等级。
   *
   * @returns 合法区间的等级值
   */
  getLevel(): number {
    return clampWaterLevel(this.ctx.state.waterFilterLevel)
  }

  /**
   * 设置严格等级（越界值被夹取到合法区间）。
   *
   * @param level - 目标等级
   */
  setLevel(level: number): void {
    this.ctx.state.waterFilterLevel = clampWaterLevel(level)
    this.ctx.persist()
    this.bumpVersion()
  }

  /**
   * 全部自定义规则（含未启用项，保持用户录入顺序）。
   *
   * @returns 规则列表快照
   */
  getRules(): WaterFilterRule[] {
    const copy: WaterFilterRule[] = []
    const list: WaterFilterRule[] = this.ctx.state.waterFilterRules
    for (let i = 0; i < list.length; i++) {
      copy.push(list[i])
    }
    return copy
  }

  /**
   * 已启用规则的数量（入口文案与确认弹窗展示用）。
   *
   * @returns 启用中的规则数
   */
  countEnabledRules(): number {
    let count: number = 0
    const list: WaterFilterRule[] = this.ctx.state.waterFilterRules
    for (let i = 0; i < list.length; i++) {
      if (list[i].enabled) {
        count++
      }
    }
    return count
  }

  /**
   * 新增一条自定义规则。
   *
   * @param type - 规则类型（WaterRuleType）
   * @param value - 规则值（关键词或长度上限）
   * @returns 校验失败的原因；空串表示新增成功
   */
  addRule(type: string, value: string): string {
    const error: string = validateWaterRule(type, value)
    if (error.length > 0) {
      return error
    }
    const rule: WaterFilterRule = new WaterFilterRule()
    rule.id = this.nextRuleId()
    rule.enabled = true
    rule.type = type
    rule.value = value.trim()
    this.ctx.state.waterFilterRules = this.manager.add(rule)
    this.ctx.persist()
    this.bumpVersion()
    return ''
  }

  /**
   * 修改一条自定义规则。
   *
   * @param id - 规则标识
   * @param type - 新类型
   * @param value - 新规则值
   * @returns 校验失败或规则不存在的原因；空串表示修改成功
   */
  updateRule(id: string, type: string, value: string): string {
    const error: string = validateWaterRule(type, value)
    if (error.length > 0) {
      return error
    }
    const list: WaterFilterRule[] = this.ctx.state.waterFilterRules
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i].type = type
        list[i].value = value.trim()
        this.ctx.state.waterFilterRules = [...list]
        this.ctx.persist()
        this.bumpVersion()
        return ''
      }
    }
    return '规则不存在'
  }

  /**
   * 删除一条自定义规则。
   *
   * @param id - 规则标识
   */
  removeRule(id: string): void {
    this.ctx.state.waterFilterRules = this.manager.remove(
      (r: WaterFilterRule): boolean => r.id === id)
    this.ctx.persist()
    this.bumpVersion()
  }

  /**
   * 切换一条自定义规则的启用状态。
   *
   * @param id - 规则标识
   */
  toggleRule(id: string): void {
    const list: WaterFilterRule[] = this.ctx.state.waterFilterRules
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i].enabled = !list[i].enabled
        this.ctx.state.waterFilterRules = [...list]
        this.ctx.persist()
        this.bumpVersion()
        return
      }
    }
  }

  /**
   * 清空全部自定义规则。
   */
  removeAllRules(): void {
    this.manager.clear()
    this.ctx.state.waterFilterRules = this.manager.getList()
    this.ctx.persist()
    this.bumpVersion()
  }

  /**
   * 通知 UI 配置已变更（设置页角标刷新信号）。
   *
   * 配置改完之后必须调用：等级与规则只存在本域，设置页拿到的是快照，
   * 不发信号就会一直显示旧值。
   */
  private bumpVersion(): void {
    bumpAppStorageVersion(KEY_WATER_FILTER_VERSION)
  }

  /** 从持久化对象加载等级与规则（回填 FilterListManager）。 */
  load(saved: SettingsState): void {
    this.ctx.state.waterFilterLevel = clampWaterLevel(
      saved.waterFilterLevel !== undefined && saved.waterFilterLevel !== null
        ? saved.waterFilterLevel
        : WaterFilterLevel.BASIC)
    if (saved.waterFilterRules) {
      // 逐条规整：外部（旧版本或手改过的持久化对象）可能缺字段或带非法等级值
      const list: WaterFilterRule[] = []
      for (let i = 0; i < saved.waterFilterRules.length; i++) {
        const raw: WaterFilterRule = saved.waterFilterRules[i]
        if (!raw || typeof raw !== 'object') {
          continue
        }
        const rule: WaterFilterRule = new WaterFilterRule()
        rule.id = String(raw.id ?? '')
        rule.enabled = raw.enabled !== false
        rule.type = String(raw.type ?? '')
        rule.value = String(raw.value ?? '')
        if (rule.id.length === 0 || validateWaterRule(rule.type, rule.value).length > 0) {
          continue
        }
        list.push(rule)
      }
      this.ctx.state.waterFilterRules = list
      this.manager.init(list)
    }
  }

  /** 重置等级与规则（登出/切号时调用）。 */
  reset(): void {
    this.ctx.state.waterFilterLevel = WaterFilterLevel.BASIC
    this.ctx.state.waterFilterRules = []
    this.manager = new FilterListManager<WaterFilterRule>()
    this.bumpVersion()
  }

  /**
   * 生成规则标识：时间戳 + 自增序号，保证同一毫秒内连点新增也不撞键。
   */
  private nextRuleId(): string {
    this.seq++
    return 'w' + String(Date.now()) + '-' + String(this.seq)
  }
}
