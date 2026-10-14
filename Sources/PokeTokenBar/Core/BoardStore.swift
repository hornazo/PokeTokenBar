import CryptoKit
import Foundation

/// The boards this trainer is in, with each board's replica, kept in `boards.json` next to the save.
/// Board sync merges what peers send; the app re-signs our own rows when our stats change.
@MainActor @Observable
final class BoardStore {
    struct Board: Codable, Equatable, Sendable, Identifiable {
        /// Normalized invite code: the board's secret.
        let code: String
        /// When we joined, kept on every row we sign for this board.
        let joinedAt: Int64
        var replica: BoardReplica
        var lastSyncAt: Int64?
        /// Distinct nearby Macs this board synced with (their per-run sync names), most recent last.
        var syncedWith: [String] = []
        /// Set when we left: the board stays, hidden, until one sync has carried our tombstone.
        var leftAt: Int64?

        var id: String { replica.boardId }
        var boardCode: BoardCode { BoardCode(code)! }
        /// Before the first sync a joiner only has its placeholder.
        var name: String { replica.name ?? Self.placeholderName(boardCode) }

        static func placeholderName(_ code: BoardCode) -> String { "Board \(code.value.prefix(4))" }
    }

    static let shared = BoardStore()

    enum StoreError: Error, Equatable { case invalidCode, alreadyJoined, invalidName }

    /// Every board we hold, including ones we left that still have a tombstone to deliver.
    private(set) var all: [Board] = []
    /// The boards we are in.
    var boards: [Board] { all.filter { $0.leftAt == nil } }
    /// Bumped on every change, so observers (the local API's event stream) react to one value.
    private(set) var revision = 0

    private let fileURL: URL
    private let identity: TrainerIdentity
    private let now: () -> Int64

    init(fileURL: URL = AppStatePaths.directory().appendingPathComponent("boards.json"),
         identity: TrainerIdentity = .shared, now: @escaping () -> Int64 = BoardRules.now) {
        self.fileURL = fileURL
        self.identity = identity
        self.now = now
        load()
    }

    func board(_ id: String) -> Board? { boards.first { $0.id == id } }

    private func index(_ id: String) -> Int? { all.firstIndex { $0.id == id } }

    // MARK: Joining

    /// Creates a board and signs our first row on it. Returns its code to share.
    @discardableResult
    func create(name rawName: String, displayName: String, stats: BoardStats) async throws -> BoardCode {
        let name = Self.sanitizedName(rawName)
        guard !name.isEmpty else { throw StoreError.invalidName }
        let code = BoardCode.random()
        try await add(code: code, boardName: name, displayName: displayName, stats: stats)
        return code
    }

    #if DEBUG
    /// QA only (`PTB_DEBUG_BOARD`): a board with a known code, so two instances can share it unattended.
    func createForTesting(code: BoardCode, name: String, displayName: String, stats: BoardStats) async throws {
        guard board(code.boardId) == nil else { return }
        try await add(code: code, boardName: name, displayName: displayName, stats: stats)
    }
    #endif

    func join(code raw: String, displayName: String, stats: BoardStats) async throws {
        guard let code = BoardCode(raw) else { throw StoreError.invalidCode }
        guard board(code.boardId) == nil else { throw StoreError.alreadyJoined }
        try await add(code: code, boardName: "", displayName: displayName, stats: stats)
    }

    private func add(code: BoardCode, boardName: String, displayName: String, stats: BoardStats) async throws {
        let key = try await identity.privateKey()
        let joinedAt = now()
        var replica = BoardReplica(boardId: code.boardId)
        replica.merge(try BoardRecord.signed(boardId: code.boardId, boardName: boardName, displayName: Self.sanitizedName(displayName),
                                             stats: stats, joinedAt: joinedAt, issuedAt: joinedAt, left: false, key: key),
                      now: joinedAt)
        guard board(code.boardId) == nil else { throw StoreError.alreadyJoined }
        all.removeAll { $0.id == code.boardId }   // rejoining a board we left
        all.append(Board(code: code.value, joinedAt: joinedAt, replica: replica))
        changed()
    }

