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
| `bindPopup` 的位置由**锚点组件的几何区域**经 `placement` 推导，`offset` 只是相对该推导结果的微调 | 它本身表达不了「任意屏幕坐标气泡」——要落到任意坐标必须**让锚点自己带上目标坐标**（`Placement` 没有 `Center`，见 §4 与 §7.6）；零尺寸锚点会让内容完全不渲染 |
| `CustomContentDialog` 是官方高级对话框里**唯一**支持自定义内容的模板 | 输入类弹窗只能用它 |
| `@BuilderParam` 传值要写 `this.xxx`（不带括号），而 `CustomBuilder` 位置写 `this.xxx()` | 写错会报 `Type 'void' is not assignable to type '() => void'` |
| 官方 `contentBuilder` 里的 @Builder 在**对话框组件内部**执行 | 不能用 `$变量` 绑定调用方的 @Link：源状态在那一层不存在，打开对话框即闪退（见 §3.2） |
| 官方 `ConfirmDialog` / `TipsDialog` 带 `checkTips` + `isChecked` 复选框字段 | `ConfirmDialog` 不传 `checkTips` 时仍会渲染一个**没有文字的孤立复选框**（实测）；无图标场景改用它同族的 `AlertDialog`（无复选框字段）。`TipsDialog` 实测不显示孤立复选框 |
| `ComposeTitleBar` / `SelectTitleBar` / `EditableTitleBar` 都**没有** `onBack` 回调，也没有标题区 `@BuilderParam` 槽 | 官方标题栏无法承载自定义返回拦截 |
| `ComposeListItem` 的 `IconType` 是**图标尺寸**枚举（8/16/24/40/64/96vp），不是「带角标」 | 无法表达自定义色块图标 |
| `bindContentCover` 的 `isShow` 未写 `$$` 双向绑定时，用户交互式关闭（系统返回 / 侧滑返回）**不会回写**该变量，必须自己在 `onWillDismiss` 里同步状态 | 本地 SDK `ContentCoverOptions.onWillDismiss` 声明：注册该回调后「touching the back button does not immediately dismiss the modal」——即返回事件由模态优先消费，页面的 `onBackPress` 不会被调用（见 §3.1 修复记录） |

---

## 3. 已迁移清单

### 3.1 浮层体系（`FloatingLayerComponent`）

| 原实现 | 迁移后 | 视觉策略 |
| --- | --- | --- |
| 回复编辑器 / 发新主题：全屏 `Stack` 遮罩 + 手搓居中/底部定位 | `bindSheet` 半模态（**三种断点统一 `SheetType.BOTTOM`**，宽屏仅限宽） | sheet 背景置 `Color.Transparent`、`blurStyle` 默认 NONE、蒙层色对齐 `AppColors.overlay`。**注**：这是迁移当时的做法（外观由内容容器的 `surfaceMaterial` 磨砂玻璃承担），后续已被 §7.2 的系统材质接管——sheet 背板改走 `sheetMaterial`，内容容器不再叠自绘玻璃。**另注**：`md+` 曾用 `SheetType.CENTER` 保持居中浮层形态，已作废——编辑器自己用「窗口键盘高度占底部 padding」（`keyboardAvoidMode: NONE`）做避让，该做法只在贴底样式下成立；居中形态会被二次垫高，面板比内容高一截、工具行下方留长空白，且底边越出可视区导致底部圆角不再绘制（真机截图逐像素实测，见 `IMMERSIVE_LIGHT_DESIGN.md` §12.7） |
| 图片查看器：同层 `Stack` 内渲染 | `bindContentCover` 全屏模态 | 内容自带暗场景底色，`modalTransition` 用系统默认 |
| 通用确认框（`floatingLayerStore.showConfirm`） | 官方 `ConfirmDialog`，调用点下移到唯一使用方 `BrowseHistoryPanel` | 官方模板样式，主按钮保留 `AppColors.destructive` 实底 |
| 「放弃编辑」确认框（`replyConfirmActive`） | 官方 `ConfirmDialog`，下移到 `ReplyDialog` / `NewTopicDialog` 各自的 `CustomDialogController` | 同上 |

副作用（正向）：`FloatingLayerStore` 不再保存确认框状态，`FloatingPage` 从 6 个枚举减到 5 个，
`MainPage.onBackPress` 的返回分支同步简化。

