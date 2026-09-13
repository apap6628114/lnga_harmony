import { hdsMaterial, HdsTabs } from '@kit.UIDesignKit'

/**
 * HDS 材质宿主：给**页面内容区的常驻浮动控件**提供系统沉浸光感材质。
 *
 * ## 为什么需要它
 *
 * API 26 Release 收紧了沉浸光感（`systemMaterial`）的生效范围：
 *
 * - 弹窗类组件 / 弹窗类接口（PromptAction、Popup、菜单、半模态）+ `Slider` / `Toggle` / `Select`
 *   → 页面内全部区域生效；
 * - **其他 ArkUI 组件 → 仅在 `Navigation` / `NavDestination` 标题栏，或横向 `Tabs` 中
 *   `barPosition: BarPosition.End` 的底部 TabBar 中生效**。
 *
 * 本工程没有 `Navigation` / `Tabs`，`PanelNavBar` 还是自绘标题栏，所以内容区的右下角浮动按钮、
 * 页码指示器**没有任何 ArkUI 合规材质通道**——官方 FAQ 对此的答复就是"改用 `backgroundEffect`
 * 自绘近似"（也就是本工程此前的 `GlassModifier` 磨砂玻璃）。
 *
 * 但 **UI Design Kit 的 HDS 材质是另一套体系**：`HdsTabs` 的 `barFloatingStyle.systemMaterialEffect`
 * 由 HDS 组件自身渲染材质（`SystemCapability.UIDesign.HDSComponent.Core`，API 23 起），
 * 不受上面那条 ArkUI 生效范围门禁约束。于是可以**把一个只放自定义内容的 `HdsTabs` 当成"材质宿主"**，
 * 借用它的悬浮页签栏背板来承载任意浮动控件。
 *
 * ## 非合规声明（务必知情）
 *
 * 这是**设计语义层面的挪用**，不是官方推荐用法：
 * 一个只含单个空 `TabContent` 的 `HdsTabs`，既不是页签导航，也不承载页面内容，唯一目的是它的材质背板。
 * 请只用于"官方组件覆盖不了的小面积控件"（这也是官方技术支持在开发者问答里给出的边界）；
 * 不要用它给列表、面板、大面积区域套材质。官方明确表示不能通过改包名 / 反射 / 隐藏接口绕过
 * API 26 门禁——本组件**没有**做任何那类事，它调用的是公开的 HDS 接口。
 *
 * ## 不降级（工程约定）
 *
 * 与 `UIMaterialManager` 的约定一致：**不为不支持材质的设备写降级分支**。设备不支持时材质不生效，
 * 控件就是透明的——这是接受的结果。HDS 材质等级固定用 `ADAPTIVE`，由系统按设备算力自适应
 * （HDS 官方推荐值，不要写死 `EXQUISITE`）。
 *
 * ## 四条硬约束（踩坑清单）
 *
 * 1. **悬浮三条件缺一不可**：`barOverlap(true)` + `barPosition(BarPosition.End)` + `vertical(false)`。
 *    少任何一个，`barFloatingStyle` 都不生效（官方文档与公开实测一致）。
 * 2. **必须 `.clip(false)`**。HdsTabs 默认裁切自身内容，材质边缘的折射高光 / 阴影会被切掉，
 *    观感是一块生硬的色块（公开方案实测：加 `.clip(false)` 后才是正常的 HdsTabs 效果）。
 * 3. **`gradientMask.maskColor` 必须显式置透明**。HdsTabs 的底部渐变遮罩默认会画一层蒙版，
 *    叠在材质上等于给材质又盖一层内容色。
 * 4. **宿主外层容器必须固定尺寸**：`HdsTabs` 会撑满父容器，直接把悬浮栏放进页面 `Stack`
 *    会让它铺满整屏。所以外面包一层固定尺寸的 `Row`，把 `HdsTabs` 关在里面。
 *
 * ## 尺寸与落点（`contentPadding` 的代价）
 *
 * 材质块（悬浮栏本体）在宿主内**水平居中、贴底**，因此宿主每边都比材质块多出
 * `2 * contentPadding` 的透明余量：
 *
 * ```text
 * 宿主宽 = barWidth  + 4 * contentPadding
 * 宿主高 = barHeight + 4 * contentPadding
 * 材质块左边距 = 2 * contentPadding，右边距 = 2 * contentPadding
 * 材质块底边距 = 2 * contentPadding + barBottomMargin
 * ```
 *
 * **默认 `contentPadding = 0`**：材质块与宿主逐像素重合，调用点沿用原来的落点与间距
 * （不需要为了"多出来的余量"重算 padding），光效靠上面的 `.clip(false)` 溢出宿主边界。
 * 只有真机上发现光效确实被父容器裁掉时，才把它调大，并**同步修正调用点的外边距**（见上式）。
 */
@Component
export struct HdsMaterialHost {
  /** 材质块宽度（原自绘玻璃控件的宽度）。 */
  @Prop barWidth: number = 40

  /** 材质块高度（原自绘玻璃控件的高度）。 */
  @Prop barHeight: number = 40

  /**
   * 材质块四周的透明余量（vp）。默认 0，理由见文件头"尺寸与落点"。
   * 调大后材质块会相对宿主内缩，**必须同步修正调用点的外边距**。
   */
  @Prop contentPadding: number = 0

  /** 材质块与宿主底边的距离（vp）。默认 0，材质块贴宿主底边。 */
  @Prop barBottomMargin: number = 0

  /**
   * 材质块内容。用尾随闭包传入（**不要**写成 `content: this.myBuilder` 的方法引用形式：
   * 方法引用会让 builder 内的 `this` 指向宿主组件而不是页面组件，页面状态会读到 `undefined`）。
   */
  @BuilderParam content: () => void

  /**
   * 整块点击回调。绑定在 `onTabBarClick` 上——材质块本身就是"页签"，点它即页签点击。
   *
   * 注意：**内容的子元素不要再写自己的 `onClick`**（会与这里双触发）。确实需要块内多个热区时
   * （页码指示器就是这种），不传本回调，改由内容里的子元素各自处理点击。
   */
  onTap?: () => void

  build() {
    Row() {
      HdsTabs() {
        // 唯一页签，内容完全由调用方决定；空 TabContent 不渲染任何东西，
        // 它存在只是 HdsTabs 的结构要求。
        TabContent()
          .tabBar(this.content())
      }
      .width('100%')
      .height('100%')
      // 关掉自身裁切，让材质折射高光 / 阴影能溢出宿主边界（见文件头约束 2）
      .clip(false)
      .barWidth(this.barWidth)
      .barHeight(this.barHeight)
      // 悬浮页签栏三条件（见文件头约束 1）
      .barOverlap(true)
      .barPosition(BarPosition.End)
      .vertical(false)
      // 只有一个页签，不需要滑动手势
      .scrollable(false)
      .barFloatingStyle({
        barBottomMargin: this.barBottomMargin,
        // 关掉 HdsTabs 的底部渐变遮罩（见文件头约束 3）
        gradientMask: { maskColor: Color.Transparent },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .onTabBarClick((_index: number) => {
        if (this.onTap !== undefined) {
          this.onTap()
        }
      })
    }
    .width(this.barWidth + this.contentPadding * 4)
    .height(this.barHeight + this.contentPadding * 4)
    .padding(this.contentPadding)
  }
}
