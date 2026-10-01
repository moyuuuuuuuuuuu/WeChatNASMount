# WeChat NAS Mount

一个轻量的 macOS 工具，把 SMB NAS 共享挂载到微信沙盒内部，解决微信因 App Sandbox 无法访问指向 `/Volumes` 的媒体软链接问题。

## 版本兼容性

适配微信版本：4.1.11

## 功能

- 图形化配置主/备用 NAS 地址、共享名、用户名和沙盒挂载点
- 不保存 NAS 密码，复用 macOS 钥匙串中的 SMB 凭据
- 使用 macOS 13+ 的 `SMAppService.mainApp` 注册应用登录启动
- 菜单栏显示连接状态，关闭设置窗口后继续运行
- 主地址连接失败时自动使用备用地址
- 新挂载成功时显示 macOS 系统通知
- 网络就绪后自动连接；失败按 30、60、120、240 秒间隔重试，唤醒后立即检查
- 挂载成功后验证本机媒体链接及 NAS 目录可读性，再报告成功
- 网络操作在后台执行，每次命令限制为约 20 秒，设置界面保持响应
- 保留各地址失败原因，便于区分磁盘访问权限、网络和认证问题
- 默认只迁移图片、视频和文件；建议将微信数据库保留在本机

## 使用前准备

1. 在 Finder 中连接一次 `smb://NAS地址/共享名`，并勾选把密码保存到钥匙串。
2. 将 App 放入“应用程序”文件夹。
3. 打开 App，填写配置。
4. 点击“打开完全磁盘访问权限”，把本 App 加入并开启权限。
5. 点击“保存并启用自动连接”。在系统设置 → 通用 → 登录项中确认应用已启用。
6. 菜单栏显示 `NAS ●` 表示媒体目录检查通过；`NAS !` 时打开“设置与状态”查看错误。

## 从旧版本升级

将新版放在原应用路径并启动，填写原 NAS 配置后点击保存。新版会注册正式登录项，并将旧 `ink.moyuu.wechat-nas-mount.plist` 移到配置目录备份。旧的每 30 秒重复启动进程的 LaunchAgent 不再使用。

早期地址写死的 `wechat-nas-mount` 版本没有配置文件，需要首次填写地址。应用临时签名更新后，macOS 可能需要重新授予完全磁盘访问权限。注册登录项不等于获得磁盘权限。

关闭设置窗口不会退出应用；菜单栏“退出”停止当前会话检查，“关闭登录启动”取消后续登录自动启动。重启验证需要实际注销或重启，不能仅凭注册成功保证。

应用只检查已有的媒体软链接，不创建或修复链接，也不卸载被其他共享占用的挂载点。NAS 暂时断开时避免操作媒体，连接恢复后应用再检查。

可用命令：

```bash
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --status
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --mount
```

`--status` 返回 JSON，包括实际 SMB 挂载、可读媒体目录数和登录项状态；异常返回非零退出码。

> 本工具负责安全挂载，不会自动移动、覆盖或删除微信数据。修改微信媒体目录前请退出微信并保留备份。

## 构建

需要 macOS 13 或更高版本和 Swift 6 工具链：

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

产物位于 `dist/`。没有 Developer ID 时会使用临时签名，其他 Mac 首次运行可能需要在“隐私与安全性”中手动允许。

GitHub Actions 会在每次推送后生成可下载的构建产物。推送 `v*` 标签时还会自动创建 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

## 安全说明

- 配置文件位于 `~/Library/Application Support/WeChatNASMount/config.json`。
- 软件不会读取或保存 SMB 密码。
- 完全磁盘访问权限是 macOS 的广泛权限；应用使用它访问微信容器内挂载点及验证媒体目录。
- SMB 网络中断时请避免强制操作大量媒体文件。

## License

MIT
