# HarmonyOS API 26 沉浸光感与新材质完整指南

> 本文是面向 AI、ArkTS 开发者和本工程维护者的沉浸光感知识库。
>
> 适用范围：HarmonyOS API 26.0.0 Release，ArkUI 声明式开发，以及 UI Design Kit（HDS）沉浸光感。
>
> 官方文档核对时间：2026-09-05。华为官方页面可能继续修订；遇到本文与 SDK 实际行为不一致时，应以当前 SDK API 参考和变更说明为准。

> **本工程当前状态（双通路：官方系统材质 + 自绘磨砂玻璃）**：Release 收紧生效范围后，本工程页面
> 内容区的沉浸光感材质曾整体静默失效（组件背景透明、材质消失），当时的处置是全部改为自绘磨砂玻璃。
> 随后工程把全部手搓浮层迁移到**官方弹窗 / 半模态组件**，这些位置重新落回 Release 的
> 「页面内全部区域生效」清单，于是**系统沉浸材质重新接回来了**——`dialogMaterial`（弹窗）、
> `sheetMaterial`（半模态面板）、`controlMaterial`（`Slider` / `Toggle`）。
>
> 再往后，**页面内容区的浮层本体也逐个迁到了官方弹窗类接口**：菜单改走 `bindMenu`
> （`menuMaterial`）、页码选择器改走 `bindPopup`（`popupMaterial`）、子版块筛选改走 `bindSheet`
> （`sheetMaterial`）。这些浮层此前是"手搓 `Stack` + `position` + 自绘玻璃"，现在本体由系统接管。
>
> 现在的分界：**弹窗类组件与接口（Dialog / 半模态 / 菜单 / 气泡）+ `Slider` / `Toggle` /
> `Select` → 系统沉浸材质**——包括**资料卡**（`bindPopup`）、页码选择气泡、标题栏菜单；
> **HDS 材质宿主（非合规旁路，见 §12.9）→ 内容区右下角浮动操作控件（发帖 / 刷新 / 回复按钮、
> 页码指示器），以及 `PanelNavBar` 的返回 / 右侧操作按钮**——标题栏是自绘 `Stack`、不属于
> `Navigation` 标题栏，ArkUI 侧拿不到材质，只能走这条旁路；
> **页面内容区其余常驻控件（列表、`PanelNavBar` 栏位本体、图片查看器）→ 自绘磨砂玻璃**。
>
> 第三条通路是 Release 之后才出现的：**ArkUI 的 `systemMaterial` 在内容区没有任何合法通道**
> （官方 FAQ 的建议就是"改用 `backgroundColor` 等通用属性替代材质效果"，也就是自绘玻璃），
> 但 **UI Design Kit 的 HDS 材质不受那条门禁约束**——`HdsTabs` 的悬浮页签栏背板
> （`barFloatingStyle.systemMaterialEffect`，API 23 起）由 HDS 组件自己渲染材质。于是可以把
> 一个只放自定义内容的 `HdsTabs` 当"材质宿主"，给内容区的小面积浮动控件接上**真材质**。
> 这条路是**设计语义层面的非合规挪用**（详见 §12.9 的边界与风险），只用于官方组件覆盖不到的
> 小面积控件。
>
> 分流表、落地契约与接入清单见第 12 节；本文其余章节保留为沉浸光感契约与踩坑记录。

## 0. 先记住这一条：Release 的生效范围门禁

API 26 Beta 阶段，开发者容易形成“只要给任意组件设置 `systemMaterial`，材质就会生效”的认知。API 26 Release 对既有 Beta 接口增加了生效范围约束：**接口仍然存在，但很多组件在错误的页面区域中会静默不生效。**

Release 后的判断规则如下：

| 组件或接口 | 生效范围 |
| --- | --- |
| 弹窗类组件 | 页面内全部区域。包括 `AlertDialog`、`ActionSheet`、`CustomDialog`、`CalendarPickerDialog`、`DatePickerDialog`、`TimePickerDialog`、`TextPickerDialog`、`SelectionMenu`、`AlphabetIndexer` 弹窗，以及 `Text` 设置 `copyOption` 后长按或双击产生的文本菜单 |
| 弹窗类接口 | 页面内全部区域。包括 `PromptAction`、`ArkUI_NativeDialog`、`@ohos.promptAction` 弹窗、Popup 控制、Tips 控制、菜单控制、半模态转场 |
| `Slider`、`Toggle`、`Select` | 页面内全部区域 |
| 其他 ArkUI 组件 | 仅在 `Navigation`/`NavDestination` 标题栏，或横向 `Tabs` 中 `barPosition: BarPosition.End` 的底部 `TabBar` 区域 |

因此，以下代码在 Beta 阶段可能有效，在 Release 中可能只显示普通组件样式：

```ts
Column() {
  Text('普通组件')
}
.width(328)
.height(56)
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
}))
```

如果这个 `Column` 不在允许的标题栏或底部 TabBar 区域中，材质不会生效。需要材质时，应把它放入有效区域，或改用 `backgroundColor` 等普通属性实现稳定的降级视觉。

这条门禁是本工程所有材质判断的第一条规则，优先级高于材质参数、设备算力和颜色配置。

## 1. 沉浸光感是什么

沉浸光感从 API 26.0.0 开始由 ArkUI 提供，包含两部分能力：

1. **沉浸式系统材质**：由系统统一处理材质滤镜、折射、高光、背景模糊、阴影和部分交互反馈。
2. **沉浸式空间动效**：由系统为弹窗、菜单、Slider 等场景提供非线性形变、边缘流光和粒子动画等空间动效。

系统会根据设备材质等级、系统设置中的沉浸光感强弱和深浅色模式自适应效果。应用不应把它当作一个固定颜色或固定透明度的“玻璃背景”，而应把它当作由系统接管的视觉层。

### 1.1 ArkUI 与 HDS 是两套入口

| 入口 | 主要对象 | 适合场景 | 等级控制 |
| --- | --- | --- | --- |
| ArkUI `uiMaterial` | `uiMaterial.ImmersiveMaterial`、通用属性 `systemMaterial` | 普通 ArkUI 组件、弹窗、局部交互控件 | 设备决定，使用 `uiMaterial.getGlobalMaterialLevel()` 查询，不可由应用设置 |
| UI Design Kit `hdsMaterial` | `HdsNavigation`、`HdsNavDestination`、`HdsTabs` 的 `systemMaterialEffect` | HDS 导航、HDS 底部页签、空间化首眼和悬浮导航 | 可设置 `ADAPTIVE`，也可在确有必要时指定等级 |

如果页面使用 HDS 导航和 HDS 底部页签，优先使用 HDS 的 `systemMaterialEffect`，它会跟随 HDS 最新规范。如果页面是普通 ArkUI 组件或弹窗，使用本文的 `uiMaterial` 规则。

## 2. Beta1 到 Release 的行为变化

| 项目 | API 26 Beta 阶段 | API 26 Release 阶段 |
| --- | --- | --- |
| `systemMaterial` / `ImmersiveMaterial` | 支持组件接入新材质，很多普通组件在页面任意位置都能看到效果 | 接口仍可调用，但普通组件受生效区域限制 |
| 弹窗类组件和接口 | 可在页面任意位置使用 | 仍可在页面任意位置使用 |
| `Slider`、`Toggle`、`Select` | 可在页面任意位置使用 | 仍可在页面任意位置使用 |
| 其他组件 | 组件级材质通常直接可见 | 只有标题栏或底部 TabBar 区域生效 |
| 变更性质 | Beta 新增能力 | Release 为性能和功耗增加的行为约束 |

官方变更说明将该行为变更标记为 API 26 Beta 版本新增接口的适配事项，起始 API Level 为 26.0.0。工程中如果 `targetSdkVersion`/`targetAPIVersion` 已进入 26.0.0 适配范围，应按 Release 约束检查全部材质代码，不能只在高性能开发设备上验证。

## 3. 三层开关与优先级

沉浸光感不是单一开关。最终结果由应用配置、组件配置、设备能力和生效区域共同决定。

### 3.1 应用级开关

必须在 `entry` 类型的 module 中配置 metadata：

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "metadata": [
      {
        "name": "ohos.arkui.UIMaterial.state",
        "value": "enable"
      }
    ]
  }
}
```

`value` 有三种状态：

| 值 | `MaterialState` | 行为 |
| --- | --- | --- |
| 不配置或 `default` | `DEFAULT` | Dialog、Toast、AlphabetIndexer 等在没有冲突样式时按默认规则启用；其他组件通常需要主动设置 |
| `enable` | `ENABLE` | 批量打开官方支持的默认材质组件；Navigation 标题栏、Chip/ChipGroup、Select、菜单、Toggle、SegmentButton、Slider、SelectionMenu 等按官方清单启用；Tabs 在悬浮样式生效时启用 TabBar 材质 |
| `disable` | `DISABLE` | 全局禁用沉浸式系统材质；主动设置的组件级材质也不生效 |

只有 `entry` module 中的 metadata 生效。可用以下代码读取配置：

```ts
import { uiMaterial } from '@kit.ArkUI';

@Entry
@Component
struct MaterialStateDemo {
  private readonly materialInfo: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();

  build() {
    Text(`${this.materialInfo.state}`)
  }
}
```

### 3.2 组件级开关

组件级开启有三种形式：

1. 通用属性：`.systemMaterial(new uiMaterial.ImmersiveMaterial({...}))`。
2. 弹窗 options：例如 `CustomDialogControllerOptions`、`AlertDialogParam`、`ActionSheetOptions`、`ShowToastOptions`、`PopupOptions`、`TipsOptions`、`ContextMenuOptions` 的 `systemMaterial`。
3. 组件专属接口：例如 `Select.menuSystemMaterial`、Navigation 标题栏 options 的 `systemMaterial`、Tabs `barFloatingStyle` 的 `systemMaterial`。

优先级：

1. 应用级 `disable` 是总禁用，覆盖一切组件配置。
2. 应用级 `enable` 负责给官方支持的组件提供默认材质。
3. 组件级材质优先级高于应用级默认效果，可覆盖具体组件的材质参数。
4. 组件级关闭使用 `uiMaterial.Material.empty`。

`undefined` 和 `Material.empty` 不等价：

```ts
import { uiMaterial } from '@kit.ArkUI';

