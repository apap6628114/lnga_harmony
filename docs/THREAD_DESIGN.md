# Thread 详情页设计约束

本文是 Thread 详情页的设计契约和故障定位依据，不是功能介绍或界面效果说明。文中的“必须”“不得”表示当前实现依赖的不变量；“当前实现”表示可以替换、但替换时必须继续满足不变量的实现选择。

当前工程的 [`targetSdkVersion` 与 `compatibleSdkVersion`](../build-profile.json5) 均为 HarmonyOS API 26。本文最初形成于 API 23，原始目标是约束连续分页、列表定位和滚动事务；API 26 新增的系统材质与标题区动态视觉属于表现层扩展，不改变原有分页和索引语义。

## 1. 文档范围与演进边界

### 1.1 本文覆盖

- 从任意页进入后向前、向后连续扩展的帖子窗口。
- 页面替换、列表重新挂载、帖子定位和旧请求失效。
- 上一页前插时的视口锚点恢复。
- pid 路由和引用链接的页内、跨页定位。
- 固定标题区、列表初始避让以及 API 26 动态模糊/偏色的坐标关系。

帖子正文渲染、BBCode 版式、投票、回复编辑器和菜单业务不属于本文范围，除非它们改变上述契约。

### 1.2 演进分层

| 阶段 | 引入的设计 | 不得被后续阶段改变的内容 |
| --- | --- | --- |
| API 23 基线 | 连续分页窗口、零基帖子索引、`REPLACE` 后延迟定位、前插锚点事务 | 数据窗口、索引和滚动生命周期契约 |
| 引用导航扩展 | 引用头页码透传、整页定位、一次单帖兜底 | 普通分页请求和连续窗口语义 |
| API 26 视觉扩展 | 标题按钮系统材质、正文渐变模糊、标题偏色、共享滚动效果计算 | 上述全部数据和定位不变量 |

视觉实现不能成为修改分页索引、插入伪数据项或改变请求提交顺序的理由。

### 1.3 关键实现文件

| 文件 | 职责 |
| --- | --- |
| [`ThreadPanel.ets`](../entry/src/main/ets/pages/ThreadPanel.ets) | 页面生命周期、请求调度、列表定位、前插锚点、滚动协调和日志 |
| [`ThreadPaginationManager.ets`](../entry/src/main/ets/common/managers/ThreadPaginationManager.ets) | 连续页窗口、pid 去重、页码映射和预取缓存提交 |
| [`LazyDataSource.ets`](../entry/src/main/ets/common/datasource/LazyDataSource.ets) | `PostInfoDataSource` 的 ArkUI 列表变更通知 |
| [`TitleScrollEffect.ets`](../entry/src/main/ets/common/utils/TitleScrollEffect.ets) | 标题总高、重叠进度、模糊半径和空间渐变停靠点 |
| [`PanelNavBar.ets`](../entry/src/main/ets/common/components/PanelNavBar.ets) | 固定标题内容、按钮材质和偏色覆盖层 |
| [`ThreadSummaryService.ets`](../entry/src/main/ets/service/ThreadSummaryService.ets) | 全帖 AI 总结的跨页取数、截断策略与提示词组装 |
| [`ThreadWaterFilterService.ets`](../entry/src/main/ets/service/ThreadWaterFilterService.ets) | 智能去水的全帖抓取、本地规则判定、同形状页重组与落盘（见 [WATER_FILTER_DESIGN.md](WATER_FILTER_DESIGN.md)） |
| [`ThreadPaginationUnit.test.ets`](../entry/src/test/ThreadPaginationUnit.test.ets) | 分页管理器不变量的单元回归 |

## 2. 用户可观察行为

Thread 不是“每次只显示一页”的普通分页页面，而是从任意页建立窗口、随后向两侧连续扩展的帖子流。连续滚动模式必须满足：

1. 标题区固定在屏幕顶部，帖子列表在其后方滚动。
2. 普通进入或分页器跳页完成后，目标页首帖完整位于标题区下方。
3. 正文继续向上滚动时可以进入标题区；可读性由滚动联动的模糊与偏色保证。
4. 接近窗口末端时追加下一页，接近窗口开头时前插上一页；两种加载互不阻塞。
5. 前插不能改变用户正在阅读内容的屏幕位置。
6. 任意一次 `REPLACE` 后，旧请求、旧定位任务和旧前插事务均不能影响新窗口。
7. `ThreadNavMode.PAGE` 保持传统翻页语义，不启动连续窗口的边缘加载和预取。

## 3. 状态所有权

| 层 | 权威状态 | 不负责的内容 |
| --- | --- | --- |
| `ThreadPaginationManager` | `posts`、`pageOfIndex`、`loadedPageStart`、`loadedPageEnd`、`totalPages`、预取缓存、请求代际 | ArkUI 生命周期和滚动命令 |
| `ThreadPanel` | 加载模式、列表挂载状态、导航意图、可见索引、前插锚点和滚动视觉进度 | 重新定义分页事实 |
| `PostInfoDataSource` | `List` 所需的插入、删除、更新通知 | 保存第二套分页窗口 |
| `TitleScrollEffect` / `PanelNavBar` | 标题区几何与视觉映射 | 数据索引、页码和请求调度 |

`ThreadPaginationManager` 是帖子数组与页窗口的唯一事实来源。`PostInfoDataSource` 只能镜像管理器的提交结果，不得独立决定页面是否已加载。

## 4. 核心不变量

### 4.1 可见数据是连续页窗口

设当前窗口为闭区间 `[S, E]`：

