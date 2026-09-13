import ComposableArchitecture
import SwiftUI

struct MirrorHostButton: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Environment(ToolbarPopoverCoordinator.self) private var popovers
  @Dependency(FeatureFlags.self) private var featureFlags
  @State private var sheet: MirrorSheet?
  @State private var connectionToOpen: MirrorSavedConnection?

  private enum MirrorSheet: String, Identifiable {
    case pairing, connect
    var id: String { rawValue }
  }

  private var status: String {
    if !mirrors.host.isRunning { return "Host off" }
    return mirrors.host.subscriberCount == 0 ? "Host listening" : "Host mirroring"
  }

  private var tint: Color {
    guard mirrors.host.isRunning else { return .secondary }
    return mirrors.host.subscriberCount == 0 ? .blue.opacity(0.65) : .green.opacity(0.65)
  }

  var body: some View {
    if featureFlags.remoteMirror {
      let isPresented = popovers.presented == .mirror
      Button {
        popovers.toggle(.mirror)
      } label: {
        Image(systemName: "network").foregroundStyle(tint)
      }
      .help("Remote Mirror — \(status). Hover to preview or click to keep open.")
      .accessibilityLabel("Remote Mirror — \(status)")
      .accessibilityIdentifier("remote-mirror-host-button")
      .onHover { if sheet == nil { popovers.hoverButton(.mirror, hovering: $0) } }
      .popover(
        isPresented: Binding(
          get: { isPresented },
          set: {
            if !$0 {
              popovers.dismiss(.mirror)
            }
          }
        )
      ) {
        MirrorPopover {
          MirrorSettingsView(
            host: mirrors.host,
            interact: { popovers.pin(.mirror) },
            pair: { present(.pairing) },
            connect: {
              connectionToOpen = nil
              present(.connect)
            },
            reconnect: {
              connectionToOpen = $0
              present(.connect)
            }
          )
          .fixedSize(horizontal: false, vertical: true)
        }
        .onHover { popovers.hoverPopover(.mirror, hovering: $0) }
      }
      .background {
        Color.clear
          .sheet(item: $sheet) { destination in
            switch destination {
            case .pairing:
              MirrorPairingView(host: mirrors.host) { sheet = nil }
            case .connect:
              AddRemoteMirrorView(dismiss: { sheet = nil }, savedHost: connectionToOpen)
            }
          }
      }
      .onDisappear {
        popovers.dismiss(.mirror)
      }
    }
  }

  private func present(_ destination: MirrorSheet) {
    popovers.dismiss(.mirror)
    sheet = destination
  }
}

private struct MirrorPopover<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @State private var contentHeight: CGFloat = 360

  var body: some View {
    ScrollView {
      content()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
    }
    .frame(width: 460, height: min(contentHeight, max(240, (NSScreen.main?.visibleFrame.height ?? 840) - 180)))
    .transaction { $0.animation = nil }
  }
}

