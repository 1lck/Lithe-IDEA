# Windows W1 Document Safety Test Plan

## Entry point

Build and run `windows/build-windows/Release/lithe_windows_qt.exe`, then open a
writable test workspace from **File > Open Workspace**. Keep a second editor or
PowerShell window available for external file changes.

## Preconditions

- Use at least two UTF-8 text files and one read-only file.
- Include one CRLF file and one UTF-8 BOM file.
- Keep copies of any test data that matters; destructive delete cases are part
  of this plan.

## Normal path

1. Open two files, edit both, switch tabs, and verify text, selection, scroll,
   Undo, and Redo remain independent.
2. Revert one file exactly to its loaded text and verify its dirty dot clears.
3. Save the other file and verify its dirty dot clears without changing the
   filename label.
4. Restart the application and verify clean tabs, order, active tab, selection,
   and scroll position restore. Dirty text must not restore.
5. Open the read-only file and verify the editor cannot be changed.
6. Save CRLF and BOM fixtures, then verify their original format remains on
   disk.

## Close and workspace protection

1. Dirty two files and close the window or switch workspace.
2. Verify one dialog offers **Save All**, **Discard**, and **Cancel**, with
   **Cancel** as the default.
3. Choose **Save All** and make one destination unwritable. Verify every file is
   attempted, the transition is blocked, successful files are clean, and the
   failed file remains open with an error banner.
4. Repeat with **Cancel** and verify nothing closes. Repeat with **Discard** and
   verify the transition proceeds only after the explicit choice.

## External conflict and deletion

1. Dirty a file in Lithe, edit it externally, and verify Lithe keeps the editor
   text and shows a persistent conflict banner.
2. Choose **Keep Editor Version** and verify no immediate disk write occurs;
   the next explicit save writes conditionally.
3. Repeat and choose **Load Disk Version**. Verify **Cancel** is the default in
   the destructive confirmation and that accepting resets old Undo/Redo while
   preserving a usable view position.
4. Delete an open file externally. Verify its tab and buffer stay open and the
   banner offers **Recreate** or **Close**.
5. Recreate while another process has already recreated the path. Verify the
   save fails with a conflict and does not overwrite that file.

## Rename and delete safety

1. Rename an open dirty file from the project tree. Verify the buffer, dirty
   state, editor view, and tab survive under the new path only after the disk
   rename succeeds.
2. Delete an open dirty file from the project tree. Verify **Cancel**, **Delete
   Disk and Keep Buffer**, and **Delete and Discard** paths independently.
3. Force a rename/delete failure and verify the original document identity and
   buffer remain unchanged.

## Automated checks

Run:

```powershell
cargo test --manifest-path rust/Cargo.toml --offline
ctest --test-dir windows/build-windows -C Release --output-on-failure
pwsh scripts/verify-windows-boundaries.ps1
```

Expected result: Rust tests, all Windows CTest targets, and architecture
boundary checks pass.
