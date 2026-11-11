"""Geo-lift test design on real market data: synthetic control, placebo
inference and a power analysis.

The question a marketing team brings: "we want to run a campaign in a few
countries and measure the lift. Which countries, for how long, and what's the
smallest lift we'd be able to see?"

No campaign ran in this data, so the lift is added by hand: multiply a
market's real weekly searches by (1 + lift) over a test window, then check
whether synthetic control finds it. Doing that over many windows and lift
sizes gives the power curve. This is how GeoLift-style tools size a test
before it runs.

Synthetic control builds the treated market's "no campaign" path as a
weighted mix of the other markets, with weights >= 0 that sum to 1, fitted on
the weeks before the test. The lift is actual vs that mix during the test.

Inference: placebo tests. Pretend each untreated market (or group of
markets) was the treated one, run the same estimate, and see how big the fake
lifts get. Those fake lifts are the null distribution: a real lift has to land
above their 97.5th percentile (a two-sided 5% test, equal tails). The fake
lifts aren't centred on zero here (spring 2013 shifted some markets against
others), so equal tails are used rather than |lift|.

Placebos only come from mid-size markets (100+ searches a week). My first
version used every market, and the small ones (31-85 searches a week, about
1.5 times as noisy week to week, see geo_noise_by_size) widened the critical
value: a single market couldn't detect even a 40% lift, and three markets
needed 25% instead of 15% over 6 weeks (section 5, geo_placebo_pool_check.csv).
A placebo should be about as noisy as the market being tested. The cost is a
small pool: 10 mid-size markets, so 35 placebo groups per test window for a
three-market design and 9 for a single market (placebos_per_window in
geo_power.csv).

Market choice uses only weeks 0-17, before the earliest test window: fit on
weeks 0-11, score the fit on weeks 12-17. Choosing markets on the same weeks
the power curve is run on would make the design look better than it is.

Input: geo_weekly from sql/07_geo_panel.sql (weekly searches, 19 markets,
34 weeks). Output: results/geo_*.csv

usage: python stats/geo_lift.py   (after scripts/build.py)
"""
import itertools
import pathlib

import duckdb
import numpy as np
from scipy.optimize import nnls

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "results"
RNG = np.random.default_rng(7)

con = duckdb.connect(str(ROOT / "experiments.duckdb"), read_only=True)
panel = con.sql("select country, week, searches from geo_weekly order by country, week").df()
wide = panel.pivot(index="week", columns="country", values="searches")
weeks = wide.index.to_list()
markets = [int(c) for c in wide.columns]
Y = wide.to_numpy(float)                # weeks x markets
T_WEEKS = Y.shape[0]
LARGEST = 219                           # by far the largest market (geo_markets), a donor only

MIN_PRE = 18
LIFTS = [0.0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40]
LENGTHS = [2, 4, 6, 8]


def col(m):
    return markets.index(m)


def sc_fit(y_pre, X_pre):
    """Weights >= 0 summing to 1, least squares on the pre-period.
    The sum-to-one constraint is added as an extra heavily weighted row,
    which keeps it a plain non-negative least squares problem."""
    lam = 1e4
    A = np.vstack([X_pre, lam * np.ones(X_pre.shape[1])])
    b = np.concatenate([y_pre, [lam]])
    w, _ = nnls(A, b)
    return w / w.sum()


def estimate(Ymat, treated, start, length, lift=0.0, donors=None):
    """Estimated relative lift for a treated group of markets.

    Each series is divided by its own pre-period mean so big and small
    markets are on the same scale. Returns lift, weights, and the actual and
    synthetic (normalised) series."""
    tcols = [col(m) for m in treated]
    if donors is None:
        donors = [m for m in markets if m not in treated]
    dcols = [col(m) for m in donors]
    y = Ymat[:, tcols].sum(axis=1).copy()
    y[start:start + length] *= 1 + lift
    pre = slice(0, start)
    y_n = y / y[pre].mean()
    X = Ymat[:, dcols]
    X_n = X / X[pre].mean(axis=0)
    w = sc_fit(y_n[pre], X_n[pre])
    synth = X_n @ w
    post = slice(start, start + length)
    est = y_n[post].sum() / synth[post].sum() - 1
    return est, w, y_n, synth


MID_SIZE = 100   # average weekly searches


def placebo_lifts(treated, start, length, n_draws=200, min_size=MID_SIZE, rng=RNG):
    """Fake lifts from pretending other markets (same group size) were treated.
    The real treated markets are left out of the donor pool for these.
    min_size=0 lets the small markets back in (the check in section 5)."""
    pool = [m for m in markets if m not in treated and m != LARGEST
            and Y[:, col(m)].mean() >= min_size]
    k = len(treated)
    combos = list(itertools.combinations(pool, k))
    if len(combos) > n_draws:
        idx = rng.choice(len(combos), n_draws, replace=False)
        combos = [combos[i] for i in idx]
    out = []
    for fake in combos:
        donors = [m for m in markets if m not in fake and m not in treated]
        est, *_ = estimate(Y, list(fake), start, length, donors=donors)
        out.append(est)
    return np.array(out)


