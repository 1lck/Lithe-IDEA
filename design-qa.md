# Lithe Java Navigation and Terminal QA

## Scope

- Java projects only for semantic code navigation.
- Go to Definition through the editor context menu and `Command-B`.
- Find Usages through the editor context menu and `Command-Option-U`.
- Clickable Java usage results in the bottom tool pane.
- Integrated project terminal backed by a real PTY.

## Java Navigation Verification

- Fixture: Maven project at `/private/tmp/lithe-java-qa`.
- Definition navigation from `calculator.add(...)` to `Calculator.add(...)`: passed.
- Find Usages returned both call sites in `App.java`: passed.
- Clicking a usage reopened the source at the reported UTF-16 line and column: passed.
- JDT LS launched with the compatible Homebrew Java runtime: passed.

## Terminal Verification

- Terminal opened in `/private/tmp/lithe-java-qa`: passed.
- `pwd` executed through the integrated PTY and returned the project directory: passed.
- Command submitted while the shell was starting was retained and executed once: passed.
- Terminal restart did not let the old process mark the new session as stopped: passed.
- ANSI escape sequences were removed from displayed output: passed.

## Build and Package Verification

- Isolated-cache Debug build: passed.
- Production app package and ad-hoc signing: passed.
- App bundle launched from `dist/Lithe.app`: passed.

final result: passed
