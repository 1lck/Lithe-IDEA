import LitheModuleAPI
import Foundation

enum JavaFileIconResolver {
    static func resolve(for url: URL, storage: any FileStorage, logSink: (any LogSink)? = nil) async -> LitheIconKind? {
        guard url.pathExtension.lowercased() == "java" else { return nil }
        let data = await Task.detached(priority: .utility) { () -> Data? in
            do { return try storage.readPrefix(from: url, byteCount: 4 * 1024) }
            catch {
                logSink?.emit(EditorIconFallbackSelected(error: error, stage: "java"))
                return nil
            }
        }.value
        guard let data, let prefix = String(data: data, encoding: .utf8) else { return nil }
        return LitheIcons.javaSymbolKind(fromSourcePrefix: prefix)
    }
}
