/**
 * NGA 帖子附件上传（图片 / 视频）。
 *
 * 官方 APK 使用 post/check 返回的 attach_url 发起 multipart 请求，
 * 上传结果是 UTF-8 编码的 JS 对象字面量。
 *
 * 视频半边用于**动态照片**（NGA `动图`）：正文形态是
 * `[img]封面[/img][b]MPHOTO[/b][flash=video]视频[/flash]`，
 * 服务端把两半都存成普通附件（真实帖附件元数据：封面 `type:'img'`、视频 `type:'app_video'`），
 * 配对关系完全由正文这段标记表达——因此客户端要做的就是把两半传上去并拼出这段串。
 */

import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { NGA_UPLOAD_URL } from '../../common/constants/NgaDomains';
import { decodeUtf8 } from '../../common/utils/CodecUtils';
import { Logger, DOMAIN_NETWORK } from '../../common/utils/Logger';
import type { Cookies } from '../NgaClient';

const logger = new Logger(DOMAIN_NETWORK, 'NgaUploader');

/** 动态照片封面在上传时使用的原始文件名（与官方客户端一致：附件元数据 `url_utf8_org_name`）。 */
export const MOVING_PHOTO_COVER_NAME: string = 'upload.jpg';

/** 动态照片视频在上传时使用的原始文件名（同上）。 */
export const MOVING_PHOTO_VIDEO_NAME: string = 'video.mp4';

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
  for (let i: number = 0; i < keys.length; i++) {
    appendTextPart(parts, boundary, keys[i], fields[keys[i]]);
  }
  return parts.join('');
}

/**
 * 构造动态照片正文标签（协议形态，两处走查依据见 `MOVING_PHOTO_PLAN.md` §9）。
 *
 * 封面不追加 `.medium.jpg`：真实动态照片帖的正文原文是 `[img]./xxx.jpg[/img]`（裸名），
 * 与普通图片插入路径（追加 `.medium.jpg`）不同，这里与官方形态逐字对齐。
 *
 * @param coverUrl - 上传返回的封面地址
 * @param videoUrl - 上传返回的视频地址
 * @returns 可直接插入正文的 BBCode 三元组
 */
export function buildMovingPhotoTag(coverUrl: string, videoUrl: string): string {
  return '[img]./' + coverUrl + '[/img][b]MPHOTO[/b][flash=video]./' + videoUrl + '[/flash]';
}

/**
 * 发起一次附件上传（multipart），返回接口原始 UTF-8 文本。
 *
 * @param data - 附件二进制数据
 * @param fileName - 附件文件名或路径
 * @param auth - post/check 返回的附件鉴权码
 * @param fid - 版块 ID
 * @param attachUrl - post/check 返回的上传地址，空值时使用兼容兜底地址
 * @param cookies - NGA 会话 Cookie
 * @param isImage - 是否为图片附件（决定字段集与分段 Content-Type）
 * @returns 上传接口原始 UTF-8 文本
 */
async function ngaUploadAttachment(
  data: ArrayBuffer,
  fileName: string,
  auth: string,
  fid: number,
  attachUrl: string,
  cookies: Cookies,
  isImage: boolean
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
    'lite': 'js',
    'auth': auth,
    'mvimg': '1',
  };
  if (isImage) {
    fields['attachment_file1_img'] = '1';
  }
  // 视频半边**不带** attachment_file1_img：该字段语义是"这是个图片附件"（服务端据此出图/缩略图），
  // 视频不应该声明。恒传 mvimg='1'（官方是「有原图/动图时为 1」的条件值，普通单图传空），
  // 动态照片正是"有动图"的场景，两半都带它；普通图片沿用恒传值（既有偏差见
  // docs/REVIEW_POST_API_MIGRATION.md G3，线上单图上传实测正常）。
  const partContentType: string = isImage ? 'image/jpeg' : 'video/mp4';
  const textBytes: Uint8Array = encoder.encodeInto(buildMultipartText(boundary, fields));
  const fileHeader: string =
    '--' + boundary + '\r\n' +
    'Content-Disposition: form-data; name="attachment_file1"; filename="' + baseFileName + '"\r\n' +
    'Content-Type: ' + partContentType + '\r\n\r\n';
  const headerBytes: Uint8Array = encoder.encodeInto(fileHeader);
  const footerBytes: Uint8Array = encoder.encodeInto('\r\n--' + boundary + '--\r\n');
  const fileBytes: Uint8Array = new Uint8Array(data);
  const totalLength: number = textBytes.byteLength + headerBytes.byteLength +
    fileBytes.byteLength + footerBytes.byteLength;
  const fullBody: Uint8Array = new Uint8Array(totalLength);
  let offset: number = 0;
  fullBody.set(textBytes, offset);
  offset += textBytes.byteLength;
  fullBody.set(headerBytes, offset);
  offset += headerBytes.byteLength;
  fullBody.set(fileBytes, offset);
  offset += fileBytes.byteLength;
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

  logger.verbose('[NGA][UPLOAD] %{public}s size=%{public}s image=%{public}s',
    url, String(data.byteLength), String(isImage));
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
  return ngaUploadAttachment(imageData, fileName, auth, fid, attachUrl, cookies, true);
}

/**
 * 上传动态照片的视频半边。
 *
 * 与图片上传同走一个附件接口，差别只有两处：不带 `attachment_file1_img`、
 * 分段 Content-Type 为 `video/mp4`（字段选择的依据与待验证项见 `MOVING_PHOTO_PLAN.md` §9）。
 *
 * @param videoData - 视频二进制数据
 * @param fileName - 视频文件名或路径（动态照片用 `video.mp4`）
 * @param auth - post/check 返回的附件鉴权码
 * @param fid - 版块 ID
 * @param attachUrl - post/check 返回的上传地址，空值时使用兼容兜底地址
 * @param cookies - NGA 会话 Cookie
 * @returns 上传接口原始 UTF-8 文本
 */
export async function ngaUploadVideoFile(
  videoData: ArrayBuffer,
  fileName: string,
  auth: string,
  fid: number,
  attachUrl: string,
  cookies: Cookies
): Promise<string> {
  return ngaUploadAttachment(videoData, fileName, auth, fid, attachUrl, cookies, false);
}
