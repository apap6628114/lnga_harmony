# 帖子两层递进树 — 精确代码接入地图

> 调研对象：`C:\Users\ll\Desktop\nga_oh`（NGA 论坛鸿蒙客户端，ArkUI/ArkTS，API 26 0.0，单 entry 模块）
> 目的：为「ThreadPanel 新增帖子两层递进树阅读模式」产出可直接照做的接入点清单，避免实现者反复试错。
> 纪律：本次只读源码、未修改任何源码；所有行号以当前工作区文件为准（ThreadPanel.ets 共 3090 行、SettingsPanel.ets 共 862 行、PostItem.ets 共 217 行）。
> 结论均来自源码，不含平台记忆推断。

---

## 0. 一句话结论（先看这 10 条）

1. **设置字段是一条 6 段的固定流水线**：`SettingsState` 字段 → 域 store（`ReadingSettings`）setter + `load()` → `SettingsStore` 门面转发 + `loadUserSettings()` 里的 AppStorage 同步 → `AppStorageKeys` 常量 → `Constants` 枚举类 → `SettingsPanel` 的 `SettingPickerRow + SelectDialog`。新增一个字符串枚举字段要改 **6 个文件**，缺一不可（详见 §1.2）。
2. 设置持久化是**整个 `SettingsState` 整体 `putJSON`**（`SettingsStore.ets:135-144`），所以新增字段**不需要**改 `PersistenceCatalog`（`PersistenceCatalog.ets:74-78` 里 settings 域是一个整体 payload）与数据导入合并（`DomainMergers.ets:179-241` 对本机字段做基、标量字段整体覆盖，新字段自动兼容）；但如果新字段是**数组**且要按业务键并集，才需要登记 `SETTINGS_ARRAY_KEY_FIELDS`（`DomainMergers.ets:42-54`）。
3. **标题区更多菜单的「切换项」模式已有现成样板**：`NavBarMenuItem.active` 只表示「用主题色文字表达激活态」，不占系统选中图标位（`PanelNavBar.ets:27-34`、`253-263`）；「只看楼主」就是单项 active 切换的活例（`ThreadPanel.ets:2709-2719`）。
4. ThreadPanel 是**连续分页窗口**（`ThreadPaginationManager` 是帖子数组与页窗口的**唯一事实来源**，`docs/THREAD_DESIGN.md:56-61`）。树模式「一次性抓全帖」**不要**把全量 posts 硬塞进 `mgr.replaceWith()`（那会把 `loadedPageEnd` 停在 1 却让 `posts` 含全部楼层，直接破坏 `docs/THREAD_DESIGN.md:67-86` 的不变量）；建议树模式使用**独立数据源 + 独立 List + 独立数据结构**，或走「逐页相邻 append」的合规路径（不推荐，见 §7.4）。
5. **「一次性抓全帖所有页 + 进度 + 取消 + 节流」已有完整可抄范式**：`SavedThreadService.saveThread()`（`SavedThreadService.ets:70-171`），逐页 `fetchThreadRaw` → `fillThreadResult` 校验 → 300ms 页间节流（`:26`）→ `savedThreadProgress.show(percent, label)` → 用户可 `cancel()` → `finally { hide() }`。树模式的抓取服务应照此写，但**不要写存档**（那一步是 `savedThreadStore.save`）。
6. **进度提示有 4 种现成范式**：轮询式全局指示器 `TtsProgressIndicator`（无取消）/ `SavedThreadProgressIndicator`（带「取消」，会拦截自身点击）/ `PidLocateIndicator`（`n/m` 步数文案，`PidLocateIndicator.ets:59-61`），以及 ThreadPanel 内的 `LoadingState()` + `loadingContentOpacity` 400ms 延迟淡入（`ThreadPanel.ets:1330-1339`、`3046-3055`）。进度状态用「全局单例 + 轮询 150ms」解耦，动画在组件侧（`PidLocateProgress.ets:31-81` 带代际接管，防连点串台）。
7. **`PostItem` 是编排层、子组件已拆干净**（`PostItem.ets:24-69`）：`PostItemHeader` / `PostAttachments` / `PostVoteBar` / `PostPoll` / `PostComments` / `HotRepliesSection` 都能在树节点组件里单独复用；它们全部是 `@Prop post: PostInfo` + 普通箭头回调（ArkTS 禁止 `@Prop` 传函数），签名见 §3.2。**`BBCodeContentView` 的 `nodes` 是普通字段（不是 @State/@Prop）**（`BBCodeContentView.ets:131`），内容变了不会自己刷新——树节点必须靠 LazyForEach 键值重建。
8. **引用关系提取不需要从零写**：`QuoteInjectionCore.ets` 里已有两条权威正则——Reply to 头 `P_REPLY_HEADER`（`:17`）与引用 pid 头 `P_QUOTE_HEADER`（`:20`）；但该文件是 **TS 镜像真源**（`tools/bbcode-ts/src/common/utils/QuoteInjectionCore.ts`），**禁止直接改入口 `.ets`**，树构建器应新写（新文件只要不在镜像清单里就安全，见 §5.4）。
9. **LazyForEach 刷新只认键值**：楼层键值是 `String(pid) + '_' + String(uiRev)`（`ThreadPanel.ets:2558`），内容变化必须递增 `uiRev`（`PostInfo.ets:29-34`、`ThreadPaginationManager.ets:321-323`）；侧边栏分组给出的「版本号进键值」范式是 `${id}_${collapsed}_${rev}`（`CommunityPanel.ets:217`），树节点的「展开/折叠」状态必须同样进键值。
10. **阅读进度记录与树模式天然冲突**：记录锚点是 `onScrollIndex` 的**中心楼层数组下标** → `mgr.getDisplayPage(anchorIndex)`（`ThreadPanel.ets:576-587`、`2624-2627`），恢复用 `mgr.findPostIndex(pid)` + `scrollToIndex`（`:787-795`、`691-699`）。树的节点顺序 ≠ 楼层顺序，若复用 `mgr`/`posts`，进度语义会被打乱；必须显式定义「树模式是否记录进度」（建议：树模式暂停记录，或把锚点改为「节点列表里的 pid 下标」）。

---

## 1. 设置持久化完整链路（以 `threadNavMode` / `showSignature` / `recordReadingProgress` 为例）

### 1.1 链路总览（新增字段必须逐段落地）

```text
[1] SettingsState 字段（含默认值）
        │
        ▼
[2] 域子 store（ReadingSettings）          ← setter 改 state + ctx.persist()；load(saved) 做 `!== undefined` 判空
        │
        ▼
[3] SettingsStore（门面）                  ← 转发 setter；loadUserSettings() 里按需 AppStorage.setOrCreate
        │
        ├──► [4] AppStorageKeys 常量（仅需跨组件响应式时才加）
        │
        ▼
[5] Constants 枚举类（字符串常量集合，参考 ThreadNavMode）
        │
        ▼
[6] SettingsPanel UI（SettingPickerRow + SelectDialog + badge @State）
```

### 1.2 逐文件改动清单（一个字符串枚举字段的完整 checklist）

| # | 文件:行号 | 现状（可直接照抄的模式） | 新增字段要做什么 |
|---|---|---|---|
| 1 | `entry/src/main/ets/store/settings/SettingsState.ets:19-20` | `@Observed export class SettingsState`，所有字段平铺、带默认值 | 加字段，例如 `threadRenderMode: string = ThreadRenderMode.LIST`（默认值必须写在这里，`reset()` 用 `new SettingsState()` 恢复默认） |
| 1a | 同文件 `:32` `showSignature`；`:37` `imageLoadStrategy`；`:45` `showTopicPreview`；`:46` `threadNavMode`；`:48` `prefetchPageCount`；`:50` `recordReadingProgress` | 布尔/字符串字段的写法与注释风格 | 新字段紧邻 `threadNavMode`/`recordReadingProgress` 放置，写中文 JSDoc |
| 2 | `entry/src/main/ets/store/settings/domain/ReadingSettings.ets:10-15` | `class ReadingSettings { private ctx: SettingsContext }`，构造函数注入 `ctx` | 无需改构造 |
| 2a | 同文件 `:17-20` `setThreadNavMode(v: string)` | `this.ctx.state.xxx = v; this.ctx.persist()` | 新增 `setThreadRenderMode(v: string): void`（同样两行） |
| 2b | 同文件 `:34-43` `load(saved: SettingsState)` | 每个字段都 `if (saved.x !== undefined)` 才赋值（兼容老存档缺字段） | 追加一段 `if (saved.threadRenderMode !== undefined) this.ctx.state.threadRenderMode = saved.threadRenderMode` |
| 2c | 同文件 `:6-8` 文件头注释 | 注释里列了本域承载的字段 | 同步补一句 |
| 3 | `entry/src/main/ets/store/SettingsStore.ets:282-286` | `// --- Reading ---` 段：`setThreadNavMode` / `setPrefetchPageCount` / `setRecordReadingProgress` 都只做一行转发 | 追加 `setThreadRenderMode(v: string): void { this.readingSettings.setThreadRenderMode(v) }` |
| 3a | 同文件 `:146-180` `loadUserSettings()` | `saved` 存在时按域调 `load(saved)`（`:152-159`，reading 在 `:154`）；随后 `AppStorage.setOrCreate(...)`（`:167-175`） | 如果 ThreadPanel 需要「设置页改了默认样式，已打开的帖子页即时响应」，就在 `:167-175` 加 `AppStorage.setOrCreate(KEY_THREAD_RENDER_MODE, this.state.threadRenderMode)`；不需要即时响应则**只读 `appStore.settings.threadRenderMode` 即可，省略 AppStorage** |
| 3b | 同文件 `:109-127` `reset()` | 用 `new SettingsState()` 换掉 state，只显式重同步了列布局 AppStorage（`:122-125`）。**注释明确承认 AppStorage 旧值不会自动清** | 若新增了 AppStorage 键，`reset()` 里必须一并 `AppStorage.setOrCreate(KEY_..., 默认值)`，否则登出/切号后残留上一个账号的值 |
| 4 | `entry/src/main/ets/common/constants/AppStorageKeys.ets:52`（`showSignature`）、`:109`（`contentFontSize`）、文件末 `:163` | 每个键一条 JSDoc + `export const KEY_X: string = 'camelCase'`；文件头 `:5-11` 强调**装饰器参数必须写字面量**，常量与 `@StorageProp('xxx')` 是手工对齐关系 | 需要跨组件响应式才加：`export const KEY_THREAD_RENDER_MODE: string = 'threadRenderMode'`；同时在使用方写 `@StorageProp('threadRenderMode')`（字面量） |
| 5 | `entry/src/main/ets/common/constants/Constants.ets:309-316` `class ThreadNavMode` | 字符串常量类（不是 `enum`）：`static readonly SEAMLESS: string = '0'` / `PAGE: '1'` | 新增 `export class ThreadRenderMode { static readonly LIST: string = '0'; static readonly TREE: string = '1' }`（与 `ShowSignature` 不同，这里必须用字符串常量类，因为要持久化为字符串） |
| 6 | `entry/src/main/ets/pages/SettingsPanel.ets:51-53` | `@State threadNavBadge: string = '无缝加载'` 等 badge 缓存 | 新增 `@State threadRenderBadge: string = '列表'` |
| 6a | 同文件 `:172-178` `aboutToAppear()` | 首帧把 appStore 当前值换算成 label 填 badge | 追加 `this.threadRenderBadge = this.threadRenderLabel(appStore.settings.threadRenderMode)` |
| 6b | 同文件 `:385-421`（`threadNavLabel` / `threadNavOptions` / `showThreadNavPicker`） | **完整样板**：label 转换 → `ActionOption[]`（`{label, value}`）→ `buildRadioContent` → `CustomDialogController({ systemMaterial: UIMaterialManager.dialogMaterial, maskColor: UIMaterialManager.scrim, builder: SelectDialog({...}) })` → `open()` | 复制三件套为 `threadRenderLabel/threadRenderOptions/showThreadRenderPicker`，选中回调里 `appStore.settingsStore.setThreadRenderMode(String(v))` 并回写 badge |
| 6c | 同文件 `:156-170` `buildRadioContent` | 通用：`ActionOption[]` + 当前值 → `SelectRadioResult{selectedIndex, items:SheetInfo[]}`，每项 action 即应用设置 | 直接复用，不修改 |
| 6d | 同文件 `:600-688` Block 3A（「阅读设置」实际所在区块） | 见 §1.3 行号片段 | 在「帖子楼层导航」行（`:646-652`）之后、「预加载页数」行（`:656-662`）之前插入 `SettingPickerRow({ iconRes, iconColor, label: '帖子阅读样式', badgeText: this.threadRenderBadge, onAction: () => this.showThreadRenderPicker() })` + `Divider().margin({ left: 60 }).color(AppColors.separator)` |
| 6e | 同文件 `:184-186` `aboutToDisappear()` | 把 `xxxDialogController` 置 `undefined` 释放 | 追加新控制器 = undefined |
| 7 | `entry/src/main/ets/common/constants/Constants.ets:200-239` `class SettingsIconColors` | 每行一个语义色（`static readonly readingProgress: string = '#0EA5E9'` 等），相邻功能同色相 | 新增 `static readonly threadRender: string = '#0891B2'`（建议，取青蓝色系、避开已用的 20 个色） |
| 7a | `entry/src/main/resources/base/media/settings_*.svg` | 现有 20 个设置图标，命名 `settings_<语义>.svg` | 新增图标（如 `settings_thread_tree.svg`），写清 SVG 才行；Light/Dark 不需要双份（图标 `fillColor` 由 `AppColors.white` 运行时染色） |

