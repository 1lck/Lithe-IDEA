# Agent 笔记：运行时保持发布程序包不变以支持增量更新

状态：已实现

## 先说结论

Sparkle 增量更新（differential update，只下载两个版本之间差异的更新包）依赖上一版
app bundle 的精确字节基线。所以 Lithe 运行时不能往已安装的程序包里写任何东西，
缓存、索引、日志、插件状态和语言服务状态都要放进平台缓存等可写目录。

JDT LS（Java 语言服务器）以前直接把安装包里的 `config_mac*`、`config_win` 当成
Equinox 的可写配置区，这是唯一一个按设计会写安装目录的地方。现在由 Rust Core 在
启动前把其中唯一的输入文件 `config.ini` 复制到平台缓存，macOS 和 Windows 走同一条
代码路径，安装目录从此只读。

## 问题

Equinox（JDT LS 使用的 OSGi 框架，负责加载插件）会往 `-configuration` 参数指定的
目录里写框架状态：`org.eclipse.osgi`、`org.eclipse.core.runtime`、锁文件等。旧实现
把安装包里的配置目录直接传给了它：

- macOS：`Contents/Resources/LanguageServers/jdtls/config_mac*` 在第一次启动 Java
  语言服务后就多出运行时文件。Sparkle 的 delta 以干净的发布包为源，更新时出现
  `Source doesn't have expected hash`，只能回退下载完整 ZIP。完整包下载成功，
  掩盖了 bundle 已经被运行时修改这件事。
- Windows：同一个 `config_win` 位于 `resource_dir()` 下的安装目录。NSIS 按用户安装
  时状态写进安装目录；MSI 按机器安装到 Program Files 时，这个目录本来就不该被
  普通用户写入。

普通资源读取没有问题，问题在于把资源路径当成了可写目录。只检查应用能不能启动
证明不了这一点，要比较一次完整工作流前后安装目录的文件清单。

## 决策

1. **已发布的 app bundle 和 Windows 安装目录都是只读发行物。** 构建脚本可以生成
   资源，运行时只能读取。规则写在 `develop-lithe` Skill 的
   “Keep installed packages read-only” 一节，根目录 `AGENTS.md` 只做入口，不重复
   这些规则。
2. **Rust Core 负责 JDT LS 的可写配置区**，代码在
   `rust/lithe-core/src/lsp/languages/jdt_configuration.rs`。平台适配层仍然把安装包
   里的配置目录作为 `jdtlsLaunchResources.configurationDirectory` 交给 Core；Core
   在启动进程前做这几件事：
   - 读取其中的 `config.ini`。JDT LS 发行包的 `config_*` 目录里只有这一个文件
     （已对照 1.61.0 发行包确认）。
   - 按 `config.ini` 的 SHA-256 选定目录
     `cacheDirectory/jdtls-configuration/<sha256>/configuration`，把文件复制进去，
     并把这个目录作为 `-configuration` 传给 JDT LS。`config.ini` 列出了每个 bundle
     的版本号，所以 JDT LS 升级后自动换到新目录，不会复用为另一组 bundle 记录的
     框架状态。
   - 多套一层 `configuration/`，是因为 `config.ini` 里有
     `eclipse.p2.data.area=@config.dir/../p2`，这样 p2 数据也落在同一个 SHA-256
     目录里。
   - 复制出来的 `config.ini` 缺失或内容不对时，用“临时文件 + rename”原子地重写。
     这个目录完全是派生数据，所以没有“缓存损坏、需要用户手动删除”的失败状态。
   - 写入前沿着缓存路径解析符号链接。如果缓存目录解析后落在 JDT LS 安装目录内，
     直接拒绝启动（`invalid_request`），不写任何东西。
   - 在区域根目录写 `.lithe-last-used`。其他 SHA-256 区域超过 JDT 工作区缓存的
     统一保留期（30 天，复用 `jdt_cache_retention`）没被使用就删除；删除失败只
     记 warn 日志，不影响启动。
3. **区域放在 `jdtls-configuration/`，和 `jdtls/` 并列。** 两个平台的工作区缓存
   清理只扫描 `jdtls/` 下的 64 位 hex 目录；如果把配置区放进去，一个正被其他安装
   使用的配置区可能被当成过期工作区删掉。
