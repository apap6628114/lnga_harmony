# 沉浸光感（Immersive Light）设计约束

本文记录本工程在 API 26（HarmonyOS 6.x）接入沉浸光感（沉浸式系统材质 + 自动反色）的设计契约与故障定位依据，重点是**自动反色（colorInvert）的生效条件**。文中的"必须/不得"表示当前实现依赖的不变量；官方行为说明均可在文末的文档链中指回。

工程目标 SDK 见 [`build-profile.json5`](../build-profile.json5)，`targetSdkVersion` 与 `compatibleSdkVersion` 均为 `26.0.0`，应用级材质开关已在 [`module.json5`](../entry/src/main/module.json5) 中配置为 `enable`。

## 1. 材质的三层开关体系

沉浸光感最终是否生效由三层共同决定，任何一层不满足都可能出现"代码写了但没效果"：

| 层 | 配置位置 | 取值 | 说明 |
| --- | --- | --- | --- |
| 系统设置 | 用户在系统设置中选择"沉浸光感"强度 | 强 / 均衡 / 弱 | 决定材质模糊、高光、阴影的丰富度；**也是自动反色的触发阈值影响因素** |
| 设备算力 | 厂商在系统配置文件中分档 | 高 / 中 / 低 | `style`、`colorInvert` 仅在高/中算力设备生效；低算力降级为背景色/边框/阴影 |
| 应用级状态 | `module.json5` 的 metadata | `default` / `enable` / `disable` | `disable` 时所有组件级材质（含主动设置）全部失效 |

### 1.1 应用级开关

```json5
{
  "module": {
    "type": "entry",
    "metadata": [
      { "name": "ohos.arkui.UIMaterial.state", "value": "enable" }
    ]
  }
}
```

- 必须写在 **entry 类型**的 module 中才生效。
- `targetAPIVersion` 必须不低于 26.0.0。
- 状态只影响"默认开启"的组件范围（Dialog、Toast、Select、Toggle、Chip 等），**不影响**开发者主动通过 `systemMaterial` 设置的材质（`disable` 模式除外）。
- 运行时可用 `uiMaterial.getMaterialInfo()` 读取 `MaterialInfo.state`（`DEFAULT`/`ENABLE`/`DISABLE`）辅助诊断。

## 2. 组件级接入与材质参数

通用属性 `systemMaterial(material)` 设置材质，参数收敛在 [`UIMaterialManager`](../entry/src/main/ets/common/managers/UIMaterialManager.ets)：

| 参数 | 取值 | 设计要点 |
| --- | --- | --- |
| `style` | `ULTRA_THIN` / `THIN` / `REGULAR` / `THICK` / `ULTRA_THICK` | 厚度与通透度；**自动反色只认 THIN 与 ULTRA_THIN** |
| `materialColor` | 带透明度的 `ResourceColor` | 为材质滤镜再混合一层纯色；**必须带透明度**，纯不透明色会完全遮挡材质滤镜 |
| `colorInvert` | `boolean` | 子树前景自动反色，见第 3 节 |
| `applyShadow` | `boolean`（默认 true） | 材质自带阴影。true 时材质阴影**优先于**通用 `shadow` 属性并使其失效；false 时通用 `shadow` 才生效 |
| `interactive` | `boolean` | 按压形变 |
| `lightEffect` | `LightEffectOptions \| null` | 触点光感流光，`color` 默认 `Color.White` |

- 材质对象是纯配置对象，可跨组件共享复用；不得在运行期频繁替换材质对象或改动其子树结构。
- 组件背景必须保持 `Color.Transparent`（或不设置），由材质层承载表现；不透明背景色会盖在材质层之上使材质不可见。

## 3. 自动反色 colorInvert（本项目最大踩坑点）

### 3.1 生效条件（缺一不可）

1. **材质样式为 `THIN` 或 `ULTRA_THIN`**（`REGULAR`/`THICK`/`ULTRA_THICK` 不进入反色路径）。
2. **系统沉浸光感强度**：材质越薄、强度越强，越容易满足反色触发阈值（弱档可能完全不触发）。
3. **设备为高/中算力档**（低算力下 `colorInvert` 参数不产生效果）。
4. **颜色必须使用"特殊资源值"**（见 3.2），**不得使用硬编码色值**（`Color.White`、`'#FFFFFFFF'` 等不触发反色）。
5. **颜色所在的属性接口必须在生效白名单内**（见 3.3）。
6. 应用级材质状态不是 `disable`。

