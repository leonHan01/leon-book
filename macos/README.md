# Notebook 36 for macOS

这是 Notebook 36 的原生 macOS 应用。它使用 SwiftUI 提供窗口、菜单、导航、文章阅读、写作和设置，不使用 Safari、Chrome 或 WKWebView；文章、设置、图片和视频只保存在这台 Mac。

## 构建

需要 macOS 13 或更高版本以及 Swift 5.10 或更高版本。完整 Xcode 不是本地调试构建的必要条件。

```bash
leonblog build
leonblog open
```

应用直接使用 Swift `FileManager` 读写本机文件，不启动 Node.js、浏览器或本地 HTTP 服务。应用默认创建 `leon` 用户，每个用户都存放在独立的 `workspaces/<user-id>` 目录中。首次升级时，已有的本地内容会自动迁入 `leon` 的工作空间。现有内容继续从 `/Volumes/T7Shield/myblog` 读取；该目录不存在时才使用 `~/Library/Application Support/Notebook 36`。

如果机器上安装了多份 macOS SDK，可以用 `NOTEBOOK36_SDK_PATH` 指定打包所用 SDK。调试可执行文件：

```bash
swift run --package-path macos Notebook36
```

## 验证

```bash
leonblog test
```

`macos/dist/Notebook 36.app` 使用临时签名，适合本机运行。应用不依赖项目目录、Node.js 或网页服务；数据目录会按优先级读取 `NOTEBOOK36_WORKDIR`、现有的 `/Volumes/T7Shield/myblog`，最后回退到应用支持目录。
