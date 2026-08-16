# 标题区与列表沉浸联动设计（Title & List Immersive Design）

本文档记录 nga_oh 中"固定标题区 + 可滚动列表"的联合设计契约：标题区与列表如何共同实现
"内容穿越标题区"的沉浸表现，包含设计目的、实现方法、复用约定、踩坑记录与故障排查。
适用于所有使用 `PanelNavBar` + 列表的面板（帖子列表、通知页、帖子详情、私信、设置等），
新页面接入时应以本文为契约，**以 `TopicListPanel` 为视觉范本**。

---

## 1. 设计目的

传统"不透明标题条 + 底部分割线 + 下方列表"会把一屏内容割裂成两块贴片，破坏沉浸感。
本项目采用**标题区与正文同一连续表面**的视觉语言：

- 列表内容初始**避让**标题区（首屏不遮挡标题与操作按钮）；
- 滚动时内容**上移侵入**标题区（内容"穿"到标题后面）；
- 侵入区域通过**渐变模糊 + 主题同色压暗**与标题区融合，避免"内容与标题生硬重叠"的边界；
- 标题区**不随内容滚动**（固定操作位：返回/标题/右侧按钮始终可达），但通过
  `scrollEffectProgress` 与列表滚动**联动**（压暗/模糊随滚动渐进出现）。

一句话：**标题区是固定玻璃，列表是下面的连续表面，滚动时表面穿进玻璃，玻璃逐渐"起雾 + 压暗"**
以保持可读性。筛选条/排序条等次级操作区作为列表首元素，与正文一起穿越，而非钉在标题栏内。

---

## 2. 总体架构：三层协作

| 层 | 组件/模块 | 职责 |
| --- | --- | --- |
| 固定标题层 | `common/components/PanelNavBar.ets` | 返回/标题/右侧操作；滚动时叠加 `title_backdrop_tint` 渐变压暗层 |
| 滚动内容层 | 各面板的 `List` | `contentStartOffset` 避让起始；`linearGradientBlur` 渐变模糊；筛选条/排序条作为首元素 |
| 联动计算层 | `common/utils/TitleScrollEffect.ets` | 滚动偏移 → 0~1 进度；模糊停靠点；压暗透明度；标题区高度常量 |

页面骨架（范本，见 `TopicListPanel.build`）：

```
Stack {
  Column { List { 筛选条 ListItem; 状态/数据 ListItem; 底部加载 ListItem } .属性链... }
    .width('100%').height('100%')
  PanelNavBar({ title, scrollEffectProgress, rightIcon, ... })
    .width('100%').position({ x: 0, y: 0 })   // 覆盖在列表上方，固定
}
.width('100%').height('100%').backgroundColor(AppColors.bg)  // 页面底色在 List 层之下
```

---

## 3. 实现方法

### 3.1 避让起点：`List.contentStartOffset`

```typescript
.contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
// = statusBarHeight + NAV_BAR_H (44vp)
```

让列表内容（含筛选条）从标题区下方起始，首屏与标题区互不遮挡。
标题区自身透明（`PanelNavBar` 无整体背景），页面底色统一为 Stack 的 `AppColors.bg`。

### 3.2 滚动侵入与进度换算：`TitleScrollEffect.getProgress`

```typescript
// 面板内：
private syncTitleScrollEffect(): void {
  const progress = TitleScrollEffect.getProgress(this.scroller.currentOffset().yOffset, this.statusBarHeight)
  if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
    this.titleScrollEffectProgress = progress
  }
}
// 挂载：.onDidScroll(() => this.syncTitleScrollEffect()).onAppear(() => this.syncTitleScrollEffect())
```

`getProgress` 的关键：**`contentStartOffset` 使列表起点的绝对滚动偏移为其相反数（负值）**，
因此"内容实际侵入标题区的距离 = offsetY + contentStartOffset"，再除以
`TITLE_SCROLL_EFFECT_DISTANCE`(20vp) 得 0~1 进度（clamp）。

```typescript
static getProgress(offsetY: number, statusBarHeight: number, contentStartOffset?: number): number {
  const start = contentStartOffset ?? TitleScrollEffect.getContentStartOffset(statusBarHeight)
  const overlapDistance = Math.max(offsetY + start, 0)
  return Math.min(overlapDistance / TITLE_SCROLL_EFFECT_DISTANCE, 1)
}
```

