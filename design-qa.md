# Lithe Terminal Visual QA

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-20670554-37d9-411d-a9b2-16eee560e363.png`
- Source shell menu: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-6fa64651-7e79-4121-8e98-ba35d284fc50.png`
- Source terminal prompt: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-934841e4-1840-4827-91fa-5662f1ed31ae.png`
- Latest captured implementation: `design-qa-artifacts/terminal-idea-restyle-prelock.jpeg`
- Viewport: 1280 x 768, dark mode, terminal bottom tool window open.
- State: zsh prompt visible in `/private/tmp/lithe-java-qa`.

## Full-View Comparison

- The terminal now uses an IDEA-style `Terminal` header, selected `Local` tab, add button, shell selector, overflow menu, and collapse control.
- The separate bottom command bar has been removed; keyboard input and cursor render directly after the PTY prompt.
- ANSI foreground, background, bold, 256-color, and true-color sequences render in the terminal canvas.
- Terminal background, toolbar height, borders, padding, and type density are aligned with the supplied IDEA references.

## Focused Comparison

- Header controls and spacing: matched closely enough for the current app scale.
- Prompt rendering: Powerlevel10k color blocks and glyphs render instead of plain sanitized text.
- Input placement: command text is inline with the shell prompt rather than in a separate form row.
- Shell menu: executable zsh, bash, Homebrew bash, and pwsh entries are populated dynamically.

## Findings

- [P1] Final automatic-refresh state is not visually verified.
  Evidence: the last code change made `TerminalSession` a directly observed object so prompt output redraws without a keyboard event, but the Mac locked before a new screenshot could be captured.
  Impact: visual handoff cannot be marked passed without seeing the final packaged build open directly into the prompt state.
  Fix: unlock the Mac, relaunch `dist/Lithe.app`, open the Java fixture terminal, and capture the initial prompt before typing.

## Patches Since Previous QA

- Replaced the output panel and fixed command row with an integrated terminal canvas.
- Added ANSI color rendering and inline input/cursor drawing.
- Added IDEA-style terminal tabs and functional shell selection.
- Added a shell startup handshake with a fallback for slow zsh initialization.
- Subscribed the terminal view directly to live session output.

final result: blocked