**全屏模态的两条关闭路径都必须回写 store**（2026-09 修复，勿改回）：图片查看器点右上角关闭按钮走
`ImageViewer.onClose` → `remove(IMAGE_VIEWER)`，由状态驱动收起；而**系统返回 / 侧滑返回由全屏模态优先消费**，
`MainPage.onBackPress` 这一步根本不会被调用。此前 `imageCoverOptions().onWillDismiss` 只调了
`action.dismiss()`，模态视觉上收起后 `floating.top` 仍是 `IMAGE_VIEWER`，于是 `FloatingLayerComponent`
根 `Stack` 的 `hitTestBehavior` 一直停在 `HitTestMode.Default`——该模式**自身参与命中测试并阻塞兄弟节点**
（本地 SDK `enums.d.ts` 原文 "block the hit test of sibling nodes"），全屏浮层容器因此吞掉下方页面的全部触摸。
用户侧表现就是「用系统返回关掉图片后界面点不动，要再按一次系统返回（这次才轮到 `onBackPress` 弹栈）才恢复」。
修复：`onWillDismiss` 中 `action.dismiss()` 后立即 `remove`，并加 `onDisappear` 兜底（与 §3.3 写私信面板同一约定，
条件判断避免误删动画期间新开的其它浮层）。

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
系统承担进出场动效与下拉手势；`onDisappear` 回写 `@Link showCompose` 保证状态一致。

**弹出与键盘避让参数与编辑器两件套同构**（`SheetType.BOTTOM` 贴底 + `keyboardAvoidMode: NONE`
+ 组件自己订阅 `keyboardHeightChange` 把键盘高度垫进内容底部留白，见
`IMMERSIVE_LIGHT_DESIGN.md` §12.7）。注意**三项必须成套**：只关系统避让不垫高 → 输入区被输入法
盖住；只垫高不关系统避让 → 系统与应用各避让一次，输入法上方凭空多一段空白。
（本面板原先依赖系统默认避让，且底部留白用 `navBarHeight` 避让手势条 —— 后者在贴底形态下
既无必要、又会与键盘留白叠加，已移除。）

---

## 4. 保持自研的项（能力边界所致）

| 项 | 官方对应 | 不迁移的原因 |
| --- | --- | --- |
| 资料卡（`ProfileCardPopup`） | `bindPopup` | **第二轮已迁移**（详见 §7.6）。第一轮回退的结论仍然成立——`bindPopup` 的位置由**锚点组件的几何区域**经 `placement` 推导，`offset` 只是相对该推导结果的微调，模型里没有「任意屏幕坐标」这一能力；第一轮的两种锚点方案（零尺寸锚点 → 内容不渲染只剩蒙层；1×1 锚点 → 气泡跑到屏幕左上角外被裁剪）都**没有让锚点带上目标坐标**。第二轮把锚点本身用 `.position()` 放到 `(profileCardX, profileCardY)`（绝对 vp 坐标由调用点算好），气泡才跟着落到点上 |
| `PanelNavBar` 标题栏 | `ComposeTitleBar` / `SelectTitleBar` / `EditableTitleBar` | 三者都没有 `onBack` 回调（返回固定走系统返回）、没有标题区 `@BuilderParam`；`ComposeTitleBar` 无角标字段；`SelectTitleBar` 的标题必须是下拉选择器（`options` 必填）；三者声明都明确要求「避免配置通用属性/事件」（会生成 `__Common__` 节点），而现有用法是 `.width('100%').position(...)`。强行替换会同时丢失自定义返回拦截、未读角标、滚动进入标题区的渐变与图标按钮的材质块底板（`HdsMaterialHost`，见 `IMMERSIVE_LIGHT_DESIGN.md` §12.9） |
| `SettingRow` 设置行 | `ComposeListItem` / `SubHeader` | `IconType` 是图标尺寸枚举（8/16/24/40/64/96vp 六档），无法表达现有的「29×29 圆角色块 + 17vp 白色填充图标」；`operateItem` 没有未读数徽章字段；行高与字号会变成官方规范。`SubHeader` 是分组标题（新增视觉元素），不是列表行 |
| 三列 / 侧边栏导航容器 | `SideBarContainer` + `Navigation` | 本轮范围外（用户明确排除） |
| `ToastComponent` | `promptAction.showToast` | 官方 toast 不支持动作按钮，而工程有「回复成功 → 前往查看」这类带回调的 toast（`appStore.showToastAction`）；官方 toast 也无法承载现有玻璃底色与自定义命中测试策略 |

