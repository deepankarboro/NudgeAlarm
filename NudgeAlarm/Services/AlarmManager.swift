import Foundation
import UserNotifications
import AVFoundation
import SwiftUI

@Observable
public final class AlarmManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = AlarmManager()
    
    public var isRinging: Bool = false
    public var activeRingingAlarm: AlarmModel?
    public var isPermissionGranted: Bool = false
    
    private var audioPlayer: AVAudioPlayer?
    private var speechSynthesizer = AVSpeechSynthesizer()
    
    public override init() {
        super.init()
        setupNotifications()
    }
    
    public func requestPermissions(completion: @escaping (Bool) -> Void = { _ in }) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { granted, error in
            DispatchQueue.main.async {
                self.isPermissionGranted = granted
                completion(granted)
            }
        }
    }
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().delegate = self
    }
    
    public func scheduleAlarm(_ alarm: AlarmModel) {
        guard alarm.isEnabled else {
            cancelAlarm(alarm)
            return
        }
        
        let center = UNUserNotificationCenter.current()
        cancelAlarm(alarm) // Remove existing triggers
        
        let content = UNMutableNotificationContent()
        content.title = "⚡️ PULSE WAKE: \(alarm.label)"
        content.body = "Time for \(alarm.targetReps) \(alarm.exerciseType.rawValue)! Complete exercise to turn off sound."
        content.sound = UNNotificationSound.defaultRingtone
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = [
            "alarmId": alarm.id.uuidString,
            "exerciseType": alarm.exerciseTypeRaw,
            "targetReps": alarm.targetReps
        ]
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        
        if alarm.repeatDays.isEmpty {
            // One-time alarm trigger
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: alarm.id.uuidString, content: content, trigger: trigger)
            center.add(request)
        } else {
            // Weekly repeating days
            for day in alarm.repeatDays {
                var dayComponents = components
                dayComponents.weekday = day
                let trigger = UNCalendarNotificationTrigger(dateMatching: dayComponents, repeats: true)
                let reqId = "\(alarm.id.uuidString)_\(day)"
                let request = UNNotificationRequest(identifier: reqId, content: content, trigger: trigger)
                center.add(request)
            }
        }
    }
    
    public func cancelAlarm(_ alarm: AlarmModel) {
        let center = UNUserNotificationCenter.current()
        var identifiers = [alarm.id.uuidString]
        for day in 1...7 {
            identifiers.append("\(alarm.id.uuidString)_\(day)")
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
    // MARK: - Alarm Ringing & Audio Session
    public func startRinging(alarm: AlarmModel) {
        self.activeRingingAlarm = alarm
        self.isRinging = true
        
        playLoudAlarmSound()
        speakInstruction("Wake up! Complete \(alarm.targetReps) \(alarm.exerciseType.rawValue) to turn off alarm!")
    }
    
    public func stopRinging() {
        self.isRinging = false
        self.activeRingingAlarm = nil
        audioPlayer?.stop()
        speakInstruction("Alarm dismissed! Great job waking up!")
    }
    
    private func playLoudAlarmSound() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            
            // System loud alarm tone generator fallback
            guard let soundURL = Bundle.main.url(forResource: "alarm_tone", withExtension: "mp3") else {
                // Synthesize loud repeating alert beep
                AudioServicesPlayAlertSound(1005)
                return
            }
            
            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.numberOfLoops = -1 // Infinite loop until exercise finished
            audioPlayer?.volume = 1.0
            audioPlayer?.play()
        } catch {
            print("Failed to play alarm audio: \(error)")
        }
    }
    
    public func speakInstruction(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        speechSynthesizer.speak(utterance)
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Trigger ringing overlay when notification fires while app is in foreground
        let userInfo = notification.request.content.userInfo
        if let alarmIdString = userInfo["alarmId"] as? String, let uuid = UUID(uuidString: alarmIdString) {
            let mockAlarm = AlarmModel(id: uuid, time: Date(), label: notification.request.content.title)
            startRinging(alarm: mockAlarm)
        }
        completionHandler([.banner, .sound, .list])
    }
    
    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let alarmIdString = userInfo["alarmId"] as? String, let uuid = UUID(uuidString: alarmIdString) {
            let mockAlarm = AlarmModel(id: uuid, time: Date(), label: response.notification.request.content.title)
            startRinging(alarm: mockAlarm)
        }
        completionHandler()
    }
}
