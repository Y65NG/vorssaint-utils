// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

enum DockHoverCursorTests {
    // Session methods are extracted from production on every test build. Only
    // the Dock lookup, pointer position and workspace notifications are replaced.
    // No event reaches the Dock: every post is recorded instead.
    enum Workspace {
        static let shared = WorkspaceCenter()
        static let activeSpaceDidChangeNotification = Notification.Name("hover.space")
        static let willSleepNotification = Notification.Name("hover.sleep")
        static let sessionDidResignActiveNotification = Notification.Name("hover.session")
    }
    final class WorkspaceCenter {
        let notificationCenter = NotificationCenter()
    }
    enum Pointer {
        static var mouseLocation = CGPoint(x: 500, y: 500)
    }
    struct Post {
        let isMove: Bool
        let location: CGPoint
        let pid: pid_t
        let tagged: Bool
    }
    final class Service {
        typealias NSWorkspace = Workspace
        typealias NSEvent = Pointer
        let dockHoverCursor: DockHoverCursor
        var dockHoldObservers: [NSObjectProtocol] = []
        var dockPID: pid_t? = 40
        var dockStrip: CGFloat = 80
        var sessionEnds = 0
        var tap: CFMachPort?
        var pointerEventGeneration = 0
        var deliveredMoves = 0
        init(_ cursor: DockHoverCursor) { dockHoverCursor = cursor }
        func dockProcessID() -> pid_t? { dockPID }
        func axPoint(fromAppKit point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: 1000 - point.y) }
        func isNearDock(_ point: CGPoint) -> Bool { point.y <= dockStrip }
        func discardFarMouseMove(axPoint: CGPoint) -> Bool { false }
        func admitMouseMove(axPoint: CGPoint) -> Bool { true }
        func cancelPendingMove() {}
        func handleOnMain(type: CGEventType, axPoint: CGPoint) { deliveredMoves += 1 }
        func endSession() {
            sessionEnds += 1
            releaseDockAutohideHold()
        }
    }

    static func run(_ suite: TestSuite) {
        var posts: [Post] = []
        let record: (CGEvent, pid_t) -> Void = { event, pid in
            posts.append(Post(isMove: event.type == .mouseMoved, location: event.location, pid: pid,
                              tagged: event.getIntegerValueField(.eventSourceUserData)
                                  == DockHoverCursor.eventTag))
        }
        func drainMainRunLoop(for seconds: TimeInterval) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }

        let icon = CGPoint(x: 300, y: 980)
        var overDock = false
        let cursor = DockHoverCursor(post: record)
        cursor.begin(dockPID: 40, at: icon) { overDock }
        suite.expect(cursor.isHolding && posts.count == 1 && posts[0].isMove
                     && posts[0].location == icon && posts[0].pid == 40 && posts[0].tagged,
                     "the hold tells only the Dock that the pointer rests on the icon")
        overDock = true
        cursor.refresh()
        suite.expect(posts.count == 1, "a real pointer on the Dock is never overridden")
        overDock = false
        drainMainRunLoop(for: DockHoverCursor.refreshInterval * 3.5)
        suite.expect(posts.count >= 3 && posts.allSatisfy { $0.isMove && $0.location == icon },
                     "the hover is re-asserted after the real pointer leaves the Dock")

        let other = CGPoint(x: 360, y: 980)
        posts = []
        cursor.begin(dockPID: 40, at: other) { overDock }
        suite.expect(posts.count == 1 && posts[0].location == other,
                     "switching to another icon re-aims the existing hold")
        posts = []
        cursor.end()
        suite.expect(!cursor.isHolding && posts.count == 1 && !posts[0].isMove
                     && posts[0].location == other && posts[0].pid == 40 && posts[0].tagged,
                     "ending sends the exit on the held icon, where the Dock accepts it")
        cursor.end()
        drainMainRunLoop(for: DockHoverCursor.refreshInterval * 2.5)
        suite.expect(posts.count == 1, "an ended hold stops re-asserting and releases only once")

        posts = []
        cursor.begin(dockPID: 40, at: icon) { overDock }
        overDock = true
        cursor.end()
        suite.expect(posts.count == 1 && posts[0].isMove,
                     "a pointer back on the Dock keeps it instead of hiding it under the cursor")

        overDock = false
        cursor.begin(dockPID: 40, at: icon) { overDock }
        posts = []
        cursor.begin(dockPID: 41, at: icon) { overDock }
        suite.expect(posts.count == 2 && !posts[0].isMove && posts[0].pid == 40
                     && posts[1].isMove && posts[1].pid == 41,
                     "a restarted Dock releases the old process before holding the new one")
        cursor.end()

        let name = "com.vorssaint.tests.dock-hover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let marker = DefaultsKey.dockPreviewRestoreAutohide
        var writes: [Bool] = []
        var acceptsWrites = true
        let restore = {
            DockAutohideRecovery.restoreIfNeeded(defaults: defaults) { writes.append($0); return acceptsWrites }
        }
        restore()
        suite.expect(writes.isEmpty, "without an interrupted older hold the Dock preference is untouched")
        defaults.set(true, forKey: marker)
        acceptsWrites = false
        restore()
        suite.expect(writes == [true] && defaults.bool(forKey: marker),
                     "a failed restoration stays recoverable for the next launch")
        acceptsWrites = true
        restore()
        suite.expect(writes == [true, true] && defaults.object(forKey: marker) == nil,
                     "an upgrade restores auto-hide left off by an interrupted older session")

        posts = []
        let service = Service(DockHoverCursor(post: record))
        let iconFrame = CGRect(x: 280, y: 0, width: 40, height: 40)
        service.beginDockAutohideHold(on: iconFrame)
        service.beginDockAutohideHold(on: iconFrame.offsetBy(dx: 60, dy: 0))
        suite.expect(posts.count == 2 && posts[0].location == CGPoint(x: 300, y: 980)
                     && posts[1].location == CGPoint(x: 360, y: 980),
                     "the hold aims at the centre of the preview's icon")
        suite.expect(service.dockHoldObservers.count == 3, "switching apps keeps exactly one set of observers")
        posts = []
        Pointer.mouseLocation = CGPoint(x: 500, y: 20)
        service.dockHoverCursor.refresh()
        suite.expect(posts.isEmpty, "the service's own Dock strip decides where the real pointer is")
        Pointer.mouseLocation = CGPoint(x: 500, y: 500)
        for event in [Workspace.activeSpaceDidChangeNotification, Workspace.willSleepNotification,
                      Workspace.sessionDidResignActiveNotification] {
            service.beginDockAutohideHold(on: iconFrame)
            Workspace.shared.notificationCenter.post(name: event, object: nil)
            suite.expect(!service.dockHoverCursor.isHolding && service.dockHoldObservers.isEmpty,
                         "leaving the workspace releases the Dock and its observers")
        }
        posts = []
        service.dockPID = nil
        service.beginDockAutohideHold(on: iconFrame)
        suite.expect(posts.isEmpty && service.dockHoldObservers.isEmpty,
                     "without a running Dock the normal preview is left as it is")

        let tagged = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                             mouseCursorPosition: .zero, mouseButton: .left)!
        tagged.setIntegerValueField(.eventSourceUserData, value: DockHoverCursor.eventTag)
        let real = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                           mouseCursorPosition: .zero, mouseButton: .left)!
        _ = service.handle(type: .mouseMoved, event: tagged)
        _ = service.handle(type: .mouseMoved, event: real)
        var queueDrained = false
        DispatchQueue.main.async { queueDrained = true }
        let deadline = Date().addingTimeInterval(3)
        while !queueDrained && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        suite.expect(queueDrained && service.deliveredMoves == 1,
                     "the preview follows the real pointer, never the Dock hold's virtual one")

        suite.expect(Defaults.registeredDefaults[DefaultsKey.dockPreviewKeepDockVisible] as? Bool == false,
                     "the experiment is disabled by default")
        suite.expect(SettingsBackupSupport.exportKeys().contains(DefaultsKey.dockPreviewKeepDockVisible)
                     && !SettingsBackupSupport.exportKeys().contains(marker),
                     "backups carry the toggle but never another session's recovery state")
    }
}
