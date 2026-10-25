# Debug JSON 组合评审草案（#1210）

设计目标：**普通插件尽量只写 JSON，通过依赖插件复用运行时、工程准备、适配器启动和调试能力；宿主承担通用解释与适配的复杂度。** 动态部分使用现有插件函数调用，输入输出继续由版本化领域 schema 校验。这版将能力声明、依赖、动态函数与流程组合放进同一种 JSON 模型。

这是 `feat/1210-debug-adapter-provider` 上的设计文件，当前宿主尚不接受。`draftVersion: "1210-3"` 是评审编号；`lithe.invalid` 只用于离线引用。没有修改现有插件契约、函数协议、产品 API 或运行逻辑。

## 插件作者主要写什么

完整例子：[Python](examples/python.registration.json)、[Java](examples/java.registration.json)、[JS/TS](examples/node.registration.json)、[C/C++/Rust/汇编](examples/native.registration.json)。

```json
{
  "pluginDependencies": {
    "java": {
      "pluginID": "example.java-runtime",
      "minimumVersion": "1.0.0",
      "maximumVersionExclusive": "2.0.0"
    }
  },
  "session": {
    "use": { "dependency": "java", "export": "debugSession", "contractVersion": 1 },
    "with": {
      "contextToken": { "$value": "/context/contextToken" },
      "configuration": { "$value": "/input/configuration" }
    }
  },
  "capabilities": {
    "sourceBreakpoints": { "source": "dap" },
    "hotCodeReplace": {
      "source": "function",
      "invoke": {
        "use": { "dependency": "java", "export": "hotCodeReplace", "contractVersion": 1 },
          "with": {
            "contextToken": { "$value": "/context/contextToken" },
            "sessionID": { "$value": "/input/sessionID" }
          }
      }
    }
  }
}
```

上面为节选：依赖是包级字段，`session` 和 `capabilities` 属于适配器。Java 插件不需要再次实现 JDT 准备和热替换。Python 同样依赖运行时插件取得 Run 使用的解释器，再依赖公共 DAP 插件启动 stdio；JS/TS 复用公共 TCP 启动流程。GCC 产生的程序由 LLDB 或支持 DAP 的 GDB 调试，原生 Provider 可同时服务多语言及无源码目标。

## 依赖可以继续依赖其他插件

```text
Python Debug → Python Runtime（解释器） + DAP Runtime（stdio 会话）
JS/TS Debug  → Node Runtime（运行时）    + DAP Runtime（动态 TCP 会话）
Java Debug   → Java Runtime             → Java Project Runtime（工程准备）
                                       → 既有 JDT 集成
```

公共插件也主要写 JSON。见 [DAP 公共流程](examples/dap-runtime.library.json)和 [Java 二级依赖组合](examples/java-runtime.library.json)。例子里的 `example.*` 包及部分导出仅用于展示目标结构，不代表这些依赖已发布。Java Project、Python Runtime、Node Runtime 的具体包清单不在本次 Debug 草案中定义。

每个导出有稳定名称和版本化契约。依赖方调用导出，不复制依赖包的路径或后端实现。包版本约束解决安装哪一版；`contractVersion` 解决本次调用使用哪种输入输出。`pluginDependencies` 与现有 `requires` 分开：前者指依赖的插件，后者仍指宿主 API 能力。最终应使用统一插件依赖管理，不保留 Debug 特有的第二套依赖管理器。

## 一种调用结构，三种实现来源

所有调用都写成 `{ "use": ..., "with": ... }`：

| use 的形式 | 谁提供实现 | 示例 |
| --- | --- | --- |
| `{dependency, export, contractVersion}` | 依赖插件导出的 JSON 流程或函数 | 复用 Java 的 debugSession |
| `{backendRef, functionID}` | 本包插件函数，或已有集成的类型化桥接 | 调用 debug.resolve |
| `{host, version}` | 通用宿主原语 | 创建适配器资源、生成启动方案 |

简单调用可以直接返回结果；需要多步时使用 `steps`，每步结果通过 `$value` 引用：

```json
{
  "steps": [
    {
      "id": "target",
      "use": { "dependency": "project", "export": "prepareDebugTarget", "contractVersion": 1 },
      "with": { "configuration": { "$value": "/input/configuration" } }
    },
    {
      "id": "session",
      "use": { "backendRef": "jdt", "functionID": "debug.resolve" },
      "with": {
        "contextToken": { "$value": "/context/contextToken" },
        "configuration": { "$value": "/input/configuration" },
        "target": { "$value": "/steps/target" }
      }
    }
  ],
  "result": { "$value": "/steps/session" }
}
```

宿主按顺序执行，`$value` 使用 JSON Pointer 读取输入、上下文和已完成步骤，保留对象/数组/整数类型。缺失值报错，`$literal` 可转义保留字段。路径转换、参数合并、资源登记等通用行为放进共享原语，插件不重复拼接命令，也不重复实现流程执行器。这版先提供直接调用和顺序组合；后续确有需要可以版本化扩充条件等声明能力，不以减少宿主解释器复杂度为由要求每个插件另写一套后端。

`/context/contextToken` 由宿主签发，调用需要它的领域契约时通过 `with` 显式传入。进入依赖包后，宿主为当前被调用方建立受限上下文，不能把调用方 token 当成访问依赖全部资源的凭据。导出契约校验公共输入和结果；JDT 桥接还接收工程准备的 `target`，该内部输入由其独立的类型化适配契约校验。

## 复用现有插件函数方案

动态后端仍使用现有进程启动、`litheFunctions` 协商、函数注册、`lithe/function/invoke`、进度、撤回、超时和取消机制，不新增 `lithe/debug/*` RPC。[自定义函数后端示例](examples/plugin-functions.library.json)展示普通后端如何导出调试启动能力；[调用消息示例](examples/java.function-call.json)展示复用的函数信封形状。