- `1 <= S <= E <= totalPages`；首次有效提交后由服务端页码建立窗口。
- 只能把 `S - 1` 前插到窗口，或把 `E + 1` 追加到窗口。
- 更远页面可以先进入预取缓存，但不得越过相邻页直接进入 `posts`。
- `posts.length === pageOfIndex.length`，且 `pageOfIndex[i]` 是 `posts[i]` 的所属页。
- 跨页去重键是 `pid`，不是楼层号 `lou`。
- 相邻页为空，或其帖子全部因 pid 重复而被过滤时，窗口边界仍必须推进；否则边缘协调会无限请求同一页。
- `APPEND` 与 `PREPEND` 在同一请求代际内运行，并分别使用 `isLoadingMore`、`isLoadingPrevious`。
- 静默刷新（回复/贴条/编辑成功后）使用 `mergePage` 合并服务端一页：
  窗口内页按 pid 原地替换内容——内容变化时递增楼层渲染版本号 `uiRev`（LazyForEach
  键值 `pid + uiRev` 变化触发该楼层重建刷新），内容相同则保持 `uiRev` 不变（键值
  稳定、组件复用、无可见重建）；未见过的新 pid 仅当该页是"窗口末页且服务端
  总页数未增长"时追加到窗口末尾；`E + 1` 页整页追加并推进窗口。`mergePage`
  不调用 `reset()`，不推进请求代际，也不改变 `S`；提交前调用方必须校验代际。
- 编辑场景的静默刷新可传 `protectedContent`（pid → 刚提交的新正文）：服务端返回
  的内容与该映射不符（read.php/CDN 缓存未失效、仍是编辑前旧正文）时跳过该楼层
  覆盖，保留乐观更新结果，防止 UI 回退。

例如窗口为 `[9, 10]` 时，第 8、11 页可以提交；第 7、12 页即使已经返回，也只能缓存。

### 4.2 列表帖子索引是零基索引

对所有帖子相关操作：

```text
listPostIndex === managerPostIndex
```

- 第 `0` 个帖子就是 `posts[0]`。
- 标题区和顶部安全距离不占用 `ListItem`。
- 普通进入或分页器跳页定位帖子索引 `0`。
- pid 定位直接使用 `findPostIndex(pid)` 的结果。
- `onScrollIndex` 的中心帖子索引直接用于查询 `pageOfIndex`。
- 前插锚点按 pid 在新数组中重新查找，不猜测前插数量。

列表末尾存在一个加载/完成状态项，但它不属于 `posts`，也不进入 `pageOfIndex`。不得为标题栏重新添加顶部伪 `ListItem`，也不得引入全局 `index + 1` 或 `index - 1` 补偿。

### 4.3 `REPLACE` 切换请求代际

活动页面内，只有 `loadPosts(..., REPLACE)` 会调用 `ThreadPaginationManager.reset()` 并切换请求代际；页面销毁时也会重置管理器，使未完成任务失效。代际计数只递增、不归零。每个请求和延迟任务捕获发起时的代际，提交前必须与当前代际一致。

由此得到：

- 新 `REPLACE` 使旧网络响应和旧下一帧任务失效。
- `APPEND`、`PREPEND` 和同一窗口的预取共享当前代际。
- 代际检查负责异步隔离；不得用固定延时假设请求或布局已经完成。

### 4.4 `REPLACE` 定位是挂载后事务

`isLoading` 分支会卸载旧 `List`。数据返回时，新 `List` 尚未存在，因此替换加载按以下顺序执行：

1. 取消旧列表定位和前插锚点，重置管理器并记录新代际。
2. 请求目标页；响应代际有效时调用 `replaceWith` 和 `PostInfoDataSource.replaceAll`。
3. 用 `prepareListNavigation` 保存目标页与可选 pid，不立即滚动。
4. 退出加载态，使 `List` 重新创建。
5. `List.onAppear` 将 `listMounted` 设为 `true`。
6. 下一帧执行 `scrollToIndex(0, START)` 或 pid 居中定位。
7. 清除定位事务后，再恢复边缘协调。

在 `listMounted === false` 时调用 `scrollToIndex` 不能视为成功定位；命令可能无异常但不会作用于新列表。

### 4.5 `PREPEND` 是显式锚点事务

`maintainVisibleContentPosition(true)` 已启用，但当前实现仍以显式 pid 锚点恢复作为前插事务，不能只依赖框架的自动保持。

事务步骤：

1. 提交上一页前，以 `lastScrollStart` 对应帖子为锚点，记录其 `pid` 和 `getItemRect(index).y`。
2. 设置 `prependAnchorPending`；事务期间忽略中间态 `onScrollIndex`，并暂停 `reconcile`。
3. 管理器提交相邻上一页，数据源前插实际新增帖子。
4. 下一帧按 pid 查找锚点的新索引。
5. 使用以下偏移恢复原屏幕位置：

   ```text
   H = statusBarHeight + NAV_BAR_H
   restoreOffset = H - anchorOffset
   scrollToIndex(anchorIndex, START, extraOffset = restoreOffset)
   ```

6. 再下一帧更新可见索引与显示页，结束事务并重新协调边缘加载。

锚点 pid 丢失、未插入新帖子或新 `REPLACE` 开始时必须取消事务。

## 5. 导航和加载流程

### 5.1 普通进入与分页器跳页

- 普通进入使用路由提供的 `threadPage` 建立单页窗口。
- 分页器跳页是 `REPLACE`，不是在旧窗口上追加。
- 用户主动跳页、只看楼主切换、回复后刷新和编辑后刷新不得继承旧的目标 pid。
- 请求失败后的重试保留本次路由定位意图。
- 回复/贴条/编辑成功后默认走静默刷新（`silentRefreshAfterPost` → `mergePage`）：
  不重建窗口、不发生位移，且不得设置 `pendingTargetPid`。窗口停在中间页时
  新楼层不在窗口内、数据无变化，不发起请求；贴条/编辑刷新目标楼层所在页，
  合并该页后即结束，不逐页推进窗口。
- 编辑成功后先以提交正文乐观更新本地楼层（换行转 `<br/>`，其余 BBCode 原样），
  并递增该楼层 `uiRev` 使 LazyForEach 键值变化立即重建显示；再发起静默刷新：
  刚提交后 read.php/CDN 缓存可能未失效，乐观更新保证用户第一时间看到新正文。
  静默刷新返回服务端确认的新正文时以服务端内容为准覆盖；返回仍是编辑前旧正文
  （缓存未失效）时跳过覆盖，保留乐观更新结果。
