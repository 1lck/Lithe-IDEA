import Darwin
import Foundation

/// Validates plugin-supplied workspace-relative paths and resolves them with
/// descriptor-relative opens.
///
/// Scheme:
/// 1. Lexical validation: no leading `/`, no empty, `.` or `..` component, no
///    NUL, each component at most `NAME_MAX` UTF-8 bytes and the whole path
///    below `PATH_MAX`. Components are normalized to NFC, the form resource
///    IDs use. APFS and HFS+ look names up normalization-insensitively, so an
///    NFC request opens an entry stored in NFD. Case is never folded: on a
///    case-insensitive volume `A.txt` and `a.txt` open the same file and the
///    service echoes the requested spelling; listings return on-disk case.
/// 2. Resolution: the root directory is opened once (following links, because
///    the host chose that path). Every further component is opened with
///    `openat(parent, name, O_NOFOLLOW)` relative to the descriptor of the
///    component before it; the last component is examined with
///    `fstatat(AT_SYMLINK_NOFOLLOW)` or opened with `O_NOFOLLOW`. No path
///    string is ever resolved again after a check.
///
/// What this prevents:
/// - `..` and absolute-path escapes, by construction.
/// - Following a symbolic link anywhere below the root, including a link
///   swapped in after an earlier check (time-of-check/time-of-use): the swap
///   either happens before the `openat` of that component, which then fails
///   with `ELOOP`, or after it, in which case the already-open descriptor still
///   names the original directory.
/// - String-prefix confusion (`/root-other`) and one-shot `realpath` races,
///   because containment is a property of the descriptor chain, not of a path.
///
/// What it does not prevent:
/// - Hard links: a regular file hard-linked into the workspace by someone who
///   can already write there is read like any other file.
/// - A directory moved out of the root by another process while a call holds
///   its descriptor; the call then finishes reading that directory at its new
///   location. It cannot reach anything that was not inside the root when the
///   descriptor was opened.
/// - Mount points inside the root; they are traversed like directories.
/// - Anything a native plugin backend does with its own OS permissions. This
///   only governs reads made through the host service.
enum MacWorkspaceSecurePath {
    static let maximumComponentBytes = Int(NAME_MAX)
    static let maximumPathBytes = Int(PATH_MAX) - 1

    /// Validated, NFC-normalized components of a workspace-relative path.
    /// `""` is the root and yields no components.
    static func components(of path: String) throws -> [String] {
        guard !path.isEmpty else { return [] }
        guard !path.utf8.contains(0) else { throw PluginWorkspaceFileError.invalidPath(.nulCharacter) }
        guard !path.hasPrefix("/") else { throw PluginWorkspaceFileError.invalidPath(.absolute) }
        var components: [String] = []
        for raw in path.split(separator: "/", omittingEmptySubsequences: false) {
            let component = String(raw).precomposedStringWithCanonicalMapping
            switch component {
            case "": throw PluginWorkspaceFileError.invalidPath(.emptyComponent)
            case ".": throw PluginWorkspaceFileError.invalidPath(.currentDirectoryComponent)
            case "..": throw PluginWorkspaceFileError.invalidPath(.parentTraversal)
            default: break
            }
            guard component.utf8.count <= maximumComponentBytes else {
                throw PluginWorkspaceFileError.invalidPath(.componentTooLong)
            }
            components.append(component)
        }
        guard components.joined(separator: "/").utf8.count <= maximumPathBytes else {
            throw PluginWorkspaceFileError.invalidPath(.pathTooLong)
        }
        return components
    }

    /// Opens the root directory. The caller owns and closes the descriptor.
    static func openRoot(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let error = errno
            throw error == ENOENT || error == ENOTDIR ? PluginWorkspaceFileError.invalidRoot : map(error)
        }
        return descriptor
    }

    /// Opens `components` as directories below `rootDescriptor`, one
    /// `openat(O_NOFOLLOW)` per component. Returns a new descriptor the caller
    /// closes; `rootDescriptor` stays open.
    ///
    /// `afterOpeningComponent` runs after each component is open, with its
    /// index. Production passes nil; tests use it to replace path components
    /// between two steps and prove the held descriptor is not re-resolved.
    static func openDirectory(
        _ components: ArraySlice<String>,
        below rootDescriptor: Int32,
        afterOpeningComponent: ((Int) -> Void)? = nil
    ) throws -> Int32 {
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw map(errno) }
        for (offset, component) in components.enumerated() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = classifyOpenFailure(errno, name: component, in: current)
                Darwin.close(current)
                throw error
            }
            Darwin.close(current)
            current = next
            afterOpeningComponent?(offset)
        }
        return current
    }

    /// Opens a regular file for reading without following a final link and
    /// without blocking on FIFOs. The caller closes the descriptor.
    static func openRegularFile(named name: String, in directory: Int32) throws -> (descriptor: Int32, status: Darwin.stat) {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw classifyOpenFailure(errno, name: name, in: directory)
        }
        var status = Darwin.stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw map(error)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw PluginWorkspaceFileError.notRegularFile
        }
        return (descriptor, status)
    }

    /// `lstat` of `name` relative to `directory`.
    static func status(of name: String, in directory: Int32) throws -> Darwin.stat {
        var status = Darwin.stat()
        guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw map(errno) }
        return status
    }

    static func kind(of status: Darwin.stat) -> PluginWorkspaceEntryKind {
        switch status.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }

    /// `O_NOFOLLOW` reports a link as `ELOOP`, and `O_DIRECTORY` reports a
    /// link or file as `ENOTDIR`; `lstat` tells the two cases apart.
    private static func classifyOpenFailure(_ error: Int32, name: String, in directory: Int32) -> PluginWorkspaceFileError {
        guard error == ELOOP || error == ENOTDIR else { return map(error) }
        var status = Darwin.stat()
        if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_mode & S_IFMT == S_IFLNK {
            return .symbolicLinkNotFollowed
        }
        return error == ELOOP ? .symbolicLinkNotFollowed : .notDirectory
    }

    static func map(_ error: Int32) -> PluginWorkspaceFileError {
        switch error {
        case ENOENT: .notFound
        case ENOTDIR: .notDirectory
        case EACCES, EPERM: .permissionDenied
        case ELOOP: .symbolicLinkNotFollowed
        case ENAMETOOLONG: .invalidPath(.pathTooLong)
        default: .io(errno: error)
        }
    }
}
