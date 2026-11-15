# Agent 笔记：Core 静态库变化必须使 Go 构建缓存失效

状态：已实现

## 先说结论

只更新 Rust Core 后，Viva 的 Go 构建可能继续链接旧内核。现在构建入口把实际静态库和相关链接输入的内容摘要加入 cgo 编译参数，保证 Core 变化时重新链接。输入不变时仍使用正常 Go 缓存，开发者不需要手动清缓存。

## 问题

cgo 是 Go 调用 C 接口的构建机制。`go help cache` 明确说明，构建缓存不会跟踪外部 C 库的变化；原入口每次暂存 Core，但路径和 Go 参数保持相同，无法通知缓存。

真实回归夹具先编译返回 1 的 C 静态库，再只替换成返回 2 的库。原入口第二次仍输出 1，说明客户端可能在编译成功后运行旧内核，甚至让验证结果失真。

## 决策

`desktop-go.sh` 对暂存静态库、C ABI 头文件和原生链接参数求 SHA-256；Windows 还包含实际选中的 Cargo import archive（链接所需的原生导入库）。摘要作为合法的 C 宏加入 `CGO_CFLAGS`，由 Go 自己将其纳入构建身份。摘要计算失败必须停止构建。

正确做法：修改 Core、运行同一入口，新的库字节触发重编译。不要只更新暂存路径中的库后直接复用旧的 Go 构建结果。普通 `go` 和 `--exec` 启动的工具使用同一套身份，避免包装入口各自遗漏。

## 考虑过的备选方案

每次清理全局缓存或传 `-a` 会反复编译未变化的依赖，拖慢日常开发。只把 Core commit 加入参数无法覆盖本地未提交的 Rust 修改，也无法覆盖原生导入库变化。更改 Go 链接参数需要解析不同 Go 命令的参数及调用者已有的参数，复杂度高于增加一个编译宏。

## 后果

每次入口多读一次参与链接的文件，不增加应用常驻内存或运行时工作。这个摘要只修复 Go 的缓存身份，不能把可变 Cargo 目录变成允许跨工作树复制的资源；资源清单仍明确拒绝复用。测试夹具只写独占系统临时目录，进程有界并在结束后删除，不改变发行包、代码签名或 Sparkle 增量更新基线。

## 验证

```bash
node --test scripts/desktop/desktop-core-cache.test.mjs
shellcheck -S warning scripts/desktop/desktop-go.sh
bash -n scripts/desktop/desktop-go.sh
```

macOS 上同一个真实编译夹具修复前输出旧值、修复后输出新值。Linux、Windows 的 CI 车道已接入该测试；未运行的平台结果不得从 macOS 外推。

## 适用范围

- `scripts/desktop/desktop-go.sh`
- `scripts/desktop/desktop-core-cache.test.mjs`
- `.github/workflows/desktop-ci.yml`
