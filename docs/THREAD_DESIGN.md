# Thread 详情页设计说明（给后续 AI）

本文说明帖子详情页最重要的体验目标、分页模型和滚动约束。修改下列文件前，请先完整阅读本文：

- [`ThreadPanel.ets`](../entry/src/main/ets/pages/ThreadPanel.ets)：界面生命周期、滚动、跳页、加载调度与日志。
- [`ThreadPaginationManager.ets`](../entry/src/main/ets/common/managers/ThreadPaginationManager.ets)：连续分页窗口、去重、页码映射与预取缓存。
- [`ThreadPaginationUnit.test.ets`](../entry/src/test/ThreadPaginationUnit.test.ets)：分页管理器的回归测试。

## 一、设计精髓

Thread 不是“每次只展示一页”的普通分页页面，而是一个可以从任意页进入、随后向上和向下连续扩展的帖子流。

必须同时满足以下体验：

1. 标题区固定在屏幕顶部，不参与滚动。
2. `List` 铺满屏幕并位于透明标题区后方；正文初始通过 `contentStartOffset` 规避标题区、两区不重叠，向下滑动后正文向上穿过标题区——此时正文从标题顶部向下渐变模糊，标题层叠加向下透明衰减的主题背景偏色（标题栏本体无整块材质，材质只用于按钮），回顶后渐隐。
3. 首次进入或跳页完成时，目标页的第一个帖子完整出现在标题区下方，不能被遮挡。
4. 向下滚动可以无缝追加下一页，向上滚动可以无缝前插上一页。
5. 使用分页器跳到任意页后，仍然满足第 3、4 点。

这里最容易误解的是第 2、3 点并不冲突：列表需要与标题区重叠，但列表处于起点时又需要保留安全距离。当前使用 `List.contentStartOffset(NAV_BAR_H + statusBarHeight)` 表达这段距离。它只负责列表起点的视觉留白，不会阻止滚动中的内容进入标题区。

不要用一个假的 `ListItem` 作为标题占位，也不要把固定标题栏放进 `List`。这会让视觉元素混入数据索引，最终迫使所有定位代码增加 `+1` 或 `-1`，并与跳页、pid 定位和前插恢复互相冲突。

## 二、职责边界

### `ThreadPanel`

负责 UI 层行为：

- 管理 `List` 是否已经挂载以及 `Scroller` 何时可用。
- 接收普通进入、pid 进入、分页器跳页等导航意图。
- 发起替换、向后追加、向前插入请求。
- 在前插前捕获视觉锚点，在提交后恢复锚点。
- 把分页管理器的结果同步给 `PostInfoDataSource`。
- 输出足以还原异步时序的结构化日志。

### `ThreadPaginationManager`

负责数据层不变量：

- 当前可见数据只能对应一个无空洞的连续页区间 `[loadedPageStart, loadedPageEnd]`。
- `posts[index]` 与 `pageOfIndex[index]` 始终一一对应。
- 只允许与窗口边界相邻的页面进入可见数据。
- 使用稳定的 `pid` 去重，不能用楼层号去重。
- 预取结果可以乱序到达缓存，但不能因此乱序提交。
- `REPLACE` 开启新一代请求；旧一代的异步响应必须失效。

### `PostInfoDataSource`

它是 ArkUI 列表通知层，不是第二套分页状态。分页事实以 `ThreadPaginationManager` 为准，数据源只负责镜像结果并发出增删改通知。

## 三、不可破坏的不变量

### 1. 列表索引始终是零基帖子索引

列表中的第 `0` 项就是管理器中的第 `0` 个帖子。标题栏和顶部安全区都不占用列表索引。

- 普通进入或跳页：定位到索引 `0`。
- pid 进入：直接定位到 pid 对应的帖子索引。
- 计算屏幕中央所在页：直接使用列表中心索引查询 `pageOfIndex`。
- 前插锚点：直接保存和恢复帖子索引或 pid。

如果后续修改中再次出现为了标题栏而添加的全局 `index + 1` 或 `index - 1`，说明布局职责又泄漏进数据索引，应先停下来重新检查设计。

