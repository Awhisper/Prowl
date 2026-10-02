import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttyMirrorPaneSource: MirrorPaneSource {
  let manager: WorktreeTerminalManager

  init(manager: WorktreeTerminalManager) {
    self.manager = manager
  }

  func panes() -> [MirrorPaneDescriptor] {
    manager.activeWorktreeStates.flatMap { state in
      let project = state.worktree.repositoryRootURL.lastPathComponent
      return state.tabManager.tabs.flatMap { tab in
        let leaves = state.trees[tab.id]?.leaves() ?? []
        return leaves.enumerated().compactMap { paneIndex, view -> MirrorPaneDescriptor? in
          guard view.surface != nil else { return nil }
          let name = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          let agent = state.surfaceAgentStates[view.id]?.detectedAgent?.rawValue.capitalized
          let terminal = name.isEmpty || name == "Terminal" ? (agent ?? "Shell") : name
          var location = [terminal, state.worktree.name]
          var title = [project, terminal, state.worktree.name]
          if leaves.count > 1 {
            let label = "Pane \(paneIndex + 1)"
            location.append(label)
            title.append(label)
          }
          return MirrorPaneDescriptor(
            id: view.id, title: title.joined(separator: " · "),
            directory: state.worktree.workingDirectory.path, busy: false,
            projectName: project,
            subtitle: location.joined(separator: " · "))
        }
      }
    }.sorted { $0.title < $1.title }
  }

  var supportsViewportText: Bool { true }
  var supportsScrollState: Bool { true }

  func snapshot(_ id: UUID) throws -> MirrorFrame {
    guard let terminal = view(id)?.surface else { throw MirrorProtocolError.invalidMessage }
    let geometry = try captureGeometry(terminal)
    var text = ghostty_text_s()
    guard ghostty_surface_read_snapshot(terminal, &text) else {
      throw MirrorProtocolError.invalidMessage
    }
    defer { ghostty_surface_free_text(terminal, &text) }
    guard text.text_len <= MirrorWire.maximumPayload / 2, let bytes = text.text else {
      throw MirrorProtocolError.messageTooLarge
    }
    let viewportText =
      geometry.active.isScrolled
      ? try viewportText(terminal, columns: geometry.columns, rows: geometry.rows, preserveRows: true) : nil
    guard try captureGeometry(terminal) == geometry else { throw MirrorPaneSourceError.captureChanged }
    return MirrorFrame(
      columns: geometry.columns, rows: geometry.rows,
      bytes: Data(bytes: bytes, count: Int(text.text_len)), viewportText: viewportText,
      scrollBounds: geometry.scrollBounds)
  }

  func write(_ bytes: Data, to id: UUID) throws {
    guard let view = view(id), let terminal = view.surface else {
      throw MirrorProtocolError.invalidMessage
    }
    view.recordEditingActivity()
    // The text action accepts a length-delimited byte buffer. Its escape parser
    // UTF-8-encodes \xNN, so preserve bytes (even split UTF-8) and escape only '\'.
    // The surface text API is unsuitable here because it applies paste encoding again.
    var action = Data("text:".utf8)
    for byte in bytes {
      action.append(byte)
      if byte == 0x5C { action.append(byte) }
    }
    let written = action.withUnsafeBytes {
      ghostty_surface_binding_action(
        terminal, $0.baseAddress!.assumingMemoryBound(to: CChar.self), UInt($0.count))
    }
    guard written else {
      throw MirrorProtocolError.invalidMessage
    }
    // Binding actions bypass keyboard callbacks. A remote command must wake
    // detection too, otherwise an Agent launched from an idle shell stays unknown.
    manager.activeWorktreeStates.first { $0.surfaces[id] != nil }?
      .wakeAgentDetection(forSurfaceID: id)
  }

  var supportsRemoteScroll: Bool { true }

  func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws {
    guard let view = view(id), let terminal = view.surface else { throw MirrorProtocolError.invalidMessage }
    let size = ghostty_surface_size(terminal)
    guard size.columns > 0, (1...1000).contains(size.rows), size.cell_height_px > 0 else {
      throw MirrorProtocolError.invalidMessage
    }
    let rows = max(1, Int(size.rows) - 3)
    if try captureGeometry(terminal).scrollBounds != nil {
      let lines = direction == .upward ? -rows : rows
      let action = "scroll_page_lines:\(lines)"
      guard ghostty_surface_binding_action(terminal, action, UInt(action.utf8.count)) else {
        throw MirrorProtocolError.invalidMessage
      }
      return
    }
    let localPoint = view.window.map { view.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    let localMods = view.ghosttyMods(NSEvent.modifierFlags)
    defer {
      if let localPoint, view.bounds.contains(localPoint) {
        ghostty_surface_mouse_pos(terminal, localPoint.x, view.bounds.height - localPoint.y, localMods)
      } else {
        ghostty_surface_mouse_pos(terminal, -1, -1, localMods)
      }
    }
    // Move through the outside position so an unchanged center cannot retain
    // local modifier keys. Precision pixels avoid the discrete wheel multiplier;
    // applications still decide how many rows each resulting mouse event moves.
    ghostty_surface_mouse_pos(terminal, -1, -1, GHOSTTY_MODS_NONE)
    ghostty_surface_mouse_pos(terminal, view.bounds.midX, view.bounds.midY, GHOSTTY_MODS_NONE)
    let pixels = Double(rows) * Double(size.cell_height_px)
    ghostty_surface_mouse_scroll(terminal, 0, direction == .upward ? pixels : -pixels, 1)
  }

  var supportsBoundedHistory: Bool { true }

  func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
    try boundedText(id, active: false, maximumBytes: MirrorHistory.maximumBytes)
  }

  func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot {
    guard let terminal = view(id)?.surface else { throw MirrorProtocolError.invalidMessage }
    let geometry = try captureGeometry(terminal)
    let text = try viewportText(terminal, columns: geometry.columns, rows: geometry.rows, preserveRows: false)
    guard try captureGeometry(terminal) == geometry else { throw MirrorPaneSourceError.captureChanged }
    return .init(text: text, columns: geometry.columns, rows: geometry.rows, scrollBounds: geometry.scrollBounds)
  }

  private struct Probe: Equatable {
    let pixelY: Double
    let offset: UInt32
    var isScrolled: Bool { pixelY < 0 || offset > 0 }
  }

  private struct CaptureGeometry: Equatable {
    let columns: UInt32
    let rows: UInt32
    let active: Probe
    let screen: Probe
    let mouseCaptured: Bool

    var scrollBounds: MirrorScrollBounds? {
      // Only native scrollback has a provable range. An unscrolled screen with
      // no retained rows may be an alternate-screen TUI with its own history.
      guard !mouseCaptured, active.isScrolled || screen.pixelY < 0 else { return nil }
      return .init(atTop: screen.pixelY >= 0 && screen.offset == 0, atBottom: !active.isScrolled)
    }
  }

  private func captureGeometry(_ terminal: ghostty_surface_t) throws -> CaptureGeometry {
    let size = ghostty_surface_size(terminal)
    guard (1...1000).contains(size.columns), (1...1000).contains(size.rows) else {
      throw MirrorProtocolError.invalidMessage
    }
    let active = try probe(terminal, tag: GHOSTTY_POINT_ACTIVE, coordinate: GHOSTTY_POINT_COORD_EXACT)
    let screen = try probe(terminal, tag: GHOSTTY_POINT_SCREEN, coordinate: GHOSTTY_POINT_COORD_EXACT)
    let bottom = try probe(terminal, tag: GHOSTTY_POINT_VIEWPORT, coordinate: GHOSTTY_POINT_COORD_BOTTOM_RIGHT)
    let columns = UInt32(size.columns)
    let rows = UInt32(size.rows)
    // Surface dimensions can advance before the terminal IO thread applies a
    // resize. The viewport's final cell verifies the terminal grid itself.
    guard bottom.pixelY >= 0, bottom.offset == columns * rows - 1 else { throw MirrorPaneSourceError.captureChanged }
    return .init(
      columns: columns, rows: rows, active: active, screen: screen,
      mouseCaptured: ghostty_surface_mouse_captured(terminal))
  }

  private func probe(
    _ terminal: ghostty_surface_t, tag: ghostty_point_tag_e, coordinate: ghostty_point_coord_e
  ) throws -> Probe {
    let point = ghostty_point_s(tag: tag, coord: coordinate, x: 0, y: 0)
    var text = ghostty_text_s()
    guard ghostty_surface_read_text(terminal, .init(top_left: point, bottom_right: point, rectangle: false), &text)
    else {
      throw MirrorProtocolError.invalidMessage
    }
    defer { ghostty_surface_free_text(terminal, &text) }
    // Geometry remains valid for a blank cell; text length is not a mode probe.
    guard text.tl_px_y.isFinite else { throw MirrorProtocolError.invalidMessage }
    return .init(pixelY: text.tl_px_y, offset: text.offset_start)
  }

  private func viewportText(
    _ terminal: ghostty_surface_t, columns: UInt32, rows: UInt32, preserveRows: Bool
  ) throws -> String {
    if !preserveRows {
      return try readText(
        terminal,
        selection: .init(
          top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
          bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
          rectangle: false))
    }
    // The existing text API unwraps soft lines. Read physical rows separately
    // so the Mac overlay preserves the Host grid without interpreting VT text.
    var lines: [String] = []
    var byteCount = 0
    for row in 0..<rows {
      let line = try readText(
        terminal,
        selection: .init(
          top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
          bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: columns - 1, y: row),
          rectangle: true))
      byteCount += line.utf8.count + (row > 0 ? 1 : 0)
      guard byteCount <= MirrorWire.maximumPayload / 8 else { throw MirrorProtocolError.messageTooLarge }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }

  private func readText(_ terminal: ghostty_surface_t, selection: ghostty_selection_s) throws -> String {
    var result = ghostty_text_s()
    guard ghostty_surface_read_text(terminal, selection, &result) else { throw MirrorProtocolError.invalidMessage }
    defer { ghostty_surface_free_text(terminal, &result) }
    guard result.text_len <= MirrorWire.maximumPayload / 8 else { throw MirrorProtocolError.messageTooLarge }
    guard let bytes = result.text,
      let text = String(bytes: UnsafeRawBufferPointer(start: bytes, count: Int(result.text_len)), encoding: .utf8)
    else { throw MirrorProtocolError.invalidMessage }
    return text
  }

  func activeText(_ id: UUID) throws -> String {
    try boundedText(id, active: true, maximumBytes: MirrorWire.maximumPayload / 8).text
  }

  private func boundedText(_ id: UUID, active: Bool, maximumBytes: Int) throws -> MirrorRetainedText {
    guard let terminal = view(id)?.surface else { throw MirrorProtocolError.invalidMessage }
    var result = ghostty_text_s()
    var truncated = false
    guard
      ghostty_surface_read_text_bounded(
        terminal, active, 10_000, UInt(maximumBytes), &result, &truncated)
    else {
      throw MirrorProtocolError.messageTooLarge
    }
    defer { ghostty_surface_free_text(terminal, &result) }
    guard let bytes = result.text, result.text_len <= maximumBytes,
      let text = String(
        bytes: UnsafeRawBufferPointer(start: bytes, count: Int(result.text_len)), encoding: .utf8)
    else { throw MirrorProtocolError.invalidMessage }
    return MirrorRetainedText(text: text, truncated: truncated)
  }

  func view(_ id: UUID) -> GhosttySurfaceView? {
    manager.activeWorktreeStates.lazy.compactMap { $0.surfaces[id] }.first
  }
}
