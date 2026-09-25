import Foundation

/// Owns one temporary Java argument file until its process has terminated.
package protocol JavaLaunchArgumentLease: AnyObject, Sendable {}

/// Result of shortening one Java process launch.
package struct JavaLaunchArgumentPreparation: Sendable {
    package let arguments: [String]
    package let lease: (any JavaLaunchArgumentLease)?

    package init(arguments: [String], lease: (any JavaLaunchArgumentLease)? = nil) {
        self.arguments = arguments
        self.lease = lease
    }
}

/// Platform adapter for the shared Rust Java command-line planner.
package protocol JavaLaunchArgumentPreparing: Sendable {
    func prepareJavaLaunch(
        executablePath: String,
        arguments: [String]
    ) throws -> JavaLaunchArgumentPreparation
}