---

## 5. 玻璃视觉的保持方式（迁移后仍适用）

迁移没有改动 `UIMaterialManager` 的任何参数，玻璃契约（`IMMERSIVE_LIGHT_DESIGN.md` §12）保持不变：

1. 官方容器的**背景一律让位**：sheet 背景 `Color.Transparent`、popup `popupColor` 透明且 `backgroundBlurStyle: NONE`、
   对话框走官方模板自身材质。
2. 弹层外观**迁移当时**仍由内容容器的 `.attributeModifier(UIMaterialManager.surfaceMaterial / inputMaterial / ...)` 承担；
   **现已被 §7.2 的系统材质取代**——弹层本体走 `dialogMaterial` / `sheetMaterial` / `menuMaterial` / `popupMaterial`，
   内容层只保留不做背景模糊的 `dialogFieldMaterial`。
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
| 32 处官方对话框（`AlertDialog` / `TipsDialog` / `SelectDialog` / `CustomContentDialog`） | `CustomDialogControllerOptions.systemMaterial` | `dialogMaterial`（`THIN` + `applyShadow: true`，不赋色） |
| 3 处半模态面板（回复 / 发新主题编辑器、写私信、**子版块筛选**） | `SheetOptions.systemMaterial` | `sheetMaterial`（同 `dialogMaterial`） |
| 4 处菜单（**帖子更多菜单**、**版块更多菜单**、**热门时间窗菜单**、**WebView 更多菜单**） | `MenuOptions.systemMaterial`（`bindMenu`） | `menuMaterial`（`THICK` + `applyShadow: true`，不赋色） |
| 1 处气泡（**页码选择器**） | `CustomPopupOptions.systemMaterial`（`bindPopup`） | `popupMaterial`（`REGULAR` + `applyShadow: true`，不赋色） |
| 7 处设置类 `Slider` + 2 处 `Toggle(Switch)` | 通用属性 `.systemMaterial(...)` | `controlMaterial`（`THIN` + 交互形变 + 点光源） |

**材质参数以 `UIMaterialManager.ets` 为唯一真源**（本文档曾与 `IMMERSIVE_LIGHT_DESIGN.md` §12.7、
正文出现三方漂移：表格写 `ULTRA_THICK`、正文写 `REGULAR` + 45% 暖白 + `applyShadow: false`、
代码写 `THIN` + `applyShadow: true`）。当前取值：弹窗 / 面板 / 半模态 `THIN`、菜单 `THICK`、
气泡 `REGULAR`，**统一不传 `materialColor`**（色调交给系统按深浅色模式自适应）+ `applyShadow: true`。
官方文档给 Dialog 推荐的 `ULTRA_THICK` 在真机上就是一块**不透的白板**（与背景是否透明无关），
`ULTRA_THIN` 又太透导致背景文字穿透。同时实测确认：**Release 下浮层内部的普通组件写
`.systemMaterial(...)` 不生效**（判定按**组件类型**，不按所处层级），所以面板内部控件
（工具条、输入框、中性按钮）仍走自绘内容层材质。

配套改动：

- 面板 / 弹窗**内容层**从自绘模糊玻璃切到无模糊的内容层材质（`dialogFieldMaterial` 输入框、
  `dialogActionMaterial` 中性按钮）——系统材质已经糊过背景，再叠 `backgroundEffect` 是二次糊化。
- 半模态面板内容容器移除 `borderRadius` + `clip` + `surfaceMaterial`，形状交给系统面板。
- `SheetOptions.backgroundColor` 一律固定 `Color.Transparent`（`BindOptions` 的默认值是
  `Color.White`，不显式置透明会盖住背板材质）。**不做设备降级**——不为"设备不支持材质"写回退填充：
  历史上曾有 `UIMaterialManager.sheetContentBackdrop` 这类"不支持则回退半透明填充"的常量，
  已按工程约定删除（材质不生效时背板全透明是接受的结果）。
