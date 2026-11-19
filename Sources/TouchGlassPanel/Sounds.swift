import AppKit
import AudioToolbox
import TouchGlassCore

/// Plays the panel's alert sounds through the system alert sound path, so they follow the
/// alert volume, the sound-effects output device and the flash-the-screen setting.
@MainActor
final class Sounds {
    private var ids: [String: SystemSoundID] = [:]

    init() {
        for name in ["Tink", "Ping", "Basso"] {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError {
                ids[name] = id
            }
        }
    }

    func play(_ cue: SoundCue) {
        guard Self.plays(cue, defaults: .standard) else { return }
        switch cue {
        case .touchStart: play("Tink")
        case .reminder: play("Ping")
        case .failure: play("Basso")
        case .rejected: NSSound.beep()
        }
    }

    /// Whether `cue` plays under the user defaults `soundsEnabled`, which defaults to off, and
    /// `reminderSoundsEnabled`, which defaults to on and only matters while sounds are on. Read on
    /// every cue, so a change applies without a restart.
    nonisolated static func plays(_ cue: SoundCue, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: "soundsEnabled") as? Bool ?? false else { return false }
        if cue == .reminder {
            return defaults.object(forKey: "reminderSoundsEnabled") as? Bool ?? true
        }
        return true
    }

    private func play(_ name: String) {
        guard let id = ids[name] else { return }
        AudioServicesPlayAlertSound(id)
    }
}
