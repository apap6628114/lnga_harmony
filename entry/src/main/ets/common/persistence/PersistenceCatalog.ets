/**
 * 持久化数据域注册表（PersistenceCatalog）— 全工程持久化治理口径的唯一真相。
 *
 * 设计见 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §2.3 / §13.1。任何新增持久化数据都必须：
 * 1. 在本文件登记 `DomainSpec`；
 * 2. 在 `DomainMigrators.ets` 声明旧数据迁移规则（若存在旧数据）；
 * 3. 在 `DomainMergers.ets` 声明导入合并策略（若参与导入）。
 *
 * 键命名规范见设计文档 §3.2：`v2.<domainId>`（Preferences）与 `filesDir/v2/<dir>/`（文件域），
 * **禁止**任何键包含 uid / token / 时间戳。
 */

import {
  DomainScope,
  DomainSpec,
  ExportPolicy,
  ImportPolicy,
  PERSISTENCE_META_KEY,
  StorageKind
} from './PersistenceTypes'

/**
 * 域 ID 常量（避免各处硬编码字符串拼写错误）。
 *
 * ⚠️ 必须声明在 `buildSpecs()` / `PersistenceCatalog` 之前：`PersistenceCatalog.SPECS` 是类静态
 * 字段，模块加载时立即执行 `buildSpecs()`；若 `DomainIds` 在其后声明，会命中 TDZ
 * （`ReferenceError: DomainIds is not initialized`，Hypium Local Test 已实际复现并导致测试页崩溃）。
 */
export class DomainIds {
  static readonly AUTH: string = 'auth'
  static readonly SESSIONS: string = 'sessions'
  static readonly SETTINGS: string = 'settings'
  static readonly THEME: string = 'theme'
  static readonly CATEGORIES: string = 'categories'
  static readonly PROFILES: string = 'profiles'
  static readonly NOTIFICATIONS: string = 'notifications'
  static readonly ACTIVITIES: string = 'activities'
  static readonly FAVORITE_MEMBERSHIP: string = 'favorite_membership'
  static readonly HISTORY: string = 'history'
  static readonly READING_PROGRESS: string = 'reading_progress'
  static readonly TREE_READING_PROGRESS: string = 'tree_reading_progress'
  static readonly VOTES: string = 'votes'
  static readonly POLL_VOTED: string = 'poll_voted'
  static readonly TRACKED_THREADS: string = 'tracked_threads'
  static readonly AI_SESSIONS: string = 'ai_sessions'
  static readonly AI_TOOL_CACHE: string = 'ai_tool_cache'
  static readonly DRAFTS: string = 'drafts'
  static readonly DRAFT_MEDIA: string = 'draft_media'
  static readonly SAVED_THREADS: string = 'saved_threads'
  static readonly MOVING_PHOTO_CACHE: string = 'moving_photo_cache'
  static readonly META: string = 'meta'
}

/**
 * 构建内置域清单。
 *
 * 字段顺序与设计文档 §2.3 表格一致（便于对照）。`key` 不含 `v2.` 前缀，由 `DomainSpec.fullKey()` 拼接。
 *
 * @returns 全部域元数据
 */
