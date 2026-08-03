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
    /// Bumped when an alarm fires so SwiftUI always re-presents verification UI.
    public var verificationPresentationToken: UUID = UUID()
    
    private var audioPlayer: AVAudioPlayer?
    private var speechSynthesizer = AVSpeechSynthesizer()
    
    // Available alarm sounds (must match files in bundle)
    public static let availableSounds = [
        "Beep",
        "Carjack",
        "Chiptune",
        "Clock Alarm",
        "Digital Alarm",
        "Mellow",
        "Oversimplified",
        "Star Dust"
    ]
    
    public override init() {
        super.init()
        setupNotifications()
        registerNotificationCategories()
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

    private func registerNotificationCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_VERIFICATION",
            title: "Start exercise now",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: "ALARM_CATEGORY",
            actions: [openAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    public func scheduleAlarm(_ alarm: AlarmModel) {
        guard alarm.isEnabled else {
            cancelAlarm(alarm)
            return
        }
        
        let center = UNUserNotificationCenter.current()
        cancelAlarm(alarm)
        
        let content = UNMutableNotificationContent()
        content.title = "⚡️ PULSEWAKE: \(alarm.label)"
        content.body = "Tap to open camera — complete \(alarm.targetReps) \(alarm.exerciseType.rawValue) to turn off the alarm."
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        if let notifSound = bundledNotificationSound(named: alarm.soundName) {
            content.sound = notifSound
        } else {
            content.sound = .default
        }
        content.categoryIdentifier = "ALARM_CATEGORY"
        content.userInfo = [
            "alarmId": alarm.id.uuidString,
            "exerciseType": alarm.exerciseTypeRaw,
            "targetReps": alarm.targetReps,
            "soundName": alarm.soundName
        ]
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: alarm.time)
        
        if alarm.repeatDays.isEmpty {
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: alarm.id.uuidString, content: content, trigger: trigger)
            center.add(request)
        } else {
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
    /// Atomically mutates observable presentation state on the caller's thread BEFORE any async
    /// side-effects start, so RootView's `fullScreenCover` never observes `isRinging == true`
    /// with `activeRingingAlarm == nil` (which would render an empty cover body and crash).
    /// All three presentation properties land in the same main-thread run-loop tick.
    public func startRinging(alarm: AlarmModel) {
        let isMain = Thread.isMainThread
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.activeRingingAlarm = alarm
            self.isRinging = true
            self.verificationPresentationToken = UUID()
            self.playLoudAlarmSound(alarm: alarm)
            self.speakInstruction("Wake up! Complete \(alarm.targetReps) \(alarm.exerciseType.rawValue) to turn off alarm!")
            WorkoutSensorHub.shared.startWakeSession()
        }
        if isMain {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    public func stopRinging() {
        DispatchQueue.main.async {
            self.isRinging = false
            self.activeRingingAlarm = nil
            self.audioPlayer?.stop()
            WorkoutSensorHub.shared.stopWakeSession()
        }
    }

    /// Stops alarm audio without extra speech (used after celebration).
    public func stopRingingAfterCelebration() {
        DispatchQueue.main.async {
            self.isRinging = false
            self.activeRingingAlarm = nil
            self.audioPlayer?.stop()
            self.speechSynthesizer.stopSpeaking(at: .immediate)
            WorkoutSensorHub.shared.stopWakeSession()
        }
    }

    /// Allows alarm audio and camera capture to run together during exercise verification.
    public func configureAudioSessionForExerciseVerification() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .duckOthers, .allowBluetooth]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio for exercise verification: \(error)")
        }
    }

    public func restoreAudioSessionAfterExerciseVerification() {
        guard isRinging else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to restore alarm audio session: \(error)")
        }
    }

    /// Keeps alarm audio looping until reps are finished (test flow + if user leaves the app).
    public func ensureVerificationAlarmActive(
        exerciseType: ExerciseType,
        targetReps: Int,
        label: String,
        soundName: String = "Beep"
    ) {
        guard !isRinging else { return }
        let alarm = AlarmModel(
            label: label,
            exerciseType: exerciseType,
            targetReps: targetReps,
            isEnabled: true,
            repeatDays: [],
            soundName: soundName
        )
        startRinging(alarm: alarm)
    }

    public func resumeAlarmPlaybackIfNeeded() {
        guard isRinging, let alarm = activeRingingAlarm else { return }
        if audioPlayer?.isPlaying != true {
            playLoudAlarmSound(alarm: alarm)
        }
    }

    public func silenceAlarmAudioForCelebration() {
        audioPlayer?.stop()
        speechSynthesizer.stopSpeaking(at: .immediate)
    }
    
    private func playLoudAlarmSound(alarm: AlarmModel) {
        do {
            // Endpoint E / C: do NOT unconditionally flip the audio session category to
            // `.playback`. When the exercise verification flow has already configured
            // `.playAndRecord` (for the microphone exertion monitor in WorkoutSensorHub),
            // flipping back to `.playback` invalidates the mic tap's underlying format and
            // breaks AVAudioEngine.start(). Keep whatever category is currently active.
            let session = AVAudioSession.sharedInstance()
            let currentCategory = session.category
            if currentCategory != .playAndRecord {
                // Fresh alarm ring (no verification yet): use .playback for maximum loudness.
                try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            }
            try session.setActive(true)

            let soundName = alarm.soundName
            guard let soundURL = Bundle.main.url(forResource: soundName, withExtension: "mp3") else {
                AudioServicesPlaySystemSound(1005)
                return
            }

            audioPlayer = try AVAudioPlayer(contentsOf: soundURL)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
        } catch {
            print("Failed to play alarm audio: \(error)")
        }
    }

    private func bundledNotificationSound(named soundName: String) -> UNNotificationSound? {
        guard Bundle.main.url(forResource: soundName, withExtension: "mp3") != nil else {
            return nil
        }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: "\(soundName).mp3"))
    }

    private func handleAlarmNotification(_ content: UNNotificationContent) {
        guard let alarm = alarmFromNotificationContent(content) else { return }
        startRinging(alarm: alarm)
    }
    
    public func speakInstruction(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        speechSynthesizer.speak(utterance)
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    /// Internal-only test seam. Public so the test bundle can verify int/NSNumber tolerance
    /// and the `userInfo` schema round-trip. Not part of the app's public API contract.
    internal func intFromUserInfo(_ userInfo: [AnyHashable: Any], key: String) -> Int? {
        if let value = userInfo[key] as? Int { return value }
        if let number = userInfo[key] as? NSNumber { return number.intValue }
        return nil
    }

    /// Internal-only test seam. Reconstructs an `AlarmModel` from a notification payload
    /// WITHOUT inserting into SwiftData. Returns nil if any required key is missing or
    /// malformed. The returned alarm is purely ephemeral and MUST NOT be passed to
    /// `modelContext.insert` - it is only used to drive the in-memory ringing state.
    internal func alarmFromNotificationContent(_ content: UNNotificationContent) -> AlarmModel? {
        let userInfo = content.userInfo
        guard let alarmIdString = userInfo["alarmId"] as? String,
              let uuid = UUID(uuidString: alarmIdString),
              let exerciseTypeRaw = userInfo["exerciseType"] as? String,
              let targetReps = intFromUserInfo(userInfo, key: "targetReps"),
              let soundName = userInfo["soundName"] as? String else {
            return nil
        }
        let exerciseType = ExerciseType(rawValue: exerciseTypeRaw) ?? .pushUp
        return AlarmModel(
            id: uuid,
            time: Date(),
            label: content.title.replacingOccurrences(of: "⚡️ PULSEWAKE: ", with: ""),
            exerciseType: exerciseType,
            targetReps: targetReps,
            isEnabled: true,
            repeatDays: [],
            soundName: soundName,
            createdAt: Date()
        )
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handleAlarmNotification(notification.request.content)
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        handleAlarmNotification(response.notification.request.content)
        completionHandler()
    }
}