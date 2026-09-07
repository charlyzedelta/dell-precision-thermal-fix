# Methodology

## Question

Dell ships these machines with a PL1 (sustained CPU power limit) far above the
processor's rated TDP. The obvious worry about capping it is that you give up
performance for temperature. **Do you?**

## Hypotheses

- **H₁** — Stock delivers no more *sustained throughput* than a correctly capped
  configuration, because thermal throttling becomes the binding constraint within
  seconds. If true, the cap is free: strictly better thermals at equal work done.
- **H₀** — Stock delivers measurably higher sustained throughput. The cap is then a
  genuine tradeoff and the right PL1 is a judgement call, not an obvious win.

## Why throughput, not clock speed

Clock frequency is a *proxy* and a misleading one under throttling: a CPU
oscillating between 4.5 GHz and 800 ms of stalled clocks can report a healthy
average while doing less work than one held steadily at 3.2 GHz. We measure
**work completed** — `stress-ng` bogo-ops over a fixed wall-clock window — and
treat clock as a secondary diagnostic.

## Design

Three configurations:

| Config | PL1 | PL1 window | PL2 |
|--------|-----|-----------|-----|
| **A** (stock) | 200 W | 56 s | 109 W |
| **B** (tuned) | 50 W | 8 s | 65 W |
| **C** (aggressive) | 55 W | 8 s | 80 W |

- **Workload**: `stress-ng --cpu $(nproc) --cpu-method matrixprod --timeout 180s`.
  `matrixprod` is deterministic and FP-heavy — representative of compute, and
  reproducible across runs at a fixed stress-ng version.
- **n = 2 per config**, order **A-B-C-C-B-A**. Counterbalancing cancels linear
  ambient drift: the room warms over an hour-long session, and a naive
  A-A-B-B-C-C ordering would confound config with time.
- **Common baseline before every run**: cool until package ≤ 64 °C (cap 300 s),
  then a further 20 s settle. Pre-run idle temp is recorded as an ambient proxy.
- **Steady state** is defined as the final 60 s of each run, discarding the
  transient while fans spin up.
- **Instrumentation**: 2 s sampling of RAPL package power, package temperature,
  and cumulative throttle time.

## Safety

The abort threshold is 104 °C — *above* TjMax (100 °C), deliberately. Aborting at
95 °C, as a first attempt did, makes it impossible to measure stock behaviour at
all: the run ends before fans have even spun up, and you conclude nothing.

Running to TjMax is safe for a measurement of this length. Intel's position is
that [thermal throttling is the designed protection and operating at maximum
temperature during a sustained workload "isn't necessarily cause for
concern"](https://www.intel.com/content/www/us/en/support/articles/000005597/processors.html);
the hardware reduces frequency and voltage automatically, and a separate
automatic shutdown sits far above at 127 °C. What sustained TjMax operation
*does* cost is long-term lifespan — which is the thing this fix exists to avoid,
and precisely why a few minutes of it is an acceptable price to measure it.

## Known limitations

- **n = 2.** Enough to see an effect this large; not enough for a confidence
  interval. Treat the deltas as indicative.
- **Single machine, single ambient.** Results are one chassis in one room. The
  installer's `--autotune` exists because the optimum is chassis- and
  ambient-specific; do not copy the wattage, copy the method.
- **Package power is RAPL-reported**, not wall measured. RAPL is a model, though
  a well-validated one on Intel client parts.
- **GPU idle throughout.** These figures do not describe combined CPU+GPU load,
  which is a hotter and separately interesting case.
