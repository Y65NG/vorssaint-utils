// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics
import Darwin

/// Keeps an auto-hidden Dock on screen for one hover session without changing
/// the user's auto-hide preference. Only the Dock is told that the pointer still
/// rests on the hovered icon: the moves go straight to its process, so the real
/// cursor, other apps and every screen's work area stay as they are.
final class DockHoverCursor {
    /// Marks the synthetic moves so the preview's own pointer tap can skip them.
    static let eventTag: Int64 = 0x56_5253_444F_434B // "VRSDOCK"
    /// A real pointer leaving the Dock still sends it an exit. Re-asserting the
    /// hover well within the Dock's hide delay keeps it from sliding away.
    static let refreshInterval: TimeInterval = 0.1

    private let post: (CGEvent, pid_t) -> Void
    private let source: CGEventSource?
    private var timer: Timer?
    private var dockPID: pid_t?
    private var point = CGPoint.zero
    private var pointerIsOverDock: () -> Bool = { false }

    var isHolding: Bool { dockPID != nil }

    init(post: @escaping (CGEvent, pid_t) -> Void = { $0.postToPid($1) }) {
        self.post = post
        source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        source?.userData = Self.eventTag
    }

    /// Starts the hold, or re-aims it when the preview moves to another icon.
    /// `point` is in global display coordinates (top-left origin) on that icon.
    func begin(dockPID: pid_t, at point: CGPoint, pointerIsOverDock: @escaping () -> Bool) {
        // A restarted Dock is a new process; let the old one go first.
        if let held = self.dockPID, held != dockPID { end() }
        self.dockPID = dockPID
        self.point = point
        self.pointerIsOverDock = pointerIsOverDock
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// While the real pointer is on the Dock the Dock already follows it, and
    /// a synthetic position would make the magnified icon jump between the two.
    func refresh() {
        guard let dockPID, !pointerIsOverDock(),
              let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left)
        else { return }
        post(move, dockPID)
    }

    /// Lets the Dock hide again. The exit lands on the held icon: the Dock
    /// ignores one placed outside itself and would stay on screen.
    func end() {
        timer?.invalidate()
        timer = nil
        guard let dockPID else { return }
        self.dockPID = nil
        // A pointer back on the Dock owns it now; an exit would hide it under the cursor.
        guard !pointerIsOverDock(),
              let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: 0, context: nil, eventNumber: 0,
                                                trackingNumber: 0, userData: nil)?.cgEvent
        else { return }
        exit.setSource(source)
        exit.location = point
        post(exit, dockPID)
    }
}

/// Earlier versions kept the Dock visible by turning auto-hide off for the
/// session and saved a marker until it was turned back on. Nothing sets the
/// marker anymore; this finishes a restoration that an interrupted session
/// left pending.
enum DockAutohideRecovery {
    static func restoreIfNeeded(defaults: UserDefaults = .standard,
                                writeAutohide: (Bool) -> Bool = { CoreDock.write($0) }) {
        guard defaults.bool(forKey: DefaultsKey.dockPreviewRestoreAutohide) else { return }
        // Keep the marker if the API disappears or restoration fails, so a later launch retries.
        guard writeAutohide(true) else { return }
        defaults.removeObject(forKey: DefaultsKey.dockPreviewRestoreAutohide)
    }
}

/// CoreDock has no public equivalent. Resolve it at runtime so its removal does
/// not prevent the app from launching.
private enum CoreDock {
    typealias Getter = @convention(c) () -> UInt8
    typealias Setter = @convention(c) (UInt8) -> Void
    // Retain the handle for the lifetime of the function pointers.
    static let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY | RTLD_LOCAL)
    static let get: Getter? = symbol("CoreDockGetAutoHideEnabled", as: Getter.self)
    static let set: Setter? = symbol("CoreDockSetAutoHideEnabled", as: Setter.self)

    static func write(_ enabled: Bool) -> Bool {
        guard let set, let get else { return false }
        set(enabled ? 1 : 0)
        return (get() != 0) == enabled
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}
