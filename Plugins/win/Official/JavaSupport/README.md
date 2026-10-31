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

## 正式签名输入交接

在持有离线缓存的同一工作树检查候选。下面命令会调用既有组装器重新构建临时副本，逐文件比较候选、receipt、源码和固定上游输入，并在结束后移除临时副本；不联网、不启动 JVM、不调用签名器。需要约一份候选大小的临时磁盘空间，所有读取均受本地截止时间约束。输出报告必须是 `.artifacts` 下候选目录外的新文件，避免写入待签名树或覆盖旧证据。

```powershell
python scripts/plugins/check-windows-java-signing-inputs.py --candidate .artifacts/windows-java-support/local-x64 --phase before-signing --report .artifacts/windows-java-support/local-x64-before.json --timeout-seconds 300
python scripts/plugins/test-check-windows-java-signing-inputs.py
```

退出码 0 和 `inputCheck: passed` 仅表示签名输入准备检查通过。报告保留全部六项 `requires`、`publisherPackage` 来源、目标 JDK 平台和归档根、PE 架构、上游版本/许可/库存、源码及现有签名实现哈希。receipt 自身也会成为发布者签名的输入，正式签名后不能把它的 `unsigned-candidate` 状态改成“已签名”。组装器在原子发布前复查缓存和源码，拒绝解压期间被替换的输入。

真实发布者应在受控 macOS 发布环境、同一冻结 revision 使用已有 `LithePluginPackageSigner`；它以标准输入接收正式私钥，并仅接受现有信任表对应的密钥。不要在 Windows 新增另一套签名工具或修改信任根。下列命令只说明准确入口，必须由发布者执行；`candidate` 和 `signer` 由发布者设置为该次构建的真实路径。

```zsh
swift build --configuration release --product LithePluginPackageSigner
signer="$(swift build --configuration release --show-bin-path)/LithePluginPackageSigner"
# 正式环境通过既有 secret 注入变量；关闭 shell tracing，不打印、保存或传入命令行参数。
printf '%s' "$LITHE_PLUGIN_PACKAGE_PRIVATE_KEY" | "$signer" "$candidate"
"$signer" --verify "$candidate"
```

完成签名后，在拥有同一构建输入的工作树对该目录执行第二阶段检查，并交回完整报告与正式签名器验证结果：

```powershell
python scripts/plugins/check-windows-java-signing-inputs.py --candidate .artifacts/windows-java-support/local-x64 --phase after-signing --baseline .artifacts/windows-java-support/local-x64-before.json --report .artifacts/windows-java-support/local-x64-after.json --timeout-seconds 300
```

第二阶段要求全部原文件、receipt、签名实现和发布配置与第一阶段一致，只允许新增 `lithe-plugin-signature.json`。它记录签名文档哈希，却不解释或验证签名；即使文档来自测试密钥或内容无效，`publisherVerification` 仍为未执行，`productionAdmission` 始终为 false。正式签名器的 `--verify` 与生产 Windows 宿主负责拒绝无效或不可信签名。两个本地 JSON 报告是人工交接证据，不能当作签名凭据或产品准入开关。

最终 ZIP 必须独立解压，再对解压目录运行现有签名器 `--verify` 及相同的签名前后库存检查，最后计算 ZIP 的 SHA-256。发布元数据继续使用 `official-plugin-releases.mjs` 的实际 API、`requires`、平台和不可变标签规则，不能从今天的清单描述历史包。已签名目录或 receipt 不注册为跨工作树可复用缓存；发布者按同一固定输入独立构建，跨环境保留报告与归档身份。

当前缺口由报告明确列出：`releaseEnabled: false`、官方条目仍指向 macOS 目录、没有 Windows 资产；现有 workflow 的 macOS 构建/原生验证步骤不能直接发布 Windows 包。本地没有检查、读取或证明持有正式私钥。仍需真实发布者签名、原始目录及归档的完整签名验证、经审查的 Windows 发布路由和最终资产校验，随后完成生产宿主签名准入、完整 JDT 生命周期及目标架构实机验收，才能另行考虑开放能力或发布。