### 1.2b 持久化落盘与 debounce（新增字段无需改，但要知道链路）

`SettingsStore.persistSettings()`（`SettingsStore.ets:135-144`）：

```ets
persistSettings(): void {
  const key: string = this.settingsKey()          // v2.settings（PersistenceCatalog.ets:74-78 的 settings 域）
  if (key.length === 0) return
  this.writeQueue.enqueue(async (): Promise<void> => {   // 串行队列：避免并发写同一 key
    await this.store.putJSON(key, this.state, false)     // false = 不立即 flush
    this.store.scheduleFlush()                           // debounce 500ms 后统一 flush
  })
}
```

- `writeQueue` 来自 `BaseStore`（`setDeps` 注入，`SettingsStore.ets:100-106` 的 `init`）。
- `PreferencesStore.scheduleFlush(delay: number = 500)`：`clearTimeout` + `setTimeout(flush)`（`common/infra/PreferencesStore.ets:131-135`）——这就是「debounce」本体；`putJSON(key, value, flush=false)` 见 `:55-65`。
- 含义：**新增字段只要进了 `SettingsState`，就会被整体序列化落盘**（无需逐字段注册）；写盘由 500ms debounce 合并，频繁 setter 不会放大 IO。树模式若在切换渲染模式时调 setter，不会造成性能问题。
- 反例：不要为「树模式当前折叠状态」之类高频 UI 状态写 setter（每次都会整份 `SettingsState` 序列化），这类状态应放组件 `@State` 或专用 store。

> 结论：**纯数据字段最少改 6 个文件**（SettingsState / ReadingSettings / SettingsStore / Constants 枚举 / SettingsPanel / 图标资源）。**仅当需要跨组件即时响应**时才多改 `AppStorageKeys.ets` 并处理 `reset()` 归一（现成坑：`SettingsStore.ets:122-125` 的注释）。

### 1.3 「阅读设置」现有 UI 区块（可直接照抄的代码片段）

**位置**：`SettingsPanel.ets:600-688`（`// ---- Block 3A: 显示签名 / 图片加载模式 ----` 到 Block 3A 结束）。这一块实际是「阅读设置」+ 显示设置混排。

```ets
// SettingsPanel.ets:646-652  帖子楼层导航（PickerRow 范式）
SettingPickerRow({
  iconRes: $r('app.media.settings_thread_navigation'), iconColor: SettingsIconColors.threadNavigation,
  label: '帖子楼层导航',
  badgeText: this.threadNavBadge,
  onAction: () => {
    this.showThreadNavPicker()
  }
})

Divider().margin({ left: 60 }).color(AppColors.separator)

// SettingsPanel.ets:656-662  预加载页数（第二种 PickerRow）
SettingPickerRow({
  iconRes: $r('app.media.settings_page_prefetch'), iconColor: SettingsIconColors.pagePrefetch, label: '预加载页数',
  badgeText: this.prefetchPageBadge,
  onAction: () => {
    this.showPrefetchPagePicker()
  }
})

// SettingsPanel.ets:666-672  记录阅读进度（ToggleRow 范式）
SettingToggleRow({
  iconRes: $r('app.media.settings_reading_progress'), iconColor: SettingsIconColors.readingProgress, label: '记录阅读进度',
  isOn: appStore.settings.recordReadingProgress,
  onChange: (v: boolean) => {
    appStore.settingsStore.setRecordReadingProgress(v)
  }
})
```

**选项选择 UI 是「弹窗（SelectDialog）」，不是菜单**：`SettingsPanel.ets:408-420`（threadNav）、`:450-462`（prefetch）、`:474-486`（imageStrategy）三个完全同构。

```ets
// SettingsPanel.ets:392-421  帖子楼层导航：选项表 + 单选弹窗（可直接复制改名）
private threadNavOptions(): ActionOption[] {
  return [
    { label: '无缝加载（连续滚动）', value: parseInt(ThreadNavMode.SEAMLESS) },
    { label: '传统翻页（跳转器换页）', value: parseInt(ThreadNavMode.PAGE) },
  ]
}

private showThreadNavPicker(): void {
  const radio: SelectRadioResult = this.buildRadioContent(
    this.threadNavOptions(),
    parseInt(appStore.settings.threadNavMode),
    (v: number): void => {
      appStore.settingsStore.setThreadNavMode(String(v))
      this.threadNavBadge = this.threadNavLabel(String(v))
    }
  )
  this.threadNavDialogController = new CustomDialogController({
    backgroundColor: Color.Transparent,
    systemMaterial: UIMaterialManager.dialogMaterial,
    maskColor: UIMaterialManager.scrim,
    builder: SelectDialog({
      title: '帖子楼层导航',
      selectedIndex: radio.selectedIndex,
      radioContent: radio.items,
      confirm: { value: '确定' }
    }),
    autoCancel: true
  })
  this.threadNavDialogController?.open()
}
```

**主题适配约定**：
- 所有颜色走 `AppColors.*`（底层是 `$r('app.color.*')`，`base`/`dark` 两套资源自动切换）或 `UIMaterialManager.*`（材质前景/遮罩），**不写死色值**（`Constants.ets:97-160`）。
- 设置行统一视觉：行高 44、左右 padding 16、图标容器 29×29 圆角 6、图标 17×17 白色、与标签间距 12（`SettingRow.ets:16-19`、`41-65`）。
- 弹窗背板：`backgroundColor: Color.Transparent` + `systemMaterial: UIMaterialManager.dialogMaterial` + `maskColor: UIMaterialManager.scrim`（三个必须显式写，见 `docs/IMMERSIVE_LIGHT_DESIGN.md` 与 `SettingsPanel.ets:408-419`）。

### 1.4 标题区更多菜单的切换项（`NavBarMenuItem.active` 语义）

接口定义：`PanelNavBar.ets:27-34`

```ets
export interface NavBarMenuItem {
  /** 菜单项文本。 */
  label: string
  /** 是否为当前生效项：用主题色文字表达，不占用系统菜单的选中图标位。 */
  active?: boolean
  /** 点击回调（写成箭头函数以捕获使用方的 this）。 */
  action: () => void
}
```

渲染：`PanelNavBar.ets:253-263`（`MenuItem` 的 `contentFontColor` 在 active 时用 `AppColors.primary`；**ForEach 键值带激活态指纹** `item.label + (active ? '|1' : '|0')`，否则激活色不刷新）；菜单参数 `:287-297`（`Placement.BottomRight`、`enableArrow:false`、`systemMaterial: UIMaterialManager.menuMaterial`）。

ThreadPanel 侧提供菜单的方式：`ThreadPanel.ets:2644-2654`（`PanelNavBar({ hasMenu: true, menuItemsProvider: (): NavBarMenuItem[] => this.moreMenuItems() })`）——**provider 而不是 @Prop 数组**，原因见 `PanelNavBar.ets:91-101`（@Prop 不能传 Function 类型）。

新增「阅读样式」切换项的可照抄样板：`ThreadPanel.ets:2709-2719`（只看楼主）

```ets
items.push({
  label: '只看楼主',
  active: this.authorOnly,
  action: (): void => {
    this.authorOnly = !this.authorOnly
    this.pendingTargetPid = ''
    this.singlePostFallback = false
    this.pendingTargetLastPost = false
    this.loadPosts(1, ThreadLoadMode.REPLACE)
  }
})
```

树模式的切换项建议：

```ets
// 插在 moreMenuItems() 的「只看楼主」之后、'从网页打开' 之前（ThreadPanel.ets:2720 前）
items.push({
  label: '递进树阅读',
  active: this.renderMode === ThreadRenderMode.TREE,
  action: (): void => {
    this.switchRenderMode(
      this.renderMode === ThreadRenderMode.TREE ? ThreadRenderMode.LIST : ThreadRenderMode.TREE
    )
  }
})
```

> **坑**：`active` 只在**菜单每次构建时**由 provider 求值，所以切换后必须让「下一次展开菜单」读到新值。状态必须放在 `@State`（或 `@StorageProp`）上——`ThreadPanel.ets:246-251` 的 `trackedThreadVersion` 注释写清了这条：非响应式数据不会触发重绘，菜单激活态会停在旧值。

### 1.5 AppStorage 同步 / 全局刷新模式（`blacklistVersion` 为范式）

- 定义：`AppStorageKeys.ets:88` `KEY_BLACKLIST_VERSION = 'blacklistVersion'`。
- 订阅方（ThreadPanel）：`ThreadPanel.ets:224` `@StorageProp('blacklistVersion') @Watch('onBlacklistVersionChange') blacklistVersion: number = 0`；回调 `:705-707` 调 `applyBlacklistStateToPosts(this.mgr.posts, appStore.settingsStore.getBlacklistIds())`。
- 订阅方（PostItem）：`PostItem.ets:37` + `:80-83`：
  ```ets
  private isPostBlacklisted(): boolean {
    return this.blacklistVersion >= 0 &&
      appStore.settingsStore.isBlacklisted(String(this.post.authorid))
  }
  ```
  `blacklistVersion >= 0` 这个「冗余读」是**故意的**：它建立响应式依赖，版本号变化 → PostItem build 重算 → 重新查全局 store。
- 同模式还有：`favoriteTopicVersion`（`ThreadPanel.ets:202`）、`trackedThreadVersion`（`:251`，注释解释了「只用于建立响应式依赖」）、`contentFontSize`（`BBCodeContentView.ets:153`）、`effectiveColorMode`（`:147`）。
- **写侧**：`AppStorage.setOrCreate(KEY_X, v)`；重绘范围 = 所有 `@StorageProp('X')` 的组件。

> 树模式若需要「设置页改默认样式后，已打开的 ThreadPanel 立即切模式」，就用这条：`@StorageProp('threadRenderMode')` + `SettingsStore.loadUserSettings()` 里 `setOrCreate` + `reset()` 归一。否则用 `@State` + 进入页面时读 `appStore.settings`。

### 1.6 新增字段建议（供 Lead 决策）

| 方案 | 字段 | 优点 | 代价 |
|---|---|---|---|
| A（推荐） | `SettingsState.threadRenderMode: string = ThreadRenderMode.LIST` | 与 `threadNavMode` 完全同构，改动面 6 文件，可预测 | 已打开的帖子页不即时响应（下次进入生效） |
| B | A + AppStorage 键 `threadRenderMode` + `@StorageProp` | 即时响应 | 多改 2 处（AppStorageKeys、`loadUserSettings`、`reset`），并要处理「菜单临时切换」与「设置默认值」两个真源打架 |
| C | 只存内存（不持久化） | 最简单 | 不满足「设置页可选默认样式」需求 |

菜单里的临时切换与设置默认值的关系建议：**菜单切换只改 ThreadPanel 的 `@State`（本次会话临时），设置页改的是默认值**；或菜单切换时一并写回设置（需在报告外由 Lead 定产品语义）。两者都可行，见 §7.4 冲突点。

---

## 2. ThreadPanel 关键流程（逐函数 + 精确行号）

文件：`entry/src/main/ets/pages/ThreadPanel.ets`（3090 行）。修改前必读 `docs/THREAD_DESIGN.md`（文件内 `:175-179` 的注释也再次强调）。

### 2.1 组件骨架与状态所有权

| 行号 | 内容 | 说明 |
|---|---|---|
| `:180-181` | `@Component export struct ThreadPanel` | 页面组件（不是 @Entry） |
| `:185-191` | `@Prop @Watch('onThreadChanged') threadTid` / `threadPage` / `threadPid` / `threadSource` / `@Prop @Watch('onScrollToPid') navEntryId` | 路由入参。`navEntryId` 变化会触发 `onScrollToPid`（`:769`） |
| `:195` | `private postsDataSource: PostInfoDataSource = new PostInfoDataSource()` | List 的数据源；**只镜像 mgr 的提交结果** |
| `:196` | `@State displayPage: number` | 当前显示页（由 `onScrollIndex` 的中心楼层换算） |
| `:199` | `@State authorOnly: boolean` | 「只看楼主」 |
| `:202` / `:224` / `:251` | `@StorageProp favoriteTopicVersion / blacklistVersion / trackedThreadVersion` | 全局版本号刷新模式（见 §1.5） |
| `:263` | `private scroller: Scroller` | 列表控制器 |
| `:296-306` | `lastScrollStart / lastScrollEnd / lastScrollCenter` | `onScrollIndex` 上报的可见区间与中心索引；进度记录用中心 |
| `:312` | `progressRecordTimer` | 阅读进度落盘节流计时器 |
| `:315-321` | `readingResumePending / readingResumeHandled / pendingResumeEntry` | 恢复进度的三个状态 |
| `:324` | `pendingTargetPid` | 尚未完成的路由定位意图 |
| `:327` | `singlePostFallback` | 单帖兜底去重 |
| `:334` / `:337` | `lastRepliedPid` / `pendingTargetLastPost` | 「前往查看」定位链路 |
| `:348` | `@State mgr: ThreadPaginationManager = new ThreadPaginationManager()` | 分页窗口唯一事实来源（`@Observed` 在子类，`ThreadPaginationManager.ets:12-13`） |
| `:351` | `prefetchGenerationByPage: Map<number, number>` | 预取去重 |
| `:354` | `lastReplacePage` | 失败重试页 |
| `:357-390` | `listNavigation*` / `prependAnchor*` | 定位事务与前插锚点事务 |
| `:392-393` | `loadingContentOpacity` / `loadingDelayTimer` | 加载态 400ms 延迟淡入 |

