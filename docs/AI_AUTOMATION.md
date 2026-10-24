# 外部 AI 接入 LeonBook

LeonBook 提供 **CLI + JSON Lines 接口 + App 本地 Unix Socket**。外部 AI 可以直接读取、保存和发布内容，无需模拟点击。协议版本为 `1`。

## 立即使用

在项目根目录运行；首次调用自动编译 CLI，构建日志写到 stderr，stdout 只输出 JSON：

```bash
./scripts/leonblog api capabilities
./scripts/leonblog api workspace.info
./scripts/leonblog api articles.list --json '{"limit":20}'
./scripts/leonblog api articles.create --json '{"title":"AI 写的文章","slug":"ai-article","body":"<h1>你好</h1><p>这是正文。</p>","status":"draft"}'
./scripts/leonblog api moments.create --json '{"text":"今天完成了新文章 #写作"}'
```

`moments.create` 发布到 **LeonBook 内的本地微博时间线**。它不调用新浪微博，也不向互联网平台发送内容。文章的 `published` 同样是本地资料库的发布状态。

每个命令可以带 `--root /绝对路径/数据根目录` 和 `--user 用户ID`。数据根目录是包含 `workspaces/` 的目录，不能传某个用户的工作区目录。默认顺序是 `--root`、`LEON_BOOK_WORKDIR`、App 记住的目录、`/Volumes/T7Shield/myblog`。省略 `--user` 使用注册表中的当前用户；需要固定目标的 AI 应始终指定 `--user`。

误传已注册的用户工作区、其子目录或 `workspaces/` 容器时，返回 `invalid_root` 并指出正确根目录，拒绝执行迁移或写入。指定已有资料库时先确认路径存在：包括 `workspace.info` 在内的存储调用会初始化不存在的数据根目录。

App 正在运行时，CLI 连接它的本地接口；App 关闭时，CLI 直接调用同一套存储逻辑。旧版 App 没有监听接口且占用了资料库时，会返回存储锁错误；请保存内容并重新打开新构建的 App。不会自动退出 App。

`./scripts/leonblog build` 同时把 CLI 打包为：

```text
macos/dist/leon-book.app/Contents/MacOS/LeonBookCLI
```

可以直接调用这个可执行文件，或把它放入 PATH 的符号链接中。保留整个 `.app` 包，因为 CLI 共享包中的资源。包内 GUI 为 `LeonBook`，CLI 使用 `LeonBookCLI`，避免在不区分文件名大小写的 macOS 磁盘上互相覆盖。

## 参数与返回值

```bash
# JSON 文件；推荐用于包含引号、换行和 HTML 的内容
./scripts/leonblog api articles.create --json @/tmp/article.json

# 从标准输入读取参数
./scripts/leonblog api articles.create --json - < /tmp/article.json

# 正文文件与元数据分开；正文必须是 UTF-8
./scripts/leonblog api articles.create \
  --json '{"title":"长文章","slug":"long-article","format":"markdown"}' \
  --body-file /tmp/article.md
```

正文支持 `html`、`markdown` 和 `text`。不指定 `format` 时，以 `<` 开头的正文按 HTML 处理，其余按 Markdown 处理。HTML 片段自动包装为 LeonBook 原生文章；Markdown 单向转换为 HTML；`text` 会转义尖括号等字符。正式内容保存为 `.html` 文件。

成功：

```json
{"apiVersion":1,"result":{"slug":"ai-article","updatedAt":"...","status":"draft"}}
```

失败：

```json
{"apiVersion":1,"error":{"code":"conflict","message":"这篇文章已在其他窗口中更新，请重新加载后再保存。"}}
```

实际成功返回完整对象，上面的文章仅列出部分字段。单次调用退出码：`0` 成功，`1` 操作失败，`2` 命令行或请求格式错误。未知参数会报错，避免拼写错误被忽略。

常见错误码：`invalid_params`、`invalid_request`、`invalid_root`、`message_too_large`、`method_not_found`、`not_found`、`already_exists`、`conflict`、`read_only`、`module_disabled`、`storage_error`、`busy`、`confirmation_required`、`app_unavailable`、`ambiguous_window`、`transport_error`。

## 正确编辑与发布

先读再改，保存时带上读取结果中的 `updatedAt`：

