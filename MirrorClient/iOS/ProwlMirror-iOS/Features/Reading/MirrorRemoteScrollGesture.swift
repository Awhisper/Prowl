import Foundation

nonisolated struct MirrorRemoteScrollGesture: Equatable {
  let offset: CGFloat
  let maximumOffset: CGFloat

  func direction(translation: CGSize) -> MirrorMessage.ScrollDirection? {
    guard abs(translation.height) >= 64, abs(translation.height) > abs(translation.width) * 1.5 else { return nil }
    if offset <= 1, translation.height > 0 { return .upward }
    if offset >= maximumOffset - 1, translation.height < 0 { return .downward }
    return nil
  }
}
