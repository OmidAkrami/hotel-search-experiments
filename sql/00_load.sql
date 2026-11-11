-- 00_load.sql
-- data/train.parquet comes from scripts/prepare_data.py (Kaggle's train.csv, typed).

create or replace view raw_train as
select * from read_parquet('data/train.parquet');


-- Helpers for p-values. Neither DuckDB nor Postgres ships a normal CDF, so
-- this is the Abramowitz & Stegun 7.1.26 approximation of erf (error < 1.5e-7),
-- which is plenty for a p-value.
create or replace macro _as_t(x) as 1 / (1 + 0.3275911 * x);

create or replace macro _erf_pos(x) as
    1 - (  0.254829592 * _as_t(x)
         - 0.284496736 * pow(_as_t(x), 2)
         + 1.421413741 * pow(_as_t(x), 3)
         - 1.453152027 * pow(_as_t(x), 4)
         + 1.061405429 * pow(_as_t(x), 5)) * exp(-x * x);

create or replace macro norm_cdf(z) as
    case when z >= 0 then 0.5 * (1 + _erf_pos(z / sqrt(2)))
         else 0.5 * (1 - _erf_pos(-z / sqrt(2))) end;

create or replace macro p_two_sided(z) as 2 * (1 - norm_cdf(abs(z)));

-- chi-square upper tail via the Wilson-Hilferty cube-root approximation
create or replace macro chisq_p(x, k) as
    1 - norm_cdf((pow(x / k, 1.0 / 3) - (1 - 2.0 / (9 * k))) / sqrt(2.0 / (9 * k)));
