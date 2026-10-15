import Foundation

/// Keeps an in-memory list of installed apps. Scans once at launch, then rescans only when
/// one of the application folders changes (kqueue directory watch — no polling).
final class AppIndex {
    private(set) var apps: [AppEntry] = []
    var onChange: (() -> Void)?

    static var roots: [(url: URL, depth: Int)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Utilities first: once a folder is visited it is skipped, so it gets its own full depth.
        return [
            (URL(fileURLWithPath: "/Applications/Utilities"), 2),
            (URL(fileURLWithPath: "/Applications"), 2),
            (URL(fileURLWithPath: "/System/Applications"), 2),
            (home.appendingPathComponent("Applications"), 2),
        ]
    }
    static let extras = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]

    private let queue = DispatchQueue(label: "glasslight.index", qos: .utility)
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    func start() {
        rescan()
        for root in Self.roots { watch(root.url) }
    }

    func rescan() {
        queue.async { [weak self] in
            let found = Self.scan()
            DispatchQueue.main.async {
                self?.apps = found
                self?.onChange?()
            }
        }
    }

    private func watch(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleRescan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    /// Installers touch the folder many times in a row; coalesce into one rescan.
    private func scheduleRescan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    static func scan() -> [AppEntry] {
        let fm = FileManager.default
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        var seen: Set<String> = [me]
        var visitedDirs = Set<String>()
        var out: [AppEntry] = []

        func add(_ app: URL, linkName: String?) {
            let real = app.resolvingSymlinksInPath()
            guard seen.insert(real.path).inserted else { return }
            let file = real.deletingPathExtension().lastPathComponent
            var name = linkName ?? fm.displayName(atPath: real.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            let info = NSDictionary(contentsOf: real.appendingPathComponent("Contents/Info.plist"))
            let id = info?["CFBundleIdentifier"] as? String ?? real.path
            out.append(AppEntry(url: real, name: name, id: id, aliases: [file]))
        }

        func visit(_ dir: URL, level: Int, maxLevel: Int) {
            guard visitedDirs.insert(dir.path).inserted,
                  let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                          options: []) else { return }
            // Not .skipsHiddenFiles: /Applications/Safari.app is a symlink carrying the "hidden" flag.
            for item in items where !item.lastPathComponent.hasPrefix(".") {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    // e.g. "/Applications/Adobe Creative Cloud/Adobe Creative Cloud" -> ACC/Creative Cloud.app
                    let target = item.resolvingSymlinksInPath()
                    if target.pathExtension == "app" {
                        add(target, linkName: item.pathExtension == "app" ? nil : item.lastPathComponent)
                    }
                } else if item.pathExtension == "app" {
                    add(item, linkName: nil)
                } else if values?.isDirectory == true, level < maxLevel {
                    visit(item, level: level + 1, maxLevel: maxLevel)
                }
            }
        }

        for root in roots { visit(root.url, level: 1, maxLevel: root.depth) }
        for extra in extras where fm.fileExists(atPath: extra.path) { add(extra, linkName: nil) }
        return out
    }
}