Column() {
  Text('内容')
}
.systemMaterial(uiMaterial.Material.empty)
```

- `undefined`：恢复组件默认的沉浸光感接口行为；在 `ENABLE` 或某些默认场景下，组件可能重新出现材质。
- `uiMaterial.Material.empty`：明确关闭当前组件的沉浸光感。

### 3.3 开关不是生效保证

即使应用级为 `enable`，或组件设置了 `ImmersiveMaterial`，还必须同时满足：

- 组件属于 Release 允许的全页面清单，或位于允许的标题栏/底部 TabBar 区域。
- 当前设备支持沉浸式材质，或接受设备不支持时的无效果降级。
- 组件没有被不透明背景、模糊、内容层背景等样式遮挡。
- 使用的材质参数在当前设备等级上有效。

## 4. 材质样式与设备等级

### 4.1 `ImmersiveStyle`

| 样式 | 视觉含义 | 推荐场景 | `colorInvert` |
| --- | --- | --- | --- |
| `ULTRA_THIN` | 超薄、透明度最高 | 浮动工具栏、圆形操作按钮、轻量提示 | 支持 |
| `THIN` | 薄、较通透 | 搜索框、轻量操作控件、导航按钮 | 支持 |
| `REGULAR` | 常规厚度 | 普通卡片、内容面板 | 不支持 |
| `THICK` | 厚、模糊明显 | 菜单、Toast、AlphabetIndexer 气泡 | 不支持 |
| `ULTRA_THICK` | 超厚、背景强模糊 | Dialog、CustomDialog、ActionSheet | 不支持 |

`ImmersiveMaterial` 默认参数为：

```ts
{
  style: uiMaterial.ImmersiveStyle.REGULAR,
  materialColor: undefined,
  colorInvert: false,
  applyShadow: true,
  interactive: false,
  lightEffect: undefined
}
```

### 4.2 `MaterialLevel`

ArkUI 的 `MaterialLevel` 由设备定义：

| 等级 | 设备 | 影响 |
| --- | --- | --- |
| `EXQUISITE` | 高算力 | 支持完整材质滤镜和更丰富的空间效果 |
| `GENTLE` | 中算力 | 在视觉效果与性能之间平衡 |
| `SMOOTH` | 低算力 | 保留降级后的背景、边框、阴影等表现 |

查询方式：

```ts
import { uiMaterial } from '@kit.ArkUI';

const materialLevel: uiMaterial.MaterialLevel = uiMaterial.getGlobalMaterialLevel();
const materialSupported: boolean = uiMaterial.isImmersiveMaterialSupported();
```

设备差异是系统设计，不应为高、中、低算力设备复制三套 UI。应使用透明背景、合理尺寸和稳定参数，让系统负责降级。

在高、中算力设备上，`style` 主要影响材质滤镜和厚薄；在低算力设备上，`style` 与 `colorInvert` 不产生相同的视觉差异，材质主要体现为背景色、边框和阴影等降级效果。

## 5. `ImmersiveMaterial` 参数规则

| 参数 | 默认值 | 规则 |
| --- | --- | --- |
| `style` | `REGULAR` | 只有高、中算力设备完整支持样式差异；自动反色仅对 `THIN`、`ULTRA_THIN` 生效 |
| `materialColor` | `undefined` | 给材质滤镜再混合一层纯色；必须使用带透明度的颜色，纯不透明色会遮挡材质滤镜；**只在高、中算力设备上生效**（本地 SDK `@ohos.arkui.uiMaterial.d.ts` 原文："takes effect only for the display effect of devices with high- and mid-level computing power"）。低算力设备上材质接管的是 `backgroundColor` / `borderColor` / `borderWidth` / `shadow` 的表现，**与 `materialColor` 无关**。**本工程四条背板通路一律不传该参数**（见 §12.7） |
| `colorInvert` | `false` | 对材质节点子树中的支持颜色接口启用自动反色；只在高、中算力、满足薄材质和特殊资源条件时生效 |
| `applyShadow` | `true` | 使用材质自带阴影；此时通用 `shadow` 不生效 |
| `interactive` | `false` | 开启按压时的交互形变 |
| `lightEffect` | `undefined` | 传入对象启用触点流光，`null` 显式关闭；默认流光色为 `Color.White`；该效果主要在高、中算力设备生效 |

### 5.1 材质赋色

正确：

```ts
new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  materialColor: '#33FF0000'
})
```

错误：

```ts
new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  materialColor: '#FFFF0000'
})
```

`#33FF0000` 带透明度，能在保留材质滤镜的同时增加色调；`#FFFF0000` 完全不透明，会把材质层盖成纯红色。`materialColor` 可以使用应用颜色资源，但它不等价于 `colorInvert` 所要求的“特殊系统资源”。

### 5.2 交互形变与点光源

```ts
Column() {
  Text('按压我')
}
.width(160)
.height(56)
.borderRadius(28)
.backgroundColor(Color.Transparent)
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN,
  interactive: true,
  lightEffect: {}
}))
```

当 `lightEffect` 生效时，部分组件默认的点击态和悬浮态反馈会被材质光感反馈替代。不要在同一控件上叠加一套含义重复的自定义按压动画。

### 5.3 阴影

材质阴影和通用阴影二选一：

```ts
Column() {
  Text('自定义阴影')
}
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR,
  applyShadow: false
}))
.shadow({ radius: 20, color: Color.Black })
```

如果保留 `applyShadow: true`，不要再设置 `shadow`；材质阴影优先，自定义阴影不会生效，还会增加重复绘制。

## 6. 自动反色 `colorInvert`

> **适用范围**：本节只讲 ArkUI 的 `uiMaterial` 通路。**HDS 通路没有反色能力**——HDS 的
> `SystemMaterialParams` 只有 `materialType` 与 `materialLevel` 两个字段，本地 SDK 的 HDS 声明
> （`@hms.hds.hdsBaseComponent.d.ets` 等）中**没有任何 invert 相关符号**。走 HDS 材质宿主的位置
> （§12.9）因此不存在"开不开反色"这个问题，只能靠 §12.3 的前景色规则保证可读性。

自动反色用于高透明材质背景下的文字、图标可读性。它不是通用的“把所有颜色取反”，而是系统在材质子树中扫描特定属性接口和特定资源值，按底层背景计算前景色。

官方术语是「**自动适配背景色的互补色**」（SDK 原文：*the subtree of the node of the material object
automatically adapts the material to the complementary color of the background color*）。三条性质决定了
它的行为边界：

1. **作用域是"材质对象节点的子树"**，不是"某类组件自带的能力"。组件不在任何名单里，判定是三个集合的
   交集：**材质子树** × **属性白名单**（§6.2）× **特殊资源值**（§6.3）。
2. **它是阈值型、非确定性的能力**：`colorInvert: true` 只表示"允许"，实际是否适配由系统判定——SDK
   注释口径是"材质层足够薄时才适配"，可适配材质由系统定义、**至少**需要 `THIN` / `ULTRA_THIN`，且与
   **应用的沉浸光感强度配置**联动：材质越薄、光感越强，越容易满足要求。所以"开了没效果"是正常结果，
   不是 bug（另有 Note：只对高 / 中算力设备的显示效果生效）。
3. **只对"特殊资源值"生效**：白名单属性上必须写 §6.3 表 1 的 `sys.color.*`；硬编码色值与应用自定义
   资源（`AppColors.*`）都不参与计算。

### 6.1 必须同时满足的条件

1. `style` 是 `THIN` 或 `ULTRA_THIN`。
2. 设备是高算力或中算力；低算力设备设置 `colorInvert` 不产生视觉差异。
3. 系统沉浸光感强度和材质透明度达到系统触发阈值；材质越薄、系统强度越强，越容易触发。
4. 颜色通过支持的属性接口设置。
5. 颜色值是官方 API 参考表 1 中的特殊系统资源。
6. 应用级状态不是 `DISABLE`。

### 6.2 颜色属性白名单

**以本地 SDK 声明为准**（`@ohos.arkui.uiMaterial.d.ts` 里 `colorInvert` 的说明，API 26.0.0）。
SDK 明确列举的可反色属性**只有下面这些**，清单外的属性不得假定能反色：

- `Text.fontColor`。
- `Button.fontColor`。
- `SymbolGlyph.fontColor`。
- `Image.fillColor`。
- `Search.placeholderColor`、`Search.fontColor`、`Search.searchIcon`、`Search.cancelButton`、`Search.caretStyle`。
- `TabContent.tabBar` 使用 `BottomTabBarStyle` 时的文字与图标色。

⚠️ **与官方网页 API 参考的差异**：网页版另外列出了 `Chip` / `ChipGroup` / `TextArea` / `TextInput` /
`SegmentButton` / `Swiper` 的颜色属性以及 `Search.searchButton`，但**本地 SDK（API 26）的
`colorInvert` 说明中没有它们**。按"系统 API 以本地 SDK 为准"的门禁，这些属性**不得作为反色依据**；
确需依赖时只能真机逐项验证，验证前一律视为不生效。

错误写法：

```ts
Text('标题')
  .fontColor(Color.White)
```

推荐写法：

```ts
Text('标题')
  .fontColor($r('sys.color.font_primary'))
```

`Color.White`、`'#FFFFFFFF'` 等硬编码色值不会触发自动反色。旧的 `sys.color.ohos_id_color_*` 命名资源也不能作为本工程的自动反色依据；新代码必须从官方表 1 中选择资源。

### 6.3 官方特殊系统资源表

下表是 `colorInvert` 可识别的资源和官方深浅色值。表外资源不得假定能够自动反色。

| 特殊资源 | 浅色 | 深色 |
| --- | --- | --- |
| `$r('sys.color.brand')` | `#FF0A59F7` | `#FF317AF7` |
| `$r('sys.color.brand_font')` | `#FF0A59F7` | `#FF5291FF` |
| `$r('sys.color.warning')` | `#FFE84026` | `#FFD94838` |
| `$r('sys.color.font_on_primary')` | `#FFFFFFFF` | `#FFFFFFFF` |
| `$r('sys.color.font_primary')` | `#E5000000` | `#E5FFFFFF` |
| `$r('sys.color.font_secondary')` | `#99000000` | `#99FFFFFF` |
| `$r('sys.color.font_tertiary')` | `#66000000` | `#66FFFFFF` |
| `$r('sys.color.font_fourth')` | `#33000000` | `#33FFFFFF` |
| `$r('sys.color.font_emphasize')` | `#FF0A59F7` | `#FF5291FF` |
| `$r('sys.color.icon_primary')` | `#E5000000` | `#E5FFFFFF` |
| `$r('sys.color.icon_secondary')` | `#99000000` | `#99FFFFFF` |
| `$r('sys.color.icon_tertiary')` | `#66000000` | `#66FFFFFF` |
| `$r('sys.color.icon_fourth')` | `#33000000` | `#33FFFFFF` |
| `$r('sys.color.icon_emphasize')` | `#FF0A59F7` | `#FF5291FF` |
| `$r('sys.color.icon_sub_emphasize')` | `#660A59F7` | `#665291FF` |
| `$r('sys.color.comp_background_primary_contrary')` | `#FFFFFFFF` | `#FFE5E5E5` |
| `$r('sys.color.comp_background_primary_contrary_secondary')` | `#FFFFFFFF` | `#FF666666` |
| `$r('sys.color.comp_background_secondary')` | `#19000000` | `#19FFFFFF` |
| `$r('sys.color.comp_background_tertiary')` | `#0C000000` | `#19FFFFFF` |
| `$r('sys.color.comp_background_emphasize')` | `#FF0A59F7` | `#FF317AF7` |
| `$r('sys.color.comp_emphasize_secondary')` | `#330A59F7` | `#33317AF7` |
| `$r('sys.color.comp_emphasize_tertiary')` | `#190A59F7` | `#19317AF7` |
| `$r('sys.color.comp_divider')` | `#33000000` | `#33FFFFFF` |
| `$r('sys.color.interactive_hover')` | `#0C000000` | `#19FFFFFF` |
| `$r('sys.color.interactive_focus')` | `#FF0A59F7` | `#FF317AF7` |
| `$r('sys.color.interactive_pressed')` | `#19000000` | `#26FFFFFF` |

### 6.4 最小可验证反色示例

