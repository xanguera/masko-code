import AppKit
import SwiftUI

/// NSHostingController subclass that supports transparent background
final class TransparentHostingController<Content: View>: NSHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.layer?.masksToBounds = false
    }
}

/// Manages the floating mascot overlay panel lifecycle.
/// Uses two panels: a fixed-size mascot panel and a child HUD panel above it.
@MainActor
@Observable
final class OverlayManager {
    private(set) var isOverlayActive = false
    private(set) var currentURL: URL?
    private(set) var currentConfig: MaskoAnimationConfig?
    private(set) var currentStateMachine: OverlayStateMachine?
    private var panel: OverlayPanel?      // Mascot video — fixed size
    private var hudPanel: OverlayPanel?   // Stats/debug/permissions — floats above
    private var workspaceObservers: [NSObjectProtocol] = []

    // Stores passed from AppStore for overlay display
    // Non-optional with defaults — avoids @Environment crash when overlay renders before stores are set
    var sessionStore: SessionStore = SessionStore()
    var eventStore: EventStore = EventStore()
    var pendingPermissionStore: PendingPermissionStore = PendingPermissionStore()

    var currentSize: OverlaySize {
        get {
            OverlaySize(rawValue: UserDefaults.standard.integer(forKey: "overlay_size")) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "overlay_size")
            resizePanel(to: newValue)
        }
    }

    func showOverlay(url: URL) {
        // If same URL already active, just re-assert
        if panel != nil, currentURL == url {
            reassertPanel()
            isOverlayActive = true
            return
        }

        // Close existing
        hideOverlay()

        let size = currentSize.cgSize
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        // Restore position or default to bottom-right
        let savedX = UserDefaults.standard.double(forKey: "overlay_x")
        let savedY = UserDefaults.standard.double(forKey: "overlay_y")
        let origin: CGPoint
        if savedX > 0 || savedY > 0 {
            origin = CGPoint(x: savedX, y: savedY)
        } else {
            origin = CGPoint(
                x: screenFrame.maxX - size.width - 40,
                y: screenFrame.minY + 40
            )
        }

        let rect = NSRect(origin: origin, size: size)
        let newPanel = OverlayPanel(contentRect: rect)

        let view = OverlayMascotView(
            url: url,
            onClose: { [weak self] in self?.hideOverlay() },
            onResize: { [weak self] newSize in self?.currentSize = newSize }
        )

        let controller = TransparentHostingController(rootView: view)
        newPanel.contentView = controller.view
        newPanel.contentViewController = controller

        // Show without stealing focus
        newPanel.orderFrontRegardless()

        // Move into a system-level Space that doesn't participate in Space swipe animations
        SkyLightOperator.shared.delegateWindow(newPanel)

        print("[masko-desktop] Overlay panel shown at \(rect), level=\(newPanel.level.rawValue)")

        self.panel = newPanel
        self.currentURL = url
        self.isOverlayActive = true

        // Save URL for restore on relaunch
        UserDefaults.standard.set(url.absoluteString, forKey: "overlay_url")

        setupObservers(for: newPanel)
    }

    /// Show overlay using a canvas config with a full state machine.
    /// Creates two panels: mascot (fixed) + HUD (child, above).
    func showOverlayWithConfig(_ config: MaskoAnimationConfig) {
        // Close existing
        hideOverlay()

        self.currentConfig = config

        // Pre-download all videos immediately (fire and forget)
        Task { await VideoCache.shared.preload(config: config) }

        // Save config JSON for restore on relaunch
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "overlay_config")
        }

        // Create state machine
        let sm = OverlayStateMachine(config: config)
        self.currentStateMachine = sm
        sm.start()

        // --- Mascot panel (fixed size, just the video) ---
        let size = currentSize.cgSize
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero

        let savedX = UserDefaults.standard.double(forKey: "overlay_x")
        let savedY = UserDefaults.standard.double(forKey: "overlay_y")
        let origin: CGPoint
        if savedX > 0 || savedY > 0 {
            origin = CGPoint(x: savedX, y: savedY)
        } else {
            origin = CGPoint(
                x: screenFrame.maxX - size.width - 40,
                y: screenFrame.minY + 40
            )
        }

        let mascotRect = NSRect(origin: origin, size: size)
        let mascotPanel = OverlayPanel(contentRect: mascotRect)

        let mascotView = OverlayStateMachineView(
            stateMachine: sm,
            onClose: { [weak self] in self?.hideOverlay() },
            onResize: { [weak self] newSize in self?.currentSize = newSize }
        )

        let mascotController = TransparentHostingController(rootView: mascotView)
        mascotPanel.contentView = mascotController.view
        mascotPanel.contentViewController = mascotController

        mascotPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(mascotPanel)

        // --- HUD panel (child window, above mascot) ---
        let hudView = HUDOverlayView(stateMachine: sm)
            .environment(sessionStore)
            .environment(pendingPermissionStore)

        // HUD panel above mascot — compact width for overlay prompts
        let hudWidth = max(size.width * 1.5, 280)
        let hudRect = NSRect(
            x: mascotRect.midX - hudWidth / 2,
            y: mascotRect.maxY + 4,
            width: hudWidth,
            height: 400
        )
        let newHudPanel = OverlayPanel(contentRect: hudRect)
        newHudPanel.isMovableByWindowBackground = false

        let hudController = TransparentHostingController(rootView: hudView)
        newHudPanel.contentView = hudController.view
        newHudPanel.contentViewController = hudController

        newHudPanel.orderFrontRegardless()
        SkyLightOperator.shared.delegateWindow(newHudPanel)

        // Attach HUD as child — moves together when mascot is dragged
        mascotPanel.addChildWindow(newHudPanel, ordered: .above)

        print("[masko-desktop] State machine overlay: mascot=\(mascotRect), hud above")

        self.panel = mascotPanel
        self.hudPanel = newHudPanel
        self.isOverlayActive = true

        setupObservers(for: mascotPanel)

        // Also reposition HUD when mascot moves (child windows move together,
        // but we need to keep the HUD anchored to the top)
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: mascotPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionHUD() }
        }
        workspaceObservers.append(moveObserver)
    }

    /// Recompute aggregate session state and push inputs to the state machine.
    /// Can be called independently (e.g. after interrupt detection) without needing an event.
    func refreshInputs() {
        guard let sm = currentStateMachine else { return }

        let active = sessionStore.activeSessions
        let isWorking = active.contains { $0.phase == .running }
        let isIdle = active.allSatisfy { $0.phase == .idle } || active.isEmpty
        let isAlert = pendingPermissionStore.count > 0
        let isCompacting = active.contains { $0.isCompacting }
        let sessionCount = active.count

        sm.setInput("claudeCode::isWorking", .bool(isWorking))
        sm.setInput("claudeCode::isIdle", .bool(isIdle))
        sm.setInput("claudeCode::isAlert", .bool(isAlert))
        sm.setInput("claudeCode::isCompacting", .bool(isCompacting))
        sm.setInput("claudeCode::sessionCount", .number(Double(sessionCount)))
    }

    /// Compute aggregate session state and push inputs to the state machine.
    /// Called after SessionStore.recordEvent() has already updated session phases.
    func handleEvent(_ event: ClaudeEvent) {
        refreshInputs()

        // Fire granular event trigger (auto-resets after transition)
        guard let sm = currentStateMachine else { return }
        let eventInput = "claudeCode::\(event.hookEventName)"
        sm.setInput(eventInput, .bool(true))
    }

    func hideOverlay() {
        // Remove all observers
        for observer in workspaceObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        hudPanel?.close()
        hudPanel = nil
        panel?.close()
        panel = nil
        currentURL = nil
        currentConfig = nil
        currentStateMachine = nil
        isOverlayActive = false
        UserDefaults.standard.removeObject(forKey: "overlay_url")
        UserDefaults.standard.removeObject(forKey: "overlay_config")
    }

    func toggleOverlay() {
        if isOverlayActive {
            hideOverlay()
        } else if let urlString = UserDefaults.standard.string(forKey: "overlay_url"),
                  let url = URL(string: urlString) {
            showOverlay(url: url)
        }
    }

    /// Restore overlay from previous session
    func restoreIfNeeded() {
        // Config-based overlay (state machine) takes priority
        if let configData = UserDefaults.standard.data(forKey: "overlay_config"),
           let config = try? JSONDecoder().decode(MaskoAnimationConfig.self, from: configData) {
            showOverlayWithConfig(config)
            return
        }
        // Fall back to URL-based overlay (single video loop)
        guard let urlString = UserDefaults.standard.string(forKey: "overlay_url"),
              let url = URL(string: urlString) else { return }
        showOverlay(url: url)
    }

    // MARK: - Private

    /// Re-apply window level and bring to front without stealing focus.
    private func reassertPanel() {
        guard let panel else { return }
        panel.level = .screenSaver
        panel.orderFrontRegardless()
        if let hudPanel {
            hudPanel.level = .screenSaver
            hudPanel.orderFrontRegardless()
        }
    }

    private func resizePanel(to size: OverlaySize) {
        guard let panel else { return }
        let newSize = size.cgSize
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y - (newSize.height - frame.height),
            width: newSize.width,
            height: newSize.height
        )
        panel.setFrame(newFrame, display: true, animate: true)
        repositionHUD()
    }

    /// Position the HUD panel centered above the mascot panel
    private func repositionHUD() {
        guard let panel, let hudPanel else { return }
        let mascotFrame = panel.frame
        let hudSize = hudPanel.frame.size
        let newOrigin = CGPoint(
            x: mascotFrame.midX - hudSize.width / 2,
            y: mascotFrame.maxY + 4
        )
        hudPanel.setFrameOrigin(newOrigin)
    }

    private func savePosition() {
        guard let panel else { return }
        UserDefaults.standard.set(panel.frame.origin.x, forKey: "overlay_x")
        UserDefaults.standard.set(panel.frame.origin.y, forKey: "overlay_y")
    }

    private func setupObservers(for targetPanel: OverlayPanel) {
        // Observe position changes to persist
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: targetPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.savePosition() }
        }
        workspaceObservers.append(moveObserver)

        // Re-assert panel when switching Spaces
        let spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertPanel() }
        }
        workspaceObservers.append(spaceObserver)

        // Re-assert panel when another app activates (Cmd+Tab)
        let appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reassertPanel() }
        }
        workspaceObservers.append(appObserver)
    }
}
