"""A/A tests and the cost of peeking, on real random-order searches.

In an A/A test both groups get exactly the same thing, so any "significant"
difference is a false positive and over many random splits the share of
p < 0.05 should be 5%. If it isn't, the test is broken.

Checked here:
  1. Unit of analysis. Splitting whole searches (the between-search design in
     06) but computing the error as if every impression were independent:
     does that break the 5%?
  2. Peeking. Checking the result every week and stopping the first time
     p < 0.05: how far above 5% does that push false positives, and does an
     O'Brien-Fleming boundary fix it?

Metric: click-through rate (clicks / impressions), randomised by search,
standard error by the delta method with searches as the unit.

usage: python stats/aa_and_peeking.py   (after scripts/build.py)
"""
import pathlib

import duckdb
import numpy as np
from scipy.stats import norm

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "results"
RNG = np.random.default_rng(2013)
N_SIMS = 5000

con = duckdb.connect(str(ROOT / "experiments.duckdb"), read_only=True)
df = con.sql("""
    select
        s.srch_id,
        datediff('week', date '2012-10-29', week_start(s.search_date)) as week_no,
        s.clicks                                         as y,
        s.hotels_shown                                   as x,
        case when s.has_booking then 1 else 0 end        as booked
    from searches s
    where s.is_random
    order by s.search_ts, s.srch_id
""").df()

y = df["y"].to_numpy(float)
x = df["x"].to_numpy(float)
week = df["week_no"].to_numpy()
n_weeks = week.max() + 1


def ratio_test(y, x, g):
    """CTR difference between g==1 and g==0, delta-method se with searches as units."""
    out = {}
    for arm in (0, 1):
        m = g == arm
        r = y[m].sum() / x[m].sum()
        xbar = x[m].mean()
        lin = (y[m] - r * x[m]) / xbar
        out[arm] = (r, lin.var(ddof=1) / m.sum(), x[m].sum())
    diff = out[1][0] - out[0][0]
    se = np.sqrt(out[0][1] + out[1][1])
    naive_se = np.sqrt(sum(r * (1 - r) / n for r, _, n in out.values()))
    return diff / se, diff / naive_se


# ---- 1. plain A/A: N_SIMS random 50/50 splits of searches ----
z_delta = np.empty(N_SIMS)
z_naive = np.empty(N_SIMS)
for i in range(N_SIMS):
    g = RNG.integers(0, 2, len(y))
    z_delta[i], z_naive[i] = ratio_test(y, x, g)

p_delta = 2 * norm.sf(np.abs(z_delta))
p_naive = 2 * norm.sf(np.abs(z_naive))

aa = [
    ("delta method (search as unit)", (p_delta < 0.05).mean()),
    ("naive (impression as unit)", (p_naive < 0.05).mean()),
]
# a false-positive rate estimated from N_SIMS runs has its own noise
fp_se = np.sqrt(0.05 * 0.95 / N_SIMS)
# z_delta / z_naive = naive se / delta-method se, for the same split
se_vs_delta = {"delta method (search as unit)": 1.0,
               "naive (impression as unit)": float(np.median(z_delta / z_naive))}
with open(OUT / "aa_false_positive_rate.csv", "w") as f:
    f.write("method,simulations,false_positive_rate_pct,expected_pct,expected_band_95,median_se_vs_delta_method\n")
    for name, rate in aa:
        f.write(f"{name},{N_SIMS},{100 * rate:.2f},5.00,"
                f"{100 * (0.05 - 1.96 * fp_se):.2f} to {100 * (0.05 + 1.96 * fp_se):.2f},"
                f"{se_vs_delta[name]:.2f}\n")

# p-value histogram for the chart: under a working test it's flat
bins = np.linspace(0, 1, 21)
with open(OUT / "aa_pvalue_histogram.csv", "w") as f:
    f.write("bin_start,bin_end,delta_method,naive\n")
    hd, _ = np.histogram(p_delta, bins)
    hn, _ = np.histogram(p_naive, bins)
    for a, b, c, d in zip(bins[:-1], bins[1:], hd, hn):
        f.write(f"{a:.2f},{b:.2f},{c},{d}\n")


