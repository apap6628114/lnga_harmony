# 主题列表帖子预览图设计（Topic Preview Design）

本文档记录 nga_oh 中「版面主题列表卡片显示首帖预览图」的完整设计契约：数据来源与实测证据、
解析层改动、UI 形态、**与「图片加载模式」的约束关系**、设置项接入、ArkTS/响应式要求、
门禁与验证清单。风格与 `docs/TITLE_LIST_DESIGN.md` 一致，落地时以本文为契约。

- 目标视觉范本：`entry/src/main/ets/pages/TopicListPanel.ets` 的 `TopicCardComponent`
- 硬约束一：**不请求帖子详情**（不调 `read.php`、不调 `ThreadApi`）
- 硬约束二：**受「图片加载模式」约束**（`ImageLoadStrategy`，见第 7 章）
- 硬约束三：**由设置项开关控制**（`entry/src/main/ets/pages/SettingsPanel.ets`，见第 8 章）

## 0. 实施状态（已落地）

| 环 | 落点 | 状态 |
| --- | --- | --- |
| 模型 | `model/Topic.ets`：`TopicListInfo.attachPrefix`、`ThreadPageInfo.previewImages`（删类型错误的 `attachs?: string`） | ✅ |
| 工具 | `common/utils/TopicPreviewUtils.ets`（新增，纯函数：前缀归一化 / 图片过滤 / 缩略图 URL） | ✅ |
| 解析 | `parser/TopicParser.ets`（`attachs` → `previewImages`）、`parser/AppSubjectListParser.ets` 与 `parser/AppUserTopicParser.ets`（`attachPrefix` **解析期内部**透传，见 §4.2；不作为 `TopicListInfo` 字段暴露） | ✅ |
| UI | `pages/TopicListPanel.ets` → `TopicCardComponent.previewArea()`（开关 + 加载模式双重判定、被动占位、**原图**、失败即隐藏、多图角标） | ✅ |
| 设置 | `AppStorageKeys.KEY_SHOW_TOPIC_PREVIEW` / `SettingsState.showTopicPreview` / `MediaSettings.setShowTopicPreview` / `SettingsStore` 门面与 AppStorage 同步 / `SettingsPanel` 行 / `SettingsIconColors.topicPreview` / `settings_topic_preview.svg` | ✅ |
| 测试 | `entry/src/test/AppTopicListUnit.test.ets`：7 个用例（见 §4.6 清单） | ✅ |
| 文档 | 本文 + `docs/research/IMAGE_PIPELINE_AUDIT.md` §5.1 与 G2 的复测更正 | ✅ |
| 独立 Review | 两个独立 Agent 审查（解析/契约 + ArkTS/ArkUI/设置链路），逐条复核后修正：失败归属（K19）、精确 1×1（K20）、角标配色、URL 形态归一、hot 分支测试覆盖、本文档与代码对齐 | ✅ |

默认值：`showTopicPreview = false`（升级后列表视觉与流量不变，由用户显式开启）；若要默认开启，
改 `SettingsState.showTopicPreview` 一处即可。

---

## 1. 需求与生效范围

