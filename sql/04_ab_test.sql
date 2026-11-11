-- 04_ab_test.sql
-- The A/B test: does showing a hotel in slots 1-4 instead of slots 6-10 change
-- what users do with it?
--
--   population   random-order searches that show all nine slots 1-4 and 6-10
--   unit         a hotel impression
--   treatment    shown in slots 1-4
--   control      shown in slots 6-10
--   primary      click-through rate
--   secondary    bookings per impression, booking value per impression,
--                share of clicks that end in a booking
--
-- The full-list filter matters. A search with 7 hotels has four in slots 1-4
-- and only three in 6-10 (slot 5 is reserved), and short lists have a high
-- click-through per hotel. Counting every search gives slots 1-4 more of
-- those easy impressions and adds about 7 points of lift (83.2% vs 76.6%,
-- see ab_list_length) that has nothing to do with position.
--
-- Impressions aren't independent: the ~25 hotels in one search share one
-- user, who clicks about once. So the error is computed with the search as
-- the unit. Every metric is a ratio (sum of x / sum of y), and the standard
-- error comes from the delta method with searches as clusters (Deng, Knoblich
-- & Lu 2018, "Applying the Delta Method in Metric Analytics"):
--
--   r = sum(num) / sum(den) per arm, n = searches in the test
--   per search: u = (num_T - r_T * den_T) / mean_den_T - (num_C - r_C * den_C) / mean_den_C
--   se(r_T - r_C) = sqrt(sum(u^2)) / n
--
-- Treatment and control impressions come from the same searches, and taking
-- the difference per search before squaring accounts for that covariance.
-- Same idea on the log scale for the relative lift.
--
-- Everything goes into one long table (ab_units) so a single query does the
-- maths for every test, metric and segment.


-- covariate for the CUPED run (section 4): how click-prone is a hotel of
-- this kind, measured only on searches before 1 Feb 2013 so it can't be
-- affected by anything later. "Kind" = stars x review band x price third
-- x location score 2 band x chain. Expressed as observed / expected clicks,
-- where expected uses the slot click-through, so slot luck doesn't leak in.
create or replace table cuped_cells as
with pre as (
    select *
    from impressions
    where is_random and not reserved_slot and search_date < date '2013-02-01'
),
slot_ctr as (
    select position, avg(case when clicked then 1.0 else 0 end) as ctr
    from pre
    group by position
),
banded as (
    select
        p.*,
        s.ctr                                                   as expected,
        coalesce(cast(p.stars as varchar), '?')                 as star_band,
        case when p.review_score is null then 'none'
             when p.review_score < 3.5 then 'low'
             when p.review_score < 4.5 then 'mid' else 'high' end as review_band,
        case when p.price_pct_in_search < 1.0 / 3 then 'cheap'
             when p.price_pct_in_search < 2.0 / 3 then 'mid' else 'pricey' end as price_band,
        case when p.loc_score2 is null then 'missing'
             else cast(least(floor(p.loc_score2 / 0.05), 6) as varchar) end as loc_band
    from pre p
    join slot_ctr s on s.position = p.position
)
select
    star_band, review_band, price_band, loc_band, is_chain,
    count(*)                                                    as impressions,
    sum(case when clicked then 1.0 else 0 end) / sum(expected)  as attractiveness
from banded
group by all
having count(*) >= 200;


-- The CUPED population: the test's impressions from Feb-Jun searches, each
-- with its covariate x (1.0 for hotel kinds with no pre-period cell).
create or replace table cuped_units as
with t as (
    select
        i.srch_id,
        case when i.slot_block = '1-4' then 'T' else 'C' end    as arm,
        case when i.clicked then 1.0 else 0 end                 as click,
        coalesce(cast(i.stars as varchar), '?')                 as star_band,
        case when i.review_score is null then 'none'
             when i.review_score < 3.5 then 'low'
             when i.review_score < 4.5 then 'mid' else 'high' end as review_band,
        case when i.price_pct_in_search < 1.0 / 3 then 'cheap'
             when i.price_pct_in_search < 2.0 / 3 then 'mid' else 'pricey' end as price_band,
        case when i.loc_score2 is null then 'missing'
             else cast(least(floor(i.loc_score2 / 0.05), 6) as varchar) end as loc_band,
        i.is_chain
    from impressions i
    where i.is_random and not i.reserved_slot and i.slot_block in ('1-4', '6-10')
      and i.search_date >= date '2013-02-01'
      and i.srch_id in (select srch_id from searches where full_top10)
)
select t.srch_id, t.arm, t.click, coalesce(c.attractiveness, 1.0) as x
from t
left join cuped_cells c
  on c.star_band = t.star_band and c.review_band = t.review_band
 and c.price_band = t.price_band and c.loc_band = t.loc_band and c.is_chain = t.is_chain;


