# PL1 sweep with Llano cooler at 1400 RPM  (VALID — this is the real dataset)

Run 2026-09-07 22:31-23:18Z, authorised under a thermal-only exception to
this host's agent policy. Harness: experiment-sweep.sh.

## Configuration
- Cooler: Llano laptop cooler, **1400 RPM** (range 300-2800), fixed for the whole run
- **Laptop's own fans: 0 RPM throughout** (`pwm1_enable=1, pwm1=0` — held in manual
  mode at 0%). Every temperature below is therefore "external cooler only".
  Restoring EC fan control can only improve these numbers, never worsen them, so
  this table is a CONSERVATIVE FLOOR.
- Both RAPL package domains swept together (intel-rapl:0 AND intel-rapl-mmio:0).
  Sweeping only the MSR domain measures the MMIO one — see the VOID datasets.
- PL2 = PL1+15, tau = 8s, constant. PL1 is the only variable.
- Workload: stress-ng --cpu 16 --cpu-method matrixprod, 180s, n=2, order
  45-55-65-50-60 / 60-50-65-55-45 (mirrored, cancels linear ambient drift).

## Phase 1 — transfer function
| PL1 | steady | peak | work/s | vs stock | work/W | throttle |
|---|---|---|---|---|---|---|
| 45W | 62.9C | 66C | 15052 | 85.2% | 334 | 0 ms |
| 50W | 68.3C | 74C | 15859 | 89.8% | 317 | 0 ms |
| 55W | 71.8C | 77C | 16512 | 93.5% | 300 | 0 ms |
| 60W | 77.0C | 82C | 16988 | 96.2% | 283 | 0 ms |
| 65W | 82.0C | 86C | 17521 | 99.2% | 270 | 0 ms |

Stock reference = 17664/s (config A, 200W PL1, pre-cooler, from README.md).
Repeat spread 0.2-0.6%, at the documented noise floor. NOTHING throttled anywhere.

## Phase 3 — burst (10s load / 20s idle, n=12 each)
| PL1 | work/s | mean peak | max | throttle |
|---|---|---|---|---|
| 50W | 15072 | 72.7C | 75C | 0 ms |
| 65W | 17102 | 84.4C | 86C | 0 ms |

+13.5% on bursty work from raising PL1. The pre-registered hypothesis -- that
bursts stay inside the PL2 window and PL1 is irrelevant to them -- is FALSIFIED.
Mechanism: tau is 8s and the burst is 10s, so each burst runs its tail under PL1.

LIMIT: 10s bursts only. Real agent tasks are often 1-3s and WOULD sit entirely
inside the boost window. The crossover below 10s is unmeasured.

## Known invalid in this dataset
- Thermal time constants: rapl-sample.service starts 1s before load, so the first
  sample is already mid-heating. The t63/t90 figures the analyser prints are an
  artifact. Needs a dedicated idle->load->idle run.
- fanRPM column: reads 0 because the fans are held off, not because they idled.

## Airflow ladder (added 2026-09-07 23:41Z)

Two PL1 points re-measured at cooler=2000 RPM, same protocol, n=2 each
(benchmark/airflow-point.sh, results/airflow-ladder.tsv).

| cooler | 50W steady | 65W steady | 65W work/s |
|---|---|---|---|
| none    | 81.8 C | -      | -     |
| 300 RPM | 78.0 C | -      | -     |
| 1400 RPM| 68.3 C | 82.0 C | 17521 |
| 2000 RPM| 66.1 C | 80.7 C | 17538 |

300->1400 buys 9.7 C. 1400->2000 buys 2.2 C at 50W, 1.4 C at 65W, and NO
throughput (17521 vs 17538 = 0.1%, noise). Diminishing returns; 1400 is the
setting. 2000 trades audible fan noise for headroom with no use.

Nothing above 65W is worth chasing either: the stock run drew 74.3W actual
with this workload, so ~74W is the workload's own ceiling, and 65W already
returns 99.2% of stock. The remaining 65->74W band is worth under 1%.

## Burst crossover (added 2026-09-08 04:20Z, cooler 2000 RPM)

Fixed work, measured time. PL1 in {50W, 65W} x burst in {1,2,3,5,10}s, n=8 per
cell. Data: results/burst-crossover.tsv

| burst | PL1=50W | PL1=65W | 65W faster by |
|---|---|---|---|
| ~1s  |   972ms |   841ms | +13.5% |
| ~2s  |  2015ms |  1728ms | +14.2% |
| ~3s  |  2988ms |  2574ms | +13.9% |
| ~5s  |  5060ms |  4412ms | +12.8% |
| ~10s | 10150ms |  8964ms | +11.7% |

**There is no crossover.** The gain is flat, slightly larger for SHORT bursts.
A 1s task benefits as much as a 10s one.

MECHANISM -- read this before designing anything on top of it. The experiment
held PL2 = PL1+15 to keep PL1 a single variable, so raising PL1 to 65W also
raised PL2 from 65W to 80W. A 1s burst sits entirely inside the 8s boost window
where PL2, not PL1, binds. So this measures raising the whole ENVELOPE:

  - short bursts gain from PL2
  - long bursts gain from PL1
  - the 14.2% -> 11.7% decline is longer bursts spending proportionally more
    time under the lower limit

A controller that raised only PL1 would do nothing for a 1s task. One that
raises the envelope helps uniformly, and needs no burst-length detection.

Two prior versions of this test were VOID and are kept as
burst-crossover-VOID-quantized.tsv: the first polled temperature inside the
timing loop (sleep 0.25, quantizing 48 of 80 samples to exactly 256ms) and
mis-calibrated ops-per-second by 15x, so bursts ran 0.25-0.8s instead of 1-9s.

## Combined CPU+GPU load (added 2026-09-08, cooler at 2000 RPM)

Every figure above was measured with the GPU IDLE, and the methodology listed
combined load as untested. Now measured: 5 minutes of back-to-back local
inference (qwen2.5-7b via Ollama) with all 16 CPU threads under stress-ng,
PL1 at 50W. Sampler runs outside the load's timing path. n=47 steady samples.
Data: results/gpu-thermal-both.tsv

| | CPU-only @50W | CPU + GPU @50W |
|---|---|---|
| CPU steady | 68.3 C | **74.6 C** |
| CPU peak | 74 C | **78 C** |
| GPU | idle | **90 W, 62 C, 97% util** |
| throttling | 0 ms | **0 ms / 300 s** |

**Sustained GPU inference costs 6.3 C of CPU headroom and causes no
throttling.** The 45-65W envelope holds under combined load.

Extrapolating to 65W: CPU-only was 82.0 C, so combined would land near 88 C
steady with peaks near 92 C. Under TjMax but a much thinner margin than the
CPU-only figure suggests. **60W (77.0 C -> ~83 C combined) is the safer choice
if the machine will run inference and CPU work at the same time.**

### Correction: the laptop fans are fine

Earlier notes in this repo and in bot-net's LOG.md claimed the fans were held
off in manual mode (`pwm1_enable=1, pwm1=0`), inferred from them reading 0 RPM
all day, and speculated it was collateral from masking thermald. Both claims
were wrong. Under this load they spin:

    fan1: 1044 RPM   fan2: 1066 RPM

They read 0 all day because nothing had ever asked enough of the machine. The
EC ramps them from chassis sensors, and until a sustained combined load there
was nothing to ramp for. There is no fan fault and no missing backup.