### 2. 可见数据只能是连续页面窗口

假设当前窗口为 `[9, 10]`：

- 只允许提交第 8 页或第 11 页。
- 第 7、12 页即使先返回，也只能缓存。
- 空页面或全部被 pid 去重的相邻页面，仍要推进对应窗口边界，否则同一页会被无限请求。
- 向前、向后加载必须拥有独立的 loading 状态，不能互相阻塞或互相覆盖。

### 3. 替换页面必须等待列表重新挂载

分页器跳页是一次 `REPLACE`，不是普通追加。典型时序为：

1. 记录导航来源与目标页。
2. 进入加载态并创建新的请求代次。
3. 请求返回后替换分页窗口和数据源。
4. 记录待执行的列表定位意图。
5. 退出加载态，让 `List` 重新创建。
6. 等待 `List.onAppear`。
7. 下一帧执行索引 `0` 或目标 pid 的定位。
8. 定位完成后再恢复边缘检测。

不要在 `List` 尚未挂载时直接调用 `scrollToIndex`。调用本身可能不报错，但命令会丢失，随后首次滚动又会触发错误页加载。

### 4. 前插必须是一个锚点事务

向上加载上一页时，列表头部会插入一批新项目。如果只提交数据，当前内容会瞬间下移；如果仅依赖 `maintainVisibleContentPosition`，ArkUI 在布局切换期间仍可能发出短暂的旧索引回调，造成连续误判上一页。

正确流程：

1. 在提交前记录首个可见帖子的 `pid` 和 `getItemRect(index).y`。
2. 标记锚点事务进行中，暂时忽略中间态的滚动回调和边缘协调。
3. 把上一页提交给分页管理器和数据源。
4. 下一帧按 `pid` 在新数组中找到该帖子的新索引。
5. 使用以下偏移恢复它原来的屏幕位置：

   ```text
   contentStartOffset = NAV_BAR_H + statusBarHeight
   restoreOffset = contentStartOffset - anchorOffset
   ```

6. 再下一帧解除事务，并重新进行一次边缘协调。

锚点必须使用 `pid`，因为前插后旧索引已经失效。不要通过猜测新插入了多少项来修正索引。

### 5. 引用跳转（Reply）是"整页请求 + 页内定位"，不是单帖请求

NGA 引用头 `[pid=被引pid,主题tid,被引楼层所在页]Reply[/pid]` 的第 3 值是页码
（lou 永不复用，`page = floor(lou/20) + 1` 稳定，已用真实样本验证）。点击跳转：

- 解析层把第 3 值保留进链接（`#/thread?tid=..&pid=..&page=..`），经
  `Screen.thread(tid, page, pid)` 进入；`threadPage` 即目标页。
- **REPLACE 请求默认不带 pid**：服务端收到 pid 时返回单帖视图
  （`lou=0`、`__PAGE=1`、`__ROWS=1`），页码与楼层信息全部丢失，无法按页加载。
  整页加载后用既有 `prepareListNavigation` 机制在页内按 pid 定位。
- 定位意图 `pendingTargetPid` 只来自路由进入（`aboutToAppear`/`onThreadChanged`），
  定位应用后清除；分页器、只看楼主、回复/编辑后刷新等用户主动 REPLACE 必须先清意图，
  错误页重试保留意图。
- 整页未命中目标 pid 时做**一次**单帖兜底（`singlePostFallback` 防重复）。
  兜底响应的 `totalPages` 会被单帖视图重置为 1，必须用兜底前暂存的真实值恢复
  （`fallbackPrevTotalPages`），否则分页器消失且 `hasNextPage()` 恒假，用户被困在单帖窗口。
- 同帖且目标 pid 已在加载窗口时，`handleLinkClick` 直接页内滚动（日志 `quote-jump local`），
  不触发路由与请求。

## 四、曾经出现的问题及根因

### 首帖被标题区遮挡

为了实现内容穿过毛玻璃的效果，列表本来就与标题区重叠。旧方案又在列表中加入伪占位项，并把所有帖子索引整体偏移一位。多个定位入口没有始终使用相同的补偿规则，导致首帖顶部、pid 定位和显示页码彼此不一致。