-- theta is the slope of click on x within arms: the coefficient a regression
-- of click on arm and x gives. Pooling the arms instead would let the gap
-- between them leak into theta, because x isn't balanced between the arms
-- here (the location score 2 imbalance, see 02).
create or replace view ab_cuped_covariate as
with m as (
    select
        *,
        avg(click) over (partition by arm)                      as click_arm_mean,
        avg(x) over (partition by arm)                          as x_arm_mean
    from cuped_units
)
select
    count(*)                                                    as impressions,
    corr(click, x)                                              as corr_click_x,
    sum((click - click_arm_mean) * (x - x_arm_mean))
        / sum(pow(x - x_arm_mean, 2))                           as theta,
    avg(x)                                                      as x_mean,
    avg(x) filter (where arm = 'T')                             as x_mean_slots_1_4,
    avg(x) filter (where arm = 'C')                             as x_mean_slots_6_10
from m;


create or replace table ab_units as
with base as (
    select
        i.*,
        case when i.slot_block = '1-4' then 'T' when i.slot_block = '6-10' then 'C' end as arm,
        case when i.clicked then 1.0 else 0 end                 as click,
        case when i.booked then 1.0 else 0 end                  as booking,
        coalesce(cast(i.stars as varchar), '?')                 as star_band,
        case when i.review_score is null then 'none'
             when i.review_score < 3.5 then 'low'
             when i.review_score < 4.5 then 'mid' else 'high' end as review_band,
        case when i.price_pct_in_search < 1.0 / 3 then 'cheap'
             when i.price_pct_in_search < 2.0 / 3 then 'mid' else 'pricey' end as price_band,
        case when i.loc_score2 is null then 'missing'
             else cast(least(floor(i.loc_score2 / 0.05), 6) as varchar) end as loc_band
    from impressions i
    where i.is_random and not i.reserved_slot
),
top as (
    select *
    from base
    where arm is not null
      and srch_id in (select srch_id from searches where full_top10)
),
seg as (
    -- one row per impression per segment dimension it belongs to
    select srch_id, arm, click, 'hotel stars' as dim,
           case when stars is null then 'unknown' when stars <= 2 then '1-2 stars'
                when stars = 3 then '3 stars' else '4-5 stars' end as segment from top
    union all
    select srch_id, arm, click, 'review score',
           case when review_score is null then 'no reviews' when review_score < 3.5 then 'under 3.5'
                when review_score < 4.5 then '3.5 to 4' else '4.5 to 5' end from top
    union all
    select srch_id, arm, click, 'price within search',
           case when price_band = 'cheap' then 'cheapest third' when price_band = 'mid' then 'middle third'
                else 'priciest third' end from top
    union all
    select srch_id, arm, click, 'booking window',
           case when days_ahead <= 3 then '0-3 days' when days_ahead <= 30 then '4-30 days'
                else '31+ days' end from top
    union all
    select srch_id, arm, click, 'length of stay',
           case when nights = 1 then '1 night' when nights <= 3 then '2-3 nights' else '4+ nights' end from top
    union all
    select srch_id, arm, click, 'party',
           case when children > 0 then 'with children' else 'adults only' end from top
    union all
    select srch_id, arm, click, 'visitor',
           case when visitor_country = 219 then 'country 219 (largest)' else 'all other countries' end from top
    union all
    select srch_id, arm, click, 'hotel type',
           case when is_chain then 'chain' else 'independent' end from top
    union all
    select srch_id, arm, click, 'promotion',
           case when on_promotion then 'on promotion' else 'no promotion' end from top
),
pairs as (
    -- each non-reserved slot and the next one down, to slot 37 (32 pairs)
    select position as upper_slot, lead(position) over (order by position) as lower_slot
    from (select distinct position from base where position <= 37) d
),
pair_rows as (
    -- only searches that show both slots of the pair, so each pair is
    -- compared inside the same searches
    select
        'slot ' || p.upper_slot || ' vs ' || p.lower_slot        as segment,
        a.srch_id,
        a.click                                                 as click_upper,
        b.click                                                 as click_lower
    from pairs p
    join base a on a.position = p.upper_slot
    join base b on b.srch_id = a.srch_id and b.position = p.lower_slot
    where p.lower_slot is not null
),
adjacent as (
    select segment, srch_id, 'T' as arm, click_upper as click from pair_rows
    union all
    select segment, srch_id, 'C', click_lower from pair_rows
),
cuped as (
    select srch_id, arm, click, x from cuped_units
),
cuped_theta as (
    select theta, x_mean from ab_cuped_covariate
)
-- main test, four metrics
select 'top slots' as test, 'ctr' as metric, 'all' as dim, 'all' as segment,
       srch_id, arm, sum(click) as num, count(*) as den
