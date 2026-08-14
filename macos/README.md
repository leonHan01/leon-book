# Notebook 36 for macOS

这是 Notebook 36 的原生 macOS 容器。它使用 SwiftUI 提供窗口、菜单、导航与设置，使用系统 WebKit 加载本机站点；文章、设置、图片和视频只保存在这台 Mac。

## 构建

需要 macOS 13 或更高版本以及 Swift 5.10 或更高版本。完整 Xcode 不是本地调试构建的必要条件。

```bash
npm run macos:build
open "macos/dist/Notebook 36.app"
```

应用默认打开 `http://localhost:3000`，并自动启动项目中的本机网页和文件存储服务。现有内容继续从 `/Volumes/T7Shield/myblog` 读取；该目录不存在时才使用 `~/Library/Application Support/Notebook 36`。

也可以在应用的“设置”中保存其他 localhost 端口，或在打包时写入默认地址：

```bash
NOTEBOOK36_DEFAULT_URL="http://localhost:5173" npm run macos:build
```

如果机器上安装了多份 macOS SDK，可以用 `NOTEBOOK36_SDK_PATH` 指定打包所用 SDK。

调试可执行文件也接受环境变量或命令行参数：

```bash
NOTEBOOK36_URL="http://localhost:5173" swift run --package-path macos Notebook36
swift run --package-path macos Notebook36 --url "http://localhost:5173"
```

## 验证

```bash
npm run macos:test
```

`macos/dist/Notebook 36.app` 使用临时签名，适合本机运行。它会记录当前项目路径，并使用已安装的 Node.js 启动本地服务；移动项目后需要重新构建应用。
