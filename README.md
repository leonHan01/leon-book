# Notebook 36

Notebook 36 是一个纯原生的 macOS 写作应用。文章、草稿、图片、视频和创作活动都只保存在本机；项目不包含浏览器界面、Node.js 服务或 HTTP API。

## 打开应用

```bash
leonblog open
```

`leonblog start` 是 `open` 的别名。若尚未构建应用，命令会自动构建后打开。

## 本地数据

已有 `/Volumes/T7Shield/myblog` 目录时，应用会继续读取其中的文章和媒体。否则使用：

```text
~/Library/Application Support/Notebook 36/
├── users.json          # 本机用户清单（初始用户为 leon）
├── active-user.json    # 最近使用的用户
└── workspaces/
    └── <user-id>/      # 每位用户独立的工作空间
        ├── articles/   # 文章 JSON、Markdown 与索引
        ├── drafts/     # 草稿恢复副本
        ├── media/      # 图片与视频原文件
        ├── moments/    # 图文微博与瀑布流索引
        └── activity/   # 最近一年的创作活动
```

首次升级时，根目录中已有的文章、草稿、媒体、微博和活动记录会自动迁入 `leon` 的工作空间。可通过 `NOTEBOOK36_WORKDIR` 指定其他数据目录。删除应用不会删除这些内容；请按普通本地文件备份。

## 原生开发与检查

```bash
leonblog build
leonblog test
```

需要 macOS 13+ 与 Swift 5.10+。更多原生构建说明见 [macos/README.md](macos/README.md)。