```ts
import { uiMaterial } from '@kit.ArkUI';

@Entry
@Component
struct InvertButtonDemo {
  build() {
    Button('操作')
      .fontColor($r('sys.color.font_primary'))
      .backgroundColor(Color.Transparent)
      .systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true
      }))
  }
}
```

注意：在 Release 中，`Button` 必须位于 Navigation 标题栏或横向 Tabs 底部 TabBar，除非它是弹窗内部的按钮；否则 `colorInvert` 条件全部满足也看不到材质。

## 7. 组件适配规则

### 7.1 Navigation 标题栏

- 应用级 `ENABLE` 时，标题栏默认 `ULTRA_THIN`。
- 组件级通过 `NavigationTitleOptions.systemMaterial` 设置。
- 通用组件位于标题栏区域内时可生效；标题栏生效范围主要是返回键和非自定义 Menu。
- 推荐 `barStyle: BarStyle.STACK`，让内容延伸至标题栏下方，材质才能透出内容。

```ts
import { uiMaterial } from '@kit.ArkUI';

@Entry
@Component
struct NavigationMaterialDemo {
  @Builder
  titleBar() {
    Row() {
      Text('标题')
        .fontSize(22)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      Button('操作')
        .backgroundColor(Color.Transparent)
        .fontColor($r('sys.color.font_primary'))
        .systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          colorInvert: true,
          interactive: true,
          lightEffect: {}
        }))
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
  }

  build() {
    Navigation() {
      Column() {
        Text('页面内容')
      }
      .width('100%')
      .height('100%')
    }
    .title({ builder: this.titleBar, height: 64 }, { barStyle: BarStyle.STACK })
  }
}
```

### 7.2 底部 Tabs

普通组件要借助底部 TabBar 使材质生效，三个条件必须同时满足：

- `barPosition: BarPosition.End`。
- `vertical(false)`。
- `barOverlap(true)`，使 TabBar 使用悬浮样式。

材质设置在 `barFloatingStyle.systemMaterial`，不是 `TabContent` 本身。`TabContent` 不支持直接设置沉浸光感。

```ts
import { uiMaterial } from '@kit.ArkUI';

@Entry
@Component
struct TabsMaterialDemo {
  build() {
    Tabs({ barPosition: BarPosition.End }) {
      TabContent() {
        Column() {
          Text('首页')
        }
      }.tabBar('首页')

      TabContent() {
        Column() {
          Text('设置')
        }
      }.tabBar('设置')
    }
    .vertical(false)
    .barOverlap(true)
    .barFloatingStyle({
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true
      })
    })
    .width('100%')
    .height('100%')
  }
}
```

### 7.3 弹窗、菜单和气泡

弹窗类是 Release 仍允许页面任意区域生效的核心场景。不要用 `Stack` + `Visibility` 自己模拟弹窗并把材质加在外层容器上；这类普通容器仍然受生效范围限制。应使用官方弹窗 API 的 options 设置 `systemMaterial`。

```ts
import { uiMaterial } from '@kit.ArkUI';

@CustomDialog
struct MaterialDialog {
  controller?: CustomDialogController;

  build() {
    Column() {
      Text('这是自定义弹窗')
      Button('关闭')
        .onClick(() => {
          this.controller?.close()
        })
    }
    .width(328)
    .height(216)
    .padding(24)
  }
}

@Entry
@Component
struct MaterialDialogPage {
  private readonly dialogController: CustomDialogController = new CustomDialogController({
    builder: MaterialDialog(),
    systemMaterial: new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THICK
    })
  })

  build() {
    Button('打开弹窗')
      .onClick(() => {
        this.dialogController.open()
      })
  }
}
```

Dialog 默认通常使用 `ULTRA_THICK`，Menu/Toast/AlphabetIndexer 通常使用 `THICK`。若主动设置了不透明背景、背景模糊或冲突阴影，默认材质可能不再出现。`CalendarPicker` 拉起的弹窗目前不支持通过通用方式获得弹窗材质，设置在组件本身的通用属性只影响组件本身。

### 7.4 Button、Select、Toggle、Slider

| 组件 | 关键规则 |
| --- | --- |
| `Button` | 应用级 `ENABLE` 不会默认开启；组件级使用 `systemMaterial`。薄材质配合官方系统颜色可自动反色；`lightEffect` 生效后默认点击/悬浮态可能被替代 |
| `Select` | 下拉按钮和下拉菜单独立控制；按钮默认 `ULTRA_THIN` + `interactive` + `lightEffect`，菜单默认 `THICK`；关闭某一侧使用 `Material.empty`，不要用 `undefined` |
| `ToggleType.Checkbox` | 当前未适配沉浸光感，设置后无材质效果 |
| `ToggleType.Switch` | 传入材质主要作为启用标记，实际视觉使用组件内部预设，随算力等级变化 |
| `ToggleType.Button` | 规则接近 Button，影响背景、边框和阴影 |
| `Slider` | 材质参数主要是启用标记，实际视觉由 Slider 内部预设；`undefined` 恢复普通样式；只有 `SliderBlockType.DEFAULT` 且 `SliderStyle` 不为 `NONE` 时交互反馈完整 |

### 7.5 ChipGroup 与 SegmentButton

- `ChipGroup` 的组件级接口是 `backgroundSystemMaterial`、`selectedBackgroundSystemMaterial`、`iconBackgroundSystemMaterial`；默认样式通常是 `ULTRA_THIN`。
- `SegmentButton` 使用 `SegmentButtonOptions.backgroundSystemMaterial`；`SegmentButtonV2` 在对应 options 中设置。
- 胶囊型多选 `SegmentButton`（`type: 'capsule'` 且 `multiply: true`）不支持 `backgroundSystemMaterial`。
- 自动反色需要将文字和图标颜色设置为官方特殊系统资源。
- Release 下，这些组件在普通内容区仍受标题栏/底部 TabBar 范围限制，组件 API 支持不等于页面任何位置都生效。

### 7.6 AlphabetIndexer

- `ENABLE` 时默认 `THICK`。
- `popupBackground` 和 `popupBackgroundBlurStyle` 未主动设置时，提示弹窗可自动使用材质。
- 主动设置上述任一属性会与沉浸光感互斥。
- 高、中算力默认显示 `THICK`；低算力降级为白色背景。

### 7.7 其余组件

普通布局容器、滚动容器、Text、Image 等都可能在 API 层面接受 `systemMaterial`，但 Release 后“接受属性”不代表“当前区域生效”。默认判断：

```text
组件属于弹窗/Slider/Toggle/Select？       -> 页面任意区域可生效
否则位于 Navigation 标题栏？              -> 可生效
否则位于横向 Tabs 的 BarPosition.End TabBar？ -> 可生效
否则                                     -> 材质不生效
```

## 8. 属性冲突与显示层级

### 8.1 背景必须透明或不设置

材质位于组件背板层；不透明 `backgroundColor`、`backgroundBlurStyle` 或自绘内容层背景可能覆盖材质，使组件看起来仍是纯色。

```ts
Column() {
  Text('可见材质')
}
.width(328)
.height(56)
.borderRadius(28)
.backgroundColor(Color.Transparent)
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.THIN
}))
```

不要在材质上再叠加 `backgroundBlurStyle`、`backgroundEffect` 或重复的背景模糊。材质本身已经包含材质滤镜和模糊能力。

### 8.2 `systemMaterial` 应放在通用样式之后

通用属性写法中，把 `systemMaterial` 放在尺寸、圆角、背景、边框和阴影等样式之后：

```ts
Column() {
  Text('推荐顺序')
}
.width(328)
.height(56)
.borderRadius(28)
.backgroundColor(Color.Transparent)
.systemMaterial(new uiMaterial.ImmersiveMaterial({
  style: uiMaterial.ImmersiveStyle.REGULAR
}))
```

通过弹窗 options、组件专属 options 设置的材质不受 ArkUI 通用属性书写顺序影响。

### 8.3 边框的折射表现

薄材质的边框区域可能显示周围背景的颜色，这是折射导致的正常光学表现，不一定是边框失效。需要降低折射时，可选择更厚的样式，或添加半透明 `materialColor`。

### 8.4 材质区域与可视区域

材质渲染区域按组件布局区域计算，不一定等于实际内容的可视区域。例如 Text 的可视区域是文字，但材质按其布局矩形计算。通过显式 `width`、`height`、`borderRadius` 统一两者。Text 本身不能直接为文字内容设置沉浸式系统材质，应给容器设置。

## 9. 功耗与性能约束

沉浸光感会消耗 GPU 资源，性能规则不是可选的视觉建议，而是 Release 收紧范围的直接背景。

### 9.1 面积和层数

- 材质影响区域越大，采样像素越多，功耗越高。
- 不要给整页背景套材质，也不要给大量小节点重复套材质。
- 同一子树只在最外层设置一次材质，禁止内外嵌套多个材质。
- 优先在标题栏、底部悬浮 TabBar、局部操作按钮、必要弹窗使用。

### 9.2 动态内容

不要把材质固定叠在视频、动图、持续动画上方。折射和模糊需要实时采样背景，背景每帧变化会导致材质重新计算。

### 9.3 弹窗尺寸

Dialog/Menu 的空间动效面积越大，绘制开销越高。避免接近全屏的沉浸材质弹窗，优先保持约 328×216 等合理内容尺寸，并让页面内容负责滚动。

### 9.4 自动反色范围

`colorInvert` 会逐个计算材质子树中通过资源接口设置的颜色。不要把它放在包含大列表、大量文本和图标的最外层；仅包住需要保证可读性的局部操作区。

### 9.5 参数和子树稳定

不要在定时器中频繁修改 `style`、`materialColor`，也不要在材质区域内频繁增删子节点。材质参数应在初始化时确定，子树结构应尽量稳定。

## 10. 低版本兼容

沉浸光感从 API 26.0.0 开始支持。兼容低版本时必须同时考虑应用级开启和组件级开启。

### 10.1 应用级开启的兼容

当应用为 `default` 或 `enable` 时，官方默认材质组件可能自动接管背景、模糊、边框和阴影。需要使用 `getMaterialInfo()` 判断当前状态，材质开启时清除会遮挡材质的背景：

```ts
import { uiMaterial } from '@kit.ArkUI';

@Entry
@Component
struct AppLevelCompatibility {
  private readonly materialInfo: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();

  build() {
    Select([{ value: '选项一' }, { value: '选项二' }])
      .value('选择')
      .backgroundColor(this.materialInfo.state === uiMaterial.MaterialState.ENABLE ?
        undefined : Color.White)
  }
}
```

这个模式让材质启用时不被白色背景遮挡；材质未启用时仍保留原来的白色背景。

### 10.2 组件级开启的兼容

组件级 `systemMaterial` 和 `ImmersiveMaterial` 在 API 26 以下不可用。按运行时系统 API 判断，低版本传 `undefined`，让组件保留原样式：

```ts
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

@Entry
@Component
struct ComponentLevelCompatibility {
  build() {
    Select([{ value: '选项一' }, { value: '选项二' }])
      .value('选择')
      .systemMaterial(deviceInfo.sdkApiVersion >= 26 ?
        new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN
        }) : undefined)
  }
}
```

如果应用整个 module 已固定要求 API 26，可以不写低版本分支；如果需要一个 HAP 兼容旧设备，必须保留这种运行时判断。

