/**
 * 基于 token-bucket 的请求限流器。
 *
 * 按 domain（通常为请求域名）分桶，每桶独立维护「最大并发数 + 最小调度间隔 +
 * 滑动窗口总速率」三重约束：
 * - 并发上限：单 domain 同时进行的请求不超过 maxConcurrency；
 * - 最小间隔：同一 domain 内两次 dispatch 之间至少相隔 minInterval 毫秒；
 * - 滑动窗口：同一 domain 在 windowMs 内最多 dispatch maxInWindow 次。
 *
 * 为什么需要第三重：只有「并发 + 最小间隔」时，6 并发 × 150ms 间隔在 60 秒里
 * 理论上能打 400 次请求——这个瞬时能力足以触发 NGA 的账号级风控，而前两重约束
 * 对此完全没有感知。滑动窗口把「均匀但持续」的请求量也压住。
 *
 * 典型用法：发起请求前 `await acquire(domain)` 取得执行许可，请求结束（无论成功/失败）
 * 后调用 `release(domain)` 释放槽位并唤醒等待者。
 *
 * 另有全局**冷却闸门**（{@link enterCooldown}）：一旦网络层识别出风控信号，
 * 所有 domain 的 acquire 都会被拒绝，直到冷却结束。这是「保守兜底」——宁可在
 * 冷却期内快速失败并给出可读原因，也不要在被限流的状态下继续重试、把惩罚窗口拉长。
 */

/** 冷却拒绝的统一标记（放在 Error.message 前缀，跨层传递不依赖类型）。 */
export const THROTTLE_COOLDOWN_MARKER: string = '[NGATHROTTLE]'

/**
 * 判断一个错误消息是否来自冷却闸门。
 *
 * @param message - 错误消息
 * @returns true 表示是冷却拒绝
 */
export function isThrottleCooldownMessage(message: string): boolean {
  return message.indexOf(THROTTLE_COOLDOWN_MARKER) >= 0
}

/** 许可授予回调。 */
type WaiterResolve = () => void

/** 许可拒绝回调（冷却期）。 */
type WaiterReject = (error: Error) => void

/**
 * 排队中的 acquire 请求。
 *
 * 必须同时持有 reject：冷却闸门拉闸时，**已经在队列里等待**的请求也要被拒绝。
 * 只挡新请求是不够的——排队者会在计时器触发时照常被放行，等于闸门对积压流量失效。
 */
class Waiter {
  /** 授予许可 */
  resolve: WaiterResolve
  /** 拒绝许可 */
  reject: WaiterReject

  /**
   * 构造等待项。
   *
   * @param resolve - 授予回调
   * @param reject - 拒绝回调
   */
  constructor(resolve: WaiterResolve, reject: WaiterReject) {
    this.resolve = resolve
    this.reject = reject
  }
}

interface Bucket {
  concurrency: number;
  maxConcurrency: number;
  minInterval: number;
  lastDispatch: number;
  waiters: Waiter[];
  drainTimerId: number;
  /** 滑动窗口内的 dispatch 时间戳（升序，队首最老）。 */
  recent: number[];
}

interface BucketStatus {
  running: number;
  queued: number;
}

const DEFAULT_MAX_CONCURRENT = 6;
const DEFAULT_MIN_INTERVAL = 150;
/** 滑动窗口时长（毫秒）。 */
const DEFAULT_WINDOW_MS = 60000;
/**
 * 单个窗口内允许的 dispatch 次数上限。
 *
 * 取值必须和 Agent 的单次运行预算（`DEFAULT_MAX_TOOL_CALLS_PER_RUN = 30`）对齐着看：
 * 一次工具调用内部可能再发 2~3 个请求（读帖 + pid 二分定位），所以一次完整任务
 * 大致对应 45~90 个请求。窗口若按 40 取，长任务会在「预算还没用完」时先被窗口卡住，
 * 表现为莫名其妙地变慢而不是失败——这种"看起来卡了但没报错"最难排查。
 *
 * 取 60 是折中：单次任务通常不会撞窗口，但连续多次提问的累积量仍被压住。
 * 若线上日志频繁出现窗口等待，说明真实阈值更高，可上调；反之若开始看到
 * `[NGA][THROTTLE]` 冷却，应下调。
 */
const DEFAULT_MAX_IN_WINDOW = 60;

export class Throttler {
  private buckets: Map<string, Bucket> = new Map();
  private maxConcurrency: number;
  private minInterval: number;
  private maxInWindow: number;
  private windowMs: number;
  /** 全局冷却截止时间戳（0 表示不在冷却期）。 */
  private cooldownUntil: number = 0;

