// RestartRequestWatcher — picks up requests/restart-<udid>.json and
// requests/keyboard-<udid>.json files and hands each to ChainManager. Parsing
// and the rules live in iMirrorCore (RestartRequests.swift,
// KeyboardRequests.swift); this file only watches, reads and deletes.
//
// A DispatchSource on the folder hears new files at once. A 5 s scan backs it
// up: the source goes deaf if someone deletes and recreates the folder.
//
// Main thread only.

import Foundation
import iMirrorCore

final class RestartRequestWatcher {
    let dir: URL
    /// Each readable request, once; its file is already gone.
    var onRequest: ((RestartRequest) -> Void)?
    /// Each keyboard request, or refusal, once; its file is already gone.
    var onKeyboard: ((KeyboardRequestFile.Read) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init(dir: URL) { self.dir = dir }

    func start() {
        guard timer == nil else { return }
        // 0700: only this user may restart a phone.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        armSource()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.scan() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()   // left while the app was off; stale ones dropped
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        source?.cancel()
        source = nil
    }

    private func armSource() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    /// Read, delete and deliver every request file in the folder.
    func scan(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names.sorted() {
            let url = dir.appendingPathComponent(name)
            if KeyboardRequestFile.udid(fromFileName: name) != nil {
                scanKeyboard(name, url, now: now)
                continue
            }
            switch RestartRequestFile.read(fileName: name, data: try? Data(contentsOf: url)) {
            case .notOurs:
                continue
            case .unreadable:
                removeIfOld(url, now: now)
            case .request(let r):
                // Delete first: a request is acted on once, whatever follows.
                try? fm.removeItem(at: url)
                onRequest?(r)
            }
        }
    }

    private func scanKeyboard(_ name: String, _ url: URL, now: Date) {
        let read = KeyboardRequestFile.read(fileName: name, data: try? Data(contentsOf: url))
        switch read {
        case .notOurs: return
        case .unreadable: removeIfOld(url, now: now)
        case .request, .refused:
            try? FileManager.default.removeItem(at: url)
            onKeyboard?(read)
        }
    }

    private func removeIfOld(_ url: URL, now: Date) {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if now.timeIntervalSince(mtime) > RestartRequestFile.unreadableGraceSec {
            try? fm.removeItem(at: url)
        }
    }
}
