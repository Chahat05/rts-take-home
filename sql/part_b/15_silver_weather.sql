-- =============================================================================
-- Part B - SILVER: Enrichment 2, hourly weather for DC (Open-Meteo).
-- Each weather file covers the past 7 days, so files overlap. For each hour,
-- keep the value from the most recent file.
-- =============================================================================
CREATE OR REPLACE TABLE silver_weather_hourly AS
WITH raw AS (
    SELECT
        filename,
        unnest(hourly.time)            AS hour_epoch,
        unnest(hourly.temperature_2m)  AS temperature_c,
        unnest(hourly.precipitation)   AS precipitation_mm
    FROM read_json('data/raw/weather/*/*.json.gz', filename = true)
)
SELECT
    to_timestamp(hour_epoch) AS hour_ts,
    temperature_c,
    precipitation_mm,
    CASE WHEN precipitation_mm >= 0.1 THEN 'Wet' ELSE 'Dry' END AS precip_band,
    CASE
        WHEN temperature_c < 10 THEN 'Cold (<10°C)'
        WHEN temperature_c < 20 THEN 'Mild (10-20°C)'
        ELSE 'Warm (20°C+)'
    END AS temp_band
FROM raw
QUALIFY ROW_NUMBER() OVER (PARTITION BY hour_epoch ORDER BY filename DESC) = 1;
