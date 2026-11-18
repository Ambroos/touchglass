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

    /// `soundsEnabled` and `reminderSoundsEnabled` in user defaults; both default to on.
    private func enabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    func play(_ cue: SoundCue) {
        guard enabled("soundsEnabled") else { return }
        switch cue {
        case .touchStart: play("Tink")
        case .reminder:
            if enabled("reminderSoundsEnabled") { play("Ping") }
        case .failure: play("Basso")
        case .rejected: NSSound.beep()
        }
    }

    private func play(_ name: String) {
        guard let id = ids[name] else { return }
        AudioServicesPlayAlertSound(id)
    }
}