### 2.2 `loadPosts` 三种模式（`:1316-1526`）

入口：`loadPosts(targetPage: number, mode: ThreadLoadMode)`，模式枚举在 `:129-136`（`REPLACE=0 / APPEND=1 / PREPEND=2`）。

**REPLACE 前置（`:1321-1346`）**——树模式若要拦截「整页替换」，这里是唯一入口：

```ets
if (mode === ThreadLoadMode.REPLACE) {
  if (this.listNavigationPending) this.cancelListNavigation(...)   // :1322-1324
  this.cancelPrependAnchor('replace')                              // :1325
  this.lastReplacePage = targetPage                                // :1326
  this.mgr.reset()                                                 // :1327  ← 推进代际
  this.prefetchGenerationByPage.clear()                            // :1328
  this.postsDataSource.clear()                                     // :1329
  this.isLoading = true; this.loadingContentOpacity = 0            // :1330-1331
  this.loadingDelayTimer = setTimeout(...400ms 淡入...)            // :1333-1339
  this.isLoadingMore = false; this.isLoadingPrevious = false       // :1340-1341
  this.hasError = false; this.lastScroll* = 0; this.titleScrollEffectProgress = 0  // :1342-1346
} else if (APPEND) { this.isLoadingMore = true }                   // :1347-1348
else { this.isLoadingPrevious = true }                             // :1349-1351
```

**取数（`:1353-1373`）**：捕获 `generation: number = this.mgr.getGeneration()`（`:1353`）；`navPid` 只在 REPLACE 时取 `pendingTargetPid`（`:1357`），`requestPid` 只在「单帖兜底」时携带 pid（`:1358`，注释解释了「带 pid 的整页请求会返回单帖视图」——这是 THREAD_DESIGN §5.3 的硬约束）。REPLACE 走 `fetchPageWithFloorFallback`（`:1370-1371`），APPEND/PREPEND 走 `fetchPostsPage(..., 15000, HIGH)`（`:1372-1373`）。

**代际校验（`:1375-1382`）**：`generation !== this.mgr.getGeneration()` → 丢弃。

**响应成功（`:1384-1468`）**：
- `resolvedPage = result.pagination.page > 0 ? ... : targetPage`（`:1385`）。
- 主题信息回填（`:1392-1407`）：`threadSubject`（`unescapeHtml(info.subject)`）、`threadFid`、`threadAuthorId`（`:1396-1398`）；**楼主稳定键只在含主楼的页采信并锁定**（`:1399-1406`，`hasMainFloor` 判定 + `isAuthorKeyUsable`）。
- REPLACE 提交（`:1409-1436`）：`pendingTargetLastPost` 消费（`:1410-1414`）→ `mgr.replaceWith(result.posts, resolvedPage, result.pagination.totalPages)`（`:1415`）→ 单帖兜底后恢复真实总页数（`:1416-1420`）→ **`this.postsDataSource.replaceAll(result.posts)`**（`:1421`）→ `displayPage`（`:1422`）→ 浏览历史（`:1425-1427`）→ 跟踪已读（`:1429-1431`）→ `prepareListNavigation(generation, resolvedPage, this.pendingTargetPid)`（`:1432`）→ `floorMissing` 提示（`:1433-1436`）。
- APPEND（`:1437-1445`）：`mgr.appendPosts(...)` → `postsDataSource.appendAll(added)`。
- PREPEND（`:1446-1461`）：`preparePrependAnchor` → `mgr.prependPosts` → `postsDataSource.prependAll(added)` → `schedulePrependAnchorRestore`。
- 提交后统一 `this.triggerPrefetches()`（`:1468`）。

**失败/异常/finally（`:1469-1525`）**：REPLACE 失败置 `hasError/errorMsg` + `postsDataSource.clear()`（`:1474-1480`）；APPEND/PREPEND 失败只记日志（`:1499-1501`）；finally 里按模式复位 loading（`:1502-1517`），`windowAdvanced` 时 `scheduleReconcile`（`:1515-1517`）。

> **树模式接入点建议**：不要改 `loadPosts` 内部，而是在调用侧分流（`aboutToAppear`/`onThreadChanged`/`navigateToPage`/菜单切换），并在 `triggerPrefetches`（`:1543-1547`）、`tryLoadNext`（`:1631-1633`）、`tryLoadPrev`（`:1665-1667`）、`reconcile`（`:1096-1097`）现有的 `threadNavMode === ThreadNavMode.PAGE` 短路旁边加一条 `|| this.renderMode === ThreadRenderMode.TREE` 短路——**这四处是本工程已验证的「关闭连续加载」开关位**。

### 2.3 `scrollToPid`（`:787-795`）与引用跳转链路

```ets
private scrollToPid(pid: string): boolean {
  const pidNumber: number = parseInt(pid, 10)
  const postIndex: number = this.mgr.findPostIndex(pidNumber)   // :789
  if (postIndex < 0) return false
  this.scroller.scrollToIndex(postIndex, false, ScrollAlign.CENTER)  // :793  ← 居中定位
  return true
}
```

- `onScrollToPid`（`:769-779`）：`navEntryId` 变化时按 `threadPid` 定位，写 `floor-nav direct` 日志。
- `handleLinkClick`（`:2439-2476`）：引用链接跳转，页内命中直接 `scrollToPid(linkPid)`（`:2463`），否则走 `loadPosts` REPLACE + `pendingTargetPid`。
- `applyListNavigation`（`:913-981`）：挂载后定位事务；整页未命中 → 单帖兜底（`:932-946`，先存 `fallbackPrevTotalPages`，再 `loadPosts(1, REPLACE)`）。
- **`scrollToIndex` 在 `listMounted === false` 时静默无效**（`docs/THREAD_DESIGN.md:127`；`ThreadPanel.ets:658-665` 的 `goToResumedPosition` 校验了这一点）。

> 树模式必须新增「pid → 树节点下标」的映射：`scrollToPid` 里 `mgr.findPostIndex` 是硬绑 posts 的，树模式下应改为 `treeDataSource.findIndexByPid(pid)`，并且要先**展开其祖先链**（否则节点被折叠、`scrollToIndex` 落点不对）。这是树模式与现有定位链路的主要接缝。

### 2.4 `isTopicAuthorPost`（`:2139-2141`）与楼主身份

```ets
private isTopicAuthorPost(post: PostInfo): boolean {
  return this.hasThreadAuthorKey && post.authorKey === this.threadAuthorKey
}
```

- 相关：`isAuthorKeyUsable`（`:2122-2128`，空串/非正数字不可比）、`threadAuthorKey` 的采集与锁定（`:1399-1406`）、`threadAuthorKey` 在 `onThreadChanged` 里必须清零（`:526-530`）。
- `authorKey` 语义见 `model/PostInfo.ets:38-49`（普通帖 = uid 数字串；匿名帖 = `#anony_<32hex>`；判不出为空串）。

### 2.5 `showProfileCard`（`:424-442`）

```ets
private showProfileCard(uid: string, screenX: number, screenY: number): void {
  const cardW: number = 280; const cardH: number = 400; const pad: number = 8
  // 屏幕内收敛：posX = clamp(screenX - cardW/2, pad, screenW - cardW - pad)
  //               posY = clamp(screenY + pad, pad, screenH - cardH - pad)
  ...
  floatingLayerStore.openProfileCard(uid, posX, posY)   // :441
}
```

- 用法：`PostItem.onProfileClick` 透传到 `showProfileCard`（`ThreadPanel.ets:2504-2506`）；`PostItemHeader` 内部把 `event.windowX/windowY` 一起回传（`PostItemHeader.ets:49-58`）。
- 树节点里复用 `PostItemHeader` 时要原样接这个回调（否则点头像无反应）。

### 2.6 `handleReplySend`（`:1707-1734`）与静默刷新

```ets
private async handleReplySend(text: string, isAnony: boolean): Promise<void> {
  let result: PostReplyResult
  try { result = await replyManager.send(text, isAnony) }
  catch (e) { appStore.showToast(...); throw new Error(...) }     // :1709-1714 失败让编辑器保留草稿
  if (!result.ok) { appStore.showToast(...); throw new Error(...) } // :1715-1718
  const isComment: boolean = replyManager.type === ReplyType.COMMENT
  const targetPost: PostInfo | null = replyManager.targetPost
  const navPid: string = isComment ? String(targetPost?.pid ?? '') : result.pid   // :1722
  appStore.showToastAction(isComment ? '贴条成功' : '回复成功', '前往查看',
    () => { this.goToRepliedPost(navPid) })                       // :1725-1727
  this.silentRefreshAfterPost(replyManager.type, String(targetPost?.pid ?? ''))  // :1733
}
```

- 静默刷新：`silentRefreshAfterPost`（`:1811-1933`）→ `mgr.mergePage(...)`（`:1868-1870`）→ 数据源 `updateAt`/`appendAll`（`:1871-1884`）→ 不重置窗口、不推进代际、不位移（THREAD_DESIGN §5.1）。
- 编辑乐观更新：`handleEditSend`（`:1743-1789`），**`uiRev++` + `postsDataSource.updateAt`**（`:1778-1786`）——这是「内容变化如何刷新 LazyForEach」的权威写法。
- 树模式：树节点的数据源如果是独立结构，回复静默刷新需要把 `mergePage` 的结果同步进树构建器的索引（或整树重建但保序）。**这是树模式最容易被漏掉的一条路径**。

### 2.7 阅读进度记录 / 恢复（`:544-700`）

| 行号 | 函数 | 要点 |
|---|---|---|
| `:549-554` | `shouldRecordProgress()` | 开关 + 已登录 + 非单帖兜底 + 非离线存档 |
| `:559-566` | `scheduleProgressRecord()` | `setTimeout 800ms` 节流（滚动停顿才落盘） |
| `:576-587` | `recordReadingProgress()` | 锚点 = `lastScrollCenter` → `mgr.getDisplayPage(anchorIndex)`；tid 取楼层自身的 tid（跨帖补记正确性，`:582-583`） |
| `:602-611` | `tryRestoreReadingProgress()` | 仅「继续阅读」语义：无 pid、page=1、来源白名单（`:618-622`）、`readingResumeHandled` 去重 |
| `:627-645` | `resumeReadingProgress()` | 读 `appStore.getReadingProgress(uid, tid)`（`:630`）；不静默定位，弹 Toast「检测到上次阅读进度 / 前往查看」（`:642-644`） |
| `:654-669` | `goToResumedPosition()` | Toast 回调，先校验 `listMounted` / tid / 开关（`:658-667`） |
| `:679-700` | `applyReadingResume(entry)` | 命中当前窗口 → `scrollToPid`（`:691-697`）；否则 `loadPosts(entry.page, REPLACE)`（`:699`） |
| `:472-498` | `aboutToDisappear()` | `recordReadingProgress()`（`:474`）→ 清计时器 → `mgr.reset()`（`:495`） |
| `:500-537` | `onThreadChanged()` | 切帖前补记旧帖（`:505-506`），重置全部状态后 `loadPosts` + `tryRestoreReadingProgress`（`:534-536`） |
| `:2610-2638` | `onScrollIndex` | 定位事务期间直接 `return`（`:2611-2623`）；否则更新 `lastScroll*`、`displayPage`、`reconcile()`、`scheduleProgressRecord()`（`:2624-2637`） |

- 数据：`ReadingProgressEntry`（`store/ReadingProgressStore.ets:8-17`：`tid/page/pid/ts`）+ `appStore.getReadingProgress`（`AppStore.ets:1106`）/ `saveReadingProgress`（`:1110`）；域 `reading_progress`（`PersistenceCatalog.ets:116-120`，上限 200 条）。
- **树模式冲突**：`recordReadingProgress` 与 `applyReadingResume` 都假定「数组下标 = 楼层顺序」。树节点列表会重排 + 折叠，必须重定义锚点（建议：树模式跳过记录与恢复；或锚点改为「展开状态下该 pid 的节点下标」，见 §7.4）。

### 2.8 `moreMenuItems`（`:2674-2739`）

完整项序（非存档来源）：`收藏到…`（`:2686-2691`，label 由 `getFavoriteMenuLabel()` `:730-744` 生成）→ `离线保存帖子`（`:2692-2697`）→ `跟踪帖子更新`（`:2699-2705`，`active: this.isTrackingCurrentThread()`）→ `只看楼主`（`:2709-2719`，`active: this.authorOnly`）→ `从网页打开`（`:2720-2727`）→ `分享帖子`（`:2728-2737`）；存档来源只有 `在线模式打开`（`:2677-2684`）。

