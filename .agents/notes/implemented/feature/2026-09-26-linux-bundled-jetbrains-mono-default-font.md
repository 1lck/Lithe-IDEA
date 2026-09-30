# Agent 笔记：Linux 内嵌 JetBrains Mono 作为全局默认字体

状态：已实现

## 先说结论

Linux 工作台的全局默认字体改为 **JetBrains Mono**，并且字体文件**内嵌在二进制里**
（`linux/assets/fonts/` 下的 4 个 TTF 经 `include_bytes!` 打进 `linux/src/fonts.rs`），
不依赖用户系统是否安装。同时把设置弹窗的「编辑器字体」接成**真正生效**的等宽字体
来源：**UI 全局字体固定为内嵌 `FAMILY`，编辑器、代码/日志显示与终端都跟随设置里的
`fontFamily`（出厂默认也是 JetBrains Mono）**。开发者要记住四件事：**新增等宽文字
用 `crate::fonts::mono_family(cx)` 或 `Theme.mono_font_family`，不要硬编码字体名或
写 `"monospace"`**；**要改出厂默认字体族只改 `linux/src/fonts.rs` 的 `FAMILY`**；
**每次 `Theme::change` 之后都要调用 `fonts::apply_theme`**，否则主题切换会把字体
字段重置回系统默认；**不要为了让字体生效去要求用户手动装字体或改系统 fontconfig**。

## 问题

工作台此前没有任何内嵌字体，UI 主题字体是 gpui-component 的默认值
（Linux 上落到 `CosmicTextSystem` 的默认族），编辑器默认字体族设置写的是
`"Geist Mono"`，而终端写死 `"monospace"`。结果是：

- 三处字体名各写各的，字体行为随机器是否装了对应字体而漂移；
- 缺字体时 GPUI 会走回退栈，字形与预期不一致，用户看到的默认字体因机器而异；
- 终端默认字体族与 UI/编辑器不统一。

产品需要一个跨机器一致的默认字体。

## 决策

### 内嵌而不是依赖系统安装

`linux/assets/fonts/` 放置 `JetBrainsMono-{Regular,Bold,Italic,BoldItalic}.ttf`
与 `OFL.txt`，`linux/src/fonts.rs` 用 `include_bytes!` 内嵌，启动时经
`cx.text_system().add_fonts(...)` 注册进 GPUI 文本系统（Linux 走
`CosmicTextSystem`，`add_fonts` 会把字节载入 cosmic-text 的 fontdb）。这样：

- 任意机器上字体都存在，不需要用户 `fc-cache` 或装系统字体；
- 四个字重/样式覆盖 UI、代码高亮（粗体）与终端斜体，避免 GPUI 合成字形。

字体以 SIL Open Font License 1.1 分发，许可证与字体同目录保留。

### 单一来源 + 每次主题切换后重设

- `fonts::FAMILY` 是内嵌字体族名，也是**出厂默认**：`settings.rs` 的
  `font_family` 默认值取它，所以设置弹窗初始就显示 JetBrains Mono。
- `fonts::mono_family(cx)` 返回**当前生效的等宽字体族**：读取设置 `fontFamily`，
  为空时回退到 `FAMILY`。编辑器、代码/日志显示与终端都经它取字体。
- `fonts::apply_theme(cx)` 把 UI 字体设为 `FAMILY`、等宽字体设为 `mono_family(cx)`：
  - `Theme.font_family`（UI 全局）固定 `FAMILY`；
  - `Theme.mono_font_family`（gpui-component 的 `Editor` 在
    `input/editor.rs` 就读取它）跟随设置。
- **必须在每次 `Theme::change(...)` 之后调用**：`change` 会按当前主题重新
  `apply_config`，可能覆盖字体字段。
- 字体的注册（`fonts::register`）只做一次，且要早于窗口创建，保证首帧文本布局
  就能命中新字体。

### 设置项「编辑器字体」必须真正生效

- 下拉写入 `settings.font_family` 后，回调里立刻 `fonts::apply_theme(cx)` 并
  `cx.refresh_windows()`，让编辑器/代码/终端在使用中即时换字体，无需重启。
- 旧配置里遗留的旧默认值 `"Geist Mono"`（只是历史默认、并非用户真实选择）在
  `settings::load` 时迁移为 `FAMILY`；空值同样回退 `FAMILY`。归一化函数是
  `migrated_font_family`，有单测覆盖。