解决方式不是取消重叠效果，而是让布局系统通过 `contentStartOffset` 表达初始安全区，并让数据索引回归零基。

### 跳页后定位失效

跳页进入加载态时，旧 `List` 会被卸载。数据返回后如果立即滚动，新的 `List` 还不存在，定位命令会丢失。

解决方式是把“想滚到哪里”保存为导航意图，等新 `List.onAppear` 后再在下一帧应用。

### 跳页后异常回跳或连续加载多页

前插页面会改变所有旧项目的索引，布局阶段还可能发出瞬时的顶部可见索引。若此时继续进行边缘判断，就可能把第 9 页、第 8 页、第 7 页连续当成需要加载，严重时一路回到第 1 页。

解决方式是前插锚点事务：捕获、暂停协调、提交、按 pid 恢复、再释放。请求代次同时负责丢弃跳页前遗留的异步响应。

### 错误的偏移方向

`scrollToIndex(..., ScrollAlign.START, extraOffset)` 的符号很容易凭感觉写反。当前恢复公式已经同时考虑原始屏幕位置和 `contentStartOffset`。修改偏移前必须用真机或模拟器观察目标帖子的实际 y 坐标，不要继续叠加经验常量。

## 五、调试日志

建议使用：

```shell
hdc shell hilog -x -T ThreadPanel -v time
```

重点按一次完整交互追踪这些日志：

- `page-nav request`：导航来源、目标页、pid。
- `page-load start/response/commit/end`：请求代次、模式、请求页和提交窗口。
- `list lifecycle`：列表何时挂载或卸载。
- `list-nav prepared/schedule/applied`：跳页定位意图何时真正应用。
- `list-nav fallback`：整页未命中后发起单帖兜底（含 pid 与引用页）。
- `quote-jump local`：引用目标已在加载窗口，页内直接定位。
- `prepend-anchor prepared/restore/applied`：前插前后的 pid、索引和 y 偏移。
- `page-edge next/previous`：哪次滚动判断触发了相邻页加载。

调试时要看事件顺序，而不是只看最后页码。大多数历史问题都来自“数据响应、组件挂载、布局完成、滚动回调”四者的时序冲突。

## 六、回归检查清单

任何涉及 Thread 布局、分页或滚动的修改至少验证：

- 首次进入第 1 页，首帖完整位于固定标题区下方。
- 渐变模糊与主题偏色仅在正文滚动进入标题区后渐显；页面位于顶部时隐藏，首帖不被遮挡。
- 向上滚动内容时，内容能穿过透明标题区，模糊与偏色向正文自然衰减，标题底部没有分割线或明显区域边界，回顶后完全渐隐。
- 连续向下滚动可逐页追加，无闪烁、无回跳。
- 从非第 1 页进入后向上滚动，上一页前插时当前帖子不跳动。
- 分页器跳到较远页面后，目标页顶部定位正确。
- 跳页后继续向上、向下滚动，两侧都能正常加载。
- pid 路由进入时目标帖子定位正确。
- 点击引用（Reply）：目标楼已在窗口 → 页内定位；跨页 → 按引用头页码加载整页并定位到目标楼。
- 引用头页码过期或楼层被删 → 单帖兜底后仍可向下翻页（`totalPages` 已恢复），分页器可用。
- 快速连续跳页时，旧响应不会覆盖新页面。
- 相邻页为空或内容全部重复时，不会无限重复请求。
- 最后一页不足一整页时，不会误判或重复追加。
- 传统单页模式 `ThreadNavMode.PAGE` 不受连续滚动逻辑影响。

验证应包含构建、分页单元测试和模拟器实际滚动。仅通过编译不足以证明异步时序正确。

## 七、给后续 AI 的留言

请把这个页面当作“连续数据窗口 + 固定覆盖层 + 异步滚动事务”，不要当作普通分页列表。