### 3.2 特殊资源值表（colorInvert 只认这些系统资源）

> 来源：官方 arkts-apis-uimaterial 的 `colorInvert` 参数说明"表1 特殊资源值对应的深浅色值"。**旧命名体系的 `sys.color.ohos_id_color_*`（如 `ohos_id_color_foreground`）不在表内，设置后不会反色**——本工程曾因此出现"黑字黑底"。

| 特殊资源值 | 浅色 | 深色 |
| --- | --- | --- |
| `$r('sys.color.brand')` | #FF0A59F7 | #FF317AF7 |
| `$r('sys.color.brand_font')` | #FF0A59F7 | #FF5291FF |
| `$r('sys.color.warning')` | #FFE84026 | #FFD94838 |
| `$r('sys.color.font_on_primary')` | #FFFFFFFF | #FFFFFFFF |
| `$r('sys.color.font_primary')` | #E5000000 | #E5FFFFFF |
| `$r('sys.color.font_secondary')` | #99000000 | #99FFFFFF |
| `$r('sys.color.font_tertiary')` | #66000000 | #66FFFFFF |
| `$r('sys.color.font_fourth')` | #33000000 | #33FFFFFF |
| `$r('sys.color.font_emphasize')` | #FF0A59F7 | #FF5291FF |
| `$r('sys.color.icon_primary')` | #E5000000 | #E5FFFFFF |
| `$r('sys.color.icon_secondary')` | #99000000 | #99FFFFFF |
| `$r('sys.color.icon_tertiary')` | #66000000 | #66FFFFFF |
| `$r('sys.color.icon_fourth')` | #33000000 | #33FFFFFF |
| `$r('sys.color.icon_emphasize')` | #FF0A59F7 | #FF5291FF |
| `$r('sys.color.icon_sub_emphasize')` | #660A59F7 | #665291FF |
| `$r('sys.color.comp_background_primary_contrary')` | #FFFFFFFF | #FFE5E5E5 |
| `$r('sys.color.comp_background_primary_contrary_secondary')` | #FFFFFFFF | #FF666666 |
| `$r('sys.color.comp_background_secondary')` | #19000000 | #19FFFFFF |
| `$r('sys.color.comp_background_tertiary')` | #0C000000 | #19FFFFFF |
| `$r('sys.color.comp_background_emphasize')` | #FF0A59F7 | #FF317AF7 |
| `$r('sys.color.comp_emphasize_secondary')` | #330A59F7 | #33317AF7 |
| `$r('sys.color.comp_emphasize_tertiary')` | #190A59F7 | #19317AF7 |
| `$r('sys.color.comp_divider')` | #33000000 | #33FFFFFF |
| `$r('sys.color.interactive_hover')` | #0C000000 | #19FFFFFF |
| `$r('sys.color.interactive_focus')` | #FF0A59F7 | #FF317AF7 |
| `$r('sys.color.interactive_pressed')` | #19000000 | #26FFFFFF |

工程约定：`UIMaterialManager.adaptiveForeground` / `adaptiveSecondaryForeground` / `inputForeground` 分别绑定 `font_primary` / `font_secondary` / `font_primary`，与旧 `ohos_id_color_*` 系列取值相同、视觉不变，但可参与反色。**任何新的"材质前景色"必须从表 1 选取，不得引入表外资源。**

### 3.3 生效属性白名单

自动反色仅对以下属性接口设置特殊资源时生效：

- `Text.fontColor`、`Button.fontColor`、`SymbolGlyph.fontColor`
- `Image.fillColor`（本工程关闭按钮反色即走此通道，`icon_close.svg` 为可染色 SVG）
- `Search`：`placeholderColor`、`fontColor`、`searchIcon`、`cancelButton` 图标色、`caretStyle` 光标色、`searchButton` 按钮色
- `TabContent.tabBar` 使用 `BottomTabBarStyle` 时的文本与图标色
- `Chip`：`prefixIcon`/`suffixIcon` 的 `fillColor`、`label.fontColor`；`ChipGroup.itemStyle.fontColor`
- `TextArea` / `TextInput`：`fontColor`、`placeholderColor`
- `SegmentButton.fontColor`、`Swiper.fontColor`

