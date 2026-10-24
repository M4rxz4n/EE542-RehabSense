RehabSense · bench prototype · Serial log

# RehabSense Session Viewer

Load a Serial Monitor log from the sleeve to see the elbow angle, biceps effort, every counted and partial rep, and faults on one timeline. Works with v2 and v3 firmware logs; nothing leaves your browser.

Open log file or copy the Serial Monitor output and press Cmd+V on this page Session

Paste Serial Monitor output

## How to read this page

The sleeve measures two things while the wearer does slow biceps curls, and the firmware decides which movements count as reps.

Elbow angle

How far the elbow is bent, from two motion sensors on the upper arm and forearm. 0° is a straight arm; about 90° is the forearm at a right angle.

Biceps effort

Muscle activity picked up by the EMG electrodes, shown as a percentage of the hardest squeeze recorded during calibration. 100% is that maximum squeeze; under % the muscle counts as relaxed.

Rep

One curl. It starts when the elbow rises past °, counts only if it reaches °, and ends when the arm drops back below °.

Partial rep

A curl that started but stopped short of °. It is shown but not counted.

Fault

A moment where a motion sensor failed to answer. Readings during a fault are unreliable.

## Session summary

Totals for the whole session. Green is on target, orange needs attention, red is a problem.

## Whole session at a glance

Each bump is one curl. The blue box marks the stretch shown in the two charts below. Click or drag inside the strip to move it.

Show

Showing

Elbow angle Stretch shown below Rep counted Rep flagged Partial rep Sensor fault

## Elbow angle over time

How far the elbow is bent at each moment. A full curl rises from near 0° to above the dashed target line and comes back down. Hover for exact values; drag sideways to move through time.

Elbow angle Target: a rep must pass ° Rep starts above °, ends below ° Rep counted (# = rep number) Rep flagged Partial rep, at its highest point Sensor fault

## Biceps effort over time

Muscle activity from the EMG electrodes, on the same time axis as the elbow chart above. It should rise during each curl and fall back near zero while the arm rests.

Biceps effort, % of maximum squeeze Muscle-on threshold, % Rep counted (same moments as above) Sensor fault

## Highest angle reached in each rep

One bar per counted rep, in order. Taller bars mean a bigger bend. Click a bar to find that rep on the charts above.

Reached the target Below the target Selected rep Target, ° Full bend goal, °

## How long each rep took

Seconds from the arm starting to rise to it coming back down. Slow, controlled curls are good, but bars far above the band usually mean a pause mid-rep.

Ideal pace, – s Within the ideal pace Too slow or too fast Selected rep

## Every rep, in order

Counted and partial reps as they happened. Select a row to find it on the charts above.

| Rep # | Time | Highest angle | Duration | Range score | Pace | Overall score | Result |
| --- | --- | --- | --- | --- | --- | --- | --- |

Rep #

Rep number. A dash means a partial rep, which gets no number.

Time

When the rep ended, in minutes:seconds from the start of the session.

Highest angle

The most the elbow bent during the rep.

Duration

Seconds from starting the rep to finishing it.

Range score

Highest angle as a percentage of the ° full bend goal. 100 means a full bend.

Pace

Whether the duration was inside the – s ideal: ok, too slow or too fast.

Overall score

Combined rep score from v3 firmware. A dash means the log didn't include one.

Result

Counted on target · Counted · too slow counted, pace off · Flagged counted but marked for review · Partial stopped short, not counted.

## Recording a session log

1. Upload `rehabsense_v3`, open the Serial Monitor at 115200 and type `l` so each line carries the device time, velocity and rep state.
2. Quick way: after the session, click in the Serial Monitor output, press Cmd+A then Cmd+C, and use **Paste log** here.
3. For long sessions, record straight to a file. Close the Arduino Serial Monitor, then in Terminal run:

   `cd ~/Desktop && screen -L /dev/cu.usbserial-0001 115200`

   Commands such as `c`, `l` and `e` work there too (typing doesn't echo). Quit with Ctrl-A, then K, then Y. Open `screenlog.0` from your Desktop here.
4. Keep the laptop unplugged from its charger while the electrodes are on.

Drop the log file to load it