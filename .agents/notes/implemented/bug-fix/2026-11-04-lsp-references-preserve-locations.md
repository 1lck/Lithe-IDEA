# Agent 笔记：查找引用保留语言服务返回的位置

状态：已实现

## 先说结论

查找引用应保留语言服务器给出的每个位置。同一文件的同一行可能包含多个不同引用，Windows 不得只按文件和行号把它们一起过滤，否则会错误地提示没有引用。

## 问题

Windows 原先为了排除当前位置，删除了文件和行号都相同的结果。例如 `name = name + name` 同一行有三个位置，光标在其中一个时，其余位置也会被删掉。macOS 保留语言服务器返回的结果。

## 决策

Windows 使用语言服务器返回的引用集合，并保留每个位置的完整范围。用户可从列表选择同一行的不同列；单个结果沿用直接跳转。语言服务器决定引用语义，界面负责呈现位置。

## 考虑过的备选方案

- 只排除光标所在范围：比按行过滤准确，但会改变上游结果，而且当前流程没有产品要求排除当前位置。因此保留全部结果，与 macOS 一致。
- 保留按行排除：会丢掉其他引用，否决。

## 后果

同一行的有效引用不会消失；当前位置如果也由服务器返回，会出现在结果中。平台不需要重新推测哪个位置应当算作引用。

## 验证

`cd windows/tauri && bun test src/features/keymaps/commands/navigation-command-actions.references.test.ts` 验证一行中的三个不同列均被呈现。组件测试不替代 Windows 实际语言服务器交互验收。

## 适用范围

Windows `windows/tauri/src/features/keymaps/commands/navigation-command-actions.ts` 的 LSP 查找引用；Spring 专属导航仍由对应提供方处理。
