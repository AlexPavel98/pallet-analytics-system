-- =====================================================
-- UPDATE SCHEMA FOR FARMING/AGRICULTURE USE CASE
-- =====================================================
-- Purpose: Modify tables to match actual Glide fields
-- Changes:
--   - Remove mandatory "shift" field
--   - Add farming fields: harvest_culture, cultivation_method, etc.
--   - Group delta calculations by harvest_culture
-- =====================================================

-- =====================================================
-- STEP 1: Update raw_pallets table
-- =====================================================

-- Add new columns for farming data
ALTER TABLE raw_pallets
    DROP COLUMN IF EXISTS shift,
    ADD COLUMN IF NOT EXISTS harvest_culture TEXT,
    ADD COLUMN IF NOT EXISTS cultivation_method TEXT,
    ADD COLUMN IF NOT EXISTS source TEXT,
    ADD COLUMN IF NOT EXISTS supplier TEXT,
    ADD COLUMN IF NOT EXISTS producer TEXT,
    ADD COLUMN IF NOT EXISTS production_type TEXT;

-- Make harvest_culture NOT NULL (required for grouping)
-- First set default for existing rows
UPDATE raw_pallets SET harvest_culture = 'unknown' WHERE harvest_culture IS NULL;
ALTER TABLE raw_pallets ALTER COLUMN harvest_culture SET NOT NULL;

-- Update operator column comment
COMMENT ON COLUMN raw_pallets.operator IS 'Logged-in user who created the pallet entry';

-- =====================================================
-- STEP 2: Update pallet_analytics table
-- =====================================================

-- Add new columns to pallet_analytics (denormalized for performance)
ALTER TABLE pallet_analytics
    DROP COLUMN IF EXISTS shift,
    ADD COLUMN IF NOT EXISTS harvest_culture TEXT,
    ADD COLUMN IF NOT EXISTS cultivation_method TEXT,
    ADD COLUMN IF NOT EXISTS producer TEXT;

-- Make harvest_culture NOT NULL
UPDATE pallet_analytics SET harvest_culture = 'unknown' WHERE harvest_culture IS NULL;
ALTER TABLE pallet_analytics ALTER COLUMN harvest_culture SET NOT NULL;

-- Update delta_sec column comment
COMMENT ON COLUMN pallet_analytics.delta_sec IS
    'Time difference in seconds between current pallet and previous pallet with SAME harvest_culture. NULL for first pallet in that culture.';

-- =====================================================
-- STEP 3: Update indexes
-- =====================================================

-- Drop old shift-based indexes
DROP INDEX IF EXISTS idx_raw_pallets_shift_ts;
DROP INDEX IF EXISTS idx_pallet_analytics_shift_ts;

-- Create new harvest_culture-based indexes
CREATE INDEX IF NOT EXISTS idx_raw_pallets_culture_ts
    ON raw_pallets(harvest_culture, pallet_ts DESC);

CREATE INDEX IF NOT EXISTS idx_pallet_analytics_culture_ts
    ON pallet_analytics(harvest_culture, pallet_ts DESC);

-- =====================================================
-- STEP 4: Update calculation function
-- =====================================================

-- Replace the calculation function to use harvest_culture
CREATE OR REPLACE FUNCTION calculate_pallet_analytics()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_pallet_ts TIMESTAMPTZ;
    v_delta_sec INTEGER;
