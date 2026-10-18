-- =============================================================================
-- Part A: XYZ Travel data warehouse - star schema (DDL)
-- Written in standard SQL; runs as-is on DuckDB and with minor type changes
-- on Snowflake.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- DIMENSIONS
-- ---------------------------------------------------------------------------

CREATE TABLE dim_date (
    date_key        INTEGER PRIMARY KEY,   -- YYYYMMDD, e.g. 20261017
    full_date       DATE NOT NULL,
    day_of_week     VARCHAR NOT NULL,      -- 'Saturday'
    is_weekend      BOOLEAN NOT NULL,
    month           INTEGER NOT NULL,
    quarter         INTEGER NOT NULL,
    year            INTEGER NOT NULL,
    is_holiday      BOOLEAN NOT NULL DEFAULT FALSE
);

-- Every customer, registered or guest. Guests are matched across bookings
-- by a hash of their email; plain-text email is never stored.
CREATE TABLE dim_customer (
    customer_key    INTEGER PRIMARY KEY,   -- surrogate key, assigned by the warehouse
    user_id         VARCHAR,               -- website account ID; NULL for guests
    email_hash      VARCHAR NOT NULL,      -- SHA-256 of normalised email
    is_registered   BOOLEAN NOT NULL,
    first_seen_at   TIMESTAMP NOT NULL,
    registered_at   TIMESTAMP              -- NULL until/unless the guest registers
);

CREATE TABLE dim_airport (
    airport_key     INTEGER PRIMARY KEY,
    iata_code       VARCHAR(3) NOT NULL,   -- 'DCA'
    airport_name    VARCHAR NOT NULL,
    city            VARCHAR NOT NULL,
    country         VARCHAR NOT NULL
);

CREATE TABLE dim_airline (
    airline_key     INTEGER PRIMARY KEY,
    airline_code    VARCHAR NOT NULL,      -- 'AA'
    airline_name    VARCHAR NOT NULL
);

-- Cities/areas used for hotel searches and car pick-up/drop-off.
CREATE TABLE dim_location (
    location_key    INTEGER PRIMARY KEY,
    city            VARCHAR NOT NULL,
    region          VARCHAR,               -- state / province
    country         VARCHAR NOT NULL
);

CREATE TABLE dim_hotel (
    hotel_key       INTEGER PRIMARY KEY,
    hotel_id        VARCHAR NOT NULL,      -- supplier's natural key
    hotel_name      VARCHAR NOT NULL,
    location_key    INTEGER NOT NULL REFERENCES dim_location (location_key),
    star_rating     DECIMAL(2,1)
);

CREATE TABLE dim_car_model (
    car_model_key   INTEGER PRIMARY KEY,
    make            VARCHAR NOT NULL,      -- 'Toyota'
    model           VARCHAR NOT NULL,      -- 'Camry'
    car_class       VARCHAR NOT NULL,      -- 'Midsize'
    seats           INTEGER NOT NULL
);

-- ---------------------------------------------------------------------------
-- SEARCH FACT  (grain: one search submitted on the site)
-- Header holds what every search has in common; one detail table per
-- business line holds what is specific to it.
-- ---------------------------------------------------------------------------

CREATE TABLE fact_search (
    search_key      BIGINT PRIMARY KEY,
    session_id      VARCHAR NOT NULL,      -- browser session; links anonymous searches
    customer_key    INTEGER REFERENCES dim_customer (customer_key),  -- NULL if never identified
    business_line   VARCHAR NOT NULL CHECK (business_line IN ('Flight', 'Hotel', 'Car')),
    search_date_key INTEGER NOT NULL REFERENCES dim_date (date_key),
    searched_at     TIMESTAMP NOT NULL,
    results_returned INTEGER
);

CREATE TABLE search_flight_detail (
    search_key            BIGINT PRIMARY KEY REFERENCES fact_search (search_key),
    origin_airport_key    INTEGER NOT NULL REFERENCES dim_airport (airport_key),
    dest_airport_key      INTEGER NOT NULL REFERENCES dim_airport (airport_key),
    depart_date_key       INTEGER NOT NULL REFERENCES dim_date (date_key),
    return_date_key       INTEGER REFERENCES dim_date (date_key),       -- NULL = one-way
    depart_time_from      TIME,               -- preferred departure time window
    depart_time_to        TIME,
    arrive_time_from      TIME,               -- preferred arrival time window
    arrive_time_to        TIME,
    passengers            INTEGER NOT NULL
);