- 回调必须是箭头函数（`PanelNavBar` 实例上执行，见 `PanelNavBar.ets:15-26` 与 `ThreadPanel.ets:2663-2672` 的注释）。
- 菜单的 `active` 与「每次构建时求值」语义见 §1.4。

### 2.9 `LazyForEach` 键值、List 配置与数据源通知

**列表结构（`:2487-2560`）**：

```ets
List({ scroller: this.scroller }) {
  LazyForEach(this.postsDataSource, (post: PostInfo) => {
    ListItem() {
      PostItem({ /* 21 个入参，见 §3.1 */ })
    }
  }, (post: PostInfo) => String(post.pid) + '_' + String(post.uiRev))   // :2558  ← 键值
  this.LoadMoreFooter()                                                   // :2559
}
.width('100%').layoutWeight(1)
.contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))  // :2562  ← 标题避让
.scrollBar(BarState.Off)                                                  // :2563
.divider({ strokeWidth: 0.5, color: AppColors.separator })                // :2564
.edgeEffect(EdgeEffect.Spring)                                            // :2565
.cachedCount(6)                                                           // :2566
.maintainVisibleContentPosition(true)                                     // :2567
.linearGradientBlur(...)                                                  // :2568-2574
.onAreaChange(...)                                                        // :2575-2580
.onDidScroll(...)                                                         // :2581-2588
.onAppear(... listMounted = true ... scheduleListNavigation ...)          // :2589-2600
.onDisAppear(... listMounted = false ...)                                 // :2601-2609
.onScrollIndex(...)                                                       // :2610-2638
```

- **数据源通知时机**：REPLACE→`replaceAll`（`:1421`）；APPEND→`appendAll`（`:1444`）；PREPEND→`prependAll`（`:1454`）；静默刷新/编辑→`updateAt`（`:1784`、`:1873`）与 `appendAll`（`:1876`）；失败→`clear`（`:1478`、`:1497`）。
- `PostInfoDataSource` 只有 4 个写原语（`LazyDataSource.ets:12-14` + `BaseLazyDataSource.ets:58-110`），**没有单条删除**。树节点折叠/展开若用「增删节点」实现，需要给数据源新增 `deleteAt`（继承后加，见 §6.3）。

### 2.10 `mgr`（ThreadPaginationManager）所有权与 `totalPages` 来源

- **所有权**：`ThreadPaginationManager` 是 posts 与页窗口的唯一事实来源（`docs/THREAD_DESIGN.md:56-61`）；`PostInfoDataSource` 只镜像、不决策（`:58`、`:61`）。
- **`totalPages` 来源链**：`getThread`/`fetchThreadRaw` → `ThreadResult.pagination.totalPages`（`model/ThreadResult.ets:16-20`、`:28`；填充在 `ThreadApi.ets:701-704`）→ `mgr.replaceWith(posts, page, totalPages)`（`ThreadPaginationManager.ets:52-63`）→ `applyState(page, max(page, totalPages))`（`PaginationManager.ets:52-56`，设置 `currentPage/totalPages/hasMore`）。
- 单帖兜底会把 `totalPages` 重置为 1，必须用 `fallbackPrevTotalPages` 恢复（`ThreadPanel.ets:342-346`、`:1416-1420`；THREAD_DESIGN §5.3 第 5 条）。
- 更底层的「总页数计算」范式（不依赖 ThreadResult）：`locatePidPage` 里请求 `page='e'` 后 `__ROWS / __R__ROWS_PAGE` 向上取整（`ThreadApi.ets:458-477`）。**树模式全量抓取建议先用它拿 totalPages**，再循环 1..N。
- 分页窗口不变量（`docs/THREAD_DESIGN.md:67-86`）：只能提交相邻页；`posts.length === pageOfIndex.length`；跨页去重键是 pid。

### 2.11 其它可复用点速查

| 行号 | 内容 |
|---|---|
| `:273-281` / `:291-293` | 标题滚动特效进度 / 模糊停靠点（树模式换 List 也要接同一个 `titleScrollEffectProgress`） |
| `:403-412` | 握姿切换 300ms 动画（`animateTo`） |
| `:719-744` | 收藏状态同步 / 菜单文案 |
| `:1151-1153` / `:1161-1177` | 页码选择器数据源 / 输入跳页 |
| `:2032-2066` / `:2085-2095` | 「离线保存帖子」弹窗 + 后台任务启动（`savedThreadService.saveThread` + Toast） |
| `:2214-2252` | AI 任务选择（单候选直接执行 / 多候选弹窗） |
| `:2391-2433` | `handleVote`（投票 + 局部更新 + `updateVoteScore`） |
| `:2435-2437` | `openImageViewer` 转发到 `common/utils/LinkUtils` |
| `:2644-2654` | `PanelNavBar` 挂载 |
| `:2656` / `:2886-3040` | `BottomBar()`：底部分页条 + 回复按钮（`HdsMaterialHost`，`:2895`、`:3015`） |
| `:3046-3055` | `LoadingState()`（`loadingContentOpacity` 淡入） |
| `:3060-3070` | `ErrorState()`（重试 → `loadPosts(lastReplacePage, REPLACE)`） |
| `:3075-3089` | `LoadMoreFooter()`（`加载更多...` / `已加载全部回复`） |

---

## 3. PostItem 复用边界

### 3.1 `PostItem` 组件签名（`common/components/PostItem.ets`，217 行）

它是**编排层**，自身只保留签名折叠与正文渲染，展开/菜单状态全部下沉（`:18-23` 文件头）。

| 行号 | 入参 / 内容 | 类型 | 树节点是否直接复用 |
|---|---|---|---|
| `:27` | `@Prop post: PostInfo` | 值拷贝 | ✅ 必需 |
| `:29-30` | `@Prop isVotedUp / isVotedDown: boolean` | bool | ✅ 从 ThreadPanel 的 Set 计算 |
| `:33` | `@Prop holdingHand: number` | 0=右/1=左 | ✅ 透传 `this.holdingStatus` |
| `:35` | `@StorageProp('showSignature') showSignature` | 全局 | ✅ 自动 |
| `:37` | `@StorageProp('blacklistVersion') blacklistVersion` | 全局版本号 | ✅ 自动 |
| `:39` | `@State private sigExpanded` | 签名折叠 | ✅ 内部 |
| `:41` | `onImageClick: (urls: string[], index: number) => void` | 回调 | ✅ 必需（否则图片不可点） |
| `:43` | `onLinkClick: (href: string) => void` | 回调 | ✅ 必需（引用/链接跳转） |
| `:45` | `onVideoClick: (url: string) => void` | 回调 | ✅ |
| `:47` | `onProfileClick: (uid, screenX, screenY) => void` | 回调 | ✅ 必需（资料卡） |
| `:49-53` | `onVote: (post, value) => Promise<VoteResult>` | 异步 | ✅（回复 `ThreadPanel.handleVote`） |
| `:55` | `onReply: (post) => void` | 回调 | ✅ |
| `:57` | `onComment: (post) => void` | 回调 | ✅ |
| `:59` | `onEdit: (post) => void` | 回调 | ✅ |
| `:61` | `onShare: (post) => void` | 回调 | ✅ |
| `:63` | `onSummarize: (post) => void` | 回调 | ✅ |
| `:65` | `onReadAloud: (post) => void` | 回调 | ✅ |
| `:67` | `isTopicAuthor: boolean` | 普通字段 | ✅（`isTopicAuthorPost(post)`） |
| `:69` | `isOwnPost: boolean` | 普通字段 | ✅（`String(post.authorid) === appStore.auth.uid`） |
| `:71-73` | `aboutToReuse` 重置 `sigExpanded` | 生命周期 | — |
| `:87-91` | 内嵌 `PostItemHeader` | 子组件 | 见 §3.2 |
| `:104-108` | 内嵌 `BBCodeContentView({ nodes: getCachedBBNodes(this.post.content) ... })` | 子组件 | ✅ 但注意 §3.3 |
| `:110-115` | `PostAttachments` | 子组件 | ✅ |
| `:117-154` | 签名折叠区（`sigExpanded`，自带「签名 ▾」折叠头） | 内置 | 树节点若是精简子节点可整体不要 |
| `:156-168` | `PostVoteBar` | 子组件 | ✅ |
| `:172-174` | `PostPoll`（仅在 `post.vote.length > 0` 时渲染，主楼才有） | 子组件 | 根节点可视需要 |
| `:176-183` | `PostComments` | 子组件 | 根节点可选 |
| `:185-192` | `HotRepliesSection` | 子组件 | 根节点可选 |
| `:80-83` | `isPostBlacklisted()`（`blacklistVersion >= 0 && appStore.isBlacklisted(...)`） | 依赖模式 | ✅ 照抄 |
| `:197-216` | `getEditTimeDisplay` / `getSignaturePreview` | 纯函数 | ✅ |

### 3.2 子组件签名与职责（树节点组件直接复用的最小集）

| 组件 | 文件:行号 | 输入 | 职责 | 树节点复用建议 |
|---|---|---|---|---|
| `PostItemHeader` | `post-item/PostItemHeader.ets:16-64` | `@Prop post: PostInfo`；`@Prop isTopicAuthor: boolean`；`onProfileClick(uid, screenX, screenY)` | 头像 + 匿名名/备注 + 楼主标记 + 用户组 + 楼层号（`lou===0?'楼主':lou===1?'沙发':'#N'`，`:60`）；点击作者区回调资料卡（`:49-58`，匿名时 Toast「该用户已匿名」） | **首选**。树节点头部「X1 回复 X2」可写在它下方或与它同排（新写一个 `TreeNodeHeader` 包一层，不要改 PostItemHeader——它同时被 PostComments/HotReplies 风格参考） |
| `PostVoteBar` | `post-item/PostVoteBar.ets:13-51` | `@Prop post/isVotedUp/isVotedDown/holdingHand/isOwnPost` + `onVote/onReply/onEdit/onShare/onSummarize/onReadAloud` | 点赞/踩/回复/编辑/分享/AI/朗读动作栏；**点赞成功后自持 `@State displayScore/displayVotedUp`，避免重建整个 PostItem**（`:26-35`、`:69-77`；THREAD_DESIGN §7 故障表最后一行） | 子节点若精简可不放；根节点/详情复用 |
| `BBCodeContentView` | `common/components/BBCodeContentView.ets:129-161` | `nodes: BBNode[]`（**普通字段，不是 @Prop/@State**）；`hideFailedImages: boolean`；`onImageClick`/`onLinkClick` | BBCode 全量渲染（文字/图片/视频/代码/表格/引用/折叠块/动态照片） | ✅ 正文渲染的唯一入口；树节点的「引用块」直接用 `[quote]` 原文渲染即可（节点类型见 `model/BBCodeNode.ets:16` COLLAPSE） |
| `PostAttachments` | `post-item/PostAttachments.ets:26-88` | `@Prop post`；`onImageClick` | 附件「附件 (N) / 收起附件」折叠展开（`:60-71`），展开时按需拉视频尺寸 | ✅ 根节点可复用 |
| `PostComments` | `post-item/PostComments.ets:74-172` | `@Prop post`；`onImageClick/onLinkClick/onProfileClick` | 楼中楼评论：头像行 + 尖角气泡 + BBCode；**「直接渲染全部评论，不再折叠」**（`:100` 注释） | ⚠️ 它没有「展开更多」逻辑，可整体借用视觉，不要指望沿用折叠 |
| `HotRepliesSection` | `post-item/HotRepliesSection.ets:18-131` | 同上 | 「热门回复」标题 + 逐条（点赞数 `+N`、原楼层号 `#lou`）+ 尖角气泡 | ✅ 根节点可复用 |
| `PostPoll` | `post-item/PostPoll.ets` | `@Prop post`（只用 `post.vote`） | 投票帖选项渲染 | 根节点可选 |
| `Avatar` | `common/components/Avatar.ets:11-15` | `@Prop avatar/uid/name` + `avatarSize: number` | 圆形头像 | 自绘树头可用 |
| `AnonymousName` | `common/components/AnonymousName.ets:6-12` | `@Prop author/isAnonymous/fontSize/normalColor/isMuted` | 匿名名六字解码渲染 | 自绘树头可用 |

**新树节点组件如果复用 `PostItemHeader` + `BBCodeContentView` + `PostVoteBar`，各自必须传的回调**：

```ets
// PostItemHeader：只接资料卡（uid 语义，不是 authorKey）
PostItemHeader({
  post: node.post,
  isTopicAuthor: this.isTopicAuthor(node.post),
  onProfileClick: (uid: string, x: number, y: number): void => { this.onProfileClick(uid, x, y) }
})

// BBCodeContentView：图片与链接两个回调必须都接，否则正文里的图片/引用链接不可点
BBCodeContentView({
  nodes: getCachedBBNodes(node.post.content),
  onImageClick: (urls: string[], index: number): void => { this.onImageClick(urls, index) },
  onLinkClick: (href: string): void => { this.onLinkClick(href) }   // 引用跳转走这里 → ThreadPanel.handleLinkClick
}).width('100%').margin({ top: 12 })

// PostVoteBar：7 个回调 + 4 个状态，缺一个按钮就哑
PostVoteBar({
  post: node.post, isVotedUp: ..., isVotedDown: ..., holdingHand: ..., isOwnPost: ...,
  onVote: (p: PostInfo, v: number): Promise<VoteResult> => this.onVote(p, v),
  onReply: (p: PostInfo): void => this.onReply(p),
  onEdit: (p: PostInfo): void => this.onEdit(p),
  onShare: (p: PostInfo): void => this.onShare(p),
  onSummarize: (p: PostInfo): void => this.onSummarize(p),
  onReadAloud: (p: PostInfo): void => this.onReadAloud(p)
})
```