- Toast 的「前往查看」是用户显式的新定位意图：目标 pid 解析链为 post.php 响应
  pid → 静默刷新追加的新楼层 pid（仅回复场景记录；并发回复时窗口末尾可能为他人
  楼层，属近似）→ 仍未知时加载服务端末页并定位其最后一个楼层（`pendingTargetLastPost`，
  由 REPLACE 提交分支消费为末项 pid）。窗口内命中直接居中滚动（零请求）；未命中
  时以新 pid 发起整页 `REPLACE` 定位（请求不携带 pid），页内未命中再走一次单帖
  兜底；只看楼主模式下提前提示不可见。

### 5.2 边缘加载与预取

`onScrollIndex` 更新 `lastScrollStart`、`lastScrollEnd` 和中心页码，然后调用 `reconcile`：

- 末端进入 `PAGE_LOAD_AHEAD_ITEMS` 范围时提交缓存或请求 `E + 1`。
- 开头进入同一阈值范围时提交缓存或请求 `S - 1`。
- `listNavigationPending` 或 `prependAnchorPending` 为真时暂停协调。
- 空页或全重复页不会引起列表索引变化，提交后必须显式安排下一次 `reconcile`。
- 预取可以并行、乱序完成，但结果只写入按页缓存；可见窗口仍逐页提交。

### 5.3 pid 与引用跳转

当前解析协议把引用头 `[pid=目标pid,主题tid,目标页]Reply[/pid]` 的第三段作为路由页码透传。Thread 不根据楼层号重新推导页码。

定位规则：

1. 同主题且目标 pid 已在当前窗口、列表不处于定位或前插事务时，直接页内居中滚动，不发起请求。
2. 跨页进入时，先按引用页码请求整页，再在页内按 pid 定位。
3. 普通整页 `REPLACE` 不携带 pid。当前 NGA 接口在携带 pid 时返回单帖视图，其 `__PAGE`、`__ROWS` 和总页数语义不同，不能用于建立普通连续页窗口。
4. 整页没有目标 pid 时只允许进行一次带 pid 的单帖兜底；`singlePostFallback` 防止循环兜底。
5. 进入单帖兜底前保存 `fallbackPrevTotalPages` 和目标页；单帖响应提交后恢复总页数和显示页，避免分页器消失或 `hasNextPage()` 永久为假。
6. 兜底仍未找到 pid 时提示目标楼层不存在，并回退到当前结果的索引 `0`。

`pendingTargetPid` 只表示尚未完成的路由定位意图。定位成功、用户主动发起其他 `REPLACE` 或页面销毁后必须清除。

## 6. 标题区布局与 API 26 视觉契约

### 6.1 几何关系

`ThreadPanel` 使用覆盖式 `Stack`：`List` 占满视口，`PanelNavBar` 固定在 `(0, 0)`。标题区总高定义为：

```text
H = statusBarHeight + NAV_BAR_H
NAV_BAR_H = 44vp
contentStartOffset = H
```

`contentStartOffset` 只定义列表位于起点时的安全距离，不创建列表项，也不阻止后续正文进入标题区。

### 6.2 滚动重叠进度

`Scroller.currentOffset().yOffset` 的零点不是列表的视觉起点。设置 `contentStartOffset = H` 后：

```text
列表位于起点： yOffset = -H
首项到达屏幕顶部： yOffset = 0
```

标题视觉必须使用正文已经侵入初始安全区的距离：

```text
overlapDistance = max(yOffset + H, 0)
progress = clamp(overlapDistance / TITLE_SCROLL_EFFECT_DISTANCE, 0, 1)
TITLE_SCROLL_EFFECT_DISTANCE = 20vp
```

`20vp` 是本项目的视觉参数，不是布局偏移，也不应被描述为平台强制值。顶部回弹使 `yOffset < -H` 时，进度仍为 `0`。不得改回 `clamp(yOffset / distance)`；该写法会把效果推迟到首项到达屏幕顶部。

`onDidScroll` 的参数是本帧滚动量，不能直接累计为绝对状态。当前实现每帧读取 `Scroller.currentOffset()`，并在 `List.onAppear` 后重新校准。

### 6.3 渲染分工

滚动进度和空间渐变是两个不同维度：

- `progress` 线性控制当前最大模糊半径和标题偏色层透明度。
- `List.linearGradientBlur` 控制模糊在视口纵向的分布：标题区内为最大强度，标题底部以下 `32vp` 衰减到零。
- 最大模糊半径为 `16`；常量分别由 `TITLE_BLUR_RADIUS` 和 `TITLE_BLUR_FADE_DISTANCE` 定义。
- `PanelNavBar` 的偏色层覆盖 `H + 32vp`，标题区内使用 `title_backdrop_tint`，随后渐变到 `title_backdrop_clear`。
- 偏色层使用 `HitTestMode.None`，不得拦截帖子或标题按钮交互。

沉浸光感是 API 26 构建的固定视觉契约，不提供运行时开关或旧版实色回退：

- 返回、更多等标题操作按钮的背板是 36×36 的 `HdsMaterialHost`（HDS 材质宿主，材质块尺寸常量
  `TITLE_POD_SIZE`）：`PanelNavBar` 是自绘标题栏，不在 `Navigation` 标题栏内，ArkUI 的
  `systemMaterial` 在 Release 下拿不到材质，HDS 悬浮页签栏材质是这里唯一的通道
  （`docs/IMMERSIVE_LIGHT_DESIGN.md` §12.9）。材质块的形状由 HDS 规范决定，**不再是自绘的正圆**；
  真机待核对项见该节"标题栏按钮"。
- 右侧存在两个操作按钮时，按钮之间固定保留 `8vp` 间距（`TITLE_ACTION_BUTTON_GAP`）。
  主按钮承载菜单（`hasMenu`），次按钮一律是**纯动作**、**不得绑定菜单**（`menuOnSecondary`
  保持 `false`）。帖子详情页只挂一颗更多按钮（全帖 AI 总结已移入该按钮的菜单，见 §6.6），
  两按钮布局由其它面板（如 `TopicListPanel`、`FavoriteSavedPanel`）使用。
