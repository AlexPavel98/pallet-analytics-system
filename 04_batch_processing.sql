-- =====================================================
-- PALLET ANALYTICS SYSTEM - BATCH PROCESSING
-- =====================================================
-- Purpose: Daily aggregations and scheduled jobs
-- =====================================================

-- =====================================================
-- TABLE: daily_shift_summary
-- =====================================================
-- Purpose: Store daily aggregated metrics per shift
-- Updated by: Scheduled cron job (daily)
-- =====================================================

CREATE TABLE IF NOT EXISTS daily_shift_summary (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    summary_date DATE NOT NULL,
    shift TEXT NOT NULL,
    total_pallets INTEGER NOT NULL,
    avg_delta_sec NUMERIC(10, 2),
    min_delta_sec INTEGER,
    max_delta_sec INTEGER,
    anomaly_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Ensure one summary per shift per day
    CONSTRAINT unique_daily_shift_summary UNIQUE (summary_date, shift)
);

-- Index for querying by date range
CREATE INDEX IF NOT EXISTS idx_daily_shift_summary_date
    ON daily_shift_summary(summary_date DESC);

-- =====================================================
-- FUNCTION: generate_daily_summary
-- =====================================================
-- Purpose: Generate daily summary for all shifts
-- Usage: Called by cron job daily at end of day
-- =====================================================

CREATE OR REPLACE FUNCTION generate_daily_summary(
    p_date DATE DEFAULT CURRENT_DATE - INTERVAL '1 day'
)
RETURNS TABLE (
    shifts_processed INTEGER,
    execution_time_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
    v_count INTEGER;
BEGIN
    v_start_time := clock_timestamp();

    -- Delete existing summary for this date (idempotent)
    DELETE FROM daily_shift_summary WHERE summary_date = p_date;

    -- Generate summary for each shift
    INSERT INTO daily_shift_summary (
        summary_date,
        shift,
        total_pallets,
        avg_delta_sec,
        min_delta_sec,
        max_delta_sec,
        anomaly_count
    )
    SELECT
        p_date,
        pa.shift,
        COUNT(*)::INTEGER,
        ROUND(AVG(pa.delta_sec), 2),
        MIN(pa.delta_sec),
        MAX(pa.delta_sec),
        COUNT(*) FILTER (WHERE pa.is_anomaly = TRUE)::INTEGER
    FROM pallet_analytics pa
    WHERE DATE(pa.pallet_ts) = p_date
      AND pa.delta_sec IS NOT NULL  -- Exclude first pallet
    GROUP BY pa.shift;

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
-- Purpose: Archive or delete old data (optional)
-- Usage: Called by cron job (e.g., monthly)
-- Warning: Adjust retention period based on requirements
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

    -- Delete old analytics first (due to foreign key)
    DELETE FROM pallet_analytics
    WHERE created_at < v_cutoff_date;

    GET DIAGNOSTICS v_analytics_count = ROW_COUNT;

    -- Delete old raw pallets
    DELETE FROM raw_pallets
    WHERE created_at < v_cutoff_date;

    GET DIAGNOSTICS v_pallets_count = ROW_COUNT;

    RETURN QUERY SELECT v_pallets_count, v_analytics_count;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- SUPABASE CRON JOBS
-- =====================================================
-- Purpose: Schedule automated tasks
-- Note: Requires pg_cron extension enabled in Supabase
-- =====================================================

-- Enable pg_cron extension (run as superuser in Supabase dashboard)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Example: Daily summary generation at 1 AM
-- SELECT cron.schedule(
--     'generate-daily-pallet-summary',  -- Job name
--     '0 1 * * *',                       -- Cron expression: 1 AM daily
--     $$SELECT generate_daily_summary(CURRENT_DATE - INTERVAL '1 day')$$
-- );

-- Example: Detect anomalies every hour
-- SELECT cron.schedule(
--     'detect-pallet-anomalies',        -- Job name
--     '0 * * * *',                       -- Cron expression: Every hour
--     $$SELECT detect_anomalies(300)$$  -- 5 minutes threshold
-- );

-- Example: Monthly cleanup (first day of month at 2 AM)
-- SELECT cron.schedule(
--     'cleanup-old-pallet-data',        -- Job name
--     '0 2 1 * *',                       -- Cron expression: 2 AM on 1st of month
--     $$SELECT cleanup_old_data(365)$$  -- Keep 1 year of data
-- );

-- =====================================================
-- USEFUL QUERIES FOR MONITORING
-- =====================================================

-- View all scheduled cron jobs
-- SELECT * FROM cron.job;

-- View cron job execution history
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- Unschedule a job
-- SELECT cron.unschedule('job-name-here');
