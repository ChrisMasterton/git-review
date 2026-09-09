import Foundation
import Darwin

/// Filesystem absence is independent of whether Git can inspect a checkout.
/// Never interpret permissions, a replaced path, or a Git error as absence.
enum CheckoutFolder {
    static func isMissing(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } != 0 && errno == ENOENT
    }
}