```bash
./scripts/leonblog api articles.get --json '{"slug":"ai-article"}'
./scripts/leonblog api articles.update --json '{"slug":"ai-article","expectedUpdatedAt":"上一步的 updatedAt","body":"<p>新的正文。</p>"}'
./scripts/leonblog api articles.publish --json '{"slug":"ai-article","expectedUpdatedAt":"修改后返回的 updatedAt"}'
```

`articles.update` 仅修改传入字段，省略的标题、标签、属性、封面、素材等都会保留。`properties`、`tags`、`media` 如果提供，则整体替换该字段。封面传 `null` 清除，其他字段不能随意传 `null`。目录通过 `articles.move` 修改。

文章更新、发布、撤回、移动、删除、历史版本恢复，以及微博更新/删除、回答更新，都要求 `expectedUpdatedAt`。待办更新、完成、删除、恢复要求 `expectedRevision`。发生 `conflict` 时重新读取，合并内容，再提交；不要盲目覆盖。

完整 Python 示例（使用参数数组，不经过 Shell 拼接）：

```python
import json
import subprocess

CLI = "/绝对路径/leonWeb/scripts/leonblog"
ROOT = "/绝对路径/资料库"

def call(method, **params):
    process = subprocess.run(
        [CLI, "api", method, "--root", ROOT, "--user", "leon", "--json", "-"],
        input=json.dumps(params, ensure_ascii=False),
        text=True, capture_output=True,
    )
    response = json.loads(process.stdout)
    if "error" in response:
        raise RuntimeError(response["error"])
    return response["result"]

article = call("articles.create", title="AI 文章", body="## 开始\n\n这是草稿。")
article = call("articles.update", slug=article["slug"],
               expectedUpdatedAt=article["updatedAt"], body="<p>修订后的正文。</p>")
article = call("articles.publish", slug=article["slug"], expectedUpdatedAt=article["updatedAt"])
post = call("moments.create", text="新文章已完成 #创作")
```

## 持续调用：JSON Lines

```bash
./scripts/leonblog api --stdio --root /绝对路径/资料库 --user leon
```

每行一个 JSON 请求，每行一个 JSON 响应，`id` 原样回传。正文中的换行必须通过 JSON 转义。请求可覆盖默认 `userID`：

```json
{"id":"1","method":"articles.list","params":{"limit":10},"userID":"leon"}
{"id":"2","method":"moments.create","params":{"text":"由外部 AI 发布"},"userID":"leon"}
```

顶层字段仅接受 `id`、`method`、`params`、`userID`。字段区分大小写，`userId`、`user` 等未知字段返回 `invalid_request`，不会退回默认用户后执行。省略 `userID` 时使用启动参数 `--user`，再省略才使用注册表当前用户。

一条请求失败不会结束 stdio 进程。超长行被丢弃至换行后返回 `message_too_large`，后续请求继续执行；读取时限制内存，不会先装入整个输入。EOF 结束进程，也允许最后一行没有换行。stdio 是本项目的 JSON Lines 协议，**不是 MCP 或 HTTP**；支持执行命令或启动子进程的 AI 都可以使用。

## 能力发现与数据格式

`capabilities` 无需初始化资料库，返回 `operations`（方法、说明、是否写入、参数）和 `examples`（复杂对象的实际 JSON 模板）。参数类型末尾的 `!` 表示必填。完整方法以运行时输出为准：

| 领域 | 方法 |
| --- | --- |
| App 窗口 | `app.commands`、`app.execute` |
| 用户与资料库 | `workspace.info`、`workspace.sync`、`users.list/create/select` |
| 文章 | `articles.list/get/create/update/publish/unpublish/delete/move` |
| 历史与关系 | `articles.revisions/restoreRevision/relations/graph`、`properties.rename` |
| 文章评论 | `articleComments.list/create/delete`，支持回复与引用 |
| 微博 | `moments.list/get/create/update/favorite/delete` |
| 微博评论 | `momentComments.list/create/delete`，支持回复 |
| 问答 | `questions.list/get/create`、`answers.list/create/update` |
| 待办 | `todos.list/get/create/update/complete/delete/restore` |
| 搜索与活动 | `search`、`activity.list` |
| 目录和素材 | `resources.list/move/trash`、`folders.create`、`media.upload` |
| 收藏 | `bookmarks.list/save/delete` |
| 回收站 | `trash.list/restore/delete/empty` |
| 备份 | `backup.create/list/validate` |

