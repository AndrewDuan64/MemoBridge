import AppKit
import Foundation

@main struct Smoke {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = ClickOutsideMonitorView(frame: NSRect(x: 10, y: 200, width: 100, height: 30))
        window.contentView!.addSubview(view)
        var dismissals = 0
        view.onOutsideClick = { dismissals += 1 }
        view.extraAllowedRect = { bounds in CGRect(x: 0, y: bounds.height + 6, width: 100, height: 40) }
        view.isActive = true
        guard view.hitTest(NSPoint(x: 1, y: 1)) == nil else { fatalError("Monitor intercepted input") }
        func click(_ p: NSPoint, in eventWindow: NSWindow?) {
            view.observeMouseDown(at: view.convert(p, to: nil), in: eventWindow)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        click(NSPoint(x: 15, y: 15), in: window)
        click(NSPoint(x: 15, y: 40), in: window)
        click(NSPoint(x: 150, y: 15), in: other)
        guard dismissals == 0 else { fatalError("Input, panel, or other-window click dismissed focus") }
        view.primaryAllowedRect = { _ in CGRect(x: 30, y: 0, width: 70, height: 30) }
        click(NSPoint(x: 45, y: 15), in: window)
        guard dismissals == 0 else { fatalError("Input click dismissed focus") }
        click(NSPoint(x: 15, y: 15), in: window)
        guard dismissals == 1 else { fatalError("Click elsewhere on input row did not dismiss focus") }
        click(NSPoint(x: 150, y: 15), in: window)
        guard dismissals == 2 else { fatalError("Outside click did not dismiss focus") }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard dismissals == 2 else { fatalError("Other-window resignation dismissed focus") }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard dismissals == 3 else { fatalError("Window resignation did not dismiss focus") }
        view.isActive = false
        click(NSPoint(x: 150, y: 15), in: window)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        guard dismissals == 3 else { fatalError("Inactive monitor notified") }
        print("Outside click monitor: inside/panel, outside, window scoping, resign and cleanup passed")
    }
}
