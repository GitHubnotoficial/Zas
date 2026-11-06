import AppKit

/// Las últimas capturas, para recuperar una aunque su miniatura ya se haya cerrado.
@MainActor
enum Recents {
    static func files(limit: Int = 8) -> [URL] {
        let fileManager = FileManager.default
        var found: [(url: URL, date: Date)] = []
        for folder in Set([Capture.folder, Capture.scratchFolder]) {
            let names = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in names where ["png", "mp4"].contains(url.pathExtension.lowercased()) {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                found.append((url, date ?? .distantPast))
            }
        }
        return found
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.url)
    }

    static func title(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("Zas ") {
            name.removeFirst(4)
        }
        return name
    }
}
