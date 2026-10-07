---
name: nga-local-rule-feature
description: 在帖子页新增「本地规则」类功能时使用（抓全帖 → 本地判定 → 生成一份派生的本地存档），如「智能去水」。覆盖派生存档的 archiveId 寻址模型、本地判定引擎的保守性红线、同形状合成页的字段要求、可选的「会话级 AI 规则」追加通道，以及从菜单项到设置页的完整接线点。不负责 AI 场景本身的注册（见 nga-ai-scenario），不负责 NGA 取数通道（见 nga-data-fetch）。
---

# 本地规则类功能（派生存档）

与 `nga-ai-scenario` 的分工：那条链路产出的是**提示词**（交给模型），这条产出的是一份
**本地存档**（纯本地判定，不调模型、不耗额度、同一输入结果可预期）。

```text
「更多」菜单项 → 确认弹窗（规模/耗时/口径/产出位置，可选 AI 追加规则）
  → service 逐页抓全帖 → 本地规则判定每层 → 保留原始行
  → 重组成「与在线响应同形状」的页 → savedThreadStore.save(archiveId = tid + '-w')
  → 全局进度发布器（可能跑几十分钟，必须跨页可见）
  → 「保存的帖子」列表里与原帖存档并列
```

## 1. 派生存档的寻址模型（最容易做错的一层）

原帖离线存档与派生存档共用同一个 `tid`，**唯一键必须是 `archiveId`**：

| | 原帖存档 | 派生存档（去水版） |
|---|---|---|
| `archiveId` | `tid` | `tid + '-w'` |
| `derivedFrom` | `''` | `tid` |
| 列表标记 | 无 | 描边标签（如「去水」） |

改动点（缺一处就会出现"打开的是另一份存档"）：

- `store/SavedThreadStore.ets`：`isValidArchiveId`（正则 `^[0-9]{1,16}(-w)?$`）；
  导出 `DERIVED_ARCHIVE_SUFFIX` / `baseArchiveIdOf` / `derivedArchiveIdOf` /
  `hasDerivedArchive`；`getByTid` 内部走 `getByArchiveId(baseArchiveIdOf(tid))`，
  这样**存量调用点无需改动**；`getRawPage` / `save` / `remove` / `importContent` 一律按 `archiveId`。
- `store/RouterStore.ets`：`Screen.archiveId` 字段 + `Screen.savedThread(archiveId, tid, page)`。
- `pages/ActivityRouter.ets`：`ThreadPanel({ … archiveId: entry.screen.archiveId })` 透传。
- `pages/ThreadPanel.ets`：`@Prop archiveId` + `getArchiveId()`（空串回退 `tid`，兼容旧书签）。
- 列表页：`ForEach` 键、打开、删除**全部**用 `archiveId`。

同一帖反复执行会**覆盖**上一份派生存档（键相同），列表不会堆叠——这是刻意的。

## 2. 判定引擎的保守性红线

派生是**破坏性**操作（产出物里不再有被删楼层），宁可漏删不可误删：

- **「是否含信息字符」用反向白名单**：只枚举明确的标点/符号/emoji 码点区段，
  **未知字符一律算有信息**。正向白名单（只保留汉字/字母/数字）会把泰文、西里尔文、
  扩展汉字这些没枚举到的文字整段判成"纯标点"删掉。新增区段只能让判定**更保守**。
- **词表整条等值，不用包含匹配**：`顶`/`好`/`眼` 这类是常用字，包含匹配会误伤
  「顶楼的图挂了」。等值只容忍**一个**尾部语气符（`了~!！。的呀啊`）。
- **短闲聊必须有长度上限**（本项目 12 字）：这条约束才是"感谢分享"判水、
  「感谢分享，不过第 3 张图的参数好像写反了」保留的分界线。
