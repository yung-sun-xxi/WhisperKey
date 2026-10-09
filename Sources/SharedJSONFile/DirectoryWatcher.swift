import Darwin
import Foundation

/// Calls `handler` on `queue` whenever the directory's entries change.
///
/// It watches the directory, not the file. Every write replaces the file atomically, which
/// swaps the inode behind the name, so a watch on the file itself goes deaf after the first
/// write. Adding, removing or renaming an entry is a write to the directory, and that is
/// what an atomic replace does.
///
/// The handler is told only that something changed, not what. Several changes in quick
/// succession may arrive as one call.
public final class DirectoryWatcher {

    private let source: DispatchSourceFileSystemObject

    public init?(directory: URL, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