from top group by all
union all
select 'top slots', 'bookings per impression', 'all', 'all', srch_id, arm, sum(booking), count(*)
from top group by all
union all
select 'top slots', 'booking value per impression', 'all', 'all', srch_id, arm, sum(booking_value), count(*)
from top group by all
union all
select 'top slots', 'booked after click', 'all', 'all', srch_id, arm, sum(booking), sum(click)
from top where clicked group by all
-- segments
union all
select 'top slots', 'ctr', dim, segment, srch_id, arm, sum(click), count(*)
from seg group by all
-- adjacent slots
union all
select 'adjacent slots', 'ctr', 'slot pair', segment, srch_id, arm, sum(click), count(*)
from adjacent group by all
-- CUPED: same test on Feb-Jun searches, raw and adjusted
union all
select 'top slots, Feb-Jun', 'ctr', 'cuped', 'unadjusted', srch_id, arm, sum(click), count(*)
from cuped group by all
union all
select 'top slots, Feb-Jun', 'ctr', 'cuped', 'adjusted', c.srch_id, c.arm,
       sum(c.click - t.theta * (c.x - t.x_mean)), count(*)
from cuped c cross join cuped_theta t group by all;


-- 1. The stats engine: one row per test / metric / segment
create or replace view ab_results as
with tot as (
    select
        test, metric, dim, segment,
        count(distinct srch_id)                                 as searches,
        sum(num) filter (where arm = 'T')                       as num_t,
        sum(den) filter (where arm = 'T')                       as den_t,
        sum(num) filter (where arm = 'C')                       as num_c,
        sum(den) filter (where arm = 'C')                       as den_c
    from ab_units
    group by all
),
est as (
    select
        *,
        num_t / den_t                                           as r_t,
        num_c / den_c                                           as r_c,
        den_t / searches                                        as xbar_t,
        den_c / searches                                        as xbar_c
    from tot
),
lin as (
    select
        u.test, u.metric, u.dim, u.segment, u.srch_id,
        sum(case when u.arm = 'T' then (u.num - e.r_t * u.den) / e.xbar_t else 0 end) as u_t,
        sum(case when u.arm = 'C' then (u.num - e.r_c * u.den) / e.xbar_c else 0 end) as u_c
    from ab_units u
    join est e using (test, metric, dim, segment)
    group by all
),
var as (
    select
        l.test, l.metric, l.dim, l.segment,
        sqrt(sum(pow(l.u_t - l.u_c, 2))) / max(e.searches)      as se_diff,
        sqrt(sum(pow(l.u_t / nullif(e.r_t, 0) - l.u_c / nullif(e.r_c, 0), 2))) / max(e.searches) as se_log_ratio
    from lin l
    join est e using (test, metric, dim, segment)
    group by all
)
select
    e.test,
    e.metric,
    e.dim,
    e.segment,
    e.searches,
    cast(e.den_t as bigint)                                     as denom_t,
    cast(e.den_c as bigint)                                     as denom_c,
    e.r_t                                                       as treatment,
    e.r_c                                                       as control,
    e.r_t - e.r_c                                               as diff,
    v.se_diff,
    v.se_log_ratio,
    e.r_t - e.r_c - 1.96 * v.se_diff                            as diff_lo,
    e.r_t - e.r_c + 1.96 * v.se_diff                            as diff_hi,
    e.r_t / e.r_c - 1                                           as rel_lift,
    exp(ln(e.r_t / e.r_c) - 1.96 * v.se_log_ratio) - 1         as rel_lift_lo,
    exp(ln(e.r_t / e.r_c) + 1.96 * v.se_log_ratio) - 1         as rel_lift_hi,
    (e.r_t - e.r_c) / v.se_diff                                 as z,
    p_two_sided((e.r_t - e.r_c) / v.se_diff)                    as p_value,
    -- what a plain two-proportion test would say (binary metrics only)
    case when e.metric <> 'booking value per impression'
         then sqrt(e.r_t * (1 - e.r_t) / e.den_t + e.r_c * (1 - e.r_c) / e.den_c) end as naive_se,
    case when e.metric <> 'booking value per impression'
         then v.se_diff / sqrt(e.r_t * (1 - e.r_t) / e.den_t + e.r_c * (1 - e.r_c) / e.den_c) end as se_ratio_vs_naive