## 11. HDS 沉浸光感接入

HDS 是官方为导航和底部页签提供的高层组件。它把材质类型和等级配置收敛到 `systemMaterialEffect`，推荐使用系统自适应等级。

### 11.1 HDS 等级和类型

`hdsMaterial.MaterialType` 主要包含：

- `NONE`：无材质。
- `ADAPTIVE`：系统自适应材质，默认优先选择。
- `IMMERSIVE`：沉浸式材质。

`hdsMaterial.MaterialLevel` 包含 `EXQUISITE`、`GENTLE`、`SMOOTH`、`ADAPTIVE`。推荐 `ADAPTIVE`，不要在低端设备上强制 `EXQUISITE`。

### 11.2 HDS Navigation

```ts
import { HdsNavigation, hdsMaterial } from '@kit.UIDesignKit';

@Entry
@Component
struct HdsNavigationDemo {
  build() {
    HdsNavigation() {
      Column() {
        Text('内容')
      }
    }
    .titleBar({
      style: {
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
  }
}
```

标题栏滚动效果可以结合 `scrollEffectOpts` 和 `ScrollEffectType.GRADIENT_BLUR` 或 `IMMERSIVE_GRADIENT_BLUR`，但不要在同一区域额外叠加 ArkUI 的重复模糊属性。

### 11.3 HDS Tabs

```ts
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';

@Entry
@Component
struct HdsTabsDemo {
  build() {
    HdsTabs() {
      HdsNavDestination() {
        Text('首页')
      }
      HdsNavDestination() {
        Text('设置')
      }
    }
    .barPosition(BarPosition.End)
    .vertical(false)
    .barOverlap(true)
    .barFloatingStyle({
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
  }
}
```

HDS 的材质类型/等级与 ArkUI 的 `ImmersiveStyle` 不是一一对应关系。不要把 `hdsMaterial.MaterialLevel` 当作 `uiMaterial.MaterialLevel` 使用，也不要期待 HDS 提供 `ULTRA_THIN` 等厚薄枚举。

## 12. 本工程落地契约

本工程是 API 26 Stage 模型单 entry 应用，`build-profile.json5` 的目标 SDK 与兼容 SDK 为 26.0.0。
材质按**生效区域**分两条通路，判断顺序固定为「先看能不能用系统材质，不能才自绘」：

| 位置 | 通路 | 工厂 |
| --- | --- | --- |
| 官方弹窗（`CustomDialogController`，含 `AlertDialog` / `TipsDialog` / `SelectDialog` / `CustomContentDialog`） | 系统沉浸材质 | `dialogMaterial`（`THIN` + `applyShadow: true`，**不赋色**，见 §12.7） |
| 半模态面板（`bindSheet`，含子版块筛选、回复 / 发帖编辑器、写私信） | 系统沉浸材质 | `sheetMaterial`（同 `dialogMaterial`，**不赋色**，见 §12.7） |
| 菜单（`bindMenu` / `bindContextMenu`） | 系统沉浸材质 | `menuMaterial`（`THICK` + `applyShadow: true`，**不赋色**） |
| 气泡（`bindPopup`，含页码选择器、资料卡） | 系统沉浸材质 | `popupMaterial`（`REGULAR` + `applyShadow: true`，**不赋色**） |
| `Slider` / `Toggle` | 系统沉浸材质 | `controlMaterial`（`THIN` + 交互形变 + 点光源） |
| 页面内容区的**右下角浮动控件**（发帖 / 刷新 / 回复按钮、页码指示器） | **HDS 材质宿主（非合规旁路）** | `HdsMaterialHost` → `HdsTabs` 的 `barFloatingStyle.systemMaterialEffect`（见 §12.9） |
| `PanelNavBar` 的**返回 / 右侧操作按钮**（标题栏是自绘 `Stack`，不在 `Navigation` 标题栏内） | **HDS 材质宿主（非合规旁路）** | 同上；材质块 `TITLE_POD_SIZE`（36vp，见 §12.9） |
| 页面内容区其他常驻控件（面板、列表、`PanelNavBar` **栏位本体**、`Toast`） | 自绘磨砂玻璃 | `surfaceMaterial` / `barMaterial` / `fabMaterial` / … |
| 图片查看器（`bindContentCover` 全屏模态、固定暗场景） | 自绘磨砂玻璃 | `darkOverlayMaterial` / `closeButtonMaterial` |

判定依据就是本文 §0 的生效范围门禁：本工程没有 `Navigation` / `Tabs`，**内容区没有任何标题栏或
底部 TabBar 可以借位**，所以 ArkUI 的 `systemMaterial` 在内容区（含 `PanelNavBar` 这个自绘标题栏）
一律不生效——要么自绘玻璃，要么走 §12.9 的 HDS 材质宿主旁路；而弹窗类组件与接口（含半模态转场）以及
`Slider` / `Toggle` 在 Release 下允许「页面内全部区域」生效，因此这些位置一律优先用系统材质。
弹窗 / 面板**内部**的内容层同理不能自绘模糊，改用 `dialogFieldMaterial` / `dialogActionMaterial`。

两条通路的衔接铁律：**同一个视觉层不叠加两种材质**。系统材质渲染在**背板层**、`backgroundColor`
等属性渲染在**内容层**，内容层会盖住背板层（官方 FAQ 明确此层级模型）。所以接了系统材质的
位置不要再写不透明 `backgroundColor`，内部输入框 / 中性按钮也不要用带模糊的 `GlassModifier`。

### 12.1 磨砂玻璃工厂（页面内容区）

材质统一收敛在 [`UIMaterialManager.ets`](../entry/src/main/ets/common/managers/UIMaterialManager.ets)：
`GlassModifier implements AttributeModifier<CommonAttribute>` 的只读单例用
`.attributeModifier(UIMaterialManager.xxx)` 绑定，**只用于页面内容区拿不到系统材质的位置**；
Release 清单内的组件（`Slider` / `Toggle` / `Select`）仍走通用属性 `.systemMaterial(controlMaterial)`
——两者不是替代关系，而是"能走系统材质就走系统材质，不能才自绘"（§12 分流表）。

| 工厂材质 | 用途 | 磨砂参数（模糊半径 / 饱和度 / 填充不透明度） |
| --- | --- | --- |
| `fabMaterial` | 浮动圆形/胶囊按钮（内容区常驻控件；**不含 `PanelNavBar` 标题栏按钮**——那三颗已迁 HDS 材质宿主，见 §12.9） | 36vp、1.4、55% + 极淡整圈描边 + 下沉投影（不设渐变） |
| `surfaceMaterial` | **当前无调用点**（页面内容区的浮层已全部迁到官方弹窗类接口，保留备用） | 72vp、1.5、42% + 描边 + 强投影 |
| `barMaterial` | 标题栏、消息页栏位 | 56vp、1.4、42% + 描边，不投影 |
| `neutralActionMaterial` | **当前无调用点**（保留备用；面板内的中性次要操作走 `dialogActionMaterial`） | 32vp、1.4、32% + 细描边，不投影 |
| `inputMaterial` | 内容区常驻输入框（登录页等） | 24vp、1.3、32% + 低透明描边，不投影 |
| `dialogFieldMaterial` | 系统材质背板之上的输入框 / 内容层（**不做模糊**） | 无模糊、暖白半透明填充 + 极淡描边 |
| `dialogActionMaterial` | 系统材质背板之上的**中性次要操作**（子版块筛选面板的「关闭」胶囊） | 无模糊、填充 32% + 描边 |
| `darkOverlayMaterial` | 图片查看器等固定暗场景浮层 | 48vp、1.2、固定深色填充 32% |
| `closeButtonMaterial` | 图片查看器关闭按钮 | 同暗场景玻璃 + 轻投影 |

玻璃的立体感由两层叠加表达：`backgroundColor` 半透明填充之上，再叠一条
`linearGradient`（顶部受光高光 → 中部透明 → 底部微暗），描边统一为一条极淡的整圈线。

两条边界约束（实测踩坑结论）：

- **描边禁止按边分色**（`border.color` 用 `EdgeColors` 顶亮底暗）：玻璃组件大多是圆角或正圆，
  所谓"顶边"在圆弧上会被渲染成一道突兀的白色弧线（按钮顶部尤其刺眼）。厚度感交给渐变表达，
  描边只负责极淡的整圈轮廓。
- **纵向渐变只给高度足够的容器**（面板、栏位）。胶囊按钮、圆形按钮高度小，矩形渐变会被压成
  "顶部亮带 + 底部暗带"，因此 `fabMaterial`、`neutralActionMaterial`、`inputMaterial`、
  `darkOverlayMaterial`、`closeButtonMaterial` 一律不设渐变，只靠模糊 + 描边 + 投影成形。

玻璃对象是稳定的只读配置，跨组件共享，渲染期不新建、不修改。

### 12.2 磨砂玻璃四条硬规则

1. **同名属性不得与 `attributeModifier` 重复**。官方明确「在 attributeModifier 中设置的属性尽量
   不要与其他方法设置的属性相同，避免在页面刷新时 attributeModifier 不生效」——属性方法的优先级
   高于 `attributeModifier`。因此玻璃组件上**禁止**再出现 `.backgroundColor(...)`（尤其是
   `Color.Transparent`，它会把玻璃填充整层抹掉）、`.backgroundEffect(...)`、`.border(...)`、
   `.shadow(...)`；确实需要偏离默认玻璃时，就在这些属性上显式写值（即用属性方法覆盖玻璃层）。
2. **填充走 `backgroundColor`，磨砂走 `backgroundEffect`**。`backgroundColor` 还负责覆盖 Button、
   TextInput 等组件的系统默认底色；若只用 `backgroundEffect({ color })` 承载填充，Button 会露出
   系统默认蓝底（本工程实测踩过）。两者分工后不重复着色：`backgroundColor(fill)` +
   `backgroundEffect({ radius, saturation, brightness })`。
3. **透度按“填充 / 半径 / 饱和度”三者协同调**：填充 32%~55%（`$r('app.color.glass_*')` 的 8 位
   ARGB 色），半径 24vp~72vp，饱和度 1.3~1.6。只顾降 alpha、不同步加大半径，背景文字会直接干扰
   正文；只顾加大半径、不同步提饱和度，玻璃会发灰。填充接近不透明则模糊层被盖住、玻璃退化成
   纯色卡片——"看不到透明性"通常就是这个原因。另外背景模糊只有在**背后确有内容**时才可见；
   叠在纯色页面底上的玻璃只能靠描边、受光渐变和阴影表达层次。
4. **前景色跟随主题**：玻璃层上的正文用 `UIMaterialManager.adaptiveForeground`
   （`sys.color.font_primary`）、次要文字用 `adaptiveSecondaryForeground`；固定暗场景（图片查看器）
   用 `onDarkForeground` 配合 `darkOverlayMaterial`。禁止在玻璃上使用硬编码黑/白文字色。

### 12.3 本工程前景色规则

- 主前景：`$r('sys.color.font_primary')`（`UIMaterialManager.adaptiveForeground`）。
- 次要前景：`$r('sys.color.font_secondary')`（`UIMaterialManager.adaptiveSecondaryForeground`）。
- 图标：`$r('sys.color.icon_primary')`、`$r('sys.color.icon_secondary')`。
- 主题色：`AppColors.primary`（应用琥珀主题）或 `$r('sys.color.brand')`。
- 深浅色一律走 `$r('app.color.*')` 资源限定词（`base/`=亮色、`dark/`=暗色），由 `setColorMode`
  联动解析，不要在代码里判断 `effectiveColorMode` 来切玻璃颜色。
