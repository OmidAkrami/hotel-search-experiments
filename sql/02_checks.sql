-- 02_checks.sql
-- What has to be true before any test result means anything.


-- 1. Size of things
create or replace view chk_overview as
select
    count(*)                                                    as impressions,
    count(distinct srch_id)                                     as searches,
    count(distinct hotel_id)                                    as hotels,
    count(distinct destination_id)                              as destinations,
    count(distinct site_id)                                     as sites,
    min(search_date)                                            as first_day,
    max(search_date)                                            as last_day,
    round(100.0 * count(distinct srch_id) filter (where is_random)
          / count(distinct srch_id), 1)                         as pct_searches_random
from impressions;


-- 2. How the file was sampled. Every single search has at least one click,
-- in both groups. Then 94% of ranked searches end in a booking against 13%
-- of random ones. A ranking 7x better than shuffling isn't believable; the
-- likely story is that Expedia sampled the two groups differently and kept
-- ranked searches with a booking far more often. Either way, booking rates
-- between the groups say nothing about the ranking. See 05 for what can be
-- compared.
create or replace view chk_sampling as
select
    case when is_random then 'random order' else 'Expedia ranking' end as arm,
    count(*)                                                    as searches,
    round(100.0 * avg(case when clicks > 0 then 1 else 0 end), 1) as pct_with_click,
    round(100.0 * avg(case when has_booking then 1 else 0 end), 1) as pct_with_booking,
    round(avg(clicks), 3)                                       as clicks_per_search,
    round(100.0 * avg(case when clicks = 1 then 1 else 0 end), 1) as pct_exactly_one_click
from searches
group by 1
order by 1;


-- 3. Assignment to random order was not the same everywhere. Among sites with
-- 1,000+ searches the random share goes from 0% to 51% (one tiny site goes
-- higher), and the chi-square test of "same share on every site" is off the
-- scale. So:
--   * comparing the two arms needs to be done within site (05 does that)
--   * inside the random arm nothing changes: positions are shuffled within
--     each search, so site mix can't line up with position
create or replace view chk_assignment_by_site as
with s as (
    select site_id, count(*) as searches, count(*) filter (where is_random) as random_searches
    from searches
    group by site_id
),
tot as (
    select sum(random_searches) * 1.0 / sum(searches) as p from s
)
select
    s.site_id,
    s.searches,
    s.random_searches,
    round(100.0 * s.random_searches / s.searches, 1)            as pct_random,
    round((s.random_searches - s.searches * t.p) / sqrt(s.searches * t.p * (1 - t.p)), 1) as z_vs_overall
from s
cross join tot t
order by s.searches desc;


-- The chi-square approximation needs an expected count of 5+ in every cell,
-- so sites too small for that are left out (sites_used shows how many stay).
create or replace view chk_assignment_test as
with s as (
    select site_id, count(*) as n, count(*) filter (where is_random) as r
    from searches
    group by site_id
),
p_all as (select sum(r) * 1.0 / sum(n) as p from s),
kept as (
    select s.*
    from s cross join p_all a
    where s.n * a.p >= 5 and s.n * (1 - a.p) >= 5
),
tot as (select sum(r) * 1.0 / sum(n) as p, count(*) as k from kept),
cells as (
    select
        pow(s.r - s.n * t.p, 2) / (s.n * t.p)
      + pow((s.n - s.r) - s.n * (1 - t.p), 2) / (s.n * (1 - t.p)) as contrib
    from kept s cross join tot t
)
select
    'same random share on every site'                           as hypothesis,
    (select count(*) from s)                                    as sites,
    (select k from tot)                                         as sites_used,
    (select k from tot) - 1                                     as dof,
    round(sum(contrib), 1)                                      as chi_square,
    chisq_p(sum(contrib), (select k from tot) - 1)              as p_value
from cells;


-- 4. Over time the share stays between 27% and 33% a week. That's more
-- wobble than pure chance at ~11k searches a week, which fits the site mix
-- shifting from week to week (shares differ by site, see 3). No sign of the
-- test being switched on or off midway.
create or replace view chk_assignment_by_week as
select
    week_start(search_date)                                     as week,
    count(*)                                                    as searches,
    round(100.0 * avg(case when is_random then 1 else 0 end), 1) as pct_random
from searches
group by 1
order by 1;


-- 5. Impressions per slot in the random arm. 5, 11, 17 and 23 are nearly empty.
create or replace view chk_slot_counts as
select
    position,
    count(*)                                                    as impressions,
    reserved_slot
from impressions
where is_random
group by position, reserved_slot
order by position;


