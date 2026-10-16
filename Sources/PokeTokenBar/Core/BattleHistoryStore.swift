import Foundation

/// Finished battles, newest first, kept in `battles.json` next to the save for the trainer page.
@MainActor @Observable
final class BattleHistoryStore {
    static let shared = BattleHistoryStore()
    static let maxEntries = 100

    private(set) var entries: [BattleHistoryEntry] = []
    /// Bumped on every change, so observers (the local API's event stream) react to one value.
    private(set) var revision = 0

    private let fileURL: URL

    init(fileURL: URL = AppStatePaths.directory().appendingPathComponent("battles.json")) {
        self.fileURL = fileURL
        load()
    }

    func add(_ entry: BattleHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        revision += 1
        save()
    }

    private struct File: Codable {
        var version = 1
        var battles: [BattleHistoryEntry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            entries = Array(try JSONDecoder().decode(File.self, from: data).battles.prefix(Self.maxEntries))
        } catch {
            AppLog.write("battles.json unreadable, starting empty: \(error)")
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(File(battles: entries)).write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.write("battles.json not saved: \(error)")
        }
    }
}
