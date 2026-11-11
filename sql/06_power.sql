-- 06_power.sql
-- What a test on this traffic can detect, worked out from the variance
-- actually observed, not from a textbook p(1-p) guess.
--
-- Two designs:
--
--   within-search (pow_mde, pow_sample_size): the slot test in 04. Every
--   search has hotels in both arms (some in 1-4, some in 6-10), so each
--   search is compared with itself.
--
--   between-search (pow_between): the usual product test, where whole
--   searches are split 50/50, say old ranking vs new ranking. Each search
--   sits in one arm.
--
-- They use different metrics (click-through on nine top slots vs on the whole
-- list), so compare metrics within a design, not across designs.
--
-- From ab_results: se = sigma / sqrt(n searches), so sigma = se * sqrt(n).
-- Minimum detectable effect at 80% power and 5% two-sided:
--   within-search    MDE = (1.96 + 0.84) * sigma / sqrt(n)
--   between-search   MDE = (1.96 + 0.84) * 2 * sigma / sqrt(n)    (n/2 per arm)
-- and the searches needed for a relative lift L on a control rate c:
--   n = ((1.96 + 0.84) * sigma / (L * c))^2, times 4 for between-search.
--
-- Traffic = the random-order searches in this file, a sample of Expedia's
-- real traffic, per 7 days over the days the file covers. The slot test only uses searches with all nine top slots
-- (1-4 and 6-10, 88% of them), and "booked after click" only exists in
-- searches with a click in those slots (52%), so traffic is scaled by those
-- shares. The weeks are illustrative; the ratios between metrics and between
-- designs are the useful part.


create or replace view pow_traffic as
select
    count(*)                                                    as random_searches,
    datediff('day', min(search_date), max(search_date)) + 1     as days,
    round((datediff('day', min(search_date), max(search_date)) + 1) / 7.0, 1) as weeks,
    round(count(*) * 7.0 / (datediff('day', min(search_date), max(search_date)) + 1)) as random_searches_per_week
from searches
where is_random;


create or replace view pow_mde as
with s as (
    select
        metric,
        control,
        se_diff * sqrt(searches)                                as sigma,
        searches * 1.0 / (select random_searches from pow_traffic) as share_of_searches,
        se_ratio_vs_naive
    from ab_results
    where test = 'top slots' and dim = 'all'
),
t as (select random_searches * 7.0 / days as per_week from pow_traffic),
weeks as (select unnest([1, 2, 4, 8, 16]) as w)
select
    s.metric,
    w.w                                                         as weeks,
    cast(w.w * t.per_week * s.share_of_searches as int)         as searches,
    round(100 * 2.8 * s.sigma / sqrt(w.w * t.per_week * s.share_of_searches) / s.control, 1) as mde_relative_pct,
    round(s.se_ratio_vs_naive, 2)                               as se_vs_naive
from s
cross join t
cross join weeks w
order by s.metric, w.w;


-- how many random-order searches it takes to detect a given relative lift
create or replace view pow_sample_size as
with s as (
    select
        metric, control, se_diff * sqrt(searches) as sigma,
        searches * 1.0 / (select random_searches from pow_traffic) as share_of_searches
    from ab_results
    where test = 'top slots' and dim = 'all'
),
t as (select random_searches * 7.0 / days as per_week from pow_traffic),
lifts as (select unnest([0.02, 0.05, 0.10, 0.20]) as lift)
select
    s.metric,
    round(100 * l.lift)                                         as lift_pct,
    cast(ceil(pow(2.8 * s.sigma / (l.lift * s.control), 2)) as bigint) as searches_needed,
    round(pow(2.8 * s.sigma / (l.lift * s.control), 2) / (t.per_week * s.share_of_searches), 1) as weeks_of_random_traffic
from s
cross join lifts l
cross join t
order by s.metric, l.lift;


-- Between-search design. Metrics per search: click-through (clicks / hotels
-- shown, a ratio, so sigma comes from the same delta-method linearisation as
-- 04), booking rate and booking value per search.
-- Caveat: every search in this file has at least one click (02). Real traffic
-- has many searches with none, so click-through varies more there and the
-- CTR row below is optimistic. The booking rows don't have that problem to
-- the same degree, but their base rate is set by the sampling too.
create or replace view pow_between as
with s as (
    select
        clicks * 1.0                                            as clicks,
        hotels_shown * 1.0                                      as shown,
        case when has_booking then 1.0 else 0 end               as booked,
        booking_value
    from searches
    where is_random
),
m as (
    select sum(clicks) / sum(shown) as ctr, avg(shown) as shown_bar from s
),
sig as (
    select 'ctr' as metric, any_value(m.ctr) as mean,
           stddev_samp((s.clicks - m.ctr * s.shown) / m.shown_bar) as sigma
    from s cross join m
    union all
    select 'booking rate per search', avg(booked), stddev_samp(booked) from s
    union all
    select 'booking value per search', avg(booking_value), stddev_samp(booking_value) from s
),
t as (select random_searches * 7.0 / days as per_week from pow_traffic),
weeks as (select unnest([1, 2, 4, 8, 16]) as w)
select
    sig.metric,
    w.w                                                         as weeks,
    cast(w.w * t.per_week as int)                               as searches,
    round(100 * 2.8 * 2 * sig.sigma / sqrt(w.w * t.per_week) / sig.mean, 1) as mde_relative_pct,
    round(pow(2.8 * 2 * sig.sigma / (0.05 * sig.mean), 2) / t.per_week, 1)   as weeks_for_5pct_lift
from sig
cross join t
cross join weeks w
order by sig.metric, w.w;
