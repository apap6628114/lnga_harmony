# 统一数据集合导出/导入 — 调研报告

> 目标：为「统一数据集合导出/导入」服务提供设计输入。本文只读代码，不改 `entry/src` 下任何 `.ets`。
>
> 调研日期：2026-10-30。代码基线：当前工作区 HEAD（未提交改动未纳入）。
>
> 引用约定：
> - 工程代码用**仓库相对路径** + `:行号`（如 `entry/src/main/ets/store/SavedThreadStore.ets:334`）。
> - SDK 声明统一前缀 `sdk/default/openharmony/ets/api/`，实际根目录 `C:\Program Files\Huawei\DevEco Studio\sdk\default`（由 `$env:DEVECO_SDK_HOME` 推导，已实测存在）。
> - 无法从代码/SDK 确证的结论标 **【待确认】**。
>
> **并行工作提醒（重要）**：本报告写作期间，工作区已出现另一条并行线的未提交产出——
> `entry/src/main/ets/common/persistence/{PersistenceTypes,PersistenceCatalog,PersistenceMetaStore,StorageBackends}.ets`、
> `docs/PERSISTENCE_UNIFICATION_DESIGN.md`（其 **§6 已定稿导出/导入容器格式**）与
> `docs/research/PERSISTENCE_INVENTORY.md`，且 `common/infra/PreferencesStore.ets` 新增了
> `deleteKey/hasKey/getAll`。因此：
> - 本文 **§2/§3/§4 的现状调研**不受影响（读的是已合入的实现）；
> - 本文 **§5 设计输入已按该并行设计对齐**（magic `NGA_OH_BACKUP`、后缀 `.ngabackup`、域清单取
>   `PersistenceCatalog`），并额外列出**核查差异与待补点**（§5.2.3、§5.5、§7）供 Lead 决策；
> - 若并行设计继续演进，以 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` 为准，本文档提供的是"现有两条
>   链路的实现事实 + 可复用件 + 风险清单"。

---

## 0. 摘要（Top 结论）

1. **两条既有链路互不复用，但都建立在同一套"原子写 + 版本号刷新"模式上**：凭证链路是「AES-256-GCM + PBKDF2 加密容器」（`CredentialExportCrypto.ets`），离线存档链路是「明文 JSON + schemaVersion 严格相等」（`SavedThread.ets` / `SavedThreadStore.ets`）。统一服务应把两者拆成**容器层（加密封装）**与**域序列化层（各域自己的 schemaVersion）**两级。
2. **加解密实现有 3 个必须在统一服务里修掉的缺陷**：① 解密时直接信任文件里的 `iterations` 字段（无上下限，恶意文件可致 PBKDF2 长时间阻塞），见 `CredentialExportCrypto.ets:117`；② 导出写文件无 `try/finally`，写失败会泄漏 fd 且在系统选择器预创建的空文件里留下 0 字节残留，见 `SettingsPanel.ets:350-352`；③ 密码只做 `trim().length >= 8` 校验且**只输一次、无二次确认**，输错只能重新导出。
3. **picker 是免权限的系统 UI**：`module.json5` 只有 INTERNET/DETECT_GESTURE/GET_NETWORK_INFO/KEEP_BACKGROUND_RUNNING 四个权限（`module.json5:15-28`），文件读写全靠 `DocumentViewPicker` 返回的 URI 授权；`@ohos.file.picker.d.ts` 全文无 `@permission` 标注。统一导出**不需要新增权限**。
4. **本地数据几乎全部落在同一个 preferences 库**（`AppStore.ets:181` 的 `nga_app_store`），键为 `<域>_<uid>` 或固定键；仅"离线存档 / 草稿 / 草稿媒体"三处在 `filesDir` 下各自成目录。因此统一导出在实现上应做**域注册表**，每个域提供 `collect / apply / schemaVersion`，而不是逐个写死。
5. **当前最大的隐私面在"设置域"里**：`SettingsState.aiProfiles[].apiKey`（`SettingsState.ets:57-58` + `AiConfig.ets:73`）与 `aiSearchProfiles[].apiKey`（`AiSearchConfig.ets:31`）以**明文 JSON** 存在 `settings_<uid>` 中；AI 会话（`ai_sessions_<uid>`）含用户全部对话正文与工具摘要。统一导出若默认勾选这两域并选择明文导出，等于把第三方密钥与私人对话写到用户可见的公共目录。**建议默认排除 API Key，并对 AI 域默认不勾选 + 明文导出前二次确认**。⚠️ 并行落地的 `PersistenceCatalog` 目前是 `settings=INCLUDE`（含 AI 配置/密钥）、`ai_sessions=INCLUDE`（默认勾选），与本节建议**冲突**，已在 §5.2.3 D2/D3 列为待决策项。
6. **换机迁移目前没有可用通道**：`backup_config.json` 声明 `"allowToBackupRestore": true`，但 `EntryBackupAbility.onBackup/onRestore` 只打日志、无实现（`EntryBackupAbility.ets:6-16`）。统一导出/导入是当前唯一可靠的设备迁移路径，设计上应把它当"迁移工具"而非"备份工具"。

---

## 1. 调研边界、方法与权威源

### 1.1 范围

| 项 | 内容 |
| --- | --- |
| 已读工程代码 | `common/security/CredentialExportCrypto.ets`、`pages/SettingsPanel.ets`、`pages/LoginPage.ets`、`common/dialogs/Dialogs.ets`、`pages/FavoriteSavedPanel.ets`、`store/SavedThreadStore.ets`、`model/SavedThread.ets`、`service/api/AuthApi.ets`、`common/utils/FileUtils.ets`、`common/utils/KeyboardAppearanceUtils.ets`、`common/utils/AppStorageVersion.ets`、`common/utils/CodecUtils.ets`、`common/infra/{PreferencesStore,CacheEnvelopeStore,SerialQueue}.ets`、`common/feedback/ToastManager.ets`、各持久化 Store、`entrybackupability/EntryBackupAbility.ets` |
| 已查 SDK 声明 | `@ohos.file.picker.d.ts`、`@ohos.file.fs.d.ts`、`@ohos.security.cryptoFramework.d.ts`、`@ohos.file.fileuri.d.ts`、`module.json5`、`resources/base/profile/backup_config.json` |
| 跳过 | `@ohos.file.photoAccessHelper.d.ts`：现有两条导出链路均不涉及相册（`saveStillToAlbum` 属图片保存功能，与数据导出无关，且 `ImageViewer.ets:260-273` 才用到） |
| 全量 grep | `picker.` / `DocumentViewPicker` / `DocumentSaveOptions` / `fileIo.openSync` / `cryptoFramework` / `huks` / `getUriFromPath` / `share`（结果见 §2.0、附录 A.2） |

### 1.2 关键 grep 结论

- **`huks` 全工程零使用**：本地凭证（uid/cid）、AI API Key 全部明文落 preferences，没有走 HUKS 加密。统一导出应把"导出加密"视为**传输层保护**，而不是"本地数据本来加密，只是换个壳"。
- **`share` 走 `@kit.ShareKit` 的 `systemShare`**（`common/utils/ShareUtils.ets:1-33`、`ImageViewer.ets:366-381`），用途是分享帖子/图片，**不是**分享文件；统一导出若要支持"导出后立即分享"，需新增 `fileUri.getUriFromPath`（`@ohos.file.fileuri.d.ts:162`）+ `systemShare` 组合。
- **`getUriFromPath`** 现有 3 处（`ImageViewer.ets:269/271/362`），均用于"沙箱路径 → media URI"喂给相册/分享，可作为统一服务"导出到沙箱临时文件再分享"的参考。
- **`fileIo.openSync`** 共 8 处（`SavedThreadStore.ets:218`、`SettingsPanel.ets:350`、`FavoriteSavedPanel.ets:824`、`LoginPage.ets:462`、`DraftStore.ets:346`、`NewTopicDialog.ets:447`、`ReplyDialog.ets:538`、`DraftMediaStore.ets:493/576`）——导出/导入链路只占 4 处，模式分两派：**带 `try/finally` 的**（存档导出、草稿保存）与**裸线性写法**（凭证导出、凭证导入）。

---

## 2. 凭证导出/导入链路

### 2.1 文件格式（加密容器 JSON）

实现：`entry/src/main/ets/common/security/CredentialExportCrypto.ets`，常量 `CredentialExportCrypto.ets:5-12`，容器类 `CredentialExportCrypto.ets:25-35`。

| 字段 | 值 / 类型 | 说明 | 出处 |
| --- | --- | --- | --- |
| `magic` | `"NGA_CREDENTIAL_EXPORT"` | 文件类型识别用；`isEncryptedCredentialExport` 只校验此字段 | `:5`、`:71-78` |
| `version` | `2`（number） | 解密时要求**严格相等**，否则抛「凭证文件格式不受支持」 | `:6`、`:109-111` |
| `kdf` | `"PBKDF2|SHA256"` | 仅写入，**解密时不读取/不校验**（固定用 PBKDF2\|SHA256） | `:28` |
| `iterations` | `120000` | 写入值；**解密时从文件读**并直接用于 KDF | `:7`、`:117-119` |
| `cipher` | `"AES256|GCM|PKCS7"` | 仅写入，解密时固定用该串 | `:30` |
| `salt` | base64(string) | 16 字节随机盐 | `:9`、`:90` |
| `iv` | base64(string) | 12 字节随机 IV（GCM 推荐值） | `:10`、`:91` |
| `tag` | base64(string) | 16 字节 GCM 认证标签 | `:11`、`:97-102` |
| `data` | base64(string) | 密文；明文为 `{uid, cid, exportedAt}` 的 UTF-8 JSON | `:19-23`、`:96`、`:103` |

JSON 采用 `JSON.stringify(output, null, 2)` 美化输出（`:104`），因此文件是人类可读的"信封 + 密文"。

### 2.2 加密参数（与 SDK 声明逐项核对）

| 参数 | 工程取值 | SDK 约束（权威） | 一致性 |
| --- | --- | --- | --- |
| 算法串 | `AES256\|GCM\|PKCS7` | `createCipher(transformation)`，transformation = 算法（含密钥长度）+ 模式 + 填充，见 `@ohos.security.cryptoFramework.d.ts:3041-3061` | ✅ |
| 密钥长度 | 32 字节（AES-256） | PBKDF2 `keySize` = 派生密钥字节数（`:5974`）；`createSymKeyGenerator('AES256')`（`:1669`） | ✅ |
| KDF | `PBKDF2\|SHA256`，120000 次 | `createKdf` 支持 `PBKDF2\|SHA256`（`:6257-6258`）；`PBKDF2Spec.iterations` 必须正整数（`:5964`） | ✅ |
| salt | 16 字节随机 | `PBKDF2Spec.salt: Uint8Array`（`:5954`），未规定长度 | ✅（自定义长度） |
| IV | 12 字节随机 | `GcmParamsSpec.iv` 1~128 字节、常用 12（`:253-261`） | ✅ |
| AAD | `"nga-oh-credential-export-v2"` 的 UTF-8 字节 | `GcmParamsSpec.aad` 0~INT_MAX（`:263-271`） | ✅（把 magic/version 语义绑进认证） |
| authTag | 16 字节 | `GcmParamsSpec.authTag` **固定 16 字节**（`:273-289`）；GCM 加密时 tag 是 `doFinal` 结果的最后 16 字节，若 `doFinal(null)` 则结果**只有** tag（`:2766-2768`） | ✅ |
| 随机源 | `createRandom().generateRandomSync(len)` | `Random.algName` 仅支持 CTR_DRBG（`:1102`）；**SDK 建议同步 API 放子线程**，主线程可能被阻塞（`:1052-1054`） | ⚠️ 见 §2.6 |
| 待确认 | `cipher.doFinal(null)` 返回值可能为 `null` | SDK 明确"结果可能为 null，使用 `.data` 前要判空"（`:2789-2790`），工程 `:97`/`:102` 未判空 | ⚠️ 判空缺失 |

**KDF 强度评估**：PBKDF2-SHA256 12 万次、8 位最短密码。对离线爆破而言，8 位纯数字/大小写字母组合的搜索空间仍偏小；`cryptoFramework` 还支持 `SCRYPT`（`:6257-6258`），统一服务可考虑升级到 scrypt（在文件里写 `kdf` 字段并**解密时校验**，不要像现有实现那样不校验）。

### 2.3 导出端到端流程

```
设置页「导出账号凭证」行 onAction                    SettingsPanel.ets:699-704
  → handleExport()                                   SettingsPanel.ets:302-325
      读 appStore.auth.token / getSession(token)     :303-308
      清空 exportPassword
      创建 CustomContentDialog（primaryTitle「加密导出凭证」）
  → 用户输入密码 → CredentialPasswordContent.onConfirm   Dialogs.ets:371-378
  → exportEncryptedCredential(password)              SettingsPanel.ets:327-357
      ① getUIContext().getHostContext() as common.UIAbilityContext      :336
      ② new picker.DocumentSaveOptions()
         newFileNames = [`nga_${nickName||User<uid>}.ngacred`]          :338-339
         fileSuffixChoices = ['NGA 凭证|.ngacred']                      :340
      ③ new picker.DocumentViewPicker(context).save(options) → uris[]   :342-343
          uris.length === 0 → 直接 return（用户取消，无提示）            :345-347
      ④ serializeCredentialExport({uid, cid}, password)                 :349
         salt/iv 随机 → PBKDF2 派生 → AES-GCM 加密 → base64 封装 JSON
      ⑤ fileIo.openSync(uris[0], READ_WRITE) → writeSync → closeSync    :350-352
      ⑥ appStore.showToast('账号凭证已加密导出')                         :353
