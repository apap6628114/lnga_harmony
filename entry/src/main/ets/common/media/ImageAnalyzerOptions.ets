/**
 * 图像分析的共享选项：**只做文字识别**（不请求主体分割 / 对象查找）。
 *
 * 通路只有一条：`Image` **没有**设置分析类型的属性——`analyzerConfig` 只存在于 `Video`
 * （`video.d.ts:965`），`image.d.ts` 全文里 `ImageAIOptions` 只出现在构造重载上
 * （`image.d.ts:559`，@since 12），因此类型只能在构造时经第二个参数下发。
 *
 * 为什么要收窄：不传 `types` 时系统默认**同时开启**主体识别与文字识别
 * （`image_common.d.ts:20-28` 原文：*"If it is not set, subject recognition and text recognition
 * are enabled by default"*）。主体分割（长按抠图）会让"长按图片"在**没有文字的照片**上也弹出
 * 选区与系统菜单，与正文图"长按只为了看 / 复制图里的字"的语义不符，还会并存出第二套选取态。
 * 收窄后：长按文字区才有选区，长按非文字区没有任何分析 UI。
 *
 * 随之而来的"乐观会话"是这个取舍的已知代价：长按无文字的照片不会出现任何选区，但选区取消链路
 * （见 `ImageAnalyzerSession.ets`）仍会把这次长按记成一次会话，于是**紧接着的那一次单击会被吞
 * 一次**（表现为"点了没反应"，再点一次即正常）。系统没有"分析是否真的出了选区"的回执可用。
 */

/**
 * 创建"只做文字识别"的图像分析选项。
 *
 * 每次调用返回**新对象**：同一个 options 实例不交给多个 `Image` 节点，与官方示例（构造处内联
 * 字面量）保持一致的用法；调用点也因此能直接读到"这个节点只做文字识别"。
 *
 * @returns 仅含 `ImageAnalyzerType.TEXT` 的分析选项
 */
export function createTextOnlyAnalyzerOptions(): ImageAIOptions {
  return { types: [ImageAnalyzerType.TEXT] }
}
