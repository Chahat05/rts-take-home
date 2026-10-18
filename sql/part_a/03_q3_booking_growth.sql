-- =============================================================================
-- Part A, Q3: percentage growth in bookings by year and business line
--
-- "Bookings" = booked items (the fact grain), counted by the year they were
-- booked, excluding cancellations. A year x business-line "spine" guarantees
-- every combination appears, so growth is always compared with the
-- immediately preceding calendar year - even if a line had zero bookings
-- that year.
-- =============================================================================
WITH yearly AS (
    SELECT
        d.year,
        b.business_line,
        COUNT(*)                         AS bookings
    FROM fact_booking b
    JOIN dim_date d ON d.date_key = b.booking_date_key
    WHERE b.booking_status <> 'Cancelled'
    GROUP BY d.year, b.business_line
),
spine AS (
    SELECT y.year, l.business_line
    FROM (
        SELECT DISTINCT year FROM dim_date
        WHERE year BETWEEN (SELECT MIN(year) FROM yearly)
                       AND (SELECT MAX(year) FROM yearly)
    ) y
    CROSS JOIN (VALUES ('Flight'), ('Hotel'), ('Car')) AS l (business_line)
),
filled AS (
    SELECT
        s.year,
        s.business_line,
        COALESCE(y.bookings, 0)          AS bookings
    FROM spine s
    LEFT JOIN yearly y
           ON y.year = s.year AND y.business_line = s.business_line
)
SELECT
    year,
    business_line,
    bookings,
    LAG(bookings) OVER w                 AS prev_year_bookings,
    ROUND(
        100.0 * (bookings - LAG(bookings) OVER w)
        / NULLIF(LAG(bookings) OVER w, 0),
        2
    )                                    AS pct_growth
FROM filled
WINDOW w AS (PARTITION BY business_line ORDER BY year)
ORDER BY business_line, year;