```

密码输入组件：`common/dialogs/Dialogs.ets:301-385`（`CredentialPasswordContent`）。要点：
- `@Prop password` + `onPasswordChange` 回写父 `@State`（`SettingsPanel.ets:51`、`:121-134`）；
- 按钮自绘在内容区，因为官方 `CustomContentDialog.buttons` 无 `enabled` 且只在 `open()` 时求值一次（`Dialogs.ets:294-300` 注释）；
- 最少 8 位（`:306` 默认值 / `SettingsPanel.ets:125` 显式传 8），`isActive()` 用 `trim().length >= minLength`（`:324-326`）；
- 输入框 `InputType.Password` 的键盘沉浸样式由平台否决（`KeyboardAppearanceUtils.ets:35-54` 文件头），统一服务沿用该组件即可自动继承此结论。

### 2.4 导入端到端流程

```
登录页「导入凭据文件」按钮                           LoginPage.ets:235-247
  → handleImport()                                   LoginPage.ets:443-497
      ① DocumentSelectOptions
         maxSelectNumber = 1                                         :450
         fileSuffixFilters = ['.ngacred']                            :451
      ② DocumentViewPicker.select(...) → uris[]                      :453-454
         uris.length === 0 → return（用户取消）                       :456-458
      ③ 读文件：openSync(READ_ONLY) + statSync + new ArrayBuffer(size)
                 + readSync + closeSync                              :462-466
      ④ TextDecoder('utf-8') 解码                                     :468-469
      ⑤ isEncryptedCredentialExport(content)：只校验 magic            :471-474
         失败 → error = '文件格式无效，请导入 .ngacred 加密凭证文件'
      ⑥ 暂存 pendingCredentialContent，打开密码弹窗                    :476-491
  → 用户输入密码 → importPasswordContent.onConfirm   LoginPage.ets:92-105
  → importEncryptedCredential(password)             LoginPage.ets:499-520
      ① deserializeCredentialExport(content, password)  → {uid, cid}   :504
         magic/version 严格校验 → base64 解码 → PBKDF2 → GCM 解密+验 tag
         → 明文 JSON 解析 → uid/cid 非空校验                            :107-134
      ② injectCredentials(uid, cid)                                  :505
         先 checkSessionByCredential 在线校验（三态 VALID/INVALID/UNKNOWN）
         → 取昵称 → appStore.createSession(uid, cid, ...)              AuthApi.ets:229-269
      ③ ok → appStore.setAuth(token, uid, nickName, avatarUrl)       :509
         → 清空 pendingCredentialContent → replaceUrl('pages/MainPage') :510-511
      ④ 失败 → error = result.error || '凭证验证失败'                  :513
      ⑤ 异常 → error = '解密失败，请检查密码或文件是否正确'             :515-516
```

**导入后状态变化（"导入凭证后状态"相关）**：`appStore.setAuth` → `AuthStore.setAuth` 写 `auth`/`sessions` 并**等待落盘**（`AuthStore.ets:95-112`，`:108-110` 注释说明"登录成功后立刻杀进程会丢 auth"）→ `uidChanged` 时 `loadUserData()` 重新 init 全部用户域 Store（`AppStore.ets:493-505`、`:521-533`）→ `settingsStore.applyCurrentTheme()` → `resetCredentialState()` → `reconcilePolling()`。也就是说**凭证导入本身就是一次"全量域重载"**，统一导入服务应复用同一套重载入口，而不是自己逐个 Store 调 `load`。

### 2.5 错误处理与用户提示

| 场景 | 处理 | 提示 / 表现 | 出处 |
| --- | --- | --- | --- |
| 导出时会话丢失 | `saveToast('未找到登录会话')` | Toast | `SettingsPanel.ets:305-308`、`:331-334` |
| 导出：用户取消选择器 | 静默 return | 无反馈 | `:345-347` |
| 导出：picker/加密/写文件抛错 | `showToast(e.message \|\| '导出失败')` | Toast（依赖 Error.message） | `:354-356` |
| 导出：密码 < 8 位 | UI 主按钮禁用（opacity 0.45）；即便绕过，`serializeCredentialExport` 抛「加密密码至少需要 8 位」 | 弹窗内无反馈 / Toast | `Dialogs.ets:364-378`、`CredentialExportCrypto.ets:81-83` |
| 导入：非 .ngacred | 后缀过滤器优先挡；兜底 `isEncryptedCredentialExport` 判 magic | `error = '文件格式无效…'`（登录页内联文本） | `LoginPage.ets:471-474` |
| 导入：读文件失败 | catch → `error = e.message \|\| '导入失败'` | 登录页内联文本 | `:492-494` |
| 导入：密码错 / 密文被篡改 | GCM 认证失败，`deserializeCredentialExport` 抛错 | 统一文案「解密失败，请检查密码或文件是否正确」 | `:515-516` |
| 导入：解密成功但 uid/cid 为空 | `throw new Error('凭证文件内容不完整')` | 被上面同一个 catch 捕获 → **文案误导**为"解密失败" | `CredentialExportCrypto.ets:128-132` |
| 导入：服务端判定无效 | `injectCredentials` 返回 `'凭据无效或已过期'` | 登录页内联文本 | `AuthApi.ets:241-247` |
| 导入：网络异常/服务端异常（UNKNOWN） | `'无法验证凭据，请检查网络后重试'` | 登录页内联文本（**不允许离线导入**） | `AuthApi.ets:242-246` |
| 导入成功后 | 路由替换为主页 | — | `LoginPage.ets:511` |

### 2.6 失败模式清单（实现缺陷 / 风险点）

| # | 失败模式 | 证据 | 严重度 | 统一服务的处理建议 |
| --- | --- | --- | --- | --- |
| F1 | **导出写文件无 `try/finally`**：`writeSync` 抛错则 `file` 未 close（fd 泄漏）；且 picker 默认 `autoCreateEmptyFile=true` 已预创建空文件，写入失败会留下 0 字节 `.ngacred` | `SettingsPanel.ets:350-352`；`@ohos.file.picker.d.ts:607-617`（`autoCreateEmptyFile` 默认 true） | 中 | 复用存档导出的 `try/finally` + 失败时 `unlinkSync` 清理（`FavoriteSavedPanel.ets:824-830` 已是正确写法） |
| F2 | **解密端信任文件内 `iterations`**：无上下限校验，恶意/损坏文件可写 `1e9` 让 PBKDF2 长时间占用线程（DoS）；写 0/负数则抛错 | `CredentialExportCrypto.ets:117-119` | 高 | 校验区间（如 `[10000, 1000000]`）与 `kdf`/`cipher` 白名单；超限直接拒绝 |
| F3 | **密码只输一次、无二次确认**：输错密码导出的文件永远打不开，且没有任何提示可纠正 | `Dialogs.ets:328-379`（仅一个 TextInput） | 中 | 导出侧加"确认密码"输入或改为"生成随机密码 + 展示/复制" |
| F4 | **密码规范化不一致**：长度校验用 `trim()`，KDF 用原串（未 trim） | `CredentialExportCrypto.ets:81` 与 `:92`（传 `password`）、`Dialogs.ets:325` | 低 | 明确契约：要么全 trim，要么明确不允许首尾空格 |
| F5 | **`doFinal(null)` 未判空**：`tag.data` / `decrypted.data` 直接访问，返回 null 时崩溃 | `CredentialExportCrypto.ets:97`、`:102`、`:123`；SDK `:2789-2790` | 低 | 判空并抛业务错误 |
| F6 | **大文件无上限**：导入时 `new ArrayBuffer(stat.size)` 按文件长度一次性分配，超大文件直接 OOM；导出无大小检查 | `LoginPage.ets:462-466` | 中 | `statSync` 后校验大小上限（建议 ≤ 20 MB）再读 |
| F7 | **`isEncryptedCredentialExport` 只校验 magic**：`{"magic":"NGA_CREDENTIAL_EXPORT"}` 这种残缺文件会进入密码弹窗，最终报"解密失败" | `CredentialExportCrypto.ets:71-78` | 低 | 预检必填字段与 base64 长度（salt=16、iv=12、tag=16） |
| F8 | **昵称进入文件名**：`nga_${nickName}.ngacred`，昵称可含 `/ \ : * ? " < > |` 等非法字符，picker 侧行为未知 | `SettingsPanel.ets:337-339` | 低 | 清洗文件名（参考 `DraftMediaStore.ets:80-99` 的 `sanitizeFileName`） |
| F9 | **同步密码学 + 同步 JSON 在 UI 线程**：PBKDF2 12 万次 + 大 JSON 解析均在按钮回调里同步执行，存在卡顿/ANR 风险 | `CredentialExportCrypto.ets:52-64`、`:93-97`；SDK 建议同步加密放子线程（`cryptoFramework.d.ts:1052-1054`） | 中 | 用 `taskpool` 执行 KDF+加解密（工程已有 `@kit.ArkTS` taskpool 用法：`ThreadApi.ets:28/264`） |
| F10 | **取消选择器静默返回**：用户无法区分"没选"与"失败" | `SettingsPanel.ets:345-347` | 低 | 无需改（系统 UI 取消是正常路径），但统一导出流程要在"开始导出"前给明确反馈 |
| F11 | **`pendingCredentialContent` 残留**：取消密码弹窗后密文仍留在内存字段，仅成功导入时清空 | `LoginPage.ets:476`、`:510` | 低 | 弹窗关闭回调里清空 |
| F12 | **错误文案混合**：文件损坏/字段缺失都被归为"解密失败" | `LoginPage.ets:515-516` | 低 | 区分"密码错误（GCM tag 校验失败）"与"文件损坏/字段缺失" |
| F13 | **导入必须联网**：`injectCredentials` 先做服务端校验 | `AuthApi.ets:241-247` | 设计使然 | 统一导入若含凭证域，必须提示"需要联网校验" |
| F14 | **`version` 升级无迁移**：`version !== 2` 一律拒绝 | `CredentialExportCrypto.ets:109-111` | 低 | 统一容器按"主版本严格、次版本兼容"设计，见 §5.7 |

