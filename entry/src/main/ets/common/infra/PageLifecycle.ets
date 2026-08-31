/**
 * 页面加载完成标志（模块级单例）。
 *
 * 官方 NOTE：ApplicationContext.setColorMode 须在窗口创建且页面
 * （loadContent）加载完成后调用。EntryAbility.loadContent 回调中标记本标志；
 * ThemeSettings.applyCurrentTheme 据此决定是否执行 setColorMode——
 * 页面未就绪时跳过，由 loadContent 兜底重放（此时页面必然已就绪）。
 */
let pageLoaded: boolean = false

/** 标记页面加载完成（仅 EntryAbility.loadContent 回调调用）。 */
export function markPageLoaded(): void {
  pageLoaded = true
}

/** 页面是否已加载完成（setColorMode 调用时机自检）。 */
export function isPageLoaded(): boolean {
  return pageLoaded
}
