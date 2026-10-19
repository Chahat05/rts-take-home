-- =============================================================================
-- Part B - DATA QUALITY CHECKS
-- Each check returns the number of failing rows. ERROR = stop the pipeline;
-- WARN = record it and carry on (the data is still usable, but noted).
-- =============================================================================
CREATE OR REPLACE TABLE quality_results AS

SELECT 'Duplicate bike rows in a snapshot' AS check_name, 'ERROR' AS severity,
       (SELECT COUNT(*) FROM (SELECT snapshot_ts, bike_id FROM silver_free_bikes
                              GROUP BY snapshot_ts, bike_id HAVING COUNT(*) > 1)) AS failed_rows

UNION ALL
SELECT 'Bikes with missing coordinates', 'ERROR',
       (SELECT COUNT(*) FROM silver_free_bikes WHERE lat IS NULL OR lon IS NULL)

UNION ALL
SELECT 'Negative station counts', 'ERROR',
       (SELECT COUNT(*) FROM silver_station_status
        WHERE num_bikes_available < 0 OR num_docks_available < 0 OR num_ebikes_available < 0)

UNION ALL
SELECT 'Bikes outside the DC-area service box', 'WARN',
       (SELECT COUNT(*) FROM silver_free_bikes
        WHERE lat NOT BETWEEN 38.6 AND 39.3 OR lon NOT BETWEEN -77.6 AND -76.7)

UNION ALL
SELECT 'E-bike range above the published maximum', 'WARN',
       (SELECT COUNT(*) FROM silver_free_bikes b
        JOIN dim_vehicle_type v USING (vehicle_type_id)
        WHERE b.current_range_m > v.max_range_m)

UNION ALL
SELECT 'Unknown vehicle type', 'WARN',
       (SELECT COUNT(*) FROM silver_free_bikes b
        WHERE b.vehicle_type_id NOT IN (SELECT vehicle_type_id FROM dim_vehicle_type))

UNION ALL
SELECT 'Dockless bike that is not an e-bike (gold assumes they all are)', 'WARN',
       (SELECT COUNT(*) FROM silver_free_bikes b
        JOIN dim_vehicle_type v USING (vehicle_type_id)
        WHERE v.propulsion_type <> 'electric_assist')

UNION ALL
SELECT 'Station status for a station not in station_information', 'WARN',
       (SELECT COUNT(*) FROM silver_station_status
        WHERE station_id NOT IN (SELECT station_id FROM dim_station))

UNION ALL
SELECT 'Station reporting more bikes + docks than its capacity', 'WARN',
       (SELECT COUNT(*) FROM silver_station_status st JOIN dim_station s USING (station_id)
        WHERE st.num_bikes_available + st.num_docks_available
              + st.num_bikes_disabled + st.num_docks_disabled > s.capacity)

UNION ALL
SELECT 'Renting station silent for over 1 hour (stale)', 'WARN',
       (SELECT COUNT(*) FROM silver_station_status
        WHERE is_renting AND snapshot_ts - last_reported_ts > INTERVAL 1 HOUR)

UNION ALL
SELECT 'Gaps over 5 minutes between snapshots', 'WARN',
       (SELECT COUNT(*) FROM (
            SELECT snapshot_ts - LAG(snapshot_ts) OVER (ORDER BY snapshot_ts) AS gap
            FROM silver_snapshots) WHERE gap > INTERVAL 5 MINUTE)

UNION ALL
SELECT 'Bike snapshots with no matching station snapshot', 'WARN',
       (SELECT COUNT(*) FROM silver_snapshots
        WHERE snapshot_ts NOT IN (SELECT snapshot_ts FROM snapshot_alignment))

UNION ALL
SELECT 'Hours with bike data but no weather', 'WARN',
       (SELECT COUNT(DISTINCT date_trunc('hour', snapshot_ts)) FROM silver_snapshots
        WHERE date_trunc('hour', snapshot_ts) NOT IN (SELECT hour_ts FROM silver_weather_hourly));
