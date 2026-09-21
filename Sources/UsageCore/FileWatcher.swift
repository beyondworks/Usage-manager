import Foundation
import CoreServices

/// Recursively watches directories via FSEvents and reports which paths were
/// written (coalesced by `latency`), so callers can re-read only those files.
public final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: ([String]) -> Void

    public init(paths: [String], latency: CFTimeInterval = 1.0, onChange: @escaping ([String]) -> Void) {
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.latency = latency
        self.onChange = onChange
    }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let changed = (unsafeBitCast(eventPaths, to: CFArray.self) as? [String]) ?? []
            Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue().onChange(changed)
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, flags) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