# ---- 1. how well can each market be rebuilt from the others? ----
# fit on weeks 0-11, score on weeks 12-17. In-sample fit always looks good,
# so the ranking uses the out-of-sample error. Everything here is before
# MIN_PRE, the first week any test window can start.
SEL_FIT, SEL_END = 12, MIN_PRE
rows = []
for m in markets:
    est, w, y_n, synth = estimate(Y, [m], start=SEL_FIT, length=SEL_END - SEL_FIT)
    pre_err = np.sqrt(np.mean((y_n[:SEL_FIT] - synth[:SEL_FIT]) ** 2))
    post_err = np.sqrt(np.mean((y_n[SEL_FIT:SEL_END] - synth[SEL_FIT:SEL_END]) ** 2))
    top = sorted(zip(w, [d for d in markets if d != m]), reverse=True)[:3]
    rows.append((m, Y[:, col(m)].mean(), pre_err, post_err, est,
                 "; ".join(f"{d}:{wt:.2f}" for wt, d in top if wt > 0.005)))
rows.sort(key=lambda r: r[3])
with open(OUT / "geo_market_fit.csv", "w") as f:
    f.write("country,avg_weekly_searches,fit_error_pre_pct,fit_error_holdout_pct,holdout_fake_lift_pct,top_donor_weights\n")
    for m, size, pe, po, est, tw in rows:
        f.write(f"{m},{size:.0f},{100 * pe:.1f},{100 * po:.1f},{100 * est:.1f},{tw}\n")


# ---- 2. candidate designs ----
# single markets: the mid-size ones (not the giant, not the tiny)
mid = [m for m in markets if m != LARGEST and Y[:, col(m)].mean() >= MID_SIZE]
fit_rank = {r[0]: i for i, r in enumerate(rows)}
best_single = min(mid, key=lambda m: fit_rank[m])
# group of three: the three mid-size markets with the best holdout fit
group3 = sorted(mid, key=lambda m: fit_rank[m])[:3]
designs = {f"one market: {best_single}": [best_single],
           "three markets: " + " + ".join(map(str, group3)): group3}


# ---- 3. power curves ----
power_rows = []
for name, treated in designs.items():
    for L in LENGTHS:
        starts = list(range(MIN_PRE, T_WEEKS - L + 1))
        # critical value: 97.5th percentile of the fake lifts, pooled across
        # placebo groups and across all test windows of this length
        null = np.concatenate([placebo_lifts(treated, s, L) for s in starts])
        crit_lo, crit = np.quantile(null, [0.025, 0.975])
        for lift in LIFTS:
            ests = np.array([estimate(Y, treated, s, L, lift=lift)[0] for s in starts])
            power_rows.append((name, L, lift, len(starts), len(null) // len(starts), crit,
                               ests.mean(), ((ests < crit_lo) | (ests > crit)).mean(),
                               (ests > crit).mean()))

# power_pct: share of windows above the upper critical value (a lift found).
# flagged_either_tail_pct: share beyond either 2.5% tail, the two-sided test;
# at 0% lift that is the design's false-positive rate.
with open(OUT / "geo_power.csv", "w") as f:
    f.write("design,test_weeks,true_lift_pct,windows_tested,placebos_per_window,critical_lift_pct,"
            "mean_estimated_lift_pct,flagged_either_tail_pct,power_pct\n")
    for name, L, lift, n, ppw, crit, mean_est, either, pw in power_rows:
        f.write(f"{name},{L},{100 * lift:.1f},{n},{ppw},{100 * crit:.1f},{100 * mean_est:.1f},"
                f"{100 * either:.0f},{100 * pw:.0f}\n")

# smallest lift with at least 80% power, per design and length.
# With 9 to 15 windows per design, the power estimates are coarse; treat the
# MDE as a ballpark.
with open(OUT / "geo_mde.csv", "w") as f:
    f.write("design,test_weeks,mde_80pct_power\n")
    for name in designs:
        for L in LENGTHS:
            ok = [lift for (n, l, lift, *_r, pw) in power_rows if n == name and l == L and pw >= 0.8 and lift > 0]
            f.write(f"{name},{L},{'%.1f%%' % (100 * min(ok)) if ok else 'over %.0f%%' % (100 * max(LIFTS))}\n")


# ---- 4. two worked readouts ----
# simulated campaigns in the three-market group over the last 6 weeks
# (20 May to 30 June 2013): one at 10%, a lift a marketer would be happy with,
# and one at the size the power analysis says is detectable.
L = 6
start = T_WEEKS - L
g3_name = [n for n in designs if n.startswith("three")][0]
mde6 = [lift for (n, l, lift, *_r, pw) in power_rows if n == g3_name and l == L and pw >= 0.8 and lift > 0]
big_lift = min(mde6) if mde6 else 0.30
# pool placebo fake lifts across every 6-week window, not just the last one:
# a single window only has a few dozen placebo groups
null = np.concatenate([placebo_lifts(group3, s, L) for s in range(MIN_PRE, T_WEEKS - L + 1)])


