-- 01_staging.sql
-- Two tables: one row per hotel shown (impressions) and one row per search.
--
-- Each srch_id is one hotel search on an Expedia site.
-- For roughly 30% of searches Expedia showed the hotels in random order
-- (random_bool = 1) instead of its own ranking. That random shuffle is the
-- experiment everything in 03 and 04 is built on.
--
-- Slots 5, 11, 17 and 23 are nearly empty (in the random arm, about 2k
-- impressions each vs 120k for slot 4, see chk_slot_counts in 02). They look
-- reserved for something that isn't in the data, so I flag them and leave
-- them out of the position work.
-- Blocks follow those gaps: 1-4, 6-10, 12-16, 18-22, 24+.
--
-- Search length matters for anything that compares slots. A search with 8
-- hotels has all four top slots but only some of 6-10, and short lists have a
-- much higher click-through per hotel (one click shared by fewer hotels). If
-- every search counts, slots 1-4 get extra weight from short lists and look
-- better than they are. So searches carries two flags:
--   full_top10   all nine slots 1-4 and 6-10 present (used by the A/B test)
--   full_top34   all thirty slots up to 34 present (used by the slot curve)

create or replace table impressions as
select
    srch_id,
    date_time                                               as search_ts,
    cast(date_time as date)                                 as search_date,
    site_id,
    visitor_location_country_id                             as visitor_country,
    srch_destination_id                                     as destination_id,
    prop_id                                                 as hotel_id,
    position,
    position in (5, 11, 17, 23)                             as reserved_slot,
    case
        when position <= 4  then '1-4'
        when position <= 10 then '6-10'
        when position <= 16 then '12-16'
        when position <= 22 then '18-22'
        else '24+'
    end                                                     as slot_block,
    random_bool = 1                                         as is_random,
    click_bool  = 1                                         as clicked,
    booking_bool = 1                                        as booked,
    coalesce(gross_bookings_usd, 0)                         as booking_value,
    price_usd,
    -- 0 stars means unknown or not shown, 0 review score means no reviews
    nullif(prop_starrating, 0)                              as stars,
    nullif(prop_review_score, 0)                            as review_score,
    prop_brand_bool = 1                                     as is_chain,
    promotion_flag = 1                                      as on_promotion,
    prop_location_score1                                    as loc_score1,
    prop_location_score2                                    as loc_score2,
    srch_length_of_stay                                     as nights,
    srch_booking_window                                     as days_ahead,
    srch_adults_count                                       as adults,
    srch_children_count                                     as children,
    -- where the hotel's price sits inside its own search, 0 = cheapest
    percent_rank() over (partition by srch_id order by price_usd) as price_pct_in_search
from raw_train;


create or replace table searches as
select
    srch_id,
    any_value(search_ts)                                    as search_ts,
    any_value(search_date)                                  as search_date,
    any_value(site_id)                                      as site_id,
    any_value(visitor_country)                              as visitor_country,
    any_value(destination_id)                               as destination_id,
    bool_or(is_random)                                      as is_random,
    count(*)                                                as hotels_shown,
    count(*) filter (where clicked)                         as clicks,
    bool_or(booked)                                         as has_booking,
    sum(booking_value)                                      as booking_value,
    min(position) filter (where clicked)                    as first_click_position,
    max(position) filter (where clicked)                    as deepest_click_position,
    min(position) filter (where booked)                     as booked_position,
    any_value(nights)                                       as nights,
    any_value(days_ahead)                                   as days_ahead,
    any_value(adults)                                       as adults,
    any_value(children)                                     as children,
    any_value(dayofweek(search_ts)) in (0, 6)               as weekend_search,
    count(*) filter (where not reserved_slot and position <= 10) = 9  as full_top10,
    count(*) filter (where not reserved_slot and position <= 34) = 30 as full_top34
from impressions
group by srch_id;


-- week number with Monday starts, used by the time-based checks and the geo panel
create or replace macro week_start(d) as cast(date_trunc('week', d) as date);