---

## 3. 离线存档导出/导入链路

### 3.1 文件格式（明文 JSON，根结构 `SavedThreadExportFile`）

模型：`entry/src/main/ets/model/SavedThread.ets:54-61`。

```jsonc
{
  "schemaVersion": 2,          // 与 SAVED_THREAD_SCHEMA_VERSION 严格比对
  "exportedAt": 1760000000000, // Date.now()
  "threads": [                 // SavedThread[]
    {
      "tid": "44191387",
      "fid": 650, "subject": "...", "author": "...", "authorid": 123,
      "forumName": "...", "totalPages": 20, "savedPages": 3,
      "lastLou": 12345, "savedAt": 1760000000000,
      "rawPages": [ /* 每页与 HTML 解析器输出同形状的原始 JSON */ ]
    }
  ]
}
```

- `SAVED_THREAD_SCHEMA_VERSION = 2`（`SavedThread.ets:16`），v2 语义：由持久化 `PostInfo[]` 快照改为持久化**同形状原始 JSON**（`rawPages`），使任意后续版本解析器可以重新解释存档（`SavedThread.ets:1-10` 文件头）。
- 单帖存档文件 `<tid>.json` 与导出容器共用同一 `SavedThread` 形状（`SavedThreadStore.ets:80-82`、`:213-215`），因此**单帖导出 = 只含一个元素的容器**（`FavoriteSavedPanel.ets:812-816`、`:1053-1055`）。

### 3.2 导出流程

```
「离线保存」Tab 标题栏次按钮（导出全部）                FavoriteSavedPanel.ets:1186-1190
  → exportAll()                                        :840-842
      appStore.savedThreadStore.getAll()
  → exportThreads(threads)                             :798-835
      ① threads.length === 0 → toast('没有可导出的存档')  :799-802
      ② context = getHostContext()（失败 → toast('无法获取文件保存器')） :803-809
      ③ DocumentSaveOptions
         newFileNames：单帖 nga_<tid>_saved.json；多帖 nga_saved_threads_<ts>.json :811-816
         fileSuffixChoices = ['JSON 存档|.json']                               :817
      ④ DocumentViewPicker.save(options) → uris[]                              :818-819
         uris.length === 0 → return                                            :820-822
      ⑤ serializeForExport(threads) → JSON 文本（**一次性 stringify**）          :823 / :321-326
      ⑥ openSync(READ_WRITE|CREATE|TRUNC) → try{writeSync}finally{closeSync}    :824-830
      ⑦ toast('已导出 N 个帖子')                                                :831
      异常 → toast('导出失败：' + formatError(e))                               :832-834
```

**导出并行入口**：单条存档行的"导出"图标（`FavoriteSavedPanel.ets:1049-1055`）导出当前帖；标题栏次按钮（`:1186-1190`）导出全部。

### 3.3 导入流程

```
「离线保存」Tab 标题栏主按钮（导入）                  FavoriteSavedPanel.ets:1177-1181
  → handleImport()                                  :849-899
      ① importing 重入保护                            :850-852
      ② context = getHostContext()（失败 → toast）      :853-859
      ③ DocumentSelectOptions.maxSelectNumber = IMPORT_MAX_FILES(=50)   :862-863（常量 :54）
         （注意：**未设置 fileSuffixFilters**，可选任意文件）
      ④ DocumentViewPicker.select(...) → uris[]         :864-865
      ⑤ 逐个 uri 串行：readUriText(uri) → importContent(content)        :872-888
         readUriText = fileIo.readTextSync(uri)          :907-909
         每文件的结果累加 imported/skipped/firstError
      ⑥ toast 汇总：成功 X 个，跳过 Y 个（首个错误）       :889-893
      异常 → toast('导入失败：' + formatError(e))          :894-895
      finally importing = false                         :896-898
  → SavedThreadStore.importContent(content)           SavedThreadStore.ets:334-390
      ① context === null → error='存档未就绪'            :336-339
      ② content 为空 → error='文件为空'                  :340-343
      ③ JSON.parse 失败 → error='文件不是有效的 JSON'     :344-350
      ④ schemaVersion !== 2 → error='文件格式版本不受支持' :351-354
      ⑤ threads 缺失/空 → error='文件中没有保存的帖子'      :355-358
      ⑥ 逐条校验：item 非空 && isValidTid(item.tid) && rawPages 非空
         否则 skipped++，hasAnyInvalid=true               :360-367
         savedAt <= 0 → 用 Date.now() 兜底                :368-370
         normalizeArchive(item)                          :371
         await save(item, false)（写盘成功 imported++，失败 skipped++ 并记录首个错误） :372-381
      ⑦ imported > 0 → bumpAppStorageVersion(KEY_SAVED_THREAD_VERSION)  :383-385
      ⑧ error 为空但有无效条目 → error='部分条目无效已跳过（tid 非法或缺少内容）' :386-388
```

### 3.4 冲突策略 / 校验 / 原子写 / 通知刷新

| 关注点 | 现状 | 证据 |
| --- | --- | --- |
| 冲突策略 | **覆盖**：同 `tid` 直接覆盖，**不比较 `savedAt` 新旧**，也不提示 | `SavedThreadStore.ets:5-7` 文件头、`:205-258` |
| 冲突键 | `tid`（NGA 主题 ID，纯数字 1~16 位） | `:38-49` `isValidTid` |
| 条目标识校验 | tid 非纯数字 → 跳过；`rawPages` 为空 → 跳过 | `:360-367` |
| **未校验项** | `rawPages` 的**元素结构**、`fid/subject/author/...` 类型均不校验，任意 JSON 会被原样落盘（渲染期才由解析器解释） | `:360-367` 仅判数组非空 |
| 覆盖写原子性 | 先写 `<tid>.json.tmp` → `renameSync` 替换；失败清理 tmp、旧文件不破坏 | `:216-244` |
| 落盘后内存缓存 | 过滤同 tid 旧项 → push → 按 `savedAt` 降序重排 | `:246-254` |
| 通知刷新 | 批量导入**循环结束后统一 bump 一次**，避免逐帖触发列表全量刷新 | `:373-374`、`:383-385` |
| 列表侧响应 | `@StorageProp('savedThreadVersion') @Watch('onSavedThreadVersionChange')` → `refreshSaved()` 重新 `getAll()` | `FavoriteSavedPanel.ets:114-116`、`:762-772` |
| 版本号实现 | `bumpAppStorageVersion` = `AppStorage.get + 1` + `setOrCreate` | `common/utils/AppStorageVersion.ets:8-12` |
| 存档目录 | `filesDir/saved_threads`，每帖一文件；`init` 时 `mkdirSync` | `SavedThreadStore.ets:27`、`:67-78` |
| 重载与规整 | `reload()` 扫描目录，跳过损坏/旧格式/非法 tid；`normalizeArchive` 修正 `savedPages` 与 `lastLou` | `:87-117`、`:126-134` |

### 3.5 大数据量表现与已知限制

| # | 限制 | 证据 | 影响 |
| --- | --- | --- | --- |
| L1 | 导出为**单文件全量 JSON**，`JSON.stringify` 一次性生成大字符串后一次 `writeSync` | `SavedThreadStore.ets:321-326`；`FavoriteSavedPanel.ets:823-827` | 内存峰值 ≈ 2 倍存档体积（对象 + 字符串）；无大小上限 |
| L2 | 导入为**单文件全量读取 + 全量 parse**，`readTextSync` 不接受 offset 流式处理 | `FavoriteSavedPanel.ets:907-909`；`SavedThreadStore.ets:346` | 大文件一次性进内存；单文件可达数百 MB 级别时必然 OOM |
| L3 | 导入每个 `tid` 都做一次同步写文件 + `rename`（循环内 `await save`） | `SavedThreadStore.ets:372-381` | N 帖 = N 次 fs 系统调用，无进度条，UI 只有最后一条 Toast |
| L4 | 导入支持一次选 50 个文件，每文件再 N 帖，串行处理 | `FavoriteSavedPanel.ets:54`、`:862-888` | 最坏 50×N 次写；无中途取消入口 |
| L5 | 导入是**部分成功**语义：失败条目跳过、已写不覆盖回滚 | `SavedThreadStore.ets:372-389` | 用户可能得到"成功 3 跳过 7"的半成品状态 |
| L6 | **无幂等键之外的防重**：重复导入同文件 = 覆盖，结果幂等（内容一致）但会重复写盘 | `:373-374` | 可接受，但统一服务应保留幂等台账 |
| L7 | 覆盖不看新旧：老存档可覆盖新存档 | `:205-258` | 迁移场景可能"倒退"；建议统一服务提供"仅当更新时才覆盖"选项 |
| L8 | `ImportResult.error` 只保留**首个**错误，其余丢失 | `:378-380`、`:386-388` | 用户无法定位全部失败原因 |
| L9 | 未设置 `fileSuffixFilters`：用户可误选任意文件 | `FavoriteSavedPanel.ets:862-865` | 统一导入应显式过滤后缀 |
| L10 | 存档不与账号绑定（全局唯一目录），导入不校验 uid | `SavedThread.ets:1-10`、`SavedThreadStore.ets:1-11` | 换账号后仍可见（设计使然），统一导出需说明"该域跨账号" |
| L11 | `getAll()` 返回**浅拷贝**（元素引用共享），导出期间无快照隔离 | `SavedThreadStore.ets:139-145` | 导出与并行保存并发时可能导出到"半新半旧"的对象（概率低） |

