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
│   ├── AlarmManager.swift         # Alarm scheduling (routes to AlarmKit or notifications),
│   │                              #   audio playback, ringing state
│   ├── PulseWakeAlarmKit.swift    # AlarmKit path (iOS 26.1+): metadata, App Intent, scheduler
│   ├── MotionVisionEngine.swift   # Camera session, Vision pose detection, CoreMotion
│   ├── PushUpDetector.swift       # Push-up rep counting state machine
│   ├── PullUpDetector.swift       # Pull-up rep counting state machine
│   ├── WorkoutSensorHub.swift     # Activity, pedometer, microphone exertion monitoring
│   ├── HealthKitManager.swift     # Workout/step read+write, today's step count
│   └── SoundEngine.swift          # Alarm sound preview, success beeps
├── Views/
│   ├── RootView.swift             # App shell; presents verification when an alarm rings
│   ├── DashboardView.swift        # Main alarm list, next alarm banner, test button
│   ├── AlarmEditView.swift        # Create/edit alarms with time, exercise, reps, days, sound
│   ├── ExerciseVerificationView.swift  # Full-screen camera + skeleton overlay + HUD
│   ├── WorkoutCelebrationView.swift    # Post-completion confetti, then stops the alarm
│   ├── StatsView.swift            # Workout history and metrics
│   ├── CameraPreviewView.swift    # AVCaptureVideoPreviewLayer wrapper
│   └── PoseOverlayCanvas.swift    # SwiftUI Canvas rendering of body skeleton
├── Resources/
│   ├── Assets.xcassets/           # App icons, colors, alarm sounds (8 MP3 files)
│   ├── Version.xcconfig           # Single source of truth for marketing/build version
│   └── Info.plist                 # Permissions, bundle config
└── NudgeAlarmApp.swift            # App entry point with SwiftData container

PulseWakeTests/
├── AlarmManagerParsingTests.swift # Notification userInfo → AlarmModel round-trip
├── PushUpDetectorTests.swift      # Rep gating; guards against phantom-rep regression
└── PullUpDetectorTests.swift      # Double-count guard, stuck-state regression
```

Both detectors expose a `FrameInput` / `processFrame` seam. `processPoseObservation` converts a
Vision observation into a `FrameInput` and calls straight through, so unit tests drive the exact
code path the camera does rather than a parallel copy that can drift out of sync.

---

## Key Technical Decisions

| Component | Decision | Rationale |
|-----------|----------|-----------|
| **SwiftData** | Local persistence | Native iOS 17+, type-safe, reactive via @Query |
| **Vision Framework** | Body pose detection | On-device, no ML model bundle needed |
| **CoreMotion** | Device pitch validation | Ensures phone positioned correctly for exercise |
| **AlarmKit** (iOS 26.1+) | Primary alarm scheduling | The only way to make an alarm that survives the volume buttons and the app being closed. See below. |
| **UNUserNotificationCenter** | Fallback below iOS 26.1 | Retained for older devices; inherently silenceable |
| **AVAudioSession** | Alarm audio | `.playback` normally; `.playAndRecord` during verification so the mic exertion monitor can run alongside |
| **@Observable** | State management | Swift 5.9+, simpler than ObservableObject |

### Why AlarmKit

The product requirement is that **nothing silences an alarm except completing the reps**. Local
notifications cannot deliver that, and it is a platform limit rather than a bug: their sound is
capped at 30 s, the volume buttons silence them, and a terminated app cannot start playing audio.

So `AlarmManager.scheduleAlarm` tries AlarmKit first and only falls back to a notification if it
is unavailable or declines. The alert presentation uses the iOS 26.1 `AlarmPresentation.Alert`
initialiser that takes **no stop button** (`stopButton` is deprecated there), leaving a single
custom button that runs `StartPulseWakeVerificationIntent` and opens the app into rep
verification. `AlarmManager.stopRingingAfterCelebration()` is the **only** caller of
`stopAlerting(id:)` — if anything else calls it, the alarm becomes escapable again.

Rejected alternatives: Critical Alerts (needs an Apple entitlement, approval not guaranteed) and
a repeating notification barrage (still silenceable one at a time).

Each alarm row on the dashboard shows a badge — *System alarm* vs *Notification* — because the
fallback is otherwise silent and the difference only becomes visible when the alarm fires.

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
TOP → (descending) → GOING_DOWN → (depth reached) → BOTTOM
  ↑                                                   ↓
  └──────── (back at top) ← PUSHING_UP ←──────────────┘
     REP COUNTED, if depth + cooldown both pass
```

**Each gate reads one signal, chosen by phone placement — never both.** Placement is
auto-detected from shoulder span (`placementFrontScore`):

| Placement | Trusted signal | Why |
|---|---|---|
| `.inFrontOfFace` (phone on the floor) | Upper-body drop | Arms point at the lens, so the projected 2D elbow angle is foreshortened and noisy — it crosses thresholds while the user is motionless |
| `.sideProfile` (phone side-on) | Elbow angle | The bend is in the image plane and measures cleanly; vertical travel is small and easily confused with the user shifting position |

