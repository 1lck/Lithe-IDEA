import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A one-shot DAP connection draft. The adapter owns its launch/attach arguments;
/// its TCP address stays outside them and never becomes a debuggee address.
enum ExternalDebugAdapterConfiguration {
    static let maximumArgumentBytes = 256 * 1_024

    enum ValidationError: LocalizedError {
        case invalidArguments

        var errorDescription: String? {
            L10n.string("Enter a JSON object of adapter arguments no larger than 256 KiB.")
        }
    }

    static func make(
        host: String, port: Int, request: DebugRequestKind, argumentsJSON: String
    ) throws -> DebugLaunchConfiguration {
        let data = Data(argumentsJSON.utf8)
        guard data.count <= maximumArgumentBytes,
              let arguments = try? JSONDecoder().decode([String: ToolingJSONValue].self, from: data) else {
            throw ValidationError.invalidArguments
        }
        return DebugLaunchConfiguration(
            name: L10n.string("External Debug Adapter"), request: request, arguments: arguments,
            adapterEndpoint: DebugAdapterEndpoint(host: host, port: port)
        )
    }
}
