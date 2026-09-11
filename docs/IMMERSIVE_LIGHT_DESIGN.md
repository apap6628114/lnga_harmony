# HarmonyOS API 26 沉浸光感与新材质完整指南

> 本文是面向 AI、ArkTS 开发者和本工程维护者的沉浸光感知识库。
>
> 适用范围：HarmonyOS API 26.0.0 Release，ArkUI 声明式开发，以及 UI Design Kit（HDS）沉浸光感。
>
> 官方文档核对时间：2026-09-05。华为官方页面可能继续修订；遇到本文与 SDK 实际行为不一致时，应以当前 SDK API 参考和变更说明为准。

> **本工程当前状态（API 26 Release 迁移已完成）**：Release 收紧生效范围后，本工程页面内容区的
> 自绘沉浸光感材质全部静默失效（组件背景透明、材质消失）。现已整体迁移到**系统磨砂玻璃**方案：
> 不再有任何 `systemMaterial` 调用点，玻璃层由 `backgroundBlurStyle` + 半透明填充 + 高光描边 +
> 柔和投影自绘，不受 Release 生效范围门禁约束。落地契约见第 12 节；本文其余章节保留为沉浸光感
> 契约与踩坑记录，仅在需要重新评估系统材质时参考。

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
| `materialColor` | `undefined` | 给材质滤镜再混合一层纯色；必须使用带透明度的颜色，纯不透明色会遮挡材质滤镜；低算力设备将其作为背景色 |
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

自动反色用于高透明材质背景下的文字、图标可读性。它不是通用的“把所有颜色取反”，而是系统在材质子树中扫描特定属性接口和特定资源值，按底层背景计算前景色。

### 6.1 必须同时满足的条件

1. `style` 是 `THIN` 或 `ULTRA_THIN`。
2. 设备是高算力或中算力；低算力设备设置 `colorInvert` 不产生视觉差异。
3. 系统沉浸光感强度和材质透明度达到系统触发阈值；材质越薄、系统强度越强，越容易触发。
4. 颜色通过支持的属性接口设置。
5. 颜色值是官方 API 参考表 1 中的特殊系统资源。
6. 应用级状态不是 `DISABLE`。

### 6.2 颜色属性白名单

官方 API 参考列出的可反色属性包括：

- `Text.fontColor`、`Button.fontColor`、`SymbolGlyph.fontColor`。
- `Image.fillColor`。
- `Search.placeholderColor`、`Search.fontColor`、`searchIcon` 图标色、`cancelButton` 图标色、`caretStyle` 光标色、`searchButton` 按钮色。
- `TabContent.tabBar` 使用 `BottomTabBarStyle` 时的文字和图标颜色。
- `Chip.prefixIcon.fillColor`、`Chip.suffixIcon.fillColor`、`Chip.label.fontColor`。
- `ChipGroup.itemStyle.fontColor`。
- `TextArea.fontColor`、`TextArea.placeholderColor`、`TextInput.fontColor`、`TextInput.placeholderColor`。
- `SegmentButton.fontColor`。
- `Swiper.fontColor`。

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
**页面内容区的玻璃视觉已全部由系统磨砂玻璃自绘承担**（见 12.1），沉浸光感只保留应用级开关（见 12.4）。

### 12.1 磨砂玻璃工厂（替代材质工厂）

材质统一收敛在 [`UIMaterialManager.ets`](../entry/src/main/ets/common/managers/UIMaterialManager.ets)：
成员是 `GlassModifier implements AttributeModifier<CommonAttribute>` 的只读单例，调用点用
`.attributeModifier(UIMaterialManager.xxx)` 绑定，**不再写 `.systemMaterial(...)`**。

| 工厂材质 | 用途 | 磨砂参数（模糊半径 / 饱和度 / 填充不透明度） |
| --- | --- | --- |
| `fabMaterial` | 浮动圆形/胶囊按钮 | 36vp、1.4、55% + 极淡整圈描边 + 下沉投影（不设渐变） |
| `surfaceMaterial` | 面板、浮层、弹窗 | 72vp、1.5、42% + 描边 + 强投影 |
| `barMaterial` | 标题栏、消息页栏位 | 56vp、1.4、42% + 描边，不投影 |
| `neutralActionMaterial` | 弹窗内的中性次要操作 | 32vp、1.4、32% + 细描边，不投影 |
| `inputMaterial` | 输入框 | 24vp、1.3、32% + 低透明描边，不投影 |
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

### 12.4 应用级材质开关

`entry/src/main/module.json5` 保留：

```json5
{
  "name": "ohos.arkui.UIMaterial.state",
  "value": "enable"
}
```

该开关只影响系统官方清单组件（Navigation 标题栏、Select、Toggle、Slider、菜单等）的默认材质，
与本工程自绘磨砂玻璃无关；改玻璃参数不需要动它。若将来发现官方组件默认材质与磨砂玻璃视觉冲突，
再评估是否改为 `disable`。

