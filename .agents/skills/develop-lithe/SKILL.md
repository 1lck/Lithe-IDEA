---
name: develop-lithe
description: Apply Lithe repository architecture, cross-platform contracts, coding rules, hardcoding restrictions, and validation workflow. Use for every implementation, refactor, review, debugging, test, build, or documentation task in the Lithe repository.
---

# Develop Lithe

Follow these instructions for all work in this repository. Prefer the existing
architecture, nearby code, and executable verification scripts over generic
framework conventions.

Architecture decisions and trade-offs live in Chinese Agent Notes under
`.agents/notes/`. For creating, migrating, updating, archiving, or reviewing
those notes, load `.agents/skills/agent-notes/SKILL.md`.

## Read the relevant source of truth

- Read the implementation and tests around a change before editing it.
- For ownership or dependency changes, read the relevant `implemented` Agent
  Note under `.agents/notes/implemented/architecture/` and the relevant
  platform boundary document.
- For cross-platform behavior, read `shared/contracts/application-boundary.md`,
  `shared/contracts/rust-core-api.md`, and the related fixtures.
- For resizable panels, splitters, continuous dragging, or other high-frequency
  UI interaction, also read
  `.agents/notes/implemented/architecture/2026-09-13-resizable-ui-performance-boundaries.md`.
- Do not introduce a new architectural direction as part of an unrelated task.

## Reuse mature developer tooling before building replacements

Treat reimplementing established IDE infrastructure as an exceptional architectural
decision, not a normal feature-development shortcut. Before adding or expanding
language intelligence, project import, build modeling, dependency resolution,
compilation, formatting, refactoring, test discovery, run/debug planning, or
LSP/DAP behavior:

- Inventory the capabilities already available in Lithe's bundled upstream tools,
  their current versions, official extension points, and compatible mature
  open-source alternatives. Check whether upgrading or enabling an existing
  capability closes the gap before writing a parallel implementation.
- Reuse the largest coherent upstream subsystem whose license, distribution model,
  resource cost, and platform support satisfy the product requirement. Do not reuse
  a few commands while independently recreating the subsystem's project state,
  dependency graph, lifecycle, or semantic model.
- Keep upstream-owned facts in their owning engine. For example, Java symbols,
  source roots, module ownership, classpaths, compilation state, and debug targets
  should come from the selected Java/project backend when it exposes them. Core may
  validate and normalize those results, but must not become a second source of
  truth merely to make the behavior cross-platform.
- Keep Lithe-owned value focused on product orchestration: bounded lifecycle,
  cancellation, stale-result protection, resource budgets, stable cross-platform
  contracts, presentation, and end-to-end workflows.
- A custom implementation is acceptable only when the upstream capability is
  absent, cannot meet a demonstrated requirement, cannot legally be distributed,
  or violates a measured product constraint. Record the evidence, rejected reuse
  options, ownership boundary, and removal or migration path in the relevant Agent
  Note when the decision creates or expands a long-lived subsystem.
- Never reverse-engineer, copy, bundle, or design around proprietary tooling beyond
  its license. Public behavior and open standards may inform an independent
  implementation only when the applicable terms permit it.

Partial reuse must preserve the upstream subsystem's correctness boundary. Define
and test the complete user-visible sequence, such as save -> synchronize project
state -> build -> resolve runtime paths -> launch, instead of testing only that
individual upstream commands were called.

## Respect repository ownership

| Path | Responsibility |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit presentation and view-local rendering |
| `macos/Sources/Lithe/Models/` | UI-facing models and the `AppModel` aggregate |
| `macos/Sources/Lithe/Application/` | Feature models, state transitions, and user actions |
| `macos/Sources/Lithe/Services/` | Product workflow orchestration |
| `macos/Sources/Lithe/Core/` | Platform-neutral ports and typed Rust operations |
| `macos/Sources/Lithe/Platform/MacOS/` | macOS adapters and composition |
| `rust/lithe-core/` | Deterministic shared commands, models, validation, and C ABI |
| `windows/` | React/Tauri Windows product and Rust platform adapters |
| `Plugins/mac/` | macOS-owned plugin packages |
| `Plugins/win/` | Windows-owned plugin packages |
| `frontend/editor/` | Shared Monaco presentation, tokenization, and editor model lifecycle; no platform APIs |
| `shared/` | Cross-platform contracts and fixtures, not compiled implementation |
| `infra/` | Repository-level development and validation infrastructure |
| `third_party/` | Upstream code; leave unchanged unless the task explicitly targets it |