- **系统材质背板 / 玻璃之上的前景，禁止使用 `AppColors.text*` 等应用自定义色**（`text_primary` /
  `text_secondary` / `text_tertiary` / `separator`）。这批颜色是为应用**实底** `bg`（亮 `#FEFAF6` /
  暗 `#121214`）调制的暖棕阶，而材质背板**不含应用 tint**（§12.7）且**半透明**：色相不匹配之外，
  低对比那两档（亮色 `#9C8B7A` / `#C4B5A0`）在实底上"刚好够用"的余量会被透出的背景内容吃光。
  所有弹窗 / 半模态 / 菜单 / 气泡的**内容层**一律取 `UIMaterialManager.adaptive*`；分隔线取
  `$r('sys.color.comp_divider')`、中性徽标底取 `$r('sys.color.comp_background_secondary')`
  （均见 §6.3 表 1）。应用色只保留在两个语义位置：**实底主操作的品牌色**
  （`AppColors.primary` + `AppColors.white`，§12.5）与**页面内容区的实底场景**（`AppColors.bg` 等）。
  2026-09 复核：`SubBoardFilterPanel`（子版块筛选半模态）是最后一个漏改的浮层，已按本条重做取色
  ——它是"材质 + 应用色"混搭的典型症状来源（低对比文字叠在半透明材质上，亮色下几乎不可辨）。

### 12.4 应用级材质开关

`entry/src/main/module.json5` 保留：

```json5
{
  "name": "ohos.arkui.UIMaterial.state",
  "value": "enable"
}
```

该开关只影响系统官方清单组件（Navigation 标题栏、Select、Toggle、Slider、菜单等）的默认材质，
与本工程自绘磨砂玻璃无关；改玻璃参数不需要动它。

**但它现在是弹窗 / 面板系统材质的前提**：应用级 `disable` 是总禁用，会连组件级
`systemMaterial` 一起压掉（§3.2 优先级 1）。因此接了 `dialogMaterial` / `sheetMaterial` /
`controlMaterial` 之后**不要改成 `disable`**；`default` 会丢掉官方清单组件的默认材质，
组件级配置仍在，但没必要退到 `default`。维持 `enable` 即可——组件级材质优先级更高，
会覆盖应用级默认效果，所以调材质参数同样不需要动它。

### 12.5 主操作按钮

主操作按钮不默认接入玻璃材质。确认、保存、退出、发送等承担明确操作语义的按钮使用实底主题色和高对比文字；需要中性浮动反馈的操作才使用 `neutralActionMaterial`。

原因：主题色玻璃叠在面板材质上容易出现背景贴边、前景对比不稳定和黑字/浅棕底等问题；实底按钮在低算力和不同背景上更可靠。

### 12.6 SaveButton

`SaveButton` 属于安全组件，其样式受到系统合法性校验约束，不支持 `systemMaterial`、材质阴影或模糊。保持系统要求的高对比固定背托，不要尝试给安全按钮接入沉浸式材质。

### 12.7 系统沉浸材质接入清单（弹窗 + 交互控件）

材质工厂在 [`UIMaterialManager.ets`](../entry/src/main/ets/common/managers/UIMaterialManager.ets)：

| 工厂 | 材质（与 `UIMaterialManager.ets` 的实际参数一致，勿凭本节旧稿记忆） | 接入点 |
| --- | --- | --- |
| `dialogMaterial` | `ImmersiveMaterial`：`THIN` + `applyShadow: true`（**不赋色**） | `new CustomDialogController({ backgroundColor: Color.Transparent, builder: …, systemMaterial: … })` |
| `sheetMaterial` | 同 `dialogMaterial` | `SheetOptions.systemMaterial` |
| `menuMaterial` | `ImmersiveMaterial`：`THICK` + `applyShadow: true`（**不赋色**） | `MenuOptions.systemMaterial`（`bindMenu` / `bindContextMenu`） |
| `popupMaterial` | `ImmersiveMaterial`：`REGULAR` + `applyShadow: true`（**不赋色**） | `PopupOptions` / `CustomPopupOptions.systemMaterial`（`bindPopup`） |
| `controlMaterial` | `ImmersiveMaterial`：`THIN` + `interactive` + `lightEffect`（本就没有材质底色） | 通用属性 `.systemMaterial(...)`，用于 `Slider` / `Toggle` |
| `dialogFieldMaterial` | `GlassModifier`：暖白填充 + 极淡描边，**不做背景模糊** | `.attributeModifier(...)`，材质背板之上的输入框 |
| `dialogActionMaterial` | `GlassModifier`：填充 32% + 描边，**不做背景模糊** | `.attributeModifier(...)`，材质背板之上的中性按钮 |

**菜单 / 气泡的两个必设参数（官方默认值会与材质打架，踩过就当踩过）**：

- `bindPopup` 的 `backgroundBlurStyle` 默认是 `COMPONENT_ULTRA_THICK`、`popupColor` 默认是
  「透明 + 该模糊」：不显式写 `backgroundBlurStyle: BlurStyle.NONE` + `popupColor: Color.Transparent`，
  就是在系统材质之上再叠一层模糊与一层内容色。
- `bindMenu` 的 `MenuOptions` 继承了 `ContextMenuOptions.systemMaterial`（本地 SDK
  `common.d.ts:15637` / `15594` 可查）；应用级 `enable` 下菜单本身也有默认材质，显式设置是
  为了把档位收敛到本工程配方，不是"没设置就没材质"。
- 菜单位置由 `placement` 按**锚点组件几何**推导（`bindMenu` 默认 `Placement.BottomLeft`）：
  本工程一律取 `Placement.BottomRight`，锚点则必须是**尺寸确定的真实节点**：标题栏菜单挂在
  那颗 36×36 的操作按钮上，排序条的热门时间窗菜单挂在排序条右端一枚 36×28 的透明占位节点上，
  得到"锚点下方、右边缘对齐"的落点。**不要把 `bindMenu` 挂在整条标题栏 / 整行排序条这类宽锚点上**：
  折叠屏多列路由（md/lg）下锚点几何会被算到**窗口左侧**，sm 单列反而不暴露（详见
  `UI_COMPONENT_MIGRATION.md` §7.4 约束 7）。
- **`builder` 字段必须传构造器**：`CustomPopupOptions.builder` 是 `CustomBuilder`（`() => void`）。
  在 `build()` 内的参数位置写 `this.Xxx()`（`bindSheet` / `bindMenu` 的写法）会被 @Builder 语法糖
  正确转换；但在**普通方法返回的 options 字段**里写 `this.Xxx()` 会被立即求值成 `void`，
  气泡拿到空 builder → **整个气泡不渲染**（实机现象：点击锚点毫无反应）。该字段写
  `builder: (): void => { this.Xxx() }`。

#### 材质参数：以 `UIMaterialManager.ets` 为准（曾出现三方漂移）

本节曾同时存在三套互相矛盾的参数（表格写 `ULTRA_THICK`、正文写 `REGULAR` + 45% 暖白 +
`applyShadow: false`、代码写 `THIN` + `applyShadow: true`）。**以下以代码为唯一真源**，改参数时请直接看
[`UIMaterialManager.ets`](../entry/src/main/ets/common/managers/UIMaterialManager.ets)：

| 工厂 | `style` | `materialColor` | `applyShadow` |
| --- | --- | --- | --- |
| `dialogMaterial` / `sheetMaterial` | `THIN` | **无（不赋色）** | `true` |
| `menuMaterial` | `THICK`（官方菜单默认档） | **无（不赋色）** | `true` |
| `popupMaterial` | `REGULAR` | **无（不赋色）** | `true` |
| `controlMaterial` | `THIN` + `interactive` + `lightEffect` | 无（本就没有材质底色） | 默认 |

**四条系统材质通路一律不赋色，且层次手段按通路各不相同。** 两条历史教训：

1. **不要为了提层次把材质调暗。** 亮色模式下玻璃一度看着"平"，当时的处置是把 tint 改成偏暗的
   `#4D5A4632` 去"制造"明度差，结果玻璃发暗发黄、整个画面发闷，被否掉了。
2. **也不要再给材质加应用色相。** 曾用的 45% 暖白 tint（`app.color.material_surface_tint`，
   亮 `#73FEFAF6` / 暗 `#73121214`）已**全部移除**：四条通路（弹窗 / 半模态 / 菜单 / 气泡）的
   `materialColor` 一律留空，色调来源完全交给系统按深浅色模式自适应——与 HDS 通路
   （`HdsMaterialHost`，同样不传任何颜色）一致。该颜色资源已从 `base` / `dark` 的 `color.json`
   删除，不要再加回来。
   （边界：**「色调来源一致」不等于「观感一致」**。HDS 用 `materialType` / `materialLevel` 这套枚举、
   由 HDS 组件自身渲染，与 `ImmersiveStyle` 的厚薄档位和 `applyShadow` 没有对应关系——官方明确
   HDS 不提供与 `ImmersiveStyle` 对等的厚薄配置。不要把两条通路的参数互相套用。）

**层次手段按通路各不相同**（2026-09 独立审查逐点核对，勿再笼统写成"层次只由遮罩承担"）：

遮罩**只有一个值 + 一条叠层让位规则**，集中在 `UIMaterialManager`（唯一真源：业务代码只引用令牌，
不再直接引用 `AppColors`，更不写十六进制字面值；资源值落在 `resources/base|dark/element/color.json`）：

- `UIMaterialManager.scrim` → `app.color.overlay`：**亮 15%（`#26000000`）/ 暗 0%（`#00000000`）**
  ——半模态、资料卡气泡、页面级官方弹窗**全部取这一个值**（2026-09 定案；此前"面板 30/40 + 弹窗
  15/0"的两档已合并为一档）
- `UIMaterialManager.nestedScrim`（`Color.Transparent`）：**叠层让位**，只给「叠在本身带遮罩的浮层
  之上」的弹窗用，见下表

| 通路 | 遮罩实际情况 | 层次主要来源 |
| --- | --- | --- |
| 半模态（`sheetMaterial`，3 处选项定义 / 4 个 `bindSheet` 调用点） | ✅ `SheetOptions.maskColor = UIMaterialManager.scrim` | 遮罩 + 材质阴影 |
| 官方弹窗（`dialogMaterial`，32 处） | ✅ 页面级 **29 处**用 `UIMaterialManager.scrim`；叠层 **3 处**（`ReplyDialog` / `NewTopicDialog` 的放弃确认、`ProfileCardPopup` 笔记弹窗）用 `nestedScrim` 让位 | 材质阴影（`applyShadow: true`）为主 |
| 菜单（`menuMaterial`） | ❌ **无遮罩**（`bindMenu` 无 preview 时默认不显示；菜单的参数是 `mask` / `MenuMaskType`，**没有 `maskColor` 字段**） | `THICK` 档背景模糊 + 材质阴影 |
| 气泡（`popupMaterial`） | ⚠️ 资料卡 `mask: { color: UIMaterialManager.scrim }`；页码气泡显式 `mask: false` | `REGULAR` 档背景模糊 + 材质阴影 |