function buildSpecs(): DomainSpec[] {
  const specs: DomainSpec[] = []
  // ---- 凭证（不导出、不导入、不参与清空）----
  specs.push(new DomainSpec(
    'auth', '登录凭证', StorageKind.PREFERENCES, 'auth', '', 1,
    DomainScope.SECRET, ExportPolicy.NEVER, ImportPolicy.NEVER, false, false, 512,
    '当前登录会话（token/uid/cid）。敏感，永不导出。'
  ))
  specs.push(new DomainSpec(
    'sessions', '多账号会话表', StorageKind.PREFERENCES, 'sessions', '', 1,
    DomainScope.SECRET, ExportPolicy.NEVER, ImportPolicy.NEVER, false, false, 512,
    'token → 账号会话映射，用于登录自愈。敏感，永不导出。'
  ))
  // ---- 设备级：设置与偏好 ----
  specs.push(new DomainSpec(
    'settings', '设置与偏好', StorageKind.PREFERENCES, 'settings', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.SPECIAL, true, false, 8192,
    '字号/布局/黑白名单/屏蔽词/备注/收藏版块/AI 配置与任务等。'
  ))
  specs.push(new DomainSpec(
    'theme', '主题', StorageKind.PREFERENCES, 'theme', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_FIELDS, true, false, 128,
    '亮/暗/跟随系统。全局设置，跨账号。'
  ))
  specs.push(new DomainSpec(
    'categories', '板块分类缓存', StorageKind.PREFERENCES, 'categories', '', 1,
    DomainScope.DEVICE, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 256,
    '服务端板块分类，可重建。'
  ))
  specs.push(new DomainSpec(
    'profiles', '用户资料缓存', StorageKind.PREFERENCES, 'profiles', '', 1,
    DomainScope.DEVICE, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 2048,
    '用户资料 LRU 缓存，可重建。'
  ))
  // ---- 账号镜像（物理单份 + ownerUid 软隔离）----
  specs.push(new DomainSpec(
    'notifications', '通知缓存', StorageKind.PREFERENCES, 'notifications', '', 1,
    DomainScope.ACCOUNT_MIRROR, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 1024,
    '通知列表本地缓存（服务端镜像）。切号后按 ownerUid 判定有效性并重建。'
  ))
  specs.push(new DomainSpec(
    'activities', '关注动态缓存', StorageKind.PREFERENCES, 'activities', '', 1,
    DomainScope.ACCOUNT_MIRROR, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 1024,
    '关注动态列表本地缓存（服务端镜像）。'
  ))
  specs.push(new DomainSpec(
    'favorite_membership', '收藏成员关系缓存', StorageKind.PREFERENCES, 'favorite_membership', '', 1,
    DomainScope.ACCOUNT_MIRROR, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 512,
    '主题在收藏夹中的归属缓存（服务端镜像）。'
  ))
  // ---- 设备级：阅读与社交用户数据 ----
  specs.push(new DomainSpec(
    'history', '浏览历史', StorageKind.PREFERENCES, 'history', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 512,
    '浏览历史兼主题列表已读台账（含已读基线）。上限 500 条。'
  ))
  specs.push(new DomainSpec(
    'reading_progress', '阅读进度', StorageKind.PREFERENCES, 'reading_progress', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 128,
    '每帖读到哪一楼的定位锚点。上限 200 条。'
  ))
  specs.push(new DomainSpec(
    'tree_reading_progress', '递进树阅读进度', StorageKind.PREFERENCES, 'tree_reading_progress', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 128,
    '每帖在递进树视图读到哪一行（锚点楼层 pid / 所属根 / 页码）。上限 200 条。'
  ))
  specs.push(new DomainSpec(
    'votes', '点赞/踩记录', StorageKind.PREFERENCES, 'votes', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 256,
    '本地记录的已赞/已踩 pid 集合。上限 200 帖。'
  ))
  specs.push(new DomainSpec(
    'poll_voted', '投票已投记录', StorageKind.PREFERENCES, 'poll_voted', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 128,
    '已参与投票的 tid 集合。上限 200 帖。'
  ))
  specs.push(new DomainSpec(
    'tracked_threads', '跟踪帖子', StorageKind.PREFERENCES, 'tracked_threads', '', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.MERGE_BY_KEY, true, false, 512,
    '本地跟踪任务与已读基准。'
  ))
  // ---- 设备级：AI ----
  specs.push(new DomainSpec(
    'ai_sessions', 'AI 对话历史', StorageKind.PREFERENCES, 'ai_sessions', '', 1,
    DomainScope.DEVICE, ExportPolicy.OPTIONAL, ImportPolicy.MERGE_BY_KEY, true, false, 4096,
    'AI 会话记忆（含消息、摘要、工具调用记录）。含隐私内容，默认不勾选导出。'
  ))
  specs.push(new DomainSpec(
    'ai_tool_cache', 'AI 工具结果缓存', StorageKind.PREFERENCES, 'ai_tool_cache', '', 1,
    DomainScope.DEVICE, ExportPolicy.OPTIONAL, ImportPolicy.SKIP, true, true, 2048,
    '工具结果 TTL 缓存，可重建。'
  ))
  // ---- 设备级：文件域 ----
  specs.push(new DomainSpec(
    'drafts', '编辑器草稿', StorageKind.JSON_FILES, '', 'drafts/', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.REPLACE_BY_KEY, true, false, 2048,
    '未发送的回复/发帖草稿，保留 7 天。'
  ))
  specs.push(new DomainSpec(
    'draft_media', '草稿媒体副本', StorageKind.JSON_FILES, '', '!draft_media/', 1,
    DomainScope.DEVICE, ExportPolicy.NEVER, ImportPolicy.SKIP, true, false, 262144,
    '草稿中图片的沙箱副本。体积大且路径不可移植，不参与导出/导入（导入草稿后需在编辑器重新选图）。'
  ))
  specs.push(new DomainSpec(
    'saved_threads', '离线保存的帖子', StorageKind.JSON_FILES, '', 'saved_threads/', 1,
    DomainScope.DEVICE, ExportPolicy.INCLUDE, ImportPolicy.REPLACE_BY_KEY, true, false, 131072,
    '整帖离线存档（同形状原始 JSON）。'
  ))
  specs.push(new DomainSpec(
    'moving_photo_cache', '动态照片缓存', StorageKind.JSON_FILES, '', '!mphoto/', 1,
    DomainScope.DEVICE, ExportPolicy.NEVER, ImportPolicy.SKIP, true, true, 1048576,
    '动态照片播放缓存（filesDir/mphoto），可重建，无导出价值。'
  ))
  // ---- 内部元数据 ----
  specs.push(new DomainSpec(
    'meta', '数据版本锚点', StorageKind.PREFERENCES, 'meta', '', 1,
    DomainScope.DEVICE, ExportPolicy.NEVER, ImportPolicy.NEVER, false, false, 1024,
    '迁移状态、全局数据版本与一次性提示标记（含导出/导入历史）。内部专用。'
  ))
  /*
   * 载荷模式分配：
   * - **ENVELOPE（rawPayload=false）**：账号镜像域（notifications/activities/favorite_membership）
   *   与沿用 `CacheEnvelopeStore` 信封信封结构的 tracked_threads/ai_sessions —— 它们需要
   *   `ownerUid`/schemaVersion 元数据，且 Store 侧改造后统一读"信封.payload"；
   * - **RAW（rawPayload=true）**：其余存量域（settings/history/votes/...）：裸 JSON 直接落盘，
   *   Store 只换键即可接入，不必改载荷结构。
   *
   * 迁移器 `DomainMigrators` 对 ENVELOPE 域的产出统一是 `payload` 片段（如 `{items}` /
   * `{favoredFolderIds,knownFolderIds}`），由 `PersistenceHub.writePayload` 套上标准信封。
   */
  const envelopeDomainIds: string[] = [
    DomainIds.NOTIFICATIONS,
    DomainIds.ACTIVITIES,
    DomainIds.FAVORITE_MEMBERSHIP,
    DomainIds.TRACKED_THREADS,
    DomainIds.AI_SESSIONS,
    DomainIds.AI_TOOL_CACHE
  ]
  for (let i: number = 0; i < specs.length; i++) {
    specs[i].rawPayload = envelopeDomainIds.indexOf(specs[i].id) < 0
  }
  return specs
}