- 继续自绘玻璃的位置：页面内容区其余常驻控件（面板、列表、`PanelNavBar` **栏位本体**）、图片查看器，
  以及 `AudioPlayer` 的自定义配色进度条（`SliderStyle.OutSet` + 显式 block/track 色）。
  **资料卡已迁到 `bindPopup`**（见 §7.6）；**右下角浮动按钮与页码条、`PanelNavBar` 的图标底板已迁到
  `HdsMaterialHost`**（见 §7.3）；`Toast` 从来不属于自绘玻璃——它用的是不透明 `AppColors.toastBg`，
  列进去会让后来者按错误的契约去改它。

### 7.3 仍未覆盖的位置（需要结构变更才能拿到材质）

`PanelNavBar` 的**栏位本体**仍是自绘栏位（保持透明，正文从下方穿越），不在 `Navigation` 标题栏内，
因此拿不到系统材质（栏位本体要拿材质需把面板栈改造成 `Navigation`/`NavDestination` +
`barStyle: BarStyle.STACK`，属于导航模型重构，本轮范围外，需要时另立目标评估）。

它承载的**菜单**是例外：菜单走 `bindMenu`（弹窗类接口），已在 `PanelNavBar` 内部接入 `menuMaterial`。
**图标底板**也不再是自绘玻璃：三颗操作按钮（返回 / 主右侧 / 次右侧）的背板改走 `HdsMaterialHost`
（HDS 材质宿主，见 `IMMERSIVE_LIGHT_DESIGN.md` §12.9）——`HdsTabs` 的悬浮页签栏材质由 HDS 组件自身
渲染、不受 §0 门禁约束，是自绘标题栏里唯一能拿到**真材质**的通道。两点必须分清：这**不等于**
"标题栏拿到了系统材质"（栏位本体仍是透明自绘，只是按钮背板换了通路），也**不是**官方推荐路径
（标题栏属官方点名的"标准场景"，官方组件是 `HdsNavigation`）。

### 7.4 页面内容区浮层的系统材质迁移（ThreadPanel / TopicListPanel）

承接 §7.1 的判定：**浮层只要换成官方弹窗类接口承载，材质就能拿到**。本轮把两个页面里剩余的
手搓玻璃浮层逐个迁走——它们此前都是「全屏 `Stack` 遮罩 + `.position()` 定位 + `surfaceMaterial`」。

| 原实现 | 迁移后 | 锚点 | 材质 |
| --- | --- | --- | --- |
| `ThreadPanel.MoreMenu`（分享菜单，宽 150 玻璃柱） | `bindMenu`（菜单项在 `PanelNavBar` **内部**渲染） | 标题栏那颗 more 按钮 | `menuMaterial` |
| `TopicListPanel.MoreMenu`（版块菜单，宽 170） | `bindMenu`（同上，挂在第二颗按钮） | 标题栏那颗 more 按钮 | `menuMaterial` |
| `TopicListPanel.HotRangeMenu`（热门时间窗，宽 150 + 打勾） | `bindMenu`（**保留** `MenuItem.selected` + `selectIcon(true)`：三项都带图标位、彼此对齐） | 排序条那一行 | `menuMaterial` |
| `ThreadPanel.PagePicker`（页码选择，220×180 固定浮层） | `bindPopup` + `CustomPopupOptions` | 分页条里的「到」 | `popupMaterial` |
| `TopicListPanel.SubBoardFilterPanel`（88%×70% 居中面板 + 遮罩） | `bindSheet`（`sm` → `BOTTOM`，其余 → `CENTER`） | 面板根 `Stack` | `sheetMaterial` |

四条落地约束（改动时勿回退）：

1. **锚点决定落位**。`bindPopup` / `bindMenu` 的位置由**锚点组件几何 + `placement`** 推导，
   不存在"在锚点之外再指定任意坐标"这条能力（§4 资料卡的实测结论）。菜单锚在标题栏那颗 more
   按钮上取 `BottomRight`、气泡挂在「到」上取 `Top`；`PagePicker` 里按 `holdingStatus` 手算左右
   定位的逻辑随之删除——气泡会自动贴向锚点所在的那一侧。
   （资料卡是唯一需要"任意坐标"的浮层，做法见 §7.6：让 1×1 锚点**自己带上目标坐标**。）
   **锚点要用有明确尺寸的容器，不要拿文字本身当锚点**：文字在 40vp 胶囊里是垂直居中的，
   它的布局矩形顶边并不在胶囊顶边，气泡底边会因此落进胶囊内部（实机现象：气泡与页码条纵向
   压住一点）。「到」的锚点改成 `.height(40)` 的 `Stack` 后，`targetSpace: 12` 才能真正把它
   推离页码条。
