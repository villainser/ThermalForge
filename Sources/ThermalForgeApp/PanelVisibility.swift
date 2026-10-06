//
//  PanelVisibility.swift
//  ThermalForge
//
//  Tells AppState when the menu bar dropdown is actually on screen.
//
//  Why not onAppear/onDisappear: MenuBarExtra(.window) keeps its content's hosting view
//  alive while the panel is hidden, and those callbacks follow the view's lifecycle,
//  not whether anyone can see it. onAppear can fire at launch with the panel closed
//  (which would pin the app to full-rate polling for nothing), and onDisappear is not
//  reliably delivered when the panel closes. The window's own state is the truth: this
//  view watches the window it lives in and reports `isVisible` and occlusion.
//
//  Notifications only trigger a re-check; the answer always comes from the window's
//  current state, so a notification that arrives a moment early or late can't leave it
//  wrong. A second check shortly after each notification catches a panel that is
//  ordered out just after it resigns key.
//

import AppKit
import SwiftUI

struct PanelVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let view = VisibilityTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class VisibilityTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var lastReported: Bool?

    private static let watched: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.willCloseNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
    ]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            report()
            return
        }
        for name in Self.watched {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowStateChanged), name: name, object: window
            )
        }
        report()
        recheckSoon()
    }

    @objc private func windowStateChanged() {
        report()
        recheckSoon()
    }

    private func recheckSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.report()
        }
    }

    private func report() {
        let visible = (window?.isVisible ?? false)
            && (window?.occlusionState.contains(.visible) ?? false)
        guard visible != lastReported else { return }
        lastReported = visible
        onChange?(visible)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
