import { hilog } from '@kit.PerformanceAnalysisKit';

// ============== 全局开关 ==============

/**
 * 日志总开关。
 * - true（默认）：正常输出日志
 * - false：静默所有日志输出（Release 包可用）
 */
export const LOG_ENABLED: boolean = true;

/**
 * 调试日志开关。
 * - true：同时输出 verbose 级别的高频调试日志（网络请求、图片预取等）
 * - false（默认）：仅输出 info/warn/error
 *
 * 调试时临时改为 true 即可查看网络请求详情，无需改动其他代码。
 */
export const VERBOSE: boolean = true;

// ============== 模块 DOMAIN 常量 ==============

/** 0x0000 — 应用入口/生命周期：EntryAbility、EntryBackupAbility、AppStore */
export const DOMAIN_APP: number = 0x0000;

/** 0x0001 — 网络层：NgaClient、NetworkMonitor、NetworkUtil */
export const DOMAIN_NETWORK: number = 0x0001;

/** 0x0002 — 状态管理层：AuthStore、CategoryStore、ProfileStore 等 */
export const DOMAIN_STORE: number = 0x0002;

/** 0x0003 — 页面/UI 组件：pages、common/components */
export const DOMAIN_UI: number = 0x0003;

/** 0x0004 — 服务/API 层：service/api */
export const DOMAIN_SERVICE: number = 0x0004;

/** 0x0005 — 解析器：parser（BBCode、HTML、JSON） */
export const DOMAIN_PARSER: number = 0x0005;

/** 0x0006 — 媒体：ImageSizeUtil、AudioPlayer、TtsPlayer、MutedVideo */
export const DOMAIN_MEDIA: number = 0x0006;

/** 0x0007 — 基础设施：PreferencesStore、SerialQueue */
export const DOMAIN_INFRA: number = 0x0007;

/** 0x0008 — 管理器：ReplyManager、StatusBarManager、PaginationManager */
export const DOMAIN_MANAGER: number = 0x0008;

/** 0x0009 — 设置模块：store/settings */
export const DOMAIN_SETTINGS: number = 0x0009;

/**
 * 将 catch 块中的异常对象格式化为可输出的字符串。
 * 统一处理 Error 对象、字符串异常、未知类型异常。
 * 对于 HarmonyOS BusinessError，会同时输出 code 和 message。
 *
 * 用法（catch 后降级返回等可恢复场景用 warn，见 Logger 类注释）：
 * ```
 * catch (e) {
 *   logger.warn('操作失败: %{public}s', formatError(e));
 * }
 * ```
 * @param e - catch 块捕获的异常对象
 * @returns 可输出的错误描述字符串
 */
export function formatError(e: Object): string {
  const err = e as Record<string, Object>;
  const hasMessage: boolean = err && typeof err.message === 'string' && err.message !== '';
  const code: number | undefined = err && typeof err.code === 'number' ? err.code as number : undefined;
  if (hasMessage && code !== undefined) {
    return '[code=' + String(code) + '] ' + (err.message as string);
  }
  // Error 对象：取 message
  if (hasMessage) {
    return err.message as string;
  }
  // 字符串异常：直接返回
  if (typeof e === 'string') {
    return e;
  }
  // 其他：序列化
  return JSON.stringify(e);
}

/**
 * 统一日志工具。
 *
 * 封装 hilog，提供 info / warn / error / verbose 四级输出，
 * 受全局开关 `LOG_ENABLED` 和 `VERBOSE` 控制。
 *
 * 用法：
 * ```
 * const logger = new Logger(DOMAIN_NETWORK, 'NgaClient');
 * logger.info('请求成功: %{public}s', url);
 *
 * // verbose 受 VERBOSE 开关控制，搭配 isVerbose() 保护昂贵参数求值
 * if (logger.isVerbose()) {
 *   logger.verbose('响应体: %{public}s', bodyText);
 * }
 *
 * // 异常格式化（降级返回等可恢复场景用 warn；无降级直接冒泡才用 error）
 * catch (e) {
 *   logger.warn('请求失败: %{public}s', formatError(e));
 * }
 * ```
 */
export class Logger {
  /** 日志域（0x0000~0xFFFF），用于命令行按模块过滤 */
  private domain: number;
  /** 日志标签，通常取类名或文件名 */
  private tag: string;

  /**
   * @param domain - 模块 domain 常量，如 DOMAIN_NETWORK
   * @param tag - 日志标签，如 'NgaClient'
   */
  constructor(domain: number, tag: string) {
    this.domain = domain;
    this.tag = tag;
  }

  /**
   * 查询 verbose 日志是否已启用。
   * 调用方可用此方法保护昂贵参数计算（如 JSON.stringify 大对象），
   * 避免 VERBOSE 关闭时仍付出求值开销：
   * ```
   * if (logger.isVerbose()) {
   *   logger.verbose('body: %{public}s', JSON.stringify(largeObject));
   * }
   * ```
   * @returns true 表示 verbose 日志会实际输出
   */
  isVerbose(): boolean {
    return LOG_ENABLED && VERBOSE;
  }

  /**
   * info 级别日志（始终输出，受 LOG_ENABLED 控制）。
   * 用于生命周期事件、初始化完成、状态变更等低频信息。
   */
  info(format: string, ...args: Object[]): void {
    if (!LOG_ENABLED) {
      return;
    }
    hilog.info(this.domain, this.tag, format, ...args);
  }

  /**
   * warn 级别日志（始终输出，受 LOG_ENABLED 控制）。
   * 用于可恢复的异常、降级路径（含 catch 捕获后降级返回、应用继续运行的场景）。
   */
  warn(format: string, ...args: Object[]): void {
    if (!LOG_ENABLED) {
      return;
    }
    hilog.warn(this.domain, this.tag, format, ...args);
  }

  /**
   * error 级别日志（始终输出，受 LOG_ENABLED 控制）。
   * 用于不可恢复的错误：catch 捕获后直接冒泡给上层、无降级路径的异常。
   * 注意：catch 后若能降级返回（如写入 result.error），属可恢复路径，请用 warn。
   */
  error(format: string, ...args: Object[]): void {
    if (!LOG_ENABLED) {
      return;
    }
    hilog.error(this.domain, this.tag, format, ...args);
  }

  /**
   * verbose 级别日志（受 LOG_ENABLED 和 VERBOSE 双重控制）。
   * 用于高频调试信息：网络请求详情、图片预取、上传流程等。
   * 映射到 `hilog.debug`，默认关闭，调试时设置 `VERBOSE = true` 即可启用。
   *
   * 注意：如果参数需要昂贵计算（如序列化大对象），请先用 `isVerbose()` 守卫：
   * ```
   * if (logger.isVerbose()) {
   *   logger.verbose('body: %{public}s', JSON.stringify(largeObject));
   * }
   * ```
   */
  verbose(format: string, ...args: Object[]): void {
    if (!LOG_ENABLED || !VERBOSE) {
      return;
    }
    hilog.debug(this.domain, this.tag, format, ...args);
  }

}