官方 App 的主题列表项会显示首帖附件的第一张图片（设置项「显示帖子预览图」控制，见
[官方设置项示例](https://jingyan.baidu.com/article/f3e34a12360544b4ea65355a.html)）。
本项目要复刻这一能力，但**只用列表接口已有的数据**。

| 列表入口（项目内调用点） | 是否带预览图数据 | 说明 |
| --- | --- | --- |
| `app_api.php subject/list`（`ForumApi.getTopicList` 普通版面列表） | ✅ **有** | `result.data[i].attachs`，约 29% 条目带图 |
| `app_api.php subject/hot`（热门榜） | ✅ **有** | 同上，`result` 为扁平数组，`attachPrefix` 在**响应顶层** |
| `app_api.php subject/topped`（置顶模式） | ❌ 无 | 实测 fid=7/‑547859 各 19/20 条，`attachs` 全无、无 `attachPrefix` |
| `app_api.php subject/search`（主题搜索） | ❌ 无 | 实测 3 组关键词 101 条，`attachs` 全无（`type` 位13 有 44 条，说明服务端就是不下发） |
| `app_api.php favor/all`（收藏夹） | ❌ 无 | 实测 9 条，无 `attachs`、无 `attachPrefix` |
| `app_api.php user/subjects`、`user/replys`、`nuke.php load_topic_by_uid` | ❌ 无 | 实测无 `attachs`、无 `attachPrefix` |

**结论：本功能只对「普通版面列表」与「热门榜」生效**；其余入口天然无图，UI 必须容忍
「无 `previewImages` → 不渲染预览区、不留空白」，这是设计前提而非缺陷。

### 1.1 板块差异：部分板块服务端根本不下发 `attachs`（实测，已知限制）

即使同为 `subject/list`，**部分板块整站不下发 `attachs`**（跨页一致，非偶发、非分页问题）：

| fid | 板块 | 3 页条目 | 带 `attachs` | `type` 位13（有附件） |
| --- | --- | --- | --- | --- |
| **-7** | 网事杂谈 | 129 | **0** | 40 |
| **843** | 国际新闻 | 99 | **0** | 80 |
| -547859 | 少前合集 | 39（1 页） | 3 | 19 |
| -81981 | 生命之杯 | 38（1 页） | 13 | 15 |
| 436 | （用户报告正常） | 120 | 48 | 48 |
| 7 | 艾泽拉斯议事厅 | 49（1 页） | 11 | 11 |
| 716 / -343809 / -576177 / -7955747 | 模型手办 等 | 35~60 | 全部 = 位13 数 | 同左 |

规律：**绝大多数板块 `attachs` 命中数 == `type` 位13 命中数**；少数板块（-7、843）为 **0**，
另有少数部分缺失（-547859、-81981）。抽查 `-7` 三条"位13=1 但无 attachs"的帖子，
`read.php` 首楼 **确实有图**（如 `[img]./mon_202609/19/-7Q43-ezxjZdT1kShs-13i.jpg[/img]`，
首楼 `attachs` 键为 `["0"]`）——即**服务端知道有附件（位13 已置位）却不把附件投送到列表条目**。
网页版 `thread.php`（用户所给 URL 的形态）同样如此：`fid=-7` 的 `__T` 0 条 `attachs`。

因此：**这些板块在官方 App 里同样看不到列表预览图**（官方 `Subject.getAttachs()` 也只读
`attachs`，无该字段则 `photos` 为空、`PostStaggeredGridViewBinder` 隐藏预览图）。

**补图方案已评估为不可行**（实测）：

| 候选 | 体积 | 能否取到首帖图 |
| --- | --- | --- |
| `read.php?tid=X`（含 `pid=0`，`pid` 参数不裁剪响应） | ≈17~21 KB | ✅ 但等于拉整页 19~20 楼 |
| `app_api.php post/list?tid=X` | ≈20~22 KB | ✅（与首楼图重合） |
| `nuke.php load_topic/load_topic_reply_ladder2?tid=X` | ≈8 KB | ❌ 返回的是"回复阶梯"，与首楼图 0 重合 |
| 批量 `tid=a,b,c`（`post/list` / `subject/list tids=`） | — | ❌ 服务端只认第一个 tid / 忽略参数 |

即"按需补图"只能**一帖一次 ~20 KB 请求**：一屏 10 条 × 命中率（-7 约 36%）≈ 3~4 次请求 / 60~80 KB，
且触碰 NGA 频率限制（`code=15`），与"不请求帖子详情"的设计前提直接冲突。
**当前实现选择不补救**：这类板块只是没有预览区（正常降级），不做按需拉详情。

**当前决定：不提示、不补图**——这类板块就是没有预览图，与官方 App 行为一致（已与需求方确认：
服务端不下发的数据不必显示）。若将来真要区分"该帖有附件但本板块不下发"，可用
`type` 位13=1 且 `previewImages` 为空 判定；但**不要把位13 当作"一定会有预览图"来驱动 UI**（见 K18）。

---

## 2. 数据来源与实测证据

### 2.1 响应形状（实测，2026-08，登录态）

```jsonc
// POST app_api.php?__lib=subject&__act=list  （与现有请求参数完全一致：fid/page/sign/f=...）
{
  "code": 0, "msg": "操作成功",
  "result": {
    "attachPrefix": "https://img.nga.cn/attachments/",   // ← 附件前缀（权威值，需透传）
    "subForum": [ ... ],
    "data": [
      {
        "tid": 47344551, "fid": 7, "author": "皮纳特丶", "authorid": 64371487,
        "subject": "[战报帖] ...", "postdate": 1786338953, "lastpost": 1789524704,
        "lastposter": "王紧张", "replies": 4426, "type": 74756,
        "attachs": [ { "attachurl": "mon_202608/19/7Q68-jpq0ZtT3cS1uo-11i.jpeg" } ],  // ← 预览图数据
        "titlefont_api": { ... }, "style": 1, "forumname": "..."
      }
    ]
  },
  "totalPage": 106923, "total": 3742292, "currentPage": 1, "perPage": 35
}
```

### 2.2 实测统计（`subject/list` 与 `subject/hot`）

| 项目 | 实测结果 |
| --- | --- |
| `attachs` 元素结构 | 只有一个键 `attachurl`（108 个元素全部如此） |
| 覆盖率（fid=7 三页 123 条） | 36 条带附件 = **29.3%**，共 80 张图 |
| 覆盖率（fid=-547859 三页 107 条） | 3 条 = 2.8% |
| 覆盖率（`subject/hot` days=1，35 条） | 12 条 = 34% |
| 附件类型分布（108 个） | jpg 100、webp 5、jpeg 1、gif 1、**mp4 1** |
| 语义 | **首帖附件**：抽查 tid=47344551，列表 `attachs[0]` 与首楼 `pid=0` 正文中 `[img]./mon_202608/19/7Q68-...jpeg[/img]` 完全一致 |

### 2.3 图片 URL 规则（实测 HTTP 状态）

| 写法 | 结果 |
| --- | --- |
| `{attachPrefix}{attachurl}` | ✅ 200 `image/jpeg` 292 KB（原图；无自定义请求头亦可取） |
| `{attachPrefix}{attachurl}.thumb.jpg` | ✅ 200 `image/jpeg` **14.9 KB**（缩略图，webp 源图同样可用，输出 jpeg 16.6 KB） |
| `{attachPrefix}{attachurl}` 去掉扩展名再 `.thumb.jpg` | ❌ 404 |
| `{attachPrefix}{attachurl}` 仅加裸后缀 `.thumb` | ❌ 404（**后缀必须带 `.jpg`**，见 §5.1 / §5.4） |
| `img4.nga.cn` 替 `img.nga.cn` | ❌ 404（**必须用 `attachPrefix` / `img.nga.cn`**） |
| 完整档位矩阵（6 源扩展 × 6 后缀） | 见 **§5.1**（`.thumb_s.jpg` ≈2~4 KB，更省流量） |

缩略图后缀与官方实现一致：官方 `AttachsBean.getThumb(1)` = `ft.s0` 的 `es.g0.s = ".thumb.jpg"`；
另有 `.medium.jpg`（`getThumb(0)`）、`.thumb_s.jpg`（`getThumb(2)`）、`.thumb_ss.jpg`。

### 2.4 官方 App 的做法（nga-hack 反编译证据，用于对齐）

| 证据 | 内容 |
| --- | --- |
| `gov/pianzong/androidnga/model/AttachsBean.java` | `attachurl/hostUrl/thumb0..2/whArr`；`parseUrlSubject()` **只认 `.jpg/.jpeg/.png/.gif/.webp`**；`isThumbUsable()` 要求 URL 含 `thumb/thumb_s/medium` |
| `Subject.java:18,84,310,725` | `attachs`（原始 Object）→ `getAttachs()`（Gson 转 `List<AttachsBean>`）→ `parseUrlSubject(hostUrl)` 逐条设前缀、过滤非图、塞进 `photos` |
| `com/donews/nga/subject/viewbinder/PostStaggeredGridViewBinder.java:134-193` | 列表卡片：`photos` 为空 → 预览 `ImageView` `setVisibility(8)`；非空 → 取 `photos.get(0)`，`style==1 ? getOriginalUrl() : getThumb(1)` 交 Glide，按宽高比在 100~250dp 间定高 |

**本项目与之的差异（有意为之）**：统一用 `.thumb.jpg`（不跟 `style==1` 走原图，省流量）；
不解析 `S{宽}-{高}` 尺寸段，固定高度 + `Cover`（见 6.1、6.6）。

---

## 3. 数据链路总览

### 3.1 现状（为什么现在一张图都没有）

```text
subject/list 响应 ──► AppSubjectListParser.parseSubjectList ──► 只取 data/subForum/totalPage/forumname
                          │（attachPrefix 被丢弃）
                          ▼
                      TopicParser.parseTopicList ──► mapTopicRaw
                          │  attachs: String(raw['attachs'] ?? '')   ← 数组被强转成 "[object Object]"
                          │  previewImages: []                       ← 恒为空数组
                          ▼
                  TopicCardComponent ──► 只渲染标题/摘要/作者/回复数（无 Image）
```

### 3.2 目标链路

```text
subject/list ─► AppSubjectListParser（透传 attachPrefix 到 fakeRaw）
                     ▼
                TopicParser（读取 attachPrefix + attachs → 过滤 → 绝对 URL → previewImages）
                     ▼
              ThreadPageInfo.previewImages: string[]
                     ▼
      TopicCardComponent（受 showTopicPreview 开关 + ImageLoadStrategy 双重约束渲染）
```

### 3.3 文件改动清单

| 文件 | 动作 | 是否镜像文件（`tools/bbcode-ts`） |
| --- | --- | --- |
| `entry/src/main/ets/model/Topic.ets` | 改：`TopicListInfo` 加 `attachPrefix`；`ThreadPageInfo` 加 `previewImages`，删除类型错误的 `attachs?: string` | ❌ 非镜像 |
| `entry/src/main/ets/parser/TopicParser.ets` | 改：解析 attachs → previewImages | ❌ 非镜像 |
| `entry/src/main/ets/parser/AppSubjectListParser.ets` | 改：透传 attachPrefix（3 处） | ❌ 非镜像 |
| `entry/src/main/ets/common/utils/TopicPreviewUtils.ets` | **新增**：纯函数（前缀归一化/过滤/缩略图） | ❌ 非镜像 |
| `entry/src/main/ets/pages/TopicListPanel.ets` | 改：`TopicCardComponent` 预览图区 | ❌ 非镜像 |
| `entry/src/main/ets/store/settings/SettingsState.ets` | 改：新增 `showTopicPreview` 字段 | ❌ 非镜像 |
| `entry/src/main/ets/store/settings/domain/MediaSettings.ets` | 改：setter + load | ❌ 非镜像 |
| `entry/src/main/ets/store/SettingsStore.ets` | 改：门面转发 + AppStorage 同步 | ❌ 非镜像 |
| `entry/src/main/ets/common/constants/AppStorageKeys.ets` | 改：新增 key 常量 | ❌ 非镜像 |
| `entry/src/main/ets/common/constants/Constants.ets` | 改：`SettingsIconColors.topicPreview` | ❌ 非镜像 |
| `entry/src/main/ets/pages/SettingsPanel.ets` | 改：新增 Toggle 行 | ❌ 非镜像 |
| `entry/src/main/resources/base/media/settings_topic_preview.svg` | **新增**：行图标 | ❌ 非镜像 |
| `entry/src/test/AppTopicListUnit.test.ets` | 改：补预览图断言 | ❌ 非镜像 |

> 本次已跑 `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` → **0 修改 / 34 文件无变化**；
> 上表全部不在镜像清单内，可直接修改。**唯一需要注意的镜像文件是
> `parser/_shared/AttachUrl.ets`**——本设计**不修改它**（新工具函数放在非镜像的
> `TopicPreviewUtils.ets`），因此无需走 bbcode-ts 门禁。若后续决定把缩略图/前缀工具下沉到
> `AttachUrl`，则必须改 `tools/bbcode-ts/src/parser/_shared/AttachUrl.ts` → `npm test`
> → `npm run sync` → dry-run 归零（见 `bbcode-ts` skill）。

---

## 4. 解析层设计

### 4.1 模型改动（`model/Topic.ets`）

```ts
export interface TopicListInfo {
  /** 当前版块名称。 */
  name: string;
  /** 当前页主题列表。 */
  threadPageList: ThreadPageInfo[];
  /** 当前版块下可浏览或屏蔽的子版块列表。 */
  subBoardList: SubBoard[];
  /** NGA 服务端当前时间。 */
  curTime: number;
  /** 主题列表分页信息。 */
  pagination: Pagination;
}

export interface ThreadPageInfo {
  // ...（其余字段不变）
  /** 首帖附件中可作为预览图的绝对 URL 列表（已过滤非图片；无附件时为空数组）。 */
  previewImages: string[];
  // 原 `attachs?: string` 删除：该字段实测是「对象数组」而非字符串（旧代码 String() 强转是错的）。
  // 原始条目不再进入页面模型——UI 只消费 previewImages；将来若要诊断/扩展再按同样方式加字段。
}
```

> `TopicRaw`（同文件的原始响应接口）**本次未改动**：`mapTopicRaw` 走 `Record<string, Object>`
> 取值，不依赖该接口；`AttachItem` 一类的结构化类型也**未引入**（`attachs` 在解析层直接按
> `Object` + `Array.isArray` 守卫处理，见 4.3 的 `parsePreviewImages`）。

### 4.2 前缀透传（`parser/AppSubjectListParser.ets`）

`attachPrefix` 在**两处**出现，必须都读：

| 接口 | 位置 |
| --- | --- |
| `subject/list`、`subject/search` | `result.attachPrefix` |
| `subject/hot` | **响应顶层** `attachPrefix`（`result` 是扁平数组，没有 result 对象） |
| `subject/topped` | 无（该入口也没有 `attachs`） |

改动点共 **6 个写/读点**（前 5 处写入 `fakeRaw`/透传，最后 1 处在解析层读取；**全部发生在解析期内部**，`TopicListInfo` 不暴露 `attachPrefix`——该字段曾加过，因全仓无消费方已删除）：

| # | 位置 | 作用 |
| --- | --- | --- |
| ① | `AppSubjectListParser.buildFlatTopicListInfo` | 新增 `attachPrefix` 形参并写进 `fakeRaw` |
| ② | `AppSubjectListParser.parseToppedList` | 显式传 `''`（置顶接口无前缀、也无 attachs） |
| ③ | `AppSubjectListParser.parseHotSubjectList` | 读**响应顶层** `attachPrefix` |
| ④ | `AppSubjectListParser.parseSubjectList` | 读 `result.attachPrefix` 写入 `fakeRaw`，并在重建 `TopicListInfo` 时补字段 |
| ⑤ | `AppUserTopicParser.buildAppTopicListInfo` | 同口径透传（收藏夹 / 用户主题回帖；现网无 attachs，为将来兜底） |
| ⑥ | `TopicParser.parseTopicList` | 统一读取 `rawObj['attachPrefix']` 并传给 `mapTopicRaw` |

```ts
// ① buildFlatTopicListInfo 增加 attachPrefix 参数，写进 fakeRaw
function buildFlatTopicListInfo(rawArr: Record<string, Object>[], blacklist: Set<string>,
  keywords: string[], page: number, attachPrefix: string): TopicListInfo {
  const t: Record<string, Object> = {};
  for (let i = 0; i < rawArr.length; i++) {
    t[String(i)] = rawArr[i];
  }
  const dataObj: Record<string, Object> = {};
  dataObj['__T'] = t;
  dataObj['__ROWS'] = rawArr.length;
  dataObj['__T__ROWS_PAGE'] = rawArr.length;
  const fakeRaw: Record<string, Object> = {};
  fakeRaw['data'] = dataObj;
  fakeRaw['attachPrefix'] = attachPrefix;   // ← 新增：交给 parseTopicList 统一读取
  fakeRaw['time'] = Math.floor(Date.now() / 1000);
  return parseTopicList(fakeRaw, blacklist, keywords, page);
}

// ② parseToppedList：置顶无 attachPrefix（也无 attachs），传空串
return buildFlatTopicListInfo(rawArr, blacklist, keywords, page, '');

// ③ parseHotSubjectList：前缀在响应顶层
const prefix: string = String(rec['attachPrefix'] ?? '');
return buildFlatTopicListInfo(rawArr, blacklist, keywords, page, prefix);

// ④ parseSubjectList：前缀在 result 内（同一 fakeRaw 构造处）
const prefix: string = String(resRec['attachPrefix'] ?? '');
fakeRaw['attachPrefix'] = prefix;

// ⑤ parseSubjectList 末尾重建 TopicListInfo 时补字段（否则缺必填字段编译不过）
const info: TopicListInfo = {
  name: base.name,
  threadPageList: base.threadPageList,
  subBoardList: subs,
  curTime: base.curTime,
  pagination: base.pagination,
  attachPrefix: prefix,   // ← 新增（base.attachPrefix 亦可，两者同源）
};
```

### 4.3 新增纯函数模块（`common/utils/TopicPreviewUtils.ets`）

```ts
/**
 * 主题列表帖子预览图工具（纯函数，可独立测试）。
 *
 * 数据来源：官方 subject 系列表条目的 `attachs` 数组 + 响应 `attachPrefix`（见
 * docs/TOPIC_PREVIEW_DESIGN.md 第 2 章实测）。本模块只做「原始条目 → 可加载 URL」的
 * 纯变换，不做网络请求、不依赖 AppStore。
 */

import { NGA_CDN_BASE } from '../../parser/_shared/AttachUrl'
import { stripImageSuffix } from './Utils'

/**
 * 可作为预览图的扩展名白名单。
 *
 * 与官方 `AttachsBean.parseUrlSubject()` 一致（jpg/jpeg/png/gif/webp）并补 bmp；
 * 实测 attachs 中混有 mp4（108 个附件里 1 个），不过滤会把视频当封面。
 * 注意：`.gif.mp4` 的 `.thumb.jpg` 实测是**可用封面**（见文档 §5.3）——若产品希望"视频帖也有
 * 预览图"，可把 mp4 放入白名单，并接受列表里显示静帧。
 */
const PREVIEW_IMAGE_EXTS: string[] = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp']

/** 附件前缀缺失时的兜底根（换域时改 NgaDomains.NGA_IMG_BASE 即可）。 */
const FALLBACK_PREFIX: string = NGA_CDN_BASE + '/'

/**
 * 归一化附件前缀为「带协议、以 / 结尾」的形态。
 *
 * @param prefix - 响应 attachPrefix（可能为空；thread.php 的 _ATTACH_BASE_VIEW 无协议）
 * @returns 可拼接的前缀
 */
export function normalizeAttachPrefix(prefix: string): string {
  let p: string = prefix.trim()
  if (p.length === 0) {
    return FALLBACK_PREFIX
  }
  if (!p.startsWith('http')) {
    p = 'https://' + p
  }
  if (!p.endsWith('/')) {
    p = p + '/'
  }
  return p
}

/**
 * 判断 attachurl 是否为可作预览图的图片。
 *
 * @param attachurl - 官方附件相对路径
 * @returns 是否可作预览图
 */
export function isPreviewImage(attachurl: string): boolean {
  const dot: number = attachurl.lastIndexOf('.')
  if (dot < 0 || dot === attachurl.length - 1) {
    return false
  }
  const ext: string = attachurl.substring(dot + 1).toLowerCase()
  return PREVIEW_IMAGE_EXTS.indexOf(ext) >= 0
}

/**
 * 把 attachurl 拼成可加载的绝对 URL。
 *
 * @param prefix - 响应 attachPrefix（空串时回退 NGA_CDN_BASE）
 * @param attachurl - 官方附件相对路径（已是 http 开头则原样返回）
 * @returns 绝对 URL；非法值返回空串
 */
export function buildPreviewUrl(prefix: string, attachurl: string): string {
  if (attachurl.length === 0) {
    return ''
  }
  if (attachurl.startsWith('http')) {
    return attachurl
  }
  if (attachurl.indexOf('/') < 0) {
    return ''
  }
  return normalizeAttachPrefix(prefix) + attachurl
}

/**
 * 把官方 attachs 字段解析为预览图 URL 列表。
 *
 * @param rawAttachs - 原始 attachs 值（实测为对象数组；占位条目可能为 ''）
 * @param prefix - 响应 attachPrefix
 * @returns 预览图绝对 URL 列表（保序、已过滤非图片；无有效项时为空数组）
 */
export function parsePreviewImages(rawAttachs: Object | undefined, prefix: string): string[] {
  if (rawAttachs === undefined || rawAttachs === null || !Array.isArray(rawAttachs)) {
    return []
  }
  const urls: string[] = []
  const arr: Object[] = rawAttachs as Object[]
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i]
    if (item === undefined || item === null || typeof item !== 'object' || Array.isArray(item)) {
      continue
    }
    const attachurl: string = String((item as Record<string, Object>)['attachurl'] ?? '')
    if (!isPreviewImage(attachurl)) {
      continue
    }
    const url: string = buildPreviewUrl(prefix, attachurl)
    if (url.length > 0) {
      urls.push(url)
    }
  }
  return urls
}
```

> **档位函数已删除**：列表统一用原图后，`toPreviewThumbUrl` / `PREVIEW_THUMB_SUFFIX` 成为
> 无调用方的死代码，已从 `TopicPreviewUtils.ets` 移除（含 2 个对应单测）。档位规则本身作为
> **知识**保留在本文档 §5.1/§5.2：需要切档时按那里的规则实现（`stripImageSuffix(url) + '.thumb.jpg'`，
> 3 行），不要重新"发明"命名形式。

### 4.4 接入 `parser/TopicParser.ets`

```ts
import { parsePreviewImages } from '../common/utils/TopicPreviewUtils'

export function parseTopicList(raw: object | null, blacklist: Set<string> = new Set(),
  keywords: string[] = [], currentPage: number = 1): TopicListInfo {
  // ...（现有逻辑不变）
  /* 附件前缀只在解析期用于拼接图片 URL，**不作为 TopicListInfo 字段对外暴露**
     （UI 消费的 previewImages 已是绝对 URL，无消费方的字段已删除） */
  const attachPrefix: string = String(rawObj?.['attachPrefix'] ?? '')
  // ...
  return {
    name: String(forumInfo?.['name'] ?? ''),
    threadPageList: topics,
    subBoardList: [],
    curTime: Number(rawObj?.['time'] ?? 0),
    pagination: calcPagination(totalRows, rowsPerPage, currentPage),
  };
}

function mapTopicRaw(raw: Record<string, Object>, isInBlackList: boolean,
  attachPrefix: string): ThreadPageInfo {
  // ...（现有逻辑不变）
  return {
    // ...
    previewImages: parsePreviewImages(raw['attachs'], attachPrefix),   // ← 新增
    // 删除旧的 attachs: String(raw['attachs'] ?? '') 与 previewImages: []
  };
}
```

`parseTopicList` 的循环里把 `attachPrefix` 一起传给 `mapTopicRaw`。

> `AppUserTopicParser.normalizeAppUserTopicItem` 里 `out['attachs'] = item['attachs'] ?? ''`
> **保持不动**（`??` 只兜 null/undefined，若某入口真的下发数组**不会**被丢弃）：空串在
> `parsePreviewImages` 里被 `Array.isArray` 守卫安全跳过。
> 同文件的 `buildAppTopicListInfo` 已补 `attachPrefix` 形参并从 `raw`（顶层或 `result`）读取——
> 这三个入口现网不下发 `attachs`，透传只为将来兜底（否则前缀只能吃 `NGA_CDN_BASE`）。

### 4.5 边界与容错规则

| 输入 | 行为 |
| --- | --- |
| `attachs` 缺失 / `''` / **JSON null** / 非数组 | `previewImages = []`（形参 `Object \| null \| undefined` + `Array.isArray` 守卫） |
| 元素为非对象（字符串/数字/嵌套数组） | 跳过该元素（`typeof item !== 'object' \|\| Array.isArray(item)`） |
| 元素缺 `attachurl` | 跳过该元素 |
| 扩展名非图片（mp4/zip…） | 跳过（白名单过滤，大小写不敏感：`A.JPG` 通过且 URL 保留原大小写） |
| `attachurl` 带 query / fragment（`a.jpg?x=1`） | 先剥离 `?`/`#` 再判扩展名（否则 `jpg?x=1` 会被误判为非图片） |
| `attachurl` 前导 `./` 或 `/` | 归一后拼接（不产生 `./mon_` 段或 `…//mon_` 双斜杠） |
| `attachPrefix` 缺失（置顶/收藏/用户列表） | 回退 `NGA_CDN_BASE`（`https://img.nga.cn/attachments/`）→ 这些入口本就无 `attachs`，结果仍是 `[]` |
| `attachPrefix` 无协议（`thread.php` 的 `_ATTACH_BASE_VIEW`） | `normalizeAttachPrefix` 补 `https://` 与尾 `/` |
| `attachPrefix` 协议大小写混写（`HTTPS://…`） | 用 `/^https?:\/\//i` 判定，**不再重复补协议** |
| `attachurl` 已是 http 绝对地址 | 原样使用（不重复拼前缀，也**不做**旧域归一化——现网 attachs 无绝对路径，见 K11） |
| `attachurl` 无 `/`（`a.jpg`/纯数字） | 视为非法，返回空串并跳过 |
| 解析出的 URL 为空串 | 不进入 `previewImages` |

### 4.6 测试（Hypium，`entry/src/test/AppTopicListUnit.test.ets` 内追加 `it`）

现有 fixture（`createSubjectListResponse`）**已经带了** `attachPrefix` 与 `attachs` 数组，
**无需**改 fixture、也**不需要**动 `entry/src/test/List.test.ets`（只是在既有测试函数里追加用例）。
实际落地的 7 个用例：

| 用例 | 保护的行为 |
| --- | --- |
| `parsesTopicPreviewImages` | `subject/list`：`result.attachPrefix` 透传 + `attachs → previewImages`；无 attachs 条目为空数组 |
| `parsesPreviewImageEdgeCases` | 非数组（对象）、`undefined`、非图扩展名、纯数字、空串；前缀缺失回退；无协议前缀补全 |
| `parsesHotSubjectPreviewPrefix` | **`subject/hot` 顶层 attachPrefix** 分支（此前零覆盖） |
| `parsesToppedWithoutPreview` | `subject/topped`：`attachPrefix === ''` 且无预览图（回归锚点） |
| `parsesPreviewItemGuards` | 元素级守卫（字符串/数字/嵌套数组/缺 attachurl）、JSON `null`、无 `/` 的路径守卫 |
| `normalizesPreviewUrlForms` | 前导 `./`·`/` 归一、协议大小写、query/fragment 不干扰扩展名判定 |
| `keepsPreviewOrderAndAbsoluteUrl` | 多图保序、绝对地址原样保留不重复拼前缀 |

---

## 5. 图片质量档位与正文 IMG 链路的关系

> 本章是"不要盲目"的落地结果：把**服务端档位**、**正文 IMG 链路**、**项目既有 URL 工具**
> 三件事各自的真实数据核对清楚，再决定预览图取哪个 URL。

### 5.1 服务端确实提供多档缩略图（实测矩阵）

对 6 种源扩展 × 6 种后缀逐一请求（2026-09，`https://img.nga.cn/attachments/` + 真实附件）：

| 源扩展（原图字节） | `.thumb.jpg` | `.thumb_s.jpg` | `.thumb_ss.jpg` | `.medium.jpg` | `.thumb_m.jpg` |
| --- | --- | --- | --- | --- | --- |
| jpeg（292 164） | **14 900** | 3 965 | 1 528 | 42 856 | ❌ 404 |
| jpg（75 107） | **10 644** | 3 357 | 1 461 | 29 564 | ❌ 404 |
| png（108 379） | **5 114** | 1 911 | 1 092 | ⚠️ 108 379（**回退原图** png） | ❌ 404 |
| gif（903 229） | **13 915**（jpeg 静帧） | 4 410 | 1 547 | ⚠️ 903 229（**回退原图** gif） | ❌ 404 |
| webp（79 962） | **15 589** | 3 990 | 1 503 | 45 447 | ❌ 404 |
| `*.gif.mp4`（1 125 519） | **18 966**（封面） | 4 203 | 1 563 | 62 717 | ❌ 404 |

三条实测规则：

1. **必须带图片扩展名**：在"名字.原扩展名"之后**整串追加** `.thumb.jpg`。
   只写裸后缀（`…jpeg.thumb` / `…jpeg.medium` / `…jpeg.thumb_s` / `…jpeg.thumb_m`）→
   **全部 404**（`text/html` 146 B）。
2. `.thumb_m.jpg` **不存在** —— `common/utils/Utils.ets:118` 注释里的"中缩略图 ≤120px"与现网不符
   （该注释无调用点，不构成 bug，但已过时）。
3. `.medium.jpg` **不可靠**：png / gif 源会**回退成原图**（字节数、content-type 与原图完全相同），
   只有 jpeg/jpg/webp/mp4 有真正的 medium 档。列表预览不要依赖它。

> `.thumb*.jpg` 对 **2020 年的老附件同样有效**（老 png：原图 108 379 → `.thumb.jpg` 5 114）
> —— 这是服务端**按后缀预生成**的能力，不是近期才上线。

### 5.2 正文 IMG 链路（成熟体系）能否输出预览图质量：能，且同源

正文图片链路（镜像真源 `tools/bbcode-ts/src/parser/bbcode/block-handlers/handleImg.ts:35,53`
→ `src/parser/_shared/AttachUrl.ts:82-89`）：

```text
[img]./mon_xxx/a.jpg[/img]  ─┐
[img]https://…[/img]        ─┴─► handleImg → resolveImgUrl
                                   ├─ 域归一化（旧域 img*.nga.178.com → img.nga.cn）
                                   └─ stripImageSuffix()   ← 所有分支都调用
                                        └─► 裸名原图 URL（BBNode.src）
```

所以"正文图片必然原图"成立；但它**只实现了"去档位"这一个方向**——这也正是既有"无缩略图分级"
缺口（`docs/research/IMAGE_PIPELINE_AUDIT.md` G2）的由来。

要输出预览图档位，需要**两个方向都在**：

```text
任意图片 URL ──stripImageSuffix()──► 裸名原图 ──+ '.thumb.jpg'──► 预览图档位
```

- 实测 `stripImageSuffix` 对 6 种真实形式都能还原到裸名（追加式、插入式均可），
  只有**叠加**形式（`.medium.jpg.thumb.jpg`）会残留一层 —— 该形式在真实数据中不存在（见 5.5）。
- "追加"侧项目**没有**可用函数：`applyImageSuffix` 零调用且形式错误（404，见 5.6）；
  `ReplyDialog.ets:428` / `NewTopicDialog.ets:443` 的 `'[img]./' + imageUrl + '.medium.jpg[/img]'`
  是**硬编码正文文本**（恰好落在有效的追加式上），不是可复用的渲染期转换。

**结论**：预览图不是另起一套体系，而是**正文链路同一形态规则的另一档**。
档位 URL 的产出口径因此是 `stripImageSuffix(url) + '.thumb.jpg'`
（先归一到裸名、再追加档位），对"列表裸名 `attachs`"与"正文任意档位 URL"**两种输入都正确**。

> **当前实现的选择（重要）**：列表预览**直接使用原图**（见 §5.3 / K22），与 `ImageViewer` /
> `ThreadPanel` 的图片链路同源同质量。因此档位函数**已从生产代码移除**（无调用方即死代码），
> 只作为**知识**保留在本章：需要切档时按本节规则实现
> （`stripImageSuffix(url) + '.thumb.jpg'`，3 行）。

### 5.3 列表预览的质量选型：**统一使用原图**（当前实现）

**决策**：列表预览图与 `ImageViewer` / `ThreadPanel` 的图片链路**保持一致——直接用原图**
（`previewImages[i]` 本身就是原图绝对 URL）。**不使用**服务端缩略档位（`.thumb.jpg` 等）。
理由与代价见 K22。

| 用途 | URL | 说明 |
| --- | --- | --- |
| 列表预览（**当前实现**） | `firstPreviewUrl()`（原图） | 与查看器、正文同源同质量；点开查看器无二次下载（`Image` 缓存命中） |
| 加载失败 | 整块隐藏 | **只有这一级**（`previewFailed`），无更低质量回退档 |
| 可选档位（**当前未实现**） | 按 §5.2 规则：`stripImageSuffix(url) + '.thumb.jpg'`（或 `.thumb_s.jpg` / `.medium.jpg`） | 规则已实测；实现约 3 行。当前刻意**不保留无调用方代码**（见 K22） |
| 查看器大图 | 原图（`openImageViewer`） | 与列表同一张图 |

**动图/视频可选增强**：`gif` 与 `*.gif.mp4` 的 `.thumb.jpg` 是**可用的 jpeg 封面**
（13.9 KB / 19.0 KB）。若希望"视频帖也有预览图"，可把 4.3 的扩展名白名单放宽到含 `mp4`
（仍排除 zip/rar 等），并接受"动图在列表里显示静帧"。

### 5.4 与 `docs/research/IMAGE_PIPELINE_AUDIT.md` §5.1 的结论差异（**已同步更正**）

该文档 §5.1（2026-09）的记录是：

> 分别请求 `.medium` / `.thumb_s` / `.thumb_m` / `.thumb` 变体 → **全部 `404`**
> → NGA 当前 CDN 不提供任何服务端缩略图 … 任何"列表用缩略图、查看器用原图"的方案都必须走
> **客户端**手段（`sourceSize` 解码降采样 / 自行缩放缓存），服务端没有小图可取

**本轮实测不能复现该结论**，差异根因可定位（两个测法只差"是否带 `.jpg`"）：

| 请求的字符串 | §5.1 记录 | 本轮实测 |
| --- | --- | --- |
| `…jpeg.thumb` / `…jpeg.medium` / `…jpeg.thumb_s` / `…jpeg.thumb_m`（**裸后缀**） | 404 | **404（一致）** |
| `…jpeg.thumb.jpg` / `…jpeg.medium.jpg` / `…jpeg.thumb_s.jpg` / `…jpeg.thumb_ss.jpg`（**带 `.jpg`**） | 未覆盖 | **200（矩阵见 5.1）** |

且 2020 年老附件同样有 `.thumb.jpg` 档 → **不是"CDN 后来才支持"**，而是当时测试用的后缀字符串
不带图片扩展名。建议：

- 更正该文档 §5.1 结论与缺口 **G2**："解析时 strip 成原图"仍成立，但"服务端没有小图可取"不成立
  —— 服务端按后缀提供多档，列表/查看器分级可以直接走服务端缩略图，不必全靠客户端 `sourceSize`；
- 该文档 §5.2 的"43 字节 GIF 错误图"结论**依然正确且重要**：`Image` 会把 404 当加载成功
  （`onError` 不触发、`onComplete` 回填 1×1）——预览图的失败判定同样受此影响，见本文档 K16。

### 5.5 正文/样本侧的 URL 命名分布（为什么"裸名"是主流）

对 `tools/bbcode-ts/samples/*.json`（24 个真实样本）里 41 个 `[img]` 分类统计：

| 形式 | 数量 | 例子 |
| --- | --- | --- |
| 裸名 `name.ext` | **32** | `./mon_202608/31/c4Q74-ia2kK2aT3cSsg-p7.jpg` |
| 绝对 URL（多为旧域 png） | 9 | `http://img.nga.178.com/attachments/mon_202002/24/7Q5-b75pZbT1kSb4-68.png` |
| 含档位段（追加式/插入式） | **0** | —— |

- 正文以**裸名 + 旧域绝对 URL** 为主，因此"strip → 原图"在实践中几乎总是幂等；
- 旧域 `img.nga.178.com` 现在**已不可达**（`fetch failed`；本项目 `resolveImgUrl` 的域归一化因此是
  必需的），换到 `img.nga.cn` 后原图与各档位均 200（见 5.1 老 png 行）；
- 客户端**自己插入**的图片走追加式 `.medium.jpg`（`ReplyDialog.ets:428`），所以"正文可能带档位段"
  这个前提必须保留 —— 这也是档位规则要求"先 strip 再追加"的理由（§5.2）。

### 5.6 与项目既有 URL 工具的关系（重要：勿"顺手复用"）

项目里**已经**有一组「多质量 URL 转换」函数（用户常误以为可直接用于预览图），
但它们服务于**另外两条图片链路**，与列表附件不同源：

| 函数 | 位置 | 面向的输入 | 语义 | 能否用于列表预览 |
| --- | --- | --- | --- | --- |
| `resolveAttachUrl` | `parser/_shared/AttachUrl.ets`（**镜像文件**） | `read.php` 帖子附件的 `attachurl`（帖子详情链路） | 裸相对路径 → `NGA_CDN_BASE + path` | 可用（输入形状相同），但列表有服务端 `attachPrefix`，应优先用响应前缀 |
| `resolveImgUrl` | 同上 | BBCode `[img]` 标签内容 | 域归一化 + `stripImageSuffix` → **原图** | ⚠️ 不能直接当预览 URL（它返回原图、不带档位）；但它内部的 `stripImageSuffix` 正是预览图需要的第一步 |
| `stripImageSuffix` | `common/utils/Utils.ets:147-150`（**镜像文件**，只读引用） | 正文图片 URL | 去掉 `.thumb_s/.thumb_m/.medium/.thumb` → **裸名原图** | ⚠️ 当前生产未使用（列表用原图）；若切档位则是**第一步**：`stripImageSuffix(url) + '.thumb.jpg'`（对裸名输入幂等） |
| `applyImageSuffix` | `common/utils/Utils.ets:152-158` | ——（**全仓零调用点**） | `name.ext` → **`name.size.ext`**（尺寸词插在扩展名**前**） | ❌ **实测 404，禁止用于预览图** |

实测（2026-09，同一张首帖附件，前缀 `https://img.nga.cn/attachments/`）：

| 形式 | 结果 |
| --- | --- |
| `mon_…-11i.jpeg`（原图） | 200 `image/jpeg` 292 164 B |
| `mon_…-11i.jpeg.thumb.jpg`（**整串末尾追加**，官方 `ft.s0.b` 形式） | 200 `image/jpeg` **14 900 B** |
| `mon_…-11i.jpeg.medium.jpg` | 200 `image/jpeg` 42 856 B |
| `mon_…-11i.jpeg.thumb`（**裸后缀**，无 `.jpg`） | **404**（`text/html` 146 B） |
| `mon_…-11i.thumb.jpeg`（= `applyImageSuffix(url, 'thumb')` 的输出） | **404**（`image/gif` 43 B 错误图） |
| `mon_…-11i.thumb_s.jpeg` / `mon_…-11i.medium.jpeg`（同函数输出） | **404** |
| `stripImageSuffix(裸名 URL)` | 原样返回（对裸名无副作用） |
| `stripImageSuffix(…jpeg.thumb.jpg)` / `(…jpeg.medium.jpg)` / `(…thumb.jpeg)` | 全部还原为 `mon_…-11i.jpeg` |

**结论**：

1. 列表附件用**先 strip 再整串追加**的 `.thumb.jpg`（与官方 `AttachsBean.getThumb(1)` 同档），
   即档位实现应**复用 `stripImageSuffix`**、但**不复用 `applyImageSuffix`**；
2. 两条实测禁用关系：`applyImageSuffix` 的 `name.size.ext` 形式不存在（404）、
   裸后缀（不带 `.jpg`）不存在（404）——后者正是 5.4 那段旧结论的来源。

> **`ImageViewer` / `ThreadPanel` 侧没有多质量转换**：`ImageViewer` 直接消费调用方传入的
> `urls: string[]`（`ImageViewer.ets:19`，前后预加载也是同一批 URL，见 `:458/:493/:511`）；
> `ThreadPanel.openImageViewer` 只是转发 `onImageClick`（`ThreadPanel.ets:1960-1961`、`2020-2021`）。
> 列表预览图若要"点开看大图"，应把 `previewImages`（原图或 `.medium.jpg`）交给既有
> `openImageViewer(urls, index)`（`common/utils/LinkUtils.ets:75`），而**不是**在卡片里自建质量
> 切换逻辑。

---

## 6. UI 设计（`TopicCardComponent`）

### 6.1 布局与尺寸

现有卡片结构（`TopicListPanel.ets:1627-1862` 的 `TopicCardComponent`）与新增预览区位置：

```text
Column（卡片，padding 16/16/16/16）
├── Row   标题行（[标签] 标题 2 行 … 可选收藏移除按钮）
├── Text  摘要 previewSnippet（可选，margin top 10）
├── ▶ 预览图区（新增，margin top 10）            ← 摘要之后、底栏之前
│     Stack(width 100%, height 120vp, 圆角 8)
│       ├── Image(thumbUrl) objectFit Cover  （或被动占位块）
│       └── Text('N 图')  右下角角标（仅多图时）
└── Row   底栏（作者 · 时间 · 版面 | 回复数，margin top 12）
```

尺寸常量（放在 `TopicListPanel.ets` 文件头常量区，附注释说明依据）：

```ts
/**
 * 主题卡片预览图区高度（vp）。
 *
 * 取 120：与卡片左右 padding 16 搭配后，常见 4:3 / 16:9 首帖图在 Cover 裁切下观感稳定；
 * 不解析 NGA 文件名的 `S{宽}-{高}` 尺寸段（官方 ft.s0.g 那套编码），避免为一屏最多 3~4 张
 * 缩略图引入一套解码逻辑——固定高度 + Cover 已满足"能看出是什么图"的预览目的。
 */
const PREVIEW_IMAGE_HEIGHT: number = 120
/** 预览图圆角（与 PostAttachments 附件图一致）。 */
const PREVIEW_IMAGE_RADIUS: number = 8
```

### 6.2 渲染判定（唯一入口，避免散落分支）

```ts
/**
 * 是否渲染预览图区。
 *
 * 三级判定（任一不满足即整块不渲染，不占高度）：
 *  1. 设置开关开启（showTopicPreview）
 *  2. 条目有可用预览图（previewImages 非空）
 *  3. 尚未加载失败（previewFailed === false）
 */
private shouldRenderPreview(): boolean {
  return this.showTopicPreview && this.previewImageUrls().length > 0 && !this.previewFailed
}
```

| `showTopicPreview` | `ImageLoadStrategy` | 条目有图 | 渲染结果 | 是否发图片请求 |
| --- | --- | --- | --- | --- |
| 关 | 任意 | 任意 | **不渲染**（无占位、无高度） | ❌ |
| 开 | `ALWAYS` | 有 | `Image(原图)` | ✅ 1 次（失败即隐藏，无二次请求） |
| 开 | `ALWAYS` | 无 | 不渲染 | ❌ |
| 开 | `MANUAL` | 有 | **被动占位块**（灰图图标 + `bgSecondary`） | ❌ |
| 开 | `WIFI_ONLY` + WiFi | 有 | `Image(原图)` | ✅ |
| 开 | `WIFI_ONLY` + 蜂窝 | 有 | **被动占位块** | ❌ |

### 6.3 被动占位态

与项目既有范式完全一致（`PostAttachments.renderImageAttach`，`PostAttachments.ets:104-125`）：

```ts
Row() {
  Image($r('app.media.icon_image'))
    .width(22).height(22)
    .fillColor(AppColors.textTertiary)
    .opacity(0.45)
}
.width('100%').height(PREVIEW_IMAGE_HEIGHT)
.justifyContent(FlexAlign.Center)
.borderRadius(PREVIEW_IMAGE_RADIUS)
.backgroundColor(AppColors.bgSecondary)
// 外层 Stack 统一承担 .margin({ top: 10 })，占位态与实图态因此同高同位
```

**必须用 `if / else if` 分支而不是 `Image(...).visibility(...)`**：离开渲染树的分支不会创建
图片节点，也就不会产生网络请求；用 `visibility` 隐藏仍可能触发加载（与「被动模式不主动请求
图片」的契约相悖）。

### 6.4 交互契约

| 手势 | 行为 | 说明 |
| --- | --- | --- |
| 点击预览图 | **进帖子**（与点击卡片其他区域一致） | 预览图**不注册 `onClick`**，事件由外层卡片 `onClick` 处理（`TopicCardComponent.build` 末尾） |
| 点击被动占位块 | 同上（进帖子） | 官方 App 的列表预览图也只是卡片的一部分，没有"点图看大图" |

> 若将来要做「点预览图打开 `openImageViewer`」：需在 `Image` 上注册 `onClick` 并确认 ArkUI
> 命中测试不会同时触发外层卡片的 `onClick`（默认只触发最内层注册了 `onClick` 的节点，但**必须
> 真机实测确认**）。本期不做，保持与官方一致且零歧义。

### 6.5 组件代码（`TopicCardComponent`）

```ts
@Component
struct TopicCardComponent {
  @Prop thread: Record<string, Object> = {}
  @Prop isFavorites: boolean = false
  @StorageProp('topicFontSize') topicFontSize: number = 15
  @StorageProp('blacklistVersion') blacklistVersion: number = 0
  /** 「显示帖子预览图」开关（设置页改动即时生效）。 */
  @StorageProp('showTopicPreview') showTopicPreview: boolean = false
  /** 图片加载模式（决定主动加载 / 被动占位）。 */
  @StorageProp('imageLoadStrategy') imageLoadStrategy: string = ImageLoadStrategy.ALWAYS
  /** 网络变更版本号：WiFi↔蜂窝切换后重判被动态（NetworkMonitor 已 bump）。 */
  @StorageProp('networkChangeVersion') networkChangeVersion: number = 0
  onRemoveFav: (tid: number) => void = (_tid: number) => {}
  onCardClick: (tid: string, pid: string) => void = (_tid: string, _pid: string) => {}
  /**
   * 预览图是否已加载失败（失败即整块隐藏，不再尝试其它质量档）。
   * 列表预览**统一用原图**（与 ImageViewer / ThreadPanel 一致，见 §5.3 / K22）。
   * 组件内状态：LazyForEach 按 tid 复用，条目不变时状态可保留；条目被回收重建时重置为 false。
   */
  @State private previewFailed: boolean = false

  /** 预览图 URL 列表（值拷贝防御：@Prop thread 为 Record，取数组需判型）。 */
  private previewImageUrls(): string[] {
    const value: Object | undefined = this.thread['previewImages']
    if (value === undefined || value === null || !Array.isArray(value)) {
      return []
    }
    return value as string[]
  }

  /** 首张预览图的**原图**绝对 URL（`shouldRenderPreview` 已保证有图）。 */
  private firstPreviewUrl(): string {
    const urls: string[] = this.previewImageUrls()
    return urls.length > 0 ? urls[0] : ''
  }

  /** 是否渲染预览图区（见 6.2 判定表）。 */
  private shouldRenderPreview(): boolean {
    return this.showTopicPreview && this.previewImageUrls().length > 0 && !this.previewFailed
  }

  /**
   * 原图加载失败 → 隐藏整块（**只有这一级**，没有更低质量的回退档）。
   * 置位幂等：同一次加载即使 `onError` 与 `onComplete` 都触发也只隐藏一次（K19）。
   */
  private onPreviewFailed(): void {
    this.previewFailed = true
  }

  /**
   * 判断解码结果是否为 NGA 的"失效图"占位（**精确 1×1**）。
   *
   * CDN 对不存在的附件返回 `404 + content-type: image/gif` 的 43 字节 1×1 GIF，`Image` 会把
   * 它当作加载成功（`onError` 不触发、`onComplete` 回填 1×1，见 `IMAGE_PIPELINE_AUDIT.md` §5.2）。
   * **不用 `≤1`**：`width/height` 为 0 表示尚未解码出尺寸，此时判失败会平白多一次原图回退。
   */
  private isBrokenPreview(width: number, height: number): boolean {
    return width === 1 && height === 1
  }

  @Builder
  previewArea() {
    if (this.shouldRenderPreview()) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (shouldUsePassive(this.imageLoadStrategy)) {
          // 被动模式：只占位不加载（分支隔离，不创建 Image 节点）
          Row() {
            Image($r('app.media.icon_image')).width(22).height(22)
              .fillColor(AppColors.textTertiary).opacity(0.45)
          }
          .width('100%').height(PREVIEW_IMAGE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(PREVIEW_IMAGE_RADIUS).backgroundColor(AppColors.bgSecondary)
        } else {
          // 实图：直接用原图（与 ImageViewer / ThreadPanel 同源同质量，见 §5.3 / K22）
          Image(this.firstPreviewUrl())
            .width('100%').height(PREVIEW_IMAGE_HEIGHT)
            .objectFit(ImageFit.Cover)
            .borderRadius(PREVIEW_IMAGE_RADIUS)
            .backgroundColor(AppColors.bgSecondary)
            .onComplete((event) => {
              if (event && this.isBrokenPreview(event.width, event.height)) {
                this.onPreviewFailed()
              }
            })
            .onError(() => { this.onPreviewFailed() })

          // 多图角标只在实图分支渲染：被动占位下不透露图片数量（见 m6）
          if (this.previewImageUrls().length > 1) {
            Text(`${this.previewImageUrls().length} 图`)
              .fontSize(11).fontColor(AppColors.white)
              .backgroundColor(AppColors.movingPhotoBadgeBg)
              .border({ width: 1, color: AppColors.movingPhotoBadgeBorder })
              .borderRadius(9)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ right: 6, bottom: 6 })
          }
        }
      }
      .width('100%')
      .margin({ top: 10 })
    }
  }

  build() {
    Column() {
      // ...标题行 / 摘要 不变
      this.previewArea()
      // ...底栏不变
    }
    // ...
  }
}
```

> **角标配色**：底色用 `AppColors.movingPhotoBadgeBg`（`#80000000`，50% 黑）+ 1px
> `movingPhotoBadgeBorder`——这是项目**图片角标**的既有配色（`BBCodeContentView.ets:840`、
> `MovingPhotoPlayer.ets:563` 同款）。
> **不要复用 `imageViewerButtonBg`**：它是 `#33FFFFFF`（20% 白，为全屏深色查看器按钮设计），
> 叠在浅色缩略图或米色占位块上时白字几乎不可读（Review m1）。

### 6.6 视觉一致性检查表

| 项 | 要求 |
| --- | --- |
| 圆角 | 8（与 `PostAttachments` 附件图一致） |
| 占位底色 | `AppColors.bgSecondary`（浅色/暗色自动适配，勿写死颜色） |
| 间距 | 与摘要间距一致：`margin({ top: 10 })` |
| 高度稳定 | 占位态与实图态**同高 120vp**，被动↔主动切换不产生跳动 |
| 无图 | 完全不渲染（不留空行、不留背景条） |
| 深色模式 | 仅使用 `AppColors` 语义色，无需单独 dark 分支 |
| 玻璃材质 | **不涉及**：预览图在列表内容层，不使用 `systemMaterial` / `GlassModifier`（详见 `docs/IMMERSIVE_LIGHT_DESIGN.md`：材质只用于浮层与系统控件） |
| 字体 | 预览区不引入新字号角色；多图角标用 11 |

---

## 7. 与「图片加载模式」的约束关系（本章为核心）

### 7.1 既有语义（回顾）

`common/constants/Constants.ets:216`：

| 值 | 标签（设置页） | 语义 |
| --- | --- | --- |
| `ImageLoadStrategy.ALWAYS` = `'0'` | 始终加载（主动式） | 直接请求图片 |
| `ImageLoadStrategy.MANUAL` = `'1'` | 手动加载（被动式） | 只显示占位，不主动请求 |
| `ImageLoadStrategy.WIFI_ONLY` = `'2'` | 只在WiFi下加载 | WiFi 下主动，蜂窝下被动 |

唯一判定入口（**不得自行判断网络**）：

```ts
// common/utils/NetworkUtil.ets:33
export function shouldUsePassive(strategy: string): boolean {
  if (strategy === ImageLoadStrategy.ALWAYS) return false
  if (strategy === ImageLoadStrategy.MANUAL) return true
  return !isWifiConnected()
}
```

现有消费方：`Avatar`、`BBCodeContentView`、`PostAttachments`、`MutedVideo`——**预览图是第五个
消费方，必须复用同一函数**，不得在列表里另写一套 `isWifiConnected` 判断。

### 7.2 两个开关的关系（判定顺序）

```text
① showTopicPreview === false        → 整块不渲染（不占位、不请求）
② previewImages 为空                → 整块不渲染
③ shouldUsePassive(strategy) === true → 渲染被动占位（不请求）
④ 否则                              → Image(缩略图)，失败回退原图，再失败隐藏
```

**「图片加载模式」是上位约束**：`MANUAL` 时即使开关打开也不会加载图片；`WIFI_ONLY` 在蜂窝下
与 `MANUAL` 表现一致。开关只决定"这块 UI 存不存在"，加载策略决定"存在时是否真的拉图"。

### 7.3 刷新链路（被动态↔主动态自动切换）

| 触发 | 机制 | 结果 |
| --- | --- | --- |
| 用户在设置页改「图片加载模式」 | `MediaSettings.setImageLoadStrategy` → `AppStorage.setOrCreate(KEY_IMAGE_LOAD_STRATEGY)` + `bumpAppStorageVersion(KEY_NETWORK_CHANGE_VERSION)` | 卡片 `@StorageProp('imageLoadStrategy')` / `('networkChangeVersion')` 变化 → 重建 → 重新判定 |
| WiFi↔蜂窝切换 | `common/managers/NetworkMonitor.ets` → `bumpAppStorageVersion(KEY_NETWORK_CHANGE_VERSION)` | 同上（`WIFI_ONLY` 下进入 WiFi 自动开始加载，离开 WiFi 自动回到占位） |
| 用户在设置页改「显示帖子预览图」 | `MediaSettings.setShowTopicPreview` → `AppStorage.setOrCreate(KEY_SHOW_TOPIC_PREVIEW)` | 卡片 `@StorageProp('showTopicPreview')` 变化 → 重建 |

**注意**：`setShowTopicPreview` **不需要**再 bump `networkChangeVersion`（那是网络语义的版本号），
`@StorageProp` 本身就会驱动刷新。

### 7.4 与「清除缓存」的关系

图片缓存由 ArkUI `Image` 组件统一管理（落在应用 cacheDir）。设置页「清除缓存」已递归删除
`context.cacheDir`（EL1/EL2）与动态照片缓存目录（`SettingsPanel.clearCache`），因此：

- 清缓存后预览图会重新下载，无需额外处理；
- 预览图**不引入**自己的磁盘缓存目录（不要为了列表缩略图新增一套缓存，避免与"清除缓存"契约脱节）。

### 7.5 备选方案 B（本期不做）：被动模式下「点击后加载」

若产品希望被动模式点一下就把图加载出来（而不是进帖子），必须：

1. 在卡片内加 `@State private previewExpanded: boolean = false`，被动态占位块 `onClick` 置 `true`；
2. 该 `onClick` 与卡片整体 `onClick`（进帖子）互斥——**必须先真机验证 ArkUI 的命中测试与冒泡
   行为**，确认不会"既加载又跳转"；
3. 该状态属于"用户临时意图"，**不要**持久化、不要进入 `LazyForEach` key。

收益有限而交互风险高（与"整卡进帖子"冲突），故本期采用 6.4 的契约。

---

## 8. 设置项接入（`SettingsPanel`）

### 8.1 持久化字段（`store/settings/SettingsState.ets`）

```ts
  /** 显示帖子预览图（主题列表卡片首帖缩略图；受图片加载模式约束）。 */
  showTopicPreview: boolean = false
```

**默认值建议 `false`**（保守）：

- 升级后已有用户的列表**视觉与流量不变**，符合"设置项由用户显式开启"；
- 若要跟随官方默认开启，改这一行为 `true` 即可（无迁移逻辑，旧数据缺字段时 `load()` 会跳过，
  保留默认值）。

### 8.2 域 store（`store/settings/domain/MediaSettings.ets`）

```ts
import { KEY_SHOW_TOPIC_PREVIEW, ... } from '../../../common/constants/AppStorageKeys'

  /** 设置是否显示帖子预览图（同步 AppStorage 供列表卡片响应式读取，并持久化）。 */
  setShowTopicPreview(enabled: boolean): void {
    this.ctx.state.showTopicPreview = enabled
    AppStorage.setOrCreate(KEY_SHOW_TOPIC_PREVIEW, enabled)
    this.ctx.persist()
  }

  /** 从持久化对象加载媒体字段（在现有 load 内追加） */
  load(saved: SettingsState): void {
    // ...现有字段
    if (saved.showTopicPreview !== undefined) {
      this.ctx.state.showTopicPreview = saved.showTopicPreview
    }
  }
```

### 8.3 门面与 AppStorage 初始化（`store/SettingsStore.ets`）

```ts
  // 设置域 setter 区
  /** 设置是否显示帖子预览图 */
  setShowTopicPreview(enabled: boolean): void { this.mediaSettings.setShowTopicPreview(enabled) }

  // loadUserSettings() 末尾的 AppStorage 同步块（与 showSignature 等并列）
  AppStorage.setOrCreate(KEY_SHOW_TOPIC_PREVIEW, this.state.showTopicPreview)
```

> `SettingsStore.reset()` 会把 `state` 换成新的 `SettingsState()`（默认 `false`），无需额外处理；
> 但**必须**确认 reset 后 AppStorage 与新内存真源一致——沿用现有做法（登出/切号后由
> `loadUserSettings` 重新写入；未登录不发生列表渲染）。

### 8.4 AppStorage key（`common/constants/AppStorageKeys.ets`）

```ts
/** 显示帖子预览图（主题列表卡片首帖缩略图） */
export const KEY_SHOW_TOPIC_PREVIEW: string = 'showTopicPreview'
```

> 文件头已声明：`@StorageProp` 装饰器参数必须写字面量，key 常量与 `@StorageProp('showTopicPreview')`
> 是**手工对齐**关系，改名时两处一起搜。

### 8.5 设置页行（`pages/SettingsPanel.ets`）

位置：**Block 3A 内、「图片加载模式」行的正下方**（语义相邻：开关决定"显示不显示"，模式决定
"怎么加载"）。

```ts
              SettingPickerRow({
                iconRes: $r('app.media.settings_image_loading'), ... label: '图片加载模式',
                onAction: () => { this.showImageStrategyPicker() }
              })

              Divider().margin({ left: 60 }).color(AppColors.separator)

              // 新增：显示帖子预览图（受上方「图片加载模式」约束）
              SettingToggleRow({
                iconRes: $r('app.media.settings_topic_preview'),
                iconColor: SettingsIconColors.topicPreview,
                label: '显示帖子预览图',
                isOn: appStore.settings.showTopicPreview,
                onChange: (v: boolean) => {
                  appStore.settingsStore.setShowTopicPreview(v)
                }
              })
```

**不要**给该行加副标题：`SettingToggleRow` 的契约是"固定 44 高、无副标题"
（`common/components/SettingRow.ets:72` 明确写了带副标题的行不在覆盖范围内）。需要补充说明时，
用 Toast（如 `appStore.showToast('预览图仍受「图片加载模式」约束')`）而非改行高。

### 8.6 图标与配色

新增 `entry/src/main/resources/base/media/settings_topic_preview.svg`（与现有图标同规格：
24×24 viewBox、`fill="#000000"`，由代码 `fillColor(AppColors.white)` 着色）：

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
  <path d="M4 4H20C21.1 4 22 4.9 22 6V18C22 19.1 21.1 20 20 20H4C2.9 20 2 19.1 2 18V6C2 4.9 2.9 4 4 4ZM4 6V15.6L8.5 11L12 15L14.5 12.2L19.5 18H20V6H4ZM8 8C9.1 8 10 8.9 10 10C10 11.1 9.1 12 8 12C6.9 12 6 11.1 6 10C6 8.9 6.9 8 8 8Z" fill="#000000" fill-rule="evenodd" clip-rule="evenodd"/>
</svg>
```

`Constants.ets` 的 `SettingsIconColors` 追加：

```ts
  /** 显示帖子预览图的玫瑰红。 */
  static readonly topicPreview: string = '#E11D48'
```

### 8.7 数据迁移

`settings_${uid}` 是整对象 JSON（`store.putJSON(this.settingsKey(), this.state)`）。新增字段对旧数据
的影响：`load()` 里 `saved.showTopicPreview === undefined` → 跳过 → 保留类默认值，**天然兼容**，
无需版本号迁移。

---

## 9. ArkTS 与响应式契约

### 9.1 卡片必须订阅的 AppStorage 键

| 键 | 装饰器 | 作用 |
| --- | --- | --- |
| `showTopicPreview` | `@StorageProp` | 开关即时生效 |
| `imageLoadStrategy` | `@StorageProp` | 主动/被动判定 |
| `networkChangeVersion` | `@StorageProp` | WiFi↔蜂窝/策略变更后重判 |

三者都是"值类型 + 会变"，用 `@StorageProp`（单向）即可；**不要**用 `@StorageLink`（卡片不需要写回）。

### 9.2 `LazyForEach` key 不变

预览图 URL 在**解析期**确定（`previewImages` 随 `thread` 一起进数据源），异步只发生在 `Image`
组件内部，不会改变 data source 内容 → `TopicListPanel` 现有 key（`tid`）**保持不动**。

> 反向提醒：绝不要把"图片是否已加载"塞进 `LazyForEach` 的 key 或 data source（会引发整表重建，
> 见 `arkui-refresh` skill 的键值契约）。

### 9.3 ArkTS 硬约束对照

| 约束 | 本设计的遵守方式 |
| --- | --- |
| 无 `any` / `unknown` | 一律 `Object` + 类型守卫（`Array.isArray` / `typeof === 'object'`） |
| 不允许索引签名 | 原始响应统一走 `Record<string, Object>`（项目既有惯例，`Record<K,V>` 索引表达式合法） |
| 对象字面量需可推断类型 | 新增字段均落在已声明接口上（`TopicListInfo` / `ThreadPageInfo`） |
| 无 `in` 运算符 | 用 `!== undefined` / 长度判断 |
| 无解构 | 逐字段赋值 |
| `@Builder` 按值传参不响应 | 预览区 `@Builder` 内部全部读 `this.*`（`showTopicPreview` / `imageLoadStrategy` / `this.thread`） |
| 组件回调用属性而非 `@Prop` | 无新增回调；如需回调按 `onRemoveFav` 的箭头属性写法 |
| `catch` 省略类型标注 | 预览图无 try/catch；失败走 `Image` 的 `onComplete`（尺寸补判）/ `onError` 回调 |
| 类型守卫后仍需显式转换 | `value as string[]`（先 `Array.isArray` 收窄） |

### 9.4 副作用纪律

- 卡片**不发网络请求**（预览图由 `Image` 组件按 URL 自行加载；解析期不预取）。
- 预览图的失败回调（`onPreviewFailed`）只改本地 `@State`，不写 Store、不弹 Toast（列表内静默降级）。
- 解析层保持**纯函数**（可被 Hypium 直接覆盖）。

---

## 10. 性能与流量预算

| 指标 | 估算 |
| --- | --- |
| 单页主题数 | 35~54（实测 fid=7 首页 54 条、3 页共 123 条 ≈41/页；合集 35 左右） |
| 带图条目占比 | ≈29%（fid=7）/ ≈3%（合集） |
| 单张预览图（**原图**） | 实测 jpg 75 KB / jpeg 292 KB / webp 80 KB / png 108 KB / gif 903 KB / mp4 1.1 MB |
| 单页新增流量 | ≈29% × 41 条 ≈ 12 张 × 平均 ≈150 KB ≈ **1~2 MB 量级**（首屏；滚动按 `cachedCount(3)` 视口加载） |
| 与查看器 | 同一 URL：点开查看器不再重新下载（`Image` 缓存内命中） |
| 被动模式 | 0（只占位、不创建 `Image` 节点） |

其他：

- `Image` 默认异步加载（无需 `syncLoad`）；`LazyForEach` 复用 + `cachedCount(3)` 已由现有列表配置。
- **没有回退档**：原图加载失败（含 404 的 43 B 1×1 GIF）即隐藏整块，最多 1 次请求。
- 原图在列表内的**解码内存与滚动帧率需真机观察**（见 K22）；若要降级到缩略档，切档方式见 K22。

---

## 11. 门禁与验证

### 11.1 前置自查（已执行）

```bash
node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry
# → [dry-run] 修改 0 个文件；新增 0 个文件；无变化跳过 34 个文件
```

本次改动不触碰镜像文件，故**无需** `npm test` / `npm run sync`（除非决定改 `AttachUrl.ts`）。

### 11.2 编译与单测

| 门禁 | 走哪里 |
| --- | --- |
| DevEco 编译（ArkTS 子集最终判定） | `harmonyos-build-deploy` skill |
| Hypium Local Test（解析纯函数） | `harmonyos-test` skill（`entry/src/test/AppTopicListUnit.test.ets`） |
| 行尾自检 | `node scripts/check-eol.mjs` |

### 11.3 真机/模拟器功能验证清单

- [ ] 设置页出现「显示帖子预览图」行，位于「图片加载模式」正下方，开关可切换并重启后保持
- [ ] 开关关闭：普通版面列表**无**预览区、无额外网络请求（DevTools/日志确认无 `img.nga.cn` 请求）
- [ ] 开关开启 + 始终加载：带附件主题显示缩略图（`.thumb.jpg`），无附件主题不留空白
- [ ] 开关开启 + 手动加载：显示被动占位块（灰图标 + 灰底），高度与其他卡片一致，**无图片请求**
- [ ] 开关开启 + 只在WiFi下加载：WiFi 显示实图；切蜂窝后（或已在蜂窝）自动回到占位
- [ ] 网络从蜂窝切回 WiFi：占位自动变为实图（不滚动、不重进页面）
- [ ] 热门榜（`subject/hot`）同样显示预览图（验证顶层 `attachPrefix` 透传）
- [ ] 置顶模式 / 搜索列表 / 收藏夹 / 用户主页：**无**预览区、无崩溃、无空白（数据本就没有）
- [ ] 原图不存在的帖子（可临时拼一个不存在的附件路径造 404）：该卡片预览区消失、高度正常回收，
      **且不出现被 Cover 拉满的白块**（K16/K20 的 1×1 判定生效）
- [ ] DevTools 网络面板核对：预览图请求的就是**原图**（无 `.thumb.jpg` 后缀），且与点开查看器是同一 URL（缓存命中）
- [ ] 长列表快速滚动时的帧率与内存（原图档，见 K22）—— 真机观察
- [ ] 暗色主题下占位底色与图片圆角观感正常；切换主题不残留
- [ ] 多图条目右下角显示「N 图」角标，位置不压住图片主体内容
- [ ] 快速滚动长列表无卡顿、无图片错位（LazyForEach 复用）
- [ ] 清除缓存后回到列表，预览图重新加载且不报错

---

## 12. 坑点清单（实施时逐条对照）

| 编号 | 坑 | 规避 |
| --- | --- | --- |
| K1 | `attachs` 是**对象数组**，旧代码 `String(raw['attachs'] ?? '')` 会得到 `"[object Object]"` | 先改类型与解析，再谈 UI（第 4 章） |
| K2 | `attachPrefix` 位置不固定：`subject/list` 在 `result`，`subject/hot` 在**响应顶层** | 两处都读，统一塞进 `fakeRaw['attachPrefix']` |
| K3 | 缩略图拼接是**整串末尾**：`xxx.jpeg.thumb.jpg` | 「去扩展名 + `.thumb.jpg`」实测 404 |
| K4 | `attachs` 里混有非图片（实测 108 个里有 1 个 mp4） | 扩展名白名单过滤（对齐官方 `parseUrlSubject`） |
| K5 | 只有 `subject/list` / `subject/hot` 有数据 | 置顶/搜索/收藏/用户列表**不要**指望有图；UI 无图即不渲染 |
| K6 | 被动↔主动切换高度跳变 | 占位块与实图**同高**（`PREVIEW_IMAGE_HEIGHT`） |
| K7 | 顺手复用 `applyImageSuffix`（`Utils.ets`）做缩略图 | **实测 404**：它输出 `name.size.ext`，而 NGA 是 `name.ext.size.jpg`（见 §5.6）；必须"strip 后整串追加 `.thumb.jpg`" |
| K7b | 只写裸后缀 `…jpeg.thumb` / `…jpeg.medium` | **实测 404**（`text/html` 146 B）；**必须带 `.jpg`** —— 这正是既有审计文档 §5.1 旧结论的根因（见 §5.4） |
| K7c | 不 strip 就直接追加 | 输入带档位段时会拼出 `…jpeg.medium.jpg.thumb.jpg`；实测**返回 medium 档而非缩略图**（叠加不会更小）。正确顺序：strip → 追加 |
| K8 | 用 `visibility` 隐藏图片导致被动模式仍发请求 | 用 `if / else` 分支隔离（对齐 `PostAttachments`） |
| K9 | 在卡片里自己判断网络 | 唯一入口 `shouldUsePassive`（`NetworkUtil`） |
| K10 | `@Builder` 按值接收 `showTopicPreview`/URL → 不刷新 | Builder 内一律 `this.*` |
| K11 | 换域（`img.nga.178.com` → `img.nga.cn`）时硬编码域失效 | 优先用响应 `attachPrefix`；兜底用 `NgaDomains.NGA_IMG_BASE`（`NGA_CDN_BASE`） |
| K12 | 把「显示帖子预览图」行塞进「清除缓存/导出凭证」块 | 放在 Block 3A「图片加载模式」下方（语义相邻） |
| K13 | 与官方 `style==1 → 原图` 行为不一致 | **有意差异**：统一缩略图省流量；如需对齐，仅当 `style===1` 时用原图（本项目 `ThreadPageInfo` 目前未保留 `style`，需一并透传） |
| K14 | 开关状态写入后设置页行不刷新 | 沿用现有写法 `isOn: appStore.settings.showTopicPreview`（Toggle 自身状态已变）；跨面板刷新由 `@StorageProp` 承担 |
| K15 | 忘记在 `loadUserSettings` 写 AppStorage → 冷启动后卡片读不到开关 | 与 `KEY_SHOW_SIGNATURE` 等并列 `AppStorage.setOrCreate` |
| K16 | **缩略图 404 时 `Image.onError` 不触发** | CDN 对不存在路径返回 `404 + content-type: image/gif + 43 B 1×1 图`，`Image` 视为**加载成功**（`IMAGE_PIPELINE_AUDIT.md` §5.2）。回退链不能只靠 `onError`，必须同时在 `onComplete` 里用 `width/height ≤ 1` 判失败（见 §6.5），否则会显示一块被 `Cover` 拉满的空白 |
| K17 | 用 `.medium.jpg` 当"大图"档 | 对 png / gif 源会**回退原图**（字节数与 content-type 同原图），并不省流量；查看器一律给原图，`.medium.jpg` 只在明确知道源是 jpeg/webp 时可选 |
| K18 | 把 `type` 位13 当作"一定有预览图" | 部分板块（-7 网事杂谈、843 国际新闻）**整站不下发 `attachs`**，位13 却照常置位（见 §1.1）。预览图是否存在**只看 `previewImages` 是否非空**；位13 最多用于"该帖有附件但本板块不给"的提示，且**不得**据此自动拉取 `read.php` 补图 |
| K19 | 失败信号重复触发被当成两次失败 | 同一次加载可能 `onError` 与 `onComplete`(1×1) **都**触发（K16）。失败处理必须**幂等**——本实现只置 `previewFailed = true`，多触发一次也只是再隐藏一次，不产生错误状态或重复请求。**注**：早期草案是"`stage` 0→1→2 两级回退（缩略图→原图）"，那种写法下双信号会**连跳两级**直接隐藏；列表改用原图后已无此风险，但该教训在将来切回多档时仍然成立 |
| K20 | 用 `≤1` 判"失效占位图" | `onComplete` 的 `width/height` 为 **0 表示尚未解码出尺寸**，`≤1` 会把它误判为失效 → **平白隐藏一张合法图**。用**精确 `=== 1 && === 1`** 匹配 43 字节 1×1 GIF（K16） |
| K21 | 以为 `stripImageSuffix` 能归一所有档位 | 镜像 `Utils.stripImageSuffix` 只认 `.thumb_s` / `.thumb_m` / `.medium` / `.thumb` **四种**，**不含 `.thumb_ss`**（CDN 实测存在该档位）：`a.jpeg.thumb_ss.jpg` 会被拼成 `a.jpeg.thumb_ss.jpg.thumb.jpg`。现网 `attachs` 是裸名（实测），不触发；即便拼出的 URL 取不到，也会回退到原 URL（仍显示那张小图），故**不改镜像**（改它要走 bbcode-ts 门禁且会分叉正文语义）。同理主名内嵌扩展名（`xxx.png.jpeg`）会被 strip 成 `xxx`，同样靠回退链兜底 |
| K22 | 以为列表预览"必须"用缩略档省流量 | **本功能明确选择原图**（与 `ImageViewer` / `ThreadPanel` 的图片链路一致，需求方已确认）：列表与查看器同源，点开无二次下载。**代价**：一屏多张原图会显著抬高解码内存与首屏流量（实测 jpg 75 KB / jpeg 292 KB / png 108 KB / gif 903 KB / mp4 1.1 MB；且官方解码内存优化里 `.gif`/`.webp` **不做** `sourceSize` 降采样），长列表滚动性能需真机观察。**若要切回缩略档**：在 `TopicPreviewUtils` 里按 §5.2 规则实现档位 URL（`stripImageSuffix(url) + '.thumb.jpg'`，约 3 行；注意镜像的 strip 不认 `.thumb_ss`，见 K21），把 `TopicCardComponent.previewArea` 里的 `this.firstPreviewUrl()` 换成它，并恢复"缩略图失败→原图"两级回退（多档时失败回调必须**按分支归属**，见 K19）。**当前刻意不保留该函数与其单测**：无调用方即死代码 |

---

## 13. 实施顺序（建议提交粒度）

1. **解析层**（可独立验收，零 UI 风险）：`Topic.ets` → `TopicPreviewUtils.ets` → `TopicParser.ets`
   → `AppSubjectListParser.ets` → 补 `AppTopicListUnit.test.ets`，跑 Hypium。
2. **UI 层**（先硬编码开关为开，验证渲染与回退链）：`TopicCardComponent` 预览区 + 常量。
3. **设置项**：`AppStorageKeys` → `SettingsState` → `MediaSettings` → `SettingsStore` →
   `SettingsPanel` 行 + 图标/配色。
4. **联调**：按 11.3 清单逐项验证（重点：三种加载模式 + 网络切换 + 无图入口）。

**回滚**：删除第 3 步（设置项）后把 `TopicCardComponent` 的 `showTopicPreview` 默认值置 `false`
即可整体下线；解析层产出（`previewImages`）保留亦无害（仅多几个字段）。

---

## 14. 附录：实测复现方式

探针脚本（临时目录，不入库）使用 `nga-hack/nga-client` 的 `NgaClient`（App 签名 + 网页 cookie）：

```js
const client = new NgaClient({ cookie, accessUid: uid, accessToken: cid })
// ① 普通版面列表
await client.appPost('app_api.php', 'subject', 'list', { fid: '7', page: '1' }, { signParams: '7', output: 12 })
// ② 热门榜（attachPrefix 在顶层）
await client.appPost('app_api.php', 'subject', 'hot', { fid: '7', days: '1', _page: '1' }, { signParams: '71', output: 12 })
```

固定结论（2026-09 实测）：

```text
【列表数据】
fid=7   subject/list 3 页 123 条 → 36 条带 attachs（29.3%），80 张图，type 位13 37 条
fid=-547859 subject/list 3 页 107 条 → 3 条带 attachs（2.8%）
subject/hot days=1 35 条 → 12 条带 attachs
subject/topped（fid=7 / -547859）→ 0 条带 attachs，无 attachPrefix
subject/search（战报/图/原创 三组 101 条）→ 0 条带 attachs（type 位13 44 条）
favor/all 9 条、user/subjects 2 条、user/replys 20 条 → 0 条带 attachs
108 个附件元素：键组合只有 attachurl；jpg 100 / webp 5 / jpeg 1 / gif 1 / mp4 1
语义：tid=47344551 列表 attachs[0] 与首楼 pid=0 的 [img] 路径一致 → 列表 attachs = 首帖附件

【质量档位矩阵（探针 9/10/11，6 源扩展 × 后缀）】
  name.ext              → 原图（jpeg 292164 / jpg 75107 / png 108379 / gif 903229 / webp 79962 / gif.mp4 1125519）
  name.ext.thumb.jpg    → 14900 / 10644 / 5114 / 13915 / 15589 / 18966      ✅
  name.ext.thumb_s.jpg  →  3965 /  3357 / 1911 /  4410 /  3990 /  4203      ✅
  name.ext.thumb_ss.jpg →  1528 /  1461 / 1092 /  1547 /  1503 /  1563      ✅
  name.ext.medium.jpg   → 42856 / 29564 / ⚠️原图108379 / ⚠️原图903229 / 45447 / 62717
  name.ext.thumb_m.jpg  → 404（全源）        name.ext.thumb（裸后缀）       → 404（text/html 146B）
  name.thumb.ext         → 404（全源，= Utils.applyImageSuffix 输出）
  叠加 name.ext.medium.jpg.thumb.jpg → 返回 medium 档（不是缩略图）
  老附件（2020 png）同样有 .thumb.jpg（108379 → 5114）→ 非近期上线
  img.nga.178.com 已不可达（fetch failed）；img4.nga.cn 非附件域（404）

【stripImageSuffix 语义（项目 doStripSuffix 逐字复刻）】
  裸名 / .medium.jpg 追加式 / .thumb.jpg 追加式 / .thumb_s.jpg 追加式 / .thumb.ext 插入式
    → 全部还原为裸名 ✅
  .medium.jpg.thumb.jpg 叠加式 → 只还原一层（→ .medium.jpg）

【正文 [img] 命名分布（tools/bbcode-ts/samples/*.json，41 个 [img]）】
  裸名 name.ext 32 / 绝对 URL（多为旧域 png）9 / 含档位段 0
```

复现探针（临时目录，不入库）：`probe-quality-matrix.mjs`（档位矩阵 + doStripSuffix 语义）、
`probe-suffix-string.mjs`（裸后缀 vs 带 `.jpg` 后缀对照）、`probe-old-attach.mjs`（老附件/png/旧域）、
`probe-img-forms.mjs`（样本 `[img]` 命名分布）。