4. **macOS Swift 和 Windows Tauri 都不做复制。** 它们只负责发现安装包资源和提供
   平台缓存目录（macOS `Caches/Lithe/language-servers`，Windows
   `app_cache_dir()/language-servers`）。

正确做法：平台交出只读的安装包路径和平台缓存目录，Core 生成可写副本后再拼
`-configuration`。

不要这样做：在 Swift 或 Tauri 里各自复制一份配置目录，或者把缓存目录放进安装包
里的某个子目录。前者让两个平台分叉，本来就只有 macOS 修了；后者 Core 会直接拒绝。

## 考虑过的备选方案

- **Equinox 级联配置**（`-Dosgi.sharedConfiguration.area=<安装包配置目录>` 加
  `-Dosgi.configuration.cascaded=true`，upstream `bin/jdtls.py` 的做法）：否决。
  级联模式下，本地配置区为空时 Equinox 会读取父配置区里的框架状态。已经运行过旧版
  Lithe 的 Windows 安装目录里留着旧 JDT LS 写下的状态，安装器只覆盖自己安装的文件，
  这些运行时文件可能一直留着，级联会让新版本读到它们。只复制 `config.ini`（vscode-java 的做法）完全不读安装
  目录里的运行时文件。
- **在 macOS Swift resolver 里复制整个配置目录**（这个 PR 的第一版）：否决。只修了
  macOS，Windows 的同一个问题还在；整目录复制还会把旧版本写进 bundle 的状态一起
  搬进缓存。另外“缓存不完整就报错”会让 Java 语言服务一直不可用，提示“重装 Lithe”
  也解决不了，因为缓存在 Caches 里，重装不会清掉。
- **每次 Sparkle 更新前清理 app bundle**：否决。清理发生得太晚，修不了已经生成的
  delta 源哈希；清理失败也会继续造成回退，而且让更新器去修改发行物。
- **把 JDTLS 状态放进用户项目或 `.lithe/`**：否决。OSGi 状态属于语言服务运行时，
  写进工作区会制造项目噪声、污染 Git。
- **只把配置目录设为只读**：否决。Equinox 会把启动失败变成难以诊断的权限错误。

## 后果

- 增量更新重新以干净的 app bundle 为基线。JDT LS 首次启动只增加用户缓存，
  不改变已安装的程序包。
- 两个平台同一条代码路径，同一组测试；以后改 JDT LS 启动参数不会只修一边。
- 升级 JDT LS 后会留下一个旧的配置区（几 MB），30 天没被使用就自动删除。
- 已经被旧版本写过的安装目录：macOS 在这次更新时回退完整 ZIP 一次，替换后的
  bundle 是干净的；Windows 安装目录里的旧状态文件还在，但 JDT LS 不再读写它们。
- 守护脚本 `scripts/verify-runtime-bundle-immutability.sh` 只保留对 macOS Swift
  源码的通用写入扫描。JDT LS 的约束由 Core 的行为测试保证，不再用 grep 检查实现
  代码的字面量，也不再检查一段只在 macOS CI 上运行的 Windows 源码。

## 验证

- `jdt_configuration` 单元测试：安装目录前后逐字节一致、损坏副本自动修复并保留
  Equinox 状态、新 `config.ini` 使用新区域、缓存在安装目录内或经符号链接指向安装
  目录时拒绝且不写入、过期区域按保留期删除。
- `real_jdtls_discovers_builds_and_launches_java_25_entrypoints`：用真实 JDT LS
  完成导入、构建、classpath 解析后，断言安装目录的文件清单和大小与启动前一致，
  并且 `org.eclipse.osgi` 出现在缓存配置区。临时恢复旧行为时，这个断言会因为安装包
  配置目录里多出 `org.eclipse.osgi` 等目录而失败。
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/lsp/languages/jdt_configuration.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `rust/lithe-core/src/lsp/interface/engine_real_jdt_tests.rs`
- `shared/contracts/rust-core-api.md`
- `scripts/verify-runtime-bundle-immutability.sh`
- `scripts/verify-macos-app-build-safety.sh`
- `scripts/test-macos.sh`
- `.agents/skills/develop-lithe/SKILL.md`
- `docs/architecture/macos-updates.md`
