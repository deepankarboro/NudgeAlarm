import Foundation
import AVFoundation

public final class SoundEngine {
    public static let shared = SoundEngine()
    private var previewPlayer: AVAudioPlayer?

    private init() {}

    /// Plays the selected alarm MP3 once so the user can hear it in the alarm editor.
    public func previewAlarmSound(named soundName: String) {
        stopAlarmSoundPreview()
        guard let url = Bundle.main.url(forResource: soundName, withExtension: "mp3") else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            previewPlayer = try AVAudioPlayer(contentsOf: url)
            previewPlayer?.numberOfLoops = 0
            previewPlayer?.volume = 1.0
            previewPlayer?.prepareToPlay()
            previewPlayer?.play()
        } catch {
            print("Alarm sound preview failed: \(error)")
        }
    }

    public func stopAlarmSoundPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }
    
    public func playSuccessBeep() {
        AudioServicesPlaySystemSound(1054)
    }
}