These gates were originally an `OR` of both signals, which let noise on the untrusted signal
drive an entire rep cycle and pass the depth check on its own. That produced phantom reps and is
the regression `PushUpDetectorTests.test_elbowNoiseWithoutBodyMovement_countsNothing` guards.

- Body drop is measured against `topBodyBaselineY`, a slowly-adapting top-of-rep baseline
- Depth required (front): `frontMinBodyDropForRep` = 0.038 of frame height
- Rep cooldown: 0.8 s. A blocked rep resets to `.top` rather than parking the state machine

### Pull-Up State Machine

```
HANGING → (elbow < 160° or shoulder > wrist-0.25) → PULLING_UP
  ↑                                                    ↓
  └──────── (elbow ≥ 160°) ← LOWERING ← CHIN_ABOVE_BAR ← (chin ≥ wrist-0.08 or elbow < 75°)
     REP COUNTED
```

- A locked-out arm is **160°** (`fullLockoutAngle`). 135° was previously used and is visibly
  bent, which let a half-finished rep close the cycle
- On full lockout, `.lowering` **always** returns to `.hanging`. `registerCompletedRep` can
  decline a rep and return without touching `currentState`; delegating the transition to it
  parked the machine in `.lowering` permanently and silently stopped all counting
- Tracks chin relative to wrists (bar height proxy)

### Device Pitch Validation
- **Push-ups**: Phone flat/propped (-65° to +65° pitch)
- **Pull-ups**: Phone upright (pitch > 25° or < -25°)

---

## Permissions Required
| Permission | Key | Purpose |
|------------|-----|---------|
| Camera | `NSCameraUsageDescription` | Pose detection via Vision |
| Microphone | `NSMicrophoneUsageDescription` | Exertion monitoring during verification |
| Motion | `NSMotionUsageDescription` | Device pitch validation, activity, steps |
| Health (read) | `NSHealthShareUsageDescription` | Step count and workout history for Stats |
| Health (write) | `NSHealthUpdateUsageDescription` | Saving completed alarm workouts |
| Alarms | `NSAlarmKitUsageDescription` | AlarmKit system alarms |
| Notifications | System prompt | Fallback alarm delivery below iOS 26.1 |

These are requested **in sequence** (`DashboardView.requestPermissionsInSequence`), each waiting
on the previous answer. Firing them together stacked the system dialogs on top of one another.

---

## Build Configuration
- **Target**: PulseWake
- **Bundle ID**: com.deepankarboro.pulsewake
- **Deployment Target**: iOS 17.0
- **Swift Version**: 5.0
- **Versioning**: `PulseWake/Version.xcconfig` is the single source of truth.
  `scripts/bump_build_number.sh` bumps the patch and build number on **Archive** only
  (it checks `ACTION=install`). The file therefore shows as modified after every archive —
  that is expected, not a stray edit.
- **Test target**: `PulseWakeTests` (26 tests). Detector tests run on the simulator with no
  camera via the `processFrame` seams.

---

## Known Limitations / Parked Items

See `HANDOFF.md` for the current live issue and test sequence. Longer-standing items:

1. **No Widget Extension target** - AlarmKit's Lock Screen / Dynamic Island presentation needs
   one. The system full-screen alert is expected to work without it, but this is unconfirmed
2. **`MotionVisionEngine` partially unsynchronised** - the shared `VNDetectHumanBodyPoseRequest`
   race is fixed (per-frame request), but `visionImageOrientation` and `processingExercise` are
   still written on main/`sessionQueue` and read on `videoQueue` without a lock
3. **Pull-up double-count** - `repCountedThisCycle` clears on the next `.hanging` frame, so
   holding at the top past the 0.4 s cooldown can count one physical rep twice
4. **Escape hatch gap** - it only triggers when *no* body is detected for ~20 s, so it does not
   catch a detector that sees you but fails to count. Combined with an unsilenceable alarm, that
   can leave the user stuck
5. **Custom sound file import** - UI exists for preset selection; no custom file import UI
6. **HealthKit background delivery** - removed; needs an entitlement the app does not carry
7. **No haptic feedback** - Could add on rep completion
8. **No cloud sync** - Local-only SwiftData storage
9. **No watchOS companion** - Could extend for remote dismiss

---

## Testing Checklist

Alarm reliability first — it is the product; rep counting is a detail on top of it.

- [ ] Dashboard badge reads **System alarm**, not Notification
- [ ] Alarm fires at scheduled time (foreground / background / force-quit)
- [ ] Alert is full-screen with **no Stop button**
- [ ] Volume buttons do not silence it
- [ ] Force-quitting the app does not silence it
- [ ] Completing the reps *does* silence it
- [ ] Push-up detection counts reps accurately (currently under-counting)
- [ ] Push-up detection rejects arm movement with no body drop
- [ ] Pull-up detection counts reps accurately
- [ ] Device pitch validation works for both exercises
- [ ] Permission prompts appear one at a time on first launch
- [ ] Camera permission flow (grant / deny / settings)
- [ ] Alarm sound plays and loops (all 8 sounds)
- [ ] SwiftData persistence across app launches
- [ ] Toggling an alarm off does not freeze the app
- [ ] Delete alarm cancels the scheduled alarm
- [ ] Edit alarm updates the scheduled alarm
- [ ] Stats view shows history correctly