from est e
join var v using (test, metric, dim, segment)
order by e.test, e.metric, e.dim, e.segment;


-- 2. Headline readout, rounded for people
create or replace view ab_headline as
select
    metric,
    searches,
    denom_t                                                     as impressions_t,
    denom_c                                                     as impressions_c,
    round(case when metric = 'booking value per impression' then treatment else 100 * treatment end, 3) as treatment,
    round(case when metric = 'booking value per impression' then control else 100 * control end, 3) as control,
    case when metric = 'booking value per impression' then 'USD' else '%' end as unit,
    round(100 * rel_lift, 1)                                    as lift_pct,
    round(100 * rel_lift_lo, 1)                                 as lift_lo,
    round(100 * rel_lift_hi, 1)                                 as lift_hi,
    round(z, 1)                                                 as z,
    p_value,
    round(se_ratio_vs_naive, 2)                                 as se_vs_naive
from ab_results
where test = 'top slots' and dim = 'all'
order by case metric when 'ctr' then 1 when 'bookings per impression' then 2
                     when 'booking value per impression' then 3 else 4 end;


-- 3. Who reacts most to position? Lift of slots 1-4 over 6-10 by segment,
-- on two scales: relative (lift %) and absolute (extra clicks per 100
-- impressions). They answer different questions. A segment with a low base
-- click-through can show a bigger relative lift for the same absolute gain.
-- Each level is tested against the first level of its dimension, on both
-- scales. 16 comparisons per scale, so p-values are adjusted with
-- Benjamini-Hochberg: sort p ascending, adjusted p = min over k >= i of
-- p_k * m / k, done with a window running from the largest p down.
-- Segments of one dimension share searches (a search shows hotels from
-- several segments), so the two estimates in a comparison are correlated.
-- Each estimate is linearised per search (delta method) and the error of the
-- difference comes from the per-search difference of those terms, which
-- carries the covariance, the same way the main test handles 1-4 vs 6-10.
create or replace view ab_segments as
with s as (
    select
        dim, segment, searches, denom_t, denom_c, treatment, control,
        diff, se_diff,
        ln(treatment / control)                                 as log_lift,
        se_log_ratio,
        row_number() over (partition by dim order by segment)   as level_no
    from ab_results
    where test = 'top slots' and metric = 'ctr' and dim not in ('all', 'cuped')
),
pairs as (
    select s.dim, s.segment, r.segment as reference
    from s
    join s r on r.dim = s.dim and r.level_no = 1
    where s.level_no > 1
),
psi as (
    -- per search and segment: the linearised gain (absolute scale) and log
    -- lift (relative scale), slots 1-4 minus slots 6-10
    select
        u.dim, u.segment, u.srch_id,
        sum(case when u.arm = 'T' then (u.num - s.treatment * u.den) / s.denom_t
                 else -(u.num - s.control * u.den) / s.denom_c end) as psi_gain,
        sum(case when u.arm = 'T' then (u.num - s.treatment * u.den) / (s.treatment * s.denom_t)
                 else -(u.num - s.control * u.den) / (s.control * s.denom_c) end) as psi_lift
    from ab_units u
    join s on s.dim = u.dim and s.segment = u.segment
    where u.test = 'top slots' and u.metric = 'ctr'
    group by u.dim, u.segment, u.srch_id
),
pair_se as (
    select dim, segment, sqrt(sum(d_gain * d_gain)) as se_gain, sqrt(sum(d_lift * d_lift)) as se_lift
    from (
        select
            p.dim, p.segment, x.srch_id,
            sum(case when x.segment = p.segment then x.psi_gain else -x.psi_gain end) as d_gain,
            sum(case when x.segment = p.segment then x.psi_lift else -x.psi_lift end) as d_lift
        from pairs p
        join psi x on x.dim = p.dim and x.segment in (p.segment, p.reference)
        group by p.dim, p.segment, x.srch_id
    )
    group by dim, segment
),
vs_ref as (
    select
        p.dim, p.segment, p.reference,
        p_two_sided((a.log_lift - r.log_lift) / e.se_lift)     as p_lift,
        p_two_sided((a.diff - r.diff) / e.se_gain)              as p_gain
    from pairs p
    join s a on a.dim = p.dim and a.segment = p.segment
    join s r on r.dim = p.dim and r.segment = p.reference
    join pair_se e on e.dim = p.dim and e.segment = p.segment
),
k as (
    select
        *,
        row_number() over (order by p_lift)                     as k_lift,
        row_number() over (order by p_gain)                     as k_gain,
        count(*) over ()                                        as m
    from vs_ref
),
bh as (
    select
        dim, segment, reference, p_lift, p_gain,
        least(1, min(p_lift * m / k_lift) over (
            order by k_lift desc rows between unbounded preceding and current row)) as p_bh_lift,
        least(1, min(p_gain * m / k_gain) over (
            order by k_gain desc rows between unbounded preceding and current row)) as p_bh_gain
    from k
)
select
    s.dim,
    s.segment,
    s.searches,
    s.denom_t + s.denom_c                                       as impressions,
    round(100 * s.treatment, 2)                                 as ctr_top_pct,
    round(100 * s.control, 2)                                   as ctr_next_pct,
    round(100 * (exp(s.log_lift) - 1), 1)                       as lift_pct,
    round(100 * (exp(s.log_lift - 1.96 * s.se_log_ratio) - 1), 1) as lift_lo,
    round(100 * (exp(s.log_lift + 1.96 * s.se_log_ratio) - 1), 1) as lift_hi,
    round(100 * s.diff, 2)                                      as gain_pts,
    round(100 * (s.diff - 1.96 * s.se_diff), 2)                 as gain_lo,
    round(100 * (s.diff + 1.96 * s.se_diff), 2)                 as gain_hi,
    b.reference                                                 as compared_with,
    round(b.p_bh_lift, 4)                                       as p_bh_lift,
    round(b.p_bh_gain, 4)                                       as p_bh_gain
