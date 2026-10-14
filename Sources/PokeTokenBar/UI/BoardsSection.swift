import AppKit
import SwiftUI

/// Leaderboards in the Battle tab: create one, join with a code, see your rank, sync with trainers nearby.
@MainActor
struct BoardsSection: View {
    let l: L
    var boards = BoardStore.shared
    var sync = BoardSyncService.shared
    var settings = TrainerPageSettings.shared
    var context = TrainerContext.shared

    @State private var newName = ""
    @State private var code = ""
    @State private var error: String?
    @State private var leaving: BoardStore.Board?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l.boardsTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if boards.boards.isEmpty {
                Text(l.boardsEmpty).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(boards.boards) { board in row(board) }
            HStack(spacing: 6) {
                TextField(l.boardsNamePlaceholder, text: $newName)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(create)
                Button(l.boardsCreate, action: create)
                    .controlSize(.small)
                    .disabled(working || BoardStore.sanitizedName(newName).isEmpty)
            }
            HStack(spacing: 6) {
                TextField(l.boardsCodePlaceholder, text: $code)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit(join)
                Button(l.boardsJoin, action: join)
                    .controlSize(.small)
                    .disabled(working || code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            Toggle(l.boardsSync, isOn: Binding(
                get: { settings.boardSync },
                set: { settings.boardSync = $0; sync.update(enabled: $0) }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(boards.codes.isEmpty)
            Text(l.boardsSyncHint).font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(leaving.map { l.boardsLeaveConfirm($0.name) } ?? "", isPresented: Binding(
            get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button(l.boardsLeave, role: .destructive) {
                guard let board = leaving else { return }
                leaving = nil
                Task {
                    await boards.leave(board.id)
                    sync.update(enabled: settings.boardSync)
                }
            }
        }
    }

    private func row(_ board: BoardStore.Board) -> some View {
        let standings = BoardScoring.standings(board.replica)
        let me = context.publicKey.flatMap { key in standings.first { $0.record.publicKey == key } }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "trophy").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(board.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(l.boardsMembers(standings.count))
                    if let me {
                        Text(l.boardsRank(me.rank, of: standings.count))
                        Text(l.boardsPoints(me.score.total))
                    }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Text(syncText(board)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Menu {
                Button(l.boardsCopyCode) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(board.boardCode.display, forType: .string)
                }
                Divider()
                Button(l.boardsLeave, role: .destructive) { leaving = board }
            } label: {
                Text(board.boardCode.display).font(.system(.caption2, design: .monospaced))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func syncText(_ board: BoardStore.Board) -> String {
        guard let last = board.lastSyncAt else { return l.boardsNotSynced }
        let date = Date(timeIntervalSince1970: Double(last) / 1000)
        return l.boardsSynced(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
    }

    private func create() {
        let name = newName
        run {
            try await boards.create(name: name, displayName: context.displayName, stats: context.boardStats())
            newName = ""
        }
    }

    private func join() {
        let raw = code
        run {
            try await boards.join(code: raw, displayName: context.displayName, stats: context.boardStats())
            code = ""
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await body()
                sync.update(enabled: settings.boardSync)
            } catch let failure as BoardStore.StoreError {
                switch failure {
                case .invalidCode: error = l.boardsInvalidCode
                case .alreadyJoined: error = l.boardsAlreadyJoined
                case .invalidName: error = nil
                }
            } catch {
                self.error = l.boardsKeyUnavailable
            }
        }
    }
}
