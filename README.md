# WeChat NAS Mount · 微信、QQ 与飞书

macOS 菜单栏客户端，将 NAS 共享挂载到聊天应用自己的沙盒内部。三个应用共用 NAS 主地址、备用地址和用户名，各自使用独立共享名、远端目录、挂载点和连接检查。

## 适配版本

- 微信：4.1.11
- QQ：6.9.98（51102）
- 飞书：8.2.14（7727.149）
- 系统：macOS 13+

## 设置页面

窗口顶部是“公共 NAS 连接”：主地址、备用地址和用户名统一填写一次。“微信”“QQ”“飞书”三个标签各自配置启用开关、共享名和远端目录。

**远端目录是共享内的相对路径**。例如共享名为 `ChatStorage`，微信目录为 `WeChat`，QQ 目录为 `QQ`，对应 `smb://NAS/ChatStorage/WeChat` 和 `smb://NAS/ChatStorage/QQ`。三个应用可以选择不同共享或共享内子目录，但使用同一套 NAS 连接。远端目录留空表示共享根目录。

升级时自动读取旧版微信和 QQ 配置，保留原共享名、子目录、挂载点和媒体链接。全新配置中 QQ、飞书默认关闭；升级保留 QQ 原启用状态。若旧版启用的应用使用不同 NAS 连接，拒绝静默合并，请先在旧版统一主地址、备用地址和用户名。保存新版配置前会保留带唯一名称的配置备份。应用标识及登录项身份保持不变。

微信沿用已经准备好的 `xwechat_files/<账号>/msg/{attach,video,file}` 链接。微信的远端目录用于校验这些链接的存储范围，客户端不会自动搬动微信数据或重写链接。已经挂载时，界面拒绝直接变更其服务器、共享、远端目录和挂载点，避免破坏现有连接。需要先退出微信，准备新位置及链接，再处理旧挂载。

QQ 固定挂载在 `~/Library/Containers/com.tencent.qq/Data/Documents/nas-qq-storage`；微信保留旧配置里的挂载点。QQ 不会修改微信目录或微信配置。

## 首次启用 QQ

1. 在 Finder 连接 NAS 的 SMB 共享，将凭据保存到钥匙串。客户端不读取或保存密码。
2. 为客户端授予完全磁盘访问权限。使用原应用安装路径升级，临时签名变化后可能需要重新添加权限条目。
3. 在 QQ 标签页填写 NAS 位置、勾选自动连接，点击“保存设置”。
4. 完全退出 QQ，点击“迁移 QQ 图片到 NAS”，查看确认提示并开始。
5. 客户端检测本机 `nt_qq_*` 账号，把各账号的 `nt_data/Pic` 复制到所选远端目录下的 `mac-<唯一标识>/<账号>/Pic`。复制后逐文件计算 SHA-256，一致后才建立链接。
6. 各账号的本地原目录保留为 `Pic.nas-backup-<唯一标识>`。迁移记录保存在配置目录；迁移中断时可通过“恢复 QQ 本地图片”处理。
7. 完成后启动 QQ，检查聊天图片；数据库、登录信息、表情资源、头像及 QQ 下载目录保持本地。

迁移不会覆盖已有 NAS 目录。若多个账号中途失败，界面报告失败，保留已完成步骤的记录与备份；退出 QQ 后可统一恢复。迁移和恢复使用进程锁，防止多个客户端或命令同时修改目录。

“恢复 QQ 本地图片”可以在 NAS 离线时工作：恢复迁移前的本地副本，保留 NAS 文件和原链接作为恢复凭据。**迁移之后新增到 NAS 的图片不会自动合并回本地**，请按需要另行取回；恢复不会删除 NAS 原件。已有迁移记录时，必须先恢复本地才能更改 QQ 的 NAS 位置或关闭自动连接。

QQ 接收或下载的普通文件仍由 QQ 自身的“设置 → 存储管理 → 更改存储路径”管理，本版本不修改该设置。

## 首次启用飞书

