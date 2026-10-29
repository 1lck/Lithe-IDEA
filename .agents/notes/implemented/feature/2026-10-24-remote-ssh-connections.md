# Agent 笔记：远程开发的 SSH 连接配置、测试与单连接启动

状态：已实现

## 先说结论

欢迎页的“远程开发”按钮会打开一个连接窗口：左侧是保存的 SSH 连接，右侧是表单、测试连接和主机信息。连接列表存在偏好设置里，密码和私钥口令只存在单独的钥匙串服务 `remote` 里，从不发给 Rust Core。测试、浏览和打开都通过系统 OpenSSH 完成，OpenSSH 提出的每个问题（密码、口令、验证码、未知主机指纹）都弹窗问用户。连接主机时只用**一条** SSH 连接完成探测、安装和启动远端服务，所以需要密码的主机只认证一次。

## 问题

远程开发需要一个地方告诉 Lithe“连哪台机器、怎么登录”，并且在打开项目前确认这台机器能用。难点有三个：

- 认证方式很多：`~/.ssh/config` 别名、SSH Agent、私钥文件、密码、2FA。Lithe 不应该自己实现 SSH，也不能把密码放进命令行或环境变量。
- 一次“连接”要做好几件事（探测平台、检查已安装的服务、上传、启动）。每件事各开一条 SSH 连接，用密码登录的主机就会被连续问好几次。
- 连接信息里有秘密，必须和普通设置分开存放。

## 决策

### 连接配置放在哪里

- 连接模型 `RemoteSSHConnection` 只包含会改变目标或认证方式的字段，以及用户起的名字、选中的远程文件夹和上次检查到的主机信息。它存在偏好设置键 `lithe.remote.ssh-connections.v1` 下，由 `RemoteConnectionStore` 负责读写。
- 勾选“记住到钥匙串”时，密码或私钥口令存在钥匙串服务 `remote`、键 `remote.ssh.<连接 id>.secret` 下。取消勾选、删除连接或改成不需要秘密的认证方式时，保存会顺带删除这个条目。
- 窗口像 IDEA 的运行配置一样，把整张列表当作一份工作副本来编辑：点“保存”才写入，关窗口不保存。唯一例外是“上次检查到的主机信息”：它不是用户的修改，已经保存过的连接会立即单独写回，不会把表单里其他没保存的修改一起写进去。

### 认证怎么问

- Rust Core 用 `lithe-git-host` 的 AskPass（由 Lithe 自己充当 `SSH_ASKPASS` 程序、通过带令牌的回环 socket 把问题转给主程序）会话启动 `ssh`，和 Git 共用同一套机制。每个问题变成一个 `authentication` 事件，界面用 `remote.authRespond` 回答一次。
- 记住的秘密只在**第一次**、并且提问内容明确是在要它时自动填入：密码认证的提问里要有 `password`，私钥认证的要有 `passphrase`。验证码、主机指纹确认，以及任何重复的提问都交给用户，所以记错的密码不会被悄悄重复发送。
- 认证方式只翻译成 OpenSSH 选项：私钥对应 `IdentityFile` + `IdentitiesOnly=yes`，密码对应 `PreferredAuthentications=keyboard-interactive,password`，等等。另外始终加上 `BatchMode=no`，避免用户配置里的 `BatchMode yes` 把提问吞掉。连接里设置的选项排在传输链默认的保活选项前面，因为 OpenSSH 对每个选项只认第一次出现的值。

### 单连接启动

`lithe_remote::client::launch` 在远端跑一段单行 POSIX `sh` 脚本：

1. 先输出主机详细信息和平台标记块；
2. 客户端按平台选出随 App 附带的服务，把“版本 SHA-256 大小 目录名”作为一行写回；
3. 远端已有报告相同哈希的服务就直接复用，否则从同一条流里读取刚好那么多字节，写到临时文件名后再改名，并再次校验；
4. 最后 `exec` 启动服务，协议会话接着在同一条流上开始。