  /**
   * 构造限流器，设置各 domain 桶共享的默认并发、间隔与窗口参数。
   *
   * @param maxConcurrent - 单 domain 最大并发请求数
   * @param minInterval - 同一 domain 内两次 dispatch 的最小间隔（毫秒）
   * @param maxInWindow - 单个滑动窗口内允许的 dispatch 次数
   * @param windowMs - 滑动窗口时长（毫秒）
   */
  constructor(maxConcurrent: number = DEFAULT_MAX_CONCURRENT,
    minInterval: number = DEFAULT_MIN_INTERVAL,
    maxInWindow: number = DEFAULT_MAX_IN_WINDOW,
    windowMs: number = DEFAULT_WINDOW_MS) {
    this.maxConcurrency = maxConcurrent;
    this.minInterval = minInterval;
    this.maxInWindow = maxInWindow;
    this.windowMs = windowMs;
  }

  /**
   * 进入全局冷却：期间所有 {@link acquire} 立即被拒绝。
   *
   * 多次调用取「更晚的截止时间」，不会被短冷却覆盖掉长冷却。
   *
   * 拉闸的同时**清空所有桶里已排队的等待者**：只设截止时间是不够的，排队者要等下一次
   * 计时器触发或某个请求 release 才会被唤醒，最长可能要等一整个窗口（≈60 秒），
   * 表现为工具长时间停在 running，与「冷却期立即失败、不要静默排队」的设计相反。
   *
   * @param durationMs - 冷却时长（毫秒）
   */
  enterCooldown(durationMs: number): void {
    if (durationMs <= 0) {
      return;
    }
    const until: number = Date.now() + durationMs;
    if (until > this.cooldownUntil) {
      this.cooldownUntil = until;
    }
    this.buckets.forEach((bucket: Bucket): void => {
      this.drainForCooldown(bucket);
    });
  }

  /**
   * 判断当前是否在冷却期。
   *
   * @returns true 表示处于冷却期
   */
  isCoolingDown(): boolean {
    return Date.now() < this.cooldownUntil;
  }

  /**
   * 剩余冷却时长。
   *
   * @returns 毫秒数；不在冷却期时为 0
   */
  cooldownRemainingMs(): number {
    const remaining: number = this.cooldownUntil - Date.now();
    return remaining > 0 ? remaining : 0;
  }

  private getBucket(domain: string): Bucket {
    let b = this.buckets.get(domain);
    if (!b) {
      const newBucket: Bucket = {
        concurrency: 0,
        maxConcurrency: this.maxConcurrency,
        minInterval: this.minInterval,
        lastDispatch: 0,
        waiters: [],
        drainTimerId: -1,
        recent: [],
      };
      this.buckets.set(domain, newBucket);
      b = newBucket;
    }
    return b;
  }

  /**
   * 丢弃已经滑出窗口的时间戳。
   *
   * @param bucket - 目标桶
   * @param now - 当前时间戳
   */
  private pruneWindow(bucket: Bucket, now: number): void {
    const cutoff: number = now - this.windowMs;
    while (bucket.recent.length > 0 && bucket.recent[0] <= cutoff) {
      bucket.recent.shift();
    }
  }

  /**
   * 计算滑动窗口还差多久才腾出一个名额。
   *
   * @param bucket - 目标桶（调用前须已 prune）
   * @param now - 当前时间戳
   * @returns 需要等待的毫秒数；0 表示名额充足
   */
  private windowWaitMs(bucket: Bucket, now: number): number {
    if (bucket.recent.length < this.maxInWindow) {
      return 0;
    }
    // 等到「刚好让第 (length - maxInWindow) 条滑出窗口」才腾出名额
    const boundary: number = bucket.recent[bucket.recent.length - this.maxInWindow];
    const wait: number = boundary + this.windowMs - now;
    return wait > 0 ? wait : 0;
  }

  /**
   * 计算距离下一次可 dispatch 还需等待多久（取间隔与窗口两者的较大值）。
   *
   * @param bucket - 目标桶
   * @param now - 当前时间戳
   * @returns 等待毫秒数；0 表示可立即 dispatch
   */
  private dispatchWaitMs(bucket: Bucket, now: number): number {
    this.pruneWindow(bucket, now);
    const intervalWait: number = bucket.minInterval - (now - bucket.lastDispatch);
    const windowWait: number = this.windowWaitMs(bucket, now);
    const wait: number = Math.max(intervalWait, windowWait);
    return wait > 0 ? wait : 0;
  }