---

## 4. 可复用组件清单

> 结论口径：**直接复用** = 原样调用；**抽取公共模块** = 把现有逻辑提成通用工具后复用；**重写** = 现有实现不满足统一服务需求，按新契约实现。

| # | 组件 / 能力 | 位置 | 现状要点 | 复用建议 |
| --- | --- | --- | --- | --- |
| C1 | 加密容器 `CredentialExportCrypto`（`serializeCredentialExport`/`deserializeCredentialExport`/`isEncryptedCredentialExport`） | `common/security/CredentialExportCrypto.ets:71-134` | 算法/参数正确，但 payload 写死 uid/cid；无参数校验、无版本迁移、无判空 | **重写**为通用 `EncryptedContainer`：`seal(plaintext, password, aad)` / `open(json, password)`，保留相同算法与字段（兼容旧 `.ngacred`），补 F2/F5/F7 |
| C2 | 密码输入弹窗 `CredentialPasswordContent` | `common/dialogs/Dialogs.ets:301-385` | `@Prop password` + 回调；按钮自绘解决官方按钮无动态激活态；最少位数可配 | **直接复用**（统一导出的"加密密码"弹窗即它）；若要加"确认密码"则**抽取**新组件（不要把确认逻辑塞进该组件，它已被 2 处使用） |
| C3 | picker 调用模式（save / select） | `SettingsPanel.ets:336-347`、`LoginPage.ets:448-458`、`FavoriteSavedPanel.ets:803-821`、`:853-868` | 三处重复：取 `UIAbilityContext` → new Options → new DocumentViewPicker(context) → await → 空数组判断 | **抽取公共模块**：`pickSaveFile(ctx, suggestedName, suffixChoice)` / `pickOpenFiles(ctx, suffixes, maxCount)`；统一错误文案与取消语义 |
| C4 | Toast 提示 `appStore.showToast` | `store/AppStore.ets:849`；实现 `common/feedback/ToastManager.ets:125-127` | 系统浮层（`openCustomDialog`），未注入 UIContext 前暂存最后一条 | **直接复用**；长耗时导出应改用"带进度/可取消"的浮层（新增组件，不复用 Toast） |
| C5 | 二次确认对话框 `TipsDialog` | `SettingsPanel.ets:67-118`、`FavoriteSavedPanel.ets:913-939` | 官方 `TipsDialog` + `systemMaterial` + `maskColor` 契约（见 `docs/IMMERSIVE_LIGHT_DESIGN.md` 第 12 节） | **直接复用**（明文导出确认、覆盖导入确认、删除前确认） |
| C6 | 原子写（临时文件 + rename） | `SavedThreadStore.ets:216-244`、`DraftStore.ets:338-376` | 两处实现同构：`.tmp` → `writeSync` → `closeSync` → `renameSync`；失败清理 tmp | **抽取公共模块**：`writeFileAtomic(path, content)` / `writeFileAtomicBytes(path, ArrayBuffer)`；统一服务导出文件、导入还原临时文件都该用它 |
| C7 | 文件读取 | `FavoriteSavedPanel.ets:907-909`（`readTextSync(uri)`）；`LoginPage.ets:462-469`（手工 stat+buffer+readSync） | `readTextSync` 简洁且工程注释确认 fs API 接受 uri；手工 buffer 方式**无大小上限** | **抽取公共模块**：`readTextFromUri(uri, maxBytes)`（先 `statSync` 校验上限再读）；统一服务导入统一走此函数 |
| C8 | 缓存信封 `CacheEnvelopeStore<T>` | `common/infra/CacheEnvelopeStore.ets:7-176` | `{schemaVersion, uid, items, updatedAt}`；校验（严格/宽容）、加载、串行落盘 | **直接复用**其结构语义作为"域容器"原型；但**导出需要取到原始 items**，现有 `load` 只返回 `items` 副本 → 统一服务应直接读 preferences 原始 JSON（`PreferencesStore.getJSON`）再自行解包，避免误把 `uid` 校验用于跨账号导入 |
| C9 | 偏好读写 `PreferencesStore` | `common/infra/PreferencesStore.ets:11-82` | `getString/putString/getJSON/putJSON`，`flush`、`scheduleFlush` | **直接复用**（统一服务只通过它读写 preferences，不直接碰底层 preferences API） |
| C10 | 版本号刷新 `bumpAppStorageVersion` + `AppStorageKeys` | `common/utils/AppStorageVersion.ets:8-12`；`common/constants/AppStorageKeys.ets:1-148` | 版本键集中注册；`@StorageProp` 字面量需手工对齐（文件头注释） | **直接复用**；统一导入后按域逐个 bump（清单见 §5.3） |
| C11 | 编解码 `CodecUtils` | `common/utils/CodecUtils.ets:23-36`（`stringToUint8Array`/`uint8ArrayToBase64`） | 纯函数，无副作用 | **直接复用**；注意只有 encode，没有 base64 decode（现有 `CredentialExportCrypto.ets:37-40` 自带 `base64Decode`）→ 抽取时补一个 `base64ToUint8Array` |
| C12 | 键盘沉浸样式 `KeyboardAppearanceUtils` | `common/utils/KeyboardAppearanceUtils.ets:66-87` | 密码框的键盘沉浸被平台否决（文件头 35-54 行）；本工程受影响的 3 处密码框之一即导出/导入密码 | **直接复用**；统一服务的密码输入若仍用 `InputType.Password`，不要为"沉浸"改 `Normal`（会明文显示），该文件头已明确禁止 |
| C13 | 目录递归删除 `removeDirRecursively` | `common/utils/FileUtils.ets:27-50` | `lstatSync` 判类型防软链越界；失败只记日志 | **直接复用**（清理导出临时目录/导入解包目录） |
| C14 | 文件分享（可选能力） | `common/utils/ShareUtils.ets:1-33`、`ImageViewer.ets:355-381` | `systemShare.SharedData` + `ShareController.show`；沙箱路径需 `fileUri.getUriFromPath` | **抽取公共模块**：`shareExportedFile(sandboxPath)`，用于"导出到沙箱 → 一步分享给微信/网盘"的迁移路径（当前导出只能落到用户选的位置） |
| C15 | 域名/版本等常量 | `common/constants/Constants.ets`、`common/constants/AppStorageKeys.ets` | — | 新增统一导出格式常量时**集中放** `common/constants/`（不要散落在 service 里） |
| C16 | 单帖/全量导出入口 | `FavoriteSavedPanel.ets:798-842`、`:1049-1055`、`:1186-1190` | 入口形态（行内 + 标题栏）已验证可用 | **直接复用 UI 形态**，实现替换为统一服务调用 |

---

## 5. 统一导出导入服务的设计输入

### 5.1 数据域盘点（现状事实，作为注册表基线）

> 除 `saved_threads` / `drafts` / `draft_media` 外，所有数据都在 prefs 库 `nga_app_store`（`AppStore.ets:181`）里，键形如 `<prefix>_<uid>`。
>
> **对齐说明**：并行线已落地 `PersistenceCatalog`（`common/persistence/PersistenceCatalog.ets:29-144`，共 20 个 `DomainSpec`），
> 每域声明 `id/storage/key/dirName/schemaVersion/scope/exportPolicy/importPolicy/clearable/rebuildable/avgItemBytes`（`PersistenceTypes.ets:137-243`）。
> 下表"域"列已按 Catalog 的 `DomainIds` 对齐；**统一导出导入必须以此注册表为唯一真相**，不要再维护第二份域清单。
> 注意 Catalog 里的 `schemaVersion` 是"v2 重构后新体系"的版本号，与旧实现的 `SAVED_THREAD_SCHEMA_VERSION=2`、`TRACKED_THREAD_SCHEMA_VERSION=2`、`NOTIFICATION_CACHE_SCHEMA_VERSION=3` **不是同一套编号**，旧号不复用。

