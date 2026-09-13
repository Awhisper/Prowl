import ComposableArchitecture
import Foundation
import Observation

@MainActor
@Observable
final class RemoteMirrorStore {
  let host: MirrorHost
  private(set) var clients: [MirrorClient] = []
  var selectedID: UUID?
  let savedHosts = MirrorSavedHostCache()
  @ObservationIgnored private let runtime: GhosttyRuntime

  init(manager: WorktreeTerminalManager, runtime: GhosttyRuntime) {
    @Dependency(FeatureFlags.self) var flags
    host = MirrorHost(
      source: GhosttyMirrorPaneSource(manager: manager), enabled: flags.remoteMirror)
    self.runtime = runtime
  }

  var selected: MirrorClient? { clients.first { $0.id == selectedID } }

  func makeClient(address: String, port: UInt16, pairingKey: String) -> MirrorClient {
    let client = MirrorClient(
      configuration: .init(address: address, port: port, pairingKey: pairingKey),
      replica: MirrorReplica(runtime: runtime)
    )
    return client
  }

  func add(_ client: MirrorClient, pane: MirrorPaneDescriptor) {
    clients.append(client)
    selectedID = client.id
    client.subscribe(pane)
  }

  func remove(_ client: MirrorClient) {
    client.close()
    clients.removeAll { $0.id == client.id }
    if selectedID == client.id { selectedID = nil }
  }

  func stop() {
    host.stop()
    for client in clients { client.close() }
  }
}

/// Hover previews read memory only. Secure storage is read after an explicit action.
@MainActor @Observable
final class MirrorSavedHostCache {
  private(set) var entries: [MirrorSavedConnection] = []
  private(set) var hasLoaded = false
  private(set) var notice: String?
  @ObservationIgnored private let load: () throws -> [MirrorSavedConnection]

  init(load: @escaping () throws -> [MirrorSavedConnection] = { try MirrorSavedConnection.loadAll() }) {
    self.load = load
  }

  func loadIfNeeded() {
    guard !hasLoaded else { return }
    do {
      entries = MirrorSavedConnection.verifiedHosts(from: try load() + entries)
      hasLoaded = true
      notice = nil
    } catch {
      SupaLogger("RemoteMirror").warning("Saved Host discovery failed: \(error)")
      notice = "Saved hosts are unavailable. Use Connect to Host to continue."
    }
  }

  func remember(_ connection: MirrorSavedConnection) {
    entries = MirrorSavedConnection.verifiedHosts(from: entries + [connection])
  }
}
