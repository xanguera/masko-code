import Foundation

@Observable
final class EventStore {
    private(set) var events: [ClaudeEvent] = []
    private let maxEvents = 1000
    private static let filename = "events.json"
    private var persistTimer: Timer?
    private var isDirty = false

    init() {
        events = LocalStorage.load([ClaudeEvent].self, from: Self.filename) ?? []
    }

    /// Debounced persist — batches rapid writes (max once per 5 seconds)
    private func schedulePersist() {
        isDirty = true
        guard persistTimer == nil else { return }
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.persistTimer = nil
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard isDirty else { return }
        isDirty = false
        LocalStorage.save(events, to: Self.filename)
    }

    func append(_ event: ClaudeEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
        schedulePersist()
    }

    func clear() {
        events.removeAll()
        persistTimer?.invalidate()
        persistTimer = nil
        isDirty = false
        LocalStorage.save(events, to: Self.filename)
    }

    func events(for sessionId: String) -> [ClaudeEvent] {
        events.filter { $0.sessionId == sessionId }
    }

    func events(ofType type: HookEventType) -> [ClaudeEvent] {
        events.filter { $0.eventType == type }
    }
}