遇到新问题时，先用日志确定它属于数据窗口、组件生命周期、布局坐标还是滚动回调，再修改对应层。不要用延时常量、全局索引补偿或重复滚动命令掩盖时序问题；这些修补通常会解决一个入口，却破坏跳页后的另一条路径。

保留视觉设计本身：标题区必须固定，列表必须能够穿过透明标题区（无常驻整块毛玻璃背板，可读性由滚动联动的小模糊与同色偏色背板保障）。真正要隔离的是“初始安全距离”和“数据索引”，不是标题与列表的视觉重叠。

如果设计不变量发生变化，请同步更新本文和回归测试，让下一位开发者能从仓库中直接理解新的事实。

## 八、标题区视觉层（官方沉浸光感适配，2026-08）

实现依据是华为官方的[沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material)与[标题栏动态模糊](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-navigation-dynamic-blur)指南。项目保留自定义路由和 `PanelNavBar`，但视觉语义与 HDS 标题栏一致；全部改动都是纯视觉，不触碰本章任何数据不变量：

- **系统材质只用于可操作按钮**：返回、更多等按钮为 36×36 圆形光感底板，使用 API 26 `systemMaterial` 与 `UIMaterialManager.fabMaterial`（ULTRA_THIN、interactive、lightEffect）；标题栏本体不再使用 `titleBarMaterial`。沉浸光感关闭时，按钮回退到 `AppColors.frostGlass` 圆底，标题区回退到原有 `frostGlassStrong` 背板。
- **正文采用官方 `GRADIENT_BLUR` 语义**：均匀模糊和分割线会强化标题区的矩形边界，因此滚动列表使用 `List.linearGradientBlur` 直接处理进入标题下方的正文。标题区内保持最大模糊，标题底部以下 `TITLE_BLUR_FADE_DISTANCE`（32vp）连续衰减到零，完全生效时最大半径为 `TITLE_BLUR_RADIUS`（16）。
- 正文初始通过 `contentStartOffset` 规避标题区；开始滚动后，渐变模糊随滚动进度增强。标题层只负责 `title_backdrop_tint` 到 `title_backdrop_clear` 的同色透明渐变，并向标题底部以下延伸 32vp；不再使用均匀 `backgroundBlurStyle` 或底部分割线，因此不会形成独立标题块。
- 联动状态 `titleScrollEffectProgress` 使用 `scroller.currentOffset().yOffset` 与 `contentStartOffset` 共同计算。`List` 位于起点时，其绝对偏移为 `-contentStartOffset`，首项到达屏幕顶部时才为 `0`；因此正文侵入标题区的真实距离是 `yOffset + contentStartOffset`。官方示例的生效区间为 0–20vp，这里使用 `clamp((yOffset + contentStartOffset) / TITLE_SCROLL_EFFECT_DISTANCE, 0, 1)`；`onDidScroll` 每帧同步，`List.onAppear` 重新校准，REPLACE 加载开始时归零。
- 原始滚动进度只表达正文与标题区开始重叠后的几何距离；背景偏色透明度与正文模糊半径均使用线性映射，避免用视觉曲线掩盖坐标误差。起点回弹时进度保持为零，正文开始越过初始安全区后效果立即连续生效。
- 渐变偏色层使用 `hitTestBehavior(HitTestMode.None)`，不会拦截下方帖子交互；视觉效果不占列表索引，也不改变 `contentStartOffset` / `restoreOffset` 公式，两者继续共用 `NAV_BAR_H`。
- 页面位于顶部时渐变模糊与偏色均隐藏，首帖完整可见性不受影响，与第六节回归清单第 1 条一致。

材质参数由 `UIMaterialManager` 静态单例一次性确定，不逐列表项创建材质。标题区的滚动进度、起始避让、模糊半径和渐变停靠点统一由 `TitleScrollEffect` 计算，避免页面之间出现视觉参数漂移。`PanelNavBar` 默认 `scrollEffectProgress=0`；Thread、主题列表、通知、私信、浏览历史、收藏夹、黑名单、关键词屏蔽和用户备注页传入各自列表的实时滚动进度，静态表单和 WebView 等不符合覆盖式列表模型的页面仍保持原有布局。
