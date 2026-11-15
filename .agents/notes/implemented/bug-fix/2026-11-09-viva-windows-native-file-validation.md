# Agent 笔记：Viva Windows 原生程序识别与配置权限保留

状态：已实现

## 先说结论

Windows 文件没有 Unix 执行位，插件启动前应交给系统识别真正的程序，不能用 chmod 位判断。保存本机工具链配置时，必须把原文件的 Windows 访问控制权限保留到替换后的文件；只检查 Go 的读写模式不够。两项规则都由原生文件适配器实现，Core 继续拥有清单、路径与文档规则。

## 问题

Windows 上真实 Go 测试程序的文件模式通常是 `0666`。原包路径校验把它误判为不可执行，导致调试适配器根本没有启动；等待暂停的测试最后超时。只等待“会话消失”的夹具甚至会把启动失败误当成退出清理成功。

工具链保存器用新临时文件替换旧文件，虽然保留了 Go 可见的模式，原文件单独设置的访问控制列表（ACL，哪些用户可以访问文件）却被临时文件继承的目录权限替换。用受保护的用户专属权限做回归，可复现这项丢失。

## 决策

- 包路径仍逐段拒绝符号链接和非普通文件。Unix 使用执行位；Windows 使用系统的 [GetBinaryTypeW](https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-getbinarytypew) 识别 Win32/Win64 程序，不自己解析程序文件，也不运行它来探测。原生调用使用系统 DLL 和长路径形式。
- Windows 启动夹具声明并复制真实的 `.exe` 文件，遵循 Go 进程启动器的原生命名规则。退出回归必须证明进程确实创建过；启动失败时直接报告真实错误，不能等超时或只看会话为空。
- 原生配置发布先读取原文件的所有者、组、访问控制列表及继承保护状态，把这些权限应用到尚未发布的同目录临时文件。随后再次核对取消和字节基线，最后原子改名。任何权限准备失败都保留原文件，不忽略权限错误。
- 工具链 pin 保存复用 `configfile` 的受保护原生发布器，不再保留另一份命名路径式权限复制。元数据从已经打开的来源句柄读取并复制到临时句柄；权限回归必须保存实际改变的 pin，空重置不再触发写入，不能借无变化操作宣称权限发布已验证。
- “保留模式”的跨平台测试比较保存前后的原生模式。Windows 不要求返回 Unix 的 `0640`，但必须另外验证真实访问控制描述符不变。

正确做法是把新内容和原权限准备好之后再替换目标。不要先覆盖原文件，再尝试修权限；那样权限设置失败时已经改变了用户文件。

## 考虑过的备选方案

直接接受所有普通文件会把文本或伪装成 `.exe` 的数据当成程序，因此不用它代替执行位检查。自行解析 PE（Windows 程序文件格式）会重复系统加载器的工作，也不采用。

配置保存仅复制 chmod 模式无法表达 Windows 权限。直接采用带属性合并的文件替换接口还需要处理它的多阶段失败和恢复语义；这里先在未发布临时文件上准备权限，再沿用现有原子改名，让失败保留源文件的约束保持清楚。

## 后果

Windows 包内程序可通过原生校验，普通数据仍被拒绝；macOS/Linux 的执行位规则不变。保存器多做少量原生元数据操作，但它只发生在后台的明确保存动作，不增加渲染或常驻工作。无法保留原权限时保存失败并保留草稿，不悄悄放宽访问权限。

这是原生文件边界的验证，不代表插件市场安装、全部调试传输、原生窗口或发行更新已验收。包内程序只读取，配置和临时文件仍属于工作区，不写入安装目录或应用资源。

## 验证

在 Lithe-dev 的真实 Windows 上：`TestResolveExecutableAcceptsWindowsImageAndRejectsData` 先因 Unix 执行位误判失败，修复后通过；同时覆盖原生程序识别和伪 `.exe` 拒绝。`TestSavePinPreservesWindowsSecurityDescriptor` 先证明保存丢失用户专属权限，修复后通过。macOS 上相关 pluginhost/toolchain 测试通过。

```bash
scripts/desktop/desktop-go.sh test ./internal/pluginhost ./internal/toolchain ./internal/workbench -count=1 -timeout=180s
```

逐项计时仍使用 `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope DesktopGo`；完整流程以本次提交自己的报告为准，不借用修改前的 Windows 结果。

## 适用范围

- `desktop/internal/pluginhost/executable_windows.go`
- `desktop/internal/pluginhost/executable_other.go`
- `desktop/internal/pluginhost/pluginhost.go`
- `desktop/internal/configfile/metadata_windows.go`
- `desktop/internal/configfile/configfile.go`
- `desktop/internal/toolchain/pins_windows_test.go`
- `desktop/internal/workbench/debug_test.go`
