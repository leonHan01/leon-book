# 文章内画板接入调研

核查日期：2026-10-23（Asia/Shanghai）。范围：官方文档、官方仓库、许可证和发布记录；本次仅调研与代码阅读，没有安装依赖、启动应用或游戏，也没有验证 WKWebView 实机性能。下文的集成结构是项目建议，不代表已经实现。

后续接入进展：文章内离线 Excalidraw 已实现，并通过隐藏 WKWebView 的字体、图片导出与保存重开检查。本文保留调研时的判断；实际用法、构建与存储约定见 [画板接入说明](../../macos/Whiteboard/README.md)。

## 结论

**优先选择 Excalidraw，先做“文章静态预览 + 点击进入独立画板编辑器 + 可再次编辑”的单人离线版本。** 它提供完整画板交互、React 嵌入组件、JSON 源数据和 PNG/SVG 导出，核心与 npm 包采用 MIT 许可证。SwiftUI 应用可以在构建阶段把组件及资源打包为静态网页，再由 WKWebView 加载；用户机器不需要安装 Node。最后一点是根据其浏览器组件形态作出的工程判断，仍须验证本项目的资源加载方式。[Excalidraw 安装](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/installation)、[集成](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/integration)、[许可证](https://github.com/excalidraw/excalidraw/blob/master/LICENSE)

若需求主要是复杂流程图、架构图，可把 draw.io 留作备选；若需要高度定制的无限画布且接受商业授权，再评估 tldraw。**当前 tldraw SDK 是 source available，不能作为 MIT/Apache 式免费开源 SDK 推荐。** [tldraw 官方许可说明](https://tldraw.dev/community/license)

## 候选比较

| 方案 | 许可与定位 | 嵌入方式 | 数据与离线 | 本项目判断 |
| --- | --- | --- | --- | --- |
| Excalidraw | MIT；成品画板，偏手绘草图、箭头、说明图 | React/ReactDOM 组件 | `.excalidraw` JSON + `files`；PNG/SVG；需打包字体等资源 | 第一选择；现成功能与接入成本较平衡 |
| tldraw SDK | 当前 SDK 使用专有 tldraw license；默认仅开发环境，生产另行授权 | React 组件，可定制 shape/tool/UI | JSON snapshot、asset store、PNG/SVG；支持自托管静态资源 | 技术可接，但不满足“宽松开源、无生产授权成本”的目标 |
| draw.io / diagrams.net | 仓库源码 Apache-2.0；附带图标、模板另有条款 | 完整编辑器 iframe + `postMessage` JSON 协议，不要求宿主采用 React | XML，PNG/SVG；可自托管静态网页，离线嵌入仍须验证 | 更适合专业制图；集成和资源包更复杂，尚未实测包体 |
| Fabric.js | MIT；Canvas 图形底层库 | 原生 JS/TS，不必引入 React | JSON、SVG、图像导出；图片资源自己管理 | 仅在功能缩到简单涂鸦/图片标注时考虑；工具栏、连接线、历史等产品行为要自建 |

比较依据：[Excalidraw 包定义](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/package.json)、[Excalidraw JSON](https://docs.excalidraw.com/docs/codebase/json-schema/)、[tldraw 安装](https://tldraw.dev/installation)、[draw.io 嵌入协议](https://www.drawio.com/docs/reference/embed-mode/)、[draw.io README](https://github.com/jgraph/drawio/blob/dev/README.md)、[Fabric.js 核心能力](https://www.fabricjs.com/docs/core-concepts/)、[Fabric.js 许可证](https://github.com/fabricjs/fabric.js/blob/master/LICENSE)。表中适配与工作量判断为本次调研推断，未做性能或体积基准。

## Excalidraw：推荐接入方式

### 编辑器与离线资源

官方导出 `Excalidraw` React 组件；现查主分支的 peerDependencies 接受 React/ReactDOM 17、18、19。应另建一个小型前端构建目录，把 JS、CSS、字体输出到 macOS 资源包，现有文章编辑器继续使用原生 JS。字体默认从 CDN 获取，必须复制 `dist/prod/fonts` 并设置 `window.EXCALIDRAW_ASSET_PATH`，否则“JS 已本地化”仍不等于完整离线。[包定义](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/package.json)、[字体自托管说明](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/installation)

### 保存与恢复

`initialData` 可加载初始场景；`onChange` 和 `excalidrawAPI` 可用于捕获修改、取场景、取文件及更新场景。持久化应保存可编辑源文件，再生成预览；仅保存 PNG/SVG 会失去可靠的对象级编辑数据。[Props](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/api/props/)、[API](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/api/props/excalidraw-api)

`.excalidraw` 格式包含 `elements`、`appState`、`files`。图片元素通过文件 ID 引用 `files` 中的图片数据；不能只保存元素数组。首版可把图片作为 data URL 保存在源 JSON，简化迁移和备份；图片很多时再设计二进制附件去重。这是存储策略建议，不是库要求。[JSON 格式](https://docs.excalidraw.com/docs/codebase/json-schema/)

官方 Utils 文档与当前主分支存在签名差异：当前 `serializeAsJSON` 源码接收 `elements, appState, files, type`，`local` 输出包含被引用的图片文件，`database` 输出不包含 `files`。实现时必须按锁定版本的类型和源码调用，不能直接照抄旧文档简例，否则会出现“形状恢复了，图片丢了”。[序列化源码](https://github.com/excalidraw/excalidraw/blob/master/packages/excalidraw/data/json.ts)、[Utils 文档](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/api/utils)

可用 `exportToBlob` 生成 PNG，`exportToSvg` 生成 SVG，导出需要传入场景引用的 `files`。推荐文章日常显示 PNG，SVG 作为可选导出，避免直接把不受控制的 SVG 标记插入正文 DOM。[导出 API](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/api/utils/export)

### 协作边界

npm 组件**不包含即插即用的多人协作服务**。官网的协作能力不能等同于嵌入组件的默认能力；接入多人编辑需要宿主实现通信、状态合并、持久化和访问控制。首版单人编辑无需协作后端。[官方 FAQ](https://docs.excalidraw.com/docs/@excalidraw/excalidraw/faq)

## tldraw：主要限制是当前许可证

当前 `LICENSE.md` 将向最终用户提供功能的部署计入生产环境，默认只允许开发使用，且禁止干预 license key 检查。生产使用须取得试用、商业或非商业 hobby 授权；hobby 授权需要申请且保留水印。把 SDK 放到本地桌面 WebView，或技术检测暂未拦截，都不能推导为获得免费生产许可。[许可证原文](https://github.com/tldraw/tldraw/blob/main/LICENSE.md)、[官方许可说明](https://tldraw.dev/community/license)

key 可在客户端离线验证，但其域名和有效期适用规则需要覆盖实际桌面加载方式。官方两页对 hobby 遥测的描述存在差异：license 页写商业和 hobby 不发送信息，license-key 页写 hobby/trial 会发送许可与页面相关信息；如果选它，应以锁定版本源码及签署授权核实离线和遥测要求，不能承诺绝对零网络请求。[License key](https://tldraw.dev/sdk-features/license-key)、[License](https://tldraw.dev/community/license)

技术上可用 `getSnapshot` / `loadSnapshot` 保存、恢复 JSON。`persistenceKey` 会使用浏览器 IndexedDB；本项目应改走原生存储。图片属于 assets，需要同时保存实际文件及记录；可以实现 `TLAssetStore`。字体、图标、翻译默认走 CDN，可以用 `@tldraw/assets` 和 `assetUrls` 完整自托管。PNG/SVG 可通过 `editor.toImage` 或 SVG 方法导出。[持久化](https://tldraw.dev/sdk-features/persistence)、[Assets](https://tldraw.dev/sdk-features/assets)、[安装与静态资源](https://tldraw.dev/installation)、[图像导出](https://tldraw.dev/sdk-features/image-export)

多人协作通过 `@tldraw/sync`，生产需要自己的同步服务器与图片存储。官方 demo 服务仅用于原型，房间按 ID 公开可达且数据约一天后删除，不能用作正式文章存储。[协作文档](https://tldraw.dev/sdk-features/collaboration)

## draw.io：专业制图备选

官方 embed 方案通过 iframe 与宿主交换 `postMessage`，支持初始化、加载 XML、保存、自动保存及导出。JSON 协议适合再封装成 WKWebView → Swift 消息；无需把正文编辑器改为 React。导出支持 PNG/SVG 等格式，PDF 需要配置导出服务。[嵌入协议](https://www.drawio.com/docs/reference/embed-mode/)

官网说明 embed 模式支持于 `embed.diagrams.net`；离线不能直接依赖该在线地址。官方 FAQ 允许用静态服务器部署 `src/main/webapp/`，并介绍关闭远程集成的选项。因此自带网页资源是候选路线，但“本地自定义 scheme + 嵌入协议”的组合仍需单独验证，不能把网页自托管等同于 WKWebView 已兼容。图片如仍引用远程 URL 也会破坏离线目标，应在导入时本地化，XML 与相关图片一起保存。[官方 FAQ](https://github.com/jgraph/drawio/wiki/FAQ)、[URL 参数](https://www.drawio.com/docs/reference/supported-url-parameters/)

截至核查日期，源码 `LICENSE` 仍为 Apache-2.0；README 对图标、stencil 和模板单列了 Atlassian 生态使用限制，还把此仓库描述为 test version 并提到付费生产版本。这些文字需要按实际取用的代码/资产/发行版分别核查，**不能据 README 推断 Apache 源码本身在生产使用必然收费，也不能把所有随包资产一概宣称为纯 Apache-2.0**。当前 README 还明确此版本不支持实时协作；自托管并不自动获得多人编辑。[LICENSE](https://github.com/jgraph/drawio/blob/dev/LICENSE)、[README](https://github.com/jgraph/drawio/blob/dev/README.md)

## 本项目的集成建议

项目当前文章以语义 HTML 为权威正文，使用 SwiftUI + WKWebView + 原生 JS `contenteditable`，Markdown 只用于单向导入。建议新增 HTML 画板块，避免用 Markdown fence 存放 JSON。以下结构均为待实现设计：

1. **正文只放引用和预览。** 用非正文编辑的 `figure` 块保存画板 ID、引擎、源数据 revision、预览地址和说明文字；列表、阅读和长文编辑都只渲染图片。
2. **点击才启动完整画板。** 复用一个独立弹窗/面板 WKWebView 载入本地 Excalidraw bundle；打开时由 Swift 送入源数据，保存后更新对应 HTML 块并关闭。这样不会为文章里的每张图维持一个活跃画布。
3. **原生存储为准。** 当前文章 WebView 使用 nonPersistent data store，不能把 localStorage/IndexedDB 当文章附件的唯一存储。源 JSON、图片和预览由 Swift 负责落盘与备份，JS 消息只传明确的数据和 ID。
4. **源数据与预览同版本提交。** 每次保存产生不可变 revision（例如内容哈希），先写源文件和预览，再更新文章引用。不能反复覆盖同一 `board.json`：只记录 HTML 的文章撤销/历史会指向新数据，无法还原旧画板。资源清理需保护历史仍引用的 revision。
5. **扩展既有 HTML 规则。** 现有 `cleanHTML` 删除 script/iframe/svg 和未知属性，应明确允许画板块的少量 metadata，完整编辑器留在独立 WebView；普通图片的双击预览、替换操作也要识别画板分流。
6. **沿用现有媒体路由约束。** 当前 `/media/<slug>/<filename>` 只解析两层目录，可用 `/media/whiteboards/<id>-<revision>.excalidraw` 与相应 PNG；若采用更深目录必须扩展 resolver。实际存放位置和打包/export规则由存储层决定。

建议先支持手绘、矩形/椭圆、箭头、文字、图片、撤销重做、保存/取消、重新编辑和 PNG 预览。多人协作、AI 制图、跨文章共用画板可留到下一阶段。

### 已核查的代码接入点

以下以本次调研时的工作树为准，包含已有未提交修改；根目录 README 的 Markdown 存储说明有滞后，应以当前代码及 macOS README 为准。

| 位置 | 现有行为 | 接入时需要处理 |
| --- | --- | --- |
| [RichArticleDocument.swift](../../macos/Sources/LeonBook/RichArticleDocument.swift) 的 `RichArticleDocument` / `RichArticleFile` | `html-v1` 正文与完整 HTML 文件读写 | 保留画板引用、预览、说明；普通浏览器至少能阅读导出的预览 |
| [RichArticleEditor.swift](../../macos/Sources/LeonBook/RichArticleEditor.swift) 的 `makeNSView` / `Coordinator` | 临时 WebView 数据空间、`richArticle` 消息桥、`documentID` 校验 | 新增打开/保存画板消息与独立编辑 WebView；沿用文档身份及只读校验，防止切换文章后旧回调写错位置 |
| [RichArticleEditor.html](../../macos/Sources/LeonBook/Resources/RichArticleEditor.html) 的 `commands` / `cleanHTML` / `notify` | 斜杠菜单、HTML 白名单、最多 100 条正文撤销历史 | 增加 `/画板` 入口、画板属性白名单和整块插入/删除；一次画板确认保存对应一次正文撤销操作 |
| [RichArticleInteractions.js](../../macos/Sources/LeonBook/Resources/RichArticleInteractions.js) 的图片交互 | 图片双击放大、替换、删除及说明 | 画板预览点击进入画板编辑，避免“替换图片”造成源文件与预览不一致 |
| [ArticleEditorViews.swift](../../macos/Sources/LeonBook/ArticleEditorViews.swift) 的 `RichArticleEditor` 调用 | 绑定当前草稿与只读状态 | 挂载编辑面板，处理确认、取消和关闭前未保存状态 |
| [LocalBlogStore.swift](../../macos/Sources/LeonBook/LocalBlogStore.swift) 的 `mediaURL` / `removeUnreferencedMediaFiles` 与 [LocalBlogStore+Indexes.swift](../../macos/Sources/LeonBook/LocalBlogStore+Indexes.swift) | 两层媒体路径解析、按 `media_references` 判定清理；当前引用索引覆盖文章、动态与回答 | 把源 JSON、预览、草稿和历史的画板引用纳入资源生命周期，不能只登记预览 PNG |
| [NativeModels.swift](../../macos/Sources/LeonBook/NativeModels.swift) 的 `NativeArticleRevisionSnapshot` | 快照含正文及附件记录，没有独立画板版本模型 | 正文指向不可变 revision，同时保留对应源数据；复制画板后的修改应生成独立新版本 |
| [Package.swift](../../macos/Package.swift) 的资源配置 | `.process("Resources")` | 打包前端产物时保留 JS 分块、字体和图片所需目录结构，必要时对画板子目录单独使用 `.copy` |

建议存储提交顺序为：生成并校验源 JSON与 PNG → 原子写入新的 revision 文件 → 更新草稿画板块引用 → 经现有文章保存流程持久化。任一步失败保留旧引用；未提交资源稍后回收。此顺序是设计建议，现有代码尚未提供画板事务。移动文章或导出独立 HTML 时还需打包附件并重写预览路径，不能把 `/media/...` 当成在任意外部浏览器都可直接解析的地址。

## 后续验证边界

落地前需要验证本地字体/资源路径、WKWebView 文件选择与剪贴板、中文输入、触控板缩放、导出含图片的画板、保存后重开、文章撤销/历史恢复与附件备份。应验证 `baseURL:nil`、自定义 scheme、字体加载和 Canvas 导出之间的实际行为；本次没有启动应用或游戏，也未测量冷启动、内存、包体大小、长文滚动或 WebKit 性能，不能承诺已流畅运行。

## 维护证据与版本选择

2026-10-23 查阅官方 Releases：Excalidraw 页面列出 `v0.18.1` 为 Latest，说明其修复上游 Mermaid XSS；tldraw 列出 `v5.5.2` 为 Latest，包含 license domain 修复；draw.io 列出 `v32.5.5` 为 Latest。这里仅记录查询时的发布证据，不据此推断维护 SLA，也不把可变主分支的版本号当成最终依赖版本。正式集成应锁定发布版本、保留第三方 LICENSE/NOTICE，并以该版本 API/源码重新核查上述配置。[Excalidraw Releases](https://github.com/excalidraw/excalidraw/releases)、[tldraw Releases](https://github.com/tldraw/tldraw/releases)、[draw.io Releases](https://github.com/jgraph/drawio/releases)
