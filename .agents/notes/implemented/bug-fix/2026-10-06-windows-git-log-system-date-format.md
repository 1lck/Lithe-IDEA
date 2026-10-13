# Agent 笔记：Windows Git Log 日期遵循系统格式

状态：已实现

## 先说结论

Windows Git Log 的英文日期不再由翻译模板固定为日/月/年，而是读取 Windows 的短日期和时间格式，包括用户自定义格式。提交作者时间先转换到本机时区，再计算今天、昨天和相对分钟数。中文界面继续使用中文地区格式；本次不新增日期设置页面，也不改变 macOS 产品。

## 问题

同样是英文界面，IDEA 和 PyCharm 会随本地系统显示月/日/年或日/月/年，Lithe 却固定显示日/月/年和 12 小时制。原来的同时区限制还会让其他时区的近期提交无法显示相对时间。

## 决策

以 IntelliJ Community 本地版本 `fb72b4df43ab` 为依据：Git Log 的 `VcsLogDefaultColumn.kt` 调用 `DateFormatUtil.formatPrettyDateTime`；英文默认读取系统格式，日期时间显示转换为本机时区。Lithe 对齐这一默认行为，已有的相对分钟措辞和刷新机制继续保留。

平台适配器（负责调用操作系统的代码）通过 `GetDateFormatEx` 和 `GetTimeFormatEx` 读取用户格式，React 日期单元格只接收格式化结果。调用不写注册表、不写安装目录，也不创建缓存文件；结果由单元格持有，卸载或提交变化后拒绝迟到结果。

正确做法是把作者日期和 UTC 偏移还原为绝对时间，再交给平台显示。例如同一瞬间来自不同作者时区，仍应显示相同的“5 minutes ago”。不要直接把作者墙上时钟的数字与本机当前时间相减，也不要在英文翻译中写死月份顺序。

未知偏移的旧数据仍只显示绝对日期，无法解析的日期原样显示。浏览器预览使用 `Intl.DateTimeFormat` 的地区默认格式；原生调用失败时记录错误并保留这一显示回退，不能把浏览器验证当作 Windows 自定义格式验收。

## 考虑过的备选方案

- 将英文模板改成月/日/年：只能匹配美式设置，仍无法遵循英式或自定义格式。
- 固定使用 `Intl.DateTimeFormat("en-US")`：能显示美式日期，但不能读取 Windows 用户对短日期和时间的覆盖设置。
- 在前端解析 Windows 日期模式：需自行维护格式语法、引号、历法和本地化名称，直接调用原生格式化接口更可靠。

## 后果

英文日期顺序、补零、分隔符和时间制与 Windows 用户设置一致；每个可见单元格挂载或提交变化时进行一次原生调用，鼠标移入刷新只重新计算相对时间，不重复调用原生接口。系统格式变更可在重新打开 Git Log 后生效，不增加整表定时刷新。

本次仅对齐系统默认显示，不复制 IDEA 的日期覆盖设置页面、提交者日期切换或相对分钟取整边界。右侧提交详情仍显示既有后端原始日期。

## 验证

- `.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend` 可通过 `-FrontendTestPath` 定向验证日期工具、原生结果显示及迟到结果保护。
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml --bin lithe-windows date_time::tests` 验证原生美式/英式日期顺序、时间制和非法时间戳。显式地区测试关闭用户覆盖，不修改系统设置。
- `scripts/verify-runtime-bundle-immutability.sh` 检查运行时安装目录只读边界。
- `scripts/verify-agent-notes.sh` 和 `scripts/verify-platform-feature-matrix.sh` 验证记录。
- 在真实 Windows 产品中对比系统短日期/时间设置和 Git Log，检查英文、中文、跨时区提交以及重新打开后的格式生效。

## 适用范围

- `windows/tauri/src/platform/system-date-time.ts`
- `windows/tauri/src-tauri/src/date_time.rs`
- `windows/tauri/src/features/git/utils/git-log-date.ts`
- `windows/tauri/src/features/git/components/log/git-log-date-cell.tsx`
- `shared/platform-feature-matrix/features/git-history.json`