BEGIN
    -- Find the most recent pallet BEFORE this one with the SAME harvest_culture
    SELECT pallet_ts INTO v_previous_pallet_ts
    FROM raw_pallets
    WHERE harvest_culture = NEW.harvest_culture
      AND pallet_ts < NEW.pallet_ts
    ORDER BY pallet_ts DESC
    LIMIT 1;

    -- Calculate delta_sec if previous pallet exists
    IF v_previous_pallet_ts IS NOT NULL THEN
        v_delta_sec := EXTRACT(EPOCH FROM (NEW.pallet_ts - v_previous_pallet_ts))::INTEGER;
    ELSE
        -- First pallet for this harvest_culture, no previous pallet
        v_delta_sec := NULL;
    END IF;

    -- Insert calculated analytics with farming fields
    INSERT INTO pallet_analytics (
        pallet_id,
        pallet_ts,
        harvest_culture,
        cultivation_method,
        producer,
        delta_sec,
        is_anomaly
    ) VALUES (
        NEW.id,
        NEW.pallet_ts,
        NEW.harvest_culture,
        NEW.cultivation_method,
        NEW.producer,
        v_delta_sec,
        FALSE
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- STEP 5: Update batch recalculation function
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

    -- Recalculate for all pallets using harvest_culture grouping
    INSERT INTO pallet_analytics (pallet_id, pallet_ts, harvest_culture, cultivation_method, producer, delta_sec, is_anomaly)
    SELECT
        id,
        pallet_ts,
        harvest_culture,
        cultivation_method,
        producer,
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
            harvest_culture,
            cultivation_method,
            producer,
            LAG(pallet_ts) OVER (PARTITION BY harvest_culture ORDER BY pallet_ts) AS prev_pallet_ts
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
-- STEP 6: Update summary function
-- =====================================================

CREATE OR REPLACE FUNCTION get_culture_summary(
    p_harvest_culture TEXT,
    p_start_date TIMESTAMPTZ DEFAULT NULL,
    p_end_date TIMESTAMPTZ DEFAULT NULL
)
RETURNS TABLE (
    harvest_culture TEXT,
    total_pallets BIGINT,
    avg_delta_sec NUMERIC,
    min_delta_sec INTEGER,
    max_delta_sec INTEGER,
    anomaly_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        pa.harvest_culture,
        COUNT(*)::BIGINT AS total_pallets,
        ROUND(AVG(pa.delta_sec), 2) AS avg_delta_sec,
        MIN(pa.delta_sec) AS min_delta_sec,
        MAX(pa.delta_sec) AS max_delta_sec,
        COUNT(*) FILTER (WHERE pa.is_anomaly = TRUE)::BIGINT AS anomaly_count
    FROM pallet_analytics pa
    WHERE pa.harvest_culture = p_harvest_culture
      AND (p_start_date IS NULL OR pa.pallet_ts >= p_start_date)
      AND (p_end_date IS NULL OR pa.pallet_ts <= p_end_date)
      AND pa.delta_sec IS NOT NULL
    GROUP BY pa.harvest_culture;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- STEP 7: Update daily summary table
-- =====================================================

DROP TABLE IF EXISTS daily_shift_summary;

CREATE TABLE IF NOT EXISTS daily_culture_summary (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    summary_date DATE NOT NULL,
    harvest_culture TEXT NOT NULL,
    total_pallets INTEGER NOT NULL,
    avg_delta_sec NUMERIC(10, 2),
    min_delta_sec INTEGER,
    max_delta_sec INTEGER,
    anomaly_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT unique_daily_culture_summary UNIQUE (summary_date, harvest_culture)
);

CREATE INDEX IF NOT EXISTS idx_daily_culture_summary_date
    ON daily_culture_summary(summary_date DESC);

-- =====================================================
-- STEP 8: Update daily summary generation
-- =====================================================

CREATE OR REPLACE FUNCTION generate_daily_summary(
    p_date DATE DEFAULT CURRENT_DATE - INTERVAL '1 day'
)
RETURNS TABLE (
    cultures_processed INTEGER,
    execution_time_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_count INTEGER;
BEGIN
    v_start_time := clock_timestamp();

    -- Delete existing summary for this date
    DELETE FROM daily_culture_summary WHERE summary_date = p_date;

    -- Generate summary for each harvest_culture
    INSERT INTO daily_culture_summary (
        summary_date,
        harvest_culture,
        total_pallets,
        avg_delta_sec,
        min_delta_sec,
        max_delta_sec,
        anomaly_count
    )
    SELECT
        p_date,
        pa.harvest_culture,
        COUNT(*)::INTEGER,
        ROUND(AVG(pa.delta_sec), 2),
        MIN(pa.delta_sec),
        MAX(pa.delta_sec),
        COUNT(*) FILTER (WHERE pa.is_anomaly = TRUE)::INTEGER
    FROM pallet_analytics pa
    WHERE DATE(pa.pallet_ts) = p_date
      AND pa.delta_sec IS NOT NULL
    GROUP BY pa.harvest_culture;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_end_time := clock_timestamp();

    RETURN QUERY SELECT
        v_count,
        EXTRACT(MILLISECONDS FROM (v_end_time - v_start_time))::INTEGER;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- VERIFICATION
-- =====================================================

-- Show updated schema
SELECT
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_name = 'raw_pallets'
  AND table_schema = 'public'
ORDER BY ordinal_position;
