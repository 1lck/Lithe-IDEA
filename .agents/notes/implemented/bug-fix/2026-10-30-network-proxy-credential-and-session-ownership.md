# Agent 笔记：代理密码绑定身份

状态：已实现

## 先说结论

保存的代理密码只属于保存时的代理类型、主机、端口和用户名，不能因为修改设置或测试另一台代理就自动转送。密码与身份作为一个记录写入系统钥匙串，不进入偏好、日志或普通输入框。比较规则由 Rust Core 决定，桌面端只负责展示、保存和把 Core 的结论落到请求上。

## 问题

只保存密码而从可变偏好恢复代理身份，会把旧密码重新绑定到另一台服务器。只保存地址而不保存身份，修改地址后旧密码就会被当作新服务器的凭据发送出去。

## 决策

代理身份与密码作为一个记录经安全存储端口写入系统钥匙串（`desktop/internal/credentials`，macOS 后端在 `backend_darwin.go`）。Core 的比较规则（`network` 模块）：主机去空白后忽略 ASCII 大小写，用户名去空白但区分大小写，类型和端口严格相同；不匹配时移除密码。

- 只有用户明确输入的新密码不带已存身份。
- 无身份的旧版密码不能推断归属，要求重新输入，不按当前地址自动迁移。
- 保存另一台代理的地址但没有新密码时，不改变钥匙串里原有的身份，重启后仍保持隔离。
- 写入失败不更新内存中的凭据，保留用户输入供重试。

正确做法：测试代理 B 时保留密码原来的 A 身份，由 Core 拒绝复用；不要把 A 的密码与 B 的草稿重新打包后发送。

代理的凭据只用于拼装代理地址（`desktop/internal/core/network.go` 的 `NetworkProxyIdentity` 与密码字段，以及 `desktop/internal/netproxy/netproxy.go` 的 `proxyURL`），不写入日志。

## 考虑过的备选方案

- **修改地址时直接清空密码**：重启仍可能从旧钥匙串重新绑定；独立更新身份和密码还可能在失败中产生不一致，因此将二者保存在同一记录中。

## 后果

跨代理密码隔离由 Core 的规则和共享 fixture 保护。旧版未绑定密码需要用户重新输入一次，这是避免错误迁移秘密的兼容代价。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/netproxy/... ./internal/credentials/...`：代理策略与凭据记录的测试。
- Core 仓库的 `network::tests`（以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准）。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`

## 适用范围

- `desktop/internal/core/network.go`
- `desktop/internal/netproxy/netproxy.go`
- `desktop/internal/credentials/credentials.go`
- `desktop/internal/credentials/backend_darwin.go`
- `desktop/internal/settingswindow/network_view.go`
- `desktop/internal/workbench/network.go`
- Core 仓库的网络代理规则与 [`proxy-policy-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/network/proxy-policy-v1.json) 夹具