macOS is the current reference product. Windows is an independent React/Tauri
implementation and must not import Swift source or depend on macOS types.

## Preserve application boundaries

- Views receive `AppModel` or a dedicated feature model. They must not call the
  Rust C ABI, construct platform adapters, or depend on concrete workflow
  services.
- Application feature models own UI state transitions and coordinate user
  actions. Keep platform setup out of `AppModel`.
- Services orchestrate workflows through ports. They must not directly create
  `Process`, `Pipe`, `FileManager`, `FileHandle`, watchers, persistence stores,
  or concrete `Mac*` adapters.
- Core and application code must remain free of SwiftUI, AppKit, CoreServices,
  Tauri, WebView2, Win32, and concrete platform implementations.
- `MacServiceContainer` is the macOS composition root. Platform capabilities
  belong in `macos/Sources/Lithe/Platform/MacOS/`.
- Deterministic behavior shared by both products belongs in `rust/lithe-core/`.
  Native filesystem, process, terminal, runtime, security, persistence, and UI
  behavior belongs in platform adapters.
- Cross-platform use alone does not justify duplicating semantics already owned by
  a mature upstream engine. Put only Lithe's stable normalization and orchestration
  contract in Core; keep language, build, project-model, and debugger facts in the
  selected provider.
- Windows feature code must import `@/platform/tauri-core` instead of the Tauri
  core API directly. Shared operations route through `lithe-core`; Windows-only
  terminal, watcher, credential, process, and WebView behavior stays in the
  Tauri host or a platform plugin.

## Keep shared contracts deterministic

- Use UTF-8 JSON for process and language boundaries.
- Use workspace-relative paths with `/` separators as identifiers. Absolute
  paths are allowed only in platform-owned diagnostics.
- Use one-based line numbers and `null` for missing locations.
- Keep lists and serialized results deterministically ordered.
- Represent asynchronous operations with explicit `idle`, `loading`, `ready`,
  and `failed` outcomes where the application contract requires them.
- Return stable error codes and user-facing messages. Put platform-specific
  details in the contract's `details` field.
- Preserve `operationID`, cancellation, timeout, and stale-result semantics for
  process-backed features.
- Add or update a shared fixture before a second platform relies on new shared
  behavior.
- Treat command names, JSON fields, error codes, and the C ABI as compatibility
  surfaces. Update contract documentation and every consumer when they change.

## Keep the platform feature matrix current

For every new user-visible capability or cross-platform behavior change, update
`shared/platform-feature-matrix.json` in the same pull request. Each row is one
independently verifiable user capability and must include both platforms'
`implementationStatus`, `verificationStatus`, evidence paths, owner, and a
concrete verification action. Platform-only capabilities still get a row with
`implementationStatus: platform-specific` on the other side.

`implementationStatus` and `verificationStatus` are independent dimensions.
Code presence without runtime evidence keeps its implementation status and uses
`verificationStatus: pending`; only the verification procedure completing on the
target platform permits `verified`. The status labels, icons, and descriptions in
the JSON are the generator's only status source of truth.

Run `node scripts/generate-platform-feature-matrix.mjs` after changing the source
and commit both generated views under `docs/development/`. Run
`./scripts/verify-platform-feature-matrix.sh` before handoff. Pull requests that
change platform implementation paths are required by CI to update the JSON. A
reviewer may add the `matrix-exempt` label only for a reviewed refactor with no
user-observable change; explain that exception in the pull request.

### Mandatory pre-PR matrix gate

Do not declare a platform change complete, commit it as ready for review, push
it, or create/update a pull request until the local equivalent of the CI change
gate has passed. First inspect the actual platform paths changed relative to the
PR base:

```bash
git diff --name-only origin/preview...HEAD
```

When any platform implementation path listed above changed, run both checks:

```bash
./scripts/verify-platform-feature-matrix-change.sh origin/preview HEAD
./scripts/verify-platform-feature-matrix.sh
```

Use the exact pull-request base and head SHA instead of `origin/preview` and
`HEAD` when those SHAs are available. If the change gate reports platform paths
without `shared/platform-feature-matrix.json`, stop and update the matrix source
and its generated Markdown/CSV views before proceeding. Do not use
`matrix-exempt` to bypass a user-visible behavior change. A user request to skip
optional tests does not waive this contract gate when the work is being prepared
for a pull request.

## Follow the codebase's language conventions

Apply the style used by surrounding files. Prefer descriptive names, focused
types and functions, explicit ownership, and straightforward control flow.
Avoid unrelated cleanup, speculative abstractions, and new dependencies that
the existing stack can reasonably avoid.

### Swift and macOS

- Use the Swift 6.3.3 toolchain pinned in `.swift-version` (Xcode 26.6). The application target intentionally uses Swift
  5 language mode while tests use Swift 6 language mode; do not change these
  modes as part of unrelated work.
- Put presentation in Views, feature state in Application, orchestration in
  Services, interfaces in Core ports, and native APIs in Platform/MacOS.
- Use the existing Swift Testing patterns under `macos/Tests/LitheTests/`.
- Keep platform-specific types from leaking through shared or application
  interfaces.

### macOS shared frontend controls

- The approved visual baseline is the shared style already used by the Git Log
  Branch/User/Date/Paths dropdowns, the settings-window dropdowns, and the
  Project/Dependencies dropdown in the Project sidebar. The top-bar project
  switcher is a consumer of that style, never its visual reference.
- Use exactly these entry points and owners:

  | Purpose | Entry point | Owning source |
  | --- | --- | --- |
  | Action dropdowns, checked actions, toggles and submenus | `LitheMenu` | `macos/Sources/Lithe/Views/Components/LitheDropdown.swift` |
  | Native product right-click menus | `litheContextMenu` / `LitheContextMenuPresenter` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
  | Searchable selectors and custom popup content | `litheDropdown(isPresented:opensUpward:content:)` / `LitheDropdownPopover` | `macos/Sources/Lithe/Views/Components/LitheDropdown.swift` |
  | Value selection, including settings forms | `LitheSettingsSelect` | `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift` |
  | Action/custom dropdown windows, placement and dismissal | `LitheContextMenuPresenter` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
  | Value-select popup window and keyboard selection | `LitheSettingsSelectPopupPresenter` (private, through `LitheSettingsSelect`) | `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift` |
  | Monaco/WebKit editor context menus (existing resolved actions only) | `installNativeContextMenu` → `MonacoEditorContextMenu` → `LitheContextMenuPresenter` | `macos/EditorFrontend/context-menu.ts` / `macos/Sources/Lithe/Views/Editor/MonacoEditorContextMenu.swift` |
  | Shared row metrics and highlight | `LitheDropdownMetrics` / `LitheDropdownRowStyle` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
  | Shared outer background, 8pt radius, border and clipping | `litheContextMenuSurface` | `macos/Sources/Lithe/Theme/LitheTheme.swift` |

  These are interaction entry points into one visual system. Callers supply
  content, selection and actions; they must not define another dropdown
  background, border, corner radius, row metrics or opening animation.
- Apply these constraints only where an existing shared owner covers the control.
  Check the corresponding IDEA Community action/control/theme source before
  changing that owner; record the source path and revision in its owning Note.
  Screenshots help verify the result, but do not justify guessing geometry or
  adding IDEA functionality that Lithe does not have. A missing shared control
  is not permission to introduce another visual system as part of a style fix.
- When adding or changing a product dropdown, do not use SwiftUI `Menu`,
  `Picker` with `.menu` style, SwiftUI `.popover`, `NSPopover`, or `NSPopUpButton`
  as its presentation. Shared dropdown panels use `animationBehavior = .none`:
  open directly without the system popup/bounce animation or a spring/scale transition.
