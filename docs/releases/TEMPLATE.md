<!--
复用方式：复制为 v<version>.md，替换 {version}、{previous_version} 和正文占位符，再删除本注释。
以“新功能 → 改进 → 修复”为固定分类顺序；删除没有内容的分类，中英文保持一致。
每条只写一个用户可感知的变化、一个短句、一行 Markdown，不嵌套列表。
建议中文约 40 字以内、英文约 20 词以内；按需写平台名，不承诺任何屏幕宽度下都不换行。
不列内部类名、实现机制、测试数量或原始提交列表；贡献者在底部集中致谢。
保留双语下载、升级、可信来源 Gatekeeper 提示和版本对比；链接与兼容性必须逐版核实。
发布标题使用 Lithe v<version>，不要复制其他项目的名称、功能或贡献者。
-->

## 中文

{一句话概括本次更新对用户的帮助。}

### 下载

- [项目主页](https://github.com/1lck/Lithe-IDEA)
- [macOS Apple Silicon](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-arm64.dmg)
- [macOS Intel](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-x86_64.dmg)
- [Windows x64](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-windows-x64.exe)
- [全部下载文件](https://github.com/1lck/Lithe-IDEA/releases/tag/v{version})

### 重点更新

本次更新内容如下。

#### ✨ 新功能

- {一句短句描述用户可感知的变化。}

#### ⚡ 改进

- {一句短句描述用户可感知的变化。}

#### 🛠 修复

- {一句短句描述用户可感知的变化。}

### 升级说明

- macOS：打开对应架构的 DMG，将 Lithe.app 拖入“应用程序”。
- Homebrew：新版配方更新后，运行 `brew update && brew upgrade --cask lithe`。
- Windows：下载并运行 x64 安装包。

### 兼容性与已知问题

- {核实并填写本版系统要求、签名状态和已知限制。}

如果 macOS 提示无法打开 Lithe.app，请在“应用程序”中按住 Control 点按应用并选择“打开”；如果仍被阻止，可在终端执行 `xattr -dr com.apple.quarantine /Applications/Lithe.app`。仅对可信来源的应用使用。

[查看完整变更](https://github.com/1lck/Lithe-IDEA/compare/v{previous_version}...v{version})

---

## English

{Short user-facing release summary.}

### Downloads

- [Project homepage](https://github.com/1lck/Lithe-IDEA)
- [macOS Apple Silicon](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-arm64.dmg)
- [macOS Intel](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-x86_64.dmg)
- [Windows x64](https://github.com/1lck/Lithe-IDEA/releases/download/v{version}/Lithe-{version}-windows-x64.exe)
- [All downloads](https://github.com/1lck/Lithe-IDEA/releases/tag/v{version})

### Highlights

Changes are grouped below.

#### ✨ New features

- {One short sentence describing a user-visible change.}

#### ⚡ Improvements

- {One short sentence describing a user-visible change.}

#### 🛠 Fixes

- {One short sentence describing a user-visible change.}

### Upgrade instructions

- macOS: open the DMG for your architecture and drag Lithe.app to Applications.
- Homebrew: run `brew update && brew upgrade --cask lithe` after the cask update is available.
- Windows: download and run the x64 installer.

### Compatibility and known issues

- {Verify system requirements, signing status, and known limitations for this version.}

If macOS says it cannot open Lithe.app, Control-click it in Applications and choose Open. If it is still blocked, run `xattr -dr com.apple.quarantine /Applications/Lithe.app` in Terminal. Use this only for an app from a source you trust.

[Full changelog](https://github.com/1lck/Lithe-IDEA/compare/v{previous_version}...v{version})

### 🙌 感谢贡献者

{Verified GitHub contributor links.}

### 🙌 Contributors

{Verified GitHub contributor links.}