### 3.3 `BBCodeContentView` 的 nodes 来源与性能

- **来源**：`getCachedBBNodes(content)`（`parser/bbcode/BBCodeCache.ets:71-78`）。命中 LRU（`MAX_CACHE_SIZE=150`，`:10`）直接返回；未命中**在调用线程同步 `parseBBCode`** 后入缓存。→ 首次渲染一个楼层时若缓存未命中，会在 UI 线程解析，**长正文/大量节点会卡首帧**。
- **预热 API**（树模式全量展示前必须用）：
  - `preWarmBatchAwait(contents: string[], priority?: taskpool.Priority)`（`BBCodeCache.ets:112-148`）：taskpool 批解析，失败静默降级（`getCachedBBNodes` 届时同步解析）；`PARSE_TIMEOUT_MS = 30000`（`:12`）。
  - `preWarmPosts(posts: PostInfo[], includeSignatures: boolean, priority?)`（`common/utils/PostWarmup.ets:19-58`）：自动收集 `content + signature + comments.content + hotReplies.content`（跳过黑名单楼层），调用上面那个 await 版。
  - 现有调用点：`ThreadPanel.fetchPostsPage` 每页取回后立刻 `await preWarmPosts(result.posts, false, priority)`（`ThreadPanel.ets:1228-1232`）。→ **树模式抓全帖后应统一 `preWarmPosts(allPosts, false, HIGH)` 一次**，再切到树视图；否则逐节点同步解析会连续卡帧。
- **刷新语义（关键）**：`nodes` 不是 `@State`，**内容变了不会刷新**。要让某个树节点更新正文，只能：
  1. 改 LazyForEach 键值让它重建（现有做法：`uiRev`，`PostInfo.ets:29-34`）；
  2. 或给数据源 `updateAt` 换新 `PostInfo` 对象 + 键值含 `uiRev`。
- **组件内部缓存**：`aboutToAppear` 里 `splitIntoGroups` + 图片尺寸预填（`BBCodeContentView.ets:222-272`），`aboutToDisappear` 注销识图会话（`:280-286`）。组件被 LazyForEach 回收/复用时会重跑 `aboutToAppear`——所以树节点组件不要做「一次性的昂贵初始化」（如全量预计算），放 service/纯函数里。
- 正文图的 AI 识图会在滚动时取消选区（`ThreadPanel.ets:2581-2588` 的 `dismissAnalyzerSessions()`）；树模式换 List 时若沿用滚动容器，这段必须一起接（否则选区残留）。

### 3.4 折叠交互可借鉴模式（工程内盘点）

| 场景 | 文件:行号 | 实现 | 可借鉴点 |
|---|---|---|---|
| 附件「附件 (N) / 收起附件」 | `post-item/PostAttachments.ets:33-34`、`:51-54`、`:56-88` | `@State attachsExpanded`，点击切换 + 展开时才 `fetchAttachVideoSizes()`；`aboutToReuse` 重置 | **「展开更多」最标准的样板**：折叠文案带数量、展开时才做昂贵工作、复用时复位 |
| BBCode `[collapse]` 折叠块 | `BBCodeContentView.ets:132-133`、`:1466-1523` | `@State collapseKeys: Set<string>`（按标题记），`▾/▸` + 「点击展开」 | 树的两层折叠可参考（用 `Set<pid>` 记展开态） |
| 侧边栏分区折叠 | `CommunityPanel.ets:181-225`、`:250-269`；`LazyDataSource.ets:36-83` | `SidebarSection.collapsed` + `rev`；`ListItemGroup({ header })`；**LazyForEach 键值 `${id}_${collapsed}_${rev}`**（`:217`） | **两级渲染（分组头 + 分组内容）的现成范式**：`ListItemGroup` 的 header 就是「根节点」，group 内容就是「子回复」 |
| 帖子签名折叠 | `PostItem.ets:117-154` | `sigExpanded` + 预览文本 + `maxLines(4)` | 长文本摘要折叠 |
| 评论区（无折叠） | `post-item/PostComments.ets:98-172` | 全量 `ForEach` | 若要「超过 N 条折叠」，需自己加阈值 |
| Markdown 嵌套列表缩进 | `common/components/MdNodesView.ets:190-223` | 子列表 `padding({ left: 10 })` 嵌套递归 | 树的两层缩进视觉参考（缩进用 padding-left，不用空格文本） |
| 编辑器格式行折叠 | `common/components/EditorFormatBar.ets:193-272` | 第一行常显 + 第二行展开 | 底部操作条「展开更多」交互参考 |

---

## 4. 取数与进度

### 4.1 `ThreadApi` 三个入口签名（`service/api/ThreadApi.ets`）

```ets
// :358-379  HTML-only 取数原语：不解析、不过滤、不碰渲染状态；保证不抛异常（失败 raw=null）
export async function fetchThreadRaw(token: string, tid: string, pid: string,
  authorid: string, page: string): Promise<ThreadRawResult>

export interface ThreadRawResult {           // :59-64
  raw: Record<string, Object> | null         // 与内部帖子解析器兼容的同形状原始数据
  error: string                              // 失败信息；成功为空串
}

// :387-423  帖子详情（渲染整页的唯一取数入口）：解析 + 过滤 + 黑名单/备注/关键词
export async function getThread(token: string, tid: string, pid: string,
  authorid: string, page: string,
  blacklist: Set<string> = new Set(),
  keywords: string[] = [],
  noteMap: Record<string, string> = {}): Promise<ThreadResult>

// :451-530  pid → 页码二分查找（纯数据行为：只读 __R 页末 pid 与 __ROWS）
export async function locatePidPage(token: string, tid: string, targetPid: number,
  onProgress?: (done: number, total: number) => void): Promise<number>   // 失败/楼层不存在返回 -1

// :541-707  同形状原始数据 → ThreadResult（含 post 映射、分页、主题信息）
export function fillThreadResult(raw: Record<string, Object>, result: ThreadResult,
  blacklist: Set<string>, keywords: string[] = [], noteMap: Record<string, string> = {}): void
```

**分页字符串约定**：
- `page` 是**字符串**参数；`'1'` 起；**`'e'` 表示末页**（`ThreadApi.ets:87` 注释、`:458-460` 实际用法）。
- 请求路径固定 `/read.php` + `__output=17`（`buildThreadHtmlRequest`，`:89-105`）；`pid` 非空 → 单帖视图（分页语义不同，**不能用来建立连续窗口**，THREAD_DESIGN §5.3 第 3 条）。
- 单帖视图 0 楼层 → 归一为 `THREAD_FLOOR_MISSING_ERROR = '该楼层不存在或已删除'`（`:146`、`:234-245`、`:271-276`）。

**`ThreadResult` 关键字段**（`model/ThreadResult.ets:16-30`）：`threadInfo`、`forumName`、`pagination: ThreadPaging{page,totalPages,totalRows}`、`posts: PostInfo[]`、以及继承自 `ApiResult` 的 `ok`/`error`。

### 4.2 `withTimeout`

`common/utils/TimeoutUtils.ets:11-21`：

```ets
export function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T>
```

- 超时以 `Error('timeout')` 拒绝；`finally { clearTimeout(timer) }`（避免每次成功调用留下悬挂定时器——文件头注释解释了原因）。
- 工程内超时档位：常规页 15000ms（`ThreadPanel.ets:1259`、`:1373`）、单帖兜底回退 10000ms（`:1302`）、预取 10000ms（`:1582`）、`locatePidPage` 每步 15000ms（`ThreadApi.ets:460`、`:509`）、BBCode 批解析 30000ms（`BBCodeCache.ets:12`）。
- **树模式全量抓取建议**：每页包 `withTimeout(fetchThreadRaw(...), 15000)`，并别忘 `fetchThreadRaw` 自身「保证不抛异常」的语义（失败返回 `raw=null`，超时才会抛）。

### 4.3 `NgaThrottleSignals`（如何避免触发风控）

`service/api/NgaThrottleSignals.ets`（纯函数、无状态，供 `NgaClient` 决策）：

| 行号 | 内容 |
|---|---|
| `:18-22` | `DEFAULT_THROTTLE_COOLDOWN_MS = 60000`、`RETRY_BASE_DELAY_MS = 400`、`RETRY_MAX_DELAY_MS = 3000` |
| `:30-42` | 风控关键词（强特征词白名单：过于频繁/太频繁/刷新太快/频率限制/toomanyrequests…） |
| `:44-64` | `looksLikeThrottle(text): boolean` |
| `:66-120` | `READ_ONLY_OPERATIONS` 只读白名单（`lib/act` 组合） |
| `:122-134` | `isWritableOperation(lib, act)`：**不在白名单一律按写处理（不重试）** |
| `:136-148` | `retryDelayMs(attempt)`：指数退避封顶 3s |
| `:150-201` | `hasThrottleSignal(parsed)`：`code=15` / `error_code` / `error` 三种形态，**只看错误字段不扫正文** |

`NgaClient` 侧：重试带指数退避 + 命中风控进 60s 冷却（`NgaClient.ets:170` 注释、`:357`、`:549`）。

**树模式全量抓取的节流建议（照抄 `SavedThreadService`）**：

- 页间最小间隔 `SAVE_PAGE_INTERVAL_MS = 300`（`SavedThreadService.ets:25-26`、`:105-108`）——顺序抓取、不并发（并发 N 页会明显提高风控概率）。
- 单帖页数上限保护：先取总页数，超过阈值（如 200 页）提示「帖子过长，暂不支持递进树」而不是硬抓。
- 失败策略：任一页失败立即终止并提示（`SavedThreadService.ets:113-124`），不做「跳过该页继续拼树」——缺页会让引用关系断裂。
- 用户可取消（见 §4.4）。
- 不要用 `taskpool` 并发多页请求（`fetchThreadRaw` 内部已用 taskpool 做 HTML 解析，网络请求本身串行更安全）。

### 4.4 进度提示范式（可直接照抄）

#### (a) `SavedThreadProgressIndicator`（带取消，最贴近「长帖抓取」需求）

- 状态发布器：`common/media/SavedThreadProgress.ets:11-18`（`visible/percent/label`）+ `:32-45`（`show(percent,label)` / `hide()`）+ `:49` 单例 `savedThreadProgress`。
- 指示组件：`common/components/SavedThreadProgressIndicator.ets:22-109`：
  - `@State percent/-1, visible, label`；`@StorageProp('navBarHeight')`（`:26`）；
  - 150ms 轮询（`:19`、`:37-55`）；
  - UI：`Progress(Linear, 80×4)` + `Text('正在保存帖子')` + `label` + `percent%` + `Text('取消')`（点击 `savedThreadService.cancel()`，`:87-97`，`HitTestMode.Block` 独占拦截防误触下层）；
  - 定位：全屏 `Stack` + `alignContent(Alignment.Bottom)` + `margin({ bottom: TTS_PROGRESS_BOTTOM_MARGIN + navBarHeight })`（`:103-107`），**定位层 `HitTestMode.Transparent` 让空白区点击穿透**。
- 挂载点：`MainPage.ets:408-410`（与 Tts / PidLocate 并列）。

#### (b) `TtsProgressIndicator`（无取消，最简）

`common/components/TtsProgressIndicator.ets:15-79`：结构同上，无 label/取消；`TTS_PROGRESS_BOTTOM_MARGIN = 148`（`Constants.ets:48`）。

#### (c) `PidLocateIndicator`（`n/m` 步数文案，最适合「全帖抓取进度」）

`common/components/PidLocateIndicator.ets:19-76`：

- 状态：`step/total`；文案 `` `正在定位楼层… ${step}/${total}` ``（`:59-61`，`total<=1` 时只显示「正在定位楼层…」）。
- 位于 TTS 指示器**上方** `TTS_INDICATOR_OFFSET = 48`（`:16`、`:73`）——多个指示器同时出现时的避让范式。
- 状态管理器带**代际接管**（`PidLocateProgress.ets:31-81`：`begin()` 返回 generation，过期的 `show/hide` 被忽略）——树模式若可能连点/切帖，**必须照抄这个代际模式**，否则旧抓取任务的进度会污染新任务。

> 树模式建议：新写 `common/media/ThreadTreeProgress.ets`（照抄 `PidLocateProgress` 的代际版）+ `common/components/ThreadTreeProgressIndicator.ets`（照抄 `SavedThreadProgressIndicator`，文案改为「正在抓取全帖… n/N 页」+「取消」），挂到 `MainPage.ets:408-410` 旁；**或**复用 `savedThreadProgress`（会与真正保存帖子冲突，不推荐）。

#### (d) ThreadPanel 内联加载态