- 材质不做设备降级：设备不支持材质时按钮背板就是透明的，这是接受的结果。
- 标题操作必须使用语义明确的独立 SVG 资源，不在标题栏中混用文字操作；视觉图标与无障碍名称分别由 `rightIcon` 和 `rightIconAccessibilityText` 提供。
- 标题栏本体不使用整块材质；正文模糊由 `List` 承担，标题可读性由颜色渐变层承担。
- 不绘制用于强调标题底边的常驻分割线，避免形成独立矩形区域。
- 浮层不再自绘玻璃：更多菜单走 `bindMenu`（`menuMaterial`），页码选择器走 `bindPopup`
  （`popupMaterial`），菜单 / 气泡内部的输入框走 `dialogFieldMaterial`；右下角**常驻**的分页条与
  回复按钮走 `HdsMaterialHost`（HDS 材质宿主）。
  组件不得保存材质启用状态，也不得按持久化设置切换 `systemMaterial`。

### 6.5 正文图的长按识图（AI 图像分析）

正文图（含引用块内的图）已开启系统 AI 图像分析，**长按图片的文字区**即可识别文字并框选 / 复制。
同一能力也开在 `ImageViewer` 的三张轮播图上。分析类型**只保留文字识别**：不请求主体分割
（长按抠图）与对象查找——长按非文字区没有任何识别 UI，也就不会并存出第二套选取态。

- 开关只有一处：`.enableAnalyzer(true)`（API 11+，ArkUI `Image` 自带，**无需额外权限与依赖**——
  `ohos.permission.INTERNET` 已在 `module.json5` 声明）。默认值为 `false`，不写即关闭。
  正文图这一处的值绑 `@State analyzerEnabled`（取消选取态要把它关一次，见 §6.5.1）。
- **分析类型只能经构造下发**：`Image` 没有 `analyzerConfig` 一类的属性（那是 `Video` 的，
  `video.d.ts:965`），类型只能走构造第二个参数 `ImageAIOptions`（`image.d.ts:559`）。本工程统一用
  `common/media/ImageAnalyzerOptions.ets` 的 `createTextOnlyAnalyzerOptions()` 构造（只有
  `ImageAnalyzerType.TEXT`）。**不要退回不传 `types` 的写法**：不传时系统默认同时开启主体识别与
  文字识别（`image_common.d.ts:20-28` 原文），长按无文字的照片也会弹选区与系统菜单。
- 节点归属：正文图由 `BBCodeContentView.RenderImageContent` 渲染（`PostItem` 内部），
  **不在 `ThreadPanel.ets` 里**；改这一处同时覆盖引用块与就地播放的动态照片封面。
- `.draggable(false)` **必须保留**：它不决定识别是否生效（分析器的长按由系统内部处理，
  不属于拖拽类事件），但它是"长按只归识别"的消歧手段——`draggable(true)` 会让绑定到组件上的
  长按手势被拖拽消费（`image.d.ts` 原文）。真机长按无反应时先核对这一行是否还在。
- **主题列表预览图（`TopicListPanel`）显式保持关闭**（`.enableAnalyzer(false)`）：
  列表缩略图不是"大图预览场景"，且列表长按与卡片点击、滚动同处一条手势通道。
  **该差异是产品决策，不是平台限制**，不要"顺手统一"。
- 不做设备能力探测与降级：非国内设备、老设备与**模拟器**上该能力静默失效（长按无反应、不报错、
  不影响点击与缩放）。**模拟器不支持本特性，因此本条不能在模拟器验收。**
- 系统限制（**不是缺陷，不要当 bug 修**）：svg / gif 不参与分析；图需 ≥100×100；
  **长截图（高 > 宽×7）不做文字识别**；支持语种为简繁中文、英文、维吾尔文、藏文。
- **只做文字识别的代价（已知、可接受）**：长按**没有文字的照片**不会有任何识别 UI，但选区取消
  链路仍会把这次长按记成一次会话，于是紧接着的那一次单击会被吞一次（表现为"点了没反应"，再点
  即正常）。系统没有"这次分析是否真的出了选区"的回执可用，判据只能是长按本身。

#### 6.5.1 选取态的取消（会话登记 + 集中拆除）

系统只在长按之后**接管**识别交互，**没有**"清除选区"接口：`startImageAnalyzer` /
`stopImageAnalyzer` 只存在于 `XComponentController` 与 `CanvasRenderingContext2D`，Vision Kit 的
`VisionImageAnalyzerController` 只有 `setImageAnalyzerVisibility`（官方文档写的是"设置 AI 识图
**控件**的可见性"，示例里用于在 `aboutToAppear` 隐藏 AIButton；**它是否连已显示的选区一并收起
本地无证据**）与只读的界面状态查询（`getImageAnalyzerUIStatus`）。因此**在不引入 `@kit.VisionKit`
的前提下**，`Image` 上唯一可用的杠杆是**把 `enableAnalyzer` 关掉一次**：组件不再支持 AI 分析 ⇒
分析器整体拆除 ⇒ 选取态与系统文本菜单一并消失，稍后再打开即恢复长按识图。

取消契约（三条取消路径 + 一条"不取消"）：

| 交互 | 行为 |
| --- | --- |
| 单击**产生选取态的那张**正文图 | **只取消选取态**，这次点击不进查看器；再点一次才进 |
| 单击正文里的其它图片（含**别的楼层**的图） | 先收掉选区，再照常进查看器（点的是另一张图，拦下来反而莫名其妙） |
| 单击正文任意位置（含正文文字、链接、折叠块、动态照片角标…） | 取消选取态，各元素原有点击行为不变 |
| 滑动宿主列表（帖子列表 / 私信详情 / 个人主页）与正文内的横向滚动（代码块 / 宽表） | 取消选取态。系统在滚动过程中只是把文本菜单临时收起、松手又放出来，**必须主动拆** |

实现要点（**改这块之前先读**）：

- 会话登记表在 `common/media/ImageAnalyzerSession.ets`。登记必须**跨组件**：触发取消的交互
  常常发生在别的楼层（滚动起点甚至不在那一层）。正文组件在 `aboutToDisappear` 必须注销会话，
  否则列表回收楼层后登记表会持有已销毁组件的回调。