`shouldUpdateProgress` 只在 0/1 或差值 ≥0.001 时写入响应式状态，避免高频滚动刷 UI。

### 3.3 视觉融合：渐变模糊 + 渐变压暗

**内容层**——`List.linearGradientBlur`（API 26 渲染层模糊）：

```typescript
.linearGradientBlur(
  TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),   // TITLE_BLUR_RADIUS(16) * progress
  {
    fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
    direction: GradientDirection.Bottom
  }
)
```

`getBlurStops`：标题区内最大模糊(1)，标题底部向下 `TITLE_BLUR_FADE_DISTANCE`(32vp) 连续衰减到 0：

```
[ [1, 0], [1, titleEnd], [0, fadeEnd], [0, 1] ]
```

**标题层**——`PanelNavBar` 渐变压暗（`scrollEffectProgress > 0` 时出现）：

- 高度 `statusBarHeight + NAV_BAR_H + TITLE_BLUR_FADE_DISTANCE`，向下线性渐变：
  `title_backdrop_tint`（30% bg 同色，如 base `#4DFEFAF6`）实色到 `statusBarHeight+NAV_BAR_H` 处，
  之后 32vp 内衰减到 `title_backdrop_clear`（`#00FEFAF6` 全透明）；
- 整体 `opacity = getBackdropOpacity(progress)`（=progress）；
- `hitTestBehavior(HitTestMode.None)`，纯视觉层不拦截触摸。

**融合原理**：压暗是"bg 压 bg"（30% bg 同色半透明），模糊衰减距离与压暗衰减距离同为 32vp，
滚动时标题区内外底色恒一、连续渐变，无硬边界。

### 3.4 筛选条/排序条作为列表首元素（SegmentButton）

帖子列表排序条 / 通知页"消息-动态"筛选条，均为 `List` 第一个 `ListItem`：

```typescript
ListItem() {
  Row() {
    SegmentButton({ options, selectedIndexes: $selected, onItemClicked })
  }
  .width('100%')
  .padding({ left: '4%', right: '4%' })
  .margin({ top: 8, bottom: 6 })
  .onAreaChange((_o, n) => { this.sortBarBottomY = n.globalPosition.y + n.height })  // 采集底部坐标
}
```

- 随列表滚动**穿越标题区**（不是钉在标题栏内的固定 tab）；
- `onAreaChange` 采集筛选条底部全局纵坐标 `sortBarBottomY`，供状态视图精确撑满；
- SegmentButton 参数契约（与 `TopicListPanel.sortOptions` 完全一致）：

| 参数 | 值 |
| --- | --- |
| `multiply` | `false` |
| `fontColor` | `AppColors.textSecondary` |
| `selectedFontColor` | `AppColors.primary` |
| `fontSize` / `selectedFontSize` | `13` / `13` |
| `fontWeight` / `selectedFontWeight` | `Normal` / `Bold` |
| `backgroundColor` / `selectedBackgroundColor` | `AppColors.bgSecondary` / `AppColors.primaryLight` |

### 3.5 状态视图撑满：`sortBarBottomY` + `getStateViewHeight`

加载/错误/空态作为 `ListItem{ Column{ LoadingStateView / ErrorStateView / EmptyStateView } }`，
高度 = 筛选条下方可视区：

```typescript
private getStateViewHeight(): number {
  const topOffset = this.sortBarBottomY > 0
    ? this.sortBarBottomY
    : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50   // 首帧兜底
  return Math.max(this.listViewportHeight - topOffset, 400)                // 下限 400
}
```

状态切换过渡：`.transition(TransitionEffect.OPACITY.animation({ duration: 200 }))`。

### 3.6 List 属性链契约（范本逐项）

```
.width('100%').layoutWeight(1)
.scrollBar(BarState.Off)
.divider({ strokeWidth: 0.5, color: AppColors.separator })
.lanes(new BreakpointType(1, 1, 1).getValue(this.currentBreakpoint), 12)
.edgeEffect(EdgeEffect.Spring)
.cachedCount(3)
.contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
.linearGradientBlur(...)                    // 见 3.3
.onAreaChange(采集 listViewportHeight)       // 首帧 1 → 实际视口高
.onDidScroll(syncTitleScrollEffect)
.onAppear(syncTitleScrollEffect)
.onScrollIndex(分页预加载 / 其他)
```

