# 图片长按识图（AI 图像分析 / OCR 选字）完整方案

> **调研对象**：鸿蒙官方「长按图片 → 识别成文本 → 可选取 / 可复制」能力，即 ArkUI
> **AI 图像分析（`Image.enableAnalyzer`）+ Vision Kit AI 识图**。
> **唯一权威依据**：本地 DevEco SDK 声明文件（逐条给「文件:行号」+ 签名原文）。
> 官方文档镜像（API 23）仅用于补充行为描述与约束，与本地声明冲突时以本地声明为准。
> **结论**：本工程只需一个属性方法 `.enableAnalyzer(boolean)`，无需新增权限、无需新增依赖。
>
> 工程：NGA 论坛鸿蒙客户端 `C:\Users\ll\Desktop\nga_oh`，stage 模型，
> `build-profile.json5` `targetSdkVersion / compatibleSdkVersion = 26.0.0`、`runtimeOS = HarmonyOS`。

---

## 0. SDK 版本锚点与检索基线

**SDK 根**：`C:\Program Files\Huawei\DevEco Studio\sdk\default`（下称 `<SDK>`）

`<SDK>\sdk-pkg.json`（原文节选）：

```json
{
  "apiVersion": "26",
  "displayName": "HarmonyOS 26.0.0",
  "path": "HarmonyOS-26.0.0",
  "platformVersion": "26.0.0",
  "releaseType": "Release",
  "stage": "Release",
  "version": "26.0.0.105"
}
```

→ 本地 SDK = **API 26 / HarmonyOS 26.0.0 Release（26.0.0.105）**。下文所有 `@since ≤ 26` 的接口
在本工程**均处于可用版本区间**；`enableAnalyzer` 起始 API 11，比工程最低要求低 15 个版本，
**不存在可用性缺口**。

**全量检索结果**（`grep -i enableAnalyzer`，覆盖 `<SDK>\openharmony\ets\component` 全部
`.d.ts` 与 `component_config.json`）：真正声明该属性的组件只有 **4 个** ——
`Image` / `Video` / `XComponent` / `Canvas`；**`Web` 没有**（ArkWeb 走另一条 API
`enableImageAnalyzer`，API 23 起，本工程不用）。本方案只涉及 `Image`。

---

## 1. 核心 API 契约（本地 SDK 原文）

### 1.1 属性方法

`<SDK>\openharmony\ets\component\image.d.ts:1626`（文档注释 1578–1625）：

```ts
/**
 * Sets whether to enable the AI image analyzer, which supports subject recognition, text recognition,
 * and object lookup.
 * ...
 * @param { boolean} enable - Whether the **Image** component supports AI analysis.<br>When this parameter is set to
 *     **true**, the **Image** component supports AI analysis. When this parameter is set to **false**, the **Image**
 *     component does not support AI analysis.<br>Default value: **false**
 * @returns { ImageAttribute }
 * @syscap SystemCapability.ArkUI.ArkUI.Full
 * @stagemodelonly
 * @atomicservice [since 12]
 * @since 11
 */
enableAnalyzer(enable: boolean): ImageAttribute;
```

| 项 | 值 |
| --- | --- |
| 起始版本 | **API 11**（`attributeModifier` 中可调用：API 12 起） |
| 默认值 | **`false`** —— 不写就是关闭 |
| 系统能力 | `SystemCapability.ArkUI.ArkUI.Full`（无需 syscap 判断，非可选能力包） |
| 权限 | **`ohos.permission.INTERNET`**（`image.d.ts:1611-1613` 原文 "The **ohos.permission.INTERNET** permission is required."）。工程 `entry/src/main/module.json5:17` **已声明**，无需改动 |
| 依赖库 | **无**。`ImageAnalyzerType` / `ImageAIOptions` / `ImageAnalyzerController` 都是 ArkUI 全局声明（`image_common.d.ts`），**不 import 任何模块** |
| 废弃状态 | 无（`grep '@deprecated|@useinstead'` 整份 `image.d.ts` **零命中**） |
| 组件校验 | `component_config.json` 的 `"Image"` 条目 `attrs` 列表**含 `"enableAnalyzer"`** → DevEco/hvigor 的属性校验会放行 |

### 1.2 行为：长按触发，默认开「文字识别 + 主体识别」

