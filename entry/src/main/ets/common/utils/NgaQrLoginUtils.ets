import { NGA_HOSTS } from '../constants/NgaDomains'

/**
 * 判断主机名是否为 NGA 的受信任站点。
 *
 * @param hostname - 不含协议、端口和路径的主机名
 * @returns 是否属于已配置的 NGA 主机
 */
function isTrustedNgaHost(hostname: string): boolean {
  const lowerHostname: string = hostname.toLowerCase()
  for (let i: number = 0; i < NGA_HOSTS.length; i++) {
    if (lowerHostname === NGA_HOSTS[i]) {
      return true
    }
  }
  return false
}

/**
 * 安全解码二维码 URL 的查询参数。
 *
 * @param value - 未解码的查询参数值
 * @returns 解码后的值；编码不合法时返回空字符串
 */
function decodeQueryValue(value: string): string {
  try {
    return decodeURIComponent(value)
  } catch (e) {
    return ''
  }
}

/**
 * 校验 NGA 扫码登录二维码的查询参数。
 *
 * @param query - 不含问号和片段的查询字符串
 * @returns 是否只包含一次必需的登录参数
 */
function isValidQrLoginQuery(query: string): boolean {
  const parts: string[] = query.split('&')
  let lib: string = ''
  let action: string = ''
  let qrkey: string = ''
  let hasLib: boolean = false
  let hasAction: boolean = false
  let hasQrkey: boolean = false
  for (let i: number = 0; i < parts.length; i++) {
    const equalIndex: number = parts[i].indexOf('=')
    if (equalIndex <= 0) {
      return false
    }
    const currentKey: string = decodeQueryValue(parts[i].substring(0, equalIndex))
    const currentValue: string = decodeQueryValue(parts[i].substring(equalIndex + 1))
    if (currentValue.length === 0) {
      return false
    }
    if (currentKey === '__lib') {
      if (hasLib) {
        return false
      }
      hasLib = true
      lib = currentValue
    } else if (currentKey === '__act') {
      if (hasAction) {
        return false
      }
      hasAction = true
      action = currentValue
    } else if (currentKey === 'qrkey') {
      if (hasQrkey) {
        return false
      }
      hasQrkey = true
      qrkey = currentValue
    } else {
      return false
    }
  }
  return hasLib && hasAction && hasQrkey && lib === 'login' &&
    action === 'qrlogin_ui' && qrkey.length > 0
}

/**
 * 校验扫码结果是否为 NGA 官方扫码登录二维码。
 *
 * 只接受 HTTPS、已配置的 NGA 主机、固定的 nuke.php 路径以及
 * `__lib=login&__act=qrlogin_ui&qrkey=...` 参数组合，避免把任意二维码
 * 直接交给带有登录 Cookie 的 WebView。
 *
 * @param rawUrl - 扫码得到的原始文本
 * @returns 是否为可交给 NGA 授权 WebView 的 URL
 */
export function isNgaQrLoginUrl(rawUrl: string): boolean {
  const value: string = rawUrl.trim()
  const scheme: string = 'https://'
  if (!value.toLowerCase().startsWith(scheme)) {
    return false
  }

  const authorityStart: number = scheme.length
  const authorityEnd: number = value.indexOf('/', authorityStart)
  const queryStart: number = value.indexOf('?', authorityStart)
  const fragmentStart: number = value.indexOf('#', authorityStart)
  const firstDelimiter: number[] = [authorityEnd, queryStart, fragmentStart]
  let endOfAuthority: number = value.length
  for (let i: number = 0; i < firstDelimiter.length; i++) {
    if (firstDelimiter[i] >= 0 && firstDelimiter[i] < endOfAuthority) {
      endOfAuthority = firstDelimiter[i]
    }
  }

  const authority: string = value.substring(authorityStart, endOfAuthority)
  if (authority.length === 0 || authority.indexOf(':') >= 0 || authority.indexOf('@') >= 0) {
    return false
  }
  if (!isTrustedNgaHost(authority)) {
    return false
  }

  const pathStart: number = value.indexOf('/', authorityStart)
  const actualPathStart: number = pathStart >= 0 ? pathStart : value.length
  let pathEnd: number = value.length
  const pathQueryStart: number = value.indexOf('?', actualPathStart)
  const pathFragmentStart: number = value.indexOf('#', actualPathStart)
  if (pathQueryStart >= 0 && pathQueryStart < pathEnd) {
    pathEnd = pathQueryStart
  }
  if (pathFragmentStart >= 0 && pathFragmentStart < pathEnd) {
    pathEnd = pathFragmentStart
  }
  if (value.substring(actualPathStart, pathEnd) !== '/nuke.php') {
    return false
  }

  if (pathQueryStart < 0) {
    return false
  }
  const queryEnd: number = pathFragmentStart >= 0 ? pathFragmentStart : value.length
  const query: string = value.substring(pathQueryStart + 1, queryEnd)
  return isValidQrLoginQuery(query)
}