文章与微博列表返回 `{items,total,offset,hasMore}`，默认 `limit=100`，范围 1–1000。搜索默认 60 条，最多 1000 条。其他列表返回数组。完整请求与 Socket 响应上限 8 MiB；请求包括元数据、正文、JSON 转义和外层字段，`--json` 与 `--body-file` 共用一个额度。CLI 在连接 App 或进入离线存储之前检查完整请求，两种模式一致。请求过大时尚未执行；响应过大时写入可能已成功，不能直接重发。大资料库请减小页数、按需读取正文。

素材先调用 `media.upload`：

```bash
./scripts/leonblog api media.upload --json '{"path":"/tmp/photo.png","kind":"image","slug":"moments"}'
```

返回 `{key,kind,name,size,url}`。把其中的 `kind/name/size/url` 放入微博的 `images` 数组，或文章的 `media` 数组，并在 HTML 中引用 `url`。`kind` 支持 `image/video/audio/file`；应用原有的微博媒体格式与数量限制继续生效。

复杂参数可以直接参考 `capabilities.result.examples`，或先读取现有对象再修改：

- 文章属性使用 `{"kind":"text","value":"内容"}` 等类型化值，也兼容简单字符串。属性字典是整体替换。
- `textRuns` 元素示例：`{"text":"加粗文本","bold":true}`；传 `text` 而不传 `textRuns` 会重置文字样式。
- 引用评论的 `selection` 是 `{"quote":"原文","anchorID":"标题锚点"}`；`parentID` 指向同一文章/微博的父评论。作者使用目标工作区的用户名称。
- 待办 `priority` 是 `0/1/2`，`dueDay` 是 `YYYY-MM-DD` 或 `null`；`completed` 是布尔值。
- 集合和收藏使用各自的完整可序列化对象；`capabilities` 给出可保存的模板。

## App 命令、同步与边界

`app.commands` 返回打开窗口的 `windowID`、`userID` 和可执行命令列表。多窗口时用 `windowID` 明确目标：

```bash
./scripts/leonblog api app.commands
./scripts/leonblog api app.execute --json '{"windowID":"列表中的窗口ID","command":"article.open","arguments":{"slug":"ai-article"}}'
```

命令沿用 App 的命令注册表，包括已启用的扩展命令。`app.execute` 返回 `accepted:true` 表示命令已分发；异步保存或需要系统选择框的命令不因此被视为完成。自动写作请优先使用返回已保存对象的内容接口。App 未打开时，窗口命令返回 `app_unavailable`。

通过接口写入后，打开该工作区的窗口会刷新列表与阅读视图，并安排原有备份流程。未保存的编辑器内容会保留；后续保存仍接受版本冲突检查。`users.select/create` 修改后续 API 请求使用的默认用户，不强制切换正在编辑的窗口。

只读挂载、目录深度、路径检查、模块启停和存储锁继续有效。删除文章/微博进入回收站；永久删除和清空回收站须传 `confirm:true`。删除评论同时删除回复，使用与 UI 一致。

`backup.create` 备份**整个数据根目录**，包含用户注册表和所有用户工作区；外部挂载源目录需要单独备份。备份目标必须位于数据根目录之外。完整资料库恢复仍通过 App 设置中的恢复流程执行。系统选择框、偏好面板和并未注册为命令的 UI 操作没有一对一的无界面 API；该版本没有提供任意 SQL、Shell 执行或第三方社交平台账号接入。

Socket 位于 `/tmp/leonbook-api-<uid>/<数据根目录哈希>.sock`，目录权限 `0700`，Socket 权限 `0600`，连接双方检查相同 macOS 用户；不监听 TCP 端口。每个连接使用 4 字节大端长度 + UTF-8 JSON，交换一次请求/响应。可用 `AutomationSocket.path(for:)` 获取准确路径。需要禁用 App 监听时，启动进程设置 `LEON_BOOK_AUTOMATION=0`。CLI 离线能力仍受本地文件访问权限控制。

Socket 连接建立后如果中断，CLI **不会自动把写入请求重发到离线存储**，避免重复发文。`id` 只用于关联响应，不是幂等键。遇到传输超时或结果不明，应先查询内容确认结果，再决定是否重试。

## 验证

```bash
./scripts/leonblog test
```

`LeonBookAutomationTests` 使用临时资料库验证文章/微博生命周期、部分字段更新、旧版本冲突、问答、待办、用户隔离、只读挂载、模块权限、备份校验和 Socket 通信；还检查误传数据根目录、请求字段拼写、在线/离线请求大小一致、超长行恢复及无需关闭 stdin 的交互响应。测试不启动正式 App，不操作用户实际资料库。
