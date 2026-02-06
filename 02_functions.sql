-- =====================================================
-- PALLET ANALYTICS SYSTEM - FUNCTIONS
-- =====================================================
-- Purpose: Backend logic for calculating pallet analytics
-- =====================================================

-- =====================================================
-- FUNCTION: calculate_pallet_analytics
-- =====================================================
-- Purpose: Calculate delta_sec for a newly inserted pallet
-- Logic:
--   1. Find the previous pallet in the SAME shift
--   2. Calculate time difference (delta_sec)
--   3. Insert result into pallet_analytics
-- Called by: Trigger on raw_pallets INSERT
-- =====================================================

CREATE OR REPLACE FUNCTION calculate_pallet_analytics()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_pallet_ts TIMESTAMPTZ;
    v_delta_sec INTEGER;
BEGIN
    -- Find the most recent pallet BEFORE this one in the SAME shift
    SELECT pallet_ts INTO v_previous_pallet_ts
    FROM raw_pallets
    WHERE shift = NEW.shift
      AND pallet_ts < NEW.pallet_ts
    ORDER BY pallet_ts DESC
    LIMIT 1;

    -- Calculate delta_sec if previous pallet exists
    IF v_previous_pallet_ts IS NOT NULL THEN
        v_delta_sec := EXTRACT(EPOCH FROM (NEW.pallet_ts - v_previous_pallet_ts))::INTEGER;
    ELSE
        -- First pallet in this shift, no previous pallet
        v_delta_sec := NULL;
    END IF;

    -- Insert calculated analytics
    INSERT INTO pallet_analytics (
        pallet_id,
        pallet_ts,
        shift,
        delta_sec,
        is_anomaly
    ) VALUES (
        NEW.id,
        NEW.pallet_ts,
        NEW.shift,
        v_delta_sec,
        FALSE  -- Default to not anomaly, can be updated later
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: recalculate_all_analytics
-- =====================================================
-- Purpose: Batch recalculation of all analytics
-- Use case: Initial setup, data correction, or full refresh
-- Warning: This will DELETE all existing analytics and recalculate
-- =====================================================

CREATE OR REPLACE FUNCTION recalculate_all_analytics()
RETURNS TABLE (
    processed_count INTEGER,
    execution_time_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_count INTEGER;
BEGIN
    v_start_time := clock_timestamp();

    -- Clear existing analytics
    DELETE FROM pallet_analytics;

    -- Recalculate for all pallets
    -- This uses a window function to get the previous timestamp per shift
    INSERT INTO pallet_analytics (pallet_id, pallet_ts, shift, delta_sec, is_anomaly)
    SELECT
        id,
        pallet_ts,
        shift,
        CASE
            WHEN prev_pallet_ts IS NOT NULL THEN
                EXTRACT(EPOCH FROM (pallet_ts - prev_pallet_ts))::INTEGER
            ELSE
                NULL
        END AS delta_sec,
        FALSE AS is_anomaly
    FROM (
        SELECT
            id,
            pallet_ts,
            shift,
            LAG(pallet_ts) OVER (PARTITION BY shift ORDER BY pallet_ts) AS prev_pallet_ts
        FROM raw_pallets
    ) AS pallet_with_prev;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_end_time := clock_timestamp();

    RETURN QUERY SELECT
        v_count,
        EXTRACT(MILLISECONDS FROM (v_end_time - v_start_time))::INTEGER;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: get_shift_summary
-- =====================================================
-- Purpose: Get analytics summary for a specific shift
-- Returns: Average delta, min, max, count, anomaly count
-- =====================================================

CREATE OR REPLACE FUNCTION get_shift_summary(
    p_shift TEXT,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    shift TEXT,
    total_pallets BIGINT,
    avg_delta_sec NUMERIC,
    min_delta_sec INTEGER,
    max_delta_sec INTEGER,
    anomaly_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        pa.shift,
        COUNT(*)::BIGINT AS total_pallets,
        ROUND(AVG(pa.delta_sec), 2) AS avg_delta_sec,
        MIN(pa.delta_sec) AS min_delta_sec,
        MAX(pa.delta_sec) AS max_delta_sec,
        COUNT(*) FILTER (WHERE pa.is_anomaly = TRUE)::BIGINT AS anomaly_count
    FROM pallet_analytics pa
    WHERE pa.shift = p_shift
      AND (p_start_date IS NULL OR pa.pallet_ts >= p_start_date)
      AND (p_end_date IS NULL OR pa.pallet_ts <= p_end_date)
      AND pa.delta_sec IS NOT NULL  -- Exclude first pallet in shift
    GROUP BY pa.shift;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: detect_anomalies
-- =====================================================
-- Purpose: Mark pallets as anomalies based on threshold
-- Logic: If delta_sec > threshold, mark as anomaly
-- Can be run periodically or on-demand
-- =====================================================

CREATE OR REPLACE FUNCTION detect_anomalies(
    p_threshold_seconds INTEGER DEFAULT 300  -- Default: 5 minutes
)
RETURNS TABLE (
    updated_count INTEGER
) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Reset all anomalies first
    UPDATE pallet_analytics SET is_anomaly = FALSE;

    -- Mark as anomaly if delta exceeds threshold
    UPDATE pallet_analytics
    SET is_anomaly = TRUE
    WHERE delta_sec > p_threshold_seconds
      AND delta_sec IS NOT NULL;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN QUERY SELECT v_count;
END;
$$ LANGUAGE plpgsql;