当前函数协议 v1/v2 只允许插件私有调用，现有领域结果也不经插件函数传输。本提案新增的是**导出和依赖调用的领域绑定**：宿主校验调用方依赖、被调用方导出、契约及授权，然后在拥有该函数的目标插件会话上调用现有函数通道，最后由 Core 校验领域结果。不会把调用方的 pluginID 塞进目标会话，也不会删除旧 `wrongPlugin` 拒绝条件。旧函数继续私有；只有显式导出的新契约能被依赖方使用。

JSON 组合由宿主驱动，不让正在等待结果的后端处理器再递归调度自己。依赖图与导出调用图检查循环；取消传播至本次子调用；共享后端不因一个调用取消而退出。函数撤回、插件更新或依赖禁用会使对应调用失效，迟到结果不得恢复旧会话。依赖不会继承调用者全部权限：需要执行资源时，只传递当前操作获准的受限引用。

JDT 是宿主已有集成，原始 JDT LS 不会因此被假定支持 `litheFunctions`。`hostIntegration` 把现有 JDT 操作适配到同一种类型化调用入口，不更改共享语言服务器的插件归属。新增普通第三方插件不需要在组合根增加插件名称分支。

## 能力也在 JSON 里

- `source: "dap"`：使用标准 DAP 实现，按 initialize 和后续 capabilities 事件确定支持。
- `source: "function"`：通过同一种 invoke 组合调用已导出的函数，结果使用该操作的标准契约。
- `source: "disabled"`：明确关闭。省略的能力不展示。

断点、变量修改、重启、反向单步、内存、反汇编、指令断点等都能声明。线程、调用栈、变量读取及基本执行控制继续复用公共 DAP 会话。函数实现标准操作也必须满足对应契约；某种绑定尚未由宿主实现时返回 `host_not_supported`。热替换作为已有的非标准能力给出完整绑定例子；其他函数操作的输入输出定义随实际接入扩充。

实际状态同样返回 JSON，区分 `unknown`、`supported`、`unsupported` 及原因。例如原生插件可以声明反汇编，但当前宿主未实现时，状态如 [native.capabilities.json](examples/native.capabilities.json)，不会只凭清单点亮按钮。统一配置、可检查结果与动态确认可以同时存在。

## Schema 文件

| 文件 | 责任 |
| --- | --- |
| [注册](debug-adapter-registration.draft.schema.json) | 依赖、导出、后端、目标匹配、能力与会话实现 |
| [JSON 组合](debug-composition.draft.schema.json) | 导入、导出、函数/宿主调用、步骤及类型化取值 |
| [配置](debug-configuration.draft.schema.json) | 现有 Run 配置解析后的标准 Debug 输入 |
| [启动方案](debug-start-plan.draft.schema.json) | prepare / ready / failed 与现有 DAP 配置 |
| [函数领域绑定](debug-function-binding.draft.schema.json) | 复用函数通道的 Debug 输入输出契约 |
| [有效能力状态](debug-capability-state.draft.schema.json) | 宿主计算并投影给双端的能力状态 |

已知契约由 Core 的版本目录提供 schema。插件自定义导出需提供成对的包内输入/结果 schema，引用只读包内资源；变更不兼容形状时升级契约版本。本目录没有替代 DAP 消息 schema，也不重新实现上游工程模型。

## 保持已有行为与后续实现

用户确认优先保证插件好写和复用能力，允许通用适配器复杂度和 API 版本增加。正式接入时为依赖/导出、领域函数绑定、新权限及宿主原语分配明确版本，旧版本语义继续保留。不是在现有 API 3 或函数 v1/v2 下悄悄接受新字段；也不预占并行开发中的具体版本号。这一阶段只改变评审设计，现有 Build/VCS/UI/设置/Run API 不变。

Run 三层覆盖、配置 ID、导入参数与最终 `DebugLaunchConfiguration` 保持兼容。`targetBindings` 由宿主统一把目标事实映射到参数；重复显式字段报冲突，不能覆盖。Java 的准备动作继续走既有工程/构建流程和编译失败决策，使用 Run JDK；准备后从 JDT 读取新路径，调试结束不终止共享服务。

通用宿主原语示例 `debug.process.acquire`、`debug.process.acquireTcp`、`debug.session.plan` 目前也只是契约方向，需在实现时定义完整参数/结果、期限及所有权。TCP 例子的 `jsDebugStandalone` 指复用现有端口发现逻辑的解码档位，不代表可以信任任意日志地址。导入配置里的 backendRef 在入口被规范化为调用方资源描述并取得租约，不能按依赖包的局部 ID 误解析。最终方案跨包传递的是宿主签发的 processRef / endpointRef，这些引用绑定当前操作。launch 终止自己拥有的目标，attach 默认断开；失败和取消清理本次资源，插件及应用包只读。

`java.ready.json` 中的 `${exampleHostResolved...}` 只是避免写入机器绝对路径的展示占位值，实际结果必须是宿主已解析的值；它不引入新的字符串模板语法。

新增下载或打包运行时的资源清单、工具链身份与复用验证，在实际新增资源时同步维护。本次没有下载资源，没有启动 Lithe 或后端进程，没有运行时跨平台验收证据。

离线校验覆盖 schema、正例、参数、局部引用和关键拒绝条件；依赖安装、图校验、函数授权、资源服务与两端执行器仍需实现。正式契约和 Core 同批落地，合并后同步 lithe-plugin-docs。
架构理由见[对应 Agent Note](../../../.agents/notes/proposed/architecture/2026-10-25-debug-adapter-provider-and-declarative-registration.md)。
