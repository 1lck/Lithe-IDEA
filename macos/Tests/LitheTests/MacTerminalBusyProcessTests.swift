import Foundation
import LitheTerminalModule
import Testing
@testable import Lithe

@MainActor
struct MacTerminalBusyProcessTests {
    private let leader = MacProcessIdentity(processID: 10, startTime: 1_000_000)

    @Test func idleOriginalShellDoesNotPrompt() {
        let programs = inventory([process(10, group: 10, name: "zsh")])
        #expect(programs.isEmpty)
    }

    @Test func execReplacementInLeaderGroupIsBusyEvenWithShellArgv0() {
        // exec preserves the original shell's PID and start time. argv[0] can
        // still claim to be a shell, so the executable path is authoritative.
        let programs = inventory(
            [process(10, group: 10, name: "sleep")],
            executables: [10: "/programs/sleep"],
            commands: [10: ["zsh", "300"]]
        )
        #expect(programs.map(\.processID) == [10])
        #expect(programs.first?.commandLine == "zsh 300")
    }

    @Test func childrenWithJobControlDisabledRemainBusy() {
        let programs = inventory(
            [process(12, parent: 11, group: 10),
             process(10, group: 10, name: "zsh"),
             process(11, parent: 10, group: 10)],
            executables: [10: "/shell/zsh", 11: "/programs/server"],
            commands: [11: ["server", "--port", "8080"]],
            ports: [11: [8080], 12: [3000, 8080]]
        )
        #expect(programs.map(\.processID) == [11])
        #expect(programs.first?.commandLine == "server --port 8080")
        #expect(programs.first?.listeningPorts == [3000, 8080])
    }

    @Test func jobControlledGroupsRemainSeparateAndStable() {
        let programs = inventory(
            [process(30, parent: 10, group: 30),
             process(21, parent: 20, group: 20),
             process(10, group: 10, name: "zsh"),
             process(20, parent: 10, group: 20)],
            ports: [20: [8080], 21: [3000, 8080], 30: [9000]]
        )
        #expect(programs.map(\.processID) == [20, 30])
        #expect(programs.map(\.listeningPorts) == [[3000, 8080], [9000]])
        #expect(programs.first?.startedAt == Date(timeIntervalSince1970: 1))
    }

    @Test func directProcessLaunchCountsLeaderEvenWhenItIsAShell() {
        let programs = inventory(
            [process(10, group: 10, name: "zsh")],
            interactiveShellPath: nil
        )
        #expect(programs.map(\.processID) == [10])
    }

    @Test func reusedPIDIsNotTheOriginalInteractiveShell() {
        let reusedLeader = MacProcessInfo(
            identity: MacProcessIdentity(processID: 10, startTime: 2_000_000),
            parentProcessID: 1, processGroupID: 10, sessionID: 10,
            hasControllingTerminal: true, name: "zsh"
        )
        let programs = inventory([reusedLeader])
        #expect(programs.map(\.processID) == [10])
    }

    @Test func unreadableLeaderExecutableDoesNotSuppressConfirmation() {
        let programs = inventory(
            [process(10, group: 10, name: "zsh")],
            executables: [:]
        )
        #expect(programs.map(\.processID) == [10])
        #expect(programs.first?.commandLine == "zsh")
    }

    private func inventory(
        _ members: [MacProcessInfo],
        interactiveShellPath: String? = "/shell/zsh",
        executables: [Int32: String] = [10: "/shell/zsh"],
        commands: [Int32: [String]] = [:],
        ports: [Int32: [Int]] = [:]
    ) -> [TerminalRunningProgram] {
        MacTerminalTransport.runningPrograms(
            in: members,
            sessionLeader: leader,
            interactiveShellPath: interactiveShellPath,
            arguments: { processID in
                executables[processID].map { executable in
                    MacProcessArguments(
                        executablePath: executable,
                        arguments: commands[processID] ?? [executable],
                        environment: [:]
                    )
                }
            },
            listeningTCPPorts: { ports[$0] ?? [] }
        )
    }

    private func process(
        _ processID: Int32,
        parent: Int32 = 1,
        group: Int32,
        name: String = "worker"
    ) -> MacProcessInfo {
        MacProcessInfo(
            identity: MacProcessIdentity(processID: processID, startTime: 1_000_000),
            parentProcessID: parent,
            processGroupID: group,
            sessionID: leader.processID,
            hasControllingTerminal: true,
            name: name
        )
    }
}