`ThreadPanel.ets:3046-3055` `LoadingState()` + `loadingContentOpacity` 的 400ms 延迟淡入（`:1330-1339`，`animateTo({duration:150})`）；页面级覆盖层用 `Stack` + `layoutWeight`，标题栏仍在上层（`PanelNavBar` 是 `position({x:0,y:0})`，见 `:2644-2654`）。

### 4.5 Toast API

`AppStore.ets:1488` / `:1497-1499`：

```ets
showToast(msg: string): void
showToastAction(msg: string, actionText: string, onAction: () => void): void   // 例：'回复成功' + '前往查看'
```

- 实现在 `ToastManager`，已迁到**系统浮层**（`PromptAction.openCustomDialog`），不在页面树内（`MainPage.ets:405-407` 注释）——所以 Toast 回调可能晚于面板销毁触发，**闭包内必须重新校验组件状态**（范式：`goToResumedPosition`，`ThreadPanel.ets:654-669`）。
- 树模式抓取失败/取消/完成可直接用 `appStore.showToast('...')`；「抓取完成」若需要动作，用 `showToastAction('已生成递进树', '查看', ...)`——但注意回调重入时的生命周期校验。

---

## 5. 测试与门禁

### 5.1 Hypium 用例注册方式

- 入口：`entry/src/test/List.test.ets`（106 行）。所有测试文件导出 `export default function xxxTest(): void`，在 `testsuite()` 里逐个调用（`:55-106`）。
- 新文件必须：① 建 `entry/src/test/<Feature>Unit.test.ets`；② `import xxxUnitTest from './<Feature>Unit.test'`（`:1-50` 的 import 区）；③ 在 `testsuite()` 里调用一次（`:56-105`）。
- 测试文件结构样板：`entry/src/test/ThreadPaginationUnit.test.ets:1-23`

```ets
import { describe, it, expect } from '@ohos/hypium'
import { ThreadPaginationManager, MergePageResult } from '../main/ets/common/managers/ThreadPaginationManager'
import { PostInfo } from '../main/ets/model/PostInfo'

export default function threadPaginationUnitTest(): void {
  describe('threadPaginationWindow', (): void => {
    it('commitsOnlyAdjacentPagesInBothDirections', 0, (): void => {
      const manager: ThreadPaginationManager = new ThreadPaginationManager()
      manager.replaceWith([createPost(50, 50)], 5, 8)
      expect(manager.loadedPageStart).assertEqual(4)
    })
  })
}
```

- **ArkTS 测试代码约束**（`entry/src/AGENTS.md` + `harmonyos-test` skill）：显式类型、禁 `any/unknown`、禁 `{}` 无类型字面量、新类/成员写 JSDoc、新 `.ets` 不用 `//` 单行注释、异步用例必须 `return` 等待链、不依赖执行顺序/真实网络/时间。

### 5.2 已有相关测试文件清单（`entry/src/test/`）

| 文件 | 与本功能的关系 |
|---|---|
| `ThreadPaginationUnit.test.ets`（314 行） | **最相关**：分页窗口不变量（相邻页提交/非相邻拒绝/空页推进/pid 去重/双向扩展同代际/mergePage 语义）——树模式若做「逐页 append 全帖」必须扩展它 |
| `QuoteInjectionUnit.test.ets` | 引用注入纯函数（quote 头解析结果）——树构建器的「引用提取」可参照其测试风格 |
| `BBCodeUnit.test.ets` | 解析器/渲染语义（树节点正文渲染依赖） |
| `HotReplyUnit.test.ets` | 热门回复解析（`hotReplies` 结构） |
| `TopicReadUnit.test.ets` / `HistoryReadLedgerUnit.test.ets` | 已读台账 |
| `AppThreadUnit.test.ets` | `getThread` 相关的 App HTML 解析映射 |
| `DataTransferUnit.test.ets` | settings 导入合并（`:73` 里有本地 `SettingsState` 复制类；新增字段若涉及导出/导入需同步检查） |
| `PersistenceCatalogUnit.test.ets` / `PersistenceMigrationUnit.test.ets` | 域清单与迁移（新增字段**无需**改，但若新增域才需要） |
| `List.test.ets` | 全部用例注册入口 |

> 建议新增 `ThreadTreeBuilderUnit.test.ets`（纯函数：建树 + 引用提取 + 环/自引用/缺失目标防御 + 两层平铺），在 `List.test.ets` 注册。**不要**把树构建逻辑写进 `.ets` 组件里（否则无法单测）。

### 5.3 编译验证命令（只记录，不执行）

**HAP 调试编译**（来源：skill `harmonyos-build-deploy`）：

```powershell
$env:DEVECO_SDK_HOME = 'C:/Program Files/Huawei/DevEco Studio/sdk'
$env:_JAVA_OPTIONS = '-Xmx1024m -Xms256m -XX:+UseSerialGC'
$env:NODE_OPTIONS = '--max-old-space-size=8192'
& 'C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw.bat' assembleHap --mode module -p module=entry@default -p buildMode=debug --no-daemon
```

- 成功判定：日志尾部出现 `BUILD SUCCESSFUL`，且 `entry/build/default/outputs/default/entry-default-signed.hap` 时间戳更新。
- 注意：PowerShell 下 `2>&1 | Select-Object` 会让退出码显示 1（NativeCommandError 噪音），以日志为准。
- **`assembleHap` 不编译 `entry/src/test`**，Hypium 用例必须走下面这条。

**Hypium Local Test**（来源：skill `harmonyos-test`）：

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' test -p module=entry -p coverage=false --no-daemon
```

- 结果文件：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`（必须确认修改时间是本次运行；要求 `Failure=0`、`Error=0`）。
- 日志：`entry/.test/default/intermediates/test/coverage_data/coverage.log`（尾部 250 行用于排查）。
- 判定纪律：`BUILD SUCCESSFUL` ≠ 用例通过；编译失败应报「测试未执行」。

### 5.4 行尾门禁与镜像门禁

**行尾**：`node scripts/check-eol.mjs`（`scripts/check-eol.mjs:1-56`）

- 检查：`node scripts/check-eol.mjs`（发现违规退出码 1）
- 修复：`node scripts/check-eol.mjs --fix`（字节级只删 CRLF 中的 CR，不触碰编码），之后 `git add` 并复查。
- 写文件一律用 write/edit 工具或 Node `writeFileSync`（内容用 `\n`）；**禁止** PowerShell `Out-File`/`Set-Content`/`echo >`，**禁止** `git checkout-index`/`git checkout -- .` 重写工作区（用 `git restore`）。

**TS 镜像门禁**（`bbcode-ts` skill）：`tools/bbcode-ts/src/` 是唯一真源，`scripts/sync-to-ets.mjs` 会把其中**每个 `.ts`** 机械写到 `entry/src/main/ets/` 同路径 `.ets`（`tools/bbcode-ts/scripts/sync-to-ets.mjs:18-20`、`:47-71`）。

- 动手前先自查：`node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry`（输出含目标 `.ets` → 必须走镜像流程；「0 修改」→ 可安全直接改）。
- 当前镜像清单（`tools/bbcode-ts/src/**`，共 31 个）：解析器、`parser/bbcode/*`、`parser/nga/html-thread/*`、`parser/_shared/*`、`common/utils/Utils.ts`、**`common/utils/QuoteInjectionCore.ts`**、`model/BBCodeNode.ts`、`common/components/bbcode/bbcode-utils.ts` 等。
- **树模式相关结论**：
  - `entry/src/main/ets/common/utils/QuoteInjectionCore.ets` **是镜像文件，禁止直接改**；引用正则 `P_REPLY_HEADER`（`:17`）与 `P_QUOTE_HEADER`（`:20`）可以 import 使用（模块已导出的是函数；正则是模块级常量未导出，所以树构建器需要**自己复制这两条正则**，或向 Lead 申请走镜像流程把提取函数加进 `tools/bbcode-ts/src`）。
  - 新文件 `common/utils/ThreadTreeBuilder.ets`、`common/model/ThreadTreeNode.ets`、`common/datasource/ThreadTreeNodeDataSource.ets`、`common/components/thread-tree/*` **不在镜像清单**，可安全直接写。

### 5.5 `docs/THREAD_DESIGN.md` 中与「新增渲染模式」相关的约束

| 章节:行号 | 约束 | 对树模式的含义 |
|---|---|---|
| §1.1 `:9-17` | 本文覆盖连续窗口/定位/前插锚点；正文渲染不属于本文 | 树模式属**渲染层扩展**，但不得改变分页/索引契约 |
| §1.2 `:19-27` | 演进分层：视觉实现不能成为修改分页索引、插入伪数据项的理由 | 树节点**不能**塞进 `postsDataSource` 冒充楼层（禁止伪 `ListItem` 的同类行为） |
| §2 `:40-50` | 连续滚动 7 条可观察行为；`ThreadNavMode.PAGE` 保持传统翻页 | 树模式是第三种阅读形态，需明确定义它是「独立模式」而不是「连续窗口的变体」 |
| §3 `:52-62` | 状态所有权表：mgr 唯一事实来源；dataSource 只镜像 | 树数据源**不得**再维护一份「哪些页已加载」的分页事实 |
| §4.1 `:65-86` | 连续页窗口 + 相邻页提交 + pid 去重 + mergePage 语义 | 全量抓取若走 `appendPosts` 必须逐页相邻；不要用 `replaceWith(全量)` |
| §4.2 `:88-103` | **零基索引**：`listPostIndex === managerPostIndex`；标题不占 ListItem；不得 `index±1` | 树节点列表是**另一条索引体系**，绝不能与 posts 索引混用 |
| §4.3 `:105-113` | 只有 REPLACE 推进代际；代际只增不归零 | 树模式切换若触发 REPLACE，旧请求自然失效 |
| §4.4 `:115-127` | REPLACE 定位是「挂载后事务」；`listMounted=false` 时 scrollToIndex 无效 | 树视图首次渲染后也要等 `onAppear` 再定位 |
| §5.1 `:153-173` | 跳页/只看楼主/回复编辑刷新不得继承旧 pid；静默刷新流程 | 切树模式要清 `pendingTargetPid`/`singlePostFallback`/`pendingTargetLastPost`（照抄只看楼主分支 `ThreadPanel.ets:2713-2716`） |
| §5.2 `:175-183` | 边缘加载与预取的暂停/空页推进语义 | 树模式应像 `PAGE` 一样关掉边缘加载（4 个短路点，见 §2.2 末尾） |
| §5.3 `:185-199` | 引用头第三段 = 页码；整页请求不带 pid；单帖兜底只有一次 | 树模式的「跳转箭头」定位应复用 `applyListNavigation` 语义，不要另发明一套 |
| §6 `:201-261` | 标题区几何、`contentStartOffset = statusBarHeight + NAV_BAR_H`、模糊/偏色、材质通道 | 树视图若换 `List`，必须沿用同一个 `contentStartOffset`、`linearGradientBlur`、`titleScrollEffectProgress`（否则标题区视觉退化） |
| §7 `:358-372` | 已知故障模式表（伪 ListItem、挂载前滚动、前插锚点、静默刷新代际、`uiRev` 刷新） | 树模式最容易踩的两条：键值不含折叠态 → 折叠不刷新；内容变化不增 `uiRev` → 正文不刷新 |
| §9.1 `:399-405` | 自动验证：API 26 debug HAP 构建通过 + `ThreadPaginationUnit.test.ets` 通过 | 树模式**新增纯逻辑必须有单测**；改动分页管理器必须扩展该测试 |
| §10 `:430-440` | 维护规则：改窗口语义要同步 mgr/测试/文档 | 若最终选择「树模式复用 mgr」，必须同步更新本文档 |

> **一句话**：THREAD_DESIGN 把「帖子数组 + 页窗口」定为唯一真源，把「列表索引」定为零基且与 manager 索引一一对应。树模式引入第二条排序/分组维度， safest 的做法是**独立的展示数据源 + 独立的 List**，ThreadPanel 只做模式分流与回调转发。

---

## 6. 现有基础设施盘点（可复用 / 不可复用）

### 6.1 树形 / 分组渲染

| 设施 | 文件:行号 | 结论 |
|---|---|---|
| 侧边栏分组（两层） | `CommunityPanel.ets:181-225`（`ListItemGroup({ header })`）、`:250-269`（分组头折叠箭头） | **工程内唯一的「两级列表」实现**：`LazyForEach(sidebarDataSource)` + 每个元素是 `ListItemGroup`，header 是根、group 内是子项。树模式可借用「分组头 + 分组内容」的布局思路，但**不建议**直接复用 `ListItemGroup`（它的 header 固定在组顶、组内滚动联动语义与树节点折叠不完全一致；且树需要「根节点本身也是完整楼层卡片」） |
| 分组数据源扩展 | `LazyDataSource.ets:57-83`（`SidebarDataSource.updateSection` / `indexOf`）、`:36-50`（`SidebarSection` 含 `collapsed/rev`） | **数据源层可复用的模式**：`rev` 版本号进 LazyForEach 键值（`CommunityPanel.ets:217` `key = id_collapsed_rev`） |
| Markdown 嵌套列表缩进 | `MdNodesView.ets:190-223` | 只有视觉缩进，不是数据层树 |
| BBCode 折叠块 | `BBCodeContentView.ets:1466-1523` | 正文内折叠，可借鉴交互，不是楼层树 |
| 结论 | — | **没有现成的「楼层树」组件/数据源**，必须新写；但「分组 + 版本号键值」和「折叠展开」两块模式齐全 |

