# Lithe

Lithe 是一款面向 AI 编程工作流的原生 macOS 代码浏览与 Git 审查工具。

## 当前能力

- IDEA 风格的 Welcome Screen 和工作台
- 打开本地目录、最近项目和文件树
- 多标签原生文本编辑、保存和基础语法着色
- 文件名与项目全文搜索
- FSEvents 外部文件变化监听和编辑冲突提示
- Git Changes、并排 Diff、文件暂存、撤销与提交
- 明确的 Run 未接入状态

## 构建

需要 Swift 6.2 或更高版本：

```bash
swift build --disable-sandbox
swift run --disable-sandbox Lithe
```

生成可直接打开的本地 App Bundle：

```bash
./scripts/package-app.sh
open dist/Lithe.app
```

最低支持 macOS 14。当前使用 Swift Package Manager，不依赖第三方包。

## 产品边界

Lithe 不内置 AI、语言服务器、终端、测试运行器或调试器。外部 AI 工具负责生成和运行代码，Lithe 负责浏览项目、观察外部变化和审查 Git 修改。

完整范围见 [需求开发书.md](./需求开发书.md)。
