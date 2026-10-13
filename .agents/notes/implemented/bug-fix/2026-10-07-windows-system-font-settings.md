# Agent 笔记：Windows系统字体目录与编辑器字体设置

状态：已实现

## 先说结论

Windows字体信息交给系统DirectWrite接口，后台枚举后展示规范名和本地化名称。目录只提供选项，不改写设置。编辑器开放全部字体、6–72字号和连字预览，保留上游共享NumberInput数值控件；设置归一化与现有Monaco更新路径负责持久化和实时生效。

## 问题

注册表文本和名称猜测不能可靠表达本地化字体及等宽属性；目录未加载时回写后备字体会覆盖用户选择。

## 决策

Windows字体信息交给系统DirectWrite接口，后台枚举后展示规范名和本地化名称。目录只提供选项，不改写设置。编辑器开放全部字体、6–72字号和连字预览，保留上游共享NumberInput数值控件；设置归一化与现有Monaco更新路径负责持久化和实时生效。

## 考虑过的备选方案

不继续用注册表字符串猜字体；不因目录不完整而替换用户设置；不采用独立数字输入框覆盖上游共享数值控件。

## 后果

字体信息更准确，搜索保留非拉丁文字；代价是Windows DirectWrite绑定与后台枚举。目录只读系统字体，不下载、不写入字体文件或安装目录；失败保留选择并显示错误。其他平台不依赖此适配器，更新器不受影响。

## 验证

- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/settings/components/editor-font-settings.test.tsx`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/settings/components/editor-settings-routing.test.tsx`
- `node .agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs --working-directory windows/tauri -- src/features/settings/lib/editor-font-size.test.ts`
- `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml fonts::tests`

## 适用范围

- `windows/tauri/src/features/settings/components/macos-settings-panels.tsx`
- `windows/tauri/src-tauri/src/fonts.rs`
- `windows/tauri/src/features/settings/lib/editor-font-size.ts`
