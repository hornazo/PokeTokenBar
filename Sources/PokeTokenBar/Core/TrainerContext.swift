import Foundation

/// Settings for what leaves the app: the trainer page's local API and board sync. Persisted in
/// UserDefaults; everything is off by default.
@MainActor @Observable
final class TrainerPageSettings {
    static let shared = TrainerPageSettings()
    static let defaultPort = 47323

    private enum Key {
        static let enabled = "trainerPage.enabled"
        static let port = "trainerPage.port"
        static let origins = "trainerPage.pairedOrigins"
        static let shareAIBand = "trainerPage.shareAIBand"
        static let boardSync = "boards.syncNearby"
    }

    private let defaults: UserDefaults

    /// Serve the local API on 127.0.0.1.
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    var port: Int { didSet { defaults.set(port, forKey: Key.port) } }
    /// Origins the user allowed to read the local API, in the order they were allowed.
    var pairedOrigins: [String] { didSet { defaults.set(pairedOrigins, forKey: Key.origins) } }
    /// Publish the weekly AI usage band to the page and to boards.
    var shareAIBand: Bool { didSet { defaults.set(shareAIBand, forKey: Key.shareAIBand) } }
    var boardSync: Bool { didSet { defaults.set(boardSync, forKey: Key.boardSync) } }

    /// `PTB_TRAINER_PORT` overrides the port without saving it, so two instances (each with its own
    /// `PTB_STATE_DIR`) can run side by side for QA.
    init(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Key.enabled)
        let stored = Int(environment["PTB_TRAINER_PORT"] ?? "") ?? defaults.integer(forKey: Key.port)
        port = (1024...65535).contains(stored) ? stored : Self.defaultPort
        pairedOrigins = defaults.stringArray(forKey: Key.origins) ?? []
        shareAIBand = defaults.bool(forKey: Key.shareAIBand)
        boardSync = defaults.bool(forKey: Key.boardSync)
    }

    func pair(_ origin: String) {
        guard !pairedOrigins.contains(origin) else { return }
        pairedOrigins.append(origin)
    }

    func unpair(_ origin: String) {
        pairedOrigins.removeAll { $0 == origin }
    }
}

/// The trainer as the rest of the app knows them: save, usage and battle name. Set up at launch.
@MainActor
final class TrainerContext {
    static let shared = TrainerContext()

    weak var companion: CompanionStore?
    weak var usage: UsageStore?
    var settings = TrainerPageSettings.shared
    var defaults: UserDefaults = .standard

    /// The battle trainer name, also used on boards.
    var displayName: String {
        let stored = BattleTrainer.sanitized(defaults.string(forKey: BattleTrainer.defaultsKey) ?? "")
        return stored.isEmpty ? BattleTrainer.defaultName(random: 0) : stored
    }

    var identity = TrainerIdentity.shared
    /// Our board key, once loaded.
    var publicKey: String? { identity.publicKey }

    var aiBand: WeeklyUsageBand? {
        guard settings.shareAIBand, let usage else { return nil }
        return WeeklyUsageBand(snapshots: usage.snapshots)
    }

    func showcase() -> TrainerShowcase? {
        guard let companion else { return nil }
        return TrainerShowcase.build(state: companion.state, activeName: companion.state.active == nil ? nil : companion.displayName)
    }

    func boardStats() -> BoardStats {
        showcase().map { BoardStats(showcase: $0, aiBand: aiBand) } ?? BoardStats(aiBand: aiBand)
    }
}