- 长按判定**不用 `LongPressGesture`**：绑到组件上的长按手势会与分析器内部的长按**竞争**
  （`draggable(false)` 之后这类手势是生效的），赢了就等于掐掉系统识图。改用 `onTouch` 计时：
  `ANALYZER_LONG_PRESS_MS = 400` 是对 **ArkUI 长按手势默认阈值 500ms**（分析器内部阈值官方
  **未公开**，只能按手势默认值推断）留的提前量，判定结果只用于"取消 / 进查看器"分流，不消费任何
  事件；位移超过 `ANALYZER_LONG_PRESS_SLOP = 10vp` 即撤销判定。若按下被分析器接管而只收到
  `Cancel`，由 `ANALYZER_CANCEL_FALLBACK_MS = 250` 补判（**只补判 `Cancel` 不补判 `Up`**：
  `Cancel` 不是点击，补判错了最多吞掉下一次单击；对 `Up` 补判会把三百毫秒的慢点击直接吞掉）。
- **取消不能只挂在图片的 `onClick` 上**：系统选区浮层盖在图上，点击可能被浮层消费掉，那时
  `onClick` 不触发、选区就再也收不掉。因此图片自己的 `Up` 也承担取消，并置
  `suppressImageTap` 把紧随其后的那次 `onClick` 按下去——保住"第一次点击只取消、不进查看器"。
  该标记在下一次按下即复位，不会外泄。
- 正文根容器用 `onTouch` 而不是 `onClick` 收"点击正文"：点击本身是手势，父子同类手势只会有一个
  响应（正文内每个可点元素都自带 onClick），而触摸事件自叶向根冒泡，根容器一处即可覆盖全部
  可点元素。图片自己的 `onTouch` 先于根容器执行，据此把"落在图上的点击"让位给图片自己处理。
- 拆除后必须**跨帧**再重新武装（`ANALYZER_REARM_DELAY_MS = 150`）：同一帧里的 `false → true`
  会被状态批处理合并成空操作，分析器根本不会被拆掉。代价是该正文组件整树重渲染两次——只有
  真有会话时才会走到这里（登记表空表早退），滚动等无会话路径不付这个成本。
- 已知副作用（可接受）：**程序化滚动**（跳页定位、锚点补偿、翻页前插引起的偏移变化）同样会落在
  `onDidScroll` 上，因此也会收掉选区；长按了**无识别内容**的图（gif / svg / <100×100 / 长截图，
  见 §6.5）同样会成立会话，于是"下一次单击该图"会被吞一次。两者都能重新长按找回。
- 覆盖范围是**正文组件内部**：楼层其它区域（头像、动作栏）与 `ImageViewer` 内的手势**不在**
  本契约内，这是产品选择，不要顺手扩大（要扩就先确认交互，再把取消调用接到对应容器上）。
  另外两点边界：**按图片地址**判定会话归属，同一地址在一层里出现两次视为同一张图；路由入栈时
  底层页面不销毁，因此"导航离开"不会取消选区（未被要求，真机若发现浮层残留再在路由处补一行）。

完整 API 契约、约束出处与真机验收清单见
[`docs/research/IMAGE_TEXT_RECOGNITION_GUIDE.md`](research/IMAGE_TEXT_RECOGNITION_GUIDE.md)。

### 6.4 共享实现的适用条件

`TitleScrollEffect` 和 `PanelNavBar` 是共享实现，不是 Thread 专用视觉副本。页面直接复用时必须同时满足：

1. 正文由可取得绝对偏移的 ArkUI `List` 或 `Scroll` 承载。
2. 标题栏固定覆盖在正文视口顶部，正文容器占满标题栏后方的可用视口。
3. 初始避让使用同一个 `contentStartOffset = H`，不得通过标题占位行或伪数据项实现。
4. 模糊只作用于正文容器，标题偏色只由 `PanelNavBar.scrollEffectProgress` 控制。

当前 `SettingsPanel`、`ProfilePanel`、`FontSizeSettingsPanel`、`TtsSettingsPanel`、`AiSettingsPanel`、`AiChatPage` 和 `MessageDetailPanel` 已按上述条件调整布局并复用相同模型。`MessageDetailPanel` 自己持有标题栏和列表滚动状态；路由容器不得替它代持标题栏，否则无法建立可靠的滚动联动。

`WebViewPanel` 不满足第 1、3 项：`Web` 可报告网页滚动位置，但没有与 ArkUI `contentStartOffset` 等价且不修改网页文档的能力。因此该页面保留非重叠的静态标题布局，并由页面根节点绘制不透明 `AppColors.bg`，避免网页加载或透明区域暴露活动栈下层内容。不得为了表面一致向任意网页注入顶部 DOM/CSS，也不得未经约束切换为 `FIT_CONTENT` 后放入外层 `Scroll`；这两种做法分别会改变网页布局语义，或引入页面高度与无限加载限制。

### 6.6 全帖 AI 总结（更多菜单入口）

「更多」菜单里的「AI 总结帖子」是**全帖** AI 总结；动作栏那颗 AI 图标是**单楼层**总结。
两者是不同功能，共用同一条 `AiChatPage` 流式通道，仅场景标识不同
（`thread_summary` / `post_summary`）：

| 维度 | 单楼层总结（动作栏） | 全帖总结（更多菜单） |
| --- | --- | --- |
| 数据来源 | 该楼层正文（`getCachedBBNodes` 已缓存） | 按总页数跨页取数，仅复用已加载窗口 |
| 场景 | `AiScenario.POST_SUMMARY` | `AiScenario.THREAD_SUMMARY` |
| 入口 | `PostVoteBar.onSummarize` | `moreMenuItems()` 的「AI 总结帖子」项 |

入口与「收藏夹」「离线保存帖子」「跟踪帖子更新」并列，同属**帖子级动作**，因此只出现在
非离线存档分支（`isSavedSource()` 为假时）。**不得**改回标题栏图标：标题栏为单颗更多按钮，
贴子级动作集中在菜单里更容易发现，也不与右侧滚动收起动画争位置。

取数与组装全部在 [`ThreadSummaryService`](../entry/src/main/ets/service/ThreadSummaryService.ets)，
`ThreadPanel` 只负责门禁、进度展示与路由。契约：

