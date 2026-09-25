# Agent 笔记：运行时保持发布程序包不变以支持增量更新

状态：已实现

## 先说结论

Sparkle 增量更新依赖上一版 app bundle 的精确字节基线。Lithe 运行后不能把缓存、索引、
日志、插件状态或语言服务状态写回 app bundle；这些数据必须进入平台提供的 Caches、
Application Support、临时目录或工作区。macOS 的 JDTLS 配置现在会按 `config.ini` 的
SHA-256 复制到缓存后再启动，Windows/Tauri 也明确把语言服务状态放在 `app_cache_dir()`。

## 问题

JDTLS 的 Eclipse/OSGi 启动状态会写入它收到的 configuration 目录。旧实现直接把安装包内
的 `config_mac` 或 `config_mac_arm` 传给 JDTLS，用户启动一次 Java 语言服务后，
`Contents/Resources/LanguageServers/jdtls/...` 就多出运行时文件。Sparkle 生成的 delta
仍以干净发布包为源，更新时便出现 `Source doesn't have expected hash`，随后只能下载完整
ZIP。完整包下载成功掩盖了 bundle 已被运行时修改这一事实。

普通资源读取没有问题，问题在于把资源解析路径当成可写目录。只检查应用能否启动，不能
证明后续工作流没有修改 bundle；需要同时保护代码路径、开发提示和运行时回归测试。

## 决策

1. 发布 app bundle 和 Windows 安装目录中的打包资源统一视为只读发行物。构建脚本可以
   生成资源，运行时只能读取它们。
2. macOS `MacJDTLSLaunchResourceResolver` 对内置 JDTLS 的架构配置读取 `config.ini`，
   用稳定摘要命名 `Caches/Lithe/language-servers/jdtls/configurations/` 下的缓存目录，
   通过临时目录复制后原子移动。JDTLS 后续产生的 OSGi 状态只进入该缓存；外部 JDTLS
   仍保留兼容 wrapper 回退。
3. Windows/Tauri 的语言服务状态继续由 `app_cache_dir()` 提供，守护脚本禁止把
   `resource_dir()` 当作缓存目录。
4. 根目录 `AGENTS.md` 把资源生命周期、可写位置、签名和 delta 影响列为开发与审查要求。
   `scripts/verify-runtime-bundle-immutability.sh` 在 macOS 构建、服务边界检查和 macOS
   测试入口执行，扫描明显的 bundle 写入，并验证两个平台的语言服务缓存边界。
5. Swift 运行时测试在临时 bundle 中模拟 JDTLS 写入 OSGi 状态，断言状态出现在缓存、
   原始配置目录保持不变。这个测试和静态守护脚本分别覆盖行为回归与新增代码风险。

正确做法：从 bundle 读取固定 JAR 和 `config.ini`，把可变目录交给平台缓存 adapter。

不要这样做：在更新前删除 bundle 中的运行时文件，或只依赖文件权限阻止写入。崩溃、权限
变化、并发启动和更新时序都可能留下错误基线，而且会使已签名发行物变成不可预测状态。

## 考虑过的备选方案

- **每次 Sparkle 更新前清理 app bundle**：否决。清理发生得太晚，不能修复已经生成的
  delta 源哈希；清理失败也会继续造成回退，且会让更新器修改发行物。
- **把 JDTLS 状态放进用户项目或 `.lithe/`**：否决。索引和 OSGi 状态属于语言服务
  运行时，写入工作区会制造项目噪声、污染 Git，并让不同安装共享不兼容的绝对路径。
- **只把 `config.ini` 设为只读**：否决。Eclipse 会在目录中创建其他状态文件；只锁一个
  文件既不能阻止目录变更，也会把 JDTLS 失败转化为难以诊断的权限错误。
- **仅依赖人工发布前检查**：否决。回归发生在应用运行阶段，必须由构建入口的静态检查
  和真实 resolver 测试持续执行。

## 后果

- 增量更新重新使用干净的 app bundle 基线，JDTLS 首次启动只会增加用户缓存，不会改变
  已安装程序包。
- 每个不同的 JDTLS `config.ini` 摘要都会得到独立缓存目录，升级配置不会复用不兼容的
  OSGi 状态；缓存需要按现有 JDT workspace retention 策略清理。
- macOS 新增 runtime 写入必须经过平台存储 adapter，并在 Agent Note 或代码中说明
  生命周期和所有权。守护脚本是有意收窄的静态检查，复杂路径仍需要运行时哈希测试。
- Windows 的文件编辑、项目生成和用户插件写入工作区仍然允许；本约束只禁止把运行时
  生成物写进安装目录的打包资源。

## 验证

- `scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-agent-notes.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'macJdtlsResolverSelectsDirectLaunchResourcesDeterministically'`
- `./scripts/test-macos.sh`
- `git diff --check`

`macJdtlsResolverSelectsDirectLaunchResourcesDeterministically` 会在临时 app 资源目录中
创建完整 JDTLS fixture，resolver 返回缓存配置目录后向其中写入
`org.eclipse.core.runtime`，并断言原始 `config_mac*` 目录没有该文件。静态守护脚本还会
检查 macOS 生产 Swift 没有在同一表达式中把 bundle 路径交给写操作，并确认 Windows
缓存函数使用 `app_cache_dir()`。

## 适用范围

- `AGENTS.md`
- `scripts/verify-runtime-bundle-immutability.sh`
- `scripts/verify-macos-app-build-safety.sh`
- `scripts/test-macos.sh`
- `macos/Sources/Lithe/Platform/MacOS/Runtime/MacJDTLSLaunchResourceResolver.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Tests/LitheTests/JavaLanguageServerRuntimeTests.swift`
- `windows/tauri/src-tauri/src/lsp.rs`
- `docs/architecture/macos-updates.md`
