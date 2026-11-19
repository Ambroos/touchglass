import Foundation
import Testing
import TouchGlassCore
@testable import TouchGlassPanel

@Suite struct SoundsTests {
    /// A throwaway defaults domain, so the tests never read or write the app's own.
    private func defaults(_ values: [String: Bool]) -> UserDefaults {
        let name = "touchglass-sounds-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    private let cues: [SoundCue] = [.touchStart, .reminder, .failure, .rejected]

    @Test func silentByDefault() {
        let defaults = defaults([:])
        for cue in cues { #expect(!Sounds.plays(cue, defaults: defaults)) }
    }

    @Test func reminderSettingAloneDoesNotTurnSoundsOn() {
        let defaults = defaults(["reminderSoundsEnabled": true])
        for cue in cues { #expect(!Sounds.plays(cue, defaults: defaults)) }
    }

    @Test func enabledPlaysEveryCueIncludingReminders() {
        let defaults = defaults(["soundsEnabled": true])
        for cue in cues { #expect(Sounds.plays(cue, defaults: defaults)) }
    }

    @Test func enabledWithoutRemindersSkipsOnlyReminders() {
        let defaults = defaults(["soundsEnabled": true, "reminderSoundsEnabled": false])
        #expect(Sounds.plays(.touchStart, defaults: defaults))
        #expect(!Sounds.plays(.reminder, defaults: defaults))
        #expect(Sounds.plays(.failure, defaults: defaults))
        #expect(Sounds.plays(.rejected, defaults: defaults))
    }
}
