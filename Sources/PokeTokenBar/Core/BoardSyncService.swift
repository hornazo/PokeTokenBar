import Foundation
@preconcurrency import MultipeerConnectivity

/// Syncs boards with Macs nearby over MultipeerConnectivity, apart from battles (`_ptb-battle`) so each
/// keeps its own protocol version and prompts. Connections need no prompt: they only ever carry boards,
/// whose standings are public; rows prove their own membership (`BoardSyncSession`).
@MainActor @Observable
final class BoardSyncService {
    /// Bonjour service type; must match `NSBonjourServices` in the app's Info.plist.
    static let serviceType = "ptb-board"
    static let versionKey = "v"
    /// How long one sync may take, and how soon the same peer is synced again.
    static let sessionTimeout: Duration = .seconds(30)
    static let resyncInterval: TimeInterval = 5 * 60

    static let shared = BoardSyncService(store: nil)

    private(set) var isRunning = false
    private(set) var lastSyncAt: Date?
    /// Peers synced with since the service started.
    private(set) var syncCount = 0

    var store: BoardStore?
    private var peerID: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var connections: [MCPeerID: Connection] = [:]
    private var lastSynced: [String: Date] = [:]
    private let proxy = BoardSyncProxy()

    private final class Connection {
        let session: MCSession
        var sync: BoardSyncSession
        var timeout: Task<Void, Never>?
        init(session: MCSession, sync: BoardSyncSession) {
            self.session = session
            self.sync = sync
        }
    }

    init(store: BoardStore?) {
        self.store = store
        proxy.owner = self
    }

    /// Runs while sync is on and there is at least one board (left ones still deliver their tombstone).
    func update(enabled: Bool) {
        // Without a league of our own we still watch everyone else's.
        let wanted = enabled && store != nil
        if wanted, !isRunning { start() } else if !wanted, isRunning { stop() }
    }

    private func start() {
        // A random name: board sync never shows who you are to Macs that aren't in your boards.
        let peer = MCPeerID(displayName: "ptb-\(UUID().uuidString.prefix(8))")
        let info = [Self.versionKey: String(BoardSyncMessage.version)]
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: info, serviceType: Self.serviceType)
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        advertiser.delegate = proxy
        browser.delegate = proxy
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        peerID = peer
        self.advertiser = advertiser
        self.browser = browser
        isRunning = true
    }

    private func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        for peer in connections.keys { close(peer) }
        isRunning = false
    }

    /// Only the peer with the smaller name invites, so two Macs don't open two sessions to each other.
    static func shouldInvite(me: String, them: String, lastSynced: Date?, now: Date) -> Bool {
        me < them && (lastSynced.map { now.timeIntervalSince($0) >= resyncInterval } ?? true)
    }

    // MARK: Delegate events (main actor)

    fileprivate func found(_ peer: MCPeerID, info: [String: String]?) {
        guard let peerID, let browser, peer != peerID, connections[peer] == nil,
              info?[Self.versionKey] == String(BoardSyncMessage.version),
              Self.shouldInvite(me: peerID.displayName, them: peer.displayName,
                                lastSynced: lastSynced[peer.displayName], now: Date()),
              let connection = makeConnection(peer) else { return }
        connections[peer] = connection
        browser.invitePeer(peer, to: connection.session, withContext: Data(String(BoardSyncMessage.version).utf8), timeout: 15)
    }

    fileprivate func invited(by peer: MCPeerID, context: Data?, respond: (Bool, MCSession?) -> Void) {
        guard isRunning, connections[peer] == nil, context == Data(String(BoardSyncMessage.version).utf8),
              let connection = makeConnection(peer) else { return respond(false, nil) }
        connections[peer] = connection
        respond(true, connection.session)
    }

    private func makeConnection(_ peer: MCPeerID) -> Connection? {
        guard let peerID, let store else { return nil }
        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = proxy
        let connection = Connection(session: session, sync: BoardSyncSession(replicas: store.syncReplicas))
        connection.timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionTimeout)
            guard !Task.isCancelled else { return }
            self?.close(peer)
        }
        return connection
    }

    fileprivate func peer(_ peer: MCPeerID, changed state: MCSessionState, in session: MCSession) {
        guard let connection = connections[peer], connection.session === session else { return }
        switch state {
        case .connected:
            send(connection.sync.start(), to: peer)
        case .notConnected:
            close(peer)
        default:
            break
        }
    }

    fileprivate func received(_ data: Data, from peer: MCPeerID, in session: MCSession) {
        guard let connection = connections[peer], connection.session === session else { return }
        do {
            let replies = try connection.sync.receive(BoardSyncMessage.decode(data))
            send(replies, to: peer)
            if connection.sync.isFinished { finish(peer) }
        } catch {
            AppLog.write("board sync with a nearby Mac stopped: \(error)")
            close(peer)
        }
    }

    private func send(_ messages: [BoardSyncMessage], to peer: MCPeerID) {
        guard let connection = connections[peer] else { return }
        do {
            for message in messages { try connection.session.send(message.encoded(), toPeers: [peer], with: .reliable) }
        } catch {
            close(peer)
        }
    }

    /// Both directions are done: merge what we got, then hang up after a moment so our last rows leave.
    private func finish(_ peer: MCPeerID) {
        guard let connection = connections[peer], let store else { return }
        for (boardId, shared) in connection.sync.shared {
            guard let received = shared.received else { continue }
            store.merge(boardId: boardId, records: received.records, receipts: received.receipts, from: peer.displayName)
        }
        lastSynced[peer.displayName] = Date()
        lastSyncAt = Date()
        syncCount += 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.close(peer)
        }
    }

    private func close(_ peer: MCPeerID) {
        guard let connection = connections.removeValue(forKey: peer) else { return }
        connection.timeout?.cancel()
        connection.session.disconnect()
        connection.session.delegate = nil
    }

    fileprivate func discoveryFailed(_ error: Error) {
        AppLog.write("board sync discovery failed: \(error)")
    }
}

/// Sendable wrapper for MultipeerConnectivity values that only cross from its delegate queue to the main actor.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Forwards MultipeerConnectivity's private-queue callbacks to the main actor in order (main queue, not
/// `Task`, as `NearbyBattleService` does: tasks carry no ordering guarantee).
private final class BoardSyncProxy: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
                                    MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    weak var owner: BoardSyncService?

    private func onMain(_ work: @escaping @MainActor (BoardSyncService) -> Void) {
        let box = UncheckedBox(value: work)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let owner = self?.owner else { return }
                box.value(owner)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let box = UncheckedBox(value: (peerID, info))
        onMain { $0.found(box.value.0, info: box.value.1) }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let box = UncheckedBox(value: error)
        onMain { $0.discoveryFailed(box.value) }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let box = UncheckedBox(value: (peerID, context, invitationHandler))
        onMain { $0.invited(by: box.value.0, context: box.value.1, respond: box.value.2) }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let box = UncheckedBox(value: error)
        onMain { $0.discoveryFailed(box.value) }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let box = UncheckedBox(value: (peerID, session))
        onMain { $0.peer(box.value.0, changed: state, in: box.value.1) }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let box = UncheckedBox(value: (peerID, session))
        onMain { $0.received(data, from: box.value.0, in: box.value.1) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {}
}