# ---- 2. peeking ----
# Weekly looks. For each simulated A/A split, compute the z-score on all data
# up to week k, for every k. Running sums make that cheap:
#   sum((y - r x)^2) = sum(y^2) - 2 r sum(xy) + r^2 sum(x^2)
def weekly_z(g):
    z = np.empty(n_weeks)
    stats = {}
    for arm in (0, 1):
        m = g == arm
        w = week[m]
        cum = [np.cumsum(np.bincount(w, weights=v, minlength=n_weeks))
               for v in (y[m], x[m], y[m] ** 2, x[m] ** 2, x[m] * y[m], np.ones(m.sum()))]
        stats[arm] = cum
    for k in range(n_weeks):
        parts = []
        for arm in (0, 1):
            sy, sx, syy, sxx, sxy, n = (c[k] for c in stats[arm])
            r = sy / sx
            xbar = sx / n
            ss = syy - 2 * r * sxy + r * r * sxx
            parts.append((r, ss / (n - 1) / xbar ** 2 / n))
        z[k] = (parts[1][0] - parts[0][0]) / np.sqrt(parts[0][1] + parts[1][1])
    return z


# O'Brien-Fleming style boundary: reject at look k if |z_k| > c / sqrt(t_k),
# where t_k is the share of the final sample seen so far (the "information
# fraction"). Weeks aren't equal in size here (traffic grows from November to
# June), so t_k uses the actual cumulative search counts, not k / K.
# c is calibrated by simulating the null as Brownian motion observed at those
# t_k, so the overall false-positive rate is 5%.
def obf_constant(t, alpha=0.05, sims=200_000):
    dt = np.diff(np.concatenate([[0.0], t]))
    paths = np.cumsum(RNG.standard_normal((sims, len(t))) * np.sqrt(dt), axis=1)
    z = paths / np.sqrt(t)
    return np.quantile((np.abs(z) * np.sqrt(t)).max(axis=1), 1 - alpha)


# weeks are numbered from 0, and week 0 is only 4 days (1-4 Nov 2012). The
# first look is at week index 2, after 2 weeks and 4 days of data, so it
# isn't run on a handful of searches
first_look = 2
K = n_weeks - first_look
cum_n = np.cumsum(np.bincount(week, minlength=n_weeks))[first_look:]
info = cum_n / cum_n[-1]
c_obf = obf_constant(info)

stop_naive = np.zeros(N_SIMS, bool)
stop_obf = np.zeros(N_SIMS, bool)
final_only = np.zeros(N_SIMS, bool)
first_stop_week = []
for i in range(N_SIMS):
    g = RNG.integers(0, 2, len(y))
    z = weekly_z(g)[first_look:]
    hits = np.abs(z) > 1.96
    stop_naive[i] = hits.any()
    if hits.any():
        first_stop_week.append(int(np.argmax(hits)) + first_look + 1)
    stop_obf[i] = (np.abs(z) > c_obf / np.sqrt(info)).any()
    final_only[i] = abs(z[-1]) > 1.96

with open(OUT / "peeking.csv", "w") as f:
    f.write("rule,looks,false_positive_rate_pct\n")
    f.write(f"one look at the end,1,{100 * final_only.mean():.1f}\n")
    f.write(f"look every week; stop at first p < 0.05,{K},{100 * stop_naive.mean():.1f}\n")
    f.write(f"look every week; O'Brien-Fleming boundary (c = {c_obf:.2f}),{K},{100 * stop_obf.mean():.1f}\n")

# the false "wins" show up mostly early, when the data is thin
with open(OUT / "peeking_first_false_win.csv", "w") as f:
    f.write("week,false_wins\n")
    counts = np.bincount(first_stop_week, minlength=n_weeks + 1)
    for wk in range(first_look + 1, n_weeks + 1):
        f.write(f"{wk},{counts[wk]}\n")

print(open(OUT / "aa_false_positive_rate.csv").read())
print(open(OUT / "peeking.csv").read())
