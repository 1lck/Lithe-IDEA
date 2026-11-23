# Agent 笔记：目录索引排除与项目树可见性分离

状态：已实现

## 先说结论

目录能否在树里浏览，与是否进入 Lithe 自有索引是两种不同的策略。
手动排除及 Git 自动排除由 Rust Core 判断，两端只存储项目偏好并触发刷新。
语言服务拥有自己的扫描器；Java 导入排除不能当作整个 Java 资源扫描已停止的证据。

## 问题

目录标记原本是显示角色，用户把目录标记为已排除后仍可能进入搜索缓存。
复用隐藏名单可以减少扫描，却会同时让用户无法在树里找到目录，违反浏览需求。

## 决策

Viva 的单项目排除规则存于用户配置目录的项目哈希文件。读取失败（非法 JSON、权限不足或本版本不认识的已有字段形状）时，本会话以默认规则启动以保持工作区可用，同时记录一次 `app.settings.decode_failed`，`stage=directory_rules`。**这次会话不能编辑排除规则或 Git 自动排除开关**：否则会把加载失败误当成空规则覆盖原来的用户设置。用户修复原文件并重新打开项目后才恢复编辑；只重建索引和正常查询不会碰持久文件。`Store.Unread` 的兼容形状失败也视作无法安全编辑，不能仅靠 `Load` 的 nil error 判定文件已完整读取。

Git 忽略语义交给本机 Git 的 `check-ignore`；查询同层目录时批量提交，
再用 `ls-files` 保护已跟踪后代。单个被忽略文件不会被升级成目录排除。
关闭自动排除保留手动标记与包含例外；应用存储不写入 `.gitignore` 或 `.iml`。

两端开关统一放在“设置 › 版本控制 › Git”，紧接程序与凭据设置，删除独立索引
页面及项目环境页中的重复入口。开关仍绑定当前工作区，Git 页切到全局配置或
选择子仓库都不改变它的范围；无项目时只显示禁用控件，不创建偏好。作用范围、
取消排除例外和语言服务限制放入同一说明提示，读取或保存错误仍直接显示。

已排除目录的标记子菜单只保留“取消排除”，避免在仍受排除策略约束时直接改成
源码、资源等角色。手动排除与 Git 自动排除使用同一菜单规则；取消后恢复普通
目录可用的标记选项。普通文件夹只改变角色，不创建包含例外；只有明确的取消
排除动作才创建例外：取消手动排除恢复记忆角色，取消 Git 自动排除保留当前角色。
修改任何普通角色都保留已有例外，只有明确手动排除删除该目录自身的例外。
不能用历史记忆角色覆盖自动排除前仍有效的源码、资源等角色。
不能猜测旧例外的产生原因，因此不自动删除
历史例外。继承手动排除的子目录仍须到对应父目录取消排除。
树中的排除状态使用目录图标及提示表达，目录后代仍可浏览；文件名文字保留
独立的 Git 状态颜色，不把整个排除子树统一染色而遮盖修改或冲突状态。

排除目录的文件仍可打开编辑。语言服务工作副本不自动打开这些文件；
已有工作副本在策略变化后关闭并清除其诊断。Java provider 合并导入排除配置，
但构建系统显式声明的模块和依赖仍由构建工具决定。Java 会话保留插件初始化时
原有的导入排除项，每次初始化、配置查询和动态通知都重新合并当前策略；取消
Lithe 排除不能清除插件规则，也不能把上一次合并结果作为下一次的原始配置。

多根库存、搜索与替换请求显式携带当前工作区的根集合。父根到达另行登记的嵌套
根时停止索引遍历，由嵌套根按自己的偏好生成候选。例如打开 `main` 与
`main/nested`，只在后者排除 `archive`，父根不能再把该目录加入候选或读取内容。
这一边界进入缓存身份，保存和 watcher 直更也保留同样的边界；移除嵌套根后，
父根恢复扫描。失效的无关附加根不应阻断当前根的限定搜索；尚未移除的缺失嵌套
根仍保留归属边界，避免目录重建后从父根回填。不能从 Core 全局策略表推断根成员，否则另一个窗口的策略或关闭
后保留的退役记录会改变当前窗口的结果。只过滤最终结果也不够，因为文本已经
被读取并驻留索引。
同一搜索请求的目录范围同时过滤文件名、类型、符号和内容来源，并在结果上限与
分页游标之前应用，不能让范围之外的候选占满一页。

语言服务的文档提交、诊断接受和就绪队列发送与策略撤回使用同一会话同步边界。
锁顺序为索引边界、发送顺序、会话状态；库存扫描先在这些锁之外准备。就绪时还
须重查排队文件的资格，防止策略已安装、会话撤回尚未执行时发出旧事件。路径
判断解析符号链接，删除事件使用最近仍存在的祖先，避免同一文件的 URI 别名
绕过排除。

