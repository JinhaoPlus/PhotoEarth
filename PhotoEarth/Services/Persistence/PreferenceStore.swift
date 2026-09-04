import Foundation

nonisolated struct SyncedPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var onboardingCompleted = false
    var autoplayEnabled = true
    var lastSelectedPlaceID: String?
    var hiddenJourneyIDs: [String] = []
    var favoriteJourneyIDs: [String] = []
}

nonisolated protocol PreferenceSyncing: Sendable {
    func load() async -> SyncedPreferences
    func save(_ preferences: SyncedPreferences) async
}

actor ICloudPreferenceStore: PreferenceSyncing {
    private let key = "photoEarth.preferences.v1"

    func load() async -> SyncedPreferences {
        guard
            let data = NSUbiquitousKeyValueStore.default.data(forKey: key),
            let preferences = try? JSONDecoder().decode(SyncedPreferences.self, from: data),
            preferences.schemaVersion == SyncedPreferences.currentSchemaVersion
        else {
            return SyncedPreferences()
        }
        return preferences
    }

    func save(_ preferences: SyncedPreferences) async {
        guard let data = try? JSONEncoder().encode(preferences), data.count < 64 * 1_024 else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
    }
}

actor LocalPreferenceStore: PreferenceSyncing {
    private let key = "photoEarth.preferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() async -> SyncedPreferences {
        guard
            let data = defaults.data(forKey: key),
            let preferences = try? JSONDecoder().decode(SyncedPreferences.self, from: data),
            preferences.schemaVersion == SyncedPreferences.currentSchemaVersion
        else {
            return SyncedPreferences()
        }
        return preferences
    }

    func save(_ preferences: SyncedPreferences) async {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

actor MemoryPreferenceStore: PreferenceSyncing {
    private var value = SyncedPreferences()

    func load() async -> SyncedPreferences { value }
    func save(_ preferences: SyncedPreferences) async { value = preferences }
}
