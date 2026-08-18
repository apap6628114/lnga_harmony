---
name: arkui-refresh
description: 诊断与修复 ArkUI/ArkTS 组件的「UI 不刷新 / 状态不生效」问题。覆盖 V1 状态管理（@State/@Prop/@Link/@Observed/@ObjectLink/@StorageProp/@Watch）的观测规则、ForEach/LazyForEach 键值驱动刷新机制、IDataSource 数据源通知语义，以及本项目已验证的修复模式（LazyForEach 键值含内容版本号、@StorageProp 版本号驱动全页刷新、派生数据缓存失效）。用户报告“UI 不刷新”“界面不更新”“改了数据没反应”“编辑后内容没变”“LazyForEach/ForEach 不刷新”“@State/@Prop 不生效”等刷新类问题时使用。不执行 UI 自动化与设备测试（见 harmonyos-test / harmonyos-build-deploy），不替代 harmonyos-docs 的 API 检索。
---

# ArkUI 组件刷新机制与「不刷新」排查

把「UI 不刷新」当作**断链排查**，不做玄学。刷新 = 数据变化被框架**观测到** + 组件被**判定需要更新**，两个环节都可能断链。先对照规则定位断链点，再套修复模板，禁止盲改装饰器。

## 1. V1 状态管理观测规则速查

先对表，再猜。观测不到 = 改了也不刷新。

| 数据形态 | 可观测的修改 | 不可观测（典型断链） |
|---|---|---|
| `@State` 简单类型（number/string/boolean） | 整体赋值 | — |
| `@State` class 对象 | 对象整体赋值；**第一层属性**赋值 | 嵌套对象深层字段（对象里套对象） |
| `@State` 数组 | 整体重新赋值；push/pop/splice 等数组方法；**替换数组元素** `arr[i] = newItem` | **数组元素内部属性赋值** `arr[i].field = x`（除非元素是 @Observed 类） |
| `@State` Map/Set | `Map.set/delete`、`Set.add/delete`、`clear` 等自身方法 | 直接改 key 对应对象内部字段（需 @Observed） |
| `@Prop` | 父组件重渲染时重新赋值（初始化深拷贝）；更新依赖父组件重渲染，与传参引用是否相同无关 | 父组件没重渲染（如 LazyForEach key 不变）则不更新；@Prop 内修改不影响父 |
| `@Link` | 任一端修改，两端同步刷新 | — |
| `@Observed` + `@ObjectLink` | @Observed 类实例**所有属性**（嵌套 @Observed 可递归） | 非 @Observed 类 |
| `@StorageProp` / `@StorageLink` | AppStorage 键值整体更新（`setOrCreate`/`set`） | 直接改存储值**对象内部**字段（需 @Observed） |
| `@Watch` | 被装饰状态变量变化后回调 | 不直接驱动 UI，只作副作用 |
| 普通成员变量 | — | **完全不参与观测**，build 里读它只是快照 |

四条最重要的实战结论（官方文档依据见 §8）：

1. **@State 数组「替换元素」`arr[i] = newItem` 可观测**，但**「元素内部属性赋值」`arr[i].field = x` 不可观测**（后者需元素为 @Observed 类 + @ObjectLink 消费，或整体换新数组）。
2. **深层字段要 @Observed + @ObjectLink**，@State 只看得见第一层。
3. **@Prop 更新依赖父组件重渲染**：LazyForEach 下 key 不变 → 父组件不重渲染 → @Prop 收不到新值（即使同一对象内部已变）。
4. **组件内部如果缓存了派生数据，缓存失效时机要自己管**（aboutToAppear 只跑一次）。

## 2. ForEach / LazyForEach 键值驱动机制（本项目最高频的坑）

LazyForEach 的组件更新**完全由键值（key）驱动**，`onDataChange` 通知本身不保证刷新：

> - 「修改数据源中的一个数据项**若不影响其生成的键值，则对应组件不会被更新**，否则对应组件就会被重建更新」—— LazyForEach API 参考（keyGenerator 参数说明）
> - 「为了高性能渲染，使用 `onDataChange` 更新 UI 时，**需要生成不同于原来的键值来触发组件刷新**」—— LazyForEach 开发者指南（使用限制）
> - 「键值没有变化的数据项会使用原先的子组件，键值发生变化的会重建子组件」—— `onDataReloaded` 说明

自定义 keyGenerator 时，**内容变化必须能改变 key**；只放稳定标识（如 pid）意味着内容更新永远不刷新。

通知方法选型（数据源先改数据、后通知，顺序不可反）：

| 变更 | 通知方法 | 说明 |
|---|---|---|
| 整体重载 | `onDataReloaded()` | 键值没变的复用、变的重建 |
| 追加/插入 | `onDataAdd(index)` | 新 index → 新 key → 新建组件，**必然刷新** |
| 删除 | `onDataDelete(index)` | 先删数据再通知 |
| 单条内容变化 | `onDataChange(index)` | **仅当该 index 的 key 变化才刷新**（见上文） |
| 移动 | `onDataMove(from, to)` | 移动前后 key 须不变 |
| 批量（API 12+） | `onDatasetChange(ops)` | `DataChangeOperation.CHANGE` 可显式携带新 `key`；不能与其他通知方法混用 |