CREATE TABLE search_hotel_detail (
    search_key            BIGINT PRIMARY KEY REFERENCES fact_search (search_key),
    location_key          INTEGER NOT NULL REFERENCES dim_location (location_key),
    checkin_date_key      INTEGER NOT NULL REFERENCES dim_date (date_key),
    checkout_date_key     INTEGER NOT NULL REFERENCES dim_date (date_key),
    rooms                 INTEGER NOT NULL
);

CREATE TABLE search_car_detail (
    search_key            BIGINT PRIMARY KEY REFERENCES fact_search (search_key),
    pickup_location_key   INTEGER NOT NULL REFERENCES dim_location (location_key),
    pickup_date_key       INTEGER NOT NULL REFERENCES dim_date (date_key),
    dropoff_date_key      INTEGER NOT NULL REFERENCES dim_date (date_key),
    car_model_key         INTEGER REFERENCES dim_car_model (car_model_key), -- NULL = any model
    passengers            INTEGER NOT NULL
);

-- ---------------------------------------------------------------------------
-- BOOKING FACT  (grain: one booked item - one flight, hotel stay or car rental)
-- A trip with a flight and a hotel = two rows sharing the same order_id.
-- ---------------------------------------------------------------------------

CREATE TABLE fact_booking (
    booking_key      BIGINT PRIMARY KEY,
    order_id         VARCHAR NOT NULL,       -- groups items booked together
    customer_key     INTEGER NOT NULL REFERENCES dim_customer (customer_key),
    business_line    VARCHAR NOT NULL CHECK (business_line IN ('Flight', 'Hotel', 'Car')),
    booking_date_key INTEGER NOT NULL REFERENCES dim_date (date_key),
    booked_at        TIMESTAMP NOT NULL,
    search_key       BIGINT REFERENCES fact_search (search_key), -- search that led here; NULL if unknown
    booking_status   VARCHAR NOT NULL,       -- 'Confirmed', 'Cancelled'
    amount_usd       DECIMAL(12,2) NOT NULL
);

CREATE TABLE booking_flight_detail (
    booking_key           BIGINT PRIMARY KEY REFERENCES fact_booking (booking_key),
    origin_airport_key    INTEGER NOT NULL REFERENCES dim_airport (airport_key),
    dest_airport_key      INTEGER NOT NULL REFERENCES dim_airport (airport_key),
    airline_key           INTEGER NOT NULL REFERENCES dim_airline (airline_key),
    depart_date_key       INTEGER NOT NULL REFERENCES dim_date (date_key),
    departs_at            TIMESTAMP NOT NULL,
    arrives_at            TIMESTAMP NOT NULL,
    passengers            INTEGER NOT NULL
);

CREATE TABLE booking_hotel_detail (
    booking_key           BIGINT PRIMARY KEY REFERENCES fact_booking (booking_key),
    hotel_key             INTEGER NOT NULL REFERENCES dim_hotel (hotel_key),
    checkin_date_key      INTEGER NOT NULL REFERENCES dim_date (date_key),
    checkout_date_key     INTEGER NOT NULL REFERENCES dim_date (date_key),
    rooms                 INTEGER NOT NULL,
    nights                INTEGER NOT NULL
);

CREATE TABLE booking_car_detail (
    booking_key           BIGINT PRIMARY KEY REFERENCES fact_booking (booking_key),
    car_model_key         INTEGER NOT NULL REFERENCES dim_car_model (car_model_key),
    pickup_location_key   INTEGER NOT NULL REFERENCES dim_location (location_key),
    dropoff_location_key  INTEGER NOT NULL REFERENCES dim_location (location_key),
    pickup_at             TIMESTAMP NOT NULL,
    dropoff_at            TIMESTAMP NOT NULL,
    passengers            INTEGER NOT NULL
);
