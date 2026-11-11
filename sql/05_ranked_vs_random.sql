-- 05_ranked_vs_random.sql
-- The comparison everyone wants first: Expedia's ranking against random order.
--
-- The naive version (booking rate per search) is in rank_naive and it's
-- meaningless here, see 02: the two groups were sampled differently.
--
-- What can be compared: searches that ended in a booking. Assuming Expedia
-- kept booked searches at a similar rate in both groups, the booked searches
-- in each group are a fair sample of booked searches under that ordering.
-- Caveats:
--   * conditioning on "booked" is conditioning on an outcome. If the ranking
--     changes WHO books, the groups differ for that reason too.
--   * the random share differs by site (02), so every comparison here is done
--     within site and then averaged with the same site weights for both arms
--     (direct standardisation).


-- 1. The naive readout, kept so the mistake is visible
create or replace view rank_naive as
select
    case when is_random then 'random order' else 'Expedia ranking' end as arm,
    count(*)                                                    as searches,
    round(100.0 * avg(case when has_booking then 1 else 0 end), 1) as booking_rate_pct,
    'not comparable: sampling differs by arm'                   as note
from searches
group by 1
order by 1;


-- 2. Booked searches, compared within site
create or replace table rank_booked as
select
    s.srch_id,
    s.site_id,
    s.is_random,
    s.booked_position,
    case when s.booked_position <= 4 then 1.0 else 0 end        as booked_in_top4,
    s.clicks,
    s.deepest_click_position,
    s.booking_value,
    i.price_pct_in_search                                       as booked_price_pct,
    i.stars                                                     as booked_stars,
    i.review_score                                              as booked_review
from searches s
join impressions i on i.srch_id = s.srch_id and i.booked
where s.has_booking;


create or replace view rank_booked_compare as
with long as (
    select site_id, is_random, 'position of booked hotel' as metric, booked_position * 1.0 as v from rank_booked
    union all select site_id, is_random, 'share booked from slots 1-4', booked_in_top4 from rank_booked
    union all select site_id, is_random, 'hotels clicked', clicks * 1.0 from rank_booked
    union all select site_id, is_random, 'deepest click position', deepest_click_position * 1.0 from rank_booked
    union all select site_id, is_random, 'booked hotel price percentile in search', booked_price_pct from rank_booked
    union all select site_id, is_random, 'booked hotel stars', booked_stars * 1.0 from rank_booked where booked_stars is not null
    union all select site_id, is_random, 'booked hotel review score', booked_review from rank_booked where booked_review is not null
    union all select site_id, is_random, 'booking value (USD)', booking_value from rank_booked where booking_value > 0
),
by_site as (
    select
        metric, site_id,
        avg(v) filter (where not is_random)                     as m_ranked,
        avg(v) filter (where is_random)                         as m_random,
        var_samp(v) filter (where not is_random)                as v_ranked,
        var_samp(v) filter (where is_random)                    as v_random,
        count(*) filter (where not is_random)                   as n_ranked,
        count(*) filter (where is_random)                       as n_random,
        count(*)                                                as n
    from long
    group by metric, site_id
    -- a site needs both arms (and a few of each) to be compared within
    having count(*) filter (where is_random) >= 20 and count(*) filter (where not is_random) >= 20
),
w as (
    select *, n * 1.0 / sum(n) over (partition by metric) as wt from by_site
),
raw as (
    select
        metric,
        avg(v) filter (where not is_random)                     as raw_ranked,
        avg(v) filter (where is_random)                         as raw_random
    from long
    group by metric
)
select
    w.metric,
    count(*)                                                    as sites_used,
    sum(w.n_ranked)                                             as booked_ranked,
    sum(w.n_random)                                             as booked_random,
    round(max(r.raw_ranked), 3)                                 as raw_ranked,
    round(max(r.raw_random), 3)                                 as raw_random,
    round(sum(w.wt * w.m_ranked), 3)                            as std_ranked,
    round(sum(w.wt * w.m_random), 3)                            as std_random,
    round(sum(w.wt * (w.m_ranked - w.m_random)), 3)             as diff,
    round(1.96 * sqrt(sum(w.wt * w.wt * (w.v_ranked / w.n_ranked + w.v_random / w.n_random))), 3) as ci95,
    p_two_sided(sum(w.wt * (w.m_ranked - w.m_random))
                / sqrt(sum(w.wt * w.wt * (w.v_ranked / w.n_ranked + w.v_random / w.n_random)))) as p_value
from w
join raw r on r.metric = w.metric
group by w.metric
order by case w.metric
    when 'position of booked hotel' then 1 when 'share booked from slots 1-4' then 2
    when 'hotels clicked' then 3 when 'deepest click position' then 4
    when 'booked hotel price percentile in search' then 5 when 'booked hotel stars' then 6
    when 'booked hotel review score' then 7 else 8 end;