2. **背板填充与模糊写死为"完全让位给系统材质"**：气泡 `popupColor: Color.Transparent` +
   `backgroundBlurStyle: BlurStyle.NONE`；菜单不设 `backgroundColor` / `backgroundBlurStyle`。
   `bindPopup` 的 `popupColor` 默认是「透明 + `COMPONENT_ULTRA_THICK` 模糊」、`backgroundBlurStyle`
   默认同一模糊，不清掉就是在系统材质之上再叠一层模糊；菜单同理（`ContextMenuOptions.backgroundColor`
   / `backgroundBlurStyle`）。**不做设备降级**：不为 `isImmersiveMaterialSupported() === false` 写
   回退分支（历史上曾有 `floatingBackdrop` / `floatingBackdropBlur` 这类"回退半透明填充 + 默认模糊"
   的常量对，已按工程约定删除）——材质不生效时气泡 / 菜单背板全透明是**接受**的结果。
3. **内容层分工不变**：浮层**本体**由 options 的系统材质承担；内部普通组件一律自绘内容层
   （页码选择器里的输入框改用 `dialogFieldMaterial`，替代原来的 `backgroundColor(Color.Transparent)`）。
   但 **`Toggle` / `Slider` / `Select` 例外**——它们在 Release 清单内是"页面内全部区域"，
   处在半模态内部**依然生效**，所以子版块筛选里的 `Toggle(Switch)` 继续用 `controlMaterial`。
4. **状态回写不能省**（三处都踩过）：系统只隐藏菜单 / 气泡，**不会回写**驱动显隐的状态变量。
   - **标题栏菜单：本地不持有状态。** 用**两参** `bindMenu(content, options)` 把开合完全交给系统。
     受控形式（一参 `show`）需要"本地布尔取反 + 系统关闭时回写"**两个真源**，二者在"点锚点本身"
     这条路径上会互相打架——结果取决于系统是否把该次点击透传给锚点，实测症状就是"点区域外关闭后，
     第一次点按钮没反应、第二次才打开"。
   - **排序条上的 `HotRangeMenu` 仍是受控形式**（它的入口是 `showHotRangeMenu = true` 的赋值而非
     锚点点击，且锚点是一整行、不能整行都弹菜单），必须靠 `MenuOptions.onDisappear` 回写。漏了它
     后果比"点两次"更重：状态卡在 `true` 后赋同一个值不触发刷新，菜单**再也弹不出来**。
   - **半模态**：靠 `onDisappear` 回写 `showSubBoardFilterPanel`，`shouldDismiss` 保留
     「提交中点击遮罩不关闭」的守卫。
   - **气泡**：靠 `onStateChange` 回写 `showPagePicker`（漏了它，气泡被系统关掉后状态停在 `true`，
     下次点击赋同一个值不触发刷新，**气泡再也弹不出来**）。
5. **`builder` 字段要传构造器，不能传构造结果**（实机踩坑）。`CustomPopupOptions.builder` 的类型是
   `CustomBuilder`（`() => void`）。在 `build()` 内的**参数位置**写 `this.PagePicker()` 会被 ArkUI 的
   @Builder 语法糖正确转成构造器（`bindSheet` / `bindMenu` 就是这么写的，已验证有效）；但在
   **普通方法返回的 options 对象字段**里写 `this.PagePicker()` 会被当作立即调用、得到 `void`，
   气泡拿到空 builder，**整个气泡不渲染**（现象：点「到」毫无反应，连空壳都没有）。
   该字段统一写 `builder: (): void => { this.PagePicker() }`。