- 下拉选项里已去掉未随产品分发的 `"Geist Mono"`，避免用户选到一个不存在的字体。

### 正确做法

- 新增需要等宽文字（代码、日志、路径、终端）的地方，用
  `crate::fonts::mono_family(cx)`，不要新写 `"monospace"` 或字体名字面量。
- 新增普通 UI 文字不需要设字体族，继承 `Theme.font_family` 即可。
- 主题切换路径（`main.rs` 与 `workbench/view.rs`）在 `Theme::change` 后调用
  `crate::fonts::apply_theme(cx)`。
- 改设置里的字体后要 `apply_theme` + `refresh_windows`，保证即时生效。
- 换字体时替换 `linux/assets/fonts/` 的文件并更新 `FAMILY`，同步更新许可证。

### 不要这样做

- 不要在业务代码里散落 `"JetBrains Mono"` / `"monospace"` 字面量。
- 不要把字体注册放在窗口创建之后，也不要在 `Render` 里重复注册。
- 不要只改 `settings.font_family` 而不 `apply_theme`：那样设置存了但不生效。
- 不要依赖系统 fontconfig 或让用户手动装字体来“修好”默认字体。

## 考虑过的备选方案

### 备选方案一：只把默认字体名改成 JetBrains Mono，要求用户自己安装

改动最小，但默认字体是否生效取决于机器，和“跨机器一致”的目标冲突；缺字体时
静默回退，问题难排查。不采用。

### 备选方案二：把字体装到 `~/.local/share/fonts`

只解决开发机，不进仓库、不随产品分发，CI/其他机器仍会回退。不采用。

### 备选方案三：运行时从网络下载字体

引入构建/运行期网络依赖与校验负担，且离线或代理不可用时字体会缺失。忽略。

## 后果

- 收益：UI、编辑器、代码显示与终端跨机器一致，不再受系统字体安装影响；缺字体
  导致的回退与排查成本消失。
- 收益：设置弹窗的「编辑器字体」从“存了不生效”变为真正生效，且能即时切换。
- 收益：字体名来源收敛为「内嵌 `FAMILY` 常量 + 设置项」两处，语义清晰。
- 代价：二进制体积增加约 1.1 MB（4 个 TTF 内嵌）。
- 代价：仓库新增二进制字体资源，需要在升级字体时同步更新 `OFL.txt`。
- 注意：终端单元格宽度由 `gpui_xterm` 的 `measure_cell` 按半角 ASCII 步进测量
  （见 Linux 终端组件笔记）。用户若把编辑器字体换成非等宽字体，终端网格会退化，
  这是用户自选字体的预期后果。

## 验证

- `bash scripts/build-linux.sh` 通过，产物 `target/debug/lithe-linux` 内可检索到
  `JetBrains Mono` 字符串与注册失败告警文案，证明字体已内嵌。
- `cargo test --manifest-path linux/Cargo.toml -p lithe-linux --lib` 通过，
  含 `settings::tests::font_family_migrates_legacy_defaults`（空值/旧默认迁移、
  用户自选保留）。
- 运行应用后 UI、编辑器、代码显示与终端默认字体均为 JetBrains Mono；在设置弹窗把
  「编辑器字体」改为别的等宽字体，编辑器与终端即时跟随，重启后仍保持。
- `./scripts/verify-agent-notes.sh` 通过。

## 适用范围

- `linux/src/fonts.rs`：字体内嵌、注册、主题字体族设置与等宽字体族查询的唯一入口。
- `linux/assets/fonts/`：内嵌字体文件与 OFL 许可证。
- `linux/src/main.rs`：启动时注册字体并在首次主题设置后应用。
- `linux/src/workbench/view.rs`：主题切换后重新应用字体族。
- `linux/src/settings.rs`：编辑器字体默认值与旧默认值迁移（`migrated_font_family`）。
- `linux/src/workbench/settings_dialog.rs`：字体下拉项、选中后即时应用。
- `linux/src/workbench/terminal.rs`：终端 `TerminalConfig.font_family` 跟随等宽字体，
  字体变化时 `update_config` 即时生效。
- `linux/src/workbench/bottom_panel.rs`、`linux/src/workbench/maven.rs`、
  `linux/src/workbench/project_dialog.rs`：代码/日志文本改用 `fonts::mono_family(cx)`。
- 不适用于 macOS/Windows 产品；两端的字体分别由各自平台的呈现层管理。
