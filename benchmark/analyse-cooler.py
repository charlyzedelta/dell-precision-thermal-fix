#!/usr/bin/env python3
"""Turn the cooler sweep into the transfer function a dynamic controller needs.

Three outputs:
  1. steady temp / throughput / throttle vs PL1  -- the map
  2. heating and cooling time constants          -- how fast the controller may move
  3. burst behaviour at 50W vs 65W               -- does PL1 matter for bursty work at all
"""
import csv, glob, os, statistics, sys

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")

# Pre-cooler anchor from README.md: config B was 50/65W.
PRE_COOLER_B = dict(steadyC=81.8, maxC=88.5, throttle_ms=0, watts=50.0, fan=3112,
                    bogo_ops=2728014)

def read_tsv(p):
    if not os.path.exists(p): return []
    with open(p) as f:
        return list(csv.DictReader(f, delimiter="\t"))

def num(x, d=None):
    try: return float(x)
    except (TypeError, ValueError): return d

def sweep():
    rows = read_tsv(os.path.join(D, "cooler-sweep.tsv"))
    if not rows:
        print("no sweep data yet"); return
    by = {}
    for r in rows:
        if r.get("pl1_end") and r["pl1_end"] != r["pl1_w"]:
            print(f"  !! run {r['run']}: PL1 DRIFTED {r['pl1_w']}W -> {r['pl1_end']}W "
                  f"-- this row is not a measurement of {r['pl1_w']}W")
        if r.get("aborted") == "1":
            print(f"  !! run {r['run']} PL1={r['pl1_w']}W ABORTED at {r['maxC']}C")
        by.setdefault(int(r["pl1_w"]), []).append(r)

    print("\n=== TRANSFER FUNCTION (cooler attached) ===")
    print(f"{'PL1':>5} {'steady':>8} {'peak':>6} {'work/s':>10} {'throttle':>9} {'watts':>7} {'fan':>6}  {'n':>2}")
    table = []
    for pl in sorted(by):
        rs = by[pl]
        f = lambda k: [num(r[k]) for r in rs if num(r[k]) is not None]
        st, pk, bps = f("steadyC"), f("maxC"), f("bogo_per_s")
        thr, w, fan = f("throttle_ms"), f("steadyW"), f("fanRPM")
        m = lambda v: statistics.mean(v) if v else float("nan")
        table.append((pl, m(st), m(pk), m(bps), m(thr), m(w), m(fan), len(rs)))
        print(f"{pl:>4}W {m(st):>7.1f}C {m(pk):>5.0f}C {m(bps):>10.0f} "
              f"{m(thr):>8.0f}ms {m(w):>6.1f}W {m(fan):>6.0f}  {len(rs):>2}")

    # anchor: did the cooler actually move the 50W point?
    at50 = [t for t in table if t[0] == 50]
    if at50:
        _, st, pk, bps, thr, w, fan, _ = at50[0]
        d = st - PRE_COOLER_B["steadyC"]
        print(f"\n=== COOLER EFFECT (50W anchor, identical config both sides) ===")
        print(f"  steady temp : {PRE_COOLER_B['steadyC']:.1f}C -> {st:.1f}C   ({d:+.1f}C)")
        print(f"  peak        : {PRE_COOLER_B['maxC']:.1f}C -> {pk:.0f}C")
        print(f"  fan RPM     : {PRE_COOLER_B['fan']} -> {fan:.0f}  "
              f"({(fan-PRE_COOLER_B['fan'])/PRE_COOLER_B['fan']*100:+.0f}%)")
        print("  (fan RPM is the cleaner signal: same load, same cap, less work for the fans)")

    # what does the headroom buy, in throughput?
    if len(table) > 1:
        base = next((t for t in table if t[0] == 50), table[0])
        print(f"\n=== WHAT HIGHER PL1 BUYS (vs 50W) ===")
        for pl, st, pk, bps, thr, w, fan, n in table:
            if base[3] and bps == bps:
                print(f"  {pl:>3}W: {bps/base[3]*100:>6.1f}% work   {st:>5.1f}C steady   "
                      f"{thr:>6.0f}ms throttle   {bps/w if w else 0:>7.0f} work/W")

def timeconstants():
    print("\n=== THERMAL TIME CONSTANTS (from 2s samples) ===")
    print("  how long the controller has before heat becomes a problem, and how fast it recovers")
    logs = sorted(glob.glob(os.path.join(D, "raw-cooler", "rapl_run*_pl*.log")))
    if not logs:
        print("  no sample logs yet"); return
    print(f"  {'PL1':>5} {'idle':>6} {'steady':>7} {'t63%':>6} {'t90%':>6}")
    for lg in logs:
        pl = os.path.basename(lg).split("_pl")[1].split("r")[0]
        try:
            rows = [l.split() for l in open(lg) if l.strip()]
            temps = [float(r[2]) for r in rows if len(r) >= 3]
        except Exception:
            continue
        if len(temps) < 20: continue
        t0, steady = temps[0], statistics.mean(temps[-30:])
        rise = steady - t0
        if rise <= 1: continue
        def t_at(frac):
            tgt = t0 + rise * frac
            for i, v in enumerate(temps):
                if v >= tgt: return i * 2
            return None
        print(f"  {pl:>4}W {t0:>5.0f}C {steady:>6.1f}C "
              f"{str(t_at(.63) or '-'):>5}s {str(t_at(.90) or '-'):>5}s")

def burst():
    rows = read_tsv(os.path.join(D, "cooler-burst.tsv"))
    if not rows:
        print("\n=== BURST: no data yet ==="); return
    print("\n=== BURST BEHAVIOUR (10s load / 20s idle) ===")
    print("  If 50W and 65W are indistinguishable here, bursty agent work never")
    print("  leaves the PL2 window and PL1 is the WRONG lever for interactivity.")
    by = {}
    for r in rows:
        by.setdefault(int(r["pl1_w"]), []).append(r)
    for pl in sorted(by):
        rs = by[pl]
        pk = [num(r["peakC"]) for r in rs if num(r["peakC"]) is not None]
        bp = [num(r["bogo_per_s"]) for r in rs if num(r["bogo_per_s"]) is not None]
        th = [num(r["throttle_ms"], 0) for r in rs]
        print(f"  PL1={pl:>3}W  peak {statistics.mean(pk):>5.1f}C (max {max(pk):.0f})  "
              f"work/s {statistics.mean(bp):>9.0f}  throttle {sum(th):>5.0f}ms total")
    if len(by) == 2:
        a, b = sorted(by)
        ba = statistics.mean([num(r["bogo_per_s"], 0) for r in by[a]])
        bb = statistics.mean([num(r["bogo_per_s"], 0) for r in by[b]])
        if ba:
            print(f"\n  -> raising PL1 {a}W->{b}W changes burst throughput by {(bb-ba)/ba*100:+.1f}%")

if __name__ == "__main__":
    sweep(); timeconstants(); burst()
