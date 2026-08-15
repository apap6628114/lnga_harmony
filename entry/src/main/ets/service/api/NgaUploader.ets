import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { NGA_UPLOAD_URL } from '../../common/constants/NgaDomains';
import { decodeGb18030 } from '../../common/utils/CodecUtils';
import { Logger, DOMAIN_NETWORK } from '../../common/utils/Logger';
import type { Cookies } from '../NgaClient';

const logger = new Logger(DOMAIN_NETWORK, 'NgaUploader');

/**
 * 上传附件到 img8.nga.cn （Multipart + 二进制）
 * 对应 Java TopicPostModel.buildMultipartBody() + uploadFileInner()
 *
 * @param imageData - 图片二进制数据
 * @param fileName - 文件名
 * @param auth - 上传鉴权码（getPostAuth 返回）
 * @param fid - 版块 ID
 * @param cookies - NGA 会话 Cookie
 * @returns 上传接口原始文本（JS 对象字面量，由调用方解析）
 */
export async function ngaUploadFile(
  imageData: ArrayBuffer,
  fileName: string,
  auth: string,
  fid: number,
  cookies: Cookies
): Promise<string> {
  const url: string = NGA_UPLOAD_URL
  const boundary: string = '----NGAFormBoundary' + Math.random().toString(36).slice(2, 12)
  const encoder: util.TextEncoder = util.TextEncoder.create()

  const textFields: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_url_utf8_name"\r\n\r\n' + fileName + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="fid"\r\n\r\n' + String(fid) + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="auth"\r\n\r\n' + auth + '\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="func"\r\n\r\nupload\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="v2"\r\n\r\n1\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="lite"\r\n\r\njs\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_auto_size"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_watermark"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_dscp"\r\n\r\n\r\n' +
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1_img"\r\n\r\n1\r\n' +
    '--' + boundary + '\r\n' +
    // origin_domain 为服务端约定值（非连接域名），不随站点域切换修改
    'Content-Disposition: form-data; name="origin_domain"\r\n\r\nbbs.ngacn.cc\r\n'

  const fileHeader: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1"; filename="' + fileName + '"\r\n' +
    'Content-Type: image/jpeg\r\n\r\n'
  const fileFooter: string = '\r\n--' + boundary + '--\r\n'

  const textBytes: Uint8Array = encoder.encodeInto(textFields)
  const headerBytes: Uint8Array = encoder.encodeInto(fileHeader)
  const footerBytes: Uint8Array = encoder.encodeInto(fileFooter)
  const imageU8: Uint8Array = new Uint8Array(imageData)

  const totalLength: number = textBytes.byteLength + headerBytes.byteLength + imageU8.byteLength + footerBytes.byteLength
  const fullBody: Uint8Array = new Uint8Array(totalLength)
  let pos: number = 0
  fullBody.set(textBytes, pos)
  pos += textBytes.byteLength
  fullBody.set(headerBytes, pos)
  pos += headerBytes.byteLength
  fullBody.set(imageU8, pos)
  pos += imageU8.byteLength
  fullBody.set(footerBytes, pos)

  const contentType: string = 'multipart/form-data; boundary=' + boundary
  const headers: Record<string, string> = {
    'Content-Type': contentType,
    'User-Agent': 'NGA_WP_JW',
    'X-User-Agent': 'Nga_Official',
  }
  if (cookies) {
    headers['Cookie'] = 'ngaPassportUid=' + cookies.uid + '; ngaPassportCid=' + cookies.cid
  }

  logger.verbose('[NGA][UPLOAD] %{public}s size=%{public}s', url, String(imageData.byteLength))
  return new Promise<string>((resolve, reject) => {
    const httpRequest = http.createHttp()
    httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: fullBody.buffer as ArrayBuffer,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      readTimeout: 120000,
      connectTimeout: 30000,
    }, (err, resp) => {
      httpRequest.destroy()
      if (err) {
        logger.verbose('[NGA][UPLOAD] fail: %{public}s', err.message)
        reject(new Error('上传失败: ' + err.message))
        return
      }
      const respText: string = decodeGb18030(resp.result as ArrayBuffer)
      logger.verbose('[NGA][UPLOAD] resp %{public}s %{public}s', String(resp.responseCode), respText.slice(0, 200))
      if (resp.responseCode !== 200) {
        reject(new Error('上传HTTP ' + String(resp.responseCode)))
        return
      }
      resolve(respText)
    })
  })
}