`<SDK>\openharmony\ets\component\image_common.d.ts:19-28`（`ImageAnalyzerType`，@since 12）：

```ts
/**
 * Defines the AI image analysis type. If it is not set, subject recognition and text recognition are enabled by
 * default.
 */
declare enum ImageAnalyzerType {
    SUBJECT = 0,        // 主体识别
    TEXT,               // 文字识别
    OBJECT_LOOKUP       // 对象查找
}
```

→ **只写 `.enableAnalyzer(true)`、不传 `ImageAIOptions` 时，系统默认开启「主体识别 + 文字识别」**，
即长按既有**选字 / 复制**，也有**抠图**。

> ⚠️ **本工程不使用这个默认形态**（§4 决策 10）：类型经构造参数显式收窄为**只做文字识别**
> （`ImageAnalyzerType.TEXT`），长按非文字区不再有任何识别 UI。下面 §1.3 的定制入口因此**已被用到**
> （只用到 `types`，不绑定 `aiController`）；本节其余关于抠图 / 识图搜索的描述保留为平台能力记录。

用户可见交互（官方指南 `guides/AI/Vision Kit（场景化视觉服务）/AI识图/AI识图.md` 原文）：

> 识别文字。**用户长按文本选取文字**或持续长按文本中的电话号码、邮箱、网址、地址、时间等实体，
> 可触发对应实体的快捷操作，如持续长按文本中的时间，可触发"新建日程"快捷操作入口。

> 主体分割。**用户长按主体分割**，分割后用户可以完成复制，分享，全选，识图搜索等功能。

最佳实践 `best/行业场景解决方案/社交通讯/AI辅助图文内容编创/AI辅助图文内容编创.md` 说得最直白：

> **长按图片可识别文字并实现物体抠图**
> 图片可 OCR 文字识别时，**点击图片内出现的识别按钮或长按文字，会出现复制文本菜单和文字框选区域**。

> ⚠️ **"长按"这件事不在 `Image` 的 API 参考页里**：`Image.md` 全文只有 `copyOption` 与 `draggable`
> 两处出现「长按」。**长按是这套能力的入口语义，由系统在 `enableAnalyzer(true)` 之后自行接管**，
> 开发者侧没有 `onLongPress` 之类的回调，也**没有** `Image` 的 `startImageAnalyzer` / `stopImageAnalyzer`
> （那两个只存在于 `XComponentController` 与 `CanvasRenderingContext2D`）。

### 1.3 定制入口（本工程**未使用**，仅备查）

`image_common.d.ts:95-143`：

```ts
declare interface ImageAnalyzerConfig { types: ImageAnalyzerType[]; }        // @since 12，必填

declare interface ImageAIOptions {                                            // @since 12
    types?: ImageAnalyzerType[];              // 分析类型（优先级高于 ImageAnalyzerConfig.types）
    aiController?: ImageAnalyzerController;   // 绑定控制器以定制交互
}

declare class ImageAnalyzerController {                                       // @since 12
    constructor();
    getImageAnalyzerSupportTypes(): ImageAnalyzerType[];   // 设备能力探测
}
```

对应构造重载 `image.d.ts:559`（@since 12）：

```ts
(src: PixelMap | ResourceStr | DrawableDescriptor, imageAIOptions: ImageAIOptions): ImageAttribute;
```

> 注意该重载**不接受 `ImageContent`**；本工程 `Image(src)` 走的是 `(src)` 单参重载，
> 与 AI 选项无关，因此**不需要改构造调用**。

---

## 2. 平台约束（决定"哪些图能识别、哪些不能"）

### 2.1 环境约束（**最重要，直接决定验收方式**）

| 约束 | 原文出处 | 对本工程的含义 |
| --- | --- | --- |
| **"本 kit 暂不支持模拟器"** | `guides/AI/Vision Kit（场景化视觉服务）/Vision Kit简介` | **本特性无法在模拟器验证**，必须真机。模拟器上表现为长按无任何反应（静默失效，不报错） |
| 支持设备：Phone / Tablet / PC-2in1 | 同上 | 覆盖本工程目标设备 |
| "仅适用于中国境内（香港特别行政区、澳门特别行政区、中国台湾除外）" | 同上 | 出海/境外设备上该能力可能不可用 |
| "该特性依赖设备能力" | `image.d.ts:1585` | 老设备/低端设备可能不支持；**官方无降级路径**（见 §2.4） |

