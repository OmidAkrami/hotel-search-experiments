-- 08_dashboard.sql
-- Flat, aggregated tables for the Tableau readout. The Python outputs (A/A,
-- peeking, geo-lift) are already flat CSVs in results/.


-- slot curve for both arms, with error bars
create or replace view dash_position_curve as
select
    arm,
    position,
    impressions,
    ctr_pct,
    ctr_lo,
    ctr_hi,
    bookings_per_100_impressions,
    booked_after_click_pct
from pos_curve;


create or replace view dash_ab_headline as
select * from ab_headline;


-- forest plot: one row per segment, lift with its interval
create or replace view dash_segments as
select dim, segment, impressions, lift_pct, lift_lo, lift_hi, p_bh_lift,
       gain_pts, gain_lo, gain_hi, p_bh_gain
from ab_segments;


create or replace view dash_adjacent as
select comparison, lift_pct, lift_lo, lift_hi, p_bh, significant_after_bh
from ab_adjacent;


create or replace view dash_power as
select * from pow_mde;


create or replace view dash_assignment_by_site as
select site_id, searches, pct_random, z_vs_overall
from chk_assignment_by_site
where searches >= 1000;


create or replace view dash_power_between as
select * from pow_between;