未提供 keyGenerator 时默认键值与 index 相关（不同版本实现有差异，FAQ 与 API 参考表述不一致），**不要依赖默认行为**；内容更新场景必须显式提供含内容指纹的 key。

## 3. 高频场景诊断表

| 现象 | 根因 | 修复 |
|---|---|---|
| 改对象字段 UI 不动 | 对象非 @State，或 @State 一层观测够不到深层 | 换 @Observed + @ObjectLink（模板 T1） |
| 改数组元素**内部属性** UI 不动 | 元素内部属性赋值 `arr[i].field = x` 不可观测（替换元素 `arr[i] = newItem` 本身可观测） | 元素类加 @Observed + @ObjectLink，或整体换新数组 / 数据源通知（模板 T2） |
| **LazyForEach 内容更新 UI 不动** | **key 只含稳定标识，内容变化 key 不变 → onDataChange 无效** | **key 引入内容版本号（模板 T3，本项目已落地）** |
| 子组件 @Prop 收不到新值 | 父组件没重渲染（key 不变）或传的是同引用 | 先解决父组件重渲染；@Prop 无法替代观测链路 |
| 回调/异步里改了数据没反应 | 改的是非状态变量，或改完没走任何通知 | 确认修改走 @State 赋值或数据源通知 |
| 派生数据缓存不更新（aboutToAppear 算一次） | 缓存无失效时机 | 在组件重建/数据更新时重建缓存（模板 T6） |
| 跨页面/跨组件广播不刷新 | 无共享状态通道 | @StorageProp 版本号驱动（模板 T5，本项目黑名单案例） |

## 4. 诊断流程

1. **锁定数据源**：UI 读的值来自哪？状态变量 / `DataSource.getData(index)` / AppStorage / 普通成员？普通成员直接判死（无观测）。
2. **锁定修改点**：改的是引用、第一层属性、深层字段，还是数组元素？对照 §1 表格找断链。
3. **LazyForEach 场景额外确认 key**：修改前后 key 变了吗？不变 → 必然不刷新（§2）。
4. **确认组件有没有重渲染**：临时在 build/aboutToAppear/@Watch 打日志，或诊断期临时把 keyGenerator 换成 `JSON.stringify(item)` 观察是否恢复刷新（仅诊断用，验证后还原）。
5. **套 §5 模板修复**，注意修复要落在「观测链」上，不是靠 `this.forceUpdate()` 之类绕过（ArkUI 无此 API，整体重建请走 `onDataReloaded`/状态替换）。
6. **验证**：纯逻辑断言走 Hypium；组件行为走模拟器/真机（§7）。

## 5. 修复模板（代码级）

**T1 深层字段不刷新 → @Observed + @ObjectLink**

```typescript
@Observed
export class Inner {
  value: string = ''
}
// 父持有 @State @Observed 对象数组/对象，子组件用 @ObjectLink 接收
// @ObjectLink 要求源对象是 @Observed 实例且经 @State/@ObjectLink 链传递
```

**T2 数组元素修改不刷新 → 整体替换引用**

```typescript
// 场景 A：@State 数组「元素内部属性赋值」不可观测（替换元素 arr[i] = newItem 可观测）：
//   稳妥做法是整体换新数组引用（元素属性变化也一并反映）：
const next: Item[] = []
for (let j = 0; j < this.list.length; j++) next.push(j === i ? newItem : this.list[j])
this.list = next
// 场景 B：数据源（LazyForEach/ForEach）场景走 updateAt → onDataChange，
//   但 key 不变则不刷新，必须配合内容版本号（见 T3）
```

**T3 LazyForEach 内容更新 → key 含内容版本号（本项目已验证）**

模型加本地版本号（非服务端字段）：

```typescript
export class PostInfo {
  pid: number = 0
  /** 本地渲染版本号：内容更新时递增，驱动 LazyForEach 键值变化重建该楼层 */
  uiRev: number = 0
  content: string = ''
}
```

keyGenerator 与更新点：

```typescript
// keyGenerator：平时内容不变 key 稳定（滚动复用不受影响），内容更新后 key 变化触发重建
}, (post: PostInfo) => String(post.pid) + '_' + String(post.uiRev))

// 更新点（乐观更新）：
const p: PostInfo = this.mgr.posts[idx]
p.uiRev++          // 必须先/同时递增版本号
p.content = newText
this.postsDataSource.updateAt(idx, p)
```

要点：内容相同必须保持版本号不变（避免无谓重建）；每次「内容变化」的写入点都要递增；服务端合并时按「新旧内容是否相同」决定版本号继承或 +1。

**T4 更新单条又不想整体重建窗口 → 只重建该楼层**