安装目录和 `Bootstrapper` 一致（`~/.lithe-server/bin/<版本>-<哈希前 16 位>`），两条路径装的服务可以互相复用。脚本要穿过 SSH 跳转，所以不含 `'`、`\`、`!` 和换行。

### 随 App 附带的远端服务

`scripts/remote/build-remote-servers.sh` 用 Rust 自带的 `rust-lld` 从 `lithe-remote` crate 只启用 `server` feature，构建两个 Linux musl 静态版，输出到 `rust/target/remote-servers/`，同时写一个 `manifest.json` 记录服务版本。打包时复制到 `Contents/Resources/RemoteServers/<目标>/lithe-remote-server`。源码合并不改变这个可执行文件名或安装身份，构建组合见远程工作区路由 Note。

- 这是只读的固定输入：运行时只读取它并上传给主机，不往这个目录写任何东西，所以不影响代码签名和 Sparkle 增量包。
- Linux ELF 文件对 `codesign` 来说只是资源。macOS 版服务是 Mach-O，需要 Developer ID 签名和公证，所以暂时不附带；远程 Mac 会显示“暂不支持这个平台”。
- 构建输出在每个 worktree 自己的 Cargo 目标目录里，从源码重新构建，不跨 worktree 复用。

### 主机信息与 IP 地区

探测脚本额外输出 `key=value` 格式的主机名、发行版、内核、CPU、内存、磁盘和运行时长；原始输出在客户端解析，这样脚本里不需要那些不能穿过 SSH 的字符。主机地址用本机系统解析器解析。**只有用户点击“查询地区”时**，才会把这个地址通过 HTTPS 发给 ipinfo.io；内网和保留地址在本地判断，不会发出去。

## 考虑过的备选方案

### 用 OpenSSH 连接复用（ControlMaster）避免重复认证

最吸引人的地方是不需要新脚本。不采用的原因是：执行 ssh 的进程运行器会在 ssh 退出后结束整个进程组，复用主进程可能被一起结束；`ControlPath` 的长度和权限在不同系统上也各有坑。单连接启动不依赖这些行为。

### 在 Lithe 里自己实现 SSH 并保存密码

见 `.agents/notes/proposed/architecture/2026-10-24-remote-development-workspace-host.md` 中“内置 SSH 库”一节：会丢掉用户的 SSH 配置、ProxyJump 和各种 Agent。现在由 OpenSSH 负责认证，Lithe 只负责回答它提出的问题。

### 自动查询 IP 地区

会在用户不知情时把服务器地址发给第三方，所以改成手动触发，并在 ⓘ 里写明会发给谁。

## 后果

- 新增 Core 命令 `remote.probe`、`remote.connect`、`remote.readDir`、`remote.readFile`、`remote.writeFile`、`remote.disconnect`、`remote.authRespond`，契约见 `shared/contracts/rust-core-api.md` 的“Remote connections”一节。
- 三个打包 workflow 需要安装 `x86_64-unknown-linux-musl` 和 `aarch64-unknown-linux-musl` 目标。
- 连接打开后由 Core 持有，直到 `remote.disconnect` 或 App 退出；断线不会自动重连：Core 返回 `connection_closed`，传输层首次发现时通知所属窗口，弹出远程开发窗口并预选原连接，用户重新认证后恢复同一个远程文件夹，工作区随之重新加载。关闭项目会释放连接。

## 验证

```bash
cargo test --manifest-path rust/Cargo.toml -p lithe-remote --lib
cargo test --manifest-path rust/Cargo.toml -p lithe-remote --all-features --test server
cargo test --manifest-path rust/Cargo.toml -p lithe-core remote::
./scripts/macos/verify/verify-runtime-bundle-immutability.sh
```

`lithe-remote-server` 的 `one_connection_installs_once_and_starts_the_server` 通过本机传输验证“首次上传、再次复用、两次都能建立会话”。`lithe-core` 的远程测试用假 `ssh` 覆盖选项映射、失败分类、平台不支持和主机信息解析。

## 适用范围

- `macos/Sources/Lithe/Views/Workspace/RemoteConnectionsView.swift`
- `macos/Sources/Lithe/Application/Features/RemoteConnectionsFeatureModel.swift`
- `macos/Sources/Lithe/Services/Remote/RemoteConnectionStore.swift`
- `macos/Sources/Lithe/Platform/MacOS/Remote/`
- `rust/lithe-core/src/remote/`
- `rust/lithe-remote/src/client/launch.rs`
- `scripts/remote/build-remote-servers.sh`
