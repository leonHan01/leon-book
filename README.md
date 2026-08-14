# Notebook 36

一个只在本机运行和保存内容的个人出版应用。公开阅读、文章写作、站点设置、图片与视频上传都通过本机服务完成，不连接 Cloudflare 或其他云端存储。

## 数据位置

这台 Mac 已有数据时继续使用 `/Volumes/T7Shield/myblog`。如果该目录不存在，则使用：

```text
~/Library/Application Support/Notebook 36/
├── articles/   # 文章 JSON、Markdown 与索引
├── drafts/     # 草稿恢复副本
├── media/      # 图片与视频原文件
├── settings/   # 站点设置
└── activity/   # 最近一年的创作活动
```

可以通过 `BLOG_WORKDIR` 改成本机的其他目录。服务只监听 `127.0.0.1`，写作页面不再需要云端登录。

## 本地运行

要求 Node.js `>=22.13.0`。

```bash
npm install
npm run dev
```

打开 `http://localhost:3000`。`npm run dev` 会同时启动网页和本地文件存储服务。

生产模式：

```bash
npm run build
npm start
```

## macOS 应用

```bash
npm run macos:build
open "macos/dist/Notebook 36.app"
```

应用默认打开本机博客地址。构建与地址配置说明见 `macos/README.md`。

## 数据与上传

- 文章同时保存为 JSON 和 Markdown
- 图片支持 JPG、PNG、WebP、GIF、AVIF
- 视频支持 MP4/MOV、WebM
- 媒体原文件写入本机 `media/` 目录
- 保存文章和设置时使用版本检查，避免多个窗口静默覆盖
- 首页活动热力图来自本机最近一年的发布、编辑与图片上传记录

请像对待普通本地文件一样备份数据目录。删除应用不会自动删除其中的内容。

## 质量检查

```bash
npm run typecheck
npm run lint
npm test
npm run macos:test
```
