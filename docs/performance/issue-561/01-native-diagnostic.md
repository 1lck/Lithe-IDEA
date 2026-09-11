# Issue 561: isolated Java text diagnostic

> 归档说明：本报告记录 2026-09-11 正式修复之前的第一阶段原生文本操作诊断。正文保留当时的结论、数据和限制；完整应用复现见[第二阶段报告](02-product-reproduction.md)，正式修复及后续复测见 [PR #621](https://github.com/1lck/Lithe-IDEA/pull/621)。本文的约 266 KiB 探针文件与后续 447 KiB 完整产品文件规模不同，计时不可混用。
>
> 原始计时已随文提交为 [native-results.json](native-results.json)，环境和 Rust 调用记录见 [native-metadata.json](native-metadata.json)。文末命令是当时的执行记录，依赖本地 `.artifacts/issue-561/` 中的探针和输入文件；本目录归档报告与数据，不包含这些可执行诊断材料。

## Scope

No product source was changed. No IDE window or LSP was started. This is an isolated native text-operation probe, not an end-to-end reproduction of the user report.

Fixture: 8329 lines, 271949 UTF-8 bytes (265.6 KiB), 142 methods, 164 imports, 69 injected fields. The fixture has 1990 fold regions and 50701 classified tokens; its structure may differ substantially from the unavailable user file.

LargeService.java and LargeService.txt contain identical bytes. The native probe loads the Java fixture and does not test extension routing.

Host: macOS 27.0 / arm64. Rust library: existing release binary, modified 2026-09-07 09:13:10; no fresh product build. The inspected Java source files predate this binary, but embedded-source provenance has not been independently verified.

## Measurements

Each row is a median of five measured repetitions after one warmup. The attributed-string setup and initial viewport layout are excluded. Units: milliseconds.

| Colored tokens | Layout requested | Tokens | Attribute mutation | Subsequent layout | Total |
|---|---|---:|---:|---:|---:|
| none | visible | 0 | 0.000 | 0.015 | 0.016 |
| none | full | 0 | 0.000 | 75.202 | 75.203 |
| visible | visible | 1347 | 0.375 | 6.290 | 6.685 |
| visible | full | 1347 | 0.398 | 87.341 | 87.711 |
| full | visible | 50701 | 14.591 | 9.227 | 23.931 |
| full | full | 50701 | 14.676 | 246.190 | 261.200 |

The separate Rust java.structure C ABI call took 948.395 ms median, including response serialization and copying but excluding Python JSON decoding. This call runs in a background task in the product and must not be added directly to main-thread blocking time.

## Interpretation

Full-document layout after full-document token coloring was the largest measured native step. Keeping only viewport layout reduced this operation-level cost substantially; restricting token coloring reduced it further. These results justify collecting a product main-thread profile around applyJavaStructure/updateFolds. They do not prove that this is the sole cause of the reported 2–7 FPS, or exclude LSP and other product paths.

## Limitations

- NativeTextProbe reproduces the NSLayoutManager fold delegate and NSTextStorage foreground-attribute loop, not the complete CodeTextView or SwiftUI view tree.
- System monospaced font and simplified five-color palette; product theme/font costs are not included.
- Viewport token filtering, setup, initial viewport layout, and JSON decoding are excluded from reported native timing.
- One warmup and five measured repetitions per condition; these are diagnostic medians, not performance assertions.
- No actual typing, scrolling, or product FPS was measured.

## Product verification matrix

Use the same Java file and initial viewport; hold theme, font, window size, import folding and Code Vision constant. Use a Release build, separate cold-open and warm-open runs, then check a single-character edit and continuous scrolling.

| Condition | LSP | Semantic coloring | Fold layout | What it isolates |
|---|---|---|---|---|
| A | On | Current | Current | Product baseline |
| B | Off | Current | Current | LSP contribution |
| C | Off | Viewport only | Current | Coloring contribution |
| D | Off | Current | Skip unchanged/full invalidation | Layout contribution |
| E | Off | Viewport only | Skip unchanged/full invalidation | Combined local change |

Add timing spans for structure request/response, applyJavaSemanticHighlights, updateFolds, and editor input. Sample the main thread while the hitch occurs. Record ranges processed, token counts, layout refresh count, and input-to-visible-update latency. A matching hot stack plus repeatable improvement in the single-variable condition confirms attribution. Re-enable LSP before accepting a fix.

## Rerun native probe

```sh
swiftc -O .artifacts/issue-561/NativeTextProbe.swift -o .artifacts/issue-561/native-text-probe
.artifacts/issue-561/native-text-probe .artifacts/issue-561
```

The original compiler and native execution were supervised with 60-second and 90-second subprocess deadlines. The optional run-core-probe.py accepts an explicit dylib path and enforces a 30-second parent-owned deadline.

Raw native timings: native-results.json. Core times and provenance: metadata.json. Fixture and decoded Rust response are retained in the same directory.