**为什么叠层必须"让位"**：每层浮层各自画一次遮罩，两层同时在场就是两层黑叠在一起（工程实测过
"半模态 30% + 弹窗 15% = 40.5%"的观感，且与"改一个值全局生效"的预期不符）。现在下层那一层
`scrim` 独自承担，**画面上任意时刻只有一层遮罩**。

**暗色的 0% 是取舍，不是漏配**：`#00000000` 是**完全透明但仍然生效**的一层遮罩——命中区、
`autoCancel` 的点击外部关闭、遮罩吞掉事件的行为都照常，只是不可见；暗色下浮层与背景的分离
**只靠材质阴影**。在此之前工程走的是「**不设** `maskColor`」→ 系统默认 `0x33000000`（固定 20% 黑、
**不随深浅色**），那正是要消除的魔法值，**不要退回不设 `maskColor` 的写法**（SDK 默认值见
`component/custom_dialog_controller.d.ts`）。

日后若觉得浮层与背景分不开，改 `scrim` 对应的**资源值**（一处生效于全部接入点），或调菜单 / 气泡
档位（它们**没有 `maskColor` 可调**）。**一律不要往材质里加色。**

至于**为什么同一套材质在暗色下天生更好看**（这是材质物理特性，不是参数没调对）：材质的边缘
高光、折射、流光**都是亮部细节**，在暗背景上对比度最高；亮色模式下背景内容本身亮度高，模糊
之后仍是"花花一片"，而暗色模式的背景已被压暗，模糊出来是柔和的暗色块。所以两条通路各有取向：
**暗色 = 光学感强，亮色 = 干净通透**，不要把亮色硬调成暗色的样子。

在真机上逐轮替换参数、截图对比得到的事实（档位评价仍然成立，**当前取值见上表**）：

| 参数 | 实测表现 |
| --- | --- |
| `ULTRA_THICK`（官方对 Dialog 的推荐值） | **就是一块不透的白板**，与背景是否透明无关（两张不同配置的截图逐像素完全相同）——这是"没有高透玻璃感"的直接原因 |
| `ULTRA_THIN` | 几乎全透，背景文字与前景文字重叠，可读性崩 |
| `THIN` | 背景可见且柔和、前景清晰——**当前弹窗 / 面板 / 半模态取值**（注意：该档位结论是**配暖白 tint 时**测得的，tint 移除后**尚未重新做三档截图对比**；用户已目视确认无 tint 版本优于带 tint 版本，但 `THIN` / `REGULAR` / `ULTRA_THIN` 三档在无 tint 条件下的相对优劣未验证） |
| `REGULAR` | 比 `THIN` 更实一档，用于小面积气泡（`popupMaterial`），避免压住上下文 |
| `THICK` | 官方菜单默认档，用于"浮在内容之上"的菜单（`menuMaterial`） |

系统材质**没有模糊半径参数**："又透又柔"靠的是档位自带的模糊。背景杂色偏重时，宁可换更厚的档位，
也不要靠 `materialColor` 给材质加色——四条背板通路一律不赋色（见上表），色调交给系统深浅色自适应。
想把背景糊成更柔和的色块，只有自绘 `backgroundEffect`（大半径）能做到。

#### 生效边界：按「组件类型」判定，不按「组件在哪一层」

真机实测确认（输入框设了 `.systemMaterial(...)` 后完全没有背景、只剩文字）：
**Release 下普通组件写 `.systemMaterial(...)` 不生效**——即使它处在官方浮层内部。判定的维度是
**组件类型，不是组件所处的层级**：

- 面板 / 菜单 / 气泡**本体** → 由承载接口的 options 拿系统沉浸材质
  （`SheetOptions` / `CustomDialogControllerOptions` / `MenuOptions` / `CustomPopupOptions`）。
- 本体**内部**的普通组件（工具条按钮、输入框、中性按钮、`Text`、`Image`）→ 不在官方清单内，
  任何位置都不生效，只能用自绘内容层材质（`dialogFieldMaterial` / `dialogActionMaterial`）。
  Beta1 时这些控件能直接吃系统材质，Release 收紧生效范围后不行了——**这是与 Beta1 截图唯一的
  观感差距来源**。
- 本体内部若出现 **`Toggle` / `Slider` / `Select`**，它们**依然生效**：这三者在 Release 清单里是
  「页面内全部区域」，与所在层级无关。`SubBoardFilterPanel`（半模态子版块筛选）里的
  `Toggle(Switch)` 继续走 `controlMaterial` 就是这个道理。

#### 三条落地要点

1. **弹窗材质写在承载接口的 options 上，不是内容组件的通用属性。** 官方高级模板
   （`@ohos.arkui.advanced.Dialog` 的 `AlertDialog` / `TipsDialog` / `SelectDialog` /
   `CustomContentDialog`）的 options **没有** `backgroundColor` / `systemMaterial` 字段，
   材质只能写在外层 `CustomDialogController` 的 options 上。
2. **弹窗与面板都必须显式 `Color.Transparent` 背景。** `CustomDialogControllerOptions.backgroundColor`
   与 `SheetOptions.backgroundColor`（继承 `BindOptions`）默认都不透明 / 白色，会作为**内容层**盖住
   背板材质——实测不置透明时弹窗就是白板。半模态这一项直接置 `Color.Transparent`
   （不做设备降级，见本节末尾的约定说明）。
3. **`controlMaterial` 只给 `Slider` / `Toggle`。** `ToggleType.Checkbox` 官方明确未适配沉浸光感，
   设置后无效果；`ToggleType.Switch` 的材质参数只作启用标记，视觉走组件内部预设。自定义配色的
   功能型进度条（`AudioPlayer`，`SliderStyle.OutSet` + 显式 `blockColor` / `trackColor` /
   `selectedColor`）不接入，避免与材质内部预设冲突。

半模态面板的形状与阴影**全部交给系统材质**：容器不再自绘 `borderRadius` + `clip(true)` + 描边 +
`shadow`（`sheetMaterial` 的 `applyShadow: true` 已承担阴影，自绘装饰会与材质打架）。
（"容器保留 Beta1 自绘装饰"的旧写法已随 `sheetMaterial` 接入而作废。）

半模态的圆角由系统按 `radius`（默认 32vp）绘制，**贴底样式（`SheetType.BOTTOM`）不绘制底部两角**：
这是官方明示的规范（"底部样式不显示半模态底部 2 个圆角，即使设置了底部 2 个圆角也不生效"，
见《半模态转场》`radius` 一节），不是缺陷、也无法用 `radius` 改掉——底部面板与屏幕底边重合，
底部圆角在物理上无意义。

因此编辑类面板（回复 / 发新主题、写私信）**在全部断点统一用贴底样式**，宽屏只限宽、不切
`SheetType.CENTER`。两者绑定在一起的原因是**键盘避让方式**：编辑器关掉了系统避让
（`keyboardAvoidMode: NONE`），改用「窗口上报的键盘高度 = 内容底部 padding」自己把内容顶到输入法
上方，这套做法只在贴底样式下成立。切到居中样式会同时产生两个肉眼可见的坏结果（真机截图逐像素
实测）：① 内容被二次垫高且 `FIT_CONTENT` 按含键盘高度的内容测量，面板容器比内容高一截，多出的
高度堆在内容下方，工具行与键盘之间出现一条长空白；② 面板底边随之越出可视区，系统不再绘制底边，
面板变成"上圆下方"——顶边圆角清晰（实测约 45vp），底边却是全宽直线。宽屏限宽仍保留
（`SheetWidthConstants.resolve`），否则贴底面板会横贯整个窗口。

`colorInvert` 只在 `THIN` / `ULTRA_THIN` 下生效，且要求颜色走官方特殊系统资源（§6.3）。
`dialogMaterial` / `sheetMaterial` 现在是 `THIN`——**已经在自动反色的档位门槛内**，但工程并未开启
`colorInvert`，因此弹窗内容的前景色仍按 §12.3 用 `sys.color.font_*` / `icon_*` 保证深浅色可读性。

**设备不支持材质时不做兜底（程序约定）**：`uiMaterial.isImmersiveMaterialSupported()` 返回 `false` 时，
`systemMaterial` 上的 `ImmersiveMaterial` 完全不生效（官方声明原文）。**这类设备不在本工程的适配
范围内，也不允许为它们写降级分支**——气泡 / 菜单 / 半模态的背板一律写成"完全让位给系统材质"的
固定形式（气泡 `popupColor: Color.Transparent` + `backgroundBlurStyle: BlurStyle.NONE`；菜单不设
`backgroundColor`；半模态 `SheetOptions.backgroundColor: Color.Transparent`），材质不生效时背板全透明
是**接受**的结果。低算力设备不属于此类：它们由系统自行降级为背景色 / 边框 / 阴影，无需应用干预。
（历史上曾有 `sheetContentBackdrop` 这类"不支持则回退半透明填充"的常量，已按本约定删除。）

### 12.8 浮层内部的层级表达：描边优先，颜色差慎用

玻璃材质上的内容（输入区、工具条按钮、次级操作）**用描边 + 极淡填充表达层级，而不是用颜色差**。
这条取向的理由是结构性的，不是审美偏好：

1. **底色是动态的。** 玻璃层的实际颜色由「背景内容 + 系统模糊」共同决定（背板材质已不含应用 tint，
   见上表），随背后内容变化。内容元素若再用深浅色块表达层级，层级关系就跟着底色漂移——同一个按钮，
   背景是帖子列表时是一个观感，背景是空白页时又是另一个。
2. **描边是与底色无关的结构信息。** 一条细描边在任何底色上都能稳定表达"这里是输入区 /
   可交互区域"，不随背景改变而失效。
3. **官方层级模型本身要求内容层轻量。** 材质渲染在背板层，内容层的实色会盖住材质（§8.1），
   内容层越"轻"，材质越透得出来。

三条落地约束：

- **描边要极淡**（`glass_field_stroke` / `glass_neutral_stroke` 量级），填充只做轻微明度区分
  （输入区比面板略亮、中性按钮比输入区再实一点）。描边过亮过粗会退化成"线框 UI"。
- **纯描边不留填充也不行**：完全透明的输入区像未完成的占位符，需要一层极淡填充托底。
- **实底颜色留给语义。** 只有承担明确操作语义的按钮才用实底主题色（§12.5 的主操作按钮、
  破坏性操作如"退出""删除"）。它打破玻璃的连续质感、成为画面上唯一的视觉重点——这正是它有效的
  原因，所以不要为了"好看"给普通按钮也上实底。

**已落地实例（`SubBoardFilterPanel`，2026-09）**：该面板原先用三档应用色表达行状态
（生效 = `text_primary`、"已屏蔽" = `text_secondary`、版块说明 = `text_tertiary`）——既跨了调色板
（§12.3），又把三个不同含义压在同一个颜色轴上。重做后：生效 / 屏蔽 = 系统前景**两档 + 字重**
（`font_primary` + Medium / `font_secondary` + Regular），「已屏蔽」另给一枚**中性半透明底徽标**
（`sys.color.comp_background_secondary` + 7vp 圆角），面板的「关闭」入口从纯文字改为**有边界的胶囊**
（`dialogActionMaterial`）。状态因此由"结构 + 层级"表达，不再依赖颜色深浅。

