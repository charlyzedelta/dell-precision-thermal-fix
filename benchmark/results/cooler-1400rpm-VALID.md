# PL1 sweep with Llano cooler at 1400 RPM  (VALID — this is the real dataset)

Run 2026-09-07 22:31-23:18Z, authorised by Charles under a thermal-only exception
to bot-net PLAN.md Appendix C. Harness: experiment-dynamic-v4.sh.

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