| 域 | 载体 / 键 | 结构版本 | 条目上限 | 含敏感数据 | 跨账号语义 | 建议默认勾选 |
| --- | --- | --- | --- | --- | --- | --- |
| 设置 | prefs `settings_<uid>`（`SettingsStore.ets:120-130`），序列化 `SettingsState` | 无独立版本（字段级） | 单对象 | **是**：`aiProfiles[].apiKey`、`aiSearchProfiles[].apiKey`、`toolsApiKey`（`AiConfig.ets:73/105`、`AiSearchConfig.ets:31`） | 按 uid | 是（**但不含密钥**，见 §5.5） |
| 黑名单 / 屏蔽词 / 备注 / 收藏板块 | 同上（`SettingsState.blacklist/filterKeywords/notes/favorites`，`SettingsState.ets:21-29`）；加载后需回填 `FilterListManager`（`SocialListSettings.ets:276-288`） | 同上 | 无硬上限 | 黑名单=公开 uid；备注=私人 | 按 uid | 是 |
| 浏览历史 | prefs `history_<uid>`（`HistoryStore.ets:79-80`），`BrowseHistoryEntry[]` | 无独立版本 | 500（`HistoryStore.ets:41`） | 是（阅读轨迹） | 按 uid | 是 |
| 通知缓存 | prefs `cached_notifications_<uid>`（`NotificationStore.ets:74-78`），信封 v3 | 3（`:30`） | 200（`:33`） | 中（通知摘要） | 按 uid | 否（可重建） |
| 关注动态缓存 | prefs `cached_activities_<uid>`（`FollowActivityStore.ets:93-95`），信封 v2 | 2（`:25`） | 【待确认】 | 中 | 按 uid | 否 |
| 收藏关系提示缓存 | prefs `favorite_topic_membership_v1_<uid>`（`FavoriteStore.ets:40/875-877`） | 1（`:35`） | 【待确认】 | 低 | 按 uid | 否（可重建） |
| 分类缓存 | prefs `cached_categories`（`CategoryStore.ets:42/56`） | 【待确认】 | — | 低 | 不按 uid | 否（可重建） |
| AI 会话 | prefs `ai_sessions_<uid>`（`AiSessionStore.ets:36/59-63`），`AiSession[]` | 1（`AiSession.ets:15`） | 20 会话 / 每会话 200 消息（`AiSession.ets:18/26`） | **高**：全文对话 + 工具摘要 | 按 uid（`ownerUid` 校验，`AiSession.ets:73`） | **否**（需显式勾选 + 警告） |
| AI 工具结果缓存 | prefs `ai_tool_cache_<uid>`（`AiToolCacheStore.ets:39/60-65`） | 1（`:36`） | 80 条 / 1.2M 字符（`:42/45`） | 高（帖子正文/搜索摘要） | 按 uid | 否（可重建） |
| 投票记录 | prefs `votes_<uid>`（点赞/踩）+ `pollVoted_<uid>`（投票帖），`VoteStore.ets:42-48` | 无独立版本 | 200（`:13`） | 低 | 按 uid | 是 |
| 阅读进度 | prefs `reading_progress_<uid>`（`ReadingProgressStore.ets:42-44`），`ReadingProgressEntry[]` | 无独立版本 | 200（`:18`） | 是（阅读位置） | 按 uid | 是 |
| 跟踪帖子 | prefs `tracked_threads_<uid>`（`TrackedThreadStore.ets:128-132`），信封 v2 | 2（`:50`） | 【待确认，`TRACK_MAX_COUNT` 在 `model/TrackedThread.ets`】 | 中 | 按 uid | 是 |
| 离线存档 | `filesDir/saved_threads/<tid>.json`（`SavedThreadStore.ets:27/80-82`） | 2（`SavedThread.ets:16`） | 无硬上限 | 中（帖子原文） | **不按账号**（全局目录） | 是 |
| 草稿 | `filesDir/drafts/<draftKey>.json`（`DraftStore.ets:39/231`），`EditorDraft` | 无版本（结构随类演进） | 保留 7 天（`:50`） | 高（未发布正文） | 键含 uid 短哈希（`:100-117`） | 是（可选） |
| 草稿媒体 | `filesDir/draft_media/<draftKey>/...`（`DraftMediaStore.ets:59/211`） | — | 总体 128MB 软上限（`:69`） | 高（未发布图片/视频） | 随草稿键 | 否（体积大，默认不带） |
| 凭证 | prefs `auth` + `sessions`（`AuthStore.ets:76/145-147/291`），`PersistedAuth` 含 cid | 无版本 | — | **极高**（直接登录态） | 按 token | **排除**（沿用独立 `.ngacred`，见 §5.4） |
| 主题 | prefs `nga_theme`（`ThemeSettings.ets:30`，全局键） | — | 单对象 | 低 | 不按 uid | 可选（默认否，避免覆盖新机主题） |
| 列布局 / UI 偏好 | prefs `settings_<uid>` 内 + `AppStorage` 多个键（`AppStorageKeys.ets:120-148`），部分纯内存 | — | — | 低 | 按 uid | 否 |

> 关键差异：**大部分域可以"读 prefs 原始 JSON → 整段搬运"**，但"设置域"与"凭证"是结构体/混合体，直接搬运会同时覆盖掉不相关字段（例如只导入黑名单却把 AI 密钥一起改掉）。统一服务必须支持**域内子集选择**（settings 域至少拆成 黑名单/屏蔽词/备注/收藏/AI 配置/显示/阅读/其他 子项），否则"选择性导出"是假的。

### 5.2 容器格式（对齐既有设计，并做核查补充）

> **既有设计**：`docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6.1-§6.2 已定稿容器格式，常量落在
> `common/persistence/PersistenceTypes.ets:110-129`：
> `BACKUP_MAGIC='NGA_OH_BACKUP'`、`BACKUP_ENCRYPTED_MAGIC='NGA_OH_BACKUP_ENC'`、
> `BACKUP_FILE_SUFFIX='.ngabackup'`、`BACKUP_FORMAT_VERSION=1`、`BACKUP_MAX_FILE_BYTES=64MB`、
> `IMPORT_UNDO_TTL_MS=10min`。**本报告不再另起一套格式**；下面只做"逐项核查 + 本文档补充的约束"。

分两层：**容器层**（文件级、可加密）与**域层**（每域独立 `schemaVersion`，域清单取 `PersistenceCatalog`）。

#### 5.2.1 明文容器（已定：`NGA_OH_BACKUP`）

```jsonc
{
  "magic": "NGA_OH_BACKUP",
  "formatVersion": 1,          // 容器层格式版本；> 当前 → 拒绝并提示升级 App
  "dataVersion": 2,            // 全局数据版本（PERSISTENCE_DATA_VERSION）
  "exportedAt": 1760000000000,
  "appVersionName": "1.2.0",
  "appVersionCode": 1020000,
  "deviceTag": "phone",        // 仅诊断，导入不依赖
  "domains": [
    { "id": "settings", "schemaVersion": 1, "updatedAt": 1760000000000, "payload": { } },
    { "id": "saved_threads", "schemaVersion": 1, "updatedAt": 1760000000000, "payload": [ ] }
  ],
  "checksum": "sha256:<hex of JSON.stringify(domains)>"
}
```

核查结论与补充约束：

- ✅ `domains` 用**数组**保证顺序稳定（设计文档已注明）——这同时是 `checksum` 可复算的前提。
- ⚠️ `checksum` 的计算依赖"同一序列化器往返后字节一致"。`payload` 由各域自己的序列化器产出，**必须保证同一份数据两次 `JSON.stringify` 结果一致**（不要用 `Map`/`Set`/动态字段顺序）；验收时建议加"导出→导入→再导出，两次 checksum 相等"的自测。
- ⚠️ `checksum` 只防"截断/手改"，不防篡改（无密钥）；真正的完整性由加密容器的 GCM tag 提供。**不要在明文容器上假称"防篡改"**。
- ✅ `magic` + `formatVersion` 放明文，未加密也能识别类型/给升级提示（与设计文档一致）。
- 建议（本文补充）：域 `payload` 里**不要放 `ownerUid` 以外的身份字段**；`ownerUid` 由导入器重写（见 §5.4），否则 `CacheEnvelopeStore.isValidEnvelope` 会整体丢弃（`CacheEnvelopeStore.ets:64-86`）。
- 建议（本文补充）：带二进制内容的域（`draft_media`、`moving_photo_cache`）在 v1 只导出**清单**、不内嵌 base64——设计文档 §6.4 已按此处理（`draft_media` 导入不含媒体），与容器"纯 UTF-8 JSON"定位一致。

#### 5.2.2 加密容器（已定：`NGA_OH_BACKUP_ENC`）

复用 `CredentialExportCrypto` 的算法参数（PBKDF2-SHA256 / 120000 次 / AES-256-GCM / 12B IV / 16B tag），
AAD 定为 `nga-oh-data-backup-v1`（设计文档 §6.1），与凭证的 AAD `nga-oh-credential-export-v2`
（`CredentialExportCrypto.ets:12`）隔离，防止两种文件互相当作对方导入。

```jsonc
{
  "magic": "NGA_OH_BACKUP_ENC",
  "formatVersion": 1,
  "kdf": "PBKDF2|SHA256",
  "iterations": 120000,
  "cipher": "AES256|GCM|PKCS7",
  "salt": "…", "iv": "…", "tag": "…", "data": "<b64 of 明文容器 JSON>"
}
```

核查结论与补充约束（**这些是现有 `CredentialExportCrypto` 没有、统一实现必须加的**）：

1. **解密端必须校验 `kdf` / `cipher` 白名单**（现有凭证实现只校验 magic+version，字段写了却不校验：`CredentialExportCrypto.ets:28/30` vs `:107-124`）。
2. **`iterations` 必须校验上下限**（如 `[10000, 1000000]`）。现有实现直接采用文件里的值（`CredentialExportCrypto.ets:117`），恶意文件可写 `1e9` 造成 PBKDF2 长时间阻塞（§2.6 F2）。
3. **`salt/iv/tag/data` 的 base64 解码后长度校验**：salt=16、iv=12、tag=16（与写入端常量 `:9-11` 对齐），不符直接拒绝，避免把"文件损坏"误报成"密码错误"。
4. **`doFinal` 返回值判空**（SDK `@ohos.security.cryptoFramework.d.ts:2789-2790`；现有实现 `CredentialExportCrypto.ets:97/102/123` 未判空）。
5. **加密粒度**：整包加密（设计文档已定），`data` 是"明文容器 JSON 的 base64"；大包场景用 `Cipher.update` 分片（SDK `:2418-2419` 允许对称加解密多次 update），**不要**一次性 `stringToUint8Array(整包)`（内存 2 倍）。
6. **口令策略**：设计文档定"最短 8 位、默认勾选加密、取消时二次确认、不提供找回"（§6.2）。本文补充：现有 `CredentialPasswordContent` 只有单输入框、无二次确认（`Dialogs.ets:328-379`），导出侧**必须**新增"确认密码"或"生成随机口令"，否则用户输错即永久失去备份（§2.6 F3）。

#### 5.2.3 对并行设计文档 §6 的纠偏清单（供 Lead 决策）

> 对照 `docs/PERSISTENCE_UNIFICATION_DESIGN.md` §6 与 `PersistenceCatalog` 现值，逐条列出**与本文调研结论冲突或需修正**的点。

| # | 设计文档现写法 | 问题 | 建议 |
| --- | --- | --- | --- |
| D1 | §6.3 "完成后调 `picker.DocumentSavePicker` 保存" | **SDK 中不存在 `DocumentSavePicker`**。`@ohos.file.picker.d.ts` 只有 `DocumentViewPicker`，保存用其 `save(options)`（`:721`），选择用 `select(options)`（`:679`）。 | 改为 `new picker.DocumentViewPicker(context).save(options)`，与现有两处实现一致（`SettingsPanel.ets:342-343`、`FavoriteSavedPanel.ets:818-819`） |
| D2 | §6.4 `settings` 域"AI 配置按 id 合并" | `SettingsState.aiProfiles[]` 含**明文 `apiKey`**（`SettingsState.ets:57-58` + `AiConfig.ets:73`），`aiSearchProfiles[]` 同（`AiSearchConfig.ets:31`）。按此策略，用户导入一份"设置备份"会把第三方 API Key 一起写回（可能覆盖本机密钥），且导出包里**明文含密钥**（未加密时）。 | ①导出前从 settings 域 payload 中**剥离** `apiKey`/`toolsApiKey` 字段（导出后仍可用，但密钥需重新填）；或 ②新增独立子开关"包含 AI 密钥（不推荐）"；③导入合并时若包里无密钥字段，**保留本机密钥**而不是清空 |
| D3 | Catalog `ai_sessions`：`ExportPolicy.INCLUDE`（`:106-110`） | 默认勾选 = 默认导出用户与 AI 的全部私人对话；体积可达数 MB。与"最小暴露"原则冲突。 | 改为 `OPTIONAL`（默认不勾选），勾选时 UI 明示"包含你与 AI 的全部对话"，并**强制加密**（至少默认勾选加密） |
| D4 | Catalog `draft_media`：`ExportPolicy.INCLUDE`（`:122-126`） | 草稿媒体总上限 128MB（`DraftMediaStore.ets:69`），而容器上限 64MB（`BACKUP_MAX_FILE_BYTES`）——若真导出媒体，必然超限。设计文档 §6.4 又写"导入不含媒体"，两者不自洽。 | Catalog 的 `exportPolicy` 改为 `OPTIONAL` 或 `NEVER`（配合设计文档"仅清单"语义）；`avgItemBytes` 也需重估 |
| D5 | §6.6 第 5 条"字符串字段长度裁剪到域上限" | 若对 `settings`/`drafts`/`ai_sessions` 的**正文**做裁剪，会静默损坏用户数据。 | 明确只裁剪"标题/摘要类元数据字段"，正文一律拒绝超限而不是静默截断 |
| D6 | §6.2 口令"最短 8 位、不强制复杂度" | 8 位弱口令 + PBKDF2 12 万次，离线爆破可行；且现有组件无二次确认。 | 至少：导出侧二次确认、强度提示（低/中/强）、可选"生成随机口令"；导入侧无成本。是否提高到 10 位由产品定 |
| D7 | §6.4 `drafts` 行"键内 uid 哈希段保留导入值（见风险）" | 跨账号导入时若保留旧 uid 段，新账号的编辑器按 `draftUidPart(currentUid)` 拼键（`DraftStore.ets:100-117`）会**读不到**这份草稿（等于导入无效）。 | 导入时按当前账号**重算**键中的 uid 段，并同步重命名 `draft_media/<key>` 目录；若跨账号且用户未登录，提示"登录后再导入草稿" |
| D8 | §6.1 明文容器字段 `deviceTag` | 设计文档已有，但与任务要求的"deviceInfo"相比信息量偏少（调试迁移问题时不够）。 | 保持 `deviceTag` 必选；可选追加 `apiVersion`/`appVersionName`（已有）即可，无需存设备唯一标识（**不要**存 OAID/SN，无必要且涉隐私） |



#### UI

```
设置页 → 数据管理（新增区块，放在「导出账号凭证 / 清除缓存 / 退出登录」块附近，SettingsPanel.ets:697-735）
  └─ 「导出数据」→ 导出面板（半模态 sheet 或全页）
       域勾选列表（分组：内容 / 偏好 / AI / 账号）
       每行：名称 + 条目数 + 估算大小 + 敏感标记（🔒 AI 会话 / API Key 不导出）
       底部：总大小估算 + 「下一步」
  └─ 「导入数据」→ 选择文件 → 解析容器（不落盘）→ 预览页
       每域：可导入条目数 / 冲突数 / 本机将覆盖的条目数
       单选：合并（保留本机较新） / 覆盖 / 跳过冲突
       确认 → 执行 → 进度 → 结果页（成功/跳过/失败明细，可导出日志）
