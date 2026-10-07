/**
 * 软键盘沉浸样式的取色源解析。
 *
 * ## 为什么不能用 `KeyboardAppearance.IMMERSIVE`
 *
 * SDK 枚举语义（`component/text_common.d.ts`）：
 *
 * - `IMMERSIVE`——沉浸式，**跟随系统**（按系统深浅色决定键盘样式）；
 * - `LIGHT_IMMERSIVE` / `DARK_IMMERSIVE`——显式指定浅色 / 深色沉浸样式。
 *
 * 本应用主题是**三态**（跟随系统 / 固定浅色 / 固定深色，见 `ThemeSettings`）：
 * 固定主题走 `ApplicationContext.setColorMode()`，只改变**本应用**的颜色模式，
 * **不改变系统模式**。而键盘吃的是**系统**模式——两套事实源在固定主题下必然错配：
 *
 * | 场景 | 应用界面 | 键盘（IMMERSIVE 跟系统） |
 * |------|----------|--------------------------|
 * | 主题=跟随系统 | 跟系统 | 跟系统（一致） |
 * | 系统暗色 + 主题=浅色 | 浅色 | 深色（**错配**） |
 * | 系统浅色 + 主题=深色 | 深色 | 浅色（**错配**） |
 *
 * 后两行就是"键盘沉浸配色不对"的成因。因此键盘样式必须跟随
 * **应用实际生效主题**（`effectiveColorMode`）而不是系统模式，
 * 即永远显式指定 `LIGHT_` / `DARK_`，不再使用 `IMMERSIVE`。
 *
 * ## 调用约定
 *
 * 入参必须是**响应式读取**的 `effectiveColorMode`——组件内声明
 * `@StorageProp('effectiveColorMode') effectiveColorMode: string = 'light'`，
 * 并在 `build` 中传 `this.effectiveColorMode`。若改用 `AppStorage.get()` 直读，
 * 主题切换后不会重新求值，键盘样式将停留在切换前的取值。
 *
 * 注意：`@StorageProp` 的装饰器参数须为编译期字面量，无法引用
 * `KEY_EFFECTIVE_COLOR_MODE` 常量（见 `AppStorageKeys` 文件头），故此处只能约定字面量。
 *
 * ## 已知边界：密码类编辑框的沉浸样式由输入法否决（**不是本工程的缺口**）
 *
 * 本文件对**所有**编辑框一视同仁地返回 `LIGHT_` / `DARK_IMMERSIVE`，但 `.type(InputType.Password)`
 * 的编辑框上键盘仍会显示为输入法的**默认不透明皮肤**，与界面主题不融合。原因在输入法侧：
 * 密码框会进入**安全输入（防窥）**模式，输入法在该模式下**刻意忽略一切外观定制**，
 * 包括自定义皮肤与沉浸模式。华为与荣耀官方支持文档均以此为主题：
 *
 * - [华为 - 使用三方输入法设置自定义皮肤，在输入密码时不生效](https://consumer.huawei.com/cn/support/content/zh-cn00794670/)
 * - [荣耀 - 输入法自定义皮肤在输入密码时不生效如何处理](https://club-api.c.hihonor.com/cn/thread-26325895-1-1.html)
 *
 * 这属于**平台按安全要求否决**，应用侧没有开关可覆盖：`Panel.setImmersiveMode` 的最终取值
 * 由输入法应用决定（见官方《输入法应用沉浸模式》），前台应用能做的只有设置 `keyboardAppearance`
 * ——本文件已经设置。ArkUI 也未提供「掩码但不走密码类型」的替代属性
 * （`text_input.d.ts` 无任何 mask / obscure 类属性，掩码只有 `InputType.Password` 一条路）。
 *
 * 因此：**不要**为了"让密码框也沉浸"去改这里的返回逻辑，也不要给密码框加 `NONE_IMMERSIVE`
 * 之类的特判——那是把平台行为误判成缺陷。本工程受此影响的编辑框共 3 处：
 * `AiSettingsPanel` 的 API 密钥、`LoginPage` 的密码、`Dialogs` 的导出/导入加密密码。
 * 若某字段的产品决策是「可视 > 掩码」，只能改 `.type(InputType.Normal)` 换取沉浸，
 * 代价是该字段明文显示（需产品明确同意，勿擅自改）。
 */

/** `effectiveColorMode` 的取值：深色 */
const COLOR_MODE_DARK: string = 'dark'

/**
 * 解析 ArkUI 输入框（`TextInput` / `TextArea` / `Search` / `RichEditor`）的键盘沉浸样式。
 *
 * @param effectiveColorMode - 应用实际生效颜色模式（`light` / `dark`）
 * @returns 与界面主题一致的键盘沉浸样式
 */
export function resolveKeyboardAppearance(effectiveColorMode: string): KeyboardAppearance {
  if (effectiveColorMode === COLOR_MODE_DARK) {
    return KeyboardAppearance.DARK_IMMERSIVE
  }
  return KeyboardAppearance.LIGHT_IMMERSIVE
}

/**
 * 解析 `Web` 组件的键盘沉浸样式。
 *
 * Web 侧是**独立枚举** `WebKeyboardAppearanceMode`（API 26 新增，语义与
 * `KeyboardAppearance` 对齐但类型不同，不可混用），故单独提供一个解析函数。
 *
 * @param effectiveColorMode - 应用实际生效颜色模式（`light` / `dark`）
 * @returns 与界面主题一致的键盘沉浸样式
 */
export function resolveWebKeyboardAppearance(effectiveColorMode: string): WebKeyboardAppearanceMode {
  if (effectiveColorMode === COLOR_MODE_DARK) {
    return WebKeyboardAppearanceMode.DARK_IMMERSIVE
  }
  return WebKeyboardAppearanceMode.LIGHT_IMMERSIVE
}
