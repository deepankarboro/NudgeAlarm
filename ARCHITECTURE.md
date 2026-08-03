# PulseWake - Project Documentation

## Overview
PulseWake is a motion-verified alarm app that requires users to complete physical exercises (push-ups or pull-ups) to dismiss alarms. Built with Swift/SwiftUI, SwiftData, Vision Framework, and CoreMotion.

---

## Architecture

```
PulseWake/
├── Models/
│   ├── AlarmModel.swift           # SwiftData model for scheduled alarms
│   └── WorkoutHistoryModel.swift  # SwiftData model for completed workout logs
├── Services/
│   ├── AlarmManager.swift         # Notification scheduling, audio playback, ringing state
│   ├── MotionVisionEngine.swift   # Camera session, Vision pose detection, CoreMotion
│   ├── PushUpDetector.swift       # Push-up rep counting state machine
│   ├── PullUpDetector.swift       # Pull-up rep counting state machine
│   └── SoundEngine.swift          # Speech synthesis for rep counting, success beeps
├── Views/
│   ├── DashboardView.swift        # Main alarm list, next alarm banner, test button
│   ├── AlarmEditView.swift        # Create/edit alarms with time, exercise, reps, days, sound
│   ├── ExerciseVerificationView.swift  # Full-screen camera + skeleton overlay + HUD
│   ├── StatsView.swift            # Workout history and metrics
│   ├── CameraPreviewView.swift    # AVCaptureVideoPreviewLayer wrapper
│   └── PoseOverlayCanvas.swift    # SwiftUI Canvas rendering of body skeleton
├── Resources/
│   ├── Assets.xcassets/           # App icons, colors, alarm sounds (8 MP3 files)
│   └── Info.plist                 # Permissions, bundle config
└── PulseWakeApp.swift             # App entry point with SwiftData container
```

---

## Key Technical Decisions

| Component | Decision | Rationale |
|-----------|----------|-----------|
| **SwiftData** | Local persistence | Native iOS 17+, type-safe, reactive via @Query |
| **Vision Framework** | Body pose detection | On-device, no ML model bundle needed |
| **CoreMotion** | Device pitch validation | Ensures phone positioned correctly for exercise |
| **UNUserNotificationCenter** | Alarm scheduling | Background delivery, critical alerts support |
| **AVAudioSession** | Alarm audio | Category `.playback` with `.duckOthers` |
| **@Observable** | State management | Swift 5.9+, simpler than ObservableObject |

---

## Data Models

### AlarmModel
```swift
- id: UUID
- time: Date (hour/minute only)
- label: String
- exerciseType: ExerciseType (.pushUp, .pullUp)
- targetReps: Int (3-50)
- isEnabled: Bool
- repeatDays: Set<Int> (1=Sun...7=Sat, stored as CSV string)
- soundName: String (picker: "Beep", "Carjack", "Chiptune", "Clock Alarm", "Digital Alarm", "Mellow", "Oversimplified", "Star Dust")
- createdAt: Date
```

### WorkoutHistoryModel
```swift
- id: UUID
- timestamp: Date
- alarmLabel: String
- exerciseType: ExerciseType
- completedReps: Int
- durationSeconds: Double
```

---

## Alarm Sounds

The app includes 8 built-in alarm sounds bundled in the app:

| Sound | Description |
|-------|-------------|
| **Beep** | Short electronic beep |
| **Carjack** | Intense car alarm style |
| **Chiptune** | 8-bit game style melody |
| **Clock Alarm** | Traditional alarm clock |
| **Digital Alarm** | Modern digital alarm tone |
| **Mellow** | Gentle, calm wake-up |
| **Oversimplified** | Minimalist tone |
| **Star Dust** | Ethereal ambient tone |

Sounds are stored as MP3 files in `PulseWake/Alarm Sounds/` and added to the Xcode project Resources build phase.

The alarm sound is selected per-alarm in `AlarmEditView` and saved to `AlarmModel.soundName`. `AlarmManager` plays the selected sound when the alarm fires.

---

## Exercise Detection Logic

### Push-Up State Machine
```
TOP → (elbow < 145°) → GOING_DOWN → (elbow ≤ 95°) → BOTTOM 
  ↑                                                    ↓
  └──────────────── (elbow ≥ 155°) ← PUSHING_UP ←──────┘
       REP COUNTED
```
- Uses single arm with highest average confidence (shoulder+elbow+wrist)
- Confidence threshold: 0.15 (average of 3 joints)

### Pull-Up State Machine
```
HANGING → (elbow < 135° or shoulder > wrist-0.25) → PULLING_UP
  ↑                                                    ↓
  └──────────── (elbow ≥ 140°) ← LOWERING ← CHIN_ABOVE_BAR ← (chin ≥ wrist-0.08 or elbow < 75°)
       REP COUNTED
```
- Tracks chin relative to wrists (bar height proxy)
- Validates both elbow angle and vertical displacement

### Device Pitch Validation
- **Push-ups**: Phone flat/propped (-65° to +65° pitch)
- **Pull-ups**: Phone upright (pitch > 25° or < -25°)

---

## Permissions Required
| Permission | Key | Purpose |
|------------|-----|---------|
| Camera | `NSCameraUsageDescription` | Pose detection via Vision |
| Microphone | `NSMicrophoneUsageDescription` | Audio session for alarm playback |
| Motion | `NSMotionUsageDescription` | Device pitch validation |
| Notifications | System prompt | Alarm delivery (critical alerts) |

---

## Build Configuration
- **Target**: PulseWake
- **Bundle ID**: com.deepankarboro.pulsewake
- **Deployment Target**: iOS 17.0
- **Swift Version**: 5.0
- **Auto-build version**: Timestamp-based (YYYYMMDDHHMM) via build script

---

## Known Limitations / Parked Items

1. **Background audio** - Only `audio` background mode enabled; no background task handler for long-running alarms
2. **Custom sound file import** - UI exists for preset selection; no custom file import UI
3. **Critical alerts entitlement** - Requires Apple approval for production
4. **Pull-up detection accuracy** - Depends on camera angle relative to bar; needs real-device tuning
5. **No haptic feedback** - Could add on rep completion
6. **No cloud sync** - Local-only SwiftData storage
7. **No watchOS companion** - Could extend for remote dismiss

---

## Testing Checklist
- [ ] Alarm fires at scheduled time (foreground/background/killed)
- [ ] Push-up detection counts reps accurately
- [ ] Pull-up detection counts reps accurately
- [ ] Device pitch validation works for both exercises
- [ ] Camera permission flow (grant/deny/settings)
- [ ] Notification permission flow
- [ ] Alarm sound plays and loops (all 8 sounds)
- [ ] Speech announcements work
- [ ] SwiftData persistence across app launches
- [ ] Delete alarm cancels notifications
- [ ] Edit alarm updates notifications
- [ ] Stats view shows history correctly