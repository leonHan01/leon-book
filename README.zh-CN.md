# leon-book

[English](README.md) | [简体中文](README.zh-CN.md)

`leon-book` 是一款原生 macOS 写作应用，用于管理文章、草稿、图片、视频、动态和创作活动。

应用使用 SwiftUI 构建，数据直接保存到本地文件系统，不依赖外部浏览器、Node.js 服务或 HTTP API。

## 功能

- 阅读、编辑和发布文章
- 文章编辑停止 3 秒后自动保存恢复快照，支持版本差异和一键恢复
- SQLite FTS5 全文搜索文章、类型化属性、摘要、正文和微博，支持 `[属性名:值]` 筛选、`⌘O` 快速打开，以及带模糊匹配、最近使用、固定命令和可配置快捷键的 `⌘P` 命令面板
- 保存由 SQLite 直接筛选和排序的智能集合，可组合状态、分类、属性、时间和数值条件，支持多级排序、分组及列表、表格、卡片视图
- 收藏文章、正文标题、搜索条件和全局图谱，并从侧栏快速打开
- 阅读页右侧文章面板集中显示大纲、反向链接、出链、可一键转换的未链接提及和局部关系图，并支持悬停预览
- 全局图谱支持搜索、状态与孤立节点过滤、缩放和按连接度进行节点裁剪
- 正文保存时增量更新双链与提及索引；关系面板只查询当前文章的候选关系，全局图谱复用索引而不重新扫描全部正文
- 双链可按标题、slug 或 aliases 解析；`[[文章#标题]]` 跳到标题，`[[文章#^block-id]]` 精确定位段落或列表项，并可在输入 `#^` 后按 ID 和正文预览补全块链接
- 通过 `leonbook://` URL 或 macOS 快捷指令/App Intents 自动新建文章、打开文章、搜索和查看今日动态
- 阅读工作区支持独立前进/后退历史、最近文章、固定标签页以及 `⌘+点击` 新标签打开；正文宽度、字体、字号、行距、段距、主题和代码字体可按用户调整
- 阅读正文支持拖选或双击划词评论，评论、引用与回复集中显示在右侧栏
- 写作区支持文本、列表、数字、日期、复选框和标签属性及全工作区统一重命名；右栏可切换设置、Properties、大纲和链接；“写作/阅读/审稿”作为内置模板，也可另存任意命名工作区并保存标签页、侧栏宽度和分栏状态
- 每个 macOS 窗口拥有独立的当前文章、标签页以及前进/后退导航状态
- 主导航只挂载当前页面，以轻量状态缓存代替预热并常驻完整视图树
- 搜索、知识图谱、发布、备份和采集是独立 SwiftPM 第一方模块，可在“设置 → 第一方模块”中分别启停；命令、事件和权限统一通过 ModuleKit
- 支持从当前用户工作区的 `extensions/` 加载版本化 JSON 声明式扩展，开放命令、模板变量、文本/JSON 导入器、围栏渲染器和 Base 公式函数，但不加载动态库或执行扩展脚本
- 可将普通 Markdown 文件夹或 Obsidian Vault 作为工作区，选择“复制导入 / 只读挂载 / 直接编辑”，并持续监听挂载目录
- 可选将评论、版本历史、收藏、任务布局和阅读偏好写入 Vault 内版本化的 `.leonbook/` sidecar，配合 iCloud Drive、Dropbox、Syncthing 等整目录文件同步在设备间合并
- 在文章正文中直接内嵌远程 HTTP(S) 网页
- 阅读与预览支持用 PDFKit 内嵌 PDF、播放 Vault 音频，并渲染 `$$…$$` / LaTeX 围栏及 Mermaid 图表
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
/Volumes/T7Shield/myblog/
├── leon-book.sqlite    # 用户和设置的主 SQLite 数据库
├── users.json          # 可读的兼容性导出
├── active-user.json    # 可读的兼容性导出
└── workspaces/
    └── <user-id>/      # 每位用户独立的工作空间
        ├── leon-book.sqlite # 文章、动态和活动记录数据库
        ├── articles/   # 文章 JSON、Markdown 和索引；可含可选 .leonbook/ sidecar
        ├── drafts/     # 草稿恢复副本
        ├── media/      # 图片和视频原文件
        ├── moments/    # 动态数据和时间线索引
        └── activity/   # 创作活动记录
