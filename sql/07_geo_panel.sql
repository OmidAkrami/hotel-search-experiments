-- 07_geo_panel.sql
-- Panel for the geo-lift work in stats/geo_lift.py: weekly searches per
-- visitor country.
--
-- There is no real geo campaign in this data. The point of the geo part is
-- the design: which markets to test in, how long, what lift is detectable,
-- and checking that the method finds a lift when one is there. That is done
-- by adding a known lift to real market series and seeing if synthetic
-- control recovers it (the same way Meta's GeoLift runs power analysis).
--
-- Weeks run Monday to Sunday, 5 Nov 2012 to 30 Jun 2013 (34 full weeks).
-- Countries need 30+ searches a week on average to be usable. Country ids
-- are anonymised in the source; 219 is by far the largest.


create or replace view geo_weekly as
with w as (
    select
        visitor_country                                         as country,
        week_start(search_date)                                 as week,
        count(*)                                                as searches,
        count(*) filter (where has_booking)                     as bookings
    from searches
    where search_date between date '2012-11-05' and date '2013-06-30'
    group by 1, 2
),
keep as (
    select country
    from w
    group by country
    having sum(searches) >= 30 * 34 and count(*) = 34
)
select w.*
from w
join keep k using (country)
order by country, week;


-- one row per market: size and how noisy it is week to week
create or replace view geo_markets as
with s as (
    select
        country,
        avg(searches)                                           as avg_weekly_searches,
        stddev_samp(searches) / avg(searches)                   as cv
    from geo_weekly
    group by country
)
select
    country,
    round(avg_weekly_searches)                                  as avg_weekly_searches,
    round(cv, 3)                                                as week_to_week_cv,
    rank() over (order by avg_weekly_searches desc)             as size_rank
from s
order by avg_weekly_searches desc;


-- How noisy small markets are next to the mid-size ones the placebos come
-- from (mid-size = 100+ searches a week, not counting the largest market).
create or replace view geo_noise_by_size as
with s as (
    select
        country,
        avg(searches)                                           as avg_weekly,
        stddev_samp(searches) / avg(searches)                   as cv
    from geo_weekly
    group by country
)
select
    case when country = 219 then 'largest market (219)'
         when avg_weekly >= 100 then 'mid-size (100+ a week)'
         else 'small (under 100 a week)' end                    as market_size,
    count(*)                                                    as markets,
    round(min(avg_weekly))                                      as min_avg_weekly_searches,
    round(max(avg_weekly))                                      as max_avg_weekly_searches,
    round(avg(cv), 3)                                           as mean_week_to_week_cv
from s
group by 1
order by min(avg_weekly) desc;
