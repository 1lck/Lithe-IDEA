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

struct MacTerminalSessionOwnershipTests {
    private let leader = MacProcessIdentity(processID: 10, startTime: 1_000_000)

    @Test func liveLeaderProvesEverySessionMember() {
        let session = MacTerminalSessionOwnership(leader: leader)
        let snapshot = [member(10, start: 1_000_000), member(11, parent: 10), member(12, parent: 1), other(13)]
        #expect(session.members(in: snapshot).map(\.processID) == [10, 11, 12])
    }

    @Test func jobsOutlivingTheShellRemainStoppableByIdentity() {
        var session = MacTerminalSessionOwnership(leader: leader)
        // Event order: the shell exits, its nohup job survives and forks a child.
        let hasSurvivors = session.pinMembers(snapshot: [member(11, parent: 1)])
        #expect(hasSurvivors)
        let later = [member(11, parent: 1), member(14, parent: 11, start: 3_000_000)]
        #expect(session.members(in: later).map(\.processID) == [11, 14])
    }

    @Test func reusedSessionIDIsNotOwnedAfterTheOriginalSessionEnded() {
        var session = MacTerminalSessionOwnership(leader: leader)
        // The shell and every job exit; the tab stays open.
        let hasMembersAfterExit = session.pinMembers(snapshot: [])
        #expect(!hasMembersAfterExit)
        // An unrelated session later reuses the leader's PID as its session ID.
        let foreign = [member(10, start: 5_000_000), member(20, parent: 10, start: 5_000_100)]
        #expect(session.members(in: foreign).isEmpty)
        let hasForeignMembers = session.pinMembers(snapshot: foreign)
        #expect(!hasForeignMembers, "Later pins keep the first evidence")
    }

    @Test func reusedLeaderPIDIsNeverPinnedAsEvidence() {
        var session = MacTerminalSessionOwnership(leader: leader)
        // The exit is reported late: a newer session already holds the PID.
        let foreign = [member(10, start: 5_000_000), member(20, parent: 10, start: 5_000_100)]
        let hasForeignMembers = session.pinMembers(snapshot: foreign)
        #expect(!hasForeignMembers)
        #expect(session.members(in: foreign).isEmpty)
    }

    private func member(_ processID: Int32, parent: Int32 = 1, start: UInt64 = 2_000_000) -> MacProcessInfo {
        MacProcessInfo(
            identity: MacProcessIdentity(processID: processID, startTime: start),
            parentProcessID: parent, processGroupID: processID, sessionID: leader.processID,
            hasControllingTerminal: true, name: "worker"
        )
    }

    private func other(_ processID: Int32) -> MacProcessInfo {
        MacProcessInfo(
            identity: MacProcessIdentity(processID: processID, startTime: 2_000_000),
            parentProcessID: 1, processGroupID: processID, sessionID: processID,
            hasControllingTerminal: false, name: "elsewhere"
        )
    }
}