## 4. 属性冲突与性能约束

- **`systemMaterial` 必须放在其他样式属性（背景色、边框、阴影等）之后**设置，否则材质效果优先级与预期不符。
- **不得**同时设置背景色（非透明）、`backgroundBlurStyle`、通用 `shadow`、边框与材质：材质自带滤镜与阴影已覆盖这些表现，叠加上去会造成冲突与重复绘制。
- 需要自定义阴影时：`applyShadow: false` + 通用 `shadow` 二选一组合，两套不得同时生效。
- **不得**在同一子树嵌套/层叠多个材质；材质区域避免大面积、持续动画、视频/动图背景（逐帧重采样开销大）。
- 自动反色范围应尽量小（子树越大、参与反色的元素越多，计算量越高）。

## 5. 项目实践记录

### 5.1 材质工厂

[`UIMaterialManager.ets`](../entry/src/main/ets/common/managers/UIMaterialManager.ets) 按用途收敛材质单例：`fabMaterial`（ULTRA_THIN 玻璃球）、`surfaceMaterial`（REGULAR 面板）、`barMaterial`（栏位）、`buttonMaterial`（THIN 主题琥珀）、`neutralActionMaterial`（THIN 中性操作）、`inputMaterial`（THIN 输入）、`closeButtonMaterial`（ULTRA_THIN + colorInvert，严格对齐官方反色示例）。

### 5.2 图片查看器案例（自动反色的验证闭环）

- 需求：关闭按钮在明/暗图片上都必须可见，分享按钮在黑底上文字可读。
- 失败路径 1：`ohos_id_color_foreground`（表外资源）→ 反色不触发，浅色主题下解析为黑 → 黑字黑底。
- 失败路径 2：材质组件叠加 `shadow`/`border`、`systemMaterial` 未放最后 → 属性冲突，材质表现异常。
- 成功方案（[`ImageViewer.ets`](../entry/src/main/ets/common/components/ImageViewer.ets)）：
  - 关闭按钮：`Image.fillColor($r('sys.color.font_primary'))` + `Stack` 透明背景 + `closeButtonMaterial`（ULTRA_THIN + colorInvert），`systemMaterial` 为最后一个样式属性，不叠 shadow/border。
  - 分享按钮：`Button.fontColor(adaptiveForeground)` + `neutralActionMaterial`（THIN + colorInvert），同样满足反色条件。

### 5.3 安全控件（SaveButton）与材质

`SaveButton` 继承 `SecurityComponentMethod`，样式面被严格限制为"背托 + 图标 + 文字"三层（`fontColor`/`iconColor`/`backgroundColor`/`border*`/`padding`/`textIconSpace` 等），**不支持 `systemMaterial` / 阴影 / 模糊**，且样式需通过系统合法性校验（字号过小、颜色与背景相近、过于透明等会导致授权失败）。保存按钮保持固定高对比样式（白字 + 固定背托色）是 API 26 下的正确姿势，不得尝试为其接入沉浸材质。

## 6. 故障排查清单

| 现象 | 排查项 |
| --- | --- |
| 组件看不到材质效果 | 应用级状态是否 `disable`；组件是否设置不透明背景色；设备算力/系统强度档位 |
| 材质有但无反色 | 样式是否 THIN/ULTRA_THIN；颜色是否表 1 特殊资源；属性是否在白名单；是否硬编码色值 |
| 黑字黑底 / 白字白底 | 先按上行排查，重点检查资源是否误用 `ohos_id_color_*` |
| 自定义 shadow 不生效 | `applyShadow` 是否为 true（材质阴影优先于通用 shadow） |
| 背景色/边框显示异常 | `systemMaterial` 是否放在其他样式属性之后；是否与背景色/边框/阴影共存 |

## 7. 官方文档链

- 沉浸光感开发指导：`arkts-immersive-light-sense`
- 沉浸光感 FAQ：`arkts-immersive-light-sense-faq`
- `uiMaterial` API（含 colorInvert 参数说明与表 1）：`arkts-apis-uimaterial`
- `systemMaterial` 通用属性：`ts-universal-attributes-image-effect`
