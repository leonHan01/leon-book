# leon-book for macOS

[English](README.md) | [简体中文](README.zh-CN.md)

本目录包含 `leon-book` 的原生 macOS 实现。应用使用 SwiftUI 提供窗口、菜单、导航、阅读、写作和设置界面，不使用 Safari、Chrome 或 WKWebView。

文章、草稿、设置、图片和视频都保存在本地。SQLite 负责管理结构化数据，Markdown/JSON 导出文件和媒体文件继续保存在本地文件系统中。应用不会启动 Node.js、浏览器或本地 HTTP 服务。

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

检查脚本会构建并运行原生检查，不会打开应用窗口。

## 数据目录

应用按以下顺序选择数据目录：

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog`（目录存在时）
3. `~/Library/Application Support/leon-book/`

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
