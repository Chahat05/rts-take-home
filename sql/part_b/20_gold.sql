-- =============================================================================
-- Part B - GOLD: can a traveller find a bike near DC's travel hubs?
--
-- Main table: gold_hub_availability
--   one row = one hub at one snapshot (every ~2 minutes), with bikes,
--   e-bikes and open docks within 400 m (about a 5 minute walk), plus the
--   weather for that hour.
-- Then 3 small answer views: per hub, per hour of day, and rain vs dry.
-- =============================================================================

-- Distance in metres between two lat/lon points (haversine formula).
-- 6371000 = radius of the Earth in metres.
CREATE OR REPLACE MACRO distance_m(lat1, lon1, lat2, lon2) AS
    2 * 6371000 * asin(sqrt(
          pow(sin(radians(lat2 - lat1) / 2), 2)
        + cos(radians(lat1)) * cos(radians(lat2)) * pow(sin(radians(lon2 - lon1) / 2), 2)
    ));

-- Step 1: which docking stations are within 400 m of each hub.
CREATE OR REPLACE TABLE hub_stations AS
SELECT h.hub_id, s.station_id
FROM dim_hub h
JOIN dim_station s
  ON distance_m(h.lat, h.lon, s.lat, s.lon) <= 400;

-- Step 2: dockless e-bikes within 400 m of each hub, per snapshot.
-- (Every dockless bike in this system is an e-bike - I checked the data.)
-- "Usable" = at least 5 km of battery left.
CREATE OR REPLACE TABLE hub_free_bikes AS
SELECT
    b.snapshot_ts,
    h.hub_id,
    COUNT(*)                                                     AS free_ebikes,
    SUM(CASE WHEN b.current_range_m >= 5000 THEN 1 ELSE 0 END)  AS usable_free_ebikes
FROM silver_free_bikes b
JOIN dim_hub h
  ON distance_m(h.lat, h.lon, b.lat, b.lon) <= 400
WHERE NOT b.is_reserved
  AND NOT b.is_disabled
GROUP BY b.snapshot_ts, h.hub_id;

-- Step 3: match each bike snapshot to a station snapshot.
-- The two feeds are stamped a few seconds apart, so an exact match fails.
-- ASOF JOIN picks the latest station snapshot at or before the bike snapshot,
-- and we only accept it if it's at most 10 minutes old.
CREATE OR REPLACE TABLE snapshot_alignment AS
WITH station_snaps AS (
    SELECT DISTINCT snapshot_ts AS station_snapshot_ts FROM silver_station_status
)
SELECT s.snapshot_ts, ss.station_snapshot_ts
FROM silver_snapshots s
ASOF JOIN station_snaps ss
  ON s.snapshot_ts >= ss.station_snapshot_ts
WHERE s.snapshot_ts - ss.station_snapshot_ts <= INTERVAL 10 MINUTE;

-- Step 4: docked bikes, docked e-bikes and open docks near each hub, per snapshot.
-- Bikes only count at stations that are renting; docks only at stations that are returning.
CREATE OR REPLACE TABLE hub_docked_bikes AS
SELECT
    a.snapshot_ts,
    hs.hub_id,
    SUM(CASE WHEN st.is_renting   THEN st.num_bikes_available  ELSE 0 END) AS docked_bikes,
    SUM(CASE WHEN st.is_renting   THEN st.num_ebikes_available ELSE 0 END) AS docked_ebikes,
    SUM(CASE WHEN st.is_returning THEN st.num_docks_available  ELSE 0 END) AS open_docks
FROM snapshot_alignment a
JOIN silver_station_status st ON st.snapshot_ts = a.station_snapshot_ts
JOIN hub_stations hs          ON hs.station_id = st.station_id
GROUP BY a.snapshot_ts, hs.hub_id;

