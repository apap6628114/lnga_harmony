/**
 * 存档页数字段的规整工具（无 UI / 无网络 / 无全局状态，可直接单测）。
 *
 * 存档文件是外部可控输入（导入 / 旧版本 / 手工编辑）：`startPage` 与页数可能缺失、
 * 为负数、小数、`Infinity`（`1e999` 这类 JSON 数字）甚至字符串。这些值会直接参与
 * 页码区间文案与 `startPage + 存档页序 - 1` 的算术（字符串会退化成拼接），
 * 必须在进入业务逻辑前统一转成有限整数。
 *
 * 放在独立工具文件而不是树策略里：`SavedThreadStore`（存档存取）也需要规整
 * `startPage`，不该为一个数字工具依赖「树」模块。
 */

/**
 * 把任意来源的页数字段规整为非负整数。
 *
 * @param value - 原始字段值
 * @returns 非负整数；无法解析或非有限值时返回 0
 */
export function normalizePageCount(value: number): number {
  const parsed: number = Math.floor(Number(value))
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

/**
 * 把存档的 `startPage` 规整为合法页码。
 *
 * @param startPage - 原始字段值（运行时可能是任意类型）
 * @returns 合法起始页（1 起）；无法解析时返回 1
 */
export function resolveArchiveStartPage(startPage: number): number {
  const parsed: number = Math.floor(Number(startPage))
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 1
}