- **上限是硬约束，不得为了"完整"取消**：页数超过 20 页时只取第 1~10 页与末页，正文超过
  40000 字符预算时按楼号顺序截断（末页预留 8000 字符，头部未用完的额度顺延给末页）。
  末页必须保留——长帖的结论、资源与后续进展通常落在末页。
- **截断必须如实写进提示词**：覆盖范围（页区间、层数）与未纳入原因（页数上限 / 长度上限 /
  黑名单）由服务写入「本次覆盖」「说明」两行，并显式要求模型不要推断未纳入部分。
  **不得**在截断后仍声称"已总结全部楼层"。
- **只做取数与组装，不调用模型**：模型调用仍由 `AiChatPage` → `ActiveAiService` 承担，
  与单楼层总结共用同一条通道；本服务不得引入第二条调用路径。
- **单页失败只跳过该页**：任一页请求失败记 warn 并继续，不得让整帖总结失败。
- **「只看楼主」下不复用窗口**：该模式窗口内只有楼主楼层，复用会造成"部分页只有楼主、
  部分页全体"的混口径；此时按空窗口走整帖重新取数。因此 `buildSummaryPrompt` 的
  `windowPosts` / `windowPages` 在只看楼主模式下**必须传空数组**。
- **离线存档不支持**（`ThreadSource.SAVED`）：存档只含已保存页，覆盖范围与"全帖"语义不符。
  菜单项本身就不在存档分支渲染（§6.6 入口说明），`summarizeThread` 内的入参校验是第二道
  防线——两条入口分支都不发起取数。
- **进度浮层是页内浮层，不做全局进度发布**：对比 `savedThreadProgress`（保存帖子由弹窗发起、
  用户可能离开页面），全帖总结只由本页菜单项发起，用户离开页面即整体作废，不存在需要跨页展示
  进度的场景。抓取期间浮层拦截交互，并提供取消入口。
- **任务是模块级单例，必须显式取消**：抓取不随组件销毁结束，`aboutToDisappear` 与切帖
  （`onThreadChanged`）都必须调用 `cancelThreadSummary`，并推进 `summaryGeneration` 使
  在途的进度回调与结束分支全部失效。该代际与分页代际不同源：抓取不参与帖子窗口事务，
  **不得**借用 `mgr.getGeneration()`。

### 6.7 智能去水（更多菜单入口）

「更多」菜单里的「智能去水」抓完全帖楼层、按**本地规则**（不调模型）剔掉灌水回复，
生成一份新的本地帖子（去水版，`archiveId = tid + '-w'`），与原帖的「离线保存」存档在
「保存的帖子」列表里**并列**存放。完整契约见
[`WATER_FILTER_DESIGN.md`](WATER_FILTER_DESIGN.md)，本节只记与帖子页强相关的约束：

- **入口位置与「AI 总结帖子」同组**（`moreMenuItems()` 的非存档分支），排在「离线保存
  帖子」之后。同样**不得**改回标题栏图标。
- **离线存档来源不展示本项**：存档分支只渲染「在线模式打开」。去水版是产出物而非原料，
  对存档再去水没有语义（且存档只含已保存页，覆盖范围与「全帖」不符）。
- **门禁与全帖总结对齐，但不校验 AI 可用性**：去水是纯本地规则，未配置 AI 也应照常可用
  （见 `startWaterFilter` 的注释）。门禁项：未登录 / 已有任务在跑 / `mgr.totalPages < 1` /
  **AI 规则正在生成中**（此时开始会让用户以为用了 AI 规则、实际一条没用上）。
- **AI 规则由本页持有，只对本次生效**：确认框通过 `onAiStateChange` 把规则回传给本页
  （`waterFilterAiRules` / `waterFilterAiGenerating`），发起时与持久化的自定义规则**合并**
  后传给服务。**不落盘**——按帖子主题生成的规则写进全局会在别的帖子上误删
  （见 [WATER_FILTER_DESIGN.md](WATER_FILTER_DESIGN.md) §3.6.1）。
- **每次开框都要清掉上一轮的 AI 规则**（`openWaterFilterDialog` 开头重置）：对话框是新建
  实例，页内字段才是真源；不清就会把上一个帖子的规则静默带进这一次去水。
- **主楼正文在开框时解析一次并缓存**（`resolveOpPlainText` → `waterFilterOpText`）：
  放进 `contentBuilder` 会随对话框每次重绘重复解析；主楼不在当前分页窗口时返回空串，
  此时 AI 只看标题——比不生成规则更保守，不会因此失败。
- **确认框必须写出产出位置**（`SAVE_LOCATION_HINT`，指向「保存的帖子」）：用户点完「开始」
  就离开对话框了，去水版不会出现在本页，不说就找不到产出物。
- **总页数不由本页提供**：`mgr.totalPages` 在「只看楼主」等筛选态下是筛选后的值，只作为
  提示与探测失败时的兜底；抓取范围由服务请求末页自行探测（见去水文档 §5.1）。因此
  **不得**把 `mgr.totalPages` 当作抓取范围传给服务并依赖它。
- **进度走全局发布而不是页内浮层**（与 §6.6 的全帖总结相反）：去水可跑几十分钟，用户一定
  会离开本页，进度必须跨页可见（`WaterFilterProgressIndicator` 挂在 `MainPage`）。
- **`archiveId` 必须随路由透传**：本页读取离线存档时走 `getArchiveId()`，路由未携带时回退
  为 `tid`。同一主题可能并存原帖存档与去水版，只凭 `tid` 会永远打开原帖那一份。
- **任务不随组件销毁结束**：与 `threadSummaryService` 一样是模块级单例（见 §7 对应行）。

## 7. 已知故障模式