### 6.2 折叠展开 / 底部操作条 / 浮动进度层

| 能力 | 现状 | 可复用度 |
|---|---|---|
| 折叠展开 | `PostAttachments`（`:56-88`）、`BBCodeContentView.RenderCollapse`（`:1466-1523`）、`EditorFormatBar`（`:193-272`）、`CommunityPanel` 分组折叠 | 🟢 模式齐全，直接照抄 |
| 底部操作条 | `ThreadPanel.BottomBar()`（`:2886-3040`）：`Row({space:8})` + 分页条 `HdsMaterialHost`（`:2895`）+ 回复按钮 `HdsMaterialHost`（`:3015`）；左手布局 `justifyContent(FlexAlign.Start)`（`:3039`） | 🟢 树模式若要「全部展开/收起 + 回到列表」，可扩成第三颗材质按钮 |
| 浮动进度层 | `SavedThreadProgressIndicator` / `TtsProgressIndicator` / `PidLocateIndicator` 三件套 + `MainPage.ets:408-410` 挂载 | 🟢 直接照抄（见 §4.4） |
| 浮动按钮 | `TopicListPanel.FloatingActions()`（`:1366-1395`，`HdsMaterialHost barWidth/barHeight 44`） | 🟢 需要右下角常驻按钮时参考 |
| 材质宿主 | `HdsMaterialHost.ets:65-90`（`barWidth/barHeight/contentPadding/barBottomMargin/onTap` + `@BuilderParam content`，必须尾随闭包传，不能方法引用） | 🟢 内容区唯一真材质通道（API 26 Release 门禁），新增浮动控件必须用它 |

### 6.3 `LazyDataSource` / `BaseLazyDataSource` 接口定义

`common/datasource/BaseLazyDataSource.ets:13-145`：

```ets
export class BaseLazyDataSource<T> implements IDataSource {
  protected dataList: T[] = []                                  // :15 子类可直接读写
  totalCount(): number                                          // :21-23
  getData(index: number): T                                     // :26-28
  registerDataChangeListener(listener: DataChangeListener): void     // :35-39
  unregisterDataChangeListener(listener: DataChangeListener): void   // :46-51
  replaceAll(list: T[]): void                                   // :58-64  → notifyReload()
  appendAll(list: T[]): void                                    // :71-77  → 逐项 notifyAdd(start+i)
  prependAll(list: T[]): void                                   // :84-89  → 逐项 notifyAdd(i)
  clear(): void                                                 // :92-95  → notifyReload()
  updateAt(index: number, item: T): void                        // :104-110 → notifyDataChange(index)
  length(): number                                              // :113-115
  protected notifyReload(): void                                // :118-122 → listener.onDataReloaded()
  protected notifyAdd(index: number): void                      // :129-133 → listener.onDataAdd(index)
  protected notifyDataChange(index: number): void               // :140-144 → listener.onDataChange(index)
}
```

- `common/datasource/LazyDataSource.ets:12-14`：`class PostInfoDataSource extends BaseLazyDataSource<PostInfo> {}`——**空子类**，全部能力来自基类。
- **缺口**：没有 `onDataDelete` / `onDataMove` 通知原语。树节点的「折叠收起子节点」「展开插入子节点」如果采用「原地增删」，必须给新数据源加 `deleteAt(index)`（内部 `dataList.splice` + `listener.onDataDelete(index)`）与 `insertAt(index, item)`（`onDataAdd`）。**更稳的做法**：树用「扁平的可见节点数组」，每次展开/折叠**重建整个数组并 `replaceAll`**（简单、键值稳定、性能可接受——树规模 = 楼层数，长帖 2000 级重建一次数组约毫秒级），代价是全列表重绘（有 `cachedCount` 与键值复用，实际可见区影响有限）。二选一由 Lead 拍板，报告给出两条路。
- ArkUI `IDataSource` 的完整通知集合以本地 SDK 声明为准（`DataChangeListener`），不要凭记忆写 `onDataDelete` 的参数。

---

## 7. 实现工作拆分建议（谁写哪个文件 / 冲突点）

### 7.1 新增文件清单

| 新文件（建议路径） | 职责 | 写入归属 | 依赖 |
|---|---|---|---|
| `entry/src/main/ets/common/model/ThreadTreeNode.ets` | 树节点模型：`post: PostInfo`、`parentPid: number`、`children: PostInfo[]`（两层平铺时只需 `rootIndex`）、`replyToLou: number`、`refPid: number`、`expanded: boolean`、`rev: number` | 数据层成员 | `PostInfo` |
| `entry/src/main/ets/common/utils/ThreadTreeBuilder.ets` | **纯函数**：`extractQuoteRefs(content): QuoteRef[]`（正则提取被引用 pid/作者/页码）、`buildThreadTree(posts: PostInfo[]): ThreadTreeNode[]`（两层：根 + 直接引用者；深层引用平铺到最近的第二层祖先）、防御：自引用/环/目标缺失/主楼 | 数据层成员（**必须可单测**） | `PostInfo`、`model/BBCodeNode.ets`（可选） |
| `entry/src/test/ThreadTreeBuilderUnit.test.ets` | 上述纯函数的 Hypium 用例；在 `List.test.ets` 注册 | 数据层成员 | `@ohos/hypium` |
| `entry/src/main/ets/common/datasource/ThreadTreeNodeDataSource.ets` | `extends BaseLazyDataSource<ThreadTreeNode>` + `findIndexByPid(pid)` +（若选增删路径）`deleteAt/insertAt` | 数据层成员 | `BaseLazyDataSource` |
| `entry/src/main/ets/service/ThreadTreeFetchService.ets` | **全帖抓取服务**：先取总页数（`locatePidPage` 式 `__ROWS` 计算或第 1 页 `pagination.totalPages`）→ 顺序逐页 `getThread`/`fetchThreadRaw`+`fillThreadResult` → 300ms 节流 → 进度发布（代际版）→ 可取消 → 结束后 `preWarmPosts(allPosts, false, HIGH)` → 返回 `PostInfo[]` | 数据层成员 | `ThreadApi`、`PostWarmup`、`ThreadTreeProgress` |
| `entry/src/main/ets/common/media/ThreadTreeProgress.ets` | 进度状态 + 代际接管管理器（照抄 `PidLocateProgress.ets:19-84`） | 数据层成员 | — |
| `entry/src/main/ets/common/components/ThreadTreeProgressIndicator.ets` | 全局指示器（照抄 `SavedThreadProgressIndicator.ets`，文案「正在抓取全帖… n/N 页」+ 取消） | UI 层成员 | `ThreadTreeProgress` |
| `entry/src/main/ets/common/components/thread-tree/ThreadTreeView.ets` | 树视图容器：`List` + `LazyForEach(treeDataSource)` + 根/子节点渲染 + 折叠状态 + `onScrollToNode(pid)` | UI 层成员 | `ThreadTreeNodeItem`、`PostItemHeader`、`BBCodeContentView` 等 |
| `entry/src/main/ets/common/components/thread-tree/ThreadTreeNodeItem.ets` | 单个树节点：缩进块 + 「X1 回复 X2」头部 + `@作者`（可点）+ 跳转箭头 + 正文/折叠子回复 | UI 层成员 | §3.2 子组件 |

### 7.2 修改文件清单

| 文件 | 改动 | 写入归属 | 冲突风险 |
|---|---|---|---|
| `store/settings/SettingsState.ets` | 新增 `threadRenderMode` 字段 | 设置链路 owner（单一成员） | 🔴 与 SettingsPanel/SettingsStore 同 owner，避免多头改 |
| `store/settings/domain/ReadingSettings.ets` | setter + `load()` | 同上 | 同上 |
| `store/SettingsStore.ets` | 门面 setter（+ 可选 AppStorage 同步、`reset` 归一） | 同上 | 同上 |
| `common/constants/Constants.ets` | `ThreadRenderMode` 常量类 + `SettingsIconColors.threadRender` | 同上 | 🟡 大文件，多人改易冲突（把改动限制在文件末/对应 class 内） |
| `common/constants/AppStorageKeys.ets` | （仅方案 B）新增 KEY | 同上 | 🟢 小 |
| `pages/SettingsPanel.ets` | badge @State / label / options / picker / 一行 UI / dispose | 同上 | 🔴 与 §1 链同 owner |
| `pages/ThreadPanel.ets` | 模式状态 + 菜单项 + `loadTree` 分支 + 4 处短路 + 树视图挂载 + 进度/取消接线 + 定位/进度/静默刷新适配 | **只能由 Lead 集成**（或指定唯一 owner） | 🔴🔴 全工程最热文件（3090 行，复用极多）；多人并行改必冲突 |
| `pages/MainPage.ets` | 挂 `ThreadTreeProgressIndicator()`（若用全局指示器） | Lead 集成 | 🟡 一行，但 MainPage 是多列布局核心 |
| `entry/src/test/List.test.ets` | 注册新用例 | 数据层成员 | 🟢 单行 |

### 7.3 建议的并行分工

| 成员 | 写入范围 | 可独立完成 | 交付门槛 |
|---|---|---|---|
| **数据层成员** | `ThreadTreeNode.ets`、`ThreadTreeBuilder.ets`、`ThreadTreeBuilderUnit.test.ets`、`ThreadTreeNodeDataSource.ets`、`ThreadTreeFetchService.ets`、`ThreadTreeProgress.ets`、`List.test.ets` 一行 | ✅ 可先于 UI 开工：纯函数 + 抓取服务 + 单测 | `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` 0 修改；`hvigorw test` 通过（或至少 HAP 编译）；`node scripts/check-eol.mjs` 通过 |
| **设置链路成员** | `SettingsState.ets`、`ReadingSettings.ets`、`SettingsStore.ets`、`Constants.ets`（两处）、`AppStorageKeys.ets`、`SettingsPanel.ets`、新图标资源 | ✅ 与树逻辑解耦，可并行 | HAP 编译通过；设置页手动核对（不启动应用则由 Lead 验） |
| **UI 层成员** | `thread-tree/ThreadTreeView.ets`、`thread-tree/ThreadTreeNodeItem.ets`、`ThreadTreeProgressIndicator.ets` | 🟡 可先按「固定输入的受控组件」写（props：nodes/nodesDataSource/回调），不依赖 ThreadPanel 接线 | HAP 编译通过；组件签名与 §3.2 回调对齐 |
| **Lead** | `ThreadPanel.ets`（集成）、`MainPage.ets`、模式分流与 4 处短路、进度/取消接线、定位与进度适配、最终门禁 | 必须在数据层/UI 层产出后集成 | 全量 HAP 编译 + Hypium + `check-eol` + 真机核对（由用户决定） |

### 7.4 并行冲突点与必须串行的决策

1. **`ThreadPanel.ets` 单点**：所有模式分流、短路、定位适配都在这里。**只有 Lead 写**。其他成员对它的需求以「接口清单」形式提给 Lead（例如：`onJumpToPid(pid): void`、`onProfileClick`、`onVote` 等透传）。
2. **设置链路串行**：`SettingsState → ReadingSettings → SettingsStore → Constants → SettingsPanel` 是同一条链，拆给两人会出现「字段名不一致 / load 漏字段 / badge 不同步」。**一个 owner 一次做完**。
3. **符号约定要提前冻结**：字段名（建议 `threadRenderMode`）、常量类名（`ThreadRenderMode.LIST/TREE`）、AppStorage 键（`threadRenderMode`）、菜单文案（`递进树阅读`）、进度文案（`正在抓取全帖… n/N 页`）、树节点头部文案模板（`X1 回复 X2` 中 X 用楼层号还是「楼主」）。**先由 Lead 在任务板写下，再开工**。
4. **树模式与「只看楼主」共存**：`authorOnly` 会过滤掉非楼主楼层（`ThreadPanel.ets:1201-1227`），引用关系大量断裂。建议：树模式下**禁用只看楼主**（切换时清 `authorOnly`）或在抓取完成后本地过滤再建树（过滤后「被引用者不存在」的节点降级为根）。必须由 Lead 定。
5. **树模式与「阅读进度」共存**：见 §2.7 冲突说明。建议树模式暂停记录/恢复（`shouldRecordProgress()` 返回 false + `tryRestoreReadingProgress()` 早退），并在报告外记录产品决策。
6. **树模式与「离线存档/只看楼主/静默刷新」**：`isSavedSource()`（`ThreadPanel.ets:2025-2027`）下 `getSavedThreadResult` 已能取单页，但存档页数有限；树模式在存档来源下应直接禁用（或仅对已存页建树）。回复/编辑的 `silentRefreshAfterPost` 必须让树索引失效重建（最简：树模式下静默刷新成功后 `rebuildTree()`，不做增量）。
7. **`Constants.ets` / `SettingsPanel.ets` 与 UI 层成员无交集**，可安全并行。

---

## 8. 坑清单（实现时容易踩、且不会报错的）

