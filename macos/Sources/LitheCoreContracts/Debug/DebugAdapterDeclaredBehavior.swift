import Foundation

/// What a plugin declared its debug adapter does beyond standard DAP: the `features` and
/// `defaults` of a `debugAdapters` 3 declaration.
///
/// Rust Core's debug engine follows this instead of recognizing an adapter by its ID. A host
/// only carries it from the manifest to `debug.createSession`, and reads `hotCodeReplace` to
/// decide whether to offer the Apply code changes action.
public struct DebugAdapterDeclaredBehavior: Codable, Equatable, Sendable {
    /// A custom DAP request that applies changed code to the running program.
    public struct HotCodeReplace: Codable, Equatable, Sendable {
        /// The DAP command the engine sends.
        public let request: String
        /// A DAP event whose `message` the Debug Console shows as progress.
        public let event: String?
        /// The response body field that lists the replaced units.
        public let changedField: String?
        /// The response body field with a failure the adapter reports in a successful response.
        public let errorField: String?

        public init(request: String, event: String? = nil, changedField: String? = nil, errorField: String? = nil) {
            self.request = request
            self.event = event
            self.changedField = changedField
            self.errorField = errorField
        }
    }

    /// The launch argument through which the adapter receives stepping filters.
    public struct StepFilterArgument: Codable, Equatable, Sendable {
        public let argument: String

        public init(argument: String) {
            self.argument = argument
        }
    }

    public struct Features: Codable, Equatable, Sendable {
        public let hotCodeReplace: HotCodeReplace?
        public let stepFilters: StepFilterArgument?

        public init(hotCodeReplace: HotCodeReplace? = nil, stepFilters: StepFilterArgument? = nil) {
            self.hotCodeReplace = hotCodeReplace
            self.stepFilters = stepFilters
        }
    }

    /// Stepping filters the adapter starts with when neither the launch nor the user names any.
    public struct DefaultStepFilters: Codable, Equatable, Sendable {
        public let classNameFilters: [String]
        public let skipSynthetics: Bool
        public let skipStaticInitializers: Bool
        public let skipConstructors: Bool
        public let hideFilteredStackFrames: Bool

        public init(classNameFilters: [String] = [], skipSynthetics: Bool = false, skipStaticInitializers: Bool = false,
                    skipConstructors: Bool = false, hideFilteredStackFrames: Bool = false) {
            self.classNameFilters = classNameFilters
            self.skipSynthetics = skipSynthetics
            self.skipStaticInitializers = skipStaticInitializers
            self.skipConstructors = skipConstructors
            self.hideFilteredStackFrames = hideFilteredStackFrames
        }

        private enum CodingKeys: String, CodingKey {
            case classNameFilters, skipSynthetics, skipStaticInitializers, skipConstructors, hideFilteredStackFrames
        }

        /// A manifest may leave any of them out; each then keeps its default.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                classNameFilters: try values.decodeIfPresent([String].self, forKey: .classNameFilters) ?? [],
                skipSynthetics: try values.decodeIfPresent(Bool.self, forKey: .skipSynthetics) ?? false,
                skipStaticInitializers: try values.decodeIfPresent(Bool.self, forKey: .skipStaticInitializers) ?? false,
                skipConstructors: try values.decodeIfPresent(Bool.self, forKey: .skipConstructors) ?? false,
                hideFilteredStackFrames: try values.decodeIfPresent(Bool.self, forKey: .hideFilteredStackFrames) ?? false
            )
        }
    }

    public struct Defaults: Codable, Equatable, Sendable {
        public let stepFilters: DefaultStepFilters?

        public init(stepFilters: DefaultStepFilters? = nil) {
            self.stepFilters = stepFilters
        }
    }

    public let features: Features?
    public let defaults: Defaults?

    /// An adapter that declared nothing keeps the behavior it had before `debugAdapters` 3.
    public static let none = DebugAdapterDeclaredBehavior()

    public init(features: Features? = nil, defaults: Defaults? = nil) {
        self.features = features
        self.defaults = defaults
    }
}
