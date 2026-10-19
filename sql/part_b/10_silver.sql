-- =============================================================================
-- Part B - SILVER: raw JSON files -> clean tables, one row per thing per snapshot.
-- Rebuilt from the raw files every run (CREATE OR REPLACE), so running it
-- twice gives the same result. The raw files are never changed.
-- =============================================================================

-- Every free_bike_status snapshot we collected (even one with zero bikes).
CREATE OR REPLACE TABLE silver_snapshots AS
SELECT DISTINCT to_timestamp(last_updated) AS snapshot_ts
FROM read_json('data/raw/free_bike_status/*/*.json.gz');

-- One row per dockless bike per snapshot.
CREATE OR REPLACE TABLE silver_free_bikes AS
WITH raw AS (
    SELECT last_updated, unnest(data.bikes) AS b
    FROM read_json('data/raw/free_bike_status/*/*.json.gz')
)
SELECT
    to_timestamp(last_updated)     AS snapshot_ts,
    b.bike_id,
    b.lat,
    b.lon,
    b.vehicle_type_id,
    b.is_reserved::BOOLEAN         AS is_reserved,
    b.is_disabled::BOOLEAN         AS is_disabled,
    b.current_range_meters         AS current_range_m
FROM raw
-- if the same bike shows up twice in one snapshot, keep one copy
QUALIFY ROW_NUMBER() OVER (PARTITION BY snapshot_ts, b.bike_id ORDER BY b.lat) = 1;

-- One row per station per snapshot.
CREATE OR REPLACE TABLE silver_station_status AS
WITH raw AS (
    SELECT last_updated, unnest(data.stations) AS s
    FROM read_json('data/raw/station_status/*/*.json.gz')
)
SELECT
    to_timestamp(last_updated)     AS snapshot_ts,
    s.station_id,
    s.num_bikes_available,
    s.num_ebikes_available,
    s.num_docks_available,
    s.num_bikes_disabled,
    s.num_docks_disabled,
    s.is_renting::BOOLEAN          AS is_renting,
    s.is_returning::BOOLEAN        AS is_returning,
    to_timestamp(s.last_reported)  AS last_reported_ts
FROM raw
QUALIFY ROW_NUMBER() OVER (PARTITION BY snapshot_ts, s.station_id ORDER BY s.last_reported DESC) = 1;

-- Reference tables: keep only the newest file of each (current values only).
CREATE OR REPLACE TABLE dim_station AS
WITH latest AS (
    SELECT data FROM read_json('data/raw/station_information/*/*.json.gz')
    ORDER BY last_updated DESC
    LIMIT 1
)
SELECT s.station_id, s.name AS station_name, s.lat, s.lon, s.capacity
FROM (SELECT unnest(data.stations) AS s FROM latest);

CREATE OR REPLACE TABLE dim_vehicle_type AS
WITH latest AS (
    SELECT data FROM read_json('data/raw/vehicle_types/*/*.json.gz')
    ORDER BY last_updated DESC
    LIMIT 1
)
SELECT v.vehicle_type_id, v.propulsion_type, v.max_range_meters AS max_range_m
FROM (SELECT unnest(data.vehicle_types) AS v FROM latest);

-- Enrichment 1: the 10 travel hubs I picked (reference/travel_hubs.csv).
CREATE OR REPLACE TABLE dim_hub AS
SELECT * FROM read_csv('reference/travel_hubs.csv', header = true);