- Anchor toolbar dropdowns to the triggering control's bottom-left edge, not
  the pointer position. Preserve screen-edge clamping, keyboard navigation,
  selected state, outside-click dismissal and focus behavior.
  The main-toolbar Project/Branch switches anchor their full toolbar slot,
  leaving its existing margin below the painted button. Use the shared width
  bounds in `LitheDropdownMetrics`; Project measures content width and Branch
  uses the Community New UI 375pt baseline. Do not copy the top-bar Project
  switcher's previous fixed width or create another search-field style:
  searchable popup inputs use `LitheSearchTextField` + `litheSearchField` in
  `macos/Sources/Lithe/Theme/LitheTheme.swift`, as Git Log does.
  Width is role-specific, not globally equal: action menus measure localized
  titles, icons, shortcuts and checks through the presenter; settings selectors
  retain their shared trigger/content measurement. Do not add per-caller magic
  widths or offsets. Submenus follow their visible trigger row, including scroll
  and separators; only the shared presenter handles screen-edge adjustments.
  Main-toolbar Project/Branch triggers retain their normal hover background
  while their popup is open, using `litheRowHover` with
  `activeBackground: LitheTheme.hoverBackground`. Opening does not apply a blue
  selection or a new pressed color; closing releases this retained hover state.
  This trigger rule does not change menu-row selection or checked-value state.
- Monaco editor context menus must also use the native shared presenter.
  Preserve Monaco's resolved actions, order, context keys, disabled states,
  shortcuts and action runner; do not invent IDEA-only functionality or duplicate
  the shared style in web CSS. Use only mapped IDEA SVG icons at their original
  16pt size, with original colors and dark/light variants; an unassigned action
  keeps an empty icon slot. The macOS adapter hooks the pinned Monaco 0.55.1
  context-menu renderer after upstream menu resolution; verify the real WebKit
  probe whenever changing this hook or upgrading Monaco.
- Product menu/dropdown entry points use the shared routes. Native
  SwiftUI `Picker` is allowed only for explicit `.segmented` controls, which
  have no dropdown. `ContextMenuCoverageTests` enforces these restrictions.
  System dialogs, the macOS application menu, editor completion/caret popups
  and hover documentation are separate interactions; this rule does not
  replace them with product dropdowns.
- For search inputs use `LitheSearchTextField` and `litheSearchField`; preserve
  native IME composition and the I-beam cursor before focus. Do not patch each
  feature's placeholder, border or hover cursor separately.
  Their owner is `macos/Sources/Lithe/Theme/LitheTheme.swift`; read its metrics
  rather than copying height, inset, radius, font, placeholder or focus colors.
  A binding that is still empty during marked text must not restore the prompt.
  Multiline commit text keeps `CommitMessageEditor` in
  `macos/Sources/Lithe/Views/Git/CommitMessageEditor.swift`; do not substitute a
  search field or duplicate its native composition/undo logic.
- Toolbar icons use `LitheIDEAIcon` in
  `macos/Sources/Lithe/Theme/LitheIcons.swift` and the already approved SVGs in
  `macos/Resources/IDEAIcons`. Preserve original geometry, stroke/fill and
  dark/light variants; use an action's source-assigned icon, not a guessed
  SF Symbol or a newly drawn replacement. Do not scale or overlay glyphs to
  simulate heavier strokes. An unassigned menu action retains an empty slot.
  Standard tool-window toolbar buttons use `litheToolbarIconButton` /
  `LitheIconButtonStyle` in `LitheTheme.swift`, including its disabled and hover
  feedback and default arrow cursor. Its 22pt hit area is not a rule for every
  button: main-toolbar switches and other existing controls retain their own
  shared metrics. Pointer and I-beam behavior are explicit control semantics.
- Tree rows use `litheTreeRow` and `LitheTheme.Tree` in `LitheTheme.swift` for
  the existing single-line tree style: font, row height, hover and focused versus
  inactive selection. Read shared indentation/icon metrics; do not add local
  row padding, selection colors or per-row separator lines. Preserve disclosure,
  multiselect, context actions and accessibility. Native trees keep their
  existing renderer and consume the same tokens; do not replace them with
  SwiftUI rows. Multiline project-menu entries, tables and commit graph rows
  keep their own existing shared renderer/metrics rather than using tree rows.