### 12.9 HDS 材质宿主：内容区浮动控件的"非合规旁路"（第三条通路）

**问题**：右下角的发帖 / 刷新 / 回复按钮与页码指示器是"页面内容区的常驻控件"，属于 §0 门禁里
**没有任何 ArkUI 材质通道**的位置（本工程没有 `Navigation` / `Tabs`，`PanelNavBar` 还是自绘标题栏）。
官方技术支持在开发者问答里对这类位置的正式答复是"用 `backgroundEffect` 自绘近似"，即 §12.1 的磨砂玻璃。

**旁路**：**UI Design Kit 的 HDS 材质是另一套体系**。`HdsTabs` 的悬浮页签栏通过
`barFloatingStyle.systemMaterialEffect`（`hdsMaterial.MaterialType.ADAPTIVE` +
`MaterialLevel.ADAPTIVE`，`@since 6.1.0(23)`）由 **HDS 组件自身**渲染材质，`SystemCapability` 是
`UIDesign.HDSComponent.Core`，**不受 §0 那条针对 ArkUI `systemMaterial` 的生效范围约束**。
因此可以把一个**只放自定义内容的 `HdsTabs`** 当"材质宿主"：借用它的悬浮页签栏背板承载任意小控件。

接入封装：[`HdsMaterialHost.ets`](../entry/src/main/ets/common/components/HdsMaterialHost.ets)。

#### 非合规边界（必须知情）

- 这是**设计语义层面的挪用**：单页签 + 空 `TabContent` + 自定义 `tabBar`，既不是页签导航，
  也不承载页面内容，唯一目的是它的材质背板。**官方明确"不能通过改包名、反射或隐藏接口绕过 API 26 门禁"
  ——本方案没有做任何那类事，调用的是公开 HDS 接口**，但它确实不是官方推荐的用法。
- 官方给出的合规边界是：*"对于导航栏、标题栏、悬浮页签等标准场景，优先使用 UI Design Kit 官方沉浸光感
  组件；**仅对官方组件覆盖不了的品牌化小面积控件使用自定义近似实现**"*。本组件只用于**小面积浮动控件**，
  禁止拿它给列表、面板、大面积区域套材质。
- **不降级（工程约定不变）**：材质等级固定 `ADAPTIVE`（HDS 推荐值，不要写死 `EXQUISITE`），
  不为"设备不支持材质"写兜底分支——不支持时控件就是透明的，这是接受的结果。TV 上 HdsTabs 无效果。

#### 四条硬约束（踩坑清单）

1. **悬浮三条件缺一不可**：`barOverlap(true)` + `barPosition(BarPosition.End)` + `vertical(false)`。
   少任何一个，`barFloatingStyle` 都不生效。
2. **必须 `.clip(false)`**：HdsTabs 默认裁切自身内容，材质的边缘折射高光 / 阴影会被切掉，
   观感退化成一块生硬色块（公开方案实测结论）。
3. **`gradientMask.maskColor` 显式置 `Color.Transparent`**：HdsTabs 的底部渐变遮罩默认会画一层蒙版，
   叠在材质上等于给材质再盖一层内容色。
4. **宿主外层容器必须固定尺寸**：`HdsTabs` 会撑满父容器，直接把它放进页面 `Stack` 会铺满整屏。

#### 尺寸与落点

材质块（悬浮栏本体）在宿主内**水平居中、贴底**，所以宿主每边比材质块多出 `2 * contentPadding`：

```text
宿主宽 = barWidth  + 4 * contentPadding
宿主高 = barHeight + 4 * contentPadding
材质块左右边距 = 2 * contentPadding，底边距 = 2 * contentPadding + barBottomMargin
```

`contentPadding` **默认 0**：材质块与宿主逐像素重合，调用点沿用原来的落点与间距（不必为"多出来的余量"
重算 padding），光效靠 `.clip(false)` 溢出宿主边界。只有真机上确认光效被父容器裁掉时才调大它，
并**同步修正调用点外边距**（按上式）。

#### 接入点与改造记录

| 调用点 | 材质块尺寸 | 交互 |
| --- | --- | --- |
| `TopicListPanel.FloatingActions` 发帖 / 刷新 | 44×44 | `onTap`（宿主绑定 `onTabBarClick`） |
| `ThreadPanel.BottomBar` 回复按钮 | 40×40 | 同上 |
| `ThreadPanel.BottomBar` 页码指示器 | `pageBarWidth()` × 40 | **不传 `onTap`**：块内页码格与「到」各自持有 `onClick` / `bindPopup` |
| `PanelNavBar.iconPod` 返回 / 主右侧 / 次右侧按钮 | `TITLE_POD_SIZE`（36×36） | **一律不传 `onTap`**：内容节点持有 `onClick` / `bindMenu`（与迁移前的自绘底板逐条等价） |

三条实现约定：

- **`barWidth` 必须是显式值**——HDS 悬浮栏不能像自绘玻璃那样由内容撑开。页码指示器宽度按内容结构分档
  （`ThreadPanel.pageBarWidth()`：两格 / 两格+到 / 三格+到），分档只随**总页数**变化，翻页本身不改宽度，
  避免材质块频繁重排（§9.5 的参数稳定约束）。「到」格也给显式宽度，否则分档要依赖文字度量。
- **内容宽度分两种情况，别互相套用**。
  - **两端分布型内容**（页码指示器）：必须用**显式数值宽度**（= `barWidth`）+
    `.justifyContent(FlexAlign.SpaceBetween)` + 两端 `padding`。写成 `width('100%')` 时宽度会跟着
    HDS 页签项走、整条内容随页签项的对齐方式偏移——**真机现象**：页码条里「1」左边空一大块、
    「到」右侧贴死边界，分布明显不均。铺满之后首尾各离边 `PAGE_BAR_PAD`、中间间隙均分，与父级
    怎么对齐无关。
  - **单个居中元素**（标题栏图标按钮、回复按钮）：反过来要写 **`'100%'`**（宽高都跟随 HDS 内容
    区），元素居中即与材质块同心。此时若写显式尺寸（`TITLE_POD_SIZE` 见方），图标会整体偏下——
    原因与实测见下文"标题栏按钮"第 2 条。
- **`onTap` 与内容子元素的 `onClick` 只能二选一**：宿主把 `onTap` 绑在 `onTabBarClick` 上，
  内容的子元素再写 `onClick` 会**双触发**。单动作按钮用 `onTap`；页码指示器这种块内多热区的，
  不传 `onTap`，由子元素自己处理。
- **交互归属的两种写法都成立，按"要不要 HDS 点击反馈"选**：内容不挂交互、由宿主 `onTap` 承担
  （拿到 HDS 页签项的点击反馈，见上表前两行）；或**一律不传宿主 `onTap`**、由内容节点持有
  `onClick` / `bindMenu`（`PanelNavBar.iconPod` 选这条：与迁移前逐条等价，无障碍焦点与菜单锚点
  都留在原来的节点语义上，代价是没有 HDS 的点击反馈）。**两种不能混用**——宿主 `onTap` 与
  子元素 `onClick` 同时存在即双触发。
- **自定义组件的尾随闭包后不能跟属性链**：`HdsMaterialHost({...}) { ... }.margin(...)` 会报
  `Declaration or statement expected`（`ThreadPanel` 因此把页码条与回复按钮的 8vp 间距从
  `.margin` 改成 `Row({ space: 8 })`）。内置组件（`Row` / `Column`）不受此限。
- **材质块内的定位点要用 `offset`，不能用 `position`**：页码条"当前页"数字下的「•」原本是
  `.position({ x: '50%', y: 22 })`——`position` 是相对父容器左上角的**绝对坐标**，只在原来那个
  固定 28vp 高的数字格里成立；数字格改成铺满内容区（`height('100%')`）之后，绝对坐标把点顶到了
  材质块下边界上（**真机现象**：数字看着居中偏下、「•」压在组件边界）。改成
  `.offset({ y: PAGE_BAR_DOT_OFFSET })` 后，偏移量相对的是**元素自身的居中落点**，容器怎么变都
  跟着数字走。这是 HDS 材质宿主特有的坑：内容是别人（HDS 悬浮栏）在排布，任何"假设容器尺寸"的
  绝对坐标都会失配。

#### 验证状态

DevEco 编译通过（`BUILD SUCCESSFUL`），**真机已确认材质生效**。真机截图逐像素实测得到的事实：

- 材质块高度与 `barHeight` 一致（40vp ≈ 104px，密度 2.575），页码条与回复按钮两个材质块**等高且底边对齐**；
- 同一面板里两个宿主的**内容垂直行为不同**：回复按钮的图标严格居中（中心 = 材质块中心），
  而页码条的**数字内容天生偏低约 2.5vp**（数字墨迹中心比材质块中心低 6.5px）——即 **HDS 悬浮栏的
  内容区并不与材质块同心**。处置是给页码条内容加 `PAGE_BAR_CONTENT_OFFSET_Y = -3` 的垂直补偿
  （`offset`，只影响绘制，不影响布局），并把「•」定位点的 `offset` 定为 **10vp**——它的下限是
  9.5vp：数字字形底边在内容中心 +7.5vp、点字形顶边在 `offset − 2`，小于这个值点会**压在数字上**
  （真机现象：文字与定位点重叠）。
- 材质块内的定位点、数字格高度等**任何"假设容器尺寸"的写法都已清掉**：格子用 `height('100%')`、
  定位点用 `offset`。

仍未验证：页码格点击与「到」气泡锚点在材质块内的实际表现、深浅色、左右手镜像、以及单个页面多个
`HdsTabs` 实例的常驻功耗。原先的已知风险「HDS 材质无法套用本工程的 `material_surface_tint` 暖白
tint（与弹窗 / 半模态观感可能有色调差）」**已消除**：四条 ArkUI 系统材质通路（`dialogMaterial` /
`sheetMaterial` / `menuMaterial` / `popupMaterial`）已同步取消 `materialColor`，与 HDS 一样不赋色，
色调统一由系统深浅色自适应，同屏不再存在"应用 tint vs HDS 原色"的色调差。
剩余待查：`2in1` 上的设备材质能力。

#### 标题栏按钮（`PanelNavBar.iconPod`，第三批接入）

三颗按钮（返回 / 主右侧 / 次右侧）的背板从自绘 `fabMaterial` 换成同一个 HDS 材质宿主：标题栏是本
组件自绘的 `Stack` + `Row`，**不属于 §0 门禁里的 `Navigation` 标题栏**，ArkUI 侧拿不到材质，HDS
宿主是这里唯一的真材质通道。材质块尺寸 `TITLE_POD_SIZE`（36×36）。

**真机实测：两条踩坑与修法（都已落到代码）**

1. **36×36 材质块正常显示**——HDS 规范没有把它撑大或截断（既有已验证尺寸是 40 / 44，36 亦可用）。
2. **内容容器写显式高度 → 三颗图标整体偏下**。HDS 页签项的**内容区比 `barHeight` 矮**（页签项自带
   内边距），内容容器比内容区高时，超出部分按**顶部溢出**对齐，图标中心因此落在"内容区顶 + 半个
   容器高"上，整体偏低。**修法：内容容器写 `'100%'`**（高度 = HDS 内容区高度），图标用
   `alignContent(Center)` 居中于内容区 = 与材质块同心——也就是 `ThreadPanel` 回复按钮（真机实测
   "图标中心 = 材质块中心"）的原写法。**不要在 HDS 材质块里给内容容器写显式高度**；
   `constraintSize` 的 `minHeight` 兜底同理会把容器顶回显式高度，`PanelNavBar` 因此没有加它。
