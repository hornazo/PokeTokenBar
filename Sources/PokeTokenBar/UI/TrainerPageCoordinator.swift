import AppKit
import Foundation

/// Connects the trainer page and boards to the app: serves the local API while it's on, pushes changes
/// to open pages, asks before a new page may read anything, re-signs our board rows as stats change, and
/// confirms board invites opened from the page. Installed once at launch.
@MainActor
final class TrainerPageCoordinator {
    static let shared = TrainerPageCoordinator()
    /// Our rows travel to every peer, so they're re-signed at most this often.
    static let publishInterval: Duration = .seconds(60)

    let server = LocalTrainerServer()
    private let settings = TrainerPageSettings.shared
    private let context = TrainerContext.shared
    private let boards = BoardStore.shared
    private let sync = BoardSyncService.shared
    private let hub = BattleSpectatorHub.shared

    /// Origins being asked about, or turned down during this run (asked again next launch).
    private var asking: Set<String> = []
    private var denied: Set<String> = []
    private var publishTask: Task<Void, Never>?
    private var pendingPublish = false

    func install(companion: CompanionStore, usage: UsageStore) {
        context.companion = companion
        context.usage = usage
        sync.store = boards
        sync.update(enabled: settings.boardSync)
        Task { _ = try? await context.identity.privateKey() }

        server.payload = { [weak self] endpoint in self?.payload(endpoint) ?? Data("{}".utf8) }
        server.pairedOrigins = { [weak self] in Set(self?.settings.pairedOrigins ?? []) }
        // Asked after the 403 is on its way: the page retries on its own once the user answers.
        server.onUnpairedOrigin = { [weak self] origin in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.askToPair(origin) } }
        }
        applyServerSettings()

        observe({ [weak self] in _ = self?.settings.enabled; _ = self?.settings.port }) { [weak self] in self?.applyServerSettings() }
        observe({ [weak self] in
            _ = self?.context.companion?.state
            _ = self?.settings.shareAIBand
            _ = self?.context.publicKey
        }) { [weak self] in
            self?.broadcast(.trainer)
            self?.schedulePublish()
        }
        observe({ [weak self] in
            _ = self?.boards.revision
            _ = self?.settings.boardSync
        }) { [weak self] in
            guard let self else { return }
            self.sync.update(enabled: self.settings.boardSync)
            self.broadcast(.boards)
        }
        observe({ [weak self] in
            guard let session = self?.hub.current else { return }
            _ = session.display
            _ = session.message
            _ = session.log
            _ = session.outcome
            _ = session.turnDeadline
        }) { [weak self] in self?.broadcast(.battle) }
        schedulePublish()
        #if DEBUG
        joinDebugBoard()
        #endif
    }

    #if DEBUG
    /// `PTB_DEBUG_BOARD=CODE:Name` joins (or creates) that board at launch, for the two-instance QA run.
    private func joinDebugBoard() {
        guard let spec = AppEnv.debugBoard,
              let code = BoardCode(String(spec.split(separator: ":", maxSplits: 1).first ?? "")) else { return }
        let name = spec.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        Task {
            try? await boards.createForTesting(code: code, name: name, displayName: context.displayName, stats: context.boardStats())
            sync.update(enabled: settings.boardSync)
        }
    }
    #endif

    // MARK: Local API

    private func applyServerSettings() {
        if settings.enabled {
            if server.state != .running(port: settings.port) { server.start(port: settings.port) }
        } else {
            server.stop()
        }
    }

    private func payload(_ endpoint: LocalHTTP.Endpoint) -> Data {
        switch endpoint {
        case .trainer:
            guard let showcase = context.showcase() else { return Data("{}".utf8) }
            return LocalAPIPayloads.encode(LocalAPIPayloads.trainer(name: context.displayName, publicKey: context.publicKey,
                                                                    showcase: showcase, aiBand: context.aiBand))
        case .battle:
            let snapshot = hub.current.map { BattleSpectatorSnapshot.make(from: $0, id: hub.battleId, trainerName: context.displayName) }
            return LocalAPIPayloads.encode(LocalAPIPayloads.Battle(battle: snapshot))
        case .boards:
            return LocalAPIPayloads.encode(LocalAPIPayloads.boards(boards.boards, you: context.publicKey, syncEnabled: settings.boardSync))
        }
    }

    private func broadcast(_ endpoint: LocalHTTP.Endpoint) {
        guard server.streamCount > 0 else { return }
        server.broadcast(LocalTrainerServer.eventName(endpoint), payload(endpoint))
    }

    private func askToPair(_ origin: String) {
        guard !asking.contains(origin), !denied.contains(origin) else { return }
        asking.insert(origin)
        let l = L(context.companion?.language ?? .en)
        let alert = NSAlert()
        alert.messageText = l.trainerPageAllowTitle(origin)
        alert.informativeText = l.trainerPageAllowMessage
        alert.addButton(withTitle: l.trainerPageAllow)
        alert.addButton(withTitle: l.trainerPageDeny)
        NSApp.activate(ignoringOtherApps: true)
        let allowed = alert.runModal() == .alertFirstButtonReturn
        asking.remove(origin)
        if allowed { settings.pair(origin) } else { denied.insert(origin) }
    }

    // MARK: Boards

    /// Debounced: a burst of state changes signs one new row.
    private func schedulePublish() {
        pendingPublish = true
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            while let self, self.pendingPublish {
                self.pendingPublish = false
                await self.boards.publish(displayName: self.context.displayName, stats: self.context.boardStats())
                try? await Task.sleep(for: Self.publishInterval)
            }
            self?.publishTask = nil
        }
    }

    /// A board invite opened from the page. The app always asks; the link only fills in the code.
    func open(_ url: URL) -> Bool {
        guard case .join(let code) = BoardDeepLink.parse(url) else { return false }
        let l = L(context.companion?.language ?? .en)
        NSApp.activate(ignoringOtherApps: true)
        if boards.board(code.boardId) != nil {
            let alert = NSAlert()
            alert.messageText = l.boardsAlreadyJoined
            alert.runModal()
            return true
        }
        let alert = NSAlert()
        alert.messageText = l.boardsJoinTitle
        alert.informativeText = l.boardsJoinMessage(code.display)
        alert.addButton(withTitle: l.boardsJoin)
        alert.addButton(withTitle: l.trainerPageDeny)
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        Task {
            do {
                try await boards.join(code: code.value, displayName: context.displayName, stats: context.boardStats())
                sync.update(enabled: settings.boardSync)
            } catch {
                AppLog.write("joining a board from a link failed: \(error)")
            }
        }
        return true
    }

    // MARK: Observation

    /// Re-arms itself: `withObservationTracking` fires once, before the change lands.
    private func observe(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
        withObservationTracking(read) {
            Task { @MainActor [weak self] in
                onChange()
                self?.observe(read, onChange: onChange)
            }
        }
    }
}