- Typography uses `uiFont` / `uiNSFont` for ordinary UI and `editorFont` /
  `codeFont` / monospaced `uiFont` for code and existing monospaced presentations,
  all owned by `macos/Sources/Lithe/Theme/LitheTheme.swift`. Select the existing
  bundled real face (Inter or JetBrains Mono); do not hardcode a new font family,
  use synthetic weight on an already selected face, or force every label to the
  same size/weight. Control metrics own size and emphasis. Project initials use
  `ProjectAvatarBadge` in
  `macos/Sources/Lithe/Views/Workspace/ProjectIdentityAppearance.swift`, following
  IDEA `AvatarUtils` New UI's Mono DemiBold rather than ordinary UI Bold.
  System window decorations/dialogs retain platform fonts. Monaco loads its
  existing bundled code font and remeasures after loading; no runtime download
  or write into bundled resources is allowed.

- Native product scrollbars use `litheScrollViewChrome` → `LitheScrollBarStyle`
  in `macos/Sources/Lithe/Views/Components/LitheScrollViewChrome.swift`.
  Diff uses its editor role through `DiffStripeScroller` / `LitheScrollBarPaint`;
  callers retain scroll actions and proportions, not local thumb/rail colors.
  Read `.agents/notes/implemented/feature/2026-10-02-macos-shared-scrollbar.md`
  before changing that owner; editor overrides and ordinary product colors are distinct.

When changing these shared owners, check their existing callers and run the
affected native appearance/behavior tests in dark and light themes. Relevant
checks are `ContextMenuCoverageTests`, `SettingsSelectPopupGeometryTests`,
`LitheSearchFieldStyleTests`, `LitheTreeRowStyleTests`, `BundledUIFontTests` and
`WorkbenchRenderingSafetyTests`; choose the affected suites, not unrelated
full-platform work. Do not add exceptions to coverage checks or mark full
workbench visual validation complete merely because a component test passes.

The decision and owning components are recorded in
`.agents/notes/implemented/simplification/2026-09-30-macos-shared-dropdown-style.md`.

### Rust

- Run `cargo fmt` and follow existing crate and module conventions.
- Keep shared results deterministic and preserve the JSON envelope and C ABI.
- Return structured failures across the boundary; do not expose unstable Rust
  implementation details as contract error codes.
- Add tests in the owning crate for changes to commands, parsing, validation,
  ordering, cancellation, or serialization.

#### Rust Core comments

Apply the following comment standard to first-party code under
`rust/lithe-core/`. It does not require comment coverage in the database helpers,
Windows/Tauri Rust crates, generated code, or third-party sources.

- Write comments in English and keep them accurate when behavior changes.
- Start each production module with a concise `//!` description of its
  responsibility or architectural boundary.
- Use `///` for exported APIs, shared request and response types, core domain
  types, and C ABI functions. Document ownership and add `# Safety` for unsafe
  entry points; describe errors only when the failure contract is not obvious.
- Document enums, structs, variants, and fields whenever their names alone do
  not make their semantics, allowed values, units, ownership, or protocol role
  immediately clear. This requirement applies to internal types as well as
  exported contracts.
- Use `//` inside implementations to explain non-obvious decisions and
  constraints involving compatibility, determinism, ordering, security,
  performance, or cross-platform behavior.
- In tests, comment the scenario, regression risk, or boundary being protected
  when the test name and assertions do not make that intent clear.
- Do not narrate statements, restate descriptive names, or add comments to
  trivial accessors and straightforward control flow solely for coverage.
- Run `./scripts/verify-rust-core-comments.sh` before slower Rust Core checks.
  It enforces module documentation, exported Rustdoc, English comments, and
  unsafe API safety sections without requiring documentation on every internal
  helper. Still review changed internal types and implementations for the
  semantic cases above, which a static check cannot judge reliably.

### Windows React and Tauri

- Use Bun for frontend scripts and Tauri 2 for the Windows host. Keep React
  feature code in `windows/tauri/src/features`, reusable UI in
  `windows/tauri/src/ui`, the invoke boundary in
  `windows/tauri/src/platform`, and native Rust behavior in
  `windows/tauri/src-tauri`.
- Do not restore a parallel C++/Qt application layer or one Tauri command per
  shared Core operation. Translate compatibility command names through the
  central platform dispatcher.