- **硬豁免永远第一期**：主楼 / 带附件 / 带楼中楼或热评 / 正文含富内容标记
  （`[img` `[url` `[code` `[table` `[tid=` `[attach` …，用**开标记**匹配，NGA 标签普遍带参数）。
  **豁免表里不要放 `[quote`**——见下一条。
- **引用块整段剥离（`stripQuoteBlocks`），且必须排在剥标记之前**：判定只看作者自写的部分。
  三条语义缺一不可：①引用不计入长度（否则「引用长文 + 顶」永远凑得够字数躲过长度规则）；
  ②引用里的图片/外链不豁免本层；③**只带引用、自己没写字的楼层保留**（那是作者刻意带出的
  上下文），但「引用 + mark」的自写部分照删。
  顺序不能反：`stripMarkup` 会把 `[quote]` 当短标签吃掉，之后再也认不出引用边界。
  边界异常（开标记被截断 / 没有配对闭标记）按「到文末都算引用」处理——宁可少判一层水，
  不可把别人的话当作者的正文。孤立闭标记不处理（会让长度偏长，方向安全）。
- **判定对象是「剥引用 + 剥标记 + 去空白」的紧凑文本**；语义字段（`lou` / `attachs` / `comments`）
  取自解析后的 `PostInfo`，不要靠正文文本猜。
- 自定义规则在等级词表**之后**取并集（用户显式配置优先于预设）；多条长度规则取**最宽松**一条。
- **数值型规则的文案必须带单位**（本项目长度类写「字数不超过」，输入框 placeholder 写
  「不超过多少字」）：不写单位，用户会按字节或字符理解（汉字与 emoji 计数完全不同），
  阈值就填不准。类型短名与「含值的完整描述」用两个函数（`xxxTypeLabel` / `xxxTypeDetail`），
  别在短名里塞 `…` 占位符——它会在列表页被原样渲染出来。

判定本体放 `service/WaterFilterEngine.ets`：**纯函数、无 IO、无状态**，便于单测与复用。

## 3. 会话级 AI 规则（可选追加，不落盘）

本地字符匹配盖不到「这帖特有的水法」（追更帖满屏「催更」、资源帖满屏「求个网盘」）。
可以加一条**可选**的「按主题让 AI 列规则」通道，但必须守住下面的边界——判定本体
不能因此变成调模型。

**为什么必须会话级（最容易做错）**：这类规则是按**当前帖子主题**生成的，写进持久化的
全局规则就会在别的帖子上乱删（「催更」在小说帖里合理，在技术帖里是误伤）。因此：

- 规则由弹窗构件通过 `onAiStateChange` **回传**给发起页，存在页内字段里；发起任务时与
  持久化的自定义规则**合并**后传给 service。**不要**调 `addXxxRule` 落盘。
- **每次打开弹窗都要清空页内字段**：弹窗是新建实例，页内字段才是真源；不清就会把上一个
  条目的规则静默带进这一次。
- UI 必须明说「只用于本次，不会写入你的自定义规则」。

**提示词契约与解析器必须同时改（三处同步）**：默认 system prompt（场景配置）、
解析器、设计文档。要点：

- Prompt 里写死输出格式（本项目是 `{"rules":[{"type":"contain","value":"…"}]}`，
  `type` ∈ `contain` / `equals` / `max-length`，最多 12 条），并要求**不要写通用灌水词**
  （已由内置词表覆盖）、**严禁单字 contain**（「图」「求」「顶」「好」会命中大量正经回复）。
  针对「引用 + 短评」的楼层要求用 `contain` 而不是 `max-length`（引用不计入长度）。
- 注入数据只要最小必要项（标题 + 主楼正文纯文本，截断到 ~1200 字）。正文取不到时
  **只给标题**——比不生成规则更保守，不会因此失败。