6. **菜单项的激活态用 `contentFontColor` 表达，不要用 `.selected()` + `.selectIcon(true)`**（实机踩坑）。
   后者是"选中图标"能力，菜单项会为图标单独预留一块左侧位置；一个菜单里只有个别项带它时，
   只有那几项会多出一截空白（现象：帖子更多菜单的「只看楼主」前面"像多了几个空格"）。
   与迁移前的手搓菜单对齐：激活时 `AppColors.primary`，未激活用 `$r('sys.color.font_primary')`。
   `HotRangeMenu`（热门时间窗）三项都带选中图标、彼此对齐，属于系统菜单的标准单选表现，保留。
7. **菜单锚点必须是标题栏里那颗真实的按钮**（折叠屏，三轮踩坑的最终结论）。`MainPage` 是
   "侧边栏 + 板块列 + 活动列"的嵌套 `Row`/`Column`，md/lg 下内容区起点不是 `x = 0`，菜单锚点的
   几何很容易被算到窗口左侧。依次排除掉的写法：
   - **挂在整条标题栏（自定义组件 `PanelNavBar`）上**：多列下菜单被算到**窗口左侧**；
     sm 单列时侧边栏隐藏、内容区恰好从 0 开始，所以只在折叠屏暴露。
   - **改成 `.position({ x: 0, y: 0 })` 换成打在自定义组件上的 `.align(Alignment.TopStart)`**：
     更糟。`align` 是**容器属性**（SDK 原文：在 Stack 中等价于 `alignContent`，即"设置子组件在
     容器内的对齐方式"），写在自定义组件上只影响它**内部**子节点，组件自己在父 `Stack` 里仍按
     `alignContent`（两个页面根 Stack 都是 `BottomEnd`）落位——标题栏直接掉到面板底部。
   - **套一层系统 `Column` 承载对齐与锚点**：对齐问题解决，但多列下菜单仍偏。

   正解：**把菜单放进 `PanelNavBar` 内部，锚定那颗 36×36 的操作按钮**。按钮是系统组件、
   正常布局、尺寸确定，`Placement.BottomRight` 让菜单右边缘与按钮右边缘对齐，始终落在标题栏
   范围内。`PanelNavBar` 自身保持 `.position({ x: 0, y: 0 })` 的原有定位（注意落点与迁移前的
   `.position({ top: … + 6, right: 16 })` **不再是像素等价**，需要精确间距时显式给 `targetSpace`）。
   配套两条都是踩坑换来的：
   - **两参 `bindMenu(content, options)`**，本地不持有显隐状态（见约束 4）；
   - **菜单项用提供者注入**——`menuItemsProvider: () => NavBarMenuItem[]`，而不是
     `@Prop menuItems: NavBarMenuItem[]`：平台**不允许 `@Prop` 装饰 Function 类型**（API 23 起
     编译期校验），而菜单项里带着 `action` 回调；提供者还顺带保证菜单每次构建取到最新文案与
     激活态，并避免滚动期间每帧新建数组灌进 `@Prop`。
   - 菜单项的 `ForEach` 键要带**激活态指纹**（`label + active`）：键不变时子组件不重建，
     只改 `active` 会让激活色不刷新。

`bindSheet` 这一项沿用既有配方：`dragBar: false` + `showClose: false` +
`backgroundColor: Color.Transparent`（`BindOptions.backgroundColor` 默认
`Color.White`，不清掉就盖住背板材质）+ `maskColor: AppColors.overlay` + 圆角四角同值 16。
注意 **`SheetOptions.radius` 的类型是 `LengthMetrics | BorderRadiuses | LocalizedBorderRadiuses`，
不接受裸 `number`**（写 `radius: 16` 直接编译报类型不匹配）；而 `CustomPopupOptions.radius` 是
`Dimension`、收裸 number——两者规则不同，别互相照抄。

### 7.5 明确保留自绘玻璃的位置（用户决策，2026-09）

右下角**常驻**控件不迁移：两个页面的发帖 / 刷新 / 回复圆形按钮、`ThreadPanel` 底部分页条胶囊、
`WebViewPanel` 的前进 / 后退按钮。至此 `UIMaterialManager.surfaceMaterial` 已无调用点——所有手搓
浮层（菜单、气泡、半模态、资料卡）都迁到了官方弹窗类接口，该工厂保留以备将来需要页面内容区自绘面板。
理由是它们在 Release 门禁下**不存在**系统材质通道——它们是页面内容区的 `Stack` / `Row` 普通容器，
换成 `Button` 也一样（`Button` 不在「页面内全部区域」清单里）；唯一在清单内的按钮形态
`Toggle(ToggleType.Button)` 又因"样式继承 Button 默认值且不支持设置"而做不出圆形按钮
（`borderRadius` 不生效，本地 SDK `component/toggle.d.ts` 与官方文档均有说明）。因此维持
`fabMaterial` 自绘磨砂玻璃，视觉与系统材质同屏共存。

