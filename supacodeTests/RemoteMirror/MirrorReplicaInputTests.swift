import AppKit
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct MirrorReplicaInputTests {
  private static let runtime = GhosttyRuntime()

  @Test(.timeLimit(.minutes(1))) func replayDoesNotForwardAutomaticTerminalReports() async throws {
    let replica = MirrorReplica(runtime: Self.runtime)
    let lease = UUID()
    var input = Data()
    var acknowledged: UInt64 = 0
    replica.onMessage = { message in
      if case .input(let payload) = message { input.append(payload.bytes) }
      if case .acknowledge(let payload) = message { acknowledged = payload.sequence }
    }
    defer { replica.stop() }
    try replica.start()
    try await wait { replica.view != nil }
    let view = try #require(replica.view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    for sequence in 1...3 {
      replica.display(
        .frame(
          .init(
            frame: .init(
              columns: 80, rows: 24,
              bytes: Data("\u{1b}[?1004h\u{1b}[?2031h\u{1b}[?2048h\u{1b}[?2004hSCREEN \(sequence)".utf8)),
            sequence: UInt64(sequence), subscriptionID: lease)))
      try await wait { acknowledged == UInt64(sequence) }
    }
    // Reports are generated asynchronously after the helper writes and ACKs a frame.
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
    try await wait { ContinuousClock.now >= deadline }
    #expect(input.isEmpty, "Frame replay generated Host input: \(Array(input))")

    view.insertText("用户输入", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await wait { (String(data: input, encoding: .utf8) ?? "").contains("用户输入") }
    #expect((String(data: input, encoding: .utf8) ?? "").contains("\u{1b}[200~用户输入\u{1b}[201~"))
  }

  private func wait(until condition: @MainActor () -> Bool) async throws {
    let (ticks, continuation) = AsyncStream<Void>.makeStream()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in continuation.yield(()) }
    defer {
      timer.invalidate()
      continuation.finish()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    for await _ in ticks {
      if condition() { return }
      if ContinuousClock.now >= deadline { throw Timeout() }
    }
    throw Timeout()
  }

  private struct Timeout: Error {}
}