from s
left join bh b on b.dim = s.dim and b.segment = s.segment
order by s.dim, s.level_no;


-- 4. Adjacent slots: is slot k really better than the next one down?
-- Each pair is compared within the searches that show both slots.
-- 32 tests, same BH treatment. Lower down the page the gaps get small enough
-- that most don't survive the correction.
create or replace view ab_adjacent as
with a as (
    select
        segment                                                 as comparison,
        cast(split_part(segment, ' ', 2) as int)                as upper_slot,
        searches,
        treatment,
        control,
        rel_lift, rel_lift_lo, rel_lift_hi,
        p_value
    from ab_results
    where test = 'adjacent slots'
),
r as (
    select *, row_number() over (order by p_value) as k, count(*) over () as m
    from a
)
select
    comparison,
    searches,
    round(100 * treatment, 2)                                   as ctr_upper_pct,
    round(100 * control, 2)                                     as ctr_lower_pct,
    round(100 * rel_lift, 1)                                    as lift_pct,
    round(100 * rel_lift_lo, 1)                                 as lift_lo,
    round(100 * rel_lift_hi, 1)                                 as lift_hi,
    round(p_value, 5)                                           as p_raw,
    round(least(1, min(p_value * m / k) over (order by k desc rows between unbounded preceding and current row)), 5) as p_bh,
    least(1, min(p_value * m / k) over (order by k desc rows between unbounded preceding and current row)) < 0.05 as significant_after_bh