### 2.2 图像约束

| 约束 | 原文 | 对本工程的影响 |
| --- | --- | --- |
| 静态非矢量图；**svg、gif 不支持分析** | `image.d.ts:1587`、`AI识图.md` §约束与限制 | NGA 正文里的 **GIF 动图长按无识别**，这是系统行为，不是 bug |
| PixelMap 仅支持 **RGBA_8888** | 同上 | 本工程进 `Image` 的都是 URL，不涉及 |
| **最小 100×100 分辨率** | `AI识图.md` §约束与限制 | 过小的缩略图/头像不触发识别（系统自动跳过） |
| **支持文本识别的宽高比：高 < 宽 × 7** | 同上 | **长截图（高 > 宽×7）不参与文字识别**，这是硬限制 |
| 支持语种：简体中文、繁体中文、英文、维吾尔文、藏文 | 同上 | 覆盖 NGA 主体内容 |
| `alt` 占位图不分析 | `image.d.ts:1595` | 本工程正文图未用 `alt` |
| `objectRepeat` 仅 `ImageRepeat.NoRepeat` 支持 | `image.d.ts:1596` | 本工程未设 `objectRepeat`（默认即 NoRepeat） |
| 隐私遮罩 `obscured` 打开时不支持 | `image.d.ts:1597` | 本工程未用 |
| `AnimatedDrawableDescriptor` 参数类型下不生效 | `image.d.ts:1608` | **动态照片的封面走 `MovingPhotoView`，与 `Image` 分析互不相干**（见 §3.3） |
| **不能与 `overlay` 属性同时使用**（同时设置时 `overlay` 的 `CustomBuilder` 失效） | `image.d.ts:1582-1585` | ✅ 本工程三处目标 `Image` **均未使用 `overlay`**，无冲突 |

### 2.3 与几何/变换属性**不冲突**（这是本方案能成立的关键）

`image.d.ts:1600-1606` 原文：

> Analysis is performed based on the **complete original image**. Even if the settings of the
> `clip`, `margin`, `borderRadius`, `position`, and `objectFit` attributes cause incomplete image display,
> or if a mask layer is set via `renderMode`, analysis will still be conducted on the complete original image.
> The `copyOption` attribute does not affect the AI image analyzer functionality.

→ **`objectFit(Contain)` / `borderRadius` / `clip(true)` / `.scale()` / `.translate()` 都不会影响识别**，
识别的始终是原图。这条直接消掉了两个本来最担心的点：

- `ImageViewer` 的图片被 `.scale()`/`.translate()` 缩放平移、又被父层 `clip(true)` 裁剪 —— **不影响识别**；
- 正文图用 `ImageFit.Contain` 且外层 `aspectRatio` 约束 —— **不影响识别**。

### 2.4 设备不支持时的行为（**不做降级**）

官方给了能力探测（`ImageAnalyzerController.getImageAnalyzerSupportTypes()` 返回空数组即不支持，
错误码 `110001 AI图像分析功能不支持`），但**本工程不做设备降级**：

- 与本工程对材质的一贯取向一致（`docs/IMMERSIVE_LIGHT_DESIGN.md`：*"材质不做设备降级：设备不支持
  材质时按钮背板就是透明的，这是接受的结果"*）；
- 探测需要引入 `@kit.VisionKit` 的 `VisionImageAnalyzerController`（`SystemCapability.AI.VisionImageAnalyzer`
  ，"调用接口需捕获异常"），为一行属性换来一个可选能力包的耦合与 try/catch，收益不成立；
- 不支持的设备上该属性**静默失效**（长按无反应），不会报错、不会崩溃、不影响点击与手势。

---

## 3. 本工程落点分析

### 3.1 三处目标与结论

| 面 | 文件:行 | 现状 | 结论 |
| --- | --- | --- | --- |
| **帖子正文图**（ThreadPanel 链路） | `common/components/BBCodeContentView.ets:811`（主动式实图）+ `:770`（被动式占位图标） | 未设 `enableAnalyzer`（= false） | **开启** |
| **图片查看器** | `common/components/ImageViewer.ets:580`（前一张）、`:615`（当前页）、`:633`（后一张） | 同上 | **开启** |
| **主题列表预览图** | `pages/TopicListPanel.ets:2024` | 同上 | **显式关闭**（默认即 false，写出来固化意图） |

