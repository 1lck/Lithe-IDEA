import Foundation

/// Packages a staged directory into a single archive for diagnostic-bundle
/// export. Implementations own the compression mechanism; callers only see
/// the directory-in, zip-out contract.
protocol DiagnosticsArchiving: Sendable {
    /// Compresses `directoryURL` into a zip archive at `destinationURL`,
    /// overwriting any existing file there.
    func archive(directoryURL: URL, toZipURL destinationURL: URL) throws
}
