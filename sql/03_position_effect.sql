-- 03_position_effect.sql
-- How much does position on the page matter, on its own?
--
-- In Expedia's own ranking, slot 1 gets clicked a lot partly because it's at
-- the top and partly because the algorithm put a good hotel there. Ranked
-- results can't separate the two. In the random arm the hotel in slot 1
-- is a random one, so whatever extra clicks slot 1 gets there are caused by
-- the slot itself.
--
-- One impression per search per slot, so impressions at a given slot are
-- independent across searches and the plain binomial standard error is right
-- for a single slot. (Comparing blocks of slots needs more care, see 04.)
--
-- Only searches that show all 30 slots up to 34 are used (full_top34, see
-- 01). Without that, the top slots carry every short list and the bottom
-- slots only long ones, and the curve comes out steeper than it is.
-- About 55k random and 130k ranked searches qualify (pos_curve impressions
-- at any one slot).


-- 1. Click-through, booking and conversion-after-click by slot, both arms
create or replace view pos_curve as
with p as (
    select
        case when is_random then 'random' else 'ranked' end     as arm,
        position,
        count(*)                                                as impressions,
        count(*) filter (where clicked)                         as clicks,
        count(*) filter (where booked)                          as bookings
    from impressions
    where srch_id in (select srch_id from searches where full_top34)
      and not reserved_slot and position <= 34
    group by 1, 2
    having count(*) >= 1000
),
e as (
    select
        *,
        clicks * 1.0 / impressions                              as ctr,
        1.96 * sqrt((clicks * 1.0 / impressions) * (1 - clicks * 1.0 / impressions) / impressions) as half_width
    from p
)
select
    arm,
    position,
    impressions,
    clicks,
    bookings,
    round(100 * ctr, 2)                                         as ctr_pct,
    round(100 * half_width, 2)                                  as ctr_ci95_pts,
    round(100 * (ctr - half_width), 2)                          as ctr_lo,
    round(100 * (ctr + half_width), 2)                          as ctr_hi,
    round(100.0 * bookings / impressions, 3)                    as bookings_per_100_impressions,
    round(100.0 * bookings / nullif(clicks, 0), 1)              as booked_after_click_pct
from e
order by arm, position;


-- 2. Index: each slot's click-through relative to slot 1 in the same arm.
-- Only the random column is causal. The ranked column mixes position with
-- the ranking putting better hotels on top, and its level is also inflated by
-- the sampling (02), so the two arms aren't compared slot for slot here.
create or replace view pos_index as
with r as (
    -- unrounded click-through, so the index isn't built on rounded numbers
    select
        position,
        max(clicks * 1.0 / impressions) filter (where arm = 'random') as ctr_random,
        max(clicks * 1.0 / impressions) filter (where arm = 'ranked') as ctr_ranked
    from pos_curve
    group by position
)
select
    position,
    round(100 * ctr_random, 2)                                  as random_ctr,
    round(100 * ctr_ranked, 2)                                  as ranked_ctr,
    round(100 * ctr_random / first_value(ctr_random) over (order by position), 1) as random_index,
    round(100 * ctr_ranked / first_value(ctr_ranked) over (order by position), 1) as ranked_index
from r
where ctr_random is not null and ctr_ranked is not null
order by position;


-- 3. Same thing by block of slots (the last block is 24-34 here)
create or replace view pos_blocks as
select
    case when is_random then 'random' else 'ranked' end         as arm,
    case when slot_block = '24+' then '24-34' else slot_block end as slot_block,
    count(*)                                                    as impressions,
    round(100.0 * avg(case when clicked then 1 else 0 end), 2)  as ctr_pct,
    round(100.0 * count(*) filter (where booked) / nullif(count(*) filter (where clicked), 0), 1) as booked_after_click_pct,
    -- share of all clicks in that arm that land in this block
    round(100.0 * count(*) filter (where clicked)
          / sum(count(*) filter (where clicked)) over (partition by is_random), 1) as pct_of_arm_clicks
from impressions
where srch_id in (select srch_id from searches where full_top34)
  and not reserved_slot and position <= 34
group by is_random, slot_block
order by arm, min(position);


-- 4. Does position change what happens after the click? In the random arm,
-- compare the share of clicks that turn into a booking in slots 1-4 against
-- each lower block. Both blocks come from the same searches, so the error
-- uses the delta method with the search as the cluster, as in 04.
create or replace view pos_after_click as
with per as (
    -- one row per search and block (every full_top34 search has all blocks)
    select
        srch_id,
        case when slot_block = '24+' then '24-34' else slot_block end as slot_block,
        min(position)                                           as first_slot,
        count(*) filter (where clicked)                         as c,
        count(*) filter (where booked)                          as b
    from impressions
    where is_random and not reserved_slot and position <= 34
      and srch_id in (select srch_id from searches where full_top34)
    group by 1, 2
),
tot as (
    select
        slot_block,
        min(first_slot)                                         as first_slot,
        sum(c)                                                  as clicks,
        sum(b)                                                  as bookings,
        sum(b) * 1.0 / sum(c)                                   as rate
    from per
    group by slot_block
),
-- each block's booking rate linearised per search (delta method)
psi as (
    select p.srch_id, p.slot_block, (p.b - t.rate * p.c) / t.clicks as psi
    from per p
    join tot t on t.slot_block = p.slot_block
),
se as (
    select x.slot_block, sqrt(sum(pow(top.psi - x.psi, 2)))    as se_gap
    from psi x
    join psi top on top.srch_id = x.srch_id and top.slot_block = '1-4'
    group by x.slot_block
)
select
    t.slot_block,
    t.clicks,
    round(100 * t.rate, 2)                                      as booked_after_click_pct,
    round(100 * (top.rate - t.rate), 2)                         as gap_vs_top_pts,
    case when t.slot_block <> '1-4'
         then round(p_two_sided((top.rate - t.rate) / se.se_gap), 4) end as p_value
from tot t
cross join (select rate from tot where slot_block = '1-4') top
join se on se.slot_block = t.slot_block
order by t.first_slot;
