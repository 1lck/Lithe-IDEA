# Agent 笔记：Windows 验收进程身份失败必须留下可定位证据

状态：已实现

## 先说结论

真实产品退出前，无法读取某个进程的身份，不代表该进程已经退出。验收驱动现在保留失败的 Windows API、原始错误码、能够取得的进程身份及独立退出探测结果，清理失败也不能覆盖首次错误。读取元数据只申请查询和等待权限；终止操作继续由持有原内核句柄的既有对象负责，不按名称或历史进程号清理。

## 问题

TextWindow 曾在七项功能检查完成后、发送退出事件前，因 `OwnedProcess.capture` 返回空值而失败。原件只有泛化的身份读取错误，缺少失败 API、错误码、父进程号及创建时间。之后同构建独立通过，不能确定先前是权限、短命子进程退出竞态还是其他原因；旧失败的根因仍是 unknown。

Windows 会复用进程号（PID）。判断退出和授权清理必须保留原始身份，不能看到查询失败就忽略候选，也不能为了消除失败扩大权限或按名称杀进程。

## 决策

- 继续复用 `psutil` 的原生元数据查询和进程号复用检测，`OwnedProcess` 仍是唯一的句柄所有者。元数据路径只申请查询与等待权限；需要清理时才申请终止权限。查询句柄即使仍在运行，也不能调用终止 API。
- 原生捕获每次只执行一次 `OpenProcess`、`GetProcessTimes` 和 `QueryFullProcessImageNameW`。失败后立即读取 Win32 数字错误码，再关闭句柄或补查上下文；创建时间保留完整 FILETIME（Windows 原生时间的整数刻度），不经浮点转换。身份比较拒绝与 API 失败分别记录。
- 补充父 PID、程序名称时，每个现有 `psutil` 查询最多一次。补查失败记录错误类型与数字码，不覆盖捕获失败；不读取命令行、环境或凭据来补诊断。路径只保留文件名和规范化拼写的 SHA-256，不能反向还原完整私人目录。补查结果是观察上下文，不能授权终止。
- 退出证明仍使用已有 `process_exit_proven`：内核对象已发出退出信号或进程确实不存在才接受退出；访问拒绝、失败等待和未知结果继续失败。`process_exists` 复用这条规则，不能另用查询失败或退出码猜测缺席。
- `AppSession.stop` 把结构化诊断写入现有 `app-*.stop.json` 的 `processInspection`。异常路径直接尝试清理已保留的句柄，不先做一次可能遮蔽原始错误的额外等待。某个句柄查询失败时，仍尝试清理其余已知后代，保留未知状态及清理错误；不会因未知结果重试等待或宣布成功。

正确做法：`GetProcessTimes` 返回失败后先保存错误码 5，再分别记录父 PID 查询和零等待结果，最后以失败结束并清理已保留的句柄。不要关闭句柄后才读取原 API 错误码，也不要把第二次探测的错误替换成首次原因。

## 考虑过的备选方案

- 宽泛重试捕获或忽略短命浏览器进程：会隐藏真实权限错误，也无法证明原进程退出，因此不采用。
- 新增第二套进程管理器或 WMI 查询：已有 `psutil` 与句柄所有者足够，另建所有权会扩大竞态与清理责任，因此不采用。
- 把完整路径、命令行和异常文本写入新诊断：虽然信息更多，但可能暴露用户目录、令牌和参数。新结构只记录定位所需的字段；原始异常通过异常链保留，不复制到补充诊断文本中。

## 后果

下次失败可以区分原生 API、身份拒绝、元数据权限和退出探测失败，并保留第一次失败的数字码。代价是失败时多出有限的元数据查询和少量 JSON；这是诊断补强与已证明的错误保留修复，不证明旧 TextWindow 失败已经修复。

诊断沿用当前验收输出目录，不新增运行时下载或缓存，不写安装包及产品发行资源，不影响代码签名或 Sparkle 增量更新基线。产品、Java/JDT 和正式发布能力没有因辅助检查通过而开放。

## 验证

- `python -B scripts/plugins/host-acceptance/acceptance_driver_test.py --report .artifacts/test-stability/plugin-host-acceptance-driver.json`：确定性模拟失败 API→错误码→句柄关闭的顺序，覆盖查询/终止权限分离、精确创建时间、身份比较、原始/次要错误、未知等待、清理与诊断落盘；现有轻量原生子进程回归继续运行。执行时用现有 `native_browser_supervisor.py` 设置整个 suite 的 90 秒 watchdog，并检查 Job 成员归零。
- `node .agents/skills/write-stable-tests/scripts/generate-test-report.mjs`：查看逐项 HTML/JUnit 和预算，保留旧实现的失败报告，不能用新通过覆盖原失败。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`、`./scripts/agent-notes/verify-agent-notes.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`：检查稳定性、笔记和发行目录边界。

辅助回归不能替代真实 TextWindow 的退出、进程树清空和发行资源哈希不变验证；真实复现由统一持有重型验收令牌的协调流程执行。

## 适用范围

- `scripts/plugins/host-acceptance/acceptance_driver.py`
- `scripts/plugins/host-acceptance/acceptance_driver_test.py`
- `scripts/plugins/host-acceptance/native_browser_supervisor.py`
