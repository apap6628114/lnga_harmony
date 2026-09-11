# 手搓 UI → 官方推荐组件迁移记录

> 迁移目标：把工程里「手搓形态」的 UI 承载方式（`Stack` + 全屏遮罩模拟弹窗、`Stack` + `position` 模拟气泡等）
> 换到鸿蒙官方推荐的承载 API，同时保持磨砂玻璃视觉不退化。
>
> 权威依据：本地 SDK 声明文件（API 26.0.0，`C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\ets\`）
> 与 `docs/IMMERSIVE_LIGHT_DESIGN.md`（工程玻璃契约）。
>
> 所有迁移项均通过 `hvigorw assembleHap` 编译验证（BUILD SUCCESSFUL），最终 HAP 已安装到模拟器
> `Huawei_TripleFold` 并启动确认。

---

## 1. 为什么迁移

`docs/IMMERSIVE_LIGHT_DESIGN.md` 的两条既有约定直接指向本项工作：

- §7.3：「不要用 `Stack` + `Visibility` 自己模拟弹窗并把材质加在外层容器上；这类普通容器仍然受生效范围限制。
  **应使用官方弹窗 API 的 options 设置 `systemMaterial`**。」
- §13 审查规则 11：「是否把自定义弹窗写成普通 Stack 模拟而不是使用 Dialog/Popup/Menu 等官方接口？」

迁移前工程的浮层体系正是 `FloatingLayerComponent`（一个全屏 `Stack` + 手搓遮罩 + 手搓定位）承载
图片查看器、资料卡、回复编辑器、发新主题与两类确认框；系统因此无法参与弹层的动效、手势与键盘避让。

---

## 2. 官方 API 能力边界（实测声明文件结论）

迁移前先核对了 API 26 SDK 的真实能力，几条与直觉不同的关键事实：

| 事实 | 依据 |
| --- | --- |
| `SheetOptions.blurStyle` 默认 `BlurStyle.NONE`、`BindOptions.backgroundColor` 默认 `Color.White` | 半模态**默认没有模糊且是不透明白底**，不改就不可能露出玻璃 |
| `bindSheet` / `bindContentCover` 声明明确写有「cannot be called within `attributeModifier`」 | 不能把这两个 API 塞进工程的 `GlassModifier` |
| `systemMaterial` 与 `backgroundColor` / `border` / `shadow` 是接管关系 | 走自绘玻璃时就不要同时设系统材质，避免双层背景 |
| `Placement` 枚举取值是 `Bottom` / `BottomLeft` 等 PascalCase | `Placement.BOTTOM_START` 一类写法不存在 |
| `bindPopup` 的位置由**锚点组件的几何区域**经 `placement` 推导，`offset` 只是相对该推导结果的微调 | 它表达不了「任意屏幕坐标气泡」；零尺寸锚点更会让内容完全不渲染（实测，见 §4 资料卡） |
| `CustomContentDialog` 是官方高级对话框里**唯一**支持自定义内容的模板 | 输入类弹窗只能用它 |
| `@BuilderParam` 传值要写 `this.xxx`（不带括号），而 `CustomBuilder` 位置写 `this.xxx()` | 写错会报 `Type 'void' is not assignable to type '() => void'` |
| 官方 `contentBuilder` 里的 @Builder 在**对话框组件内部**执行 | 不能用 `$变量` 绑定调用方的 @Link：源状态在那一层不存在，打开对话框即闪退（见 §3.2） |
| 官方 `ConfirmDialog` / `TipsDialog` 带 `checkTips` + `isChecked` 复选框字段 | `ConfirmDialog` 不传 `checkTips` 时仍会渲染一个**没有文字的孤立复选框**（实测）；无图标场景改用它同族的 `AlertDialog`（无复选框字段）。`TipsDialog` 实测不显示孤立复选框 |
| `ComposeTitleBar` / `SelectTitleBar` / `EditableTitleBar` 都**没有** `onBack` 回调，也没有标题区 `@BuilderParam` 槽 | 官方标题栏无法承载自定义返回拦截 |
| `ComposeListItem` 的 `IconType` 是**图标尺寸**枚举（8/16/24/40/64/96vp），不是「带角标」 | 无法表达自定义色块图标 |

---

## 3. 已迁移清单

### 3.1 浮层体系（`FloatingLayerComponent`）

| 原实现 | 迁移后 | 视觉策略 |
| --- | --- | --- |
| 回复编辑器 / 发新主题：全屏 `Stack` 遮罩 + 手搓居中/底部定位 | `bindSheet` 半模态（`sm` 用 `SheetType.BOTTOM`，`md+` 用 `SheetType.CENTER` 保持居中浮层形态） | sheet 背景置 `Color.Transparent`、`blurStyle` 默认 NONE、蒙层色对齐 `AppColors.overlay`；外观仍由内容容器的 `surfaceMaterial` 磨砂玻璃承担 |
| 图片查看器：同层 `Stack` 内渲染 | `bindContentCover` 全屏模态 | 内容自带暗场景底色，`modalTransition` 用系统默认 |
| 通用确认框（`floatingLayerStore.showConfirm`） | 官方 `ConfirmDialog`，调用点下移到唯一使用方 `BrowseHistoryPanel` | 官方模板样式，主按钮保留 `AppColors.destructive` 实底 |
| 「放弃编辑」确认框（`replyConfirmActive`） | 官方 `ConfirmDialog`，下移到 `ReplyDialog` / `NewTopicDialog` 各自的 `CustomDialogController` | 同上 |

副作用（正向）：`FloatingLayerStore` 不再保存确认框状态，`FloatingPage` 从 6 个枚举减到 5 个，
`MainPage.onBackPress` 的返回分支同步简化。

### 3.2 对话框（`common/dialogs/`）

| 原实现 | 迁移后 |
| --- | --- |
| `ConfirmDialog`（自绘玻璃 + 双按钮行 + 可选图标） | 无图标 → 官方 `AlertDialog`；带图标 → 官方 `TipsDialog`（`imageRes`）。**不要用官方 `ConfirmDialog`**：它带 `checkTips` / `isChecked` 复选框字段，即使不传 `checkTips` 也会渲染一个没有文字的孤立复选框（实测截图确认），语义上不合理 |
| `ActionSheetDialog`（自绘底部选项列表 + 打勾） | 官方 `SelectDialog`（`radioContent: SheetInfo[]` + `selectedIndex` + `confirm`） |
| `CredentialPasswordDialog` / `MakeNoteDialog` / `AddBlacklistDialog` / `AddKeywordDialog` / `AddNoteDialog` | 官方 `CustomContentDialog` + 本工程的内容构件（`CredentialPasswordContent` / `NoteEditorContent` / `BlacklistEditorContent` / `KeywordEditorContent` / `NoteAddContent`） |
| `SaveThreadDialog`（带异步拉取与页范围校验） | 官方 `CustomContentDialog` + `SaveThreadContent` 内容构件 |
| `FavoriteFolderNameDialog` | 官方 `CustomContentDialog` + `FolderNameEditorContent` 内容构件 |

内容构件用普通 `@Component` 而不是全局 `@Builder` 函数：官方 `contentBuilder` 装载的状态
（输入文本、校验错误）必须经 `this` 读取才能建立响应式依赖——`@Builder` 按值传参不建立依赖，
会出现「输入不刷新」的静默失效（见 `entry/src/AGENTS.md` 响应式约定）。

**内容构件的参数一律 `@Prop` + 回调，禁止 `@Link`**（实测崩溃，勿改回）：
`contentBuilder` 是 `@BuilderParam`，传进去的 @Builder 是在**对话框组件内部**执行的，
调用方的 `$变量` 语法在那一层解析不到源状态，打开对话框时会抛
`SyntaxError: undefined 'xxx': constructor: source variable in parent/ancestor @Component must be defined`
并直接闪退。因此内容构件统一走「父 `@State` --`@Prop`--> 子」+「子回调 --> 父写回」，
不再有跨层绑定。受影响的共 11 处：`NoteEditorContent`（NotesPanel / ProfilePanel /
ProfileCardPopup）、`NoteAddContent`（NotesPanel）、`KeywordEditorContent`（FilterKeywordsPanel）、
`BlacklistEditorContent`（BlacklistPanel）、`CredentialPasswordContent`（SettingsPanel / LoginPage）、
`FolderNameEditorContent`（FavoriteFoldersPanel / FavoriteSavedPanel）、`SaveThreadContent`（ThreadPanel）。

**传 `contentBuilder` 必须写箭头函数包装，禁止写成方法引用**（2026-09 修复，勿改回）：
`@BuilderParam` 以「方法引用」方式赋值（`contentBuilder: this.exportPasswordContent`）时，
@Builder 内部的 `this` 指向**对话框组件实例**而不是调用方页面——官方文档
《@BuilderParam装饰器：引用@Builder函数》「改变内容UI不刷新」一节给出的反例正是这种写法
（正例是 `(): void => { this.customChangeThisBuilder() }`）。后果是**静默失效**：
弹窗照常打开、输入框照常能打字（`@Prop` 收不到值时回落到默认值），但
1）内容构件读到的父状态全是 `undefined`（编辑备注打开时原内容为空、保存帖子弹窗拿不到 `tid`）；
2）回调写回落在对话框实例上，父组件状态永远是初值——**凭证导出/导入因此恒判「密码至少 8 位」**。

因此 13 处调用点统一写成 `contentBuilder: (): void => { this.xxxContent() }`
（`SettingsPanel`、`LoginPage`、`NotesPanel` ×2、`ProfilePanel`、`ProfileCardPopup`、
`FilterKeywordsPanel`、`BlacklistPanel`、`FavoriteFoldersPanel` ×2、`FavoriteSavedPanel` ×2、`ThreadPanel`）。

**官方按钮区的能力边界（凭证两处已改回自绘按钮）**：官方模板的按钮做不出「未达位数 → 未激活」的
即时反馈，原因有两条（本地 SDK 声明为准，`@ohos.arkui.advanced.Dialog.d.ets`）：

1. `ButtonOptions` 只有 `value` / `action` / `background` / `fontColor` / `buttonStyle` / `role` /
   `defaultFocus` / `textAlign`，**没有 `enabled` 之类的状态字段**；
2. `buttons?: ButtonOptions[]` 是普通可选参数（不是 `@Prop`），而对话框 `builder` 只在 `open()` 时
   执行一次——**弹窗打开后不会随输入重新求值**，即使有状态字段也刷不出来。

`contentBuilder` 是 `@BuilderParam`，其内容挂在调用方的响应式依赖里，能随父 `@State` 实时刷新。
所以凭证导出 / 导入两处（`CredentialPasswordContent`）**改为不传官方 `buttons`，由内容区自绘
「取消 + 导出/导入」**：主按钮实底主题色（材质契约 §12.5），未达位数时降到 45% 亮度表示未激活，
与迁移前 `CredentialPasswordDialog` 的观感一致。

其余输入类弹窗（`NotesPanel` / `FilterKeywordsPanel` / `BlacklistPanel` / `ProfilePanel` /
`ProfileCardPopup` / `ThreadPanel` / `FavoriteFoldersPanel` / `FavoriteSavedPanel`）**仍是**
官方按钮 + 提交时校验 + Toast 提示；如需同样的激活态，套用 `CredentialPasswordContent` 的模式即可
（不传 `buttons`，把按钮行放进内容构件）。

### 3.3 写私信表单（`ComposeMessageSheet`）

手搓遮罩 + `position({x: 0, y: '40%'})` 的伪底部面板 → `bindSheet` 半模态：
系统承担进出场动效、下拉手势与键盘避让；`onDisappear` 回写 `@Link showCompose` 保证状态一致。

---

## 4. 保持自研的项（能力边界所致）

| 项 | 官方对应 | 不迁移的原因 |
| --- | --- | --- |
| 资料卡（`ProfileCardPopup`） | `bindPopup` | **已实测迁移并回退**。`bindPopup` 的位置由**锚点组件的几何区域**经 `placement` 推导，`offset` 只是相对该推导结果的微调（声明原文：Offset of the popup relative to the display position specified by **placement**），模型里没有「任意屏幕坐标」这一能力。两种锚点方案均失败：**零尺寸锚点**建立不出气泡基准位置 → 内容不渲染、只剩蒙层挡屏（用户实测「看不见但点不动，只能按返回键」）；**1×1 锚点** → 气泡按锚点几何推导后跑到屏幕左上角外并被裁剪，遮罩也未覆盖全屏。资料卡的坐标是调用点按点击位置算好的屏幕绝对 vp 值，只有 `.position()` 能精确落位 |
| `PanelNavBar` 标题栏 | `ComposeTitleBar` / `SelectTitleBar` / `EditableTitleBar` | 三者都没有 `onBack` 回调（返回固定走系统返回）、没有标题区 `@BuilderParam`；`ComposeTitleBar` 无角标字段；`SelectTitleBar` 的标题必须是下拉选择器（`options` 必填）；三者声明都明确要求「避免配置通用属性/事件」（会生成 `__Common__` 节点），而现有用法是 `.width('100%').position(...)`。强行替换会同时丢失自定义返回拦截、未读角标、滚动进入标题区的渐变与玻璃圆底图标 |
| `SettingRow` 设置行 | `ComposeListItem` / `SubHeader` | `IconType` 是图标尺寸枚举（8/16/24/40/64/96vp 六档），无法表达现有的「29×29 圆角色块 + 17vp 白色填充图标」；`operateItem` 没有未读数徽章字段；行高与字号会变成官方规范。`SubHeader` 是分组标题（新增视觉元素），不是列表行 |
| 三列 / 侧边栏导航容器 | `SideBarContainer` + `Navigation` | 本轮范围外（用户明确排除） |
| `ToastComponent` | `promptAction.showToast` | 官方 toast 不支持动作按钮，而工程有「回复成功 → 前往查看」这类带回调的 toast（`appStore.showToastAction`）；官方 toast 也无法承载现有玻璃底色与自定义命中测试策略 |

---

## 5. 玻璃视觉的保持方式（迁移后仍适用）

迁移没有改动 `UIMaterialManager` 的任何参数，玻璃契约（`IMMERSIVE_LIGHT_DESIGN.md` §12）保持不变：

1. 官方容器的**背景一律让位**：sheet 背景 `Color.Transparent`、popup `popupColor` 透明且 `backgroundBlurStyle: NONE`、
   对话框走官方模板自身材质。
2. 弹层外观仍由内容容器的 `.attributeModifier(UIMaterialManager.surfaceMaterial / inputMaterial / ...)` 承担；
   官方容器只提供**位置、动效、手势与命中测试**。
3. 蒙层色统一对齐 `AppColors.overlay`，迁移前后遮罩观感一致。

---

## 6. 验证

- 编译：`hvigorw assembleHap --mode module -p module=entry@default -p buildMode=debug` → `BUILD SUCCESSFUL`（每批改动后均执行）。
- 部署：HAP 安装到模拟器 `Huawei_TripleFold`（`hdc install -r`）→ `install bundle successfully`。
- 启动：`hdc shell aa start -a EntryAbility -b com.example.nga_oh` → `start ability successfully`，进程存在。
- 交互与视觉的逐项确认需在模拟器/真机上手动操作（本次未做 UI 自动化）。

---

## 7. 后继：迁移带来的沉浸光感合规化（系统材质接入）

迁移到官方组件后，这些位置重新获得了**系统沉浸材质**资格——这是迁移当时没有兑现、随后补上的收益。

### 7.1 为什么迁移之后才合规

API 26 Release 的生效范围门禁（`IMMERSIVE_LIGHT_DESIGN.md` §0）：普通组件只在
`Navigation`/`NavDestination` 标题栏或横向 `Tabs` 的 `BarPosition.End` 底部 TabBar 生效；
但**弹窗类组件与弹窗类接口（含半模态转场），以及 `Slider`/`Toggle`/`Select`，可在页面内全部区域生效**。

本工程没有 `Navigation`/`Tabs`，内容区无从借位；而迁移后的承载方式正是 `CustomDialogController`
（官方弹窗）与 `bindSheet`（半模态转场）——两者都在「全区域生效」清单内。**所以「迁移到官方组件」
这一步本身就是材质合规化的前提**：手搓 `Stack` 浮层即使把材质写在外层容器上也不生效，
写在官方弹窗接口的 options 上就生效。

### 7.2 本轮接入

| 位置 | 接入点 | 材质 |
| --- | --- | --- |
| 32 处官方对话框（`AlertDialog` / `TipsDialog` / `SelectDialog` / `CustomContentDialog`） | `CustomDialogControllerOptions.systemMaterial` | `dialogMaterial`（Beta1 原配方） |
| 2 处半模态面板（回复 / 发新主题编辑器、写私信） | `SheetOptions.systemMaterial` | `sheetMaterial`（同配方） |
| 7 处设置类 `Slider` + 2 处 `Toggle(Switch)` | 通用属性 `.systemMaterial(...)` | `controlMaterial`（`THIN` + 交互形变 + 点光源） |

**材质参数在真机上实测校准过**（详见 `IMMERSIVE_LIGHT_DESIGN.md` §12.7）：弹窗 / 面板用
`REGULAR` + 45% 暖白 `materialColor` + `applyShadow: false`——即 API 26 Beta1 时期本工程实测有效的
原配方（git `0df06e94`）。官方文档给 Dialog 推荐的 `ULTRA_THICK` 在真机上就是一块**不透的白板**
（与背景是否透明无关），`ULTRA_THIN` / `THIN` 又太透导致背景文字穿透。同时实测确认：
**Release 下浮层内部的普通组件写 `.systemMaterial(...)` 不生效**，材质只在面板本体那一层参与渲染，
所以面板内部控件（工具条、输入框、中性按钮）仍走自绘内容层材质。

配套改动：

- 面板 / 弹窗**内容层**从自绘模糊玻璃切到无模糊的内容层材质（`dialogFieldMaterial` 输入框、
  `dialogActionMaterial` 中性按钮）——系统材质已经糊过背景，再叠 `backgroundEffect` 是二次糊化。
- 半模态面板内容容器移除 `borderRadius` + `clip` + `surfaceMaterial`，形状交给系统面板。
- `SheetOptions.backgroundColor` 走 `UIMaterialManager.sheetContentBackdrop`：设备支持材质时是
  `Color.Transparent`（`BindOptions` 的默认值是 `Color.White`，不显式置透明会盖住背板材质）；
  `isImmersiveMaterialSupported()` 为 `false` 时回退为半透明玻璃填充，避免内容直接浮在蒙层上。
- 继续自绘玻璃的位置：页面内容区、`PanelNavBar`、`Toast`、资料卡、图片查看器，
  以及 `AudioPlayer` 的自定义配色进度条（`SliderStyle.OutSet` + 显式 block/track 色）。

### 7.3 仍未覆盖的位置（需要结构变更才能拿到材质）

`PanelNavBar` 标题栏是内容区自绘栏位，**不在** `Navigation` 标题栏内，因此拿不到系统材质。
要接入需把面板栈改造成 `Navigation`/`NavDestination` + `barStyle: BarStyle.STACK`，
属于导航模型重构（本轮范围外，需要时另立目标评估）。
