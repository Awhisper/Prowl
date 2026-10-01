import Foundation
import Observation
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorRemoteScrollTests {
  @Test func oldHostsAndHistoryNeverReceiveRemoteScroll() {
    let old = Channel(supportsScroll: false)
    let oldSession = makeSession(old)
    #expect(!oldSession.canScroll)
    oldSession.scroll(.upward)
    #expect(old.requests.isEmpty)

    let channel = Channel()
    let session = makeSession(channel)
    session.loadHistory(refresh: true)
    session.scroll(.downward)
    #expect(channel.requests.isEmpty)
    #expect(session.showsHistory)
    #expect(session.isLoadingHistory)
  }

  @Test func oneRequestWaitsForItsFreshFrameAndCorrelatedResultIncludingNoOp() throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    let request = try #require(channel.requests.last)
    #expect(session.isScrolling)
    #expect(!session.followsLatest)
    #expect(!session.canScroll)
    session.scroll(.downward)
    #expect(channel.requests.count == 1)

    channel.frame(2)
    #expect(session.isScrolling)
    channel.result(UUID(), sequence: 2)
    channel.onMessage?(.scrollResult(.init(requestID: request, sequence: 2, subscriptionID: UUID())))
    #expect(session.isScrolling)
    channel.result(request, sequence: 2)
    #expect(!session.isScrolling)
    #expect(session.canScroll)
    #expect(session.completedScroll?.direction == .upward)
    #expect(session.text == "current")
    #expect(session.status == .live)
    #expect(channel.closes == 0)

    session.scroll(.downward)
    let next = try #require(channel.requests.last)
    channel.result(request, sequence: 2)
    #expect(session.isScrolling)
    channel.frame(3)
    channel.result(next, sequence: 3)
    #expect(session.completedScroll?.direction == .downward)
    #expect(!session.isScrolling)
  }

  @Test(arguments: [UInt64(0), 1, 2]) func resultCannotCompleteWithoutItsFreshFrame(_ sequence: UInt64) throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    channel.result(try #require(channel.requests.last), sequence: sequence)
    #expect(session.completedScroll == nil)
    #expect(!session.isScrolling)
    #expect(session.status == .disconnected)
    #expect(channel.closes == 1)
  }

  @Test func scopedFailureKeepsConnectionAndLateFailureCannotCancelNextRequest() throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    let first = try #require(channel.requests.last)
    channel.failure(first, code: "SCROLL_UNAVAILABLE: Pane is unavailable")
    #expect(!session.isScrolling)
    #expect(session.scrollError?.contains("SCROLL_UNAVAILABLE") == true)
    #expect(session.status == .live)
    #expect(channel.closes == 0)

    session.scroll(.downward)
    let second = try #require(channel.requests.last)
    #expect(session.scrollError == nil)
    channel.failure(first, code: "SCROLL_BUSY")
    channel.onMessage?(.failure(.init(error: "SCROLL_BUSY", subscriptionID: UUID(), requestID: second)))
    #expect(session.isScrolling)
    channel.failure(second, code: "SCROLL_BUSY")
    #expect(!session.isScrolling)
    #expect(session.canScroll)
  }

  @Test(.timeLimit(.minutes(1))) func timeoutEndsLoadingWithoutReplayAndIgnoresLateReply() async throws {
    let clock = ScrollTestClock()
    let channel = Channel()
    let session = makeSession(channel, clock: clock)
    session.scroll(.upward)
    let first = try #require(channel.requests.last)
    #expect(await clock.nextSleep() == .seconds(5))
    await clock.advance()
    await waitUntil { !session.isScrolling }
    #expect(session.scrollError?.contains("in time") == true)
    #expect(session.status == .live)
    #expect(channel.requests.count == 1)
    session.scroll(.downward)
    channel.frame(2)
    channel.result(first, sequence: 2)
    #expect(session.isScrolling)
    channel.result(try #require(channel.requests.last), sequence: 2)
    #expect(!session.isScrolling)
  }

  @Test func disconnectAndTakeoverClearPendingWithoutReplaying() throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    let stale = channel.onMessage
    let first = try #require(channel.requests.last)
    session.disconnect()
    #expect(!session.isScrolling)
    session.retry()
    #expect(session.status == .live)
    #expect(channel.requests.count == 1)
    stale?(.scrollResult(.init(requestID: first, sequence: 2, subscriptionID: channel.lease)))
    #expect(session.completedScroll == nil)
    session.scroll(.downward)
    channel.onMessage?(.ended(.init(reason: .takenOver)))
    #expect(!session.isScrolling)
    #expect(session.status == .takenOver)
    #expect(channel.requests.count == 2)
  }

  @Test func networkLossClearsLoadingAndOldLeaseCannotCompleteNewScroll() throws {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    let oldRequest = try #require(channel.requests.last)
    let oldLease = channel.lease
    channel.onClose?("Network lost")
    #expect(!session.isScrolling)
    #expect(session.status == .disconnected)
    session.retry()
    #expect(channel.requests.count == 1)
    session.scroll(.downward)
    let currentRequest = try #require(channel.requests.last)
    channel.onMessage?(.scrollResult(.init(requestID: currentRequest, sequence: 2, subscriptionID: oldLease)))
    channel.result(oldRequest, sequence: 2)
    #expect(session.isScrolling)
    channel.frame(2)
    channel.result(currentRequest, sequence: 2)
    #expect(!session.isScrolling)
    #expect(session.completedScroll?.direction == .downward)
  }

  @Test(arguments: [MirrorMessage.EndReason.hostStopped, .paneClosed])
  func hostTerminationClearsLoading(_ reason: MirrorMessage.EndReason) {
    let channel = Channel()
    let session = makeSession(channel)
    session.scroll(.upward)
    channel.onMessage?(.ended(.init(reason: reason)))
    #expect(!session.isScrolling)
    #expect(!session.canScroll)
    #expect(session.status == (reason == .hostStopped ? .hostStopped : .paneClosed))
    #expect(channel.requests.count == 1)
  }

  @Test(.timeLimit(.minutes(1))) func confirmedScrollCannotLaterTimeOut() async throws {
    let clock = ScrollTestClock()
    let channel = Channel()
    let session = makeSession(channel, clock: clock)
    session.scroll(.upward)
    #expect(await clock.nextSleep() == .seconds(5))
    channel.frame(2)
    channel.result(try #require(channel.requests.last), sequence: 2)
    await clock.advance()
    #expect(!session.isScrolling)
    #expect(session.scrollError == nil)
    #expect(session.completedScroll?.direction == .upward)
  }

  @Test func edgeGestureLeavesInteriorHorizontalAndSmallDragsLocal() {
    let top = MirrorRemoteScrollGesture(offset: 0, maximumOffset: 500)
    let middle = MirrorRemoteScrollGesture(offset: 250, maximumOffset: 500)
    let bottom = MirrorRemoteScrollGesture(offset: 500, maximumOffset: 500)
    #expect(top.direction(translation: CGSize(width: 0, height: 80)) == .upward)
    #expect(bottom.direction(translation: CGSize(width: 0, height: -80)) == .downward)
    #expect(top.direction(translation: CGSize(width: 0, height: -80)) == nil)
    #expect(bottom.direction(translation: CGSize(width: 0, height: 80)) == nil)
    #expect(middle.direction(translation: CGSize(width: 0, height: 300)) == nil)
    #expect(top.direction(translation: CGSize(width: 0, height: 40)) == nil)
    #expect(top.direction(translation: CGSize(width: 100, height: 80)) == nil)
    let short = MirrorRemoteScrollGesture(offset: 0, maximumOffset: 0)
    #expect(short.direction(translation: CGSize(width: 0, height: -80)) == .downward)
  }

  @Test func scrollJSONRoundTripsAndRejectsUnknownDirection() throws {
    let request = UUID()
    let lease = UUID()
    for direction in [MirrorMessage.ScrollDirection.upward, .downward] {
      let message = MirrorMessage.scroll(.init(requestID: request, direction: direction, subscriptionID: lease))
      let decoded = try MirrorWire.decode(MirrorWire.encode(message).dropFirst(4))
      #expect(decoded.kind == .scroll)
      #expect(decoded.scrollDirection == direction)
      #expect(decoded.scrollRequestID == request)
      #expect(decoded.subscriptionID == lease)
    }
    let result = MirrorMessage.scrollResult(.init(requestID: request, sequence: 4, subscriptionID: lease))
    let decoded = try MirrorWire.decode(MirrorWire.encode(result).dropFirst(4))
    #expect(decoded.kind == .scrollResult)
    #expect(decoded.scrollRequestID == request)
    #expect(decoded.subscriptionID == lease)
    #expect(decoded.sequence == 4)
    let failure = MirrorMessage.failure(.init(error: "SCROLL_BUSY", subscriptionID: lease, requestID: request))
    #expect(try MirrorWire.decode(MirrorWire.encode(failure).dropFirst(4)).scrollRequestID == request)
    let invalid = """
      {"scroll":{"_0":{"requestID":"\(request)","direction":"left","subscriptionID":"\(lease)"}}}
      """
    #expect(throws: (any Error).self) { try MirrorWire.decode(Data([0]) + Data(invalid.utf8)) }
  }

  private func makeSession(_ channel: Channel, clock: any Clock<Duration> = ContinuousClock()) -> MirrorSession {
    let session = MirrorSession(
      configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: ""), clock: clock,
      makeTransport: { _ in channel })
    session.connect()
    session.select(channel.pane)
    return session
  }

  private func waitUntil(_ predicate: @MainActor () -> Bool) async {
    let changes = AsyncStream.makeStream(of: Void.self)
    defer { changes.continuation.finish() }
    changes.continuation.yield(())
    for await _ in changes.stream {
      let finished = withObservationTracking {
        predicate()
      } onChange: {
        changes.continuation.yield(())
      }
      if finished { break }
    }
  }

  private final class Channel: MirrorTransport {
    var onReady: (() -> Void)?
    var onMessage: ((MirrorMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    let supportsScroll: Bool
    let pane = MirrorPaneDescriptor(id: UUID(), title: "Scroll", directory: "/", busy: false)
    var lease = UUID()
    var requests: [UUID] = []
    var closes = 0
    init(supportsScroll: Bool = true) { self.supportsScroll = supportsScroll }
    func start() { onReady?() }
    func close(_ reason: String?) {
      closes += 1
      onClose?(reason)
    }
    func send(_ message: MirrorMessage, closeAfterSending: Bool) {
      switch message.kind {
      case .list:
        onMessage?(
          .panes(
            .init(
              panes: [pane], capabilities: ["text-v1", "history"] + (supportsScroll ? ["remote-scroll"] : []),
              hostRunID: UUID())))
      case .subscribe:
        lease = UUID()
        onMessage?(.subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: UUID())))
        frame(1)
      case .scroll:
        if let id = message.scrollRequestID { requests.append(id) }
      default: break
      }
    }
    func frame(_ sequence: UInt64) {
      onMessage?(.textFrame(.init(sequence: sequence, text: "current", subscriptionID: lease)))
    }
    func result(_ id: UUID, sequence: UInt64) {
      onMessage?(.scrollResult(.init(requestID: id, sequence: sequence, subscriptionID: lease)))
    }
    func failure(_ id: UUID, code: String) {
      onMessage?(.failure(.init(error: code, subscriptionID: lease, requestID: id)))
    }
  }
}

private nonisolated struct ScrollTestClock: Clock {
  let now = ContinuousClock.now
  let minimumResolution = Duration.zero
  private let storage = Storage()
  func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await storage.sleep(id: id, duration: now.duration(to: deadline))
    } onCancel: {
      Task { await storage.cancel(id) }
    }
  }
  func nextSleep() async -> Duration? { await storage.nextSleep() }
  func advance() async { await storage.advance() }

  private actor Storage {
    let sleeps = AsyncStream.makeStream(of: Duration.self)
    var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var cancelled: Set<UUID> = []
    func sleep(id: UUID, duration: Duration) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if cancelled.remove(id) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          pending[id] = continuation
          sleeps.continuation.yield(duration)
        }
      }
    }
    func nextSleep() async -> Duration? {
      var iterator = sleeps.stream.makeAsyncIterator()
      return await iterator.next()
    }
    func advance() {
      let continuations = pending.values
      pending.removeAll()
      for continuation in continuations { continuation.resume() }
    }
    func cancel(_ id: UUID) {
      if let continuation = pending.removeValue(forKey: id) {
        continuation.resume(throwing: CancellationError())
      } else {
        cancelled.insert(id)
      }
    }
  }
}
