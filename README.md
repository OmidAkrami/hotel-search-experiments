# What is a top slot worth? Experiments on Expedia hotel search

Expedia published 8 months of hotel search logs for a 2013 Kaggle competition: 9.9 million hotel impressions from 400,000 searches, with clicks, bookings and booking value. For about 30% of those searches Expedia showed the hotels in random order instead of its own ranking. That makes the file a real randomised experiment on position, which is what metasearch and travel sites sell (hotels bid for it on trivago, and Expedia's ranking team optimises it).

I used it to work through a full experimentation workflow in SQL, with Python only where SQL runs out:

1. checks before trusting anything (sampling, assignment, randomisation balance)
2. the A/B test itself: hotels shown in slots 1-4 vs slots 6-10, with clustered standard errors, segment effects and multiple-testing correction
3. cross-checks: same-hotel comparison and CUPED
4. power and sample size from the observed variance, for two test designs
5. A/A tests and what weekly peeking does to false positives
6. a geo-lift test design: synthetic control, placebo inference and a power curve on market-level data

Full outputs and charts: [Kaggle notebook](https://www.kaggle.com/code/omidakrami/expedia-hotel-search-experiments-in-sql)

The competition rules treat the dataset as confidential to participants, so no data is in this repo and the README quotes aggregate results only. To run it, join the competition on Kaggle (free) and download `data.zip` yourself. The Kaggle notebook runs on the competition data directly.

---

## Checks before any test

The obvious first query compares booking rates between the two groups. Expedia's ranking: 93.9% of searches end in a booking. Random order: 13.0%. That would make the ranking 7x better than shuffling, which isn't believable.

Two checks explain it ([02_checks.sql](sql/02_checks.sql)):

- Every one of the 399,344 searches has at least one click, in both groups. The file was most likely sampled on the outcome, and ranked searches with a booking were kept far more often than random ones. Booking rates between the groups can't be compared.
- Among sites with 1,000+ searches, the share of random-order searches goes from 0% to 51%. A chi-square test of one shared share across the 32 sites big enough for it (expected counts of 5+) gives 4,188 on 31 df. Any comparison between the groups has to be made within site.

The inside of the random group is still clean. There, the hotels on each search were shuffled, so a hotel's slot has nothing to do with how good it is. That's the experiment everything below uses.

One more check: are the hotels that landed in slots 1-4 the same kind as those in slots 6-10? Stars, price, review score, chain, promotion and location score 1 are balanced (standardised mean differences all under 0.035). Location score 2 is not (SMD 0.11, and it's missing less often at the top, SMD -0.18). The share missing rises from 11% at slot 1 to 24% at slot 14, and in searches that show all 34 slots it climbs at every slot, from 8% to 26%, which points to a shuffle that wasn't fully uniform. That's why the result below is also checked two other ways.

## The A/B test: slots 1-4 vs slots 6-10

Random-order searches that show all nine slots 1-4 and 6-10 (107,238 searches; the last row uses the 63,720 of them with a click in those slots). Unit: a hotel impression. Error by the delta method with the search as the cluster, since the hotels in a search share one user ([04_ab_test.sql](sql/04_ab_test.sql)).

| metric | slots 1-4 | slots 6-10 | lift | 95% CI |
|---|---|---|---|---|
| click-through rate | 9.43% | 5.34% | +77% | +74% to +79% |
| bookings per 100 impressions | 1.13 | 0.60 | +87% | +79% to +96% |
| booking value per impression | $3.90 | $2.26 | +73% | +60% to +87% |
| clicks that end in a booking | 12.0% | 11.3% | +6% | +2% to +11% |

My first version used every random search, and short lists (say 7 hotels: four in slots 1-4, three in 6-10, since slot 5 is reserved) have a high click-through per hotel and land mostly in the top block. That version said +83% for click-through (83.2% vs 76.6%, `ab_list_length`), about 7 points of lift that came from list length.

Checked against the location score 2 imbalance:

- comparing each hotel only with itself (same hotel, shown in both blocks across different searches): +3.7 points, a +68% lift
- regression adjustment with a pre-period covariate (CUPED, Feb-Jun searches): the estimate moves from +76% to +71%

The three estimates land between +68% and +77%. They don't measure quite the same thing (the same-hotel number weights hotels by how often they appear in both blocks), so I read them as a range.

CUPED barely reduced the variance: 1.5%. The covariate's correlation with a single click is only 0.09 (squared, under 1%). It's a good tool for user-level metrics with a strong history, like revenue per user. For a single click it does little, and I kept the result in to show that.

## How fast clicks fall with position

In searches that show all slots down to 34, slot 1 in random order gets 11.0% click-through, slot 10 gets 3.9% (about a third of it) and slot 30 gets 2.2% ([03_position_effect.sql](sql/03_position_effect.sql)). Under Expedia's ranking the curve falls faster: slot 10 gets 23% of slot 1's click-through instead of 35%, because the ranking also sorts hotels by quality. I don't split that gap into position and relevance, since the ranked searches were sampled differently and their levels can't be set against the random ones.

Testing every pair of neighbouring slots within the searches that show both (32 tests, Benjamini-Hochberg corrected), 11 differences hold up, 9 of them within the first 14 slots. Slot 1 gets 31% more clicks than slot 2. Below slot 14, only 2 of 21 pairs differ after correction. Four of the pairs span a reserved slot (5, 11, 17 and 23 are nearly empty in the data), so 4 vs 6, 10 vs 12, 16 vs 18 and 22 vs 24 are really two steps.

## Who reacts most to position

Same test split by segment, each level compared with the first level of its dimension, BH-adjusted. The scale matters here, so both are shown: relative lift, and absolute gain in clicks per 100 impressions.

| segment | lift | gain (pts) |
|---|---|---|
| 1-2 star hotels | +103% | 4.0 |
| 4-5 star hotels | +64% | 4.0 |
| no reviews | +96% | 3.7 |
| reviews 3.5 to 4 | +76% | 4.3 |
| cheapest third in the search | +80% | 5.0 |
| priciest third in the search | +76% | 3.4 |
| one-night stays | +87% | 4.7 |
| 4+ nights | +71% | 3.8 |
| on promotion | +64% | 4.3 |
| not on promotion | +80% | 4.0 |

On the relative scale, low-star, unreviewed and non-promoted hotels look much more sensitive to position. On the absolute scale that goes away or reverses: 1-2 star and 4-5 star hotels both gain 4.0 clicks per 100 impressions, and unreviewed and non-promoted hotels gain less than their comparison groups (below). Their relative lift is bigger only because they start from a lower base. A hotel paying for placement per click cares about the absolute gain; a forecast of "what happens to my clicks if I move up" uses the relative one.

On the absolute scale, 8 of the 16 comparisons differ after correction, in five dimensions. Cheaper hotels within a search gain more (5.0 points for the cheapest third, 3.9 for the middle and 3.4 for the priciest, adjusted p < 0.001). One-night searches gain more than longer stays on both scales (4.7 vs 3.8 points for both 2-3 and 4+ nights, adjusted p < 0.001). Hotels rated 3.5 to 4 gain more than those rated 4.5 to 5 (4.3 vs 3.8 points, adjusted p < 0.001) and those with no reviews (3.7 points, adjusted p = 0.006). Hotels on promotion gain a little more than the rest (4.3 vs 4.0 points, adjusted p = 0.049, just under the bar), the opposite of the relative scale. Hotels with unknown stars also gain more (5.6 points, adjusted p < 0.001), but that group is small.

No detectable difference on either scale: how far ahead people book, families vs adults only, and the largest market vs the rest. Chain vs independent hotels is borderline on the relative scale (+74% vs +80%, adjusted p = 0.06).

## Expedia's ranking vs random order

Booked searches only, compared within site and averaged with the same site weights for both groups ([05_ranked_vs_random.sql](sql/05_ranked_vs_random.sql)):

- the booked hotel sat 2 slots higher under the ranking (7.6 vs 9.6), and 53% of bookings came from slots 1-4 vs 42%
- people clicked the same number of hotels (1.10 in both)
- the booked hotel was slightly better rated: +0.06 stars and +0.03 review points, both significant
- booking value: $388 vs $381, no detectable difference (95% CI for the gap -$2 to +$16)

A caveat: this conditions on a booking, which is an outcome, so if the ranking changes who books, the groups differ for that reason too.

## Power and sample size

From the variance actually seen in this traffic, at 80% power and 5% significance ([06_power.sql](sql/06_power.sql)). Two designs:

Within-search, like the slot test above: every search has hotels in both arms, so each search is compared with itself. Traffic is the full-list random searches, about 3,100 a week.

- click-through: a 4-week test detects a change of about 9%
- at a 5% lift: clicks need about 12 weeks, bookings per impression about 112, booking value about 300

Between-search, the usual product test: whole searches split 50/50, say old ranking vs new. About 3,500 random searches a week.

- click-through per search: a 4-week test detects about 3%
- at a 5% lift: clicks need under 2 weeks, booking rate about 24 weeks, booking value per search about 77

The weeks are illustrative, since this file is a sample of Expedia's traffic. The between-search click numbers are also optimistic: every search here has at least one click, and real traffic has many with none. The ratios are what carry over. Booking value takes about 26 times as long to test as clicks in the within-search design and about 49 times as long between searches. So the usual setup is a click or booking proxy, with value as a guardrail.

The unit of analysis changes with the design. In the within-search test the clustered standard error is almost the same as the naive one (1.02x), because both arms come from the same searches. When whole searches are split, it isn't (next section).

## A/A tests and peeking

5,000 simulated A/A tests on the random-order searches, splitting whole searches 50/50 ([stats/aa_and_peeking.py](stats/aa_and_peeking.py)):

- with searches as the unit (delta method) the false-positive rate is 4.9%, as it should be
- treating every impression as independent gives 0.6%. The usual warning is that the wrong unit makes tests trigger-happy. Here it does the opposite: nearly every search has exactly one click, so impressions within a search are negatively correlated, the naive standard error comes out about 40% too big, and the test goes half blind. It would miss real effects too.
- checking every week and stopping at the first p < 0.05 pushes false positives from 4.6% to 29%. The 4.6% is a single look at the end in this second simulation, a new set of 5,000 splits, so it differs a little from the 4.9% above. More than a third of those false wins appear in the first three weekly looks, when the data is thin.
- an O'Brien-Fleming boundary (strict early, 2.15 at the final look, spaced by the share of traffic seen so far) brings it back to 5.0%

## Geo-lift test design

There's no real campaign in this data, so this part is about design: which markets, how long, and the smallest lift you could detect. Same approach as GeoLift-style power analysis: add a known lift to real weekly searches in some markets, see whether synthetic control finds it, and repeat over many windows and lift sizes ([stats/geo_lift.py](stats/geo_lift.py)).

Panel: weekly searches for the 19 visitor countries with 30+ searches a week on average and searches in all 34 weeks. Market sizes here come from the sampled file, so they say nothing about Expedia's real markets.

- Synthetic control builds each test market's "no campaign" path from a weighted mix of the other markets (weights >= 0, summing to 1), fitted on the weeks before the test. Inference is by placebo: run the same estimate on comparable markets that got nothing, and require the real lift to beat 97.5% of those fake lifts.
- Placebos are limited to the 10 mid-size markets (100+ searches a week). The small ones are about 1.5 times as noisy. With them in the pool, a single market couldn't detect even a 40% lift, and three markets needed 25% instead of 15% over 6 weeks (`geo_placebo_pool_check`). The cost is a small pool: 35 placebo groups per window for a three-market test.
- Markets are chosen on weeks 0-17 only (fit on 0-11, score the fit on 12-17), before any test window starts. Choosing them on the same weeks the power curve uses would flatter the design.
- One market (country 220, the best early fit): about a 30% lift to be detected 80% of the time, over 8 weeks.
- Three markets together (220, 55 and 100): about 15% over 6 weeks (82% power), 20% over 4 weeks. A 10% lift is almost never caught (at most 8% of the time).
- With no lift added, no design flagged a single window. On 9 to 15 windows per setting that can't pin the false-positive rate down, but it points to a conservative test.
- The fake lifts centre on -4%, not zero: in spring 2013 the mid-size markets drifted down against the rest. So estimates read low. A worked example on the last 6 weeks: a true +10% comes out as +5.3% (placebo p = 0.11, not significant); a true +15% comes out as +10.1% (p = 0.01). A plain difference-in-differences against the total of all other markets says +2.8% for the 10% case.

In markets this size, a geo test is only worth running for big swings (TV, a market launch, pulling all paid spend), or pooled across many markets. The drift matters for any real readout too: when the placebos don't centre on zero, the point estimate is off by about that much.

---

## Repo layout

```
sql/
  00_load.sql               parquet view, p-value helpers (normal CDF, chi-square)
  01_staging.sql            impressions and searches tables, full-list flags
  02_checks.sql             sampling, assignment by site and week, balance, fill rates
  03_position_effect.sql    click curve by slot, blocks, after-click conversion
  04_ab_test.sql            the A/B test, segments, adjacent slots, CUPED, same-hotel check
  05_ranked_vs_random.sql   naive comparison and the site-standardised one
  06_power.sql              MDE and sample size, within- and between-search
  07_geo_panel.sql          weekly market panel for the geo work
  08_dashboard.sql          aggregated tables for Tableau
stats/
  aa_and_peeking.py         A/A simulations, peeking, O'Brien-Fleming
  geo_lift.py               synthetic control, placebo inference, power curve
scripts/
  prepare_data.py           data.zip -> data/train.parquet
  build.py                  runs sql/ and exports results
notebooks/                  the Kaggle notebook
```

## Run it

```bash
python3 -m venv .venv && source .venv/bin/activate    # tested with Python 3.14
pip install -r requirements.txt
python scripts/prepare_data.py ~/Downloads/data.zip   # from the Kaggle competition page
python scripts/build.py                               # about 10 seconds
python stats/aa_and_peeking.py                        # about 1 to 1.5 minutes
python stats/geo_lift.py                              # a few seconds
```

`prepare_data.py` extracts `train.csv` with the system `unzip` command, because Kaggle's `data.zip` uses Deflate64 compression, which Python's zipfile module can't read. You can also unzip it yourself and pass `train.csv` instead.

Outputs go to `results/` and `dashboard/`, both git-ignored.

## Methods, with references

- Delta method for ratio metrics with clustered units: Deng, Knoblich and Lu (2018), *Applying the Delta Method in Metric Analytics*
- CUPED: Deng, Xu, Kohavi and Walker (2013), *Improving the Sensitivity of Online Controlled Experiments by Utilizing Pre-Experiment Data*
- Benjamini-Hochberg (1995) for multiple comparisons
- Synthetic control and placebo inference: Abadie, Diamond and Hainmueller (2010)
- Group sequential boundaries: O'Brien and Fleming (1979)
- Using this dataset's random ranking to measure position effects: Ursu (2018), *The Power of Rankings*, Marketing Science

## Limits

- The file is a sample selected on clicks and bookings. Absolute rates are not Expedia's real rates; differences inside the random group are what's trustworthy.
- Slot effects are measured on a list where everything else is shuffled. A hotel moving up in a real ranking also pushes another one down, which this doesn't capture.
- Conversion after a click compares the people who chose to click, so it isn't a clean randomised comparison the way clicks and bookings per impression are.
- Geo-lift results are a design exercise on simulated lifts, with coarse power estimates (9 to 15 test windows per setting) and a small placebo pool.
- Country and site ids are anonymised in the source.

Data: [Personalize Expedia Hotel Searches, ICDM 2013](https://www.kaggle.com/c/expedia-personalized-sort), used under the competition rules.