| 现象 | 根因 | 正确处理 | 禁止的补丁 |
| --- | --- | --- | --- |
| 首帖被标题遮挡，pid 与页码索引错位 | 顶部伪 `ListItem` 把布局占位混入数据索引 | 使用 `contentStartOffset`，帖子索引保持零基 | 全局 `index +/- 1` |
| 跳页后没有回到页首或目标 pid | `List` 尚未重新挂载时执行滚动 | 保存定位意图，等待 `onAppear` 后下一帧执行 | 增加固定延时或重复滚动 |
| 前插后内容跳动或连续回载多页 | 数据前插期间使用瞬时旧索引继续协调 | pid 锚点事务期间暂停回调和 `reconcile` | 按新增条数猜测新索引 |
| 前插恢复方向相反 | `extraOffset` 符号未同时考虑标题安全区和原 y 坐标 | 使用 `H - anchorOffset` 并在设备上核对 | 叠加经验常量 |
| 标题模糊到首项抵达屏幕顶部才开始 | 把 `currentOffset` 的负起点裁为零 | 使用 `yOffset + contentStartOffset` | 用更激进的透明度曲线掩盖时机错误 |
| 引用跳转后只剩一帖且分页器消失 | 普通整页请求携带 pid，或单帖响应覆盖真实总页数 | 整页请求不带 pid；兜底前保存并恢复总页数 | 把单帖响应当作普通页窗口 |
| 回复成功后旧窗口被静默刷新污染 | 静默刷新响应未校验请求代际 | 提交前比较发起时代际，不一致即丢弃 | 依赖请求返回顺序 |
| 快速跳页后旧页面覆盖新页面 | 旧响应未做请求代际校验 | `REPLACE` 推进代际，提交前比较代际 | 依赖请求返回顺序 |
| 长按识图后选区永不消失：点图直接进查看器、滚动后文本菜单又回来、点正文文字只把菜单临时藏起来 | `Image` 的 AI 分析没有"清除选取"接口，选区随组件存活；系统只在滚动中临时收起菜单 | 会话登记 + 关一次 `enableAnalyzer` 把分析器整体拆掉（§6.5.1） | 组件内自查（覆盖不到别的楼层与列表滚动）、用 `LongPressGesture` 抢长按（会把系统识图一起掐掉） |
| 编辑成功后楼层正文不刷新 | LazyForEach 键值只含 pid，内容变化不改变键值，`onDataChange` 不触发组件更新 | 内容变化时递增 `uiRev`（键值 `pid + uiRev`）重建该楼层；静默刷新返回旧缓存时经 `protectedContent` 跳过覆盖 | 只改 `content` 后 `updateAt`（键值不变不刷新）；整体 `replaceAll` 重建（破坏窗口与滚动） |
| 全帖总结在切帖/返回后仍弹出 AI 页，或把旧帖楼层写进新帖总结 | 抓取任务挂在模块级单例上，不随组件销毁结束；旧帖的在途回调未被失效 | 切帖（`onThreadChanged`）与销毁（`aboutToDisappear`）都调 `cancelThreadSummary`，推进独立的任务代际使在途回调与结束分支全部失效 | 只靠 `summaryBuilding` 布尔值判断（旧任务仍会写状态）；借用 `mgr.getGeneration()` 当代际（抓取不参与窗口事务） |
| 全帖总结内容与帖子实际楼层不符（缺页/夹带未加载页） | 把「只看楼主」的窗口当作整帖复用，混了口径 | 只看楼主模式下传空窗口，按整帖重新取数 | 直接用 `mgr.posts` 组装（该模式只有楼主楼层） |
| 点赞/踩成功后数字与颜色不刷新或整层闪烁 | `PostInfo` 非 `@Observed`，分数内部字段变更不能驱动 LazyForEach；父层投票状态更新还可能用旧 `@Prop post.score` 覆盖动作栏 | `PostVoteBar` 在点击事件内先写入局部 `@State`，失败回滚，成功按本次操作语义确认最终状态；移除点赞状态的旧值 `@Watch` 同步；请求期间屏蔽同楼层重复提交 | 点赞路径递增 `uiRev` 或重建包含图片/正文的 `PostItem` |
| 去水跑完后离开帖子页看不到进度 | 去水可跑几十分钟，用户必然离开本页，页内浮层随组件销毁消失 | 走全局进度发布（`waterFilterProgress` + `MainPage` 上的指示器），与 `savedThreadProgress` 同模式 | 把进度做成本页浮层（对比 §6.6 的全帖总结：那是秒级、只从本页发起） |
| 打开「保存的帖子」里的去水版，看到的却是原帖存档 | 离线读取只按 `tid` 取档，而同一主题并存两份存档 | 路由携带 `archiveId` 并透传到 `ThreadPanel.getArchiveId()`，列表键与删除也一律走 `archiveId` | 给去水版另起一套读取路径（渲染管线会分叉） |
| 去水后的本地帖子楼层数明显偏少 | 把「只看楼主」筛选态下的 `mgr.totalPages` 当作抓取范围 | 服务请求末页自行探测真实总页数，调用方页数只作提示与兜底 | 增加「页数系数」补偿 |
| 换一个帖子去水，却套用了上一个帖子的 AI 规则 | 页内字段（`waterFilterAiRules`）在重开对话框时没清零 | `openWaterFilterDialog` 开头重置；AI 规则**不落盘**，只当次合并 | 把 AI 规则写进持久化自定义规则（会在别的帖子上误删） |

## 8. 诊断与日志

使用：

```shell
hdc shell hilog -x -T ThreadPanel -v time
```

按一次完整交互的时间顺序检查：

| 日志 | 需要核对的事实 |
| --- | --- |
| `page-nav request` | 导航来源、目标页、边界修正和旧窗口 |
| `page-load start/response/commit/end` | 模式、请求页、服务端页、代际、提交窗口和 loading 状态 |
| `page-load stale` | 旧响应是否被正确丢弃 |
| `list lifecycle` | `List` 的卸载、重新挂载和待定位状态 |
| `list-nav prepared/schedule/applied` | 定位意图是否在挂载后执行 |
| `list-nav fallback` | 整页未命中 pid 后是否只发起一次兜底 |
| `quote-jump local` | 已加载目标是否走零请求页内定位 |
| `prepend-anchor prepared/restore/applied` | pid、前后索引、原 y、恢复偏移和代际 |
| `page-edge next/previous` | 哪个可见范围触发了哪一相邻页 |
| `prefetch start/end` | 预取范围是否属于当前代际和窗口两侧 |

不要只看最终页码。大多数滚动故障来自“网络响应、响应式状态、组件挂载、布局完成、滚动回调”之间的先后关系。

