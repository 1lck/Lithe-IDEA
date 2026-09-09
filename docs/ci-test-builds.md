# Downloading CI test builds

The macOS CI and Windows CI workflows upload runnable test builds when their
respective application build lanes are selected. Builds are retained for 14
days. Documentation-only or test-only changes may skip application packaging;
use `workflow_dispatch` on the desired branch to run all lanes of that workflow.

1. Open the PR's **Checks**, then the **macOS CI** or **Windows CI** workflow run.
2. Download the application from the job summary link or the run's **Artifacts**
   section. GitHub requires you to sign in to download artifacts.
3. Match `BUILD-INFO.txt` to the revision you want to test. Artifact names contain
   the built commit SHA. For PR runs this is normally GitHub's test merge commit;
   the PR head commit is recorded separately.

| Artifact | Contents | Launch |
| --- | --- | --- |
| `lithe-macos-universal-<sha>` | An archived `Lithe.app` for Apple Silicon and Intel, with real bundled Java runtimes, language server, and official plugins | Extract the downloaded artifact, then extract `Lithe-macos-universal.zip` and open `Lithe.app` |
| `lithe-windows-x64-<sha>` | `lithe-windows.exe`, adjacent runtime DLLs, bundled extensions, JDK, and language server | Extract the whole artifact to a local Windows folder and run `lithe-windows.exe` |

Windows test builds require the Microsoft Edge WebView2 Runtime. You do not need
to clone the repository or install an IDE, Bun, Rust, or a compiler in the VM.
Keep the Windows resource directories beside the executable; copying only the
EXE leaves the app without its bundled resources.

Windows 11 on ARM supports x64 application emulation, so the x64 artifact can be
used for compatibility testing on an ARM VM. This is not a native ARM64 build,
and it does not establish that every Lithe feature works under emulation. See
[Microsoft's emulation documentation](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation).

These are development builds: macOS apps are ad-hoc signed and not notarized,
and Windows executables are unsigned. OS trust checks can differ from signed
release installs. Test builds use the same application identity and user data
as ordinary Lithe builds; they are not isolated profiles.

Application artifacts are uploaded before subsequent tests, so a build may be
available even if a later check fails. Always review the workflow results as
well as the artifact. A failed application build does not upload a partial
package. The macOS fixture package used by the packaging smoke test is never
uploaded as a runnable test build.