/**
 * 持久化域注册表。
 *
 * 全部方法均为静态查询，无状态；实例化没有意义（构造函数私有化不可用，内部约定不 new）。
 */
export class PersistenceCatalog {
  /** 内置域清单（进程内唯一一份）。 */
  private static readonly SPECS: DomainSpec[] = buildSpecs()

  /**
   * 返回全部域（顺序为声明顺序）。
   *
   * @returns 域元数据数组（只读引用，调用方不得修改元素字段）
   */
  static all(): DomainSpec[] {
    return PersistenceCatalog.SPECS
  }

  /**
   * 按域 ID 查询。
   *
   * @param id - 域 ID
   * @returns 域元数据；不存在返回 null
   */
  static byId(id: string): DomainSpec | null {
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      if (PersistenceCatalog.SPECS[i].id === id) {
        return PersistenceCatalog.SPECS[i]
      }
    }
    return null
  }

  /**
   * 返回指定存储介质的域。
   *
   * @param storage - 存储介质
   * @returns 域元数据数组
   */
  static byStorage(storage: StorageKind): DomainSpec[] {
    const result: DomainSpec[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      if (PersistenceCatalog.SPECS[i].storage === storage) {
        result.push(PersistenceCatalog.SPECS[i])
      }
    }
    return result
  }

  /**
   * 返回指定账号语义的域。
   *
   * @param scope - 账号语义
   * @returns 域元数据数组
   */
  static byScope(scope: DomainScope): DomainSpec[] {
    const result: DomainSpec[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      if (PersistenceCatalog.SPECS[i].scope === scope) {
        result.push(PersistenceCatalog.SPECS[i])
      }
    }
    return result
  }

  /**
   * 返回参与导出的域（排除 NEVER）。
   *
   * @returns 域元数据数组
   */
  static exportable(): DomainSpec[] {
    const result: DomainSpec[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      const spec: DomainSpec = PersistenceCatalog.SPECS[i]
      if (spec.exportPolicy !== ExportPolicy.NEVER) {
        result.push(spec)
      }
    }
    return result
  }

  /**
   * 返回可清空的域（「清空本地数据」入口使用）。
   *
   * @returns 域元数据数组
   */
  static clearable(): DomainSpec[] {
    const result: DomainSpec[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      if (PersistenceCatalog.SPECS[i].clearable) {
        result.push(PersistenceCatalog.SPECS[i])
      }
    }
    return result
  }

  /**
   * 返回需要启动加载的设备级域（文件域由各自 Store 初始化，不在此列）。
   *
   * @returns Preferences 设备级域
   */
  static devicePreferenceDomains(): DomainSpec[] {
    const result: DomainSpec[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      const spec: DomainSpec = PersistenceCatalog.SPECS[i]
      if (spec.scope === DomainScope.DEVICE && spec.storage === StorageKind.PREFERENCES) {
        result.push(spec)
      }
    }
    return result
  }

  /**
   * 返回账号镜像域。
   *
   * @returns Preferences 账号镜像域
   */
  static mirrorDomains(): DomainSpec[] {
    return PersistenceCatalog.byScope(DomainScope.ACCOUNT_MIRROR)
  }

  /**
   * 返回凭证域。
   *
   * @returns Preferences 凭证域
   */
  static secretDomains(): DomainSpec[] {
    return PersistenceCatalog.byScope(DomainScope.SECRET)
  }

  /**
   * 返回域 ID 列表（日志与测试用）。
   *
   * @returns 域 ID 数组
   */
  static ids(): string[] {
    const result: string[] = []
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      result.push(PersistenceCatalog.SPECS[i].id)
    }
    return result
  }

  /**
   * 自检：域 ID 唯一、Preferences 键唯一、非空、无 uid 残留。
   *
   * 供单测与启动断言使用。返回问题描述列表（空数组表示通过）。
   *
   * @returns 问题描述
   */
  static validate(): string[] {
    const problems: string[] = []
    const seenIds: Set<string> = new Set<string>()
    const seenKeys: Set<string> = new Set<string>()
    for (let i: number = 0; i < PersistenceCatalog.SPECS.length; i++) {
      const spec: DomainSpec = PersistenceCatalog.SPECS[i]
      if (spec.id.length === 0) {
        problems.push('第 ' + String(i) + ' 项的域 ID 为空')
        continue
      }
      if (seenIds.has(spec.id)) {
        problems.push('重复的域 ID：' + spec.id)
      }
      seenIds.add(spec.id)
      if (spec.id === 'draft_media' || spec.id === 'moving_photo_cache') {
        // 这两个域的目录沿用旧路径（目录名与草稿键绑定），不参与 v2 命名空间唯一性检查
        continue
      }
      if (spec.storage === StorageKind.PREFERENCES) {
        if (spec.key.length === 0) {
          problems.push('域 ' + spec.id + ' 缺少 Preferences 键')
        }
        // 键只允许小写字母与下划线（域 ID 风格；点号由 fullKey 统一加命名空间）
        for (let k: number = 0; k < spec.key.length; k++) {
          const c: string = spec.key.charAt(k)
          const isLower: boolean = c >= 'a' && c <= 'z'
          if (!isLower && c !== '_') {
            problems.push('域 ' + spec.id + ' 的键含非法字符：' + spec.key)
            break
          }
        }
        if (seenKeys.has(spec.key)) {
          problems.push('重复的 Preferences 键：' + spec.key)
        }
        seenKeys.add(spec.key)
        if (spec.fullKey() === PERSISTENCE_META_KEY && spec.id !== 'meta') {
          problems.push('域 ' + spec.id + ' 占用了内部键：' + spec.fullKey())
        }
      } else if (spec.storage === StorageKind.JSON_FILES && spec.dirName.length === 0) {
        problems.push('域 ' + spec.id + ' 缺少文件目录名')
      }
    }
    return problems
  }
}