| # | 坑 | 证据 | 规避 |
|---|---|---|---|
| 1 | **`BBCodeContentView.nodes` 不是响应式字段**，改了 nodes 不刷新 | `BBCodeContentView.ets:131` | 键值含 `uiRev`，靠 LazyForEach 重建 |
| 2 | **LazyForEach 键值不含折叠态 → 点折叠无反应** | 侧边栏范式 `CommunityPanel.ets:217`；`docs/THREAD_DESIGN.md:371` | 树节点键值必须含 `expanded`/`childCount`/`rev` |
| 3 | **`@Prop @Watch` 的 `navEntryId` 是定位触发器**，树模式切换不要复用它 | `ThreadPanel.ets:191`、`:769-779` | 新增独立状态，不要借用路由字段 |
| 4 | **`scrollToIndex` 在 List 未挂载时静默无效** | `docs/THREAD_DESIGN.md:127`；`ThreadPanel.ets:658-665` | 树视图 `onAppear` 置 `treeListMounted` 后再定位 |
| 5 | **`pendingTargetPid` 不清会与树模式抓取交错**，导致抓完又触发单帖兜底 | `ThreadPanel.ets:932-946`、`docs/THREAD_DESIGN.md:199` | 切模式时照抄 `只看楼主` 分支清 3 个字段（`:2713-2716`） |
| 6 | **整页请求带 pid 会返回单帖视图**（分页语义全变） | `ThreadApi.ets:87`、`docs/THREAD_DESIGN.md:193` | 全量抓取永远不带 pid；只有单帖兜底才带 |
| 7 | **`totalPages` 被单帖响应重置为 1** | `ThreadPanel.ets:1416-1420`、`ThreadPaginationManager.ets:62` | 全量抓取自己记 totalPages，不读写 `mgr.totalPages` 作为唯一来源 |
| 8 | **AppStorage 旧值在 `reset()` 后残留**（切号后继承上一个账号的设置） | `SettingsStore.ets:122-125` 注释 | 新键必须显式归零；或干脆不用 AppStorage（方案 A） |
| 9 | **`@StorageProp` 参数必须写字面量**，不能引用 `AppStorageKeys` 常量 | `AppStorageKeys.ets:5-11` | 使用处写 `@StorageProp('threadRenderMode')`，与常量手工对齐 |
| 10 | **`PostItem` 的 `@Prop post` 是值拷贝**：只改 `mgr.posts[i]` 的字段不会刷新 | `PostItem.ets:27`、`ThreadPanel.ets:2558` | 改内容必须 `uiRev++` + `updateAt`（活动范式 `:1778-1786`） |
| 11 | **`blacklistVersion` 的「冗余读」不能优化掉**，否则组件不再订阅 | `PostItem.ets:80-83` | 新树节点若自绘屏蔽判断，照抄该依赖写法 |
| 12 | **`IParam`/`@Prop` 不能传函数** | `PanelNavBar.ets:91-101`、`SettingRow.ets:19` | 全部用普通箭头属性 |
| 13 | **`@Builder` 按值传参会静默不刷新** | `entry/src/AGENTS.md`（ArkUI 响应式章节）、`PanelNavBar.ets:142-153` | 树节点组件的可变值一律经 `this` 读 |
| 14 | **`HdsMaterialHost.content` 必须尾随闭包传**，方法引用会让 `this` 指错 | `HdsMaterialHost.ets:82-86`、`entry/src/AGENTS.md` | 新增浮动按钮照抄 `ThreadPanel.ets:3015-3036` |
| 15 | **`QuoteInjectionCore.ets` 是镜像文件，手改会被下次 sync 覆盖** | `tools/bbcode-ts/scripts/sync-to-ets.mjs:47-71`；镜像清单含 `common/utils/QuoteInjectionCore.ts` | 新正则写进新文件；要改真源须走 `tools/bbcode-ts` + `npm test` + `npm run sync` |
| 16 | **引用正则对 HTML 降级通道/转义敏感**：`[quote]` 与 `[b]Reply to` 两种形态都要覆盖 | `QuoteInjectionCore.ets:17`、`:20` | 树构建器提取时同时匹配两种头；对 `&quot;` 等实体先按现有 `unescapeHtml` 处理（`ThreadPanel.ets:37` import 用法、`:2523` 编辑回显） |
| 17 | **匿名楼层 uid 是页内局部负数**，跨页不可比 | `model/PostInfo.ets:38-49`、`ThreadPanel.ets:2106-2140` | 引用关系只能按 **pid** 建，不能按 uid/作者名建 |
| 18 | **`savedThreadProgress` 是全局单例**，树模式若复用它，会和「离线保存帖子」互相覆盖进度 | `SavedThreadProgress.ets:49` | 新写独立单例（带代际） |
| 19 | **进度指示器轮询靠 150ms 定时器**，组件必须 `aboutToDisappear` 清定时器 | `SavedThreadProgressIndicator.ets:33-35` | 照抄 |
| 20 | **`preWarmPosts` 是异步且静默降级**，不 await 也可能首帧同步解析 | `PostWarmup.ets:51-58`、`BBCodeCache.ets:71-78` | 全帖抓取完成后 `await preWarmPosts(all, false, HIGH)` 再切树 |
| 21 | **长帖规模**：100 页 × 20 楼 = 2000 楼，O(n²) 建树会卡 | 全帖抓取场景 | 建树用 `Map<number, PostInfo>` 一次索引；两层平铺 O(n) |
| 22 | **`PostInfo.lou === 0` 是主楼**，楼层号文案 `lou===0?'楼主':lou===1?'沙发':'#N'` | `PostItemHeader.ets:60` | 「X1 回复 X2」的 X 用同一套文案规则，避免出现 `#0` |

---

## 附录 A：行号速查（按文件）

| 文件 | 行数 | 关键行号 |
|---|---|---|
| `store/settings/SettingsState.ets` | 96 | 19-20 类；32 showSignature；37 imageLoadStrategy；45 showTopicPreview；46 threadNavMode；48 prefetchPageCount；50 recordReadingProgress |
| `store/settings/SettingsContext.ets` | 25 | 15-24 上下文 |
| `store/settings/domain/ReadingSettings.ets` | 44 | 17-20/22-26/28-32 setter；34-43 load |
| `store/SettingsStore.ets` | 353 | 73-85 构造；100-106 init；109-127 reset；135-144 persist；146-180 load+AppStorage；282-286 Reading 门面 |
| `common/constants/AppStorageKeys.ets` | 163 | 5-11 字面量约定；52 showSignature；109 contentFontSize |
| `common/constants/Constants.ets` | 447 | 13 NAV_BAR_H；48 TTS_PROGRESS_BOTTOM_MARGIN；95 TITLE_POD_SIZE；98+ AppColors；125 toastAccent；135 chevron；156 quoteBorders；200-239 SettingsIconColors；309-316 ThreadNavMode |
| `pages/SettingsPanel.ets` | 862 | 51-53 badge；144-170 buildRadioContent；172-178 aboutToAppear；385-421 threadNav picker；600-688 Block 3A；646-652 threadNav 行；666-672 阅读进度行 |
| `pages/ThreadPanel.ets` | 3090 | 见 §2 全表 |
| `common/components/PanelNavBar.ets` | 434 | 27-34 NavBarMenuItem；154-187 iconPod；253-263 navBarMenu；270-272 provider；287-297 菜单参数 |
| `common/components/PostItem.ets` | 217 | 24-69 签名；85-195 build；80-83 黑名单依赖 |
| `common/components/post-item/PostItemHeader.ets` | 64 | 16-23 签名；49-58 资料卡回调；60 楼层号文案 |
| `common/components/post-item/PostVoteBar.ets` | 392 | 13-51 签名；53-77 生命周期/同步 |
| `common/components/post-item/PostComments.ets` | 173 | 74-96 签名/黑名单；98-172 build（100 注释：不再折叠） |
| `common/components/post-item/HotRepliesSection.ets` | 132 | 18-40 签名；42-131 build |
| `common/components/post-item/PostAttachments.ets` | 215 | 26-40 签名；51-54 复用重置；56-88 折叠展开 |
| `common/components/BBCodeContentView.ets` | 1786 | 129-161 签名；222-286 生命周期；1466-1523 RenderCollapse |
| `parser/bbcode/BBCodeCache.ets` | 148 | 10 缓存容量；71-78 getCachedBBNodes；100-148 preWarmBatch |
| `common/utils/PostWarmup.ets` | 58 | 19-41 收集；51-58 preWarmPosts |
| `common/datasource/BaseLazyDataSource.ets` | 145 | 13-144 接口全集 |
| `common/datasource/LazyDataSource.ets` | 119 | 12-14 PostInfoDataSource；36-83 Sidebar 分组范式 |
| `common/managers/ThreadPaginationManager.ets` | 380 | 12-13 类；32-43 reset；52-63 replaceWith；119-161 append/prepend；215-235 查询；285-336 mergePage |
| `common/managers/PaginationManager.ets` | 126 | 18-24 状态；34-44 代际；52-56 applyState；71-114 预取原语 |
| `service/api/ThreadApi.ets` | 763 | 87/89-105 分页约定；146 楼层缺失文案；234-245 单帖视图判定；358-379 fetchThreadRaw；387-423 getThread；451-530 locatePidPage；541-707 fillThreadResult |
| `service/SavedThreadService.ets` | 297 | 25-26 节流；70-171 全帖逐页抓取；200-206 sleep |
| `common/utils/TimeoutUtils.ets` | 21 | 11-21 withTimeout |
| `service/api/NgaThrottleSignals.ets` | 219 | 18-22 常量；30-42 关键词；76-120 只读白名单；136-148 退避；150-201 风控判定 |
| `common/media/SavedThreadProgress.ets` | 49 | 11-18 状态；32-45 发布/隐藏 |
| `common/components/SavedThreadProgressIndicator.ets` | 110 | 19 轮询间隔；37-55 轮询；57-109 UI |
| `common/media/PidLocateProgress.ets` | 84 | 19-26 状态；31-81 代际管理器 |
| `common/components/PidLocateIndicator.ets` | 77 | 59-61 步数文案；54-76 UI |
| `common/media/TtsProgress.ets` / `TtsProgressIndicator.ets` | — | 轮询式最简范式 |
| `common/components/PageStateView.ets` | 76 | 13-23 Loading；35-50 Error；64-76 Empty |
| `pages/MainPage.ets` | 767 | 404-410 全局指示器挂载 |
| `pages/CommunityPanel.ets` | 644 | 181-225 分组列表；250-269 分组头折叠 |
| `common/components/HdsMaterialHost.ets` | 135 | 65-90 参数；82-86 @BuilderParam 约定 |
| `pages/ActivityRouter.ets` | 165 | 62-73 ThreadPanel 挂载 |
| `store/RouterStore.ets` | 429 | 93-110 ThreadSource；145-155 Screen.thread |
| `store/ReadingProgressStore.ets` | 141 | 8-17 进度条目 |
| `common/infra/PreferencesStore.ets` | — | 55-65 putJSON(flush)；67-72 flush；131-135 scheduleFlush(debounce 500ms) |
| `store/AppStore.ets` | 1502 | 857-858 settings getter；1106/1110 进度读写；1488/1497 Toast |
| `entry/src/test/List.test.ets` | 106 | 1-50 import；55-106 testsuite |
| `docs/THREAD_DESIGN.md` | 450 | 见 §5.5 表 |
| `scripts/check-eol.mjs` | 56 | 1-56 用法与修复 |

## 附录 B：可直接照抄的代码片段索引

| 需求 | 照抄目标 |
|---|---|
| 新增设置项 UI（选择器行） | `SettingsPanel.ets:646-652` + `:385-421` + `:156-170` |
| 新增设置字段（全链路） | §1.2 表格，逐行 |
| 标题菜单「切换项」 | `ThreadPanel.ets:2709-2719` + `PanelNavBar.ets:27-34` |
| 全帖逐页抓取 + 进度 + 取消 + 节流 | `SavedThreadService.ets:70-171`（删掉 `savedThreadStore.save` 与存档字段，改为返回 posts） |
| 进度指示器（带取消） | `SavedThreadProgressIndicator.ets:22-109` + `SavedThreadProgress.ets:11-46` |
| 进度管理器（代际防串台） | `PidLocateProgress.ets:31-81` |
| 折叠/展开（带数量文案、复用重置） | `PostAttachments.ets:33-88` |
| 两级列表（分组头 + 内容） | `CommunityPanel.ets:181-225` + `LazyDataSource.ets:36-83` |
| 树节点复用（头部/正文/动作栏） | §3.2 三个 snippet |
| 内容变化刷新（uiRev） | `ThreadPanel.ets:1778-1786` + `ThreadPaginationManager.ets:321-323` |
| 定位到楼层（含未挂载校验） | `ThreadPanel.ets:787-795` + `654-669` |
| 全帖总页数计算 | `ThreadApi.ets:458-477` |
| 引用头正则 | `QuoteInjectionCore.ets:17`（Reply to）、`:20`（`[pid=A,B,C]`）——复制到新文件，不要改镜像文件 |
| 空/错误/加载态 | `PageStateView.ets:13-76` + `ThreadPanel.ets:3046-3070` |
| 材质浮动按钮 | `ThreadPanel.ets:3015-3036` / `TopicListPanel.ets:1366-1395` |

---

*本报告仅覆盖只读调研，未修改任何源码、未启动应用、未执行编译。所有行号基于本次读取的工作区快照。*

