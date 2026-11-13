import AppKit
import SwiftUI

/// Observes mouse presses in the containing window without consuming them.
/// Coordinates passed to `extraAllowedRect` are relative to this view's bounds,
/// with the origin at the upper left and y increasing downwards.
struct ClickOutsideMonitor: NSViewRepresentable {
    var isActive: Bool
    /// Defaults to the whole view; callers may restrict focus to an input inside it.
    var primaryAllowedRect: ((CGRect) -> CGRect?)? = nil
    var extraAllowedRect: (CGRect) -> CGRect?
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ClickOutsideMonitorView {
        ClickOutsideMonitorView()
    }

    func updateNSView(_ view: ClickOutsideMonitorView, context: Context) {
        view.primaryAllowedRect = primaryAllowedRect
        view.extraAllowedRect = extraAllowedRect
        view.onOutsideClick = onOutsideClick
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: ClickOutsideMonitorView, coordinator: ()) {
        view.stopMonitoring()
        view.onOutsideClick = nil
        view.primaryAllowedRect = nil
        view.extraAllowedRect = nil
    }
}

final class ClickOutsideMonitorView: NSView {
    override var isFlipped: Bool { true }

    // This helper observes input but must never become the mouse target.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var primaryAllowedRect: ((CGRect) -> CGRect?)?
    var extraAllowedRect: ((CGRect) -> CGRect?)?
    var onOutsideClick: (() -> Void)?
    var isActive = false {
        didSet { updateMonitoring() }
    }
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var monitoredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitoring()
    }

    private func updateMonitoring() {
        guard isActive, let window else {
            stopMonitoring()
            return
        }
        if monitoredWindow !== window { stopMonitoring() }
        guard monitor == nil else { return }
        monitoredWindow = window
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.isActive, self.window === window else { return }
                self.onOutsideClick?()
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.observeMouseDown(event) ?? event
        }
    }

    /// Always return the original event so other controls receive the click.
    func observeMouseDown(_ event: NSEvent) -> NSEvent {
        observeMouseDown(at: event.locationInWindow, in: event.window)
        return event
    }

    func observeMouseDown(at windowPoint: NSPoint, in eventWindow: NSWindow?) {
        guard isActive, let window, eventWindow === window else { return }
        let point = convert(windowPoint, from: nil)
        let primary = primaryAllowedRect?(bounds) ?? bounds
        if !primary.contains(point) && !(extraAllowedRect?(bounds)?.contains(point) ?? false) {
            // Defer the binding update so normal event dispatch and focus changes finish.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive, self.window != nil else { return }
                self.onOutsideClick?()
            }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        monitoredWindow = nil
    }

    deinit { stopMonitoring() }
}
