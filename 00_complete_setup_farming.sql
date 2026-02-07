-- =====================================================
-- PALLET ANALYTICS SYSTEM - COMPLETE SETUP (FARMING)
-- =====================================================
-- Purpose: All-in-one SQL for farming/agriculture pallet tracking
-- Run this entire file in Supabase SQL Editor
-- =====================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================
-- TABLE: raw_pallets
-- =====================================================
-- Purpose: Store raw pallet data from Glide
-- Fields mapped to your Glide app
-- =====================================================

CREATE TABLE IF NOT EXISTS raw_pallets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pallet_ts TIMESTAMPTZ NOT NULL,      -- Maps to: "creation date and time"
    harvest_culture TEXT NOT NULL,        -- Maps to: "harvest culture"
    cultivation_method TEXT,              -- Maps to: "cultivation method"
    source TEXT,                          -- Maps to: "source"
    supplier TEXT,                        -- Maps to: "supplier"
    producer TEXT,                        -- Maps to: "producer"
    production_type TEXT,                 -- Maps to: "production type"
    operator TEXT,                        -- Maps to: logged-in user
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- TABLE: pallet_analytics
-- =====================================================
-- Purpose: Store calculated analytics for each pallet
-- delta_sec = time difference vs previous pallet with SAME harvest_culture
-- =====================================================

CREATE TABLE IF NOT EXISTS pallet_analytics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pallet_id UUID NOT NULL REFERENCES raw_pallets(id) ON DELETE CASCADE,
    pallet_ts TIMESTAMPTZ NOT NULL,
    harvest_culture TEXT NOT NULL,
    cultivation_method TEXT,
    producer TEXT,
    delta_sec INTEGER,                    -- Time difference in seconds (NULL for first pallet)
    is_anomaly BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT unique_pallet_analytics UNIQUE (pallet_id)
);

-- =====================================================
-- TABLE: daily_culture_summary
-- =====================================================
-- Purpose: Daily aggregated metrics per harvest culture
-- =====================================================

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

-- =====================================================
-- INDEXES
-- =====================================================

-- Critical: Find previous pallet in same harvest_culture
CREATE INDEX idx_raw_pallets_culture_ts
    ON raw_pallets(harvest_culture, pallet_ts DESC);

-- Analytics queries
CREATE INDEX idx_pallet_analytics_culture_ts
    ON pallet_analytics(harvest_culture, pallet_ts DESC);

-- Time-based queries
CREATE INDEX idx_pallet_analytics_created_at
    ON pallet_analytics(created_at DESC);

-- Foreign key
CREATE INDEX idx_pallet_analytics_pallet_id
    ON pallet_analytics(pallet_id);

-- Daily summaries
CREATE INDEX idx_daily_culture_summary_date
    ON daily_culture_summary(summary_date DESC);

-- =====================================================
-- FUNCTION: calculate_pallet_analytics
-- =====================================================
-- Purpose: Calculate delta_sec for new pallet
-- Compares with previous pallet in SAME harvest_culture
-- =====================================================

CREATE OR REPLACE FUNCTION calculate_pallet_analytics()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_pallet_ts TIMESTAMPTZ;
    v_delta_sec INTEGER;
BEGIN
    -- Find most recent pallet with SAME harvest_culture
    SELECT pallet_ts INTO v_previous_pallet_ts
    FROM raw_pallets
    WHERE harvest_culture = NEW.harvest_culture
      AND pallet_ts < NEW.pallet_ts
    ORDER BY pallet_ts DESC
    LIMIT 1;

    -- Calculate delta_sec
    IF v_previous_pallet_ts IS NOT NULL THEN
        v_delta_sec := EXTRACT(EPOCH FROM (NEW.pallet_ts - v_previous_pallet_ts))::INTEGER;
    ELSE
        v_delta_sec := NULL;  -- First pallet for this culture
    END IF;

    -- Insert analytics
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
-- TRIGGER: Auto-calculate analytics on insert
-- =====================================================

CREATE TRIGGER trigger_calculate_pallet_analytics
    AFTER INSERT ON raw_pallets
    FOR EACH ROW
    EXECUTE FUNCTION calculate_pallet_analytics();

-- =====================================================
-- FUNCTION: recalculate_all_analytics
-- =====================================================
-- Purpose: Batch recalculation of all analytics
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

    DELETE FROM pallet_analytics;

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
-- FUNCTION: get_culture_summary
-- =====================================================
-- Purpose: Get analytics summary for specific harvest culture
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
-- FUNCTION: detect_anomalies
-- =====================================================
-- Purpose: Mark pallets as anomalies based on threshold
-- =====================================================

CREATE OR REPLACE FUNCTION detect_anomalies(
    p_threshold_seconds INTEGER DEFAULT 300
)
RETURNS TABLE (
    updated_count INTEGER
) AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE pallet_analytics SET is_anomaly = FALSE;

    UPDATE pallet_analytics
    SET is_anomaly = TRUE
    WHERE delta_sec > p_threshold_seconds
      AND delta_sec IS NOT NULL;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN QUERY SELECT v_count;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: generate_daily_summary
-- =====================================================
-- Purpose: Generate daily summary for all harvest cultures
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

    DELETE FROM daily_culture_summary WHERE summary_date = p_date;

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
-- FUNCTION: cleanup_old_data
-- =====================================================
-- Purpose: Delete old data (optional maintenance)
-- =====================================================

CREATE OR REPLACE FUNCTION cleanup_old_data(
    p_retention_days INTEGER DEFAULT 365
)
RETURNS TABLE (
    deleted_pallets INTEGER,
    deleted_analytics INTEGER
) AS $$
DECLARE
    v_cutoff_date TIMESTAMPTZ;
    v_pallets_count INTEGER;
    v_analytics_count INTEGER;
BEGIN
    v_cutoff_date := NOW() - (p_retention_days || ' days')::INTERVAL;

    DELETE FROM pallet_analytics WHERE created_at < v_cutoff_date;
    GET DIAGNOSTICS v_analytics_count = ROW_COUNT;

    DELETE FROM raw_pallets WHERE created_at < v_cutoff_date;
    GET DIAGNOSTICS v_pallets_count = ROW_COUNT;

    RETURN QUERY SELECT v_pallets_count, v_analytics_count;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- COMMENTS
-- =====================================================

COMMENT ON TABLE raw_pallets IS
    'Raw pallet data from Glide. Stores farming/agriculture production data.';

COMMENT ON TABLE pallet_analytics IS
    'Calculated analytics per pallet. delta_sec grouped by harvest_culture.';

COMMENT ON COLUMN pallet_analytics.delta_sec IS
    'Time difference in seconds vs previous pallet with SAME harvest_culture. NULL for first pallet.';

COMMENT ON COLUMN raw_pallets.operator IS
    'Logged-in user who created the pallet entry in Glide.';

-- =====================================================
-- VERIFICATION
-- =====================================================

-- Show all tables created
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('raw_pallets', 'pallet_analytics', 'daily_culture_summary')
ORDER BY table_name;