`ThreadPanel` 的正文图**不在 `ThreadPanel.ets` 里**：帖子内容由 `PostItem` → `BBCodeContentView`
渲染（`ThreadPanel.ets:2183` 构造 `PostItem`），图片节点在 `BBCodeContentView.RenderImageContent`。
因此在 `ThreadPanel.ets` 里改不到图，**真正的落点是 `BBCodeContentView`**。它同时服务帖子页与
其它正文场景（回复编辑器预览等），语义一致，无需加开关区分。

### 3.2 与既有手势的共存（**本方案最大的不确定项，已消解**）

`ImageViewer` 把 `PinchGesture`（双指缩放）/ `TapGesture({count:2})`（双击缩放）/
`PanGesture`（左右滑动切图）绑在**图片外的 `Stack` 容器**上，而分析的触点是**单指长按**：

- 长按与「双指捏合」「双击」的手指形态互斥，**不构成同类竞争**；
- `PanGesture` 的 `distance: 15` 需要位移才激活，**静止长按不激活**；
- 长按与**单击**（打开查看器）也不是同一条判定路径：长按归分析器、单击归 `onClick`。

工程早已在全部正文图与查看器图写了 `.draggable(false)`，这一行对识图是**消歧而非前提**：

- SDK 只声明 `draggable(true)` 会让**绑定到组件上的长按手势**失效
  （`image.d.ts:1117-1121` 原文 *"组件默认拖拽效果，设置为 true 时，组件可拖拽，**绑定的长按手势不生效**……
  若用户需要设置自定义手势，则需要将 `draggable` 设置为 `false`"*）；
- 分析器的长按由**系统内部**处理，不属于"拖拽类事件"，官方**未声明**两者交互；
- 但停用拖拽之后，"与识别争抢长按"的唯一角色（拖拽）已被移除，**行为因此完全确定** ——
  这也是本工程在 `docs/IMMERSIVE_LIGHT_DESIGN.md:1260-1262` 已确立的既有取向。
  真机若长按无反应，第一件事就是回来核对这一行是否还在。

> ⚠️ **官方文档未覆盖的空白（必须真机确认）**：SDK 与文档**都没有**声明"分析器长按"与
> "容器上自定义手势"的仲裁规则，官方示例只把 `enableAnalyzer` 的 `Image` 放在一个
> **没有绑任何手势**的 `Stack` 里。因此本方案的真机验收**必须逐条覆盖**
> "长按能识别 **且** 点击开查看器 / 双击缩放 / 双指缩放 / 左右切图全部照旧"（见 §6）。
> 若真机出现长按被容器手势吃掉，官方给出的手段是 `priorityGesture` / `parallelGesture`
> （`best/手势与导航/手势事件冲突解决方案`），但那属于真机失败后的兜底，**不预先加**。

### 3.3 明确**不**开启的位置（避免"全站开花"）

| 位置 | 不开启的理由 |
| --- | --- |
| 主题列表预览图（`TopicListPanel`） | 列表浏览不该出选字菜单：① 长按与卡片 `onClick`（打开帖子）竞争；② 列表长按与滚动是同一条手势通道；③ 官方建议"**大图预览场景**都打开此能力"，缩略图不是该场景。用户明确要求此处不支持 |
| `MovingPhotoPlayer` 封面图（`MovingPhotoPlayer.ets:483`，正文与查看器共用） | 它的兄弟节点 `MovingPhotoView` 自带「长按播放」，本工程已用 `.hitTestBehavior(HitTestMode.None)` 屏蔽并**把触点交给父容器**；封面同样设了 `HitTestMode.None`。给这张封面开分析会与"查看器长按不注册操作"的既有契约（`docs/research/MOVING_PHOTO_PLAN.md`：「图片本体的长按不注册操作」）相抵。且动态照片本身是动图语义，`AnimatedDrawableDescriptor` 已明确不生效 |
| 各类图标 / 头像 / 角标 `Image` | 非内容图，非"大图预览场景" |

### 3.4 为什么"显式写 `enableAnalyzer(false)`"而不是省略

