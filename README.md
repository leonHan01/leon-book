# Notebook 36

一个运行在 vinext 与 Cloudflare Sites 上的个人出版站：公开访客可以阅读文章，经过 ChatGPT 身份验证且在作者白名单内的用户可以写作、上传媒体和修改站点设置。

## 架构

- Next App Router / React 19 / vinext：页面与 Worker 运行时
- Cloudflare D1：文章、站点设置与上传元数据
- Cloudflare R2：图片与视频原始文件
- 同源 `/api/*`：浏览器端不依赖固定主机名或本机端口
- 服务端渲染：首页和已发布文章可被搜索引擎直接读取
- 浏览器存储：只保留当前设备的主题偏好，不保存权威内容

公开路由为 `/`、`/article/:slug` 和 `/uploads/*`。`/write`、`/settings`、`/upload` 以及草稿/写入 API 都要求作者权限。未登录返回登录流程，已登录但不在白名单内的用户返回无权限页面或 `403`。

## 本地开发

要求 Node.js `>=22.13.0`。

```bash
npm install
npm run dev
```

本地 Worker 只对 `localhost`、`127.0.0.1` 或 `::1` 启用开发作者身份，并在首次访问时初始化本地 D1 schema；该旁路不会对远程主机生效。D1/R2 的本地状态由 Wrangler/Miniflare 保存在项目目录中。

生产环境不要启用 `BLOG_ALLOW_LOCAL_WRITES`。部署前设置：

```dotenv
BLOG_AUTHOR_USER_IDS=作者的_oai_authenticated_user_id
BLOG_AUTHOR_EMAILS=作者登录 ChatGPT 使用的邮箱
BLOG_ALLOW_LOCAL_WRITES=false
```

多个作者 ID 或邮箱用英文逗号分隔，任一白名单命中即可。若生产环境未配置白名单，写入会失败关闭：匿名用户收到 `401`，已登录用户收到 `403`。

## 数据与上传

Drizzle schema 位于 `db/schema.ts`，生成的 SQL migration 位于 `drizzle/`。`.openai/hosting.json` 声明 `DB`（D1）和 `UPLOADS`（R2）绑定，构建产物会一并打包 migration。

- 图片：JPG、PNG、WebP、GIF、AVIF，最大 25 MiB
- 视频：MP4/MOV、WebM，最大 250 MiB
- 服务端同时检查 MIME、文件 magic bytes 与实际流式接收字节数
- R2 key 使用 UUID；删除文章时通过带版本令牌的清理队列删除关联对象
- 文章保存使用 `updatedAt` 乐观锁，避免多个窗口静默互相覆盖

修改 `db/schema.ts` 后执行：

```bash
npm run db:generate
```

## 质量检查

```bash
npm run typecheck
npm run lint
npm test
```

`npm test` 会先进行生产构建，再运行 API、SSR 和本地存储行为测试。测试覆盖鉴权、并发冲突、上传类型/大小、R2 清理、D1 schema 初始化、CORS、Range/HEAD 响应和主要页面的服务端 HTML。

## 可用命令

- `npm run dev`：启动 D1/R2 版本的本地站点
- `npm run build`：生成 Cloudflare Sites 构建产物
- `npm run start`：运行生产构建
- `npm run typecheck`：TypeScript 严格检查
- `npm run lint`：ESLint 检查
- `npm test`：生产构建与完整测试
- `npm run db:generate`：根据 Drizzle schema 生成 migration
- `npm run storage:dev`：单独启动旧文件系统存储适配器（仅用于兼容/行为测试，主站不依赖它）

旧文件系统适配器默认仅监听 `127.0.0.1`，跨域来源必须通过 `BLOG_ALLOWED_ORIGINS` 明确允许；请勿把它直接暴露到公网。
