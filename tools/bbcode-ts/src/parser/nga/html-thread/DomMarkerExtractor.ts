/**
 * DOM 标记内容提取 — 从 NGA 帖子页 HTML 的 DOM 标记（id=...、<h1>/<h2>/<h3> 等）中提取字段。
 *
 * 各 extract 函数保守保留独立实现（未强行参数化），原因：
 * - marker 构造存在差异：部分 marker 自带闭合 `>`（如 postsubject），部分需后续 indexOf('>')
 * - 结果后处理存在差异：postcontent/postsubject 调 unescapeHtml，postdate/forumName/threadsubject 调 trim
 * 各函数保持独立实现。
 */

import { unescapeHtml } from '../../_shared/HtmlEntityCodec';

/**
 * 提取指定楼层的帖子正文（已反转 HTML 实体）。
 *
 * @param html 源 HTML
 * @param lou 楼层号
 * @returns 帖子正文；未找到时返回空串
 */
function extractPostContent(html: string, lou: number): string {
  const marker: string = `id='postcontent${lou}'`;
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = html.indexOf('</span>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return unescapeHtml(html.substring(contentStart, endIdx));
}

/**
 * 提取指定楼层的帖子标题（已反转 HTML 实体）。
 *
 * @param html 源 HTML
 * @param lou 楼层号
 * @returns 帖子标题；未找到时返回空串
 */
function extractPostSubject(html: string, lou: number): string {
  const marker: string = `<h3 id='postsubject${lou}'>`;
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const contentStart: number = startIdx + marker.length;
  const endIdx: number = html.indexOf('</h3>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return unescapeHtml(html.substring(contentStart, endIdx));
}

/**
 * 提取指定楼层的发帖时间字符串（已 trim）。
 *
 * @param html 源 HTML
 * @param lou 楼层号
 * @returns 发帖时间；未找到时返回空串
 */
function extractPostDate(html: string, lou: number): string {
  const marker: string = `<span id='postdate${lou}'`;
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = html.indexOf('</span>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return html.substring(contentStart, endIdx).trim();
}

/**
 * 提取版块名称（已 trim）。
 *
 * @param html 源 HTML
 * @returns 版块名称；未找到时返回空串
 */
function extractForumName(html: string): string {
  const marker: string = "<h2 id='currentForumName'";
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = html.indexOf('</h2>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return html.substring(contentStart, endIdx).trim();
}

/**
 * 提取主题标题（已 trim）。
 *
 * @param html 源 HTML
 * @returns 主题标题；未找到时返回空串
 */
function extractThreadSubject(html: string): string {
  const marker: string = "<h1 id='currentTopicName'";
  const startIdx: number = html.indexOf(marker);
  if (startIdx < 0) {
    return '';
  }
  const tagEnd: number = html.indexOf('>', startIdx);
  if (tagEnd < 0) {
    return '';
  }
  const contentStart: number = tagEnd + 1;
  const endIdx: number = html.indexOf('</h1>', contentStart);
  if (endIdx < 0) {
    return '';
  }
  return html.substring(contentStart, endIdx).trim();
}

/**
 * 从用户信息表中按 uid 查询用户名。
 *
 * @param userInfo 用户信息表（uid → 用户对象）
 * @param authorid 作者 uid
 * @returns 用户名；未找到时返回空串
 */
function extractPostAuthorName(userInfo: Record<string, Object>, authorid: number): string {
  const uidKey: string = String(authorid);
  const user: Record<string, Object> | undefined = userInfo[uidKey] as Record<string, Object> | undefined;
  if (user && user['username']) {
    return String(user['username']);
  }
  return '';
}

export {
  extractPostContent, extractPostSubject, extractPostDate,
  extractForumName, extractThreadSubject, extractPostAuthorName,
};
