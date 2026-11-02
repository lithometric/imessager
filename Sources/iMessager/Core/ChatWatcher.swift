import CoreServices
import Foundation

/// Wakes the agent the moment Messages writes to chat.db (FSEvents, ~50 ms latency, no busy polling).
final class ChatWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "imessager.watcher", qos: .userInitiated)
    private let directory: String
    fileprivate let onChange: @Sendable () -> Void

    init(directory: String, onChange: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            // Only the database and its WAL matter; ignore -shm churn from our own reads and attachment writes.
            guard list.contains(where: { ($0 as? String).map { $0.hasSuffix("chat.db") || $0.hasSuffix("chat.db-wal") } ?? false })
            else { return }
            Unmanaged<ChatWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [directory] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
