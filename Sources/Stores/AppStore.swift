import AppKit
import Foundation

@Observable
final class AppStore {
    let localServer = LocalServer()
    let eventStore = EventStore()
    let sessionStore = SessionStore()
    let notificationStore = NotificationStore()
    let notificationService = NotificationService.shared
    let pendingPermissionStore = PendingPermissionStore()
    let mascotStore = MascotStore()

    private(set) var eventProcessor: EventProcessor!
    private(set) var isReady = false
    private(set) var isRunning = false

    /// Called when a Claude Code event is received — wire to OverlayManager.handleEvent
    var onEventForOverlay: ((ClaudeEvent) -> Void)?
    /// Called when a custom input is received via POST /input
    var onInputForOverlay: ((String, ConditionValue) -> Void)?
    /// Called when session phases change outside of events (e.g. interrupt detection via transcript)
    var onRefreshOverlay: (() -> Void)?

    var hasUnreadNotifications: Bool { notificationStore.unreadCount > 0 }

    var hasCompletedOnboarding: Bool = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    init() {
        self.eventProcessor = EventProcessor(
            eventStore: eventStore,
            sessionStore: sessionStore,
            notificationStore: notificationStore,
            notificationService: notificationService
        )

        // Wire local server → event processor + overlay state machine
        localServer.onEventReceived = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                await self.eventProcessor.process(event)

                // If the tool that was awaiting permission has now completed,
                // the user answered from the terminal — dismiss the overlay prompt.
                // Match by toolUseId to avoid false dismissals from subagent events.
                if let eventType = event.eventType,
                   let sid = event.sessionId,
                   let toolUseId = event.toolUseId,
                   (eventType == .postToolUse || eventType == .postToolUseFailure),
                   self.pendingPermissionStore.pending.contains(where: {
                       $0.event.sessionId == sid && $0.event.toolUseId == toolUseId
                   }) {
                    self.pendingPermissionStore.dismissForSession(sid)
                }

                self.onEventForOverlay?(event)
            }
        }

        // Wire local server → custom input endpoint
        localServer.onInputReceived = { [weak self] name, value in
            guard let self else { return }
            Task { @MainActor in
                self.onInputForOverlay?(name, value)
            }
        }

        // Wire local server → permission requests (hold connection for user decision)
        localServer.onPermissionRequest = { [weak self] event, connection in
            guard let self else { return }
            Task { @MainActor in
                self.pendingPermissionStore.add(event: event, connection: connection)
            }
        }

        // Wire interrupt detection → overlay refresh
        sessionStore.onPhasesChanged = { [weak self] in
            self?.onRefreshOverlay?()
        }

        // Update permission notification with resolution outcome
        pendingPermissionStore.onResolved = { [weak self] event, outcome in
            guard let self else { return }
            for notification in self.notificationStore.notifications where
                notification.resolutionOutcome == .pending &&
                notification.category == .permissionRequest &&
                notification.sessionId == event.sessionId {
                self.notificationStore.updateResolution(notification.id, outcome: outcome)
                break
            }
        }
    }

    /// Call once from .task {} on the menu bar view
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        do {
            try HookInstaller.ensureScriptExists()
        } catch {
            print("[masko-desktop] Failed to create hook script: \(error)")
        }

        // Evict cached videos older than 30 days
        VideoCache.shared.evictStaleFiles()

        await notificationService.requestPermission()

        do {
            try localServer.start()
        } catch {
            print("[masko-desktop] Failed to start local server: \(error)")
        }

        // Reconcile sessions when app comes to foreground (crash recovery)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sessionStore.reconcileIfNeeded()
        }

        isReady = true
    }
}
