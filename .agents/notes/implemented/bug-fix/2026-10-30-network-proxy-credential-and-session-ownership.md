# Agent 笔记：代理密码绑定身份，会话跟随请求释放

状态：已实现

## 先说结论

保存的代理密码只属于保存时的代理类型、主机、端口和用户名，不能因为修改设置或测试另一台代理就自动转送。网络请求通过租约持有会话，设置切换只替换缓存，不会让尚未创建请求的调用拿到失效会话。普通请求、连接测试和稳定版回滚复用同一个原生认证装配入口。

## 问题

只保存密码而从可变偏好恢复代理身份，会把旧密码重新绑定到另一台服务器。只锁住会话查询也不够：调用拿到会话后、创建请求前，另一线程就可能替换并使旧会话失效。回滚原先只复制代理字典，没有应答代理认证的处理器；连接测试只设置空闲超时，不能保证整体有界。

## 决策

代理身份与密码作为一个记录经安全存储端口写入 Keychain（系统钥匙串），不进入偏好、日志或普通输入框。Rust 策略命令比较保存身份与候选身份，主机去空白后忽略 ASCII 大小写，用户名去空白但区分大小写，类型和端口严格相同；不匹配时移除密码。只有用户明确输入的新密码不带已存身份。无身份的旧版密码不能推断归属，要求重新输入，不按当前地址自动迁移。

正确做法是测试代理 B 时保留密码原来的 A 身份，由 Rust 拒绝复用；不要把 A 的密码与 B 的草稿重新打包后发送。保存 B 的地址但没有新密码，也不会改变钥匙串里 A 的身份，重启后仍保持隔离。写入失败不更新内存凭据，保留用户输入供重试。

macOS 会话缓存与每个请求分别持有一个会话入口。请求租约的生命周期覆盖任务创建、响应等待，以及流式下载的完整消费；最后一个拥有者释放入口时，才允许已有任务结束并使会话失效。不返回可以立即被缓存替换操作失效的裸会话。设置改变时新请求使用新入口，旧请求的策略保持不变。自定义认证不使用进程共享凭据缓存，避免清除密码后被缓存重新提交。

回滚通过同一工厂构造带认证处理器的独立会话，保留自己的请求和资源超时。连接测试同时设置 10 秒空闲和资源总超时，视图拥有检查任务，离页、重置或草稿变化会取消请求并丢弃过期结果。会话、租约和检查任务都只占内存，不创建新的可复用缓存或发行目录资源。

## 考虑过的备选方案

- 修改地址时直接清空密码：重启仍可能从旧钥匙串重新绑定；独立更新身份和密码还可能在失败中产生不一致，因此将二者保存在同一安全记录中。
- 获取会话时加锁后立即使旧会话失效：锁不覆盖调用方后续的任务创建，仍有竞态。
- 永不使旧会话失效：避免竞态但留下原生 delegate 和连接资源；租约使用自动引用计数保留恰当生命周期，不需要再实现另一套任务计数协议。
- 让回滚仅复制代理字典：不能代替 Basic、Digest、NTLM 认证质询处理，因此复用完整原生会话工厂。

## 后果

跨代理密码隔离与两端共享规则由 Rust 和 fixture 保护。Swift 继续拥有钥匙串、原生会话及任务取消；流式调用必须保留租约至消费结束。旧版未绑定密码需要用户重新输入一次，这是避免错误迁移秘密的兼容代价。未改变 Sparkle、终端、Agent 或 JVM 的网络边界。

## 验证

- `./scripts/macos/test/test-macos.sh --filter 'NetworkProxySettingsTests|MacNetworkSessionProviderTests|MacNetworkProxyTesterTests|MacPluginPackageDownloaderTests|StableRollbackTests'`
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core network::tests`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/Network/`
- `macos/Sources/Lithe/Models/Settings/NetworkProxyPreferences.swift`
- `macos/Sources/Lithe/Views/App/NetworkSettingsView.swift`
- `macos/Sources/Lithe/Platform/MacOS/Updates/MacStableRollback.swift`
- `rust/lithe-core/src/network/`
- `shared/fixtures/network/proxy-policy-v1.json`
