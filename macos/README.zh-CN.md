# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

本目录包含 `leon-book` 的原生 macOS 实现。应用使用 SwiftUI 提供窗口、菜单、导航、阅读、写作和设置界面；文章网页嵌入使用系统 WebKit，不会启动 Safari 或 Chrome。

文章、草稿、设置、图片和视频都保存在本地。SQLite 负责管理结构化数据，Markdown/JSON 导出文件和媒体文件继续保存在本地文件系统中。应用不会启动 Node.js、外部浏览器或本地 HTTP 服务。

## 构建与运行

系统要求：macOS 13 或更高版本，以及 Swift 5.10 或更高版本。请在项目根目录使用管理脚本：

```bash
./scripts/leonblog build
./scripts/leonblog open
```

构建后的应用位于 `macos/dist/leon-book.app`，使用临时签名，适合本机运行。

如需直接运行 SwiftPM 可执行文件：

```bash
swift run --package-path macos LeonBook
```

`LeonBook` 是当前 SwiftPM target 的内部名称；应用对外显示名称为 `leon-book`。

## 检查

```bash
./scripts/leonblog test
```

检查脚本会构建并运行原生单元测试和检查，不会打开应用窗口。

## 在文章中嵌入网页

文章 Markdown 支持把远程 HTTP(S) 网页直接嵌入正文。可以使用专用的 `embed` 代码块：

```embed
https://example.com
```

也可以直接粘贴独立的 iframe：

```html
<iframe src="https://example.com" title="Example" height="520"></iframe>
```

只接受 `http` 和 `https` 地址。内嵌网页可以直接交互，也可以点击“在浏览器中打开”使用外部浏览器。

## 在文章中插入 HTML 组件

使用专用的 `html-render` 代码块，可以在文章和写作实时预览中直接运行 HTML、CSS 和 JavaScript：

````markdown
```html-render height=360
<div style="padding: 20px; background: #2563eb; color: white">
  <h2>自定义组件</h2>
  <button onclick="this.textContent = '已点击'">点击</button>
</div>
```
````

`height` 可省略，默认值为 360，允许范围为 160–1200。普通的 `html` 代码块仍只展示源码，不会执行。HTML 组件使用独立的临时 WebKit 数据空间，点击其中的 HTTP(S) 链接会交给外部浏览器打开。请只运行自己信任的 HTML 和 JavaScript。

## 数据目录

应用按以下顺序选择数据目录：

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog/`

默认使用 `/Volumes/T7Shield/myblog/`；如果该目录不可用，首次进入应用时会要求选择工作目录并记住选择。如需使用其他目录，请设置 `LEON_BOOK_WORKDIR`。

默认用户为 `leon`。每位用户都有独立的 `workspaces/<user-id>` 目录。升级到多用户结构时，根目录中已有的文章、草稿、媒体、动态和活动记录会自动迁移到 `leon` 工作空间。首次启动时，已有 JSON 数据会自动导入工作空间的 SQLite 数据库。

如果安装了多个 macOS SDK，可以使用 `LEON_BOOK_SDK_PATH` 指定打包所用的 SDK：

```bash
LEON_BOOK_SDK_PATH=/path/to/MacOSX.sdk ./scripts/leonblog build
```

## 目录结构

```text
macos/
├── Sources/LeonBook/         # SwiftUI 应用源码
├── Checks/LeonBookChecks/    # 原生检查
├── Resources/Info.plist     # 应用元数据
└── scripts/                 # 构建和检查脚本
```
