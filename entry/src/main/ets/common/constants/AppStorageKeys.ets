/**
 * AppStorage key 常量集中注册。
 *
 * 所有跨组件共享的 AppStorage 键名在此统一声明，避免字面量散落导致拼写漂移。
 * 各处 `AppStorage.setOrCreate` / `AppStorage.get<...>` / `@StorageProp` 引用本常量。
 *
 * 注意：key 的字符串值必须与历史字面量完全一致，否则破坏持久化数据兼容性。
 */

/** 状态栏高度（vp），由 EntryAbility 写入 */
export const KEY_STATUS_BAR_HEIGHT: string = 'statusBarHeight'

/** 导航栏高度（vp），由 EntryAbility 写入 */
export const KEY_NAV_BAR_HEIGHT: string = 'navBarHeight'

/** 当前断点：sm/md/lg，由 EntryAbility 写入 */
export const KEY_CURRENT_BREAKPOINT: string = 'currentBreakpoint'

/** 主题名：light/original/... */
export const KEY_THEME_NAME: string = 'themeName'

/** 生效的色彩模式：light/dark */
export const KEY_EFFECTIVE_COLOR_MODE: string = 'effectiveColorMode'

/** 图片加载策略（参见 ImageLoadStrategy） */
export const KEY_IMAGE_LOAD_STRATEGY: string = 'imageLoadStrategy'

/** 是否启用图片尺寸预取 */
export const KEY_ENABLE_IMAGE_SIZE_PREFETCH: string = 'enableImageSizePrefetch'

/** 视频是否默认静音 */
export const KEY_VIDEO_MUTED: string = 'videoMuted'

/** 是否显示签名 */
export const KEY_SHOW_SIGNATURE: string = 'showSignature'

/** 未读通知数 */
export const KEY_UNREAD_NOTI_COUNT: string = 'unreadNotiCount'

/** 未读私信通知数 */
export const KEY_UNREAD_MESSAGE_COUNT: string = 'unreadMessageCount'

/** 通知缓存版本号（变更时 +1 触发页面刷新） */
export const KEY_NOTIFICATION_VERSION: string = 'notificationVersion'

/** 浏览历史版本号（变更时 +1 触发 @Watch） */
export const KEY_BROWSE_HISTORY_VERSION: string = 'browseHistoryVersion'

/** 分类缓存版本号（变更时 +1 触发 @Watch） */
export const KEY_CAT_VERSION: string = 'catVersion'

/** 收藏板块版本号（变更时 +1 触发 @Watch） */
export const KEY_FAV_VERSION: string = 'favVersion'

/** 主题收藏夹列表版本号（变更时 +1 触发 @Watch）。 */
export const KEY_FAVORITE_FOLDER_VERSION: string = 'favoriteFolderVersion'

/** 主题与收藏夹成员关系版本号（变更时 +1 触发 @Watch）。 */
export const KEY_FAVORITE_TOPIC_VERSION: string = 'favoriteTopicVersion'

/** 黑名单版本号（变更时 +1，触发列表与帖子内容实时刷新）。 */
export const KEY_BLACKLIST_VERSION: string = 'blacklistVersion'

/** 个人主页缓存版本号（变更时 +1 触发 @Watch） */
export const KEY_PROFILE_VERSION: string = 'profileVersion'

/** AI 配置版本号（变更时 +1 触发 @Watch） */
export const KEY_AI_CONFIG_VERSION: string = 'aiConfigVersion'

/** 网络变更版本号（wifi/cellular 切换时 +1，触发图片重载） */
export const KEY_NETWORK_CHANGE_VERSION: string = 'networkChangeVersion'

/** 调试开关：true 时帖子详情强制走 HTML 解析模式，跳过 JSON API */
export const KEY_FORCE_HTML_MODE: string = 'nga_forceHtmlMode'

/** 调试模式：true 时在帖子更多菜单中显示"HTML 模式打开"等调试入口 */
export const KEY_DEBUG_MODE: string = 'nga_debugMode'

/** 内置网页浏览：true 时没有可用 App Linking 应用的 URL 在应用内 WebView 打开 */
export const KEY_USE_INTERNAL_WEBVIEW: string = 'useInternalWebView'

/** 帖子内容字体大小（vp），默认为 15 */
export const KEY_CONTENT_FONT_SIZE: string = 'contentFontSize'

/** 帖子列表字体大小（vp），默认为 15 */
export const KEY_TOPIC_FONT_SIZE: string = 'topicFontSize'