## 9. 验证要求

### 9.1 自动验证

- API 26 debug HAP 构建通过。
- `ThreadPaginationUnit.test.ets` 通过，至少覆盖：相邻页提交、非相邻页拒绝、空页推进、pid 去重、双向扩展保持同代际。
- 修改分页管理器时，新增或变更的不变量必须有对应单元测试；仅更新本文不算验证。

### 9.2 设备或模拟器验证

布局与视觉：

- 第 1 页起点的首帖完整位于标题区下方，标题模糊和偏色为零。
- 正文离开起点的第一个滚动增量即开始联动；不等待首项到达屏幕顶部。
- 进入标题区的正文可以辨识，标题底部无明显整块边界；回到起点后效果完全消失。
- 浅色、深色模式下的固定沉浸光感效果均符合第 6.3 节。
- 标题偏色层不影响帖子点击、返回和更多按钮。

分页与定位：

- 从第 1 页和任意中间页进入，向下追加、向上前插均连续。
- 上一页从缓存和网络两条路径提交时，锚点帖子均不跳动。
- 分页器跳到远页后定位页首，再向两侧滚动可继续扩展。
- pid 路由定位正确；同窗引用走页内定位，跨页引用走整页定位。
- 引用页码失效或目标删除时，兜底不循环，分页总数不会被单帖响应永久改写。
- 快速连续跳页时旧响应不会提交。
- 空页、全重复页和不足一整页的末页不会导致无限请求。
- `ThreadNavMode.PAGE` 不触发连续滚动预取和边缘加载。

AI 总结：

- 「更多」菜单里的「AI 总结帖子」可见，且与「收藏夹/离线保存帖子/跟踪帖子更新」同属一组；
  离线存档模式下不出现该项。
- 未配置 AI 或未登录时，「AI 总结帖子」菜单项与动作栏 AI 图标给出同一类提示，不进入抓取。
- 短帖（页数未超上限）全帖总结的覆盖范围写明「全帖 N 页」，层数与帖子实际楼层数一致。
- 长帖（页数超上限）覆盖范围写明取到的页区间与未纳入的页区间，且末页楼层出现在提示词中。
- 抓取期间浮层给出页数进度，取消后立即结束且不跳转 AI 页；返回键退出页面时任务同时终止。
- 「只看楼主」开启时全帖总结仍覆盖整帖楼层（不是只有楼主）。

智能去水：

- 「更多」菜单里的「智能去水」可见，且排在「离线保存帖子」之后；离线存档模式下不出现该项。
- 未登录 / 已有去水任务在跑 / 帖子尚未加载完成时分别给出提示，均不进入抓取。
- 抓取期间全局进度胶囊显示页数与剩余时间，**离开帖子页后进度仍在**；取消后立即停止且不产
  出存档。
- 完成后「保存的帖子」里同时出现原帖存档与带「去水」标签的去水版，两条都能独立打开与删除。
- 去水版标题带「（去水版）」后缀，打开后版式与在线一致（图片、楼中楼、用户组名、楼层号）。
- 「只看楼主」开启时发起去水，抓取范围仍是整帖（不是筛选后的页数）。
- 确认框里能看到产出位置说明；生成 AI 规则期间「开始」被拦；关掉再开框 AI 规则清空
  （不残留上一帖的规则），设置里的自定义规则列表也没多出条目。

编译成功不能证明挂载时序、滚动坐标或设备材质效果正确；涉及这些内容的修改必须执行运行时验证。

## 10. 维护规则

- 修改数据窗口语义：同步更新 `ThreadPaginationManager`、分页单元测试和本文第 4 节。
- 修改列表结构或定位：重新验证所有索引入口、`REPLACE` 定位和前插锚点，不得只验证第 1 页。
- 修改标题高度、状态栏处理或 `contentStartOffset`：同步检查前插恢复公式和标题重叠公式，两者必须使用同一个 `H`。
- 修改 `TitleScrollEffect` 或 `PanelNavBar`：核对所有采用相同覆盖式列表模型的调用方，但不要把 Thread 的坐标假设扩散到不同布局。
- 新增日志应描述事务标识、代际、请求页、服务端页、窗口和 pid；不要依赖无法关联时序的散点文本。
- 修改正文图属性（`draggable` / `objectFit` / `borderRadius` / `aspectRatio` / `enableAnalyzer`）：
  三个面（正文图、`ImageViewer`、主题列表预览图）的"开 / 关"是**产品决策**，不是平台限制；
  `enableAnalyzer` 与 `draggable` 的并存语义见第 6.5 节，改任一项都要重新走一遍该节的真机清单。
- 修改全帖总结的页数/长度上限、截断说明或窗口复用条件：同步更新第 6.6 节与
  `ThreadSummaryService` 的常量，并核对"覆盖范围"文案与实际纳入的楼层一致。
- 移动全帖总结的入口（标题栏按钮 ↔ 菜单项）：同步更新第 6.3 / 6.6 节与第 9.2 节验收项，
  并核对 `summarizeThread` 的门禁仍在入口分支之外独立成立（入口只是触发，不作为唯一校验）。
- 修改智能去水的判定口径、抓取范围、安全阀或存档键：同步更新第 6.7 节与
  [`WATER_FILTER_DESIGN.md`](WATER_FILTER_DESIGN.md)，该方法才是去水的权威设计文档；
  本节只保留「与帖子页强相关」的那几条约束。
- 只有实际产品契约或实现发生变化时才更新“不变量”；历史故障应记录在第 7 节，不应反向改写事实。

## 参考资料

- 华为开发者文档：[沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material)
- 华为开发者文档：[标题栏动态模糊](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-navigation-dynamic-blur)
- 华为开发者文档：[List](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-list)
- 华为开发者文档：[AI 识图](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/vision-imageanalyzer)（图片长按识图的平台能力、约束与设备支持）
- 本仓库调研：[图片长按识图完整方案](research/IMAGE_TEXT_RECOGNITION_GUIDE.md)

官方资料用于确定平台能力和设计方向；`20vp`、`32vp`、最大半径 `16`、颜色资源及具体材质参数均是本项目当前选择，应以仓库代码为准。
