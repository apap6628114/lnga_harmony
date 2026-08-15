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
  窗口内页按 pid 原地替换内容；未见过的新 pid 仅当该页是"窗口末页且服务端
  总页数未增长"时追加到窗口末尾；`E + 1` 页整页追加并推进窗口。`mergePage`
  不调用 `reset()`，不推进请求代际，也不改变 `S`；提交前调用方必须校验代际。

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
  再发起静默刷新：刚提交后 read.php/CDN 缓存可能未失效，乐观更新保证用户
  第一时间看到新正文，最终以服务端刷新内容为准覆盖。
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

- 返回、更多等标题操作按钮使用 36×36 圆形 `UIMaterialManager.fabMaterial`。
- 右侧存在两个操作按钮时，按钮之间固定保留 `8vp` 间距。
- `fabMaterial` 当前为 `ImmersiveStyle.ULTRA_THIN`，启用 `interactive` 和 `lightEffect`。
- 标题操作必须使用语义明确的独立 SVG 资源，不在标题栏中混用文字操作；视觉图标与无障碍名称分别由 `rightIcon` 和 `rightIconAccessibilityText` 提供。
- 标题栏本体不使用整块 `systemMaterial`；正文模糊由 `List` 承担，标题可读性由颜色渐变层承担。
- 不绘制用于强调标题底边的常驻分割线，避免形成独立矩形区域。
- 输入框、主操作按钮和浮层分别直接使用 `inputMaterial`、`buttonMaterial` 和 `surfaceMaterial`；组件不得保存材质启用状态，也不得按持久化设置切换 `systemMaterial`。

### 6.4 共享实现的适用条件

`TitleScrollEffect` 和 `PanelNavBar` 是共享实现，不是 Thread 专用视觉副本。页面直接复用时必须同时满足：

1. 正文由可取得绝对偏移的 ArkUI `List` 或 `Scroll` 承载。
2. 标题栏固定覆盖在正文视口顶部，正文容器占满标题栏后方的可用视口。
3. 初始避让使用同一个 `contentStartOffset = H`，不得通过标题占位行或伪数据项实现。
4. 模糊只作用于正文容器，标题偏色只由 `PanelNavBar.scrollEffectProgress` 控制。

当前 `SettingsPanel`、`ProfilePanel`、`FontSizeSettingsPanel`、`TtsSettingsPanel`、`AiSettingsPanel`、`AiChatPage` 和 `MessageDetailPanel` 已按上述条件调整布局并复用相同模型。`MessageDetailPanel` 自己持有标题栏和列表滚动状态；路由容器不得替它代持标题栏，否则无法建立可靠的滚动联动。

`WebViewPanel` 不满足第 1、3 项：`Web` 可报告网页滚动位置，但没有与 ArkUI `contentStartOffset` 等价且不修改网页文档的能力。因此该页面保留非重叠的静态标题布局，并由页面根节点绘制不透明 `AppColors.bg`，避免网页加载或透明区域暴露活动栈下层内容。不得为了表面一致向任意网页注入顶部 DOM/CSS，也不得未经约束切换为 `FIT_CONTENT` 后放入外层 `Scroll`；这两种做法分别会改变网页布局语义，或引入页面高度与无限加载限制。

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

编译成功不能证明挂载时序、滚动坐标或设备材质效果正确；涉及这些内容的修改必须执行运行时验证。

## 10. 维护规则

- 修改数据窗口语义：同步更新 `ThreadPaginationManager`、分页单元测试和本文第 4 节。
- 修改列表结构或定位：重新验证所有索引入口、`REPLACE` 定位和前插锚点，不得只验证第 1 页。
- 修改标题高度、状态栏处理或 `contentStartOffset`：同步检查前插恢复公式和标题重叠公式，两者必须使用同一个 `H`。
- 修改 `TitleScrollEffect` 或 `PanelNavBar`：核对所有采用相同覆盖式列表模型的调用方，但不要把 Thread 的坐标假设扩散到不同布局。
- 新增日志应描述事务标识、代际、请求页、服务端页、窗口和 pid；不要依赖无法关联时序的散点文本。
- 只有实际产品契约或实现发生变化时才更新“不变量”；历史故障应记录在第 7 节，不应反向改写事实。

## 参考资料

- 华为开发者文档：[沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material)
- 华为开发者文档：[标题栏动态模糊](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-navigation-dynamic-blur)
- 华为开发者文档：[List](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-container-list)

官方资料用于确定平台能力和设计方向；`20vp`、`32vp`、最大半径 `16`、颜色资源及具体材质参数均是本项目当前选择，应以仓库代码为准。