def readout(true_lift):
    est, w, y_n, synth = estimate(Y, group3, start, L, lift=true_lift)
    # two-sided placebo p-value, equal tails
    upper = (np.sum(null >= est) + 1) / (len(null) + 1)
    lower = (np.sum(null <= est) + 1) / (len(null) + 1)
    p = min(1.0, 2 * min(upper, lower))
    return est, w, y_n, synth, p


# difference-in-differences against the raw total of all other markets, for
# comparison. A raw total weights markets by size, so 219 dominates it.
donors = [m for m in markets if m not in group3]
y_raw = Y[:, [col(m) for m in group3]].sum(axis=1).copy()
y_raw[start:] *= 1.10
d_raw = Y[:, [col(m) for m in donors]].sum(axis=1)
did = (y_raw[start:].mean() / y_raw[:start].mean()) / (d_raw[start:].mean() / d_raw[:start].mean()) - 1
share_largest = Y[:, col(LARGEST)].sum() / d_raw.sum()

with open(OUT / "geo_example_readout.csv", "w") as f:
    f.write("item,small_campaign,large_campaign\n")
    a = readout(0.10)
    b = readout(big_lift)
    f.write(f"treated markets,{' '.join(map(str, group3))},{' '.join(map(str, group3))}\n")
    f.write(f"test weeks,{weeks[start]:%Y-%m-%d} to {weeks[-1]:%Y-%m-%d},same\n")
    f.write(f"true lift added,10.0%,{100 * big_lift:.1f}%\n")
    f.write(f"synthetic control estimate,{100 * a[0]:.1f}%,{100 * b[0]:.1f}%\n")
    band = f"{100 * np.quantile(null, 0.025):.1f}% to {100 * np.quantile(null, 0.975):.1f}%"
    f.write(f"fake lifts with no campaign (95% range),{band},{band}\n")
    med = f"{100 * np.median(null):.1f}%"
    f.write(f"fake lifts with no campaign (median),{med},{med}\n")
    f.write(f"p-value (placebo rank),{a[4]:.3f},{b[4]:.3f}\n")
    f.write(f"placebo estimates,{len(null)},{len(null)}\n")
    f.write(f"difference-in-differences estimate,{100 * did:.1f}% (10% case),\n")
    f.write(f"country {LARGEST}'s share of the difference-in-differences comparison total,{100 * share_largest:.1f}%,same\n")
    f.write("donor weights," + "; ".join(f"{d}:{wt:.2f}" for wt, d in sorted(zip(a[1], donors), reverse=True) if wt > 0.005) + ",same\n")

with open(OUT / "geo_example_series.csv", "w") as f:
    f.write("week,actual_index_10pct,actual_index_large,synthetic_index,in_test\n")
    for i, wk in enumerate(weeks):
        f.write(f"{wk:%Y-%m-%d},{a[2][i]:.4f},{b[2][i]:.4f},{a[3][i]:.4f},{i >= start}\n")


# ---- 5. why placebos come only from mid-size markets ----
# The same power analysis with the small markets let back into the placebo
# pool (every market except the largest and the treated ones). Their noise
# widens the critical value. A separate random generator (pools over 200
# placebo groups are sampled) keeps every output above unchanged.
rng_check = np.random.default_rng(8)
with open(OUT / "geo_placebo_pool_check.csv", "w") as f:
    f.write("design,test_weeks,placebo_pool,placebos_per_window,critical_lift_pct,mde_80pct_power\n")
    for name, treated in designs.items():
        for L in LENGTHS:
            starts = list(range(MIN_PRE, T_WEEKS - L + 1))
            ests = {lift: np.array([estimate(Y, treated, s, L, lift=lift)[0] for s in starts])
                    for lift in LIFTS if lift > 0}
            for pool_name, min_size in [("mid-size markets only", MID_SIZE),
                                        (f"every market except {LARGEST}", 0)]:
                null = np.concatenate([placebo_lifts(treated, s, L, min_size=min_size, rng=rng_check)
                                       for s in starts])
                crit = np.quantile(null, 0.975)
                ok = [lift for lift, e in ests.items() if (e > crit).mean() >= 0.8]
                mde = "%.1f%%" % (100 * min(ok)) if ok else "over %.0f%%" % (100 * max(LIFTS))
                f.write(f"{name},{L},{pool_name},{len(null) // len(starts)},{100 * crit:.1f},{mde}\n")

print(open(OUT / "geo_market_fit.csv").read())
print(open(OUT / "geo_mde.csv").read())
print(open(OUT / "geo_example_readout.csv").read())