-- 6. Randomisation check inside the random arm: are the hotels in slots 1-4
-- the same kind as the hotels in slots 6-10? If the shuffle is random they
-- should be, give or take noise. Standardised mean difference (SMD): the gap
-- in means divided by the pooled standard deviation. Under 0.1 is the usual
-- "balanced" bar. The ranked arm is there for contrast.
--
-- Result: stars, price, review score, chain, promotion and location score 1
-- are balanced. Location score 2 is not: top slots get hotels with slightly
-- better scores and far fewer missing ones. The share missing climbs steadily
-- from 11% at slot 1 to 24% at slot 14 (8% to 17% among searches that show
-- all 34 slots, so list length isn't behind it; see chk_loc2_by_slot). I
-- read that as a shuffle that wasn't fully uniform, more than an effect of
-- the "at least one click" sampling: location score 2 barely predicts clicks
-- (correlation 0.06, chk_loc2_click_corr). 04 checks the main result with a
-- same-hotel comparison and a regression adjustment.
create or replace view chk_balance_top_vs_next as
with b as (
    select
        is_random,
        slot_block = '1-4'                                      as top,
        stars, review_score, price_pct_in_search, loc_score1, loc_score2,
        case when loc_score2 is null then 1.0 else 0 end        as loc2_missing,
        case when is_chain then 1.0 else 0 end                  as chain,
        case when on_promotion then 1.0 else 0 end              as promo
    from impressions
    where slot_block in ('1-4', '6-10') and not reserved_slot
      -- same searches as the test in 04
      and srch_id in (select srch_id from searches where full_top10)
),
long as (
    select is_random, top, 'stars' as covariate, stars as v from b
    union all select is_random, top, 'review score', review_score from b
    union all select is_random, top, 'price percentile in search', price_pct_in_search from b
    union all select is_random, top, 'location score 1', loc_score1 from b
    union all select is_random, top, 'location score 2', loc_score2 from b
    union all select is_random, top, 'location score 2 missing', loc2_missing from b
    union all select is_random, top, 'chain hotel', chain from b
    union all select is_random, top, 'on promotion', promo from b
),
m as (
    select
        is_random, covariate,
        avg(v) filter (where top)                               as mean_top,
        avg(v) filter (where not top)                           as mean_next,
        var_samp(v) filter (where top)                          as var_top,
        var_samp(v) filter (where not top)                      as var_next
    from long
    group by is_random, covariate
)
select
    case when is_random then 'random order' else 'Expedia ranking' end as arm,
    covariate,
    round(mean_top, 4)                                          as slots_1_4,
    round(mean_next, 4)                                         as slots_6_10,
    round((mean_top - mean_next) / sqrt((var_top + var_next) / 2), 3) as smd,
    abs((mean_top - mean_next) / sqrt((var_top + var_next) / 2)) < 0.1 as balanced
from m
order by arm desc, abs((mean_top - mean_next) / sqrt((var_top + var_next) / 2)) desc;


-- Location score 2 missing share by slot in the random arm: all searches,
-- and only searches that show all 34 slots (so list length can't explain it)
create or replace view chk_loc2_by_slot as
select
    position,
    count(*)                                                    as impressions,
    round(100 * avg(case when loc_score2 is null then 1.0 else 0 end), 1) as pct_missing_all_searches,
    round(100 * avg(case when loc_score2 is null then 1.0 else 0 end)
          filter (where srch_id in (select srch_id from searches where full_top34)), 1) as pct_missing_full_top34
from impressions
where is_random and not reserved_slot and position <= 34
group by position
order by position;


-- How much location score 2 says about a click, in the test population of 04
create or replace view chk_loc2_click_corr as
select
    count(loc_score2)                                           as impressions_with_score,
    round(corr(case when clicked then 1.0 else 0 end, loc_score2), 3) as corr_click_loc_score2
from impressions
where is_random and not reserved_slot and slot_block in ('1-4', '6-10')
  and srch_id in (select srch_id from searches where full_top10);


-- 7. Missing values in the fields used later
create or replace view chk_fill_rates as
select
    round(100.0 * count(stars) / count(*), 1)                   as pct_stars,
    round(100.0 * count(review_score) / count(*), 1)            as pct_review_score,
    round(100.0 * count(loc_score2) / count(*), 1)              as pct_loc_score2,
    round(100.0 * count(price_usd) / count(*), 1)               as pct_price,
    round(100.0 * count(*) filter (where booked and booking_value > 0)
          / nullif(count(*) filter (where booked), 0), 2)        as pct_bookings_with_value
from impressions;
