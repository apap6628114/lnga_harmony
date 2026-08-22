/**
 * NGA 帖子图片附件上传。
 *
 * 官方 APK 使用 post/check 返回的 attach_url 发起 multipart 请求，
 * 上传结果是 UTF-8 编码的 JS 对象字面量。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { NGA_UPLOAD_URL } from '../../common/constants/NgaDomains';
import { decodeUtf8 } from '../../common/utils/CodecUtils';
import { Logger, DOMAIN_NETWORK } from '../../common/utils/Logger';
import type { Cookies } from '../NgaClient';

const logger = new Logger(DOMAIN_NETWORK, 'NgaUploader');

/**
 * 从路径中提取文件名。
 * @param fileName - 文件名或路径
 * @returns 不含路径的文件名
 */
function getBaseFileName(fileName: string): string {
  const slashIndex: number = fileName.lastIndexOf('/');
  const backslashIndex: number = fileName.lastIndexOf('\\');
  const separatorIndex: number = slashIndex > backslashIndex ? slashIndex : backslashIndex;
  return separatorIndex >= 0 ? fileName.substring(separatorIndex + 1) : fileName;
}

/**
 * 向 multipart 文本分段列表追加字段。
 * @param parts - 分段列表
 * @param boundary - multipart 分隔符
 * @param name - 字段名
 * @param value - 字段值
 */
function appendTextPart(parts: string[], boundary: string, name: string, value: string): void {
  parts.push(
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="' + name + '"\r\n\r\n' +
    value + '\r\n'
  );
}

/**
 * 构造 multipart 文本字段部分。
 * @param boundary - multipart 分隔符
 * @param fields - 文本字段
 * @returns multipart 文本
 */
function buildMultipartText(boundary: string, fields: Record<string, string>): string {
  const parts: string[] = [];
  const keys: string[] = Object.keys(fields);
  for (let i = 0; i < keys.length; i++) {
    appendTextPart(parts, boundary, keys[i], fields[keys[i]]);
  }
  return parts.join('');
}

/**
 * 上传一张帖子图片。
 *
 * @param imageData - 图片二进制数据
 * @param fileName - 图片文件名或路径
 * @param auth - post/check 返回的附件鉴权码
 * @param fid - 版块 ID
 * @param attachUrl - post/check 返回的上传地址，空值时使用兼容兜底地址
 * @param cookies - NGA 会话 Cookie
 * @returns 上传接口原始 UTF-8 文本
 */
export async function ngaUploadFile(
  imageData: ArrayBuffer,
  fileName: string,
  auth: string,
  fid: number,
  attachUrl: string,
  cookies: Cookies
): Promise<string> {
  const url: string = attachUrl.length > 0 ? attachUrl : NGA_UPLOAD_URL;
  const boundary: string = '-----------------------------7db1c5232222b';
  const encoder: util.TextEncoder = util.TextEncoder.create();
  const baseFileName: string = getBaseFileName(fileName);
  // 官方 attachment_file1_url_utf8_name 用 URLEncoder.encode(name, "utf-8")：
  // 空格编码为 '+'（鸿蒙 encodeURIComponent 为 %20），服务端按该值还原文件名，需对齐
  const encodedFileName: string = encodeURIComponent(baseFileName).replace(/%20/g, '+');
  const fields: Record<string, string> = {
    'v2': '1',
    'attachment_file1_watermark': '',
    'attachment_file1_dscp': '',
    'attachment_file1_url_utf8_name': encodedFileName,
    'fid': String(fid),
    'func': 'upload',
    'attachment_file1_img': '1',
    'lite': 'js',
    'auth': auth,
    'mvimg': '1',
  };
  const textBytes: Uint8Array = encoder.encodeInto(buildMultipartText(boundary, fields));
  const fileHeader: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1"; filename="' + baseFileName + '"\r\n' +
    'Content-Type: image/jpeg\r\n\r\n';
  const headerBytes: Uint8Array = encoder.encodeInto(fileHeader);
  const footerBytes: Uint8Array = encoder.encodeInto('\r\n--' + boundary + '--\r\n');
  const imageBytes: Uint8Array = new Uint8Array(imageData);
  const totalLength: number = textBytes.byteLength + headerBytes.byteLength +
    imageBytes.byteLength + footerBytes.byteLength;
  const fullBody: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  fullBody.set(textBytes, offset);
  offset += textBytes.byteLength;
  fullBody.set(headerBytes, offset);
  offset += headerBytes.byteLength;
  fullBody.set(imageBytes, offset);
  offset += imageBytes.byteLength;
  fullBody.set(footerBytes, offset);

  const headers: Record<string, string> = {
    'Content-Type': 'multipart/form-data; boundary=' + boundary,
    'Accept-Charset': 'utf-8',
    'User-Agent': 'Mozilla/5.0 (Linux; Android 10; NOH-AN00 Build/HUAWEINOH-AN00; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/83.0.4103.106 Mobile Safari/537.36 Nga_Official/7.17.17',
    'X-USER-AGENT': 'Nga_Official/7.17.17(HUAWEI NOH-AN00;Android 10)',
    'X-NGA-CHANNEL': 'official',
    'X-NGA-VERSION-NAME': '7.17.17',
    'X-NGA-VERSION-CODE': '71717',
  };
  if (cookies) {
    headers['Cookie'] = 'ngaPassportUid=' + cookies.uid + '; ngaPassportCid=' + cookies.cid;
  }

  logger.verbose('[NGA][UPLOAD] %{public}s size=%{public}s', url, String(imageData.byteLength));
  return new Promise<string>((resolve, reject) => {
    const httpRequest = http.createHttp();
    httpRequest.request(url, {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: fullBody.buffer as ArrayBuffer,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      readTimeout: 120000,
      connectTimeout: 30000,
    }, (error, response) => {
      httpRequest.destroy();
      if (error) {
        logger.verbose('[NGA][UPLOAD] fail: %{public}s', error.message);
        reject(new Error('上传失败: ' + error.message));
        return;
      }
      const responseText: string = decodeUtf8(response.result as ArrayBuffer);
      logger.verbose('[NGA][UPLOAD] resp %{public}s %{public}s',
        String(response.responseCode), responseText.slice(0, 200));
      if (response.responseCode !== 200) {
        reject(new Error('上传HTTP ' + String(response.responseCode)));
        return;
      }
      resolve(responseText);
    });
  });
}
