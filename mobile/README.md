# LeonBook 移动端

Android 和 iOS 共用同一套移动界面。文章、微博和待办保存在手机上，配对后可与 Mac 的一个工作区双向同步。Mac 上创建、修改或删除的内容在下次同步时反映到手机。本版手机可新建、编辑以及完成或重开待办。已有富文本在手机可阅读，编辑正文使用 HTML 输入框。由纯文本生成的文章继续用普通文本框编辑。

## 构建应用

需要 Node.js 22.13 或更高版本。iOS 项目要求 Xcode 26 或更高版本，目标系统为 iOS 16 或更高版本。Android 项目需要 Android Studio 和 Android SDK 36。手机最低 Android 7.0，并需要版本 107 或更新的 Android System WebView。参见 [Capacitor 环境要求](https://capacitorjs.com/docs/getting-started/environment-setup)。

```bash
cd mobile
npm ci
npm run sync
npm run ios       # 在 Xcode 中选择签名团队和手机，构建并安装
npm run android   # 在 Android Studio 中构建并安装 Debug 版本
```

仅构建网页资源可运行 `npm run build`。用浏览器本机调试可运行 `npm run dev`，配对地址可使用 `http://127.0.0.1:8765`。

## 在同一 Wi-Fi 上配对

1. 完成上面的 `npm ci`，再在项目根目录运行 `./scripts/leonblog build`。如果 Mac 应用已经打开，先保存并退出旧版本，再打开新版本。同步服务可在 Mac 应用打开或者关闭时运行，上传附件需要新版本的 Mac 应用或 CLI。
2. 查到 Mac 的局域网 IP。下例以 `192.168.1.23` 为例，替换为实际地址，生成供这台 Mac 使用的 HTTPS 证书。

   ```bash
   node mobile/scripts/create-lan-cert.js 192.168.1.23 ~/leonbook-sync-cert
   ```

3. 将自己生成的 `leonbook-ca.cer` 传到手机并安装为受信任的 CA。iOS 安装证书描述文件后，到「设置 → 通用 → 关于本机 → 证书信任设置」启用完全信任。Android Debug 构建可使用系统中手动安装的 CA。Android Release 构建使用系统信任的 HTTPS 证书。保留 `mac-key.pem` 在 Mac 上。参见 [Apple 证书信任说明](https://support.apple.com/102390)。
4. 在 Mac 开启同步。将数据根目录替换为你的实际目录。可以加 `--user 用户ID` 固定对应工作区，省略时取服务启动时的当前用户。

   ```bash
   ./scripts/leonblog mobile-sync \
     --root /Volumes/T7Shield/myblog \
     --host 192.168.1.23 \
     --cert ~/leonbook-sync-cert/mac-cert.pem \
     --key ~/leonbook-sync-cert/mac-key.pem
   ```

5. 打开手机上的 LeonBook，选择「连接 Mac」，粘贴终端显示的整行配对 JSON。第一次连接会拉取资料。之后在手机上点「同步」，先发送本机已保存的编辑，再拉取 Mac 的更新。iOS 若请求局域网权限，请允许。

Mac 需要开机并保持同步服务运行。终端按 Ctrl+C 可关闭，重新启动会生成新的配对凭证。在手机的「配对设置」更新同一工作区的凭证时，本机缓存和待同步修改会保留。若 Mac IP 变化，以新地址重新生成证书并配对。已有可信 HTTPS 反向代理也可以将请求代理至默认服务地址 `127.0.0.1:8765`，启动时用 `--url https://你的同步地址` 指定手机连接的地址。

## 附件与离线查看

同步后打开文章或微博，在正文图片位置或「附件」列表点击「下载附件」。下载过的附件断网后仍可查看。常见图片和音视频可直接预览，其他文件可用「导出文件」交给手机的系统分享面板。网络链接或未登记为附件的文件请在 Mac 查看，画板编辑在 Mac 进行。

单个附件最多 32 MiB，手机最多缓存 128 MiB，达到上限时优先移除最久未使用的文件。可在「配对设置 → 清除附件缓存」释放空间，正文和待同步修改会保留。切换工作区时会清除旧工作区的附件缓存。

编辑文章或微博时，点「添加附件」选择手机上的文件，保存后即可断网退出。下次点「同步」时，附件会随这条内容一起保存到 Mac，已经在 Mac 上的附件会保留。一条微博最多 9 个附件，支持常见图片、MP3 和 MP4，也可只发图片。文章可上传普通文件，一次最多新增 9 个附件。一次上传最多 64 MiB，手机最多保留 128 MiB 待上传文件。

## 处理冲突

手机发送更新时携带原来的版本。如果 Mac 已编辑或删除这一条，列表会标记「有冲突」，其余修改照常同步。点击该记录对照两边内容，可采用 Mac 版本、把手机内容及新选附件保存为新记录，或者在 Mac 记录还存在时手动合并。合并仍会检查所比较的 Mac 版本。新的文章副本保存为草稿，待办副本默认未完成。

如果请求发出后网络断线，下一次会使用同一操作编号和原内容重试。Mac 同步服务把处理结果写入用户应用数据目录下的 SQLite 日志。如果服务恰好在 Mac 写入后、结果记录前中断，手机会标记「待处理」。先在 Mac 核对保存结果，再处理手机保留的版本。

## 验证

```bash
npm --prefix mobile test
LEONBOOK_TEST_CLI="$PWD/macos/dist/leon-book.app/Contents/MacOS/LeonBookCLI" npm --prefix mobile test
```

测试使用临时资料库和回环端口，覆盖配对校验、Mac CLI 双向读写、同步重试、并发修改、删除、冲突副本和附件访问。可执行文件路径由可选变量 `LEONBOOK_TEST_CLI` 提供。
