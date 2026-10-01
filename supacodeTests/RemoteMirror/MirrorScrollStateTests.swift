import AppKit
import Clocks
import Testing

@testable import supacode

@MainActor
struct MirrorScrollStateTests {
  @Test func waitsForCorrelatedFramePresentationAndLimitsPendingInput() throws {
    let state = MirrorScrollState()
    state.didPresent(sequence: 4)
    let request = try #require(state.begin())
    #expect(state.begin() == nil)
    state.receiveResult(requestID: UUID(), sequence: 5)
    #expect(state.isLoading)
    state.receiveResult(requestID: request, sequence: 6)
    state.didPresent(sequence: 5)
    #expect(state.isLoading)
    state.didPresent(sequence: 6)
    #expect(!state.isLoading)
    #expect(state.error == nil)
  }

  @Test func resultCanArriveAfterItsFrameWasPresented() throws {
    let state = MirrorScrollState()
    let request = try #require(state.begin())
    state.didPresent(sequence: 1)
    #expect(state.isLoading)
    state.receiveResult(requestID: request, sequence: 1)
    #expect(!state.isLoading)
  }

  @Test func staleFrameCannotConfirmNewInput() throws {
    let state = MirrorScrollState()
    state.didPresent(sequence: 9)
    let request = try #require(state.begin())
    state.receiveResult(requestID: request, sequence: 9)
    #expect(!state.isLoading)
    #expect(state.error != nil)
  }

  @Test func timeoutDoesNotRetryAndLateReplyCannotCompleteNextRequest() async throws {
    let clock = TestClock()
    let state = MirrorScrollState(clock: clock)
    let previous = try #require(state.begin())
    await clock.advance(by: .seconds(5))
    #expect(!state.isLoading)
    #expect(state.error?.contains("timed out") == true)
    let next = try #require(state.begin())
    state.receiveResult(requestID: previous, sequence: 1)
    state.didPresent(sequence: 1)
    #expect(state.requestID == next)
    state.cancel()
    await clock.run()
    #expect(!state.isLoading)
  }

  @Test func resetAllowsNewSubscriptionSequenceAndCancelsTimeout() async throws {
    let clock = TestClock()
    let state = MirrorScrollState(clock: clock)
    state.didPresent(sequence: 100)
    _ = state.begin()
    state.reset()
    await clock.run()
    let next = try #require(state.begin())
    state.didPresent(sequence: 1)
    state.receiveResult(requestID: next, sequence: 1)
    #expect(!state.isLoading)
    #expect(state.error == nil)
  }
}

struct MirrorScrollGestureTests {
  @Test func onePagePerTrackpadGestureAndNoMomentumRequests() {
    var gesture = MirrorScrollGesture()
    #expect(gesture.consume(delta: 10, precise: true, phase: .began, momentum: [], timestamp: 1) == nil)
    #expect(gesture.consume(delta: 25, precise: true, phase: .changed, momentum: [], timestamp: 2) == .upward)
    #expect(gesture.consume(delta: 50, precise: true, phase: .changed, momentum: [], timestamp: 3) == nil)
    #expect(gesture.consume(delta: 0, precise: true, phase: .ended, momentum: [], timestamp: 4) == nil)
    #expect(gesture.consume(delta: 50, precise: true, phase: [], momentum: .changed, timestamp: 5) == nil)
    #expect(gesture.consume(delta: -35, precise: true, phase: .began, momentum: [], timestamp: 6) == .downward)
  }

  @Test func discreteWheelIsRateLimitedWithoutAccumulatingDelayedPages() {
    var gesture = MirrorScrollGesture()
    #expect(gesture.consume(delta: 1, precise: false, phase: [], momentum: [], timestamp: 1) == .upward)
    #expect(gesture.consume(delta: 10, precise: false, phase: [], momentum: [], timestamp: 1.1) == nil)
    #expect(gesture.consume(delta: -1, precise: false, phase: [], momentum: [], timestamp: 1.5) == .downward)
  }
}