默认值就是 `false`，省略等价。**写出来是为了固化意图**：本文件是三个面里唯一"必须保持关闭"的面，
而它就在 `ImageViewer` 的上一跳（点预览图 → 开查看器），后续改动极易顺手复制粘贴成开启。
一行显式 `false` + 注释 + 交叉引用，比省略更省未来的排查成本。

### 3.5 选取态的取消（系统没有"清除选区"接口，只能拆分析器）

**问题**（真机反馈）：长按正文图选字后，选取态连同系统浮出的文本菜单会一直留在图上——
单击图片直接进 `ImageViewer`、滚动列表时菜单只是临时隐藏（松手又回来）、点正文文字也不会收掉它。

**候选杠杆盘点**（本地 SDK 全文检索，逐个给结论）：

| 候选 | 声明位置 | 结论 |
| --- | --- | --- |
| `Image.startImageAnalyzer` / `stopImageAnalyzer` | — | **不存在**。只有 `XComponentController`（`xcomponent.d.ts:316 / 332`）与 `CanvasRenderingContext2D`（`canvas.d.ts:2877 / 2892`）有 |
| `VisionImageAnalyzerController.setImageAnalyzerVisibility(HIDDEN)` | `@hms.ai.visionImageAnalyzer.d.ets:44` | 文档原文是"设置 AI 识图**控件**的可见性"，官方示例在 `aboutToAppear` 里调用它（用途是隐藏 AIButton，另有独立的 `setAIButtonVisibility`）。**它是否连"已显示的选区"一并收起，本地没有任何证据**；为一个不确定效果引入 `@kit.VisionKit` 可选能力包，收益不成立 |
| `VisionImageAnalyzerController.getImageAnalyzerUIStatus()` | 同文件 `:159` | 只能**读**界面状态（`TEXT_SELECTED` / `SUBJECT_SELECTED`…），不能清除 |
| `Image.enableAnalyzer(false)` | `image.d.ts:1626` | **本方案采用**：声明原文 *"When this parameter is set to **false**, the **Image** component does not support AI analysis"* ⇒ 分析器整体拆除 ⇒ 选区与文本菜单一并消失（"已显示的选区会被一起拆掉"是**推断**，见 §6.3） |

**实现**（细节见 `THREAD_DESIGN.md` §6.5.1 与 `common/media/ImageAnalyzerSession.ets` 文件头）：

- 会话登记表（跨组件）+ 三条取消路径：单击**产生选区的那张**图（只取消、不进查看器）、
  单击正文任意位置（含正文文字与正文内可点元素，以及**别的楼层**的图片）、滑动宿主列表
  或正文内的横向滚动（代码块 / 宽表）；
- 长按判定用 `onTouch` **计时**，不注册 `LongPressGesture`（手势会与系统识图的长按竞争，
  赢了就掐掉识图）；计时阈值取 400ms，是对 **ArkUI 长按手势默认阈值 500ms** 留的提前量
  （分析器内部阈值未公开）；按下被接管而只收到 `Cancel` 时用 250ms 补判兜底；
- 取消同时挂在图片的 `Up` 与 `onClick` 上：系统选区浮层可能吃掉 `onClick`，只挂 `onClick`
  会让选区彻底收不掉；`Up` 上取消后用一次性标记把随后的点击按下去；
- 拆除 = 把 `enableAnalyzer` 关一次，**跨帧**（150ms）再打开。

**真机必须核对的一条**：`enableAnalyzer(false)` 是否真会把**已经显示出来的选区**一起拆掉——
SDK 只声明"组件不再支持 AI 分析"，没有逐字说明"已显示的选区会被清除"。若真机发现选区仍在，
备选方案按代价从低到高：① 在 `if` 分支里销毁并重建该 `Image` 节点（重新解码，有闪烁风险）；
② 改 `src` 触发重载（多一次网络/解码，不考虑）；③ 绑定 Vision Kit 控制器改走定制交互
（引入可选能力包）。**拿到真机结论之前不要预先加 ① / ②。**

---

## 4. 决策记录

