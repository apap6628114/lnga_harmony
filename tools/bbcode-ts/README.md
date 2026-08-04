# tools/bbcode-ts — BBCode 解析器 TS 镜像验证工具

## 动机

ArkTS 是 TypeScript 的严格子集。本工具把 HarmonyOS 工程里的 **BBCode 解析器与渲染器**
（纯逻辑、零平台 API 依赖）镜像为 TS，在 Node 环境用**真实楼层样本**批量验证解析正确性，
修复后再**机械同步**回 ArkTS 源码。解决 DevEco/Hypium 编译链慢、无法快速迭代的问题。

## 目录结构

```
tools/bbcode-ts/
  src/                          # TS 镜像（真源）：与 entry/src/main/ets 同构
    parser/bbcode/              #   词法/块级/内联解析 + block-handlers
    parser/_shared/             #   实体解码、附件 URL
    model/BBCodeNode.ts         #   节点模型
    common/components/bbcode/   #   渲染逻辑（bbcode-utils）
    common/typography/          #   排版常量
    common/utils/Utils.ts       #   bbNodesToPlainText 等
  tests/
    helpers.ts                  #   样本加载、序列化、子序列断言
    invariants.test.ts          #   文本零丢失 + 结构断言 + 边角样例
    snapshot.test.ts            #   快照回归
  samples/
    samples.lst                 #   样本清单（每行一个文件名，自动纳入测试）
    demo.txt                    #   真实楼层样本（NGA API content 字段）
    demo.snapshot.json          #   解析树快照基线（npm run snapshot 生成）
  scripts/
    sync-to-ets.mjs             #   TS 镜像 → entry/src/main/ets 单向同步
    gen-snapshot.ts             #   重新生成快照基线
```

## 使用

```bash
npm install        # 首次
npm test           # 编译 + 全部测试（不变量 + 快照回归）
npm run snapshot   # 生成/更新快照基线（审查 git diff 后提交）
npm run sync       # 把验证过的镜像写回 entry/src/main/ets（.ts → .ets）
```

## 工作流（单一真源）

1. **改解析/渲染逻辑只改 `src/` 下的 TS 镜像**（必须继续遵守 ArkTS 子集，
   见 `.claude/rules/ArkTS-syntax.md`，否则同步回 .ets 后无法编译）
2. `npm test` 在 Node 环境快速验证（毫秒级）
3. `npm run sync` 机械同步回 `entry/src/main/ets/`
4. DevEco 编译 + `entry/src/test/BBCodeUnit.test.ets`（Hypium）做最终门禁

> ⚠️ 禁止直接修改 `entry/src/main/ets` 下被镜像的 21 个文件——下一次 `npm run sync`
> 会用镜像覆盖它们。确需直接改 .ets 时，改完立即反向同步回镜像。

## 不变量设计

- **文本零丢失**：期望纯文本（预处理 → 删媒体内容 → 剥标签 → 解码实体）必须是
  解析树全部 TEXT 拼接的子序列。抓"漏解释/文字被吞"。
- **结构断言**：真实样本的表格数、行数、合并单元格、折叠块、关键短语、链接。
- **快照回归**：demo.txt 解析树 JSON 与基线逐字节对比，防意外行为漂移。
- **边角样例**：20 个手写用例覆盖标签嵌套/容错/属性/特殊字符。

## 已知设计行为（非 bug，断言已对齐）

- `bbNodesToPlainText` 会剥除每个样式子树边缘空白（纯文本提取语义）——零丢失断言
  使用 `concatTextNodes`（逐字保留）而非它。

## 修复记录

- **2026-08-05 表格分隔换行保留**：`parseTableContent` / `parseTableRowCells` 的容错
  跳过逻辑原先静默丢弃 `[tr]/[td]` 之间的杂散内容（含 `<br/>` 预处理后的换行，demo.txt
  约 720 处），现保留为行级/表级 TEXT 节点。UI 渲染零影响（`RenderTable` 只消费
  TABLE_ROW/TABLE_CELL），AI 总结与 TTS 朗读的表格文本获得单元格分隔。
  快照基线随之更新（`npm run snapshot`）。