> `listViewportHeight` 初始为 1，`onAreaChange` 更新；`getBlurStops` 内部对极小视口做了下限保护。

---

## 4. 关键常量与资源

| 常量（`common/constants/Constants.ets`） | 值 | 用途 |
| --- | --- | --- |
| `NAV_BAR_H` | 44 | 标题栏高度 |
| `TITLE_SCROLL_EFFECT_DISTANCE` | 20 | 进度 0→1 的滚动距离 |
| `TITLE_BLUR_FADE_DISTANCE` | 32 | 模糊/压暗衰减距离（二者必须一致） |
| `TITLE_BLUR_RADIUS` | 16 | 最大模糊半径 |
| `TITLE_ACTION_BUTTON_GAP` | 8 | 标题栏右侧按钮间距 |

| 资源（`resources/{base,dark}/element/color.json`） | 值（base） | 用途 |
| --- | --- | --- |
| `title_backdrop_tint` | `#4DFEFAF6` | 30% bg 同色压暗（滚动后标题区） |
| `title_backdrop_clear` | `#00FEFAF6` | 压暗层衰减末端（全透明） |
| `bg` | `#FEFAF6` | 页面底色（列表层之下） |

---

## 5. 需注意的细节（坑点清单）

1. **列表项背景必须透明**（最大坑，见 6.1）：内容行**不得**设置不透明 `backgroundColor`；
   底色统一由页面 Stack 提供。实色行会让 `linearGradientBlur` 在行边缘产生"化开的过渡带"，
   在标题区下缘衰减到 0 处突然恢复锐利 → 标题区与列表之间出现颜色跳变色带。
2. **getProgress 的负偏移**：`contentStartOffset` 使初始偏移为负，进度换算必须"加回同一份避让距离"。
3. **衰减距离一致**：模糊衰减（`getBlurStops`）与压暗衰减（PanelNavBar 渐变）必须同为
   `TITLE_BLUR_FADE_DISTANCE`，否则标题区下缘出现断裂。
4. **`listViewportHeight` 首帧为 1**：`getBlurStops` 依赖真实视口高，`onAreaChange` 必须在首帧后
   尽快更新；状态视图高度用 `sortBarBottomY` 实测，首帧兜底 `contentStartOffset + 50`、下限 400，
   避免高度跳变。
5. **加载/切页时 `titleScrollEffectProgress` 归零**：否则旧进度残留在新内容上（标题区提前压暗）。
6. **已读/局部状态更新用 `updateAt` 局部刷新**，不要 `replaceAll` 整体重建列表（会打断滚动、
   闪屏）；轮询增量同步用 `prependAll` 语义（旧列表是缓存后缀时仅插头部新增，见 6.3）。
7. **切 tab/切换数据源后回顶**：`setTimeout(0)` 后 `scroller.scrollEdge(Edge.Top)`（内容已重建，
   立即调用可能无效）。
8. **沉浸光感（IMMERSIVE_LIGHT_DESIGN.md）**：`SegmentButton.fontColor` 属 colorInvert 白名单属性，
   不得用硬编码色值；任何 `systemMaterial` 组件不得叠加不透明背景色；`systemMaterial` 必须放在
   其他样式属性之后。
9. **`maintainVisibleContentPosition(true)` 仅用于帖子详情前插场景**（ThreadPanel），
   列表面板（帖子列表/通知页）不要加——它可能干扰数据替换后的滚动位置（见 6.2）。
10. **分页预加载阈值**：列表含筛选条占位（索引 0）时，数据项索引 = 列表索引 - 1；
    触发阈值应等价于无筛选条范本的"距尾部 N 项"（如 `endIndex >= total - 2` ≈ `end - 1 >= total - 3`）。

---

## 6. 遇到的问题与解决记录

### 6.1 【严重】标题区与列表之间的颜色跳变（2026-02）

- **现象**：通知页（NotificationPanel）滚动时，标题区与列表之间存在一条"视觉极为割裂"的
  颜色跳变色带；完全模仿帖子列表（TopicListPanel）不会出现。
- **根因**：通知行/动态行 Row 设置了 `.backgroundColor(AppColors.bg)`（**不透明实色**），
  而帖子列表卡片 `TopicCardComponent` 是**透明的**（露页面底色）。`linearGradientBlur` 模糊的是
  **List 渲染层内容**：实色行把整块不透明色块带进渲染层，模糊作用在色块边缘
  （行间 0.5vp divider、行与筛选条/视口顶边的边界）形成"被化开的过渡带"；
  标题区下缘模糊衰减到 0 处过渡带突然恢复锐利，叠加 `title_backdrop_tint` 压暗 → 硬边界/色带。
