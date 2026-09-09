# WeChat NAS Mount

一个轻量的 macOS 工具，把 SMB NAS 共享挂载到微信沙盒内部，解决微信因 App Sandbox 无法访问指向 `/Volumes` 的媒体软链接问题。

## 功能

- 图形化配置 NAS 地址、共享名、用户名和沙盒挂载点
- 不保存 NAS 密码，复用 macOS 钥匙串中的 SMB 凭据
- 一键挂载并安装登录后台任务
- NAS 启动较慢或短暂离线时每 30 秒自动重试
- 默认只迁移图片、视频和文件；建议将微信数据库保留在本机

## 使用前准备

1. 在 Finder 中连接一次 `smb://NAS地址/共享名`，并勾选把密码保存到钥匙串。
2. 将 App 放入“应用程序”文件夹。
3. 打开 App，填写配置。
4. 点击“打开完全磁盘访问权限”，把本 App 加入并开启权限。
5. 点击“保存并立即挂载”。

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
- 完全磁盘访问权限仅用于在微信容器内部创建挂载点。
- SMB 网络中断时请避免强制操作大量媒体文件。

## License

MIT