1. 填写顶部公共 NAS 连接，在飞书标签页指定共享名和远端目录（默认子目录 `Feishu`），启用后保存。
2. 完全退出飞书，点击“迁移飞书图片到 NAS”。未勾选“记住我的登录状态”时，之后重开飞书需要扫码。
3. 只迁移 `~/Library/Application Support/LarkShell/sdk_storage/<32位账号标识>/resources/images`，目标为所选 NAS 目录中的 `mac-<唯一标识>/<账号>/images`。数据库、登录信息、运行环境、豆包工作数据、下载文件及其他资源目录均不迁移。
4. 逐文件 SHA-256 校验通过后才建立链接，本地原目录保留为 `images.nas-backup-<唯一标识>`；迁移记录独立保存到 `feishu-migrations.json`，操作锁独立于 QQ。
5. 飞书固定挂载点为 `~/Library/Application Support/WeChatNASMount/mounts/feishu`，不会复用或卸载微信、QQ 的挂载点。
6. “恢复飞书本地图片”从本地备份复制并校验，不依赖 NAS，恢复后仍保留原始本地备份。NAS 后来新增的图片和原链接仍保留，但不会自动合并回本机。

飞书已迁移时，修改公共 NAS 连接、飞书存储位置或关闭自动连接前，必须先恢复本地。QQ 已迁移时同样不能直接更改公共 NAS 连接。这样可以防止现有链接被无声切换到另一台 NAS。

## 自动连接与断网保护

- “保存设置”与“启用登录启动”分别操作。登录启动使用 `SMAppService.mainApp`；需要批准时，界面提示前往系统设置 → 通用 → 登录项。
- 菜单栏退出只停止当前客户端；“关闭登录启动”取消下次登录时自动运行。注册成功不代表已经通过真实重启验证。
- 启动时检查所有已启用的应用；电脑唤醒或网络恢复时立即检查。成功后每 60 秒检查，失败按 30、60、120、240、300 秒退避重试。
- 微信、QQ、飞书各自在有超时限制的工作进程中检查，一个应用的网络访问不会阻塞另一个应用的连接检查。
- QQ 与飞书使用各自独立的 SMB 会话和 soft 挂载。保留 macOS SMB 客户端的重连行为，不强制卸载正在使用的共享。
- QQ 与飞书未挂载时，各自空挂载点权限为 `0500`，防止应用在 NAS 缺失时误向本地挂载点创建远端目录；发现挂载点有本地文件时拒绝遮蔽挂载。
- 断网后不把图片链接切换到本地，也不自动合并缓存，避免产生两套分叉数据。NAS 不可达时，QQ 图片可能暂时打不开；客户端会显示异常并重试。必要时退出对应应用后手动恢复本地。
- 自动检查最长约 55 秒；迁移和恢复最多等待约 10 分钟。超时保留日志与备份，不把超时报为成功；仍在退出中的迁移进程持有操作锁，阻止并发恢复。

## 命令

```bash
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --status
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --mount
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --enable-login
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --qq-migrate
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --qq-restore
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --feishu-migrate
"/Applications/WeChat NAS Mount.app/Contents/MacOS/WeChatNASMount" --feishu-restore
```

`--status` 只读，保留旧版的 `mounted`、`readableMediaDirectories` 和登录项字段，新增 `qq`、`feishu` 状态；异常返回非零退出码。`--mount` 连接所有已启用的应用。迁移与恢复命令要求对应的 QQ 或飞书已退出。

配置、配置备份、迁移记录和 `status.json` 位于 `~/Library/Application Support/WeChatNASMount/`。不要手工删除仍在使用的迁移记录或本地备份。

## 构建与检查

```bash
swift scripts/test.swift
./scripts/build.sh
```

ZIP 产物位于 `dist/`，临时应用包位于不参与索引的 `dist/.stage.noindex/`，使用临时签名。旧构建只保留 ZIP 归档，避免启动栏出现重复应用。GitHub Actions 在推送时构建；推送 `v*` 标签时发布 Release。

可选的真实 NAS 集成检查：

```bash
swift scripts/test-nas.swift
swift scripts/test-feishu-nas.swift
```

该检查复用本机已有微信配置中的 SMB 地址和凭据，但仅使用独立生成的测试文件。它会临时挂载 QQ 的固定挂载点、验证读写与离线保护并清理测试数据；若已有 QQ 迁移或挂载，会拒绝执行。不会操作真实 QQ 账号目录或卸载微信挂载。

飞书集成检查只使用独立生成的图片测试文件，验证独立挂载、NAS 读写、卸载后的本地写入阻止、离线恢复及重新挂载；真实飞书已迁移或挂载时拒绝执行。不会操作真实飞书账号目录。

单元/文件系统检查覆盖旧版配置升级、公共连接统一、微信媒体链接回归、QQ 与飞书校验及备份、迁移切换前失败、断开的 NAS 下恢复、迁移日志范围、目录越界及超时。真实注销/重启、睡眠唤醒和断网恢复需在实际安装后另外验收。

## License

MIT
