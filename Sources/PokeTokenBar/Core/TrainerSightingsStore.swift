import Foundation

/// Trainers seen nearby, kept in `trainers.json` next to the save so the trainer list shows them later.
@MainActor @Observable
final class TrainerSightingsStore {
    static let shared = TrainerSightingsStore()
    static let maxEntries = 300
    /// A trainer still in view is written back at most this often.
    static let saveInterval: Int64 = 60_000

    private(set) var sightings: [String: TrainerSighting] = [:]
    /// Bumped on every saved change, so observers react to one value.
    private(set) var revision = 0

    private let fileURL: URL

    init(fileURL: URL = AppStatePaths.directory().appendingPathComponent("trainers.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Records who is in view now. Saves when someone is new, renamed, or last saved a minute ago or more.
    func saw(_ trainers: [TrainerList.Nearby], at now: Int64) {
        var changed = false
        for trainer in trainers {
            let name = BoardStore.sanitizedName(trainer.name)
            if let old = sightings[trainer.publicKey], old.name == name, now - old.lastSeenAt < Self.saveInterval { continue }
            sightings[trainer.publicKey] = TrainerSighting(publicKey: trainer.publicKey, name: name, lastSeenAt: now)
            changed = true
        }
        guard changed else { return }
        if sightings.count > Self.maxEntries {
            let keep = sightings.values.sorted { $0.lastSeenAt > $1.lastSeenAt }.prefix(Self.maxEntries)
            sightings = Dictionary(keep.map { ($0.publicKey, $0) }, uniquingKeysWith: { a, _ in a })
        }
        revision += 1
        save()
    }

    private struct File: Codable {
        var version = 1
        var trainers: [TrainerSighting]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let trainers = try JSONDecoder().decode(File.self, from: data).trainers
                .filter { TrainerSigning.publicKey($0.publicKey) != nil }
            sightings = Dictionary(trainers.map { ($0.publicKey, $0) }, uniquingKeysWith: { a, b in a.lastSeenAt >= b.lastSeenAt ? a : b })
        } catch {
            AppLog.write("trainers.json unreadable, starting empty: \(error)")
        }
    }

    private func save() {
        do {
            let trainers = sightings.values.sorted { $0.lastSeenAt > $1.lastSeenAt }
            try JSONEncoder().encode(File(trainers: trainers)).write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.write("trainers.json not saved: \(error)")
        }
    }
}