- Add frontend tests for product behavior and Rust tests in the owning crate.
  Verify WebView2, ConPTY, installer, signing, and updater behavior on Windows.

## Avoid hardcoded environment details

- Never commit credentials, tokens, private endpoints, signing material, or
  personal data.
- Do not embed developer-machine paths, workspace roots, home directories,
  temporary directories, or tool installation paths in application logic.
- Resolve executables, storage locations, and platform defaults through the
  appropriate adapter or configuration mechanism.
- Keep stable product constants named and centralized. Do not duplicate magic
  strings or numbers across platforms.
- Test fixtures may use clearly fake values, but must not contain real secrets
  or machine-specific paths.

## Keep installed packages read-only

The installed macOS app bundle and the Windows installation directory are the
release baseline: Sparkle builds differential updates against their exact
bytes, and a runtime write turns the next update into a full download.

- Runtime state (caches, indexes, Eclipse/OSGi state, downloads, extracted
  archives, logs, and locks) goes to the platform cache, Application Support,
  temporary storage, or the workspace, resolved through the platform storage
  adapter. Never derive a write destination from `Bundle.main.resourceURL`,
  `resource_dir()`, or the installation directory.
- A packaged tool that writes next to its own files, as Equinox does with
  `-configuration`, receives a writable copy of its inputs in the cache
  instead; see `rust/lithe-core/src/lsp/languages/jdt_configuration.rs`.
- Cover a new packaged runtime with a test that compares the installation's
  file listing before and after a typical workflow, and keep
  `scripts/verify-runtime-bundle-immutability.sh` passing.

The decision record is
`.agents/notes/implemented/bug-fix/2026-09-25-runtime-bundle-immutability-and-update-delta.md`.

## Handle failures explicitly

- Do not silently discard errors. Return, translate, or log them at the layer
  that has enough context to act on them.
- Preserve stable contract error categories when crossing Rust, Swift,
  TypeScript, Tauri, or process boundaries.
- User-facing failures should be actionable without exposing credentials,
  environment contents, or unnecessary internal details.
- Comments should explain non-obvious constraints or decisions, not narrate the
  code.

## Run validation that matches the change

Run the smallest relevant checks while iterating, then the broader affected set
before handoff.

| Change | Minimum relevant validation |
| --- | --- |
| Agent Notes or architecture decision migration | `./scripts/verify-agent-notes.sh` |
| Test code or test infrastructure | `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`, then the affected platform timing harness from `write-stable-tests` |
| Swift application or tests | `./scripts/test-macos.sh` |
| Core, Services, Views, or composition boundaries | `./scripts/verify-service-boundaries.sh` |
| Shared application behavior or JSON fixtures | `./scripts/verify-shared-contracts.sh` |
| Rust Core, JSON C ABI, or Swift bridge | `./scripts/verify-rust-core.sh` |
| Core feature behavior | `./scripts/verify-core.sh` |
| Git graph behavior | `./scripts/verify-git-graph.sh` |
| Windows boundaries from macOS/Linux | `./scripts/verify-windows-boundaries.sh` |
| Windows implementation on Windows | `./scripts/build-windows.ps1 -Configuration Release`, then `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml` |

Also run tests for directly affected crates or targets. If the current machine
cannot run a platform-specific check, state that clearly; do not claim an
unexecuted check passed.

## Keep changes reviewable

- Preserve existing uncommitted work and avoid modifying unrelated files.
- Do not commit generated output such as `.build/`, `.swiftpm/`, `target/`,
  `dist/`, `DerivedData/`, fixture build directories, or local IDE settings.
- Do not perform broad formatting or dependency updates as part of a focused
  fix.
- Do not use destructive Git commands, create commits, push branches, or change
  release metadata unless the task explicitly requests it.
- Update the owning Agent Note when behavior, ownership, or a compatibility
  surface changes. Do not rewrite notes for an implementation-only refactor
  that leaves the documented decision intact.

## Complete the work honestly

Before reporting completion, confirm that the change is in the owning layer,
relevant tests or verification scripts were run, shared consumers were checked,
and no machine-specific hardcoding was introduced. Report what changed, what
was verified, and any remaining platform or test limitations.