```

应用按以下顺序选择数据目录：

1. `LEON_BOOK_WORKDIR`
2. `/Volumes/T7Shield/myblog/`

默认数据目录为 `/Volumes/T7Shield/myblog/`。如果该目录不可用，首次进入应用时会要求选择一个工作目录；之后会记住你的选择。如需使用其他目录，也可以设置环境变量：

```bash
LEON_BOOK_WORKDIR=/Volumes/T7Shield/myblog ./scripts/leonblog open
```

首次初始化多用户结构时，根目录中已有的文章、草稿、媒体、动态和活动记录会自动迁移到默认的 `leon` 工作空间。卸载应用不会删除本地数据，请像备份普通文件一样备份该目录。

### 设置独立备份路径

打开应用的“设置 → 备份”，选择另一块磁盘或其他独立目录。数据变化会被合并处理，默认最多每小时自动生成一个带时间戳的逻辑完整快照；也可以随时手动备份。未变化文件优先使用 APFS Clone-on-Write，无法克隆时复用上一快照或复制，因此图片、视频不会在每次备份时无条件完整复制。快照包含用户配置、SQLite 数据库、工作区内文章、草稿、动态、活动记录、回收站和媒体文件；`.leon-book.lock` 锁文件不会被复制。外部挂载的 Markdown 目录不会重复复制进 LeonBook 快照，应按普通文件夹单独备份。

默认策略保留 90 天、最多 60 个快照，并要求备份卷至少保留 10 GB 可用空间；这些参数可在设置中调整。创建前会显示源数据大小、预计新增占用和磁盘余量。快照列表支持在 Finder 中浏览、SHA-256 校验，以及恢复整个数据目录；恢复前会先创建当前工作区的安全快照，并用暂存目录原子替换，失败时回滚原数据。

备份路径不能放在数据目录内部，否则应用会拒绝保存设置以避免递归复制。备份文件保持本地明文格式；如内容敏感，请把备份目录放在启用 FileVault 的 APFS 磁盘、加密移动硬盘或受控权限的目录中。应用不会自动上传备份到云端。

文章 Markdown（含 YAML Properties）和 `media/` 下的普通媒体文件是资料库的权威数据源；SQLite 保存可由这些文件重新扫描得到的文章索引，并承载本机正在使用的评论、版本、收藏等结构化数据。启用可移植 sidecar 后，这些不可重建状态会同时写入 Markdown 根目录的 `.leonbook/`，新设备导入后仍以 SQLite 提供本地查询。首次启动时，已有 JSON 数据会自动迁移；之后通过 macOS FSEvents 合并处理 Markdown 与 sidecar 的新增、修改、移动和删除，并每 15 分钟执行一次低频完整校验。

在“设置 → Markdown 工作区 / Obsidian Vault”中有三种方式：

- **复制导入**：只读取所选目录，把确认后的文章和附件复制到当前用户工作空间；之后与原目录互不影响，已有相同 slug 的文章会被跳过。
- **只读挂载**：直接把普通目录或 Vault 作为 Markdown 权威数据源并持续监听；LeonBook 可以阅读、搜索和建立关系索引，但统一阻止保存、移动、删除、重构及批量属性写入。
- **直接编辑**：与只读挂载使用相同的目录监听和索引机制，但允许 LeonBook 通过原子写入直接更新原 Markdown。SQLite 与应用媒体仍留在 LeonBook 用户工作空间；可选择把评论、版本、收藏和布局额外写入挂载目录的 `.leonbook/`。

### 可移植 `.leonbook/` sidecar

在“设置 → Markdown 工作区 / Obsidian Vault”中按当前 Markdown 根目录单独启用。LeonBook 会维护以下普通 JSON 文件：

```text
.leonbook/
├── manifest.json   # 格式版本和文件清单
├── comments.json   # 评论、回复及删除墓碑
├── history.json    # 使用跨设备同步 ID 的版本历史
├── bookmarks.json  # 收藏及删除墓碑
└── layouts.json    # 任务布局和阅读偏好
```

sidecar 是 SQLite 之外的可移植事实记录：导入时按稳定 ID 合并，删除通过墓碑传播，历史记录按同步 ID 去重；SQLite 继续作为每台设备上的快速本地索引。LeonBook 监听这些文件，因此文件同步工具完成下载后会自动导入；本机变更会原子写回。只读挂载可以导入已有 sidecar，但不会创建或修改它。停用功能不会删除目录。

此阶段不绑定任何云厂商，也不上传账号数据：iCloud Drive、Dropbox、Syncthing 等只负责同步整个 Markdown 目录。sidecar 是明文 JSON，不具备 Obsidian Sync 一类的端到端加密、远端版本历史或冲突副本管理能力；敏感资料应使用加密磁盘或可信的加密同步层。应用管理的 `media/` 仍需随 LeonBook 工作区单独同步或备份。

智能集合以标准 Obsidian `.base` YAML 保存，可直接导入不含 LeonBook 私有字段的 Base；支持递归 `and/or/not`、全局与 view 级筛选、公式、汇总和多个命名视图。LeonBook 写回已识别配置时会保留未知的顶层、Property 和 view 字段；SQLite 中的集合记录只是 `.base` 的可重建缓存。

## 开发说明

macOS 原生源码、资源和检查脚本位于 [`macos/`](macos/)。更多构建、调试和数据目录说明见 [`macos/README.md`](macos/README.md)。

Swift Package 以 `LeonBookModuleKit` 作为第一方模块 seam，并将搜索、知识图谱、发布、备份和采集分别放入独立 target。每个模块声明稳定 ID、所需权限、完整命令元数据和可发布事件；`LeonBook` target 只负责 SwiftUI/SQLite/文件系统 adapter、命令 handler 与启停状态持久化。停用模块后，其命令会从命令面板消失，直接入口也会经过同一权限判定；正在进行备份恢复或采集写入时会延迟停用，扫描等只读任务则会安全取消。`LocalBlogStore` 的搜索/图谱 adapter 与数据库 schema 已拆为独立文件，避免功能继续堆回核心 Store。

`LeonBookExtensionKit` 是与第一方模块分开的声明式扩展 seam。每个扩展包只有一个 `extension.json`，经路径、大小、ID、冲突和可执行内容校验后才会进入统一注册表；宿主 adapter 只允许插入 Markdown、创建未保存草稿、读取系统文件面板中明确选中的小型文本/JSON 文件、用原生 SwiftUI 样式呈现自定义围栏，以及在现有纯 Base 公式解释器中展开函数。设置页可以逐个启停、重新加载和查看拒绝原因。完整格式与五类示例见 [`macos/Examples/DeclarativeExtension/extension.json`](macos/Examples/DeclarativeExtension/extension.json)。

如需直接运行 SwiftPM 可执行文件：

```bash
swift run --package-path macos LeonBook
```

## 设计原则

`leon-book` 优先保证本地可用、数据透明和界面响应。文章和媒体都以普通本地文件保存，用户可以使用 Finder、备份工具或版本控制工具管理自己的内容。
