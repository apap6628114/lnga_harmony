# 主题（Theme）设计约束

本文记录本工程亮/暗色主题（原味 / 暗色 / 跟随系统）的实现契约、**主题全局化（不随 UID 隔离）**、
冷启动时序与官方对齐依据。与 [`IMMERSIVE_LIGHT_DESIGN.md`](IMMERSIVE_LIGHT_DESIGN.md)（沉浸光感材质）
互补：本文管"主题与系统栏"，后者管"材质与自动反色"。

## 1. 主题选项与资源映射

| 主题 | 内存真源 `ThemeSettings.theme`（私有字段，全局设置） | 应用 `setColorMode` | 资源 |
| --- | --- | --- | --- |
| 跟随系统 | `'system'` | `COLOR_MODE_NOT_SET`（默认，跟随系统） | 系统深浅色自动切换 |
| 原味主题 | `'light'` | `COLOR_MODE_LIGHT`（强制） | `base/element/color.json` |
| 暗色主题 | `'dark'` | `COLOR_MODE_DARK`（强制） | `dark/element/color.json` |

- 选项元数据见 `Constants.ets` 的 `THEME_OPTIONS`（system/light/dark 三项）。
- `AppColors` 全部通过 `$r('app.color.*')` 静态引用，`setColorMode` 驱动资源自动切换；
  **禁止**在属性设置中用函数返回值实现深浅色切换（官方不推荐，热更新不保证重执行）。
- 生效模式写入 AppStorage `KEY_EFFECTIVE_COLOR_MODE`（`'light'`/`'dark'`），页面经
  `@StorageProp('effectiveColorMode')` 消费（表情白底判断等）。

## 2. 主题是全局设置（不随 UID 隔离）

**背景**：早期 theme 字段随 `settings_${uid}` 持久化，未登录用户无法保存主题
（`persistSettings`/`loadUserSettings` 均依赖 `auth.uid`），"跟随系统"设置冷启动即失效。

**现状**（`ThemeSettings.ets`）：

- 主题持久化在**全局 key `nga_theme`**（Preferences 库 `nga_app_store`，与账号无关）。
- `AppStore.init` 无条件调用 `settingsStore.initTheme()` → `ThemeSettings.loadGlobal()`，
  在 `applyCurrentTheme()` 之前完成——未登录用户同样跨冷启动生效。
- `setTheme` 走 `persistGlobal()`（不依赖 uid 门禁）。
- 登出/切号（`SettingsStore.reset`）时主题**不随账号重置**：`ThemeSettings.restoreGlobal()`
  以 AppStorage `KEY_THEME_NAME`（当前生效值）对齐内存真源，保证后续 `applyCurrentTheme`
  取值一致。
- **theme 内存真源是 `ThemeSettings` 私有字段，不进入 `SettingsState`**：
  `settings_${uid}` 持久化数据中不含主题，无旧数据兼容/迁移需求。

## 3. 冷启动时序契约（状态栏图标与主题一致性）

**信息源规则（易错点）**：

- `resourceManager.getConfigurationSync().colorMode` / `context.config.colorMode` 返回**应用当前生效**
  颜色模式——应用强制 light/dark 期间读到的是固定值，**不是系统真实模式**；
- 系统真实模式须经**系统级订阅** `ApplicationContext.onSystemConfigurationUpdated`
  （API 24+，`onColorModeUpdated` 回调）获取，它不受应用 `setColorMode` 影响，
  任何时刻系统切换深浅色都会回调；
- `onConfigurationUpdate` 不适合作为深浅色通道：应用主动 `setColorMode` 后官方语义下
  不再回调；且固定模式切回跟随系统的切换事件中 `colorMode` 可能为 NOT_SET，无法判定。

**时序流程**：