  /**
   * 拒绝并清空该桶里排队的全部请求（冷却闸门拉闸时调用）。
   *
   * @param bucket - 目标桶
   */
  private drainForCooldown(bucket: Bucket): void {
    if (bucket.drainTimerId !== -1) {
      clearTimeout(bucket.drainTimerId);
      bucket.drainTimerId = -1;
    }
    const message: string = THROTTLE_COOLDOWN_MARKER + '请求过于频繁，请 ' +
      Math.ceil(this.cooldownRemainingMs() / 1000).toString() + ' 秒后重试';
    while (bucket.waiters.length > 0) {
      const waiter: Waiter | undefined = bucket.waiters.shift();
      if (waiter !== undefined) {
        waiter.reject(new Error(message));
      }
    }
  }

  private tryDispatch(bucket: Bucket): void {
    // 冷却期一律不发车：先把积压队列清掉，否则闸门只能挡住"冷启动之后"的新请求，
    // 对拉闸前已经排队的流量完全失效（它们会在计时器触发时被照常放行）
    if (this.isCoolingDown()) {
      this.drainForCooldown(bucket);
      return;
    }

    if (bucket.drainTimerId !== -1) {
      clearTimeout(bucket.drainTimerId);
      bucket.drainTimerId = -1;
    }

    while (bucket.waiters.length > 0 && bucket.concurrency < bucket.maxConcurrency) {
      const now = Date.now();
      const wait: number = this.dispatchWaitMs(bucket, now);
      if (wait > 0) {
        bucket.drainTimerId = setTimeout(() => {
          bucket.drainTimerId = -1;
          this.tryDispatch(bucket);
        }, wait);
        return;
      }
      const waiter: Waiter | undefined = bucket.waiters.shift();
      if (waiter === undefined) {
        return;
      }
      bucket.concurrency += 1;
      bucket.lastDispatch = now;
      bucket.recent.push(now);
      waiter.resolve();
    }
  }

  /**
   * 申请 domain 的执行许可：并发未满、间隔满足且窗口内还有名额时立即 resolve；
   * 否则进入等待队列，待条件满足时被唤醒。调用方取得许可后执行请求，
   * 完成后必须调用 {@link release} 释放槽位。
   *
   * 处于全局冷却期时**立即 reject**，错误 message 带 {@link THROTTLE_COOLDOWN_MARKER}，
   * 由网络层翻译成可读的「请求过于频繁」响应，而不是让请求静默排队几十秒。
   *
   * @param domain - 限流维度（通常为请求域名）
   * @returns 许可授予后 resolve 的 Promise
   */
  acquire(domain: string): Promise<void> {
    const remaining: number = this.cooldownRemainingMs();
    if (remaining > 0) {
      return Promise.reject(new Error(THROTTLE_COOLDOWN_MARKER +
        '请求过于频繁，请 ' + Math.ceil(remaining / 1000).toString() + ' 秒后重试'));
    }

    const bucket = this.getBucket(domain);

    if (bucket.concurrency < bucket.maxConcurrency) {
      const now = Date.now();
      if (this.dispatchWaitMs(bucket, now) === 0) {
        bucket.concurrency += 1;
        bucket.lastDispatch = now;
        bucket.recent.push(now);
        return Promise.resolve();
      }
    }

    return new Promise<void>((resolve, reject) => {
      bucket.waiters.push(new Waiter(resolve, reject));
      this.tryDispatch(bucket);
    });
  }

  /**
   * 释放 domain 的一个并发槽位，并唤醒等待队列中的下一个请求。
   *
   * 必须与 {@link acquire} 配对调用：每次 acquire 返回的请求执行完毕后
   * （无论成功/失败）都应调用一次，否则槽位泄漏导致后续请求永久阻塞。
   *
   * @param domain - 限流维度（通常为请求域名）
   */
  release(domain: string): void {
    const bucket = this.getBucket(domain);
    if (bucket.concurrency <= 0) {
      return;
    }
    bucket.concurrency -= 1;
    if (bucket.waiters.length > 0) {
      this.tryDispatch(bucket);
    }
  }

  /**
   * 查询指定 domain 的桶状态（活跃运行数与排队等待数）。
   *
   * @param domain - 限流维度（通常为请求域名）
   * @returns 桶状态；该 domain 从未被使用时返回全 0
   */
  getStatus(domain: string): BucketStatus {
    const bucket = this.buckets.get(domain);
    if (!bucket) {
      const empty: BucketStatus = { running: 0, queued: 0 };
      return empty;
    }
    const status: BucketStatus = { running: bucket.concurrency, queued: bucket.waiters.length };
    return status;
  }
}

export const ngaThrottler = new Throttler();
