import Foundation

struct SavedMascot: Identifiable, Codable {
    let id: UUID
    let name: String
    var config: MaskoAnimationConfig
    let addedAt: Date
}

@Observable
final class MascotStore {
    private(set) var mascots: [SavedMascot] = []
    private static let filename = "mascots.json"

    private static let seedVersion = 3 // Bump to re-apply default config on next launch

    init() {
        mascots = LocalStorage.load([SavedMascot].self, from: Self.filename) ?? []
        if mascots.isEmpty {
            seedDefaults()
        } else {
            migrateSeedIfNeeded()
        }
    }

    private func seedDefaults() {
        // Try fetching from masko.ai first, fall back to bundled JSON
        Task {
            if let config = await Self.fetchRemoteConfig() {
                await MainActor.run {
                    self.add(config: config)
                    UserDefaults.standard.set(Self.seedVersion, forKey: "defaultMascotSeedVersion")
                }
                return
            }
            // Offline fallback: load from bundle
            await MainActor.run {
                guard let config = Self.loadBundledConfig() else { return }
                self.add(config: config)
                UserDefaults.standard.set(Self.seedVersion, forKey: "defaultMascotSeedVersion")
            }
        }
    }

    private static func fetchRemoteConfig() async -> MaskoAnimationConfig? {
        guard let url = URL(string: "\(Constants.maskoBaseURL)/api/mascot-templates/masko") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(MaskoAnimationConfig.self, from: data)
    }

    /// Re-apply the default mascot config when the seed version is bumped (e.g. condition fixes).
    private func migrateSeedIfNeeded() {
        let current = UserDefaults.standard.integer(forKey: "defaultMascotSeedVersion")
        guard current < Self.seedVersion else { return }
        guard let config = Self.loadBundledConfig() else { return }

        // Match either old name or new name
        if let idx = mascots.firstIndex(where: { $0.name == config.name || $0.name == "claude code test" }) {
            mascots[idx].config = config
            persist()
            print("[masko-desktop] Default mascot config updated to seed v\(Self.seedVersion)")
        }
        UserDefaults.standard.set(Self.seedVersion, forKey: "defaultMascotSeedVersion")
    }

    private static func loadBundledConfig() -> MaskoAnimationConfig? {
        guard let url = Bundle.module.url(forResource: "claude-code-default", withExtension: "json", subdirectory: "Defaults"),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(MaskoAnimationConfig.self, from: data) else { return nil }
        return config
    }

    private func persist() {
        LocalStorage.save(mascots, to: Self.filename)
    }

    func add(config: MaskoAnimationConfig) {
        let mascot = SavedMascot(
            id: UUID(),
            name: config.name,
            config: config,
            addedAt: Date()
        )
        mascots.insert(mascot, at: 0)
        persist()
    }

    func remove(id: UUID) {
        mascots.removeAll { $0.id == id }
        persist()
    }

    func updateConfig(mascotId: UUID, config: MaskoAnimationConfig) {
        guard let idx = mascots.firstIndex(where: { $0.id == mascotId }) else { return }
        mascots[idx].config = config
        persist()
    }

    func updateEdgeConditions(mascotId: UUID, edgeId: String, conditions: [MaskoAnimationCondition]?) {
        guard let idx = mascots.firstIndex(where: { $0.id == mascotId }) else { return }
        guard let edgeIdx = mascots[idx].config.edges.firstIndex(where: { $0.id == edgeId }) else { return }
        mascots[idx].config.edges[edgeIdx].conditions = conditions
        persist()
    }
}