3. **图标被系统当成"可拖拽图片"**。`Image` 的 `draggable` 自 **API 10 起默认为 `true`**（本地 SDK
   `component/image.d.ts` 原文：值为 `true` 时**长按手势不生效**，事件被拖拽消费），真机现象是长按
   标题栏按钮出现系统拖拽预览。**修法：`.draggable(false)`**。注意通用属性 `draggable` 的默认值是
   `false`（`common.d.ts`）——这条只对 `Image` 是例外：**凡是"图标 + 点击"的按钮，图标都要显式写**。
   本轮把这类位置一并清理了：`PanelNavBar.iconPod`（三颗）、`ThreadPanel` 回复按钮、
   `TopicListPanel` 发帖 / 刷新、`WebViewPanel` 前进 / 后退、`SearchPanel` 返回按钮、
   `ImageViewer` 关闭按钮。**新增图标按钮时不要再漏**。
4. **角标不再用 `position` 绝对坐标**：容器高度改由 HDS 内容区决定之后，`position({ x: 19, y: 0 })`
   这类"假设容器尺寸"的写法必然失配（同类教训见上文"材质块内的定位点要用 `offset`"）。改法是把
   图标与角标收进一个 **18×18 的 `Stack({ alignContent: TopEnd })`**，角标锚在**图标的右上角**并用
   `offset(8, -9)` 平移——该偏移由旧落点换算而来（旧角标右上角在材质块坐标 `(35, 0)`，图标右上角在
   `(27, 9)`，差值即 `(8, -9)`）；角标宽度变化时右边缘固定，不会再顶出材质块。

**自动反色（`colorInvert`）在本通路不可用**：反色是 ArkUI `uiMaterial.ImmersiveMaterial` 的参数
（`@ohos.arkui.uiMaterial.d.ts`，`colorInvert?: boolean`，`@since 26.0.0`），HDS 的
`SystemMaterialParams` 只有 `materialType` / `materialLevel`——**HDS 材质没有公开的反色开关**。
所以标题栏三颗按钮**没有、也无法在这条通路上启用自动反色**，可读性完全靠 §12.3 的前景色规则
（图标色默认 `UIMaterialManager.adaptiveForeground` = `sys.color.font_primary`，跟随深浅色模式）
加材质块自身由系统自适应的色调。工程四条 ArkUI 背板通路（弹窗 / 半模态 / 菜单 / 气泡）同样**都没有**
开 `colorInvert`（§12.7）。

将来若把面板栈改造成 `Navigation` 标题栏（ArkUI 通路，才能写 `colorInvert`），反色的六个前提里
"白名单属性 `Image.fillColor` + 表 1 特殊系统资源（§6.3）"**对默认色已经满足**，但有三处不满足、
需要先改色：`NotificationPanel` 传的 `AppColors.primary` / `AppColors.textTertiary` 与
`BrowseHistoryPanel` 传的 `AppColors.destructive` 都是**应用资源**（不在表 1）；角标是硬编码
`Color.White`（表 1 的对应项是 `sys.color.font_on_primary`）。

**仍待核对**

- 角标是否被 HDS 页签项裁切（角标锚在图标右上角、向图标外溢出最多 9vp）；
- **绑菜单那颗的菜单落点**——锚点从"自绘 36×36 底板"换成了材质块**内部**的内容节点，必须重新确认
  菜单仍落在按钮下方、右边缘对齐。折叠屏多列路由下的锚点几何是
  `docs/UI_COMPONENT_MIGRATION.md` §7.7 踩过三轮的坑（当时连挂错三层才定位到"锚点必须是标题栏里
  那颗真实按钮"），这里等于把锚点又往里挪了一层；
- **无障碍朗读是否仍落到按钮上**——`accessibilityText` 挂在持有 `onClick` / `bindMenu` 的内容节点上
  （应与迁移前一致，因为交互节点没变）；
- **常驻多实例功耗**：标题栏把"单个页面多个 `HdsTabs` 实例"从 2 个抬到最多 3 个，且这三块是**常驻**
  的（18 处 `PanelNavBar` 调用点，随面板切换反复重建），上面那条"多实例常驻功耗未验证"因此升级为
  必须实测项。

`PanelNavBar` 的**栏位本体**仍不使用整块材质（保持透明，正文从下方穿越），本轮没有改动滚动渐变压暗层。

## 13. AI 和代码审查规则

当 AI 生成或审查沉浸光感代码时，按以下顺序判断：

1. 是否使用 API 26.0.0 的 `uiMaterial` 或 HDS API？低版本是否存在运行时分支？
2. 目标组件是否属于 Release 全页面例外清单？
3. 若不是例外，组件是否确实在 `Navigation/NavDestination` 标题栏或横向 `Tabs` 的 `BarPosition.End` 底部 TabBar？
4. 应用级配置是否位于 `entry` module？是否误用 `disable`？
5. 是否使用了 `uiMaterial.Material.empty` 明确关闭，而不是用 `undefined` 误关闭？
6. 是否使用 `ImmersiveMaterial` 的正确样式？（本工程取值以 §12.7 为准：弹窗 / 半模态 `THIN`、
   菜单 `THICK`、气泡 `REGULAR`。"弹窗用厚材质"是官方通用建议，本工程实测 `ULTRA_THICK` 是一块
   不透的白板，**已改用 `THIN`**——不要按通用建议把 `dialogMaterial` 改厚）
7. 是否在材质后设置了不透明背景、背景模糊、重复阴影或边框，导致效果被遮挡或冲突？
8. 是否给材质赋了色？（**本工程四条背板通路一律不传 `materialColor`**，见 §12.7——这里不是
   "检查透明度"，而是"不应赋色"；只有确需赋色的位置才检查颜色是否带透明度）
9. `colorInvert` 是否同时满足薄材质、高/中算力、特殊系统资源和白名单属性？
10. 是否把材质套在整页、大列表、视频、动图或持续动画上？是否有嵌套材质？
11. 是否把自定义弹窗写成普通 Stack 模拟而不是使用 Dialog/Popup/Menu 等官方接口？
12. 是否**没有**为"设备不支持材质"写降级分支？（程序约定：这类设备不在适配范围内，浮层背板一律
    完全让位给系统材质）

任何一个答案不确定，都不能把“调用成功”描述为“材质一定可见”。

## 14. 故障排查

| 现象 | 首先检查 |
| --- | --- |
| 代码无报错但完全没有材质 | Release 生效范围；组件是否在标题栏/底部 TabBar；应用是否为 `DISABLE`；设备是否支持材质 |
| Beta 有效果，Release 没效果 | 是否把普通组件放在了页面内容区；是否遗漏 `Navigation` 标题栏或 Tabs 三个悬浮条件 |
| 材质被纯色盖住 | 移除不透明 `backgroundColor`、`backgroundBlurStyle`、`backgroundEffect`；检查自绘内容层背景 |
| `colorInvert` 不工作 | `THIN`/`ULTRA_THIN`；高/中算力；系统强度；颜色是否是表 1 特殊资源；属性是否在白名单 |
| 黑字黑底或白字白底 | 检查是否硬编码颜色或误用 `ohos_id_color_*`；改为 `sys.color.font_*`/`icon_*` |
| `materialColor` 后变纯色 | 颜色不透明；改用带 Alpha 的颜色（**本工程四条背板通路不赋色，此症状不会出现**） |
| 自定义 `shadow` 不生效 | `applyShadow` 默认是 `true`；需要自定义阴影时设为 `false` |
| 材质边框颜色像周围背景 | 这是薄材质折射（`THIN` / `ULTRA_THIN` 尤其明显，官方给的解法之一就是赋色）；**本工程背板一律不赋色**，只能换更厚的档位、或加强遮罩对比 |
| Dialog/Toast 默认没有材质 | 是否主动设置了背景、模糊或阴影；`DEFAULT` 模式只有无冲突样式时才默认启用 |
| 低端设备效果明显不同 | 设备使用 `SMOOTH` 降级；`style` 和 `colorInvert` 本来就可能不生效，属于系统自适应 |
| 运行旧系统崩溃或样式异常 | `ImmersiveMaterial`/`systemMaterial` 是否按 `deviceInfo.sdkApiVersion` 做了低版本分支 |
| 页面卡顿或耗电高 | 材质面积过大、嵌套、叠加动态内容、弹窗过大、反色子树过大或参数频繁变更 |

## 15. 发布前检查清单

- [ ] `targetSdkVersion`/`targetAPIVersion` 与 API 26 适配策略一致。
- [ ] `module.json5` 的材质 metadata 只配置在 `entry` module。
- [ ] 已按 Release 生效范围逐个检查 `systemMaterial` 调用点。
- [ ] 普通组件材质全部位于有效标题栏或底部 TabBar 区域。
- [ ] 走 HDS 材质宿主（§12.9）的位置只有**小面积常驻控件**，没有列表 / 面板 / 大面积区域；材质块尺寸是显式值、内容与材质块同尺寸、宿主 `onTap` 与内容子元素交互**没有同时存在**。
- [ ] `PanelNavBar` 标题栏按钮的真机核对已完成：材质块尺寸是否被 HDS 规范接受、图标是否与材质块同心、绑菜单那颗的菜单落点、无障碍朗读；常驻多实例功耗已实测（§12.9"标题栏按钮"）。
- [ ] 弹窗使用官方弹窗接口和 options，不使用普通 Stack 冒充弹窗。
- [ ] `Tabs` 同时满足 `barPosition: End`、横向、`barOverlap(true)`。
- [ ] 材质节点没有不透明背景、重复模糊、重复阴影和嵌套材质。
- [ ] 材质赋色检查：本工程四条背板通路一律不赋色（§12.7）；若确需赋色，颜色必须带透明度。
- [ ] `colorInvert` 使用 `THIN`/`ULTRA_THIN` 与官方特殊系统资源。
- [ ] 低算力、不支持材质设备仍然可读、可操作。
- [ ] 低版本运行时将 `systemMaterial` 设置为 `undefined`。
- [ ] 已在高、中、低算力设备和深浅色模式验证，不能只在开发机验证。
- [ ] 已验证动态内容、长列表、大弹窗的 GPU 与帧率表现。

## 16. 官方资料

- [空间化沉浸光感最佳实践](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-spatiality-immersive)
- [API 26 Release：针对所有应用的变更](https://developer.huawei.com/consumer/cn/doc/harmonyos-releases/changelogs-for-all-apps-7003#section126372211)
- [沉浸光感简介](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-overview)
- [开启沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-enable)
- [组件适配沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-component-adaptation)
- [沉浸式系统材质视效](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-common-capability)
- [沉浸光感功耗优化](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-constraints)
- [沉浸光感兼容性适配](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-compatibility)
- [沉浸光感常见问题](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sense-faq)
- [沉浸光感典型场景](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-immersive-light-sample)
- [ArkUI `uiMaterial` API 参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-uimaterial)
- [HDS `hdsMaterial` API 参考](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/api/ui-design-hdsmaterial)
