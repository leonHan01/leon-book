# leon-book

[English](README.md) | [简体中文](README.zh-CN.md)

`leon-book` 是一款原生 macOS 写作应用，用于管理文章、草稿、图片、视频、动态和创作活动。

应用使用 SwiftUI 构建，数据直接保存到本地文件系统，不依赖浏览器、Node.js 服务或 HTTP API。

## 功能

- 阅读、编辑和发布文章
- 本地保存草稿，支持多用户独立工作空间
- 管理图片和视频素材
- 发布图文动态并浏览时间线
- 查看最近编辑记录和年度创作活动
- 支持离线使用，用户完全掌控本地数据

## 系统要求

- macOS 13 或更高版本
- Swift 5.10 或更高版本

本地构建和检查不要求安装完整的 Xcode。

## 使用命令

在项目根目录执行以下命令：

```bash
./scripts/leonblog open
```

当应用不存在或版本过期时，`open` 会先构建应用，然后打开 `leon-book`。其他可用命令如下：

```bash
./scripts/leonblog start   # open 的别名
./scripts/leonblog build   # 构建 macOS 应用
./scripts/leonblog test    # 运行原生检查
./scripts/leonblog help    # 显示命令帮助
```

构建后的应用位于：

```text
macos/dist/leon-book.app
```

## 本地数据

默认数据目录为：

```text
~/Library/Application Support/leon-book/
├── users.json          # 本机用户清单
├── active-user.json    # 最近使用的用户
└── workspaces/
    └── <user-id>/      # 每位用户独立的工作空间
        ├── articles/   # 文章 JSON、Markdown 和索引
        ├── drafts/     # 草稿恢复副本
        ├── media/      # 图片和视频原文件
        ├── moments/    # 动态数据和时间线索引
        └── activity/   # 创作活动记录
```

应用按以下顺序选择数据目录：

1. `LEON_BOOK_WORKDIR`
2. `NOTEBOOK36_WORKDIR`（旧配置兼容）
3. `/Volumes/T7Shield/myblog`（目录存在时）
4. `~/Library/Application Support/Notebook 36/`（旧版应用目录存在时）
5. `~/Library/Application Support/leon-book/`

首次初始化多用户结构时，根目录中已有的文章、草稿、媒体、动态和活动记录会自动迁移到默认的 `leon` 工作空间。卸载应用不会删除本地数据，请像备份普通文件一样备份该目录。

## 开发说明

macOS 原生源码、资源和检查脚本位于 [`macos/`](macos/)。更多构建、调试和数据目录说明见 [`macos/README.md`](macos/README.md)。

如需直接运行 SwiftPM 可执行文件：

```bash
swift run --package-path macos Notebook36
```

## 设计原则

`leon-book` 优先保证本地可用、数据透明和界面响应。文章和媒体都以普通本地文件保存，用户可以使用 Finder、备份工具或版本控制工具管理自己的内容。
