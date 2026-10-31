# Windows Java Support 候选包

本目录由 Windows 产品独立维护，使用共享声明契约和已锁定的 JDT LS、JDK、Lombok、Java Debug 与 Java Test 上游资源。Java 语言服务继续经过现有 Java owner、Core JDT 计划和 Core LSP 会话，不通过通用 `java -jar` 启动绕过 JDT 集成。

当前为未签名候选，未进入正式打包或发布渠道。生产宿主尚不声明 `packageTrust`；清单保留全部 `requires`，不会为了通过校验而删除能力。测试只在 `cfg(test)` 范围临时提供候选能力和公开测试密钥，不赋予生产信任。

使用当前工作树已校验的 `.artifacts/jdtls-downloads` 与 `.artifacts/jdk-downloads` 离线组装：

```powershell
python scripts/plugins/assemble-windows-java-support.py --architecture x86_64 --output .artifacts/windows-java-support/local-x64 --timeout-seconds 300
python scripts/plugins/test-assemble-windows-java-support.py
```

`arm64` 选择 Windows AArch64 JDK、ARM64 PE 标识与 `config_win_arm`；合成归档测试只验证选择和文件边界，不能当作 ARM64 实机运行证据。所有下载来源与 SHA-256 由现有 `third_party/jdtls/manifest.json`、`third_party/jdk/manifest.json` 固定。脚本不联网、不执行 JVM、不签名，拒绝覆盖已有输出，失败清理本次 `.assemble-*` 暂存，成功原子发布新目录。

`windows-java-inputs.json` 记录输入来源、哈希、架构和输出文件清单，仅作为本次组装的证据。它不是签名或资源封装证明，包及回执均禁止跨工作树复用；只复用具有既有校验路由的下载缓存。运行时 JDT 状态应位于平台应用数据的 `plugin-state/<plugin-id>/jdtls`，包目录保持只读。

Java 的官方策略固定为 `publisherPackage`，另有 `bundledSignatureRequirement: sameTeamAsHost` 声明。Windows 的 EXE 或安装器 Authenticode 不会封住相邻资源，所以即使目录确实位于 bundled 根内，未签名 Java 包仍返回 `plugin.trust.hostSealRequired`。有签名的副本必须校验完整文件树，存在的坏签名不能忽略；安装记录或回滚记录不能伪造 bundled 来源。

清单提供 plain、Maven、Gradle 三类基础模板，保留项目生成和构建工具要求；不声称已具有 macOS 的 archetype、Spring 或所有向导能力。正式发布者签名、真实市场/磁盘完整包安装、禁用/升级/回滚/卸载、真实 JDT 设置与进程清理、发行目录哈希不变及 ARM64 产品验收仍是后续门槛，当前候选或测试通过不会开放生产能力。
