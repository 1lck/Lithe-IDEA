# Agent 笔记：Java 导入期间按语法跳转

状态：已实现

## 先说结论

Java 工程导入要几分钟，这期间 JDT LS 回答不了跳转定义，用户只能等。现在 Windows 在这段时间用语法兜底：类型按文件名找，本文件的方法和字段按语法树找，并提示“仅按语法定位”。兜底只在语言服务不可用时触发，不建索引，不缓存，也不猜无法确定的名字。

## 问题

大工程打开后最先想做的往往是从一个类跳到另一个类，而这时语言服务正在导入。之前的行为是提示导入进度然后什么也不做。OpenIDEA 的 `syntaxFallback`（对应 IDEA 的 dumb mode，索引未就绪时的受限模式）证明了这段时间用语法回答大部分类型跳转是可行的。

Lithe 有一条规则：上游语言引擎负责的事实，Core 不维护第二份真源。所以问题是怎样提供兜底而不造出一份索引。

## 决策

`resolveJavaSyntaxDefinitions` 只组合已有能力，不新增 Core 命令：

- 类型：先用 `java.sourceDefinition` 在本文件找；再用 `workspace.snapshot` 找同名 `.java` 文件，优先匹配 import 或同包路径，定不下来时全部列出让用户选。
- 成员：用 `java.sourceDefinition` 的 `declarationsOnly` 加 `reference`，由 Core 从引用位置开始解析。之前它用正则找 `name(`，第一个命中常常是调用而不是声明；后来改成全树找第一个同名声明，又会跳到嵌套类型的同名成员。
- 解析规则按 Java 作用域走：从最内层类型开始，只看这个类型直接声明的成员，找不到再往外层；方法和字段是两个命名空间，分开查。
- 语法无法证明的一律返回空，跳错比不跳更糟：带接收者的访问（`other.save()`）、`this.` 在当前类型找不到、中途经过可能继承这个名字的类型（有 `extends`/`implements` 或匿名类）、同一成员里有同名局部变量或参数、方法引用（`Foo::bar`）。
- 光标已经在声明上时返回空。

结果只在 `goToActiveLspLocation` 判定语言服务不可用时使用。找到时用 `navigation.syntaxFallback` 提示，替换导入进度提示；找不到时保留原提示。等待期间用户切换了文档，结果直接丢弃。

## 考虑过的备选方案

- 像 OpenIDEA 那样建立持久符号索引（`crates/ide-index`）：否决。它覆盖更多，但这是第二份真源，要处理增量更新、缓存位置和失效，而用途只有导入期间的几分钟。
- 新增基于语法树的 `java.syntaxDeclarations`，支持局部变量作用域：暂不做。局部变量通常就在视野内，价值低于类型跳转，多一条 Core 命令不划算。
- 用已有的 `lsp.builtinNavigation`：不适合。它靠声明关键字判断，Java 的方法和字段没有这类关键字。
- 只把查找限定到文件同名类型的直接成员：否决。光标在嵌套类型里调用 `save()` 时，会跳到外层的同名方法，所以必须知道引用所在的位置。
- 局部变量按块作用域精确判断：否决。只为兜底场景多写一套作用域规则不值得，同一成员里出现同名局部变量就放弃，代价只是少跳一次。

## 后果

- 局部变量和参数跳不了，继续显示导入提示。字段被同一成员里的同名局部变量遮蔽时也不跳，即使局部变量在另一个代码块里。
- 继承来的成员跳不了；嵌套类型有 `extends`/`implements` 时，也不再往外层找。
- 只在 Windows 实现，macOS 的状态记录在功能矩阵 `java-import-progress-feedback` 中。
- 同名类型列表上限 12 个，每个候选读一次文件，发生在一次用户操作里。

## 验证

```sh
bun test windows/tauri/src/features/editor/lsp/java-syntax-definition.test.ts
cd rust && cargo test -p lithe-core --lib java_core_commands
cd rust && cargo test -p lithe-core --lib java_member
```

## 适用范围

适用于 Windows 的定义跳转（F12、Ctrl+点击）在语言服务不可用时的行为。语言服务就绪后不走这条路径。
