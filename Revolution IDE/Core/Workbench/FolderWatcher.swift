import Foundation
import CoreServices

/// Watches a folder tree for changes made outside the app. Finder, `git checkout`, another
/// process extracting files into it, and calls back so the Project Navigator can pick them up.
/// This app treats an open folder project as a live view of the filesystem rather than a one-time
/// import, so a file that appears on disk should appear in the sidebar without the user having to
/// close and reopen the project.
///
/// Wraps the FSEvents API (recursive, whole-tree watching in one stream, unlike `DispatchSource`
/// file-system-object sources which only watch a single path each). The C callback can't capture
/// Swift context directly, so `self` is threaded through via `FSEventStreamContext.info`, the
/// standard pattern for this API.
nonisolated final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let callback: () -> Void

    init?(url: URL, callback: @escaping () -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, clientInfo, _, _, _, _) in
                guard let clientInfo else { return }
                Unmanaged<FolderWatcher>.fromOpaque(clientInfo).takeUnretainedValue().callback()
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency: coalesces a burst of changes (extracting a disc, a git checkout, ...) into one refresh
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
