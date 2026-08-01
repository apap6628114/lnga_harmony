<div align="center">
  <img src="AppScope/resources/base/media/foreground.png" alt="LNGA Logo" width="120" height="120">
  <h1>LNGA</h1>
  <p><strong>NGA 玩家社区 · 鸿蒙原生客户端</strong></p>
  <p>
    <img src="https://img.shields.io/badge/HarmonyOS-6.1.0(23)-0078D7?style=flat-square">
    <img src="https://img.shields.io/badge/ArkUI-%F0%9F%93%B1-ff69b4?style=flat-square">
    <img src="https://img.shields.io/badge/API-23-brightgreen?style=flat-square">
    <img src="https://img.shields.io/badge/license-GPL--2.0-blue?style=flat-square">
  </p>
</div>

---

> ## ⚠️ 安装须知
>
> **HarmonyOS 不能直接安装 .hap 文件包**。你需要使用签名工具对 HAP 进行签名后才能安装到手机上。
>
> 推荐使用 **小白调试助手（Auto-Installer）**：
> - 📖 [使用教程视频（B站）](https://www.bilibili.com/video/BV1K6daBrENN)
> - ⬇️ [下载地址（GitHub Releases）](https://github.com/likuai2010/auto-installer/releases/tag/3.1.0)
>
> 该工具支持 Windows / macOS / Linux，可自动完成签名并安装，无需 DevEco Studio。
>
> 从本仓库 Releases 下载的 HAP 均为**未签名包**，请使用上述工具自行签名后安装。

---

## 简介

**LNGA** 是基于 **HarmonyOS** 原生框架 **ArkUI (ArkTS)** 构建的 [NGA 玩家社区](https://nga.cn) 客户端。致力于在鸿蒙生态中提供流畅、原生的 NGA 论坛浏览与交互体验。

项目完整覆盖了 NGA 论坛的核心功能：板块浏览、帖子阅读、发帖回复、私信聊天、通知推送、AI 内容总结等，并针对手机、平板、二合一设备做了自适应布局适配。

---

## 功能特性

### 论坛浏览
- **板块列表** — 网格视图展示全部分区，支持收藏排序
- **帖子列表** — 分页加载，支持筛选（精华/收藏/作者）
- **帖子详情** — 楼层分页浏览，引用折叠，图片查看，热门回复
- **BBCode 渲染** — 完整解析 NGA 论坛 BBCode（引用、图片、表情、格式、表格、骰子、列表等）
- **HTML 降级解析** — JSON API 不可用时自动切换 HTML 解析
- **表情显示** — 内置 6 套 NGA 表情包（a2/ac/dt/ng/pg/pst）

### 用户系统
- **登录认证** — RSA 加密密码登录、Web 端登录，验证码支持
- **凭证导入/导出** — 支持从文件导入导出 NGA 登录凭证
- **用户主页** — 声望、勋章、管理版块、发帖统计
- **用户卡片** — 悬停/点击查看用户信息

### 互动功能
- **发帖/回复** — BBCode 快捷工具栏，引用回复，附件上传，编辑回复
- **私信系统** — 会话列表，消息详情
- **通知中心** — 回复提醒、点赞通知、系统消息
- **投票** — 投票记录缓存
- **分享** — 帖子/主题分享

### 内容管理
- **收藏管理** — 收藏主题/版块
- **黑名单** — 用户黑名单管理
- **关键词过滤** — 自定义屏蔽关键词
- **用户备注** — 为用户添加备注标签
- **浏览历史** — 本地持久化浏览记录
- **签名控制** — 帖子中签名展开/折叠切换

### 界面与体验
- **自适应布局** — 手机/平板/二合一设备三档自适应（sm/md/lg breakpoints）
- **深色模式** — 支持浅色/深色/跟随系统主题切换
- **举手持/单手模式** — 基于运动传感器的一手操作优化
- **图片查看器** — 全屏手势缩放浏览
- **音频/视频播放** — 内置音视频播放与自适应检测
- **WebView** — 内嵌网页浏览
- **图片加载控制** — 可选择隐藏加载失败的图片

### AI 功能
- **通用 AI 对话** — ChatGPT 式流式聊天界面，支持多轮对话与中断
- **帖子内容分析** — 一键将帖子内容送入 AI 对话，自动注入上下文
- **用户行为分析** — 将用户发帖数据送入 AI 对话，分析时段分布、版块偏好
- **多服务商支持** — 内置 DeepSeek、智谱 GLM、豆包、MiniMax、Kimi、OpenAI 6 个预设 + 自定义服务商
- **AI 配置管理** — 创建/编辑/删除配置、测试连接、获取模型列表
- **场景化提示词定制** — 为帖子总结、用户分析等场景自定义 system prompt
- **流式 Markdown 渲染** — AI 输出的 Markdown 增量实时渲染

### 其他高级功能
- **全局搜索** — 帖子/主题搜索
- **自动签到** — 每日自动完成论坛签到
- **域名切换** — NGA 多域名自动切换与故障转移
- **请求限流** — 按域名的请求频率控制
- **语音朗读** — 基于 Core Speech Kit 的帖子内容语音播报，超长文本自动分段接力播放



## 快速开始

### 环境要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/) 5.0+
- HarmonyOS SDK 6.1.0 (API 23)
- Node.js 20+

### 构建运行

```bash
# 克隆仓库
git clone https://github.com/<your-username>/nga_oh.git

# 使用 DevEco Studio 打开项目根目录

# 构建 debug HAP
hvigorw assembleHap --mode debug

# 构建 release HAP
hvigorw assembleHap --mode release
```

> 也可直接在 DevEco Studio 中点击 `Run` 按钮部署到真机或模拟器。

### 权限说明

应用需要以下权限：

- `ohos.permission.INTERNET` — 网络访问，用于 NGA API 通信
- `ohos.permission.DETECT_GESTURE` — 手势检测，用于图片查看器等交互

入口文件：`entry/src/main/module.json5:15:22`

---

## 预览

**手机竖屏 (1008×2232)**

<img src="img/Screenshot_2026-05-31T204948.png" alt="手机截图 1" width="200">
<br>&nbsp;<br>
<img src="img/Screenshot_2026-05-31T205112.png" alt="手机截图 2" width="200">
<br>&nbsp;<br>
<img src="img/Screenshot_2026-05-31T205148.png" alt="手机截图 3" width="200">

**平板竖屏 (2048×2232)**

<img src="img/Screenshot_2026-05-31T205017.png" alt="平板竖屏截图 1" width="260">
<br>&nbsp;<br>
<img src="img/Screenshot_2026-05-31T205030.png" alt="平板竖屏截图 2" width="260">

**平板横屏 (3184×2232)**

<img src="img/Screenshot_2026-05-31T205043.png" alt="平板横屏截图 1" width="360">
<br>&nbsp;<br>
<img src="img/Screenshot_2026-05-31T205051.png" alt="平板横屏截图 2" width="360">


## 致谢

- [NGA 玩家社区](https://nga.cn) — 国内领先的游戏综合讨论社区
- [Justwen/NGA-CLIENT-VER-OPEN-SOURCE](https://github.com/Justwen/NGA-CLIENT-VER-OPEN-SOURCE) — Android 端开源参考实现

---

## 许可证

GNU General Public License v2.0 — 详见 [LICENSE](LICENSE)

---

<p align="center">
  用 ❤️ 和 ArkUI 构建 · 鸿蒙原生体验
</p>