    /// Signs a tombstone and hides the board. It keeps syncing until one peer has taken the tombstone,
    /// then it's forgotten; until then, other members still see our last row.
    func leave(_ id: String) async {
        guard let key = try? await identity.privateKey(), let i = index(id), all[i].leftAt == nil else { return }
        let t = now()
        if let mine = all[i].replica.records[TrainerSigning.encode(key.publicKey)],
           let tombstone = try? BoardRecord.signed(boardId: id, boardName: mine.boardName, displayName: mine.displayName,
                                                   stats: mine.stats, joinedAt: mine.joinedAt, issuedAt: max(t, mine.issuedAt + 1),
                                                   left: true, key: key) {
            all[i].replica.merge(tombstone, now: t)
        }
        all[i].leftAt = t
        changed()
    }

    // MARK: Our rows

    /// Re-signs our row on every board where the name, stats or board name changed. Cheap to call often;
    /// the caller still debounces, since each new row travels to every peer.
    func publish(displayName rawName: String, stats: BoardStats) async {
        guard !boards.isEmpty, let key = try? await identity.privateKey() else { return }
        let publicKey = TrainerSigning.encode(key.publicKey)
        let displayName = Self.sanitizedName(rawName)
        var didChange = false
        for index in all.indices where all[index].leftAt == nil {
            let board = all[index]
            let mine = board.replica.records[publicKey]
            let boardName = board.replica.name ?? ""
            if let mine, !mine.left, mine.displayName == displayName, mine.stats == stats, mine.boardName == boardName { continue }
            let issuedAt = max(now(), (mine?.issuedAt ?? 0) + 1)
            guard let record = try? BoardRecord.signed(boardId: board.id, boardName: boardName, displayName: displayName,
                                                       stats: stats, joinedAt: board.joinedAt, issuedAt: issuedAt,
                                                       left: false, key: key) else { continue }
            didChange = all[index].replica.merge(record, now: issuedAt) || didChange
        }
        if didChange { changed() }
    }

    // MARK: Sync and battles

    /// Merges what a peer sent for one board after a completed exchange. Invalid rows are dropped inside
    /// the replica. The peer also got our rows, so a board we left has delivered its tombstone and goes.
    func merge(boardId: String, records: [BoardRecord], receipts: [BattleReceipt], from peer: String?) {
        guard let index = index(boardId) else { return }
        if all[index].leftAt != nil {
            all.remove(at: index)
            return changed()
        }
        let t = now()
        for record in records { all[index].replica.merge(record, now: t) }
        for receipt in receipts { all[index].replica.merge(receipt, now: t) }
        all[index].lastSyncAt = t
        if let peer {
            all[index].syncedWith.removeAll { $0 == peer }
            all[index].syncedWith.append(peer)
            all[index].syncedWith = Array(all[index].syncedWith.suffix(50))
        }
        changed()
    }

    /// The replica of any board we still sync, left ones included.
    func replica(_ boardId: String) -> BoardReplica? { index(boardId).map { all[$0].replica } }

    /// A co-signed battle result for one of our boards.
    @discardableResult
    func record(_ receipt: BattleReceipt) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == receipt.boardId && $0.leftAt == nil }),
              all[index].replica.merge(receipt, now: now()) else { return false }
        changed()
        return true
    }

    /// Codes for every board we still sync, for proving membership to a peer.
    var codes: [BoardCode] { all.map(\.boardCode) }

    // MARK: Persistence

    private struct File: Codable {
        var version = 1
        var boards: [Board]
    }

    private func changed() {
        revision += 1
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            all = try JSONDecoder().decode(File.self, from: data).boards.filter { BoardCode($0.code) != nil }
        } catch {
            AppLog.write("boards.json unreadable, starting empty: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(File(boards: all))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.write("boards.json not saved: \(error)")
        }
    }

    static func sanitizedName(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isNewline && $0.unicodeScalars.first?.properties.generalCategory != .control }
        return String(cleaned.prefix(BoardRules.maxNameLength))
    }
}
