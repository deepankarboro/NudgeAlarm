import Foundation
import AVFoundation

public final class SoundEngine {
    public static let shared = SoundEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    private init() {}
    
    public func speakRepCount(_ count: Int, target: Int) {
        let text: String
        let remaining = target - count
        if remaining == 0 {
            text = "Final rep complete! Alarm turned off!"
        } else if remaining == 1 {
            text = "\(count)! One more rep to go!"
        } else {
            text = "\(count)!"
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.54
        utterance.pitchMultiplier = 1.1
        speechSynthesizer.speak(utterance)
    }
    
    public func playSuccessBeep() {
        AudioServicesPlaySystemSound(1054)
    }
}