private struct MirrorSettingsView: View {
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Bindable var host: MirrorHost
  let interact: () -> Void
  let pair: () -> Void
  let connect: () -> Void
  let reconnect: (MirrorSavedConnection) -> Void
  @State private var savedHosts: [MirrorSavedConnection] = []

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Remote Mirror").font(.title2.bold())
      VStack(alignment: .leading, spacing: 12) {
        Text("Host").font(.headline)
        Text("Start a service so other Prowl apps on your network can connect to this Mac.")
          .foregroundStyle(.secondary)
        Form {
          TextField("Listen IP", text: $host.address)
            .help("Use 0.0.0.0 for all IPv4 interfaces, or this Mac’s local IP.")
          TextField("Port", text: $host.port)
            .help("The network port other Prowl apps connect to")
        }
        .disabled(host.isRunning || host.isStarting)
        HStack {
          Text(
            host.isRunning
              ? "Listening · \(host.subscriberCount) mirrors" : (host.isStarting ? "Starting…" : "Host is off")
          )
          .font(.callout).foregroundStyle(.secondary)
          Spacer()
          if host.isRunning || host.isStarting {
            Button("Stop Host", role: .destructive) {
              interact()
              host.stop()
            }
            .help("Disconnect mirrors and stop listening; local terminals keep running")
          } else {
            Button("Start Host") {
              interact()
              host.start()
            }.buttonStyle(.borderedProminent)
              .help("Allow paired Prowl devices to connect to this Mac")
          }
        }
        if host.isRunning {
          Button("Add a Device…", action: pair)
            .help("Open a single-use pairing code with a 60-second expiry")
            .disabled(host.isStarting)
        }
        ForEach(host.devices) { device in
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
              Text(device.name).lineLimit(1)
              let panes = host.mirroredPanes(for: device.id)
              Text(host.isOnline(device.id) ? "Connected · \(panes.count) mirrors" : "Offline")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(panes) { pane in
                Text(pane.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  .help(pane.title + "\n" + pane.directory)
              }
            }
            Spacer()
            Button("Revoke", role: .destructive) {
              interact()
              host.revoke(device.id)
            }
            .help("Disconnect this device and require it to pair again")
          }
        }
        if let error = host.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        Text("Closing this panel keeps Host running.").font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      VStack(alignment: .leading, spacing: 12) {
        Text("Client").font(.headline)
        Text("Connect to Prowl on another device and mirror one of its terminal panes.")
          .foregroundStyle(.secondary)
        ForEach(savedHosts, id: \.endpointID) { saved in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(saved.endpointID).lineLimit(1)
              Text("Paired Host").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect") { reconnect(saved) }
              .help("Connect to this saved Host and select a pane")
          }
        }
        if let error = mirrors.credentialError { Text(error).font(.caption).foregroundStyle(.red) }
        Button("Connect to Host…", action: connect)
          .help("Enter another device’s address and pair with its Prowl app")
      }
    }
    .padding(24)
    .frame(width: 460)
    .accessibilityIdentifier("remote-mirror-host-panel")
    .onAppear { savedHosts = mirrors.savedHosts() }
    .onChange(of: host.address) { _, _ in interact() }
    .onChange(of: host.port) { _, _ in interact() }
  }
}

private struct MirrorPairingView: View {
  @Bindable var host: MirrorHost
  let dismiss: () -> Void
  @State private var copied = false
  @State private var copyError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add a Device").font(.title2.bold())
      Text(
        "On the other device, open Prowl’s Remote Mirror button. "
          + "Under Client, choose Connect to Host and enter this Mac’s address and the code below."
      )
      .foregroundStyle(.secondary)
      if let expires = host.pairingExpiresAt {
        Text(host.pairingKey).font(.title2.monospaced()).textSelection(.enabled)
        HStack {
          Text("Code expires in")
          Text(expires, style: .timer).monospacedDigit()
        }.font(.callout).foregroundStyle(.secondary)
        Button(copied ? "Copied" : "Copy Pairing Code") {
          NSPasteboard.general.clearContents()
          copied = NSPasteboard.general.setString(host.pairingKey, forType: .string)
          copyError = copied ? nil : "Unable to copy the pairing code."
        }
        .help("Copy the single-use pairing code")
        .accessibilityIdentifier("remote-mirror-copy-key")
      } else {
        Text("The code was used or expired. Refresh to pair another device.")
          .foregroundStyle(.secondary)
      }
      if let error = copyError ?? host.error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Cancel", role: .cancel) {
          host.cancelPairing()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .help("Close this window and invalidate the unused code")
        Spacer()
        Button("Refresh Code") { host.addDevice() }
          .disabled(host.isStarting || !host.isRunning)
          .help("Invalidate the old code and create a new 60-second code")
      }
    }
    .padding(24).frame(width: 440)
    .onAppear { host.addDevice() }
    .onChange(of: host.pairingKey) { _, _ in
      copied = false
      copyError = nil
    }
    .onDisappear { host.cancelPairing() }
  }
}
