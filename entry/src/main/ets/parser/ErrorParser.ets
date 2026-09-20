/**
 * 错误文案解析。
 *
 * ⚠️ 这里有**两套互不相干**的错误码，历史上曾被混用（`parseNgaError` 的通用表一度被
 * 整个替换成上传表，导致 HTML 错误页的 `error_code: 15` 从「频率限制」退化成「错误码: 15」）：
 *
 * - **通用业务错误码**：来自 HTML 错误页（`NgaClient.ngaRequest` 解析
 *   `<!--msgcodestart-->N<!--msgcodeend-->`，归一化为 `{error:{0:...}, error_code}`）
 *   与通用接口的 `code`。`15` = 频率限制、`11` = 未登录。见 {@link parseNgaError}。
 * - **上传错误码**：只出现在附件上传接口（`attach.php`）响应的 `error_code` 字段。
 *   `13` = 发帖数超过 5 方可上传附件。见 {@link formatUploadErrorCode}。
 *
 * 两套编号在 10 以后完全不同（通用 15 = 频率限制，上传 12 = 操作超时），**不要合并**。
 */

/**
 * 从官方响应中提取业务错误信息（**通用**错误码）。
 *
 * @param data - 官方接口原始对象
 * @returns 错误消息；无错误时返回 null
 */
export function parseNgaError(data: object | null): string | null {
  if (!data) return null;
  const d = data as Record<string, Object>;
  if (d['error']) {
    if (typeof d['error'] !== 'string') {
      const errorObj = d['error'] as Record<string, Object>;
      const rawCode = errorObj['2'];
      if (rawCode === 0 || rawCode === '0') {
        return null;
      }
      return String(errorObj['0'] ?? '未知错误');
    }
    return String(d['error']);
  }
  if (d['error_code']) {
    const code = Number(d['error_code']);
    // 服务端**通用**业务错误码（不是上传错误码，见文件头说明）
    const codes: Record<number, string> = {
      9: '附件过大',
      10: '权限不足',
      11: '未登录',
      12: '内容为空',
      13: '验证码错误',
      14: '用户名或密码错误',
      15: '频率限制',
    };
    return codes[code] ?? `错误码: ${code}`;
  }
  return null;
}

/**
 * 翻译官方**上传**错误码（附件上传接口响应的 `error_code`）。
 *
 * 表取自官方 `ct/k.java` 的 `c(String)` 分支
 * （`nga-hack/jadx-out/classes2/sources/ct/k.java:149-178`；其 switch 是 0 基下标，
 * 服务端下发的是 1 基，故此处按 1–13 书写）。这张表里**没有任何频次/频率类错误**，
 * 「上传有频次限制」是错误说法；每帖附件上限另有 10 的限制（官方 `PostHelper.T0`）。
 *
 * 区分错误码对用户有意义：13「发帖数超过 5 方可上传附件」是重试无法解决的条件，
 * 只显示"上传被拒绝（错误码 13）"会让他一直重试。
 *
 * @param code - 上传响应的 `error_code`
 * @returns 用户可读文案；未知码返回带码的兜底文案
 */
export function formatUploadErrorCode(code: number): string {
  const codes: Record<number, string> = {
    1: '附件上传已关闭',
    2: '该版面不允许上传附件',
    3: '账号验证超时，请刷新后重试',
    4: '文件上传错误，请重试或回报管理员',
    5: '没有可上传的文件',
    6: '文件类型错误',
    7: '附件名过长',
    8: '附件说明过长',
    9: '附件过大',
    10: '无法创建临时文件，请重试或回报管理员',
    11: '生成缩略图错误，请重试或回报管理员',
    12: '操作超时',
    13: '发帖数超过 5 方可上传附件',
  };
  return codes[code] ?? `上传被拒绝（错误码 ${code}）`;
}
