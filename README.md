# Dell Precision thermal runaway — diagnosis, measurement, and fix

Dell ships several Precision mobile workstations with the CPU's **sustained power
limit (PL1) set far above what the chassis can cool** — on the machine tested here,
**200 W on a 45 W processor**, with a 56-second averaging window. The practical
effect is that there is no sustained power limit at all: under load the CPU runs
until it hits TjMax, then throttles, and on a warm day or under combined CPU+GPU
load it shuts the machine down.

This repo contains the diagnosis, a reproducible benchmark that **quantifies the
tradeoff honestly**, and an installer that finds the right limit for *your* chassis
rather than copying someone else's number.

## Is my machine affected?

```bash
sudo ./install.sh --diagnose        # reports only, changes nothing
```

You are affected if PL1 is far above your CPU's rated TDP, or the PL1 window is
tens of seconds. Read it manually with:

```bash
R=/sys/class/powercap/intel-rapl:0
echo "PL1 $(( $(cat $R/constraint_0_power_limit_uw)/1000000 ))W \
tau $(( $(cat $R/constraint_0_time_window_us)/1000000 ))s \
PL2 $(( $(cat $R/constraint_1_power_limit_uw)/1000000 ))W"
```

Reported stock values in the wild:

| Model | Stock PL1 | Window | Stock PL2 | Source |
|---|---|---|---|---|
| Precision 7560 (i9-11950H, 45 W TDP) | **200 W** | 56 s | 109 W | measured here |
| Precision 7750 | 75 W | 56 s | 135 W | [Dell forums](https://www.dell.com/community/en/conversations/precision-mobile-workstations/precision-7750-power-levels/647fa072f4ccf8a8de57484f) |

The 56-second window appears on both — it is a Dell-wide default and is half the
problem on its own, because it lets the CPU sit near PL2 for most of a minute
before the rolling average reins it in.

## Install

```bash
git clone <this repo> && cd dell-precision-thermal-fix
sudo ./install.sh --autotune     # measures your machine, ~5 min per candidate
```

Or, if you want the tested values directly and have a similar chassis:

```bash
sudo ./install.sh --pl1 50 --pl2 65 --tau 8
```

Undo completely with `sudo ./uninstall.sh` — firmware defaults return on reboot.

The installer also lays down a **2-minute watchdog timer**, because some embedded
controllers reset RAPL limits at runtime and would otherwise silently undo the fix.

## Results — and the honest tradeoff

**Do not expect this to be free.** It is widely assumed that capping a
thermally-throttled CPU costs nothing, "because it was throttling anyway." We
tested that directly and **it is false.**

Test machine: Precision 7560, i9-11950H (8C/16T), 64 GB, Ubuntu 26.04.1, kernel
7.0.0-31. Workload `stress-ng --cpu 16 --cpu-method matrixprod`, 180 s, n=2 per
config, counterbalanced A-B-C-C-B-A, cooled to a common baseline before each run.

| Config | PL1 / PL2 | Work done | vs stock | Steady | Peak | Throttled | Pkg power | Work per watt | Fan |
|---|---|---|---|---|---|---|---|---|---|
| **A** stock | 200 / 109 W | 3,179,540 | 100% | **99.9 °C** | 100 °C | **118 s / 180 s** | 74.3 W | 42,822 | **4798 / 4800 RPM** |
| **C** | 55 / 80 W | 2,893,590 | 91.0% | 84.8 °C | 98 °C | 1.5 s | 55.0 W | 52,611 | 3286 |
| **B** ✅ | 50 / 65 W | 2,728,014 | **85.8%** | **81.8 °C** | **88.5 °C** | **0 s** | 50.0 W | **54,560** | 3112 |

Run-to-run variance was **0.3–0.8%**, so the 14% gap is roughly 20× the noise floor.

### What the numbers actually say

**Stock genuinely is faster — by 14.2%.** It throttles for 65% of the run and
*still* wins, because it is pulling 74 W against 50 W. Power buys work even
through throttling. Any claim that the cap is free is wrong.

**But stock spends everything to get it.** It runs at 99.9 °C with the fans at
**4798 of a maximum 4800 RPM**. There is no cooling reserve whatsoever. That 14%
exists only in a cool room with the GPU idle — add ambient heat, a soft surface,
or any GPU load and the machine does not throttle harder, it powers off.

**The capped config is 27% more efficient** (54,560 vs 42,822 bogo-ops per watt)
and, critically, is *power*-bound rather than *thermally* bound. Evidence: config B
was run at 53 °C and 56 °C ambient and landed within 0.3%. Stock is the
configuration that degrades as the room warms.

**55 W is a trap.** It recovers 5 points of throughput for 10 °C of peak headroom
(88.5 → 98 °C) and reintroduces throttling. Two degrees of margin is not margin.

### Conclusion

The honest framing is not "free performance." It is:

> **You trade ~14% of sustained multicore throughput for a machine that never
> exceeds 88 °C, never throttles, runs 27% more efficiently, and cannot thermally
> shut down.**

For a workstation running long unattended jobs, that is the right trade. If you
run short bursts in a cold room and babysit the machine, stock may genuinely suit
you better. Know which one you are choosing.

## Repo contents

```
install.sh              diagnose / autotune / apply
uninstall.sh            full removal
cpu-powercap-apply      the sysfs writer (validates constraint naming first)
cpu-powercap.service    boot + resume-from-suspend persistence
benchmark/              the experiment harness and RAPL sampler
benchmark/results/      raw data from the run above
docs/METHODOLOGY.md     hypotheses, design, safety rationale, limitations
```

## Safety

Lowering a power limit cannot damage hardware — it is the opposite of
overclocking. The benchmark deliberately allows the CPU to reach TjMax, which is
safe for a measurement of this length: [Intel's position is that thermal
throttling is the designed protection and running at maximum temperature during a
sustained workload "isn't necessarily cause for
concern"](https://www.intel.com/content/www/us/en/support/articles/000005597/processors.html).
Sustained TjMax operation *does* shorten CPU lifespan — which is the thing this
fix exists to prevent.

**Undervolting is not an alternative on 11th-gen Intel.** Intel [disabled it in
microcode as the Plundervolt
mitigation](https://community.intel.com/t5/Processors/11th-gen-tiger-lake-undervolting-disabled-by-intel/m-p/1245398);
MSR 0x150 is locked. Power limits are the only software lever left.

## Prior art

- [erpalma/throttled](https://github.com/erpalma/throttled) — the same idea for Lenovo ThinkPads
- [Framework laptop RAPL notes](https://github.com/junaruga/framework-laptop-config/wiki/Improving-thermal-management-with-Intel-Running-Average-Power-Limit-(RAPL)) — source of the EC-reset warning

## Limitations

n=2 per config, one machine, one ambient. GPU idle throughout — combined CPU+GPU
load is hotter and untested. Power figures are RAPL-modelled, not wall-measured.
**Copy the method, not the wattage.**

## A note on the watchdog

The installer lays down a 2-minute timer that re-asserts the limits, because
[published RAPL guidance warns some embedded controllers reset them at
runtime](https://github.com/junaruga/framework-laptop-config/wiki/Improving-thermal-management-with-Intel-Running-Average-Power-Limit-(RAPL)).

We tested for this on the Precision 7560 and **found no drift** — 32 samples over
8 minutes including a 3-minute load, all identical. The watchdog is kept as cheap
insurance for other models and future BIOS revisions, not because this machine
needs it. See `docs/METHODOLOGY.md`.