| # | 决策 | 理由 |
| --- | --- | --- |
| 1 | ~~**不传 `ImageAIOptions`，只写 `.enableAnalyzer(true)`**~~ **已被决策 10 取代** | 原理由：系统默认即「主体识别 + 文字识别」，与鸿蒙图库体验一致；改 `Image` 构造重载只为砍掉"抠图"这一项能力，收益不抵风险（且 `(src, imageAIOptions)` 重载不支持 `ImageContent`）。实践后主体分割带来的第二套选取态与"长按只为看字"的语义不符，故推翻 |
| 2 | **不加设置开关，恒定开启** | 用户明确要求；且官方定位为"大图预览场景的默认能力"，与系统图库一致。`enableAnalyzer` 无预分析开销（不做 AIButton 就不预分析） |
| 3 | **不做设备能力探测 / 降级** | 与本工程材质取向一致（§2.4）；不支持时静默失效，无副作用 |
| 4 | **列表预览图显式关闭** | §3.3 |
| 5 | **正文图在 `BBCodeContentView` 落地，不在 `ThreadPanel`** | 图片节点实际归属见 §3.1 |
| 6 | **取消选取态 = 关一次 `enableAnalyzer`** | 系统没有"清除选区"接口（§3.5 逐条盘点），这是 `Image` 上唯一可用的杠杆 |
| 7 | **长按判定用 `onTouch` 计时，不注册 `LongPressGesture`** | 手势会与分析器内部的长按竞争：本组件赢下长按的同时也就掐掉了识图 |
| 8 | **取消同时挂在图片的 `Up` 与 `onClick` 上，`Up` 取消后用一次性标记按下这次点击** | 系统选区浮层可能把 `onClick` 一起吃掉，只挂 `onClick` 会让选区彻底收不掉（§6.3 前提 3） |
| 9 | **取消入口只有正文组件内部 + 宿主列表滚动** | 产品选择：楼层其它区域（头像、动作栏）与 `ImageViewer` 内手势不在本次范围内，不要顺手扩大 |
| 10 | **分析类型收窄为「只做文字识别」**（`ImageAnalyzerType.TEXT`），正文图与 `ImageViewer` 三张轮播图一致 | 不传 `types` 时系统默认同时开启主体识别（长按抠图）与对象查找：长按无文字的照片也会弹出选区与系统菜单，与正文图"长按只为看 / 复制图里的字"的语义不符，还并存出第二套选取态（取消链路要额外照顾）。**类型只能经构造下发**——`Image` 没有 `analyzerConfig` 属性（那是 `Video` 的），统一由 `common/media/ImageAnalyzerOptions.ets` 的 `createTextOnlyAnalyzerOptions()` 提供。代价：长按无文字的照片没有任何识别 UI，但"乐观会话"仍会让紧接着的第一次单击被吞一次（§6.2 第 22 项） |

---

## 5. 改动清单

| 文件 | 改动 |
| --- | --- |
| `entry/src/main/ets/common/components/ImageViewer.ets` | 三张轮播 `Image` 改为 `Image(url, createTextOnlyAnalyzerOptions())` + `.enableAnalyzer(true)` |
| `entry/src/main/ets/common/components/BBCodeContentView.ets` | 实图 `Image(src, createTextOnlyAnalyzerOptions())` + `.enableAnalyzer(this.analyzerEnabled)` + 长按计时（含 `Cancel` 补判）+ `Up`/`onClick` 双路取消与点击抑制（§3.5）；被动式占位图标与占位行同步走同一开关与同一点击分流；根容器加 `onTouch` 收"点击正文"；代码块 / 宽表的横向 `Scroll` 加 `onDidScroll` 取消 |
| `entry/src/main/ets/common/media/ImageAnalyzerOptions.ets` | **新增**：`createTextOnlyAnalyzerOptions()`——只做文字识别的构造选项（决策 10） |
| `entry/src/main/ets/common/media/ImageAnalyzerSession.ets` | **新增**：识图选取态会话登记表（跨组件的取消通道，§3.5） |
| `entry/src/main/ets/pages/TopicListPanel.ets` | 预览图加 `.enableAnalyzer(false)`（显式固化） |
| `entry/src/main/ets/pages/ThreadPanel.ets` | 帖子列表 `onDidScroll` 里取消选取态（`dismissAnalyzerSessions()`） |
| `entry/src/main/ets/pages/MessageDetailPanel.ets` | 私信列表 `onDidScroll` 同上 |
| `entry/src/main/ets/pages/ProfilePanel.ets` | 个人主页 `onDidScroll` 同上（签名区含正文图） |
| `entry/src/test/ImageAnalyzerSession.test.ets` | **新增**：会话登记表 Hypium 用例，并在 `List.test.ets` 注册 |