后台刷新不建立全文索引；只有运行中的语言服务需要目录判断时才扫描目录。
完成后，已挂载编辑器由原来的 hook 接回文档所有权，工作区控制器只重查未挂载
的源码 buffer。最初就被排除、尚未启动语言服务的 buffer 也要重新准入；没有
LSP provider 的文件跳过，单个 provider 失败不能中断后面的文档。工作副本重开
等待在途关闭，打开后再同步期间的新编辑；补同步失败保留已打开的 owner，使
后续编辑仍可重试并能正常释放 attachment。每个异步边界检查运行实例、根成员、
buffer、挂载状态及 attachment；不重启整个语言服务。
全局 Git 忽略文件仍通过激活、焦点和显式刷新补偿，不持续监听任意外部配置。
本轮不新增“恢复跟随 Git”菜单，也不迁移已丢失的历史角色和例外。

## 考虑过的备选方案

- 复用隐藏路径：会隐藏目录，不能满足浏览与编辑需求。
- 自行解释 Git 通配符：无法完整复现嵌套规则、否定规则和已跟踪内容。
- 只过滤搜索结果：无法减少目录访问、文本读取和索引驻留量。
- 禁用整个语言服务：会影响未排除源码；采用工作副本门禁及 provider 能力提示。

## 后果

原有隐藏名单仍独立生效。新策略不会让隐藏目录重新出现。
内置隐藏规则被用户通过 `!` 条目取消后，该条目须继续传到 Core 库存和 watcher
过滤，不能在某一层重新加入已取消的内置隐藏项。显示该目录也不代表取消其
Git 索引排除。本地历史的单条通配符匹配不使用工作区索引的嵌套根边界；
构造独立规则时显式保留空边界，不把索引策略变成本地历史规则的来源。
重命名和移动同样不能从索引候选枚举历史文件。工作区对选中的源、目标调用一次
历史迁移，Core 根据历史存储的元数据迁移精确路径及目录后代，保留相对后缀；
例如排除 `archive` 后重命名为 `archive-old`，已有 `archive/notes.txt` 的记录仍须
出现在新路径。不要为了迁移历史重新扫描排除目录或把后代加入索引库存。
目录标记由树与索引配置共用同一个存储读取和结构校验器，错误类型放在无运行时
依赖的模块。搜索不能自行 `JSON.parse` 并在字段缺失时安装空标记，否则树与搜索
会对同一份损坏数据作出不同决定，原始解析错误也会绕过本地化。
自动规则的决策缓存按需建立，因此状态中的目录集合不是完整的文件系统清单。
Git 失败必须保留手动排除并报告失败，不能报告成无忽略规则。
Java 的导入配置仅属部分支持；Rust 与 Go 分别合并原生目录列表与有序过滤规则，
配置源保持原样，取消排除后恢复原值。原生动态重扫效果仍需运行时验收。
同一 provider 同时使用嵌套对象与点分键时，递归合并对象，保留无关兄弟字段；
冲突叶子由点分键覆盖，更具体的点分前缀最后应用，再叠加当前目录排除。
Python/Basedpyright 的项目配置可以覆盖语言服务器配置，因此不改写其项目配置，
界面明确提示不能保证扫描排除。其他 provider 保持运行。

上游依据：
- [rust-analyzer 配置](https://rust-analyzer.github.io/book/configuration#rust-analyzerfilesexclude)：相对路径，不支持通配符。
- [gopls directoryFilters](https://go.dev/gopls/settings#directoryFilters)：最后匹配规则优先，并保留上游默认过滤。
- [Basedpyright 服务设置](https://docs.basedpyright.com/latest/configuration/language-server-settings/)：项目配置可以覆盖 exclude。

## 验证

- `./scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench`：库存剪枝、目录标记、排除策略与语言服务门禁的回归。
- `./scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestUnreadableDirectoryRulesAreLoggedAndNeverReplacedByAnEdit|TestStartupBackgroundLogsUnreadableStoredColor|TestLogEventsMatchCatalog' -count=1`：整份无效 JSON 与已知字段形状无法读取时，都使用默认值且记录类别；排除编辑不改原文件，启动背景读取不改原文件。
- 在 Core 仓库运行 `cargo test -p lithe-core project::indexing`：真实目录访问剪枝、树浏览、旧版本拒绝、保存回填防护与例外优先级（共享 fixture 为 `rust/fixtures/workspace/indexing-policy-v1.json`）。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`。
- `./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- `desktop/internal/core/workspace_indexing.go`
- `desktop/internal/workbench/directory_exclusions.go`

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/indexing.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/indexing.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/search_index.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/search_index.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/workspace/indexing-policy-v1.json`