配合 T3：`onDataChange(index)` + key 变化 = 该 index 楼层原位重建，不卸载 List、不 replaceAll、滚动锚点由 `List.maintainVisibleContentPosition(true)` 兜底。禁止为刷单个楼层去整体 `replaceAll`/`notifyReload`（破坏窗口与滚动）。

**T5 跨组件广播刷新 → @StorageProp 版本号（本项目黑名单案例）**

```typescript
@StorageProp('blacklistVersion') @Watch('onChange') blacklistVersion: number = 0
// 任意位置（注意 ArkUI 全局对象是大写 AppStorage）：
AppStorage.setOrCreate('blacklistVersion', v + 1)
// 项目已封装 bumpAppStorageVersion(key)，见 entry/src/main/ets/common/utils/AppStorageVersion.ets
// 所有订阅组件重渲染，内部读取实时状态（如 isBlacklisted(uid)），零数据拷贝
```

适用：大量组件需要同一份事实的最新值、且数据本身存 Store/AppStorage 的广播场景。

**T6 派生数据缓存失效 → 生命周期对齐数据源**

在 `aboutToAppear` 里一次性计算的分组/解析结果（如 BBCode 节点分组）只在组件重建时重新计算。若组件会被复用而数据变化，必须在 `aboutToReuse` 或数据通知回调中重建缓存，否则显示旧内容。

## 6. 本项目已验证案例（对照）

| 案例 | 断链点 | 修复落点 |
|---|---|---|
| 编辑楼层正文不刷新（用户报告） | LazyForEach key 只含 pid，内容变化 key 不变 → onDataChange 无效 | `PostInfo.uiRev` + keyGenerator `pid_uiRev` + `ThreadPaginationManager.mergePage` 内容变化递增版本号 + `protectedContent` 防 read.php 旧缓存回退。见 `entry/src/main/ets/model/PostInfo.ets`、`entry/src/main/ets/pages/ThreadPanel.ets`、`entry/src/main/ets/common/managers/ThreadPaginationManager.ets`、`docs/THREAD_DESIGN.md` §4.1/§7 |
| 新回复楼层必然刷新（对照组） | — | `onDataAdd` 新 key → 新建组件，天然刷新；与编辑路径对比可确认 key 是唯一变量 |
| 黑名单即时遮蔽（成功范例） | — | `@StorageProp('blacklistVersion')` 驱动 PostItem/BBCodeContentView 重渲染，不依赖 LazyForEach key。见 `entry/src/main/ets/common/components/PostItem.ets`、`entry/src/main/ets/pages/ThreadPanel.ets` |
| 投票分数不刷新（同源未修） | key 不变（uiRev 未随 score 递增） | 未处理：整楼重建代价大于两个数字的收益；如需修，给 score 单独走响应式状态或递增 uiRev |
| BBCodeContentView `cachedGroups` 派生缓存 | `aboutToAppear` 只算一次 | 当前靠「key 变化 → 组件重建 → 缓存重建」天然规避；若未来做 key 不变的内容刷新，必须先加缓存失效 |

## 7. 验证要求

- 纯逻辑修复（分页/合并/版本号语义）→ 写 Hypium 单测并运行（见 `harmonyos-test` skill），断言行为契约而非编译通过。
- 组件刷新行为（重建是否发生、滚动锚点、无闪烁）→ 模拟器/真机运行时验证（见 `harmonyos-build-deploy` skill）。
- 「编译成功」与「UI 已刷新」是两件事，禁止互相替代。

## 8. 官方文档依据

- LazyForEach 开发者指南（键值生成规则 / 数据更新 / 使用限制）：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-rendering-control-lazyforeach>
- LazyForEach API 参考（keyGenerator / onDataChange / onDataReloaded / onDatasetChange）：<https://developer.huawei.com/consumer/cn/doc/harmonyos-references/ts-rendering-control-lazyforeach>
- ForEach 循环渲染：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-rendering-control-foreach>
- @State / @Prop / @Link / @Observed 与 @ObjectLink / @StorageProp 状态管理（V1）：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-state>
- ForEach/LazyForEach 刷新原理 FAQ：<https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs/faqs-arkui-41>
- Repeat（官方推荐替代 LazyForEach 的循环渲染，基于状态管理监听数据源）：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-new-rendering-control-repeat>

## 9. 完成前检查清单

- [ ] 对照 §1 表格确认修改点落在可观测范围内（@State 一层 / @Observed 深 / 数组整体 / 数据源通知）
- [ ] LazyForEach 场景确认内容变化必然改变 key（§2/§5 T3）
- [ ] 修复未引入 `replaceAll`/`notifyReload` 整窗重建（§5 T4）
- [ ] 派生数据缓存有明确失效时机（§5 T6）
- [ ] 修改了分页/数据窗口语义时同步 `docs/THREAD_DESIGN.md` §4 并补单元测试（维护规则）
- [ ] 纯逻辑部分过 Hypium；组件行为已计划或完成运行时验证（§7）
