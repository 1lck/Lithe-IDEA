import Foundation

/// Repository identity returned by Core for a file, independent of the active checkout.
package struct GitFileContext: Decodable, Sendable {
    package let root: String
    package let path: String
    package let ownership: String
}