### 12.5 主操作按钮

主操作按钮不默认接入玻璃材质。确认、保存、退出、发送等承担明确操作语义的按钮使用实底主题色和高对比文字；需要中性浮动反馈的操作才使用 `neutralActionMaterial`。

原因：主题色玻璃叠在面板材质上容易出现背景贴边、前景对比不稳定和黑字/浅棕底等问题；实底按钮在低算力和不同背景上更可靠。

### 12.6 SaveButton

`SaveButton` 属于安全组件，其样式受到系统合法性校验约束，不支持 `systemMaterial`、材质阴影或模糊。保持系统要求的高对比固定背托，不要尝试给安全按钮接入沉浸式材质。

## 13. AI 和代码审查规则

当 AI 生成或审查沉浸光感代码时，按以下顺序判断：

1. 是否使用 API 26.0.0 的 `uiMaterial` 或 HDS API？低版本是否存在运行时分支？
2. 目标组件是否属于 Release 全页面例外清单？
3. 若不是例外，组件是否确实在 `Navigation/NavDestination` 标题栏或横向 `Tabs` 的 `BarPosition.End` 底部 TabBar？
4. 应用级配置是否位于 `entry` module？是否误用 `disable`？
5. 是否使用了 `uiMaterial.Material.empty` 明确关闭，而不是用 `undefined` 误关闭？
6. 是否使用 `ImmersiveMaterial` 的正确样式：浮动控件用薄材质，弹窗用厚材质？
7. 是否在材质后设置了不透明背景、背景模糊、重复阴影或边框，导致效果被遮挡或冲突？
8. `materialColor` 是否带透明度？
9. `colorInvert` 是否同时满足薄材质、高/中算力、特殊系统资源和白名单属性？
10. 是否把材质套在整页、大列表、视频、动图或持续动画上？是否有嵌套材质？
11. 是否把自定义弹窗写成普通 Stack 模拟而不是使用 Dialog/Popup/Menu 等官方接口？
12. 是否需要在设备不支持材质时仍保持可读的普通颜色和背景？

任何一个答案不确定，都不能把“调用成功”描述为“材质一定可见”。

## 14. 故障排查

| 现象 | 首先检查 |
| --- | --- |
| 代码无报错但完全没有材质 | Release 生效范围；组件是否在标题栏/底部 TabBar；应用是否为 `DISABLE`；设备是否支持材质 |
| Beta 有效果，Release 没效果 | 是否把普通组件放在了页面内容区；是否遗漏 `Navigation` 标题栏或 Tabs 三个悬浮条件 |
| 材质被纯色盖住 | 移除不透明 `backgroundColor`、`backgroundBlurStyle`、`backgroundEffect`；检查自绘内容层背景 |
| `colorInvert` 不工作 | `THIN`/`ULTRA_THIN`；高/中算力；系统强度；颜色是否是表 1 特殊资源；属性是否在白名单 |
| 黑字黑底或白字白底 | 检查是否硬编码颜色或误用 `ohos_id_color_*`；改为 `sys.color.font_*`/`icon_*` |
| `materialColor` 后变纯色 | 颜色不透明；改用带 Alpha 的颜色 |
| 自定义 `shadow` 不生效 | `applyShadow` 默认是 `true`；需要自定义阴影时设为 `false` |
| 材质边框颜色像周围背景 | 这是薄材质折射；换厚样式或使用半透明 `materialColor` |
| Dialog/Toast 默认没有材质 | 是否主动设置了背景、模糊或阴影；`DEFAULT` 模式只有无冲突样式时才默认启用 |
| 低端设备效果明显不同 | 设备使用 `SMOOTH` 降级；`style` 和 `colorInvert` 本来就可能不生效，属于系统自适应 |
| 运行旧系统崩溃或样式异常 | `ImmersiveMaterial`/`systemMaterial` 是否按 `deviceInfo.sdkApiVersion` 做了低版本分支 |
| 页面卡顿或耗电高 | 材质面积过大、嵌套、叠加动态内容、弹窗过大、反色子树过大或参数频繁变更 |

## 15. 发布前检查清单

- [ ] `targetSdkVersion`/`targetAPIVersion` 与 API 26 适配策略一致。
- [ ] `module.json5` 的材质 metadata 只配置在 `entry` module。
- [ ] 已按 Release 生效范围逐个检查 `systemMaterial` 调用点。
- [ ] 普通组件材质全部位于有效标题栏或底部 TabBar 区域。
- [ ] 弹窗使用官方弹窗接口和 options，不使用普通 Stack 冒充弹窗。
- [ ] `Tabs` 同时满足 `barPosition: End`、横向、`barOverlap(true)`。
- [ ] 材质节点没有不透明背景、重复模糊、重复阴影和嵌套材质。
- [ ] `materialColor` 带透明度。
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
