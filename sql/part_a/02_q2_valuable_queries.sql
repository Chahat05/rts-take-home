-- =============================================================================
-- Part A, Q2: two queries most valuable to XYZ's analytics team
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Query 1: Search-to-booking conversion, by month, business line and
--          customer type (registered vs guest)
--
-- Why it matters: conversion is the core health metric of a travel site.
-- Splitting by business line shows where the funnel leaks, and splitting by
-- customer type shows whether pushing guests to register is worth it.
-- -----------------------------------------------------------------------------
WITH searches AS (
    SELECT
        DATE_TRUNC('month', s.searched_at)                AS month,
        s.business_line,
        CASE WHEN c.is_registered THEN 'Registered' ELSE 'Guest / anonymous' END
                                                          AS customer_type,
        COUNT(*)                                          AS searches
    FROM fact_search s
    LEFT JOIN dim_customer c ON c.customer_key = s.customer_key
    GROUP BY 1, 2, 3
),
bookings AS (
    SELECT
        DATE_TRUNC('month', s.searched_at)                AS month,
        s.business_line,
        CASE WHEN c.is_registered THEN 'Registered' ELSE 'Guest / anonymous' END
                                                          AS customer_type,
        COUNT(DISTINCT b.search_key)                      AS converted_searches
    FROM fact_booking b
    JOIN fact_search s       ON s.search_key = b.search_key
    LEFT JOIN dim_customer c ON c.customer_key = s.customer_key
    WHERE b.booking_status <> 'Cancelled'
    GROUP BY 1, 2, 3
)
SELECT
    s.month,
    s.business_line,
    s.customer_type,
    s.searches,
    COALESCE(b.converted_searches, 0)                     AS converted_searches,
    ROUND(100.0 * COALESCE(b.converted_searches, 0) / s.searches, 2)
                                                          AS conversion_pct
FROM searches s
LEFT JOIN bookings b
       ON  b.month = s.month
       AND b.business_line = s.business_line
       AND b.customer_type = s.customer_type
ORDER BY s.month, s.business_line, s.customer_type;


-- -----------------------------------------------------------------------------
-- Query 2: Cross-sell - of the orders that include a flight, what % also
--          include a hotel or a car? (by month)
--
-- Why it matters: it shows whether customers book the whole trip with XYZ
-- or only the flight. A low % means XYZ should offer "add a hotel?" at
-- checkout. One order (order_id) can hold several booked items.
-- -----------------------------------------------------------------------------
WITH orders AS (
    SELECT
        order_id,
        DATE_TRUNC('month', MIN(booked_at))                       AS month,
        MAX(CASE WHEN business_line = 'Flight' THEN 1 ELSE 0 END) AS has_flight,
        MAX(CASE WHEN business_line = 'Hotel'  THEN 1 ELSE 0 END) AS has_hotel,
        MAX(CASE WHEN business_line = 'Car'    THEN 1 ELSE 0 END) AS has_car
    FROM fact_booking
    WHERE booking_status <> 'Cancelled'
    GROUP BY order_id
)
SELECT
    month,
    SUM(has_flight)                                               AS flight_orders,
    ROUND(100.0 * SUM(CASE WHEN has_flight = 1 AND has_hotel = 1 THEN 1 ELSE 0 END)
          / NULLIF(SUM(has_flight), 0), 2)                        AS pct_with_hotel,
    ROUND(100.0 * SUM(CASE WHEN has_flight = 1 AND has_car = 1 THEN 1 ELSE 0 END)
          / NULLIF(SUM(has_flight), 0), 2)                        AS pct_with_car
FROM orders
GROUP BY month
ORDER BY month;