- **教训**：视觉层问题不能凭"颜色值相等"（行 bg == 页面 bg）或"结构同构"判断，
  必须按**渲染层级**建模——什么在模糊层内、什么在模糊层下、边缘与衰减终点在哪。
- **修复**：删除通知行/动态行两处 `.backgroundColor(AppColors.bg)`，行回归透明；
  底色恒为 Stack 的 `AppColors.bg`（在 List 层之下、不受模糊影响），标题区内外底色恒一、
  压暗与模糊同 32vp 连续衰减 → 无缝融合。divider 由 List 容器绘制、独立于行背景，仍可见。

### 6.2 maintainVisibleContentPosition 的误用

- 曾在通知页 List 上添加 `.maintainVisibleContentPosition(true)`（ThreadPanel 帖子前插特性），
  意图改善轮询头部插入时的滚动保持。实际列表面板（双 tab 切换 replaceAll）不需要该属性，
  且可能干扰数据替换后的滚动位置 → **已移除**，严格对齐帖子列表范本。

### 6.3 轮询增量同步与滚动打断

- 动态数据轮询合并若"无新数据也发布版本信号"，会导致列表每 60s 重建、打断用户滚动；
- 已实现：Store 仅在**内容变化**（出现新 id）时 bump `activityVersion`；
  面板同步时旧列表是缓存后缀则 `prependAll` 增量插入，否则整体替换；
- 已读变化只更新未读数（`updateAt` 局部刷新），**不 bump 版本信号**。

### 6.4 状态视图高度跳变

- 早期用固定估算值（`-52`、下限 120）导致状态视图与筛选条下方可视区不吻合、切换抖动；
- 已改为帖子列表同款算法：实测 `sortBarBottomY`（`globalPosition.y + height`），
  首帧兜底 `contentStartOffset + 50`，下限 400。

---

## 7. 页面使用现状

| 页面 | 标题区 | 列表首元素 | 备注 |
| --- | --- | --- | --- |
| `TopicListPanel`（帖子列表） | PanelNavBar（board 名 + bell 角标 + more） | 排序条 SegmentButton | **视觉范本** |
| `NotificationPanel`（通知页） | PanelNavBar（"通知" + 全部已读） | 消息/动态筛选条 SegmentButton | 双 tab，行透明 |
| `ThreadPanel`（帖子详情） | PanelNavBar（帖子标题 + more） | 无（直接帖子列表） | 另用 `maintainVisibleContentPosition`、`cachedCount(6)` |
| `MessageListPanel` / `MessageDetailPanel` / `SettingsPanel` 等 | PanelNavBar + `scrollEffectProgress` | 无 | 通用标题区 + 联动 |

新面板接入模板：复制 `TopicListPanel` 的骨架（Stack{Column{List}, PanelNavBar}）、
List 属性链、`syncTitleScrollEffect`、`getStateViewHeight`，再替换业务列表项。

---

## 8. 相关文件

| 文件 | 角色 |
| --- | --- |
| `entry/src/main/ets/common/components/PanelNavBar.ets` | 通用标题区（压暗层、iconPod 材质按钮） |
| `entry/src/main/ets/common/utils/TitleScrollEffect.ets` | 进度/模糊/高度计算 |
| `entry/src/main/ets/common/constants/Constants.ets` | `NAV_BAR_H`、`TITLE_*`、`AppColors` |
| `entry/src/main/ets/pages/TopicListPanel.ets` | 视觉范本（排序条 + 状态视图 + 属性链） |
| `entry/src/main/ets/pages/NotificationPanel.ets` | 双 tab 通知页（本设计的第二个完整实例） |
| `entry/src/main/ets/pages/ThreadPanel.ets` | 帖子详情变体（前插锚点 + maintainVisibleContentPosition） |
| `resources/{base,dark}/element/color.json` | `title_backdrop_tint/clear`、`bg`、`bg_secondary` 等 |
| `docs/IMMERSIVE_LIGHT_DESIGN.md` | 沉浸光感/材质/反色约束（与标题区视觉强相关，先读） |