> **后续变化（本节结论已部分被取代）**：上面记录的是当时的决策。此后用户改为把这些位置接到
> **HDS 材质宿主**（`HdsMaterialHost`）——先是 `TopicListPanel` / `ThreadPanel` 的发帖 / 刷新 /
> 回复按钮与页码条，再是 `PanelNavBar` 的三颗标题栏按钮（接入点与真机待核对项见
> `IMMERSIVE_LIGHT_DESIGN.md` §12.9）。仍留在 `fabMaterial` 的是 `WebViewPanel` 的前进 / 后退按钮、
> `SearchPanel` 与 `PageStateView` 的浮动按钮。
> 本节"Release 门禁下不存在**系统材质**通道"的判断依然成立，变化的是**后来多了一条非合规旁路**。

### 7.6 资料卡迁移：让锚点带上目标坐标（2026-09 第二轮）

`ProfileCardPopup` 是唯一「用户点哪就在哪」的浮层，第一轮迁 `bindPopup` 失败后退回自绘玻璃（见 §4）。
第二轮的差别只有一处：**让锚点自己带上目标坐标**，而不是指望气泡支持任意坐标。

```ts
// FloatingLayerComponent.build()：锚点就是定位载体
Column()
  .width(1).height(1)
  .hitTestBehavior(HitTestMode.None)
  .position({ x: this.floating.profileCardX, y: this.floating.profileCardY })
  .bindPopup(this.floating.top === FloatingPage.PROFILE_CARD, this.profileCardPopupOptions())
```

```ts
// profileCardPopupOptions()：气泡左上角 = 锚点左下角 + targetSpace，再上移 1vp 抵消锚点高度
placement: Placement.BottomLeft,
targetSpace: 0,
offset: { x: 0, y: -1 },   // 类型是 Position（x / y），不是 Offset（dx / dy）
```

四条必须记住的约束：

1. **`Placement` 没有 `Center`**（只有 `Left`/`Right`/`Top`/`Bottom` 与 8 个角向组合，本地 SDK
   `enums.d.ts:3056`）。Popup 的模型是"气泡在锚点**外侧**"，不存在"居中叠加在锚点上"这种落位；
   任意坐标只能靠"锚点落位 + `offset` 抵消"，不要试图用"全屏锚点 + 居中"去表达。
2. **`CustomPopupOptions.offset` 是 `Position`（`x`/`y`）**，而 `CustomDialogControllerOptions.offset`
   才是 `Offset`（`dx`/`dy`）。写错编译器直接报
   `Type '{ dx: number; dy: number; }' is not assignable to type 'Position'`。
3. **遮罩与关闭全部交还系统**：原自绘全屏 `Column`（`AppColors.overlay` + 点击关闭）删除，改由
   `mask: { color: AppColors.overlay }` + `autoCancel: true` 承担；`onStateChange` 回写
   `floatingLayerStore`（store 是显隐的单一真源），根 `Stack` 的 `hitTestBehavior` 同时移除了
   `PROFILE_CARD` 分支——不再需要靠全屏节点拦触摸。
4. **内容层让位材质**：`ProfileCardPopup` 去掉 `.borderRadius(14)` / `.clip(true)` /
   `surfaceMaterial`（形状交给气泡的 `radius: 14`、材质交给 `popupMaterial`）；内部统计条从
   `inputMaterial`（带背景模糊）换成 `dialogFieldMaterial`（不做模糊），避免对同一层背景二次糊化。

**残留风险（需真机确认）**：气泡下方空间不足时系统会自动调整位置，`offset` 随之失效。
调用点的边界夹取（`cardH = 400`）保证卡片下方至少留 400vp，正常情况下不会触发；若资料内容
超过这个高度或点击点贴近屏幕底部，可能出现位置偏移。