```

#### 数据流

```
DomainRegistry（新增，common/export/DomainRegistry.ets）
  每个域实现统一接口：
  interface ExportDomain {
    readonly name: string                 // 'settings' / 'history' / 'saved_threads' …
    readonly schemaVersion: number
    readonly sensitive: boolean
    estimateCount(ctx): Promise<number>
    collect(ctx, options): Promise<Object>      // 返回该域可 JSON 化数据
    apply(ctx, data, mode): Promise<DomainImportResult>
    bumpVersionKeys(): string[]                  // 导入后需要 bump 的 AppStorage 键
  }
导出：collect each selected domain → 逐域 JSON.stringify → checksum
      → 拼容器 → 可选整体加密 → 原子写 → 校验 size/checksum → Toast
导入：读文件（上限校验）→ 解容器 → 解析每个 domain（schema 校验）
      → 逐域 apply（模式化）→ 逐域 bump 版本 → 结果汇总
```

**导入后必须 bump 的版本键**（来自 `AppStorageKeys.ets`，各域自己的 `@Watch` 消费）：

| 域 | 版本键 | 常量 |
| --- | --- | --- |
| 离线存档 | `savedThreadVersion` | `AppStorageKeys.ets:106` |
| 跟踪 | `trackedThreadVersion` | `:115` |
| 浏览历史 | `browseHistoryVersion` | `:73` |
| 通知 | `notificationVersion` | `:64` |
| 关注动态 | `activityVersion` | `:67` |
| 黑名单 | `blacklistVersion` | `:88` |
| 收藏板块 | `favVersion` | `:79` |
| 收藏夹/关系 | `favoriteFolderVersion` / `favoriteTopicVersion` | `:82` / `:85` |
| 分类 | `catVersion` | `:76` |
| AI 配置 | `aiConfigVersion` | `:94` |
| 个人主页 | `profileVersion` | `:91` |

> 注意：设置类域没有版本键，导入后需要走 `SettingsStore.loadUserSettings` 路径（`SettingsStore.ets:132-165`，它负责把值回写 AppStorage 与各子域），**不能只写 prefs**。

### 5.4 导入策略

| 决策点 | 建议 | 依据 |
| --- | --- | --- |
| 模式 | 三选一：**合并**（默认）/ **覆盖** / **跳过冲突** | 现有离线存档只有"覆盖"（`SavedThreadStore.ets:5-7`），用户无法选择 |
| 冲突键 | 按域定义：存档=`tid`；历史=`tid`；阅读进度=`tid`；投票=`uid+tid`；跟踪=`tid`；AI 会话=`id`（`sess_<ts>_<rand>`，`AiSession.ets:109`）；草稿=`key`（含 uid 短哈希） | 见 §5.1 |
| 合并时的"谁赢" | 默认按时间戳（`savedAt` / `updatedAt` / `ts`）**新者胜**；无时间字段的域（黑名单/关键词）按"并集" | 现有覆盖策略不看时间，是缺陷（L7） |
| ID 重映射 | 本工程绝大多数 ID 是服务端 ID（tid/pid/uid/fid），**无需重映射**；需要重映射的仅两处：① 草稿 `key` 中的 uid 短哈希段（`DraftStore.ets:100-117`）——**跨账号导入**时必须重算并同步改 `draft_media/<key>` 目录名；② AI 会话 `id`（时间戳+随机数）——冲突概率极低，重复时生成新 id 即可 | `DraftStore.ets` / `AiSession.ets` |
| 凭证域 | **排除在统一包之外**：凭证单独走 `.ngacred`（它需要服务端校验、单独密码、失败即无法登录，语义与"数据迁移"不同）。若产品坚持并入，必须**强制整包加密**且**默认不勾选** | `AuthApi.ets:229-269`、`AuthStore.ets:56-74`；并行设计已定 `DomainScope.SECRET` + `ExportPolicy.NEVER` + `ImportPolicy.NEVER`（`PersistenceCatalog.ets:31-41`），与本结论一致 |
| 跨账号导入 | 允许，但要求：① 导入面板显示"包内账号 uid"与"当前账号 uid"；② 按 uid 隔离的域（AI 会话、通知、历史等）默认**不覆盖**本机账号的 `uid` 字段，需重写为当前 uid（否则信封校验会整体丢弃，见 `CacheEnvelopeStore.ets:64-86`）；③ 草稿 key 重写 uid 段 | `CacheEnvelopeStore.ets:64-86` |
| 导入前的本机快照 | 建议导入前把受影响域导出到 `filesDir/import_backup/<ts>/`，失败可回滚（体积可控，仅整段 JSON） | — |
| 子集选择 | settings 域必须支持子项勾选（黑名单/关键词/备注/收藏/AI/显示/阅读），否则"导入设置"会把 AI 密钥也一起写 | §5.1 备注 |

### 5.5 安全考量

| 项 | 现状证据 | 建议 |
| --- | --- | --- |
| 凭证 | 本地 `auth`/`sessions` 明文含 cid（`AuthStore.ets:56-74`、`:145-147`）；HUKS 未使用 | **不导出凭证**；若必须，独立 `.ngacred` + 强制密码 + 服务端校验 |
| API Key | `SettingsState.aiProfiles[].apiKey` 明文入 `settings_<uid>`（`SettingsState.ets:57-58` + `AiConfig.ets:73`）；并行 Catalog 把 `settings` 设为 `INCLUDE`（`PersistenceCatalog.ets:43-47`），**密钥会随 settings 域进包** | **导出前从 settings payload 剥离 `apiKey`/`toolsApiKey`/`aiSearchProfiles[].apiKey`**；导入时若包内无该字段则保留本机值；未加密导出时二次确认 |
| AI 会话 | `AiSession.messages[].content` 全文 + `toolNotes`（`AiSession.ets:47-97`）；并行 Catalog 设为 `INCLUDE`（`PersistenceCatalog.ets:106-110`），即**默认勾选** | 改为 `OPTIONAL`（默认不勾选）；勾选时明示"包含你与 AI 的全部对话"；**加密导出为默认**（§5.2.3 D3） |
| 密码强度 | 最少 8 位（`Dialogs.ets:306`、`CredentialExportCrypto.ets:81`） | 建议 ≥ 10 位；提供"生成随机密码"；强度提示；**导出侧二次输入确认**（F3） |
| 密文参数可信度 | 解密信任文件内 `iterations`（`CredentialExportCrypto.ets:117`） | 校验 `kdf`/`cipher` 白名单 + `iterations` 区间（如 1e4~1e6）+ `salt/iv/tag/data` 的 base64 长度 |
| 路径穿越 | 存档已用 `isValidTid`（`SavedThreadStore.ets:38-49`）、草稿用 `isValidDraftKey`（`DraftStore.ets:70-84`）防守 | 统一服务对所有"由包内容决定文件名/目录名"的字段（tid、草稿 key、媒体文件名）**必须复用这两个校验**或同规则新写；不要把 `domain.name` 直接拼进路径 |
| 超大文件 / zip bomb | 现有导入无任何大小限制（L2、F6） | 三层限制：① `statSync` 文件大小上限，**统一按 `BACKUP_MAX_FILE_BYTES = 64MB`**（`PersistenceTypes.ets:122-123`，加密/明文同限）；② 域条目数上限（按 §5.1 表）；③ 解包后单域 data 字节上限；超限直接拒绝并给明确文案 |
| JSON 解析防护 | 现有直接 `JSON.parse` 全量字符串（`CredentialExportCrypto.ets:108`、`SavedThreadStore.ets:346`） | 解析包 try/catch；限制最大长度；对 `__proto__`/原型污染字段无需特别处理（ArkTS 无原型赋值/DOM），但要**逐字段类型校验**（`rawPages` 元素级，见 3.4） |
| 明文落盘风险 | 导出到用户选择的位置（可能云盘/共享目录） | 导出前明确告知"未加密文件包含你的浏览记录/AI 对话"；默认勾选加密；文件名不含敏感信息 |
| 日志泄漏 | 现有错误日志用 `formatError(e)`，不打印 payload | 统一服务禁止把 `apiKey`/`cid`/AI 正文写入日志与 Toast |
| 文件识别 | 现有 `isEncryptedCredentialExport` 只认 magic | 统一容器 magic 唯一、版本显式，导入端按 magic → version → 解密/明文 → 域校验顺序逐层拒绝 |
| 系统备份面 | `backup_config.json` = `allowToBackupRestore: true`，`onBackup/onRestore` 空实现 | 若统一导出包写入 `filesDir`，会被系统备份一起带走；建议导出物只落缓存或用户选择位置；换机语义见 §6.4 |

### 5.6 性能与内存

| 项 | 现状 | 建议 |
| --- | --- | --- |
| 导出峰值内存 | 全量对象 + `JSON.stringify` 字符串（L1） | 逐域 `JSON.stringify`（域内分片：存档按 tid 一批、AI 按会话一批），边拼边写临时文件；整体 payload 不驻留 |
| 加密内存 | 现有全量 `stringToUint8Array` + 一次 `update` | `Cipher.update` 分片（SDK `:2418-2419`）；分片大小 1~4MB；GCM 不要求分片对齐 |
| 主线程阻塞 | KDF + 加解密 + 大 JSON 全在 UI 线程（F9） | 用 `taskpool.execute`（工程已有用法：`service/api/ThreadApi.ets:28/264`、`parser/bbcode/BBCodeCache.ets:1/100-134`）；任务参数需可序列化（传 string/ArrayBuffer，不传类实例） |
| 导入进度 | 现有只有结尾 Toast（L3） | 进度浮层（自定义 dialog 显示"域/条目"进度 + 取消按钮）；批量写盘用 `SerialQueue`（`common/infra/SerialQueue.ets:5-29`）串行，避免并发 fs 写 |
| 大数据量 | `readTextSync` 全量（L2） | 导入分片：先 `statSync` → 若为明文 JSON 且 > 8MB，用 `readTextSync({offset, length})`（SDK `ReadTextOptions` `:5718`、`readTextSync` `:2974`）按块拼接；**或**改用"包内每域一条记录、按行分隔"的 JSONL 变体（实现简单，解析内存可控） |
| 文件大小估算 | 无 | 导出面板按"域条目数 × 平均大小"估算（存档可用 `SavedThreadStore.getAll()` + 各文件 `statSync` 累计） |
| 批量 bump | 存档导入已做"循环后统一 bump"（`SavedThreadStore.ets:373-374`） | 统一服务沿用：**每个域导入完成 bump 一次**，不要每条 bump |

### 5.7 失败恢复

| 阶段 | 现状 | 建议 |
| --- | --- | --- |
| 导出写文件 | 存档导出用 `try/finally` 关闭；（凭证导出无 finally，F1） | 统一 `writeFileAtomic`（C6）：写 `.tmp` → fsync 语义由 `renameSync` 保证 → 失败 `unlinkSync` 清理 → 成功后可选再读校验 checksum |
| 导出中断 | picker 已预创建文件，可能残留 0 字节 | 同上：失败清理；成功后才告知用户 |
| 导入解析失败 | 整体 error，不落任何数据（安全） | 保持"**先完整解析校验，再落盘**"：容器解析 + 每域 schema 校验全部通过才进入 apply 阶段 |
| 导入中途失败 | 现有逐条 try/catch = 部分成功，无回滚（L5） | 版本一：按域**事务化**——先把该域全部 item 校验通过、写入临时文件/临时 key，再一次性切换（存档可行：全部 tmp 写完后逐个 rename；prefs 域可行：一次 `putJSON` 写入合并结果）；导入前快照旧值（§5.4）支持整域回滚 |
| 幂等重入 | 重复导入同文件 = 幂等覆盖 | 保持：以"域 + 冲突键"为幂等键；中途失败后重跑同一文件应能达到同一结果 |
| 版本不兼容 | 现有严格相等（`SavedThreadStore.ets:351-354`、`CredentialExportCrypto.ets:109-111`） | 容器 `formatVersion` 主版本不兼容 → 拒绝并提示"请升级 App"；域 `schemaVersion` 低于当前 → 走迁移函数表（每域 `migrate(data, from, to)`）；高于当前 → 拒绝该域但允许导入其余域 |
| 回滚 | 无 | 提供"导入前自动备份到 `filesDir/import_backup/<ts>/`"，结果页给"撤销本次导入"入口（限本次会话） |

---

## 6. 风险与未决问题

### 6.1 权限与合规

- **权限**：现有两条链路均未申请任何文件权限；picker 走系统 UI 授权（`@ohos.file.picker.d.ts` 全文无 `@permission`；`module.json5:15-28` 仅 4 个权限）。统一导出/导入沿用 picker 即**不需要新增权限**；若改用"固定目录自动备份"（如 `filesDir` 下的自动备份），同样不需要权限，但系统备份会带走（见 6.4）。
- **`fileSuffixChoices` / `fileSuffixFilters` 语义**（`@ohos.file.picker.d.ts:432-451`、`:584-595`）：每项 `描述|后缀`，多个后缀可逗号分隔；`save` 的 `pickerMode=DOWNLOAD` 时 `newFileNames`/`fileSuffixChoices` 不生效（`:599-600`）。统一服务应显式设 `pickerMode: DEFAULT`（或省略）并在导入侧设 `fileSuffixFilters`（现有存档导入没设，L9）。
- **`maxSelectNumber`**：SDK 声明 API 20 及以前上限 500，API 21+ 不再限制但"过多文件可能异常/性能差"，建议 ≤10000（`@ohos.file.picker.d.ts:455-465`）。本工程存档导入自设 50（`FavoriteSavedPanel.ets:54`）。统一包设计为单文件，因此导入只需 `maxSelectNumber = 1`（凭证导入即如此，`LoginPage.ets:450`）。
- **`autoCreateEmptyFile`**：默认 `true`（`@ohos.file.picker.d.ts:607-617`），意味着 picker 会预创建空文件并返回 URI——这解释了为什么 `SettingsPanel.ets:350` 只开 `READ_WRITE` 也能写。统一服务的"写失败清理"必须考虑预创建文件（F1）。
- **合规**：数据导出涉及个人信息（浏览记录、AI 对话、黑名单），需在隐私政策中声明"用户可导出/导入自己的数据"；AI 对话可能含第三方版权内容。

### 6.2 应用市场审核（**待确认**）

- 华为应用市场对"用户数据导出/明文文件"是否有额外审核要求（如敏感数据外发需声明）——**待确认**，建议提审前查最新《应用审核指南》。
- 导出文件若含 API Key（第三方付费密钥），可能被视为"凭据外泄风险"，审核未必关注，但**产品上应默认排除**。

### 6.3 跨版本兼容

- 现有两套格式都**没有迁移路径**：`.ngacred` v1→v2 直接不兼容（`CredentialExportCrypto.ets:109-111`）；存档 v1→v2 直接拒绝（`SavedThreadStore.ets:351-354`）。统一容器第一版就应把"主版本严格 + 域迁移表"写进契约，否则下一次结构演进会再次断代。
- 旧 `.json` 存档（`SavedThreadExportFile` v2）与旧 `.ngacred` 应继续可导入（作为"统一服务的兼容入口"），否则用户升级后旧导出文件作废。
- `settings_<uid>` 的字段只增不减（`SettingsState` 逐字段 `load`），无版本号——统一服务导入设置时需要"字段白名单 + 缺省值"策略，**不要整对象覆盖**（会丢新版本默认值/新字段）。

### 6.4 设备迁移（换机）场景

- 现状：`backup_config.json` 允许系统备份/恢复（`"allowToBackupRestore": true`），`EntryBackupAbility` 只打日志（`EntryBackupAbility.ets:6-16`）——即**系统备份走默认整目录备份**，应用没有自定义备份逻辑，也没有"恢复后校验/迁移"钩子。
- 统一导出/导入应定位为"**手动迁移**"：新机安装 → 登录（或导入凭证）→ 导入统一包。要处理：
  - 新机未登录时导入：按 uid 隔离的域应先登录或要求包内 uid 与登录 uid 一致（否则信封校验丢弃，§5.4）；
  - 凭证迁移顺序：先 `.ngacred` 登录，再导入数据包（因为 `appStore.setAuth` 会触发 `loadUserData` 重载，`AppStore.ets:521-533`）；
  - 存储分区：导出/导入不涉及 `EL1/EL2` 切换（草稿媒体在 `filesDir`，`SettingsPanel.clearCache` 才切分区，`SettingsPanel.ets:255-275`）。
- 系统备份与统一包**并存**时可能重复：建议明确"系统备份负责换机、统一包负责用户主动迁移"，文档中不要承诺系统备份可迁移凭证（当前 `onBackup` 空实现）。

### 6.5 隐私

- **AI 会话**是最大隐私面：`AiSession.messages[].content` 全部对话正文 + `toolNotes` 工具调用摘要（`AiSession.ets:41-97`）；导出文件即使用户自选位置，也容易进云盘/相册/微信。
- **AI 工具缓存**含帖子正文与搜索结果（`AiToolCacheStore.ets:1-20`），且体积上限 1.2M 字符——若纳入导出，属于"可重建但泄漏面大"的数据，建议默认排除。
- **草稿**是"未发布内容"，可能含敏感表达；草稿媒体（`draft_media`）含图片/视频，体积 128MB 级（`DraftMediaStore.ets:69`）——默认不导出媒体，或提供"仅正文"选项。
- **浏览历史 + 阅读进度**可推断用户兴趣画像，导出明文时应有提示。

---

## 7. 待确认清单（需产品/实测确认）

| # | 问题 | 影响 |
| --- | --- | --- |
| Q1 | 统一包是否必须支持"未加密导出"？若支持，默认值应是加密还是明文？ | 决定导出 UI 默认与合规口径 |
| Q2 | 是否允许跨账号导入（uid 不同）？允许的话哪些域可跨？ | 决定 §5.4 的 uid 重写与冲突策略 |
| Q3 | AI 会话 / API Key 是否允许出现在导出包内（默认勾选与否）？ | 隐私面最大的两个决策 |
| Q4 | 凭证是否并入统一包，还是保持独立 `.ngacred`？ | 直接影响容器是否需要"强制加密"分支 |
| Q5 | 导出文件的保存位置：picker 用户选（现状）还是应用自动目录 + 分享？ | 决定是否需要 C14 分享能力与"自动清理" |
| Q6 | 导入后是否提供"撤销"（导入前快照）？ | 决定 §5.7 的实现量 |
| Q7 | `taskpool` 传递大 `ArrayBuffer`/string 的开销与限制（是否复制、是否有大小上限） | 决定加密/解析是否可放后台线程【待确认 SDK 声明】 |
| Q8 | `fileIo.readTextSync(uri)` 对 picker 返回 URI 的支持是否在所有设备/API 上稳定（SDK 声明未明说，工程注释断言支持） | 导入读取实现方式（现成 vs 自行 readSync）【待确认】 |
| Q9 | `SettingsState` 中 `aiProfiles` 的 apiKey 是否有"不出现在导出包"的既定产品要求（AI 设置页是否已有脱敏约定） | 决定导出时是否需要脱敏显示 |
| Q10 | 华为审核对"明文导出用户数据"的要求 | 合规风险【待确认】 |
| Q11 | 系统备份（`allowToBackupRestore`）当前实际备份哪些目录、换机是否恢复 `filesDir` | 决定"系统备份 vs 统一包"的边界【待确认】 |
| Q12 | AI 工具缓存（`ai_tool_cache_<uid>`）是否应纳入导出（可重建、体积大） | 默认勾选决策 |
| Q13 | 草稿媒体的导出形态：内嵌 base64（包体积大）还是 zip 内文件（需引入解压） | 容器 v1 是否支持二进制域 |
| Q14 | `PersistenceCatalog` 当前 `ai_sessions=INCLUDE`、`draft_media=INCLUDE`、`settings` 含 AI 密钥：是否按 §5.2.3 D2/D3/D4 调整策略？（**需产品拍板**） | 直接影响默认勾选与隐私/体积合规 |
| Q15 | 设计文档 §6.3 的 `picker.DocumentSavePicker` 是笔误还是计划中的新 API？（SDK `@ohos.file.picker.d.ts` 只有 `DocumentViewPicker`） | 【待确认】影响实现落地 |
| Q16 | 口令最短 8 位是否提高（设计文档 §6.2 定 8 位，本文建议 ≥10 + 二次确认 + 强度提示） | 安全强度 vs 易用性 |

---

## 附录 A：证据索引

### A.1 工程代码（关键符号 / 行号）

| 主题 | 位置 |
| --- | --- |
| 凭证容器常量与实现 | `entry/src/main/ets/common/security/CredentialExportCrypto.ets:5-12`、`:71-134` |
| 凭证导出 UI | `entry/src/main/ets/pages/SettingsPanel.ets:121-134`、`:302-357`、`:697-735` |
| 凭证导入 UI | `entry/src/main/ets/pages/LoginPage.ets:92-105`、`:235-247`、`:443-520` |
| 密码输入组件 | `entry/src/main/ets/common/dialogs/Dialogs.ets:291-385` |
| 凭证服务端校验/注入 | `entry/src/main/ets/service/api/AuthApi.ets:201-269` |
| 会话/凭证落盘 | `entry/src/main/ets/store/AuthStore.ets:56-74`、`:95-112`、`:145-147`、`:291` |
| 登录后全量重载 | `entry/src/main/ets/store/AppStore.ets:493-505`、`:521-562` |
| 离线存档模型 | `entry/src/main/ets/model/SavedThread.ets:16-61` |
| 离线存档存储/导出入 | `entry/src/main/ets/store/SavedThreadStore.ets:38-49`、`:87-134`、`:205-258`、`:321-390` |
| 离线存档 UI | `entry/src/main/ets/pages/FavoriteSavedPanel.ets:54`、`:114-116`、`:762-772`、`:798-909`、`:1170-1191` |
| 原子写（草稿） | `entry/src/main/ets/common/managers/DraftStore.ets:338-376` |
| 草稿模型/键规则 | `entry/src/main/ets/common/managers/DraftStore.ets:39-59`、`:100-169` |
| 草稿媒体 | `entry/src/main/ets/common/media/DraftMediaStore.ets:37-69`、`:211` |
| 偏好存储 | `entry/src/main/ets/common/infra/PreferencesStore.ets:11-82` |
| 缓存信封 | `entry/src/main/ets/common/infra/CacheEnvelopeStore.ets:7-176` |
| 串行写队列 | `entry/src/main/ets/common/infra/SerialQueue.ets:5-29` |
| 版本号刷新 | `entry/src/main/ets/common/utils/AppStorageVersion.ets:8-12`；`common/constants/AppStorageKeys.ets:1-148` |
| Toast | `entry/src/main/ets/store/AppStore.ets:849`；`common/feedback/ToastManager.ets:125-127` |
| 键盘沉浸（密码框限制） | `entry/src/main/ets/common/utils/KeyboardAppearanceUtils.ets:1-87` |
| 目录递归删除 | `entry/src/main/ets/common/utils/FileUtils.ets:27-50` |
| 编解码 | `entry/src/main/ets/common/utils/CodecUtils.ets:23-36` |
| 系统备份 | `entry/src/main/ets/entrybackupability/EntryBackupAbility.ets:6-16`；`entry/src/main/resources/base/profile/backup_config.json:1-3` |
| 权限 | `entry/src/main/module.json5:15-28`、`:66-79` |
| 分享能力 | `entry/src/main/ets/common/utils/ShareUtils.ets:1-33`；`common/components/ImageViewer.ets:355-381` |
| taskpool 既有用法 | `entry/src/main/ets/service/api/ThreadApi.ets:28`、`:264`；`common/parser/bbcode/BBCodeCache.ets:1`、`:100-134` |
| **并行改造（未提交，供对齐）**：域类型/枚举/容器常量 | `entry/src/main/ets/common/persistence/PersistenceTypes.ets:9-129`（`StorageKind`/`DomainScope`/`ExportPolicy`/`ImportPolicy`、`BACKUP_MAGIC` 等） |
| **并行改造（未提交）**：域注册表（20 域） | `entry/src/main/ets/common/persistence/PersistenceCatalog.ets:29-144`（`buildSpecs`）、`:151-334`（查询）、`:337-359`（`DomainIds`） |
| **并行改造（未提交）**：持久化新键 `deleteKey/hasKey/getAll` | `entry/src/main/ets/common/infra/PreferencesStore.ets:76-129`（工作区改动，未提交） |
| **并行改造（未提交）**：设计文档 §6 导出/导入 | `docs/PERSISTENCE_UNIFICATION_DESIGN.md:644-788`（6.1 容器 / 6.2 口令 / 6.3 选择性导出 / 6.4 合并语义 / 6.5 兼容 / 6.6 安全 / 6.7 UI） |
| **并行改造（未提交）**：数据域盘点 | `docs/research/PERSISTENCE_INVENTORY.md` |

### A.2 SDK 声明（`sdk/default/openharmony/ets/api/`）

| 主题 | 声明位置 |
| --- | --- |
| Picker 命名空间（须在 UIAbility 内调用） | `@ohos.file.picker.d.ts:21-34` |
| `DocumentSelectOptions` / `fileSuffixFilters` / `maxSelectNumber` | `@ohos.file.picker.d.ts:412-471`、`:432-451`、`:455-465` |
| `DocumentSelectMode` / `DocumentPickerMode` | `@ohos.file.picker.d.ts:307`、`:342-361` |
| `DocumentSaveOptions` / `newFileNames` / `fileSuffixChoices` / `pickerMode` / `autoCreateEmptyFile` | `@ohos.file.picker.d.ts:564-618` |
| `DocumentViewPicker` 构造与 `select` / `save` | `@ohos.file.picker.d.ts:628-748` |
| `getSelectedIndex`（fileSuffixChoices 联动） | `@ohos.file.picker.d.ts:749-770` |
| `OpenMode` 常量 | `@ohos.file.fs.d.ts:136-173` |
| `accessSync` / `listFileSync` / `mkdirSync` | `@ohos.file.fs.d.ts:336`、`:1637`、`:1890-1918` |
| `openSync`（含错误码表） | `@ohos.file.fs.d.ts:2595-2634` |
| `readSync` / `readTextSync` / `ReadTextOptions` | `@ohos.file.fs.d.ts:2744`、`:2974`、`:5718` |
| `renameSync`（原子替换） | `@ohos.file.fs.d.ts:3078` |
| `statSync` | `@ohos.file.fs.d.ts:3235` |
| `unlinkSync` | `@ohos.file.fs.d.ts:3506` |
| `writeSync` | `@ohos.file.fs.d.ts:3651` |
| GCM 参数（iv/aad/authTag 长度约束） | `@ohos.security.cryptoFramework.d.ts:251-290` |
| GCM `doFinal` 输出语义（tag 为末 16 字节；null 输入返回 tag；结果可能为 null） | `@ohos.security.cryptoFramework.d.ts:2751-2796`、`:2912-2942` |
| PBKDF2 参数 | `@ohos.security.cryptoFramework.d.ts:5906-5975` |
| `createKdf`（支持 PBKDF2/HKDF/SCRYPT/X963KDF） | `@ohos.security.cryptoFramework.d.ts:6251-6274` |
| `createCipher`（transformation 语义、填充说明） | `@ohos.security.cryptoFramework.d.ts:3022-3061` |
| `createSymKeyGenerator` | `@ohos.security.cryptoFramework.d.ts:1669` |
| `createRandom` / `generateRandomSync`（CTR_DRBG；建议放子线程） | `@ohos.security.cryptoFramework.d.ts:1047-1126`、`:1102`、`:1052-1054` |
| `createMd` / `Md.digest`（checksum 用） | `@ohos.security.cryptoFramework.d.ts:2028-2215`、`:2141` |
| `getUriFromPath` | `@ohos.file.fileuri.d.ts:162` |

### A.3 本次 grep 清单与结论

| 模式 | 命中 | 结论 |
| --- | --- | --- |
| `picker.` / `DocumentViewPicker` / `DocumentSaveOptions` | `SettingsPanel.ets:338-342`、`FavoriteSavedPanel.ets:811-865`、`LoginPage.ets:449-454` | 三处 picker 用法，可抽公共模块（C3） |
| `fileIo.openSync` | 8 处（见 §1.2） | 导出/导入链路 4 处，写法分"带 finally"与"裸写"两派 |
| `cryptoFramework` | `CredentialExportCrypto.ets:1-134`、`NgaRsaCipher.ets:1-60` | 仅凭证导出做对称加密；RSA 仅登录参数加密 |
| `huks` | **0 命中** | 本地无 HUKS 加密；导出加密是传输层保护 |
| `getUriFromPath` | `ImageViewer.ets:269/271/362` | 沙箱路径→media URI，供分享/相册；统一导出分享可复用 |
| `share` | `ShareUtils.ets:1-77`、`ImageViewer.ets:366-381`（`@kit.ShareKit` 的 `systemShare`） | 无"文件分享"用法，需新增 `fileUri.getUriFromPath` + `SharedData` |
