# PulseWake — Handoff / Resume Point

**Last updated:** 6 August 2026
**Branch:** `main` (only branch — the old `cursor/…` branch was merged and deleted)
**Latest commit:** `dc06cc2` — Per-alarm badge showing which mechanism scheduled it
**Build state:** compiles and archives cleanly. Last archive: 1.0.5 (6).
**Testing:** via TestFlight. Developer Mode is **not** enabled on the iPhone, so changes must be
committed and archived — they cannot be run straight from Xcode.

---

## Test order

Deepankar's sequence: get the **alarm** trustworthy first, then tune rep counting. The alarm is
the product; counting is a detail on top of it.

**Set the target to 1 rep while testing the alarm itself** — the alarm is deliberately
unsilenceable and rep counting currently under-counts, so a 5-rep target risks getting stuck with
a sounding alarm.

1. **Did AlarmKit take the alarm?** The dashboard badge now answers this directly: green
   *System alarm* = AlarmKit, orange *Notification* = silent fallback, grey = not scheduled. If
   it reads Notification, AlarmKit authorization or scheduling failed and nothing below is
   meaningful. (Independent check: Settings → PulseWake should list an **Alarms** toggle.)
2. **Does the alert appear when it fires?** AlarmKit's presentation is full-screen, titled
   `PULSEWAKE — <label>`, with a single `Do N Push-Ups` button and **no Stop button**. The
   notification fallback is a banner titled `⚡️ PULSEWAKE: <label>` with a *Start exercise now*
   action. If the badge says System alarm but no full-screen alert appears, that points at the
   missing Widget Extension target.
3. **Volume buttons** — does it keep sounding?
4. **Force-quit the app** — does it keep sounding?

Only once those pass is the rep-counting work below worth doing.

---

## Then: rep counting

**Push-ups under-count: 4 real reps registered 1.** This is the one live issue.

Build and upload `6bc9515` (archiving bumps to 1.0.6 (7)), do 4–5 push-ups at normal pace, and
read the yellow telemetry HUD on the exercise screen:

```
cycles 4  ·  counted 1  ·  peak 62%
last: too shallow (62%)
live drop 0.0231  ·  need 0.038  ·  base 0.612
```

### How to interpret it

Rep counting can fail three ways that look identical from the outside. This tells them apart:

| Reading | Meaning | Fix |
|---|---|---|
| `cycles` tracks your reps, `counted` lags, `last: too shallow (X%)` | Motion is seen; the depth gate rejects it | Lower `frontMinBodyDropForRep` — X% says by how much |
| `cycles` tracks, `last: too soon (X.XXs)` | The 0.8 s cooldown is eating reps | Lower `minSecondsBetweenReps` to just under X |
| `cycles` **also** lags (1–2 when you did 4) | State machine isn't completing cycles — the gating change went too far | Reconsider body-drop as the sole front-placement signal |
| `base` drifts down across reps while your top position doesn't | `topBodyBaselineY` is tracking you between reps, shrinking each rep's measured drop | Restrict baseline updates to settled `.top` frames |

The numbers to report back: **`peak` on the reps that did NOT count**, and **whether `cycles` kept
pace with reality**.

### Two cautions while testing

- The alarm is deliberately hard to silence. Under-counting plus an unsilenceable alarm means you
  can get stuck with it sounding — test where the noise is tolerable.
- The escape hatch only appears after ~20 s with **no body detected at all**, so it does *not*
  catch this failure (the camera sees you fine). Worth adding a "cycles detected but nothing
  counting for N seconds" trigger.

---

## Done this session (all on `main`)

- **Push-up over-counting fixed.** Every rep gate was an `OR` of body-drop and elbow-angle, so
  noise on either alone completed a cycle. With the phone in front the arms are foreshortened and
  the projected elbow angle is unreliable → phantom reps. Each placement now gates on the signal
  its camera geometry makes trustworthy. Cooldown 0.45 s → 0.8 s. *(This is what over-corrected
  into the current under-counting.)*
- **Pull-up stuck detector fixed.** A locked-out arm is now 160° (was 135°, which is visibly
  bent). `.lowering` now always returns to `.hanging` on full lockout — `registerCompletedRep`
  can decline a rep and return without touching `currentState`, which parked the machine
  permanently and silently stopped all counting.
- **Alarm toggle froze the app.** `AlarmRowView` wrote `isEnabled` twice per tap (Toggle binding +
  `toggleAction`) and `.onChange` fed the second write back in, spinning forever. The side effect
  now lives in the binding's setter.
- **AlarmKit.** Alarms schedule through AlarmKit on iOS 26.1+, notifications below. The alert uses
  the iOS 26.1 initialiser that takes **no stop button**, so its only affordance opens the app
  into verification. `stopRingingAfterCelebration()` is the sole caller of `stopAlerting(id:)`.
- **Text-to-speech removed** (both `AVSpeechSynthesizer`s). Alarm sound and rep beep kept.
- **Cleanup:** per-frame `VNDetectHumanBodyPoseRequest` (was one shared request raced across
  threads); permission prompts sequenced; HealthKit background delivery dropped (needs an
  entitlement the app lacks); `armv7` capability removed; stray `payload.json` deleted.
- **Tests:** `PushUpDetectorTests` added (7 tests). Full suite green as of `8211b12`.

---

## Still open

1. **Remove the telemetry HUD before any App Store release.** It is visible to every TestFlight
   tester on the exercise screen.
2. **AlarmKit has never fired an alarm.** No Widget Extension target exists. The system
   full-screen alert is expected to work without one, but the Lock Screen / Dynamic Island
   presentation will not. Add the target if no alert appears.
3. **`MotionVisionEngine` is half-fixed.** The shared-request race is gone, but
   `visionImageOrientation` and `processingExercise` are still written on main/`sessionQueue` and
   read on `videoQueue` unsynchronised. Left deliberately — a locking change to the 30 fps hot
   path was too risky to make without a device to test on.
4. **Pull-ups can still double-count.** `repCountedThisCycle` clears on the very next `.hanging`
   frame, so holding at the top past the 0.4 s cooldown counts one physical rep twice. The
   cooldown is the only real guard; fixing it properly needs a state-machine rework.
5. **First-launch permissions** — sequencing is implemented but untested; needs a delete-and-
   reinstall to verify the four prompts now appear one at a time.

---

## Notes

- `Version.xcconfig` is bumped automatically by `scripts/bump_build_number.sh` on **Archive**
  (`ACTION=install`). It will show as modified after every archive; that is expected, not a stray
  edit.
- To exercise the ringing flow in the simulator without tapping: grant privacy with
  `xcrun simctl privacy <device> grant all com.deepankarboro.pulsewake`, then
  `xcrun simctl push <device> com.deepankarboro.pulsewake <file>.apns` with an `aps` key plus
  `alarmId`, `exerciseType`, `targetReps`, `soundName` and `"category": "ALARM_CATEGORY"` at the
  top level. Note this only exercises the legacy notification path, not AlarmKit.
