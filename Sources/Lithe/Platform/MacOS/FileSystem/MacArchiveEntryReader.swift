import Foundation

struct MacArchiveEntryReader: ArchiveEntryReader {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = MacProcessRunner()) {
        self.processRunner = processRunner
    }

    func read(entry: String, from archive: URL) -> String? {
        let result = processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/unzip",
            arguments: ["-p", archive.path, entry]
        ))
        guard result.succeeded else { return nil }
        return result.output
    }
}
