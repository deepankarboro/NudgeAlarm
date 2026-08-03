# PulseWake - Development Chat Log & Decisions

## Session Summary
**Date**: July 22, 2026  
**Project**: NudgeAlarm → PulseWake (renamed)  
**Session Type**: Code review, bug fixes, project restructuring

---

## Initial State Analysis

User had an Xcode project with:
- **Project name**: "PulseWake" (in xcodeproj, Info.plist)
- **Source folder**: "NudgeAlarm/" (inconsistent)
- **App struct**: `NudgeAlarmApp`
- **Package.swift**: Existed but with incorrect paths
- **Multiple bugs** identified during review

---

## Issues Found & Fixed

### 1. Naming Inconsistency (CRITICAL)
**Problem**: Project called "PulseWake" everywhere except source folder "NudgeAlarm" and app entry point "NudgeAlarmApp"
**Fix**: 
- Renamed source folder: `NudgeAlarm/` → `PulseWake/`
- Renamed app struct: `NudgeAlarmApp` → `PulseWakeApp`
- Updated all UI text: "NudgeAlarm" → "PulseWake", "Nudge" → "PulseWake"
- Updated xcodeproj paths and build script

### 2. AlarmManager Mock Alarm Crash (CRITICAL)
**Problem**: `userNotificationCenter(_:willPresent:)` and `didReceive(_:)` created `AlarmModel` with only `id`, `time`, `label` - missing required properties (`exerciseType`, `targetReps`, `repeatDaysRaw`, `soundName`, `createdAt`)
**Fix**: Full mock alarm initialization with all properties extracted from notification `userInfo`

### 3. PushUpDetector Confidence Threshold (HIGH)
**Problem**: Multiplied 3 confidence values (0-1 each) → ~0.01-0.1, but threshold was 0.3 - nearly impossible to pass
**Fix**: Changed to average of 3 joints, threshold 0.15

### 4. MotionVisionEngine Camera Selection (MEDIUM)
**Problem**: Always used front camera; pull-ups need back camera to see bar
**Fix**: Dynamic camera selection based on exercise type

### 5. Info.plist Issues (MEDIUM)
**Problems**:
- Missing `NSMicrophoneUsageDescription`
- Conflicting `UILaunchStoryboardName` + `UILaunchScreen` dict
- Unused background modes (`fetch`, `remote-notification`)
- Hardcoded `CFBundleVersion` overwritten by build script
**Fixes**: Added microphone usage, removed launch storyboard key, cleaned background modes, synced version with build script

### 6. ExerciseVerificationView Double Dismiss (HIGH)
**Problem**: `completeExercise()` called `onComplete()` then `dismiss()`, but parent `DashboardView` also dismissed on `onComplete`
**Fix**: Added `hasCompleted` guard to prevent duplicate execution

### 7. Package.swift Issues (MEDIUM)
**Problem**: Package.swift inside source folder with wrong relative paths
**Fix**: Removed entirely (Xcode project doesn't need SPM)

### 8. Sound Selection Infrastructure (FEATURE)
**Added**: Sound picker in `AlarmEditView` with 6 system sound options, wired to `AlarmModel.soundName`

### 9. Build System Consistency (LOW)
**Fixed**: 
- Build script now looks in `PulseWake/Info.plist`
- `CURRENT_PROJECT_VERSION` in xcodeproj matches timestamp format
- Removed LaunchScreen.storyboard from Resources (using Info.plist launch screen)

### 10. Alarm Sound Files Integration (FEATURE) - Latest Session
**Problem**: User had 8 MP3 alarm sound files in `PulseWake/Alarm Sounds/` folder but they weren't integrated into the Xcode project
**Fix**:
- Added all 8 sound files to Xcode project (PBXFileReference, PBXBuildFile, PBXGroup)
- Added "Alarm Sounds" group in project navigator
- Added files to Resources build phase
- Updated `AlarmManager` to use `alarm.soundName` when playing alarm audio
- Updated `AlarmEditView` to show actual sound file names in picker
- Added `AlarmManager.availableSounds` static array for shared access
- Notification payload now includes `soundName` for proper alarm restoration

**Sound Files Added**:
- Beep.mp3
- Carjack.mp3
- Chiptune.mp3
- Clock Alarm.mp3
- Digital Alarm.mp3
- Mellow.mp3
- Oversimplified.mp3
- Star Dust.mp3

---

## Files Modified

| File | Changes |
|------|---------|
| `PulseWakeApp.swift` | Renamed struct, updated module references |
| `Models/AlarmModel.swift` | UI text updates ("PulseWake") |
| `Models/WorkoutHistoryModel.swift` | No logic changes |
| `Services/AlarmManager.swift` | Fixed mock alarms, sound fallback, notification title, **soundName playback** |
| `Services/MotionVisionEngine.swift` | Dynamic camera selection |
| `Services/PushUpDetector.swift` | Fixed confidence calculation |
| `Services/PullUpDetector.swift` | No logic changes |
| `Services/SoundEngine.swift` | No changes |
| `Views/DashboardView.swift` | Branding updates |
| `Views/AlarmEditView.swift` | Added sound picker, **actual sound files**, branding |
| `Views/ExerciseVerificationView.swift` | Double-dismiss fix, branding |
| `Views/StatsView.swift` | Branding updates |
| `Views/CameraPreviewView.swift` | No changes |
| `Views/PoseOverlayCanvas.swift` | No changes |
| `Info.plist` | Permissions, launch screen, background modes |
| `PulseWake.xcodeproj/project.pbxproj` | Paths, build script, version, **alarm sound files** |
| `scripts/bump_build_number.sh` | Path updates |

---

## Build Verification
```
xcodebuild -project PulseWake.xcodeproj -scheme PulseWake -destination "platform=iOS Simulator,name=iPhone 17" build
** BUILD SUCCEEDED **
```

---

## Remaining Work (User to Provide)

1. **Custom alarm sound**: Add `alarm_tone.mp3` to `Assets.xcassets` (fallback if selected sound fails)
2. **Critical Alerts entitlement**: Apply for Apple approval for production
3. **Real-device testing**: Pull-up detection needs tuning with actual bar setup
4. **App icons**: Replace placeholder in `Assets.xcassets/AppIcon.appiconset/`

---

## Decisions Deferred

| Item | Reason |
|------|--------|
| Background task handler for alarms | Requires more design; current critical alerts work in foreground |
| Custom sound file import UI | Low priority; preset picker works for MVP |
| WatchOS companion | Separate effort |
| CloudKit sync | Post-MVP |
| Haptic feedback on reps | Nice-to-have |

---

## Testing Notes

- Simulator builds successfully
- Camera/Vision requires real device (simulator has no camera)
- CoreMotion requires real device
- Notifications require real device + permissions
- Critical alerts require special entitlement

---

## Next Steps (Suggested)

1. Add `alarm_tone.mp3` to Assets.xcassets (fallback)
2. Test on physical device with both exercises
3. Tune pull-up detector thresholds if needed
4. Apply for Critical Alerts entitlement
5. Generate proper app icons
6. Test App Store build flow