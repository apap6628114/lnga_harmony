/**
 * NGA 用户 APP 接口响应解析。
 *
 * ucp/get 的官方客户端链路通常返回 result 用户对象，但不同输出模式以及
 * 服务端包装可能使用 data 或 data["0"]。这里统一处理这些兼容形态，业务层
 * 只需要面对一个用户对象。
 */

/**
 * 从 ucp/get 的 APP 响应中提取用户对象。
 *
 * @param raw - NGA APP 接口响应
 * @returns 用户对象；响应没有用户数据时返回 null
 */
export function extractAppUser(raw: object): Record<string, Object> | null {
  const root: Record<string, Object> = raw as Record<string, Object>;
  const candidate: Object | undefined = root['result'] ?? root['data'];
  return findUserRecord(candidate);
}

/**
 * 提取 APP 接口业务错误文本。
 *
 * @param raw - NGA APP 接口响应
 * @param fallback - 响应没有可读错误时的默认文本
 * @returns 面向用户的错误文本
 */
export function extractAppUserError(raw: object, fallback: string): string {
  const root: Record<string, Object> = raw as Record<string, Object>;
  const code: Object | undefined = root['code'];
  if (code !== undefined && Number(code) !== 0) {
    const message: string = readMessage(root['msg']);
    return message.length > 0 ? message : `${fallback}（错误码：${String(code)}）`;
  }

  const message: string = readMessage(root['msg']);
  if (message.length > 0) {
    return message;
  }

  const error: Object | undefined = root['error'];
  const errorMessage: string = readMessage(error);
  return errorMessage.length > 0 ? errorMessage : fallback;
}

/**
 * 在响应包装层中递归查找带 uid 的用户对象。
 *
 * @param value - 可能的用户对象、数组或包装对象
 * @returns 用户对象；未找到时返回 null
 */
function findUserRecord(value: Object | undefined): Record<string, Object> | null {
  if (value === undefined || value === null || typeof value !== 'object') {
    return null;
  }

  if (Array.isArray(value)) {
    const values: Object[] = value as Object[];
    for (let i = 0; i < values.length; i++) {
      const item: Object = values[i];
      const record: Record<string, Object> | null = findUserRecord(item);
      if (record !== null) {
        return record;
      }
    }
    return null;
  }

  const record: Record<string, Object> = value as Record<string, Object>;
  const uid: string = String(record['uid'] ?? '');
  if (uid.length > 0) {
    return record;
  }

  const first: Object | undefined = record['0'];
  if (first !== undefined) {
    const firstRecord: Record<string, Object> | null = findUserRecord(first);
    if (firstRecord !== null) {
      return firstRecord;
    }
  }

  const data: Object | undefined = record['data'];
  if (data !== undefined) {
    return findUserRecord(data);
  }
  return null;
}

/**
 * 读取字符串形式的接口错误字段。
 *
 * @param value - 字符串或 NGA 错误对象
 * @returns 错误文本；无法读取时返回空字符串
 */
function readMessage(value: Object | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'object') {
    const record: Record<string, Object> = value as Record<string, Object>;
    const first: Object | undefined = record['0'];
    if (typeof first === 'string') {
      return first;
    }
  }
  return '';
}