**权限**：无需改动（`ohos.permission.INTERNET` 已在 `module.json5:17`）。
**依赖**：无需改动（全部是 ArkUI 全局声明与工程内模块，未引入 `@kit.VisionKit` 等可选能力包）。
**行尾**：全部 `.ets` 为 LF（`node scripts/check-eol.mjs` 自检）。

---

## 6. 验证要求

### 6.1 自动验证（可在本机完成）

1. `node scripts/check-eol.mjs` → 本次改动文件全为 LF（字节级复核）。**该脚本当前整体退出码为 1**，
   唯一违规项是既有的 `oh-package-lock.json5`（工具链在 Windows 上重写的锁文件：index 为 LF、
   工作区为 CRLF，`git status` 无内容差异，mtime 早于本次改动）。**不要为此改锁文件**。
2. `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` → **0 修改**（本次改动的文件都不在 TS 镜像
   清单里，未触碰解析器真源）。
3. DevEco API 26 构建通过（`harmonyos-build-deploy` skill 流程）。
   `enableAnalyzer` 在 `component_config.json` 的 `Image.attrs` 白名单内，属性校验会放行。
4. `entry/src/test` 的 Hypium 本地用例通过（`harmonyos-test` skill 流程），含会话登记表回归套件
   `imageAnalyzerSession`。

### 6.2 真机验证（**模拟器不支持本特性，必须真机**）

按 §2.1，**"本 kit 暂不支持模拟器"**：模拟器上长按静默无反应，**不能作为失败结论**。

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | 帖子页长按正文大图 | 出现文字框选区域 + 复制文本菜单；点击图中识别按钮同样出现 |
| 2 | 帖子页长按含电话号码/时间/网址的图 | 出现实体下划线，点击/持续长按出对应快捷操作 |
| 3 | 帖子页长按主体（非文字区） | **不出现**任何识别 UI（含抠图）——类型已收窄为只做文字识别（决策 10） |
| 3b | 查看器长按当前页的非文字区 | 同上：不出现抠图 / 识图搜索 |
| 3c | 正文图 / 查看器长按文字区 | 正常出现文字框选与复制菜单（收窄类型后文字识别不受影响） |
| 4 | 帖子页**单击**图片 | **照旧**打开 `ImageViewer`（回归项） |
| 5 | 查看器长按当前页 | 可选取文字 |
| 6 | 查看器**双击**图片 | **照旧**缩放 / 还原（回归项） |
| 7 | 查看器**双指捏合** | **照旧**缩放（回归项） |
| 8 | 查看器**左右滑动** | **照旧**切图（回归项） |
| 9 | 查看器长按后滑动 | 不串成切图（长按态下手势归属正确） |
| 10 | 主题列表长按预览图 | **不出现**任何识别/选字 UI；卡片点击、列表滚动照旧 |
| 11 | 正文 GIF 动图长按 | 无识别（系统限制，**非缺陷**） |
| 12 | 长截图（高 > 宽×7）长按 | 无文字识别（系统限制，**非缺陷**） |
| 13 | 深色模式 / 亮色模式 | 识别 UI 配色正常（系统接管，无工程侧配色） |
| 14 | 低端或非国内设备 | 无识别时**不报错、不崩溃**，其余交互不受影响 |

**选取态取消（§3.5，本次新增，同样必须真机）**：

