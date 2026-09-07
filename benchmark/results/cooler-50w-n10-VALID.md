# Cooler effect at PL1=50W (n=10), cooler at 300 RPM

**The Llano cooler was running at 300 RPM for all of these runs** -- near its
minimum; it goes to 2800. Everything below is the effect of a barely-running
cooler, and is a FLOOR on what the hardware can do, not its capability.

These ten runs were an ATTEMPTED 45-65W sweep that failed: cpu-powercap-watchdog.timer
re-asserted PL1=50W every 60s (37 times during the session), so every run measured 50W.
The pl1_w column is what was ASKED FOR, not what was applied. Do not read it as a sweep.

What it IS: ten runs at an identical 50W config with the Llano cooler attached --
a controlled n=10 replication of experiment.sh config B (n=2, pre-cooler, see README).

| metric | pre-cooler (n=2) | with cooler (n=10) | delta |
|---|---|---|---|
| steady temp | 81.8 C | 78.0 C | -3.8 C |
| peak temp | 88.5 C | 82.1 C | -6.4 C |
| fan RPM | 3112 | 1713 | -45% |
| throughput | 15156/s | 15631/s | +3.1% |
| steady power | 50.0 W | 50.0 W | unchanged |
| throttling | 0 ms | 0 ms | unchanged |

Throughput rose at IDENTICAL power: cooler silicon leaks less, so the same 50W does
more work. Spread across the ten runs was 1.2%, at the documented noise floor.

Caveat: brief sub-minute excursions to the nominal PL1 may have occurred at the start
of some runs, before the watchdog reset them. The two 45W-nominal runs are the two
lowest throughput values, which is consistent with that.