- **模型输出是不可信输入**，解析必须防御性、**不抛异常**、逐条丢弃坏数据：定位第一个 `{`
  到最后一个 `}` 截 JSON 子串（别匹配 ```json 前缀）→ 逐条校验类型与值 → 剥包裹引号 +
  压空白 → 拒单字 contain → 去重 → 限条数。解析为空按「AI 认为不需要额外规则」如实显示。
- 复用**唯一** AI 通道（`chatCompleteWithActiveAiStream`），不展示流式增量，
  **不得**另开 HTTP 调用路径；取消令牌在弹窗 `aboutToDisappear` 里 `cancel()`。

**门禁**：本地判定不依赖 AI，所以「AI 未配置」不能拦开始（只提示原因）；
但**「AI 规则正在生成中」必须拦开始**——规则还没拿到就开始，用户以为用了 AI 规则、
实际一条没用上，比不用 AI 更糟。

场景注册（元数据 / 默认 prompt / 注入字段说明 / 设置页卡片 / 图标）见 `nga-ai-scenario`。

## 4. 合成页必须与在线响应同形状

存档的取舍单位是**原始行 raw row**（判定用解析后的 `PostInfo`，保留时把行原样塞进新页），
这样派生版和原帖走完全相同的渲染管线。合成页要求：

- 字段齐备：`data.__R` / `__U` / `__F` / `__T` / `__ROWS` / `__R__ROWS_PAGE` / `__PAGE`。
- `__ROWS` 报**全帖保留楼层总数**（不是本页行数）——与在线响应语义一致，
  也让 `parseThreadData` 推出的总页数吻合。
- **`__U` 必须按页裁剪**：只带本页引用到的作者。整表复制到每页 → 1000 页存档膨胀上百 MB。
- **承载 `__GROUPS` 的那一条每页都要带**：`fillThreadResult` 取第一个带 `__GROUPS` 的条目
  建「组 ID → 组名」映射，不带的话除首页外楼层会退化成数字组 ID。
- **不累积整页 raw**：每页判定完只留通过的原始行。

## 5. 全帖抓取的约定

- **总页数自己探测**，不要直接用调用方给的页数：调用方在「只看楼主」等筛选态下的页数是
  **筛选后**的值，会漏抓大半个帖子。请求末页（`page=e`）读 `__ROWS` / `__R__ROWS_PAGE` 换算；
  探测失败才回退到入参提示值。
- 页间节流（本项目 250ms）、单页失败**只跳过并计数**（上千页里偶发失败是常态）。
- 按 `pid` 去重（相邻页偶有重复尾楼）。
- **安全阀**（保留层数 / 输出字符数上限）：触顶立即停止扫描并落盘，如实汇报"仅覆盖前 N 页"。
  OOM 被杀比一份标注清楚的局部结果更糟。
- **黑名单与关键词屏蔽不参与取舍**（传空）：屏蔽是阅读时偏好，不该改变存档内容。
- **进度走全局发布器**（`common/media/*Progress.ets` + `MainPage` 上挂指示组件）：
  只要任务可能跑几分钟且用户会离开页面，就必须跨页可见。参考 `savedThreadProgress`。
- **长时任务**：退后台不冻结需要 dataTransfer 型 `backgroundTaskManager` 长时任务
  （`module.json5` 的 `backgroundModes` 加 `"dataTransfer"`，`KEEP_BACKGROUND_RUNNING` 已声明），
  控制器结构照抄 `TtsBackgroundTaskController`（串行化 + `lifecycleGeneration` 防误伤）；
  申请不到时在进度提示里**如实告知**"请保持应用在前台"。

## 6. 接线点清单

| 层 | 文件 | 要改什么 |
| --- | --- | --- |
| 入口 | `pages/ThreadPanel.ets` | `moreMenuItems()` **非存档分支**插菜单项；存档分支不出现（对产物再加工没有语义） |
| 门禁 | 同上 | 与同类功能对齐，但**不校验 AI 可用性**（本地规则不需要模型）；门禁要留在入口分支之外独立成立。若加了会话级 AI 规则，再补一条「AI 正在生成规则」的拦截 |
| 确认弹窗 | `common/dialogs/*Dialogs.ets` | 官方 `CustomContentDialog` 的 contentBuilder 构件；`@Prop` + 回调，**禁 `@Link`**（contentBuilder 是 `@BuilderParam`，`$变量` 解析不到源状态）。**必须写出产出物存档在哪个列表**（如「我的 → 收藏、保存与跟踪帖子 → 保存的帖子」）：用户点完「开始」就离开弹窗了，不说就找不到产出物。内容多（如 AI 规则清单）要包 `Scroll` + `constraintSize({maxHeight})`，弹窗自身不滚动 |
| 服务 | `service/*Service.ets` | 抓取 + 判定 + 重组 + 落盘；模块级单例，不随组件销毁结束 |
| AI 规则服务（可选） | `service/*AiRulesService.ets` | 提示词组装（纯函数，便于单测）+ 防御性解析（纯函数）+ 走唯一 AI 通道发起；**不落盘**，只回传发起页 |
| 设置域 | `store/settings/domain/*Settings.ets` | 挂进 `SettingsState` 与 `SettingsStore` 门面；**变更时 bump `AppStorage` 版本号** |
| 设置页 | `pages/*Panel.ets` + `pages/SettingsPanel.ets` | 新增面板 + 入口行；角标用 `@StorageProp('xxxVersion')` + `@Watch` 驱动（两个 Screen 并存，`aboutToAppear` 不会再触发） |
| 路由 | `store/RouterStore.ets` | `ScreenType` 联合类型、静态工厂、`getTitle()` 分支 |
| 路由渲染 | `pages/ActivityRouter.ets` | `else if (entry.screen.type === 'xxx')` 分支 + import |
| 图标 | `resources/base/media/settings_*.svg` | `fill="#000000"` 交给 `.fillColor()`；设置页图标色进 `SettingsIconColors` |
| 列表数据源 | `common/datasource/LazyDataSource.ets` | 加一个 `BaseLazyDataSource<T>` 子类并加进末尾的 `export {}` |
| Ability | `entryability/EntryAbility.ets` | 需要 context 或长时任务时：`onCreate` 注入、`onDestroy` 释放 |

文档：新增 `docs/<FEATURE>_DESIGN.md`（口径表 / 判定时序 / 存储模型 / 工程约束 / 故障模式 /
验收项 / 维护规则），并在 `docs/THREAD_DESIGN.md` 的 §1.3 文件表、§6.x 菜单项清单、
§7 故障、§9.2 验收、§10 维护规则各补一行。若加了会话级 AI 规则，设计文档里要单开一节
写清「只对本次生效」的理由、提示词契约与防御性解析表。

## 7. 验证门禁

1. `node scripts/check-eol.mjs`（仅 `oh-package-lock.json5` 是历史遗留违规，别顺手"修"）。
2. `node tools/bbcode-ts/scripts/sync-to-ets.mjs --dry` 输出「0 修改」。
3. 编译见 `.dsh/skills/harmonyos-build-deploy`（**必须导出 `JAVA_HOME` 且把 `jbr\bin` 加进 PATH**，
   否则 `PackageHap` 报 `00308018 / spawn java ENOENT`；ArkTS 编译通过 ≠ 打包成功）。
4. 编译只证明能出 HAP。判定口径（误删/漏删两侧）与存档寻址必须在设备上逐项走一遍：
   误删一个正经回复比漏删十个 mark 严重得多。至少覆盖：
   - 误删侧：含词表常用字但语义正常的短回复（「顶楼的图挂了」）保留。
   - 引用侧：「引用长文 + 顶一下」仍被剔除、只引用不写字的楼层保留。
   - 存档侧：派生版与原帖在列表里并列、都能独立打开与删除；重复执行只留一份。
   - 若加了 AI 规则：关掉再开弹窗清单为空、设置里没多出规则（没落盘）、生成中点开始被拦、
     未配置 AI 时去水仍可正常开始。