-- Step 5: the main table. Every snapshot x every hub, so a hub with zero bikes
-- still gets a row (with 0). Snapshots with no fresh station data (step 3)
-- are left out.
CREATE OR REPLACE TABLE gold_hub_availability AS
SELECT
    a.snapshot_ts,
    timezone('America/New_York', a.snapshot_ts)                    AS snapshot_local,
    hour(timezone('America/New_York', a.snapshot_ts))              AS hour_of_day,
    h.hub_id,
    h.hub_name,
    COALESCE(d.docked_bikes, 0)                                    AS docked_bikes,
    COALESCE(d.docked_ebikes, 0)                                   AS docked_ebikes,
    COALESCE(f.free_ebikes, 0)                                     AS free_ebikes,
    COALESCE(f.usable_free_ebikes, 0)                              AS usable_free_ebikes,
    COALESCE(d.docked_bikes, 0) + COALESCE(f.free_ebikes, 0)        AS total_bikes,
    COALESCE(d.docked_ebikes, 0) + COALESCE(f.usable_free_ebikes, 0) AS ebikes_available,
    COALESCE(d.open_docks, 0)                                      AS open_docks,
    w.temperature_c,
    w.precipitation_mm,
    w.precip_band,
    w.temp_band
FROM snapshot_alignment a
CROSS JOIN dim_hub h
LEFT JOIN hub_docked_bikes d
       ON d.snapshot_ts = a.snapshot_ts AND d.hub_id = h.hub_id
LEFT JOIN hub_free_bikes f
       ON f.snapshot_ts = a.snapshot_ts AND f.hub_id = h.hub_id
LEFT JOIN silver_weather_hourly w
       ON w.hour_ts = date_trunc('hour', a.snapshot_ts);

-- -----------------------------------------------------------------------------
-- ANSWER VIEWS
-- -----------------------------------------------------------------------------

-- A. Per hub: bikes, e-bikes and open docks - on average and at the worst moment.
CREATE OR REPLACE VIEW answer_hub_reliability AS
SELECT
    hub_name,
    COUNT(*)                                                         AS snapshots,
    ROUND(AVG(total_bikes), 1)                                       AS avg_bikes,
    MIN(total_bikes)                                                 AS min_bikes,
    ROUND(AVG(ebikes_available), 1)                                  AS avg_ebikes,
    MIN(ebikes_available)                                            AS min_ebikes,
    ROUND(100.0 * SUM(CASE WHEN ebikes_available >= 1 THEN 1 ELSE 0 END) / COUNT(*), 1)
                                                                     AS pct_time_with_ebike,
    ROUND(AVG(open_docks), 1)                                        AS avg_open_docks,
    MIN(open_docks)                                                  AS min_open_docks
FROM gold_hub_availability
GROUP BY hub_name
ORDER BY min_open_docks, min_ebikes;

-- B. When is it hardest? Per hub and hour of day (DC time).
CREATE OR REPLACE VIEW answer_by_hour_of_day AS
SELECT
    hub_name,
    hour_of_day,
    COUNT(*)                          AS snapshots,
    ROUND(AVG(total_bikes), 1)        AS avg_bikes,
    ROUND(AVG(ebikes_available), 1)   AS avg_ebikes,
    MIN(ebikes_available)             AS min_ebikes,
    ROUND(AVG(open_docks), 1)         AS avg_open_docks,
    MIN(open_docks)                   AS min_open_docks
FROM gold_hub_availability
GROUP BY hub_name, hour_of_day
ORDER BY hub_name, hour_of_day;

-- C. Does rain change it? Per hub, wet hours vs dry hours.
CREATE OR REPLACE VIEW answer_by_weather AS
SELECT
    hub_name,
    COALESCE(precip_band, 'No weather data') AS precip_band,
    COUNT(*)                          AS snapshots,
    ROUND(AVG(total_bikes), 1)        AS avg_bikes,
    ROUND(AVG(ebikes_available), 1)   AS avg_ebikes,
    ROUND(AVG(open_docks), 1)         AS avg_open_docks
FROM gold_hub_availability
GROUP BY hub_name, COALESCE(precip_band, 'No weather data')
ORDER BY hub_name, precip_band;
