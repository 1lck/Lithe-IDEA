# 文本文件编码接入方案

Viva 桌面端的编码规则由共享内核 Lithe-core-rust 统一持有：有哪些编码、如何自动识别、字节如何解码和编码、不可表示的字符如何处理，都在 Core 中实现。桌面端只负责决定字节从哪里读、写到哪里，并把结果显示出来，不复制编码转换。

## 职责划分

| 位置 | 职责 |
| --- | --- |
| Lithe-core-rust（[仓库](https://github.com/Lithe-IDEA/Lithe-core-rust)） | 编码目录（稳定 ID、显示规则、读写规则与 BOM 策略）、自动识别、解码与编码、不可表示字符的错误 |
| `desktop/internal/workbench/encoding.go` | 编码显示名（`encodingLabels`）；编辑器文本始终是 UTF-8；非纯 UTF-8 文件保留最近一次读写的磁盘字节（`diskBytes`），因为保存防护和外部修改检测比较的是字节 |
| `desktop/internal/documentio` | 读写文件字节，以及写入保护 |

纯 UTF-8 文件（没有 BOM）走无拷贝的快速路径，不调用 Core。

## 当前目录

Core 的目录当前包含 16 种编码：`utf-8`、`utf-8-bom`、`utf-16le-bom`、`utf-16be-bom`、`utf-16le`、`utf-16be`、`gbk`、`gb18030`、`big5`、`shift-jis`、`euc-jp`、`euc-kr`、`windows-1250`、`windows-1251`、`windows-1252` 和 `koi8-r`。桌面端的 `encodingLabels` 必须覆盖同样的 ID。

自动识别只覆盖 UTF-8、带 BOM 的编码和 GBK 系：其余单字节和多字节编码的字节互相重叠，无法可靠猜测，因此只能由用户显式选择编码重新打开，不会因为“看起来像”而被自动选中。无 BOM 的 UTF-16 同理。UTF-32 LE 的 BOM（`FF FE 00 00`）以 `FF FE` 开头，自动识别会明确排除它，避免被当成 UTF-16 LE 打开并改写。

## 新增一种编码

1. 在 Lithe-core-rust 的编码目录中添加稳定 ID、显示规则、别名、读写能力和 BOM 策略，并补充原始字节 fixture，覆盖显式错误编码读取、保存后的字节、BOM 和不可表示字符的错误。fixture 的参考位置是 [`rust/fixtures/documents/encoding-explicit-reopen-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/documents/encoding-explicit-reopen-v1.json)。
2. 在 `desktop/internal/workbench/encoding.go` 的 `encodingLabels` 中添加显示名，并使用新的 Core 修订固定到 `scripts/desktop/build-desktop-core.sh` 的 `PINNED_CORE_REVISION`。
3. 按读写能力过滤菜单：只读或只写的编码不能出现在不支持的操作中。
4. 运行 `scripts/desktop/desktop-go.sh test ./internal/workbench/...` 验证编辑器的读写路径。

桌面端不得把编码转换复制到界面层。编辑器只处理 Unicode 文本和 Core 给出的编码描述；字节边界、大小限制和写入保护由 `desktop/internal/documentio` 负责。