| # | 场景 | 期望 |
| --- | --- | --- |
| 15a | 长按正文图出现选区后，单击同一张图的**选区内**区域 | 选区与文本菜单消失，**不**进入 `ImageViewer`（验证取消不依赖 `onClick`：选区浮层可能吃掉这次点击） |
| 15b | 同一次会话下，单击同一张图的**选区外**区域 | 同上；再点一次才进 `ImageViewer` |
| 16 | 选区还在时**单击正文文字 / 链接 / 折叠块 / 动态照片角标** | 选区消失，该元素原有点击行为照旧 |
| 17 | 选区还在时**滑动帖子列表**（起点在任意楼层、含列表空白处） | 滚动一开始选区就消失，**松手后不再回来** |
| 17b | 选区还在时**横向拖动代码块 / 宽表** | 选区消失 |
| 18 | 取消后**再次长按同一张图** | 识图能力已恢复（150ms 后重新武装），识别结果正常 |
| 19 | 取消后**快速连续**单击图片 | 第一次点击取消、第二次进查看器，不丢点击、不重复进查看器 |
| 20 | 长按图片后立即滚动（同一根手指不抬起） | 不误判为长按会话（位移超 10vp 即撤销判定），滚动照旧 |
| 21 | 长按图片 A 出现选区后，单击**另一楼层**的图片 B | 选区消失并进入 `ImageViewer`（跨楼层也要收干净） |
| 22 | 已知现象（**非缺陷**）：长按**没有文字**的正文图（含 gif / svg / <100×100 / 长截图，以及只做文字识别后一切无文字的照片）后单击该图 | 这张图本来不会出选区，会话是"乐观判定"出来的，因此这一次单击会被吞（表现为"点了没反应"），再点一次正常 |

### 6.3 已知不可验证项

- 模拟器：本 kit 不支持，**无法验证**。§6.2 的 15–22 项（选取态取消）同样只能在真机验收。
- **三条无法在本机证伪的前提**，全部只能靠真机结论：
  1. **"关一次开关能否拆掉已显示的选区"**——SDK 只声明"组件不再支持 AI 分析"，没有逐字说明已显示的
     选区会被清除。这是整个方案的地基，真机第 15a 项就是它的判据；万一不成立，备选方案见 §3.5。
  2. **"分析器内部长按阈值 ≥ 400ms"**——官方**未公开**分析器阈值，只能按 ArkUI 长按手势默认值
     500ms 推断（代码里已用 `Cancel` 补判兜 250–400ms 的窗口）。
  3. **"单击能否穿透系统选区浮层"**——本地查不到该浮层的命中测试语义。因此取消同时挂在图片的
     `Up` 与 `onClick` 上：`onClick` 被吃掉也能取消；但"第一次单击不进查看器"这一条依赖二者之一
     可达，真机 15a / 15b 分开验收。
- 交互类断言无法自动化（无 UI 自动化门禁）。**会话登记表**本身是纯逻辑，已由 Hypium 本地用例覆盖
  （`entry/src/test/ImageAnalyzerSession.test.ets`）：登记 / 注销（句柄唯一性、只注销命中的那条）/
  一次拆除全部 / 回调内注销自己的时序。ArkUI 侧的 `onTouch` 判定与点击分流仍只能靠真机 §6.2。

---

## 7. 官方资料

| 主题 | 出处 |
| --- | --- |
| `Image.enableAnalyzer` API 参考 | `api/应用框架/ArkUI（方舟UI框架）/ArkTS组件/图片与视频/Image/Image.md` §enableAnalyzer（本地镜像 1123–1206 行） |
| 类型定义（`ImageAnalyzerType` / `ImageAIOptions` / `ImageAnalyzerController`） | `api/应用框架/ArkUI（方舟UI框架）/ArkTS组件/图片与视频/图像类型定义/图像类型定义.md` |
| AI 识图开发指南（长按语义、约束与限制、示例） | `guides/AI/Vision Kit（场景化视觉服务）/AI识图/AI识图.md` |
| Vision Kit 简介（设备与模拟器约束） | `guides/AI/Vision Kit（场景化视觉服务）/Vision Kit简介/Vision Kit简介.md` |
| 最佳实践（社交场景长按识图与抠图） | `best/行业场景解决方案/社交通讯/AI辅助图文内容编创/AI辅助图文内容编创.md` |
| 手势冲突（`priorityGesture` / `parallelGesture` 兜底） | `best/手势与导航/手势事件冲突解决方案/手势事件冲突解决方案.md` |
| 本地 SDK 声明 | `<SDK>\openharmony\ets\component\image.d.ts:1626`、`image_common.d.ts:19-143`、`component_config.json`（`Image.attrs`） |

华为开发者文档（在线）：
[Image 组件](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-basic-components-image)、
[AI 识图](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/vision-imageanalyzer)、
[图像类型定义](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-image-common)。

官方资料用于确定平台能力与交互语义；**"哪三个面开启、哪三个面保持关闭"以及"不做设备降级"是本项目
当前选择，应以仓库代码为准**。