```
onCreate
  ├─ resourceManager.getConfigurationSync().colorMode 初始化
  │   KEY_SYSTEM_COLOR_MODE（系统真实模式缓存）与 KEY_EFFECTIVE_COLOR_MODE
  │  （冷启动应用默认跟随系统，此时该 API 返回系统真实值，二者一致）
  ├─ 注册 onSystemConfigurationUpdated：任何时刻系统切换 → 刷新 KEY_SYSTEM_COLOR_MODE；
  │   主题为 system 时同步 KEY_EFFECTIVE_COLOR_MODE + 状态栏
  └─ appStore.init() 异步开始
onWindowStageCreate → loadContent 回调（窗口+页面就绪）
  ├─ init 已完成 → 重放 settingsStore.applyCurrentTheme()
  │   （官方 NOTE：setColorMode 须在窗口创建且页面加载后调用，此处兜底保证时机）
  └─ init 未完成 → 按 onCreate 缓存值刷新状态栏；init 完成后 applyCurrentTheme 接管
appStore.init 完成 → applyCurrentTheme()
  ├─ system → setColorMode(NOT_SET) + effectiveTheme 读 KEY_SYSTEM_COLOR_MODE（系统真实值）
  ├─ light/dark → setColorMode(LIGHT/DARK) + effectiveTheme 固定
  └─ updateStatusBarStyle(effectiveTheme === 'dark')
```

**三主题往返切换自洽性**（系统暗色为例）：

| 操作 | 系统真实模式缓存 | 生效模式 | 状态栏 |
| --- | --- | --- | --- |
| 冷启动（默认跟随系统） | dark | dark | 白 ✓ |
| 切原味主题 light | dark（订阅保持新鲜） | light | 黑 ✓（浅色资源） |
| 切回跟随系统 | dark | dark | 白 ✓（深色资源） |
| 固定 light 期间系统切亮 | light（订阅更新缓存） | light | 黑 ✓（不变） |
| 再切回跟随系统 | light | light | 黑 ✓ |

## 4. 状态栏 / 导航栏适配

- 沉浸式布局（`setWindowLayoutFullScreen(true)`）下系统栏透明，图标颜色必须自行设置。
- `StatusBarManager.updateStatusBarStyle(isDark)` 只设置 `statusBarContentColor`：
  SDK 语义为设置 contentColor 后 `isStatusBarLightIcon` 失效，两套字段同时设置是冗余陷阱。
- 图标色必须与生效主题一致：深色 → `#ffffff`，浅色 → `#000000`；状态栏与三键导航栏同规则。
- 系统栏背景恒为透明（`#00000000`），由页面顶部内容承载观感。

## 5. 官方对齐依据

- 资源限定词（base/dark）+ `$r` 静态引用：官方《应用深浅色适配》推荐做法。
- `onSystemConfigurationUpdated`（API 24+，`applicationContext` 系统级订阅）：
  深浅色变化监听走系统级通道，不受应用 `setColorMode` 影响——比 `onConfigurationUpdate`
  （应用级，主动 setColorMode 后不再回调）更贴合三主题场景。
- `setColorMode` 调用时机（窗口创建 + 页面加载后）：官方 API NOTE，由 loadContent 兜底保证。
- `resourceManager.getConfigurationSync().colorMode`：仅用于冷启动（应用默认跟随系统）
  取系统真实值；固定主题期间它反映的是应用生效模式，不得用于"跟随系统"判定。
- 未开启 `configColorModeChangePerformanceInArkUI` 性能优化 metadata；
  **若将来开启**，须先把 `@StorageProp('effectiveColorMode')` 条件样式（`BBCodeContentView.ets`
  表情背景、`ReplyDialog`/`NewTopicDialog`）改造为状态变量驱动，否则切换不生效。

## 6. 相关文件

| 文件 | 职责 |
| --- | --- |
| `entry/src/main/ets/store/settings/domain/ThemeSettings.ets` | 主题状态、applyCurrentTheme、全局持久化 |
| `entry/src/main/ets/store/SettingsStore.ets` | initTheme / loadUserSettings / reset 编排 |
| `entry/src/main/ets/store/AppStore.ets` | 初始化阶段无条件 initTheme |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 冷启动初始化、onSystemConfigurationUpdated 订阅、loadContent 兜底 |
| `entry/src/main/ets/common/managers/StatusBarManager.ets` | 系统栏样式应用 |
| `entry/src/main/ets/common/constants/Constants.ets` | AppColors / THEME_OPTIONS |