from r
order by upper_slot;


-- 5. CUPED (variance reduction with a pre-experiment covariate).
-- Same test, same Feb-Jun searches, with and without the adjustment.
-- Variance reduction of v% is worth the same as running the test
-- 1 / (1 - v) times as long.
-- Result: it cuts variance by 1.5%. A single click is too noisy for hotel
-- traits to predict: the correlation between click and covariate is only
-- 0.09 (squared, under 1%). CUPED pays off on user-level
-- metrics with a strong history, like revenue per user, not on one click.
-- The adjustment does move the estimate down (4.08 to 3.86 points, +76% to
-- +71%), in line with it correcting for the location score 2 imbalance found
-- in 02 (location score 2 band is part of the covariate).
create or replace view ab_cuped as
select
    segment                                                     as version,
    searches,
    round(100 * treatment, 3)                                   as ctr_top_pct,
    round(100 * control, 3)                                     as ctr_next_pct,
    round(100 * diff, 3)                                        as diff_pts,
    round(100 * se_diff, 4)                                     as se_pts,
    round(100 * (1 - pow(se_diff / first_value(se_diff) over (order by segment desc), 2)), 1) as variance_cut_pct
from ab_results
where test = 'top slots, Feb-Jun'
order by segment desc;


-- 6. Cross-check for the imbalance found in 02: compare each hotel only with
-- itself. For hotels shown in both blocks across different random searches,
-- take CTR in slots 1-4 minus CTR in slots 6-10, and average with weights
-- n_t * n_c / (n_t + n_c), the usual precision weight for a difference.
-- Hotel quality is held fixed by construction.
-- No interval here: the weights depend on the data and many hotels appear
-- only once in a block, so closed-form errors (binomial, or clustered by
-- search) come out too narrow. The point estimate is what this check is for.
create or replace view ab_same_hotel as
with h as (
    select
        hotel_id,
        count(*) filter (where slot_block = '1-4')              as n_t,
        count(*) filter (where slot_block = '6-10')             as n_c,
        avg(case when clicked then 1.0 else 0 end) filter (where slot_block = '1-4')  as ctr_t,
        avg(case when clicked then 1.0 else 0 end) filter (where slot_block = '6-10') as ctr_c
    from impressions
    where is_random and slot_block in ('1-4', '6-10') and not reserved_slot
      and srch_id in (select srch_id from searches where full_top10)
    group by hotel_id
),
w as (
    select *, n_t * n_c * 1.0 / (n_t + n_c) as wt
    from h
    where n_t > 0 and n_c > 0
)
select
    count(*)                                                    as hotels,
    sum(n_t + n_c)                                              as impressions,
    round(100 * sum(wt * (ctr_t - ctr_c)) / sum(wt), 2)         as diff_pts,
    round(100 * sum(wt * (ctr_t - ctr_c)) / sum(wt * ctr_c), 1) as lift_pct
from w;


-- 7. Why the full-list filter: the same click-through comparison on every
-- random search (the first version of this test) and on the full-list
-- searches the test uses. Point estimates only; the second row is the same
-- comparison as ab_headline.
create or replace view ab_list_length as
with b as (
    select
        i.slot_block = '1-4'                                    as top,
        case when i.clicked then 1.0 else 0 end                 as click,
        s.full_top10
    from impressions i
    join searches s on s.srch_id = i.srch_id
    where i.is_random and not i.reserved_slot and i.slot_block in ('1-4', '6-10')
),
v as (
    select 1 as k, 'every random search' as searches_used,
           avg(click) filter (where top) as ctr_t, avg(click) filter (where not top) as ctr_c
    from b
    union all
    select 2, 'full-list searches only (full_top10)',
           avg(click) filter (where top), avg(click) filter (where not top)
    from b
    where full_top10
)
select
    searches_used,
    round(100 * ctr_t, 2)                                       as ctr_top_pct,
    round(100 * ctr_c, 2)                                       as ctr_next_pct,
    round(100 * (ctr_t / ctr_c - 1), 1)                         as lift_pct
from v
order by k;
