import Foundation
import Testing
@testable import Lithe

@Suite("Terminal shell discovery")
struct MacTerminalShellDiscoveryTests {
    @Test
    func discoversRegisteredAndPathShellsInStableOrderWithoutDuplicates() {
        let executables = Set(["/bin/zsh", "/bin/bash", "/tools/bin/fish", "/tools/bin/nu", "/custom/login-shell"])
        let shells = MacTerminalShellDiscovery.discover(
            environment: ["SHELL": "/bin/zsh", "PATH": "/tools/bin:/tools/bin:relative"],
            registeredShells: "# Login shells\n/bin/zsh\n/bin/bash # system\n/custom/login-shell\n/missing/shell\nrelative-shell"
        ) { executables.contains($0) }
        #expect(shells == ["/bin/zsh", "/bin/bash", "/custom/login-shell", "/tools/bin/fish", "/tools/bin/nu"])
    }

    @Test
    func missingEnvironmentStillFindsInstalledSystemShells() {
        let shells = MacTerminalShellDiscovery.discover(environment: [:], registeredShells: "") { $0 == "/bin/bash" }
        #expect(shells == ["/bin/bash"])
    }

    @Test
    func usesShellSpecificStartupArguments() {
        #expect(MacTerminalShellDiscovery.startupArguments(for: "/bin/zsh") == ["-l", "-i"])
        #expect(MacTerminalShellDiscovery.startupArguments(for: "/tools/fish") == ["-l", "-i"])
        #expect(MacTerminalShellDiscovery.startupArguments(for: "/tools/nu") == ["--login", "--interactive"])
        #expect(MacTerminalShellDiscovery.startupArguments(for: "/tools/pwsh") == ["-NoLogo", "-Login"])
        #expect(MacTerminalShellDiscovery.startupArguments(for: "/tools/unknown") == [])
    }
}
