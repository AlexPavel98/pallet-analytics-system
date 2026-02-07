-- =====================================================
-- ADD BREAK TRACKING TO PALLET ANALYTICS
-- =====================================================
-- Purpose: Track breaks and calculate net working time between pallets
-- Use case: Exclude break time from delta calculations
-- =====================================================

-- =====================================================
-- TABLE: breaks
-- =====================================================
-- Purpose: Store break data from Glide break tracking app
-- Glide app will write to this table
--
-- GLIDE FIELD MAPPING:
--   Glide "Start time" → break_start
--   Glide "End time"   → break_end
-- =====================================================

CREATE TABLE IF NOT EXISTS breaks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    break_start TIMESTAMPTZ NOT NULL,    -- Maps to Glide "Start time"
    break_end TIMESTAMPTZ NOT NULL,      -- Maps to Glide "End time"
    operator TEXT,                        -- Optional: who took the break
    break_type TEXT,                      -- Optional: lunch, coffee, etc.
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Ensure break_end is after break_start
    CONSTRAINT valid_break_duration CHECK (break_end > break_start)
);

-- Index for finding breaks between two timestamps (most critical query)
CREATE INDEX idx_breaks_time_range
    ON breaks(break_start, break_end);

-- Index for operator-specific queries (if needed later)
CREATE INDEX idx_breaks_operator
    ON breaks(operator);

-- =====================================================
-- UPDATE: pallet_analytics table
-- =====================================================
-- Add columns for gross and net delta
-- =====================================================

ALTER TABLE pallet_analytics
    ADD COLUMN IF NOT EXISTS gross_delta_sec INTEGER,  -- Total time including breaks
    ADD COLUMN IF NOT EXISTS break_duration_sec INTEGER DEFAULT 0,  -- Total break time
    ADD COLUMN IF NOT EXISTS net_delta_sec INTEGER;     -- Working time (gross - breaks)

-- Update existing column comment
COMMENT ON COLUMN pallet_analytics.delta_sec IS
    'DEPRECATED: Use net_delta_sec instead. Kept for backwards compatibility.';

COMMENT ON COLUMN pallet_analytics.gross_delta_sec IS
    'Total time in seconds between pallets (including breaks)';

COMMENT ON COLUMN pallet_analytics.break_duration_sec IS
    'Total break time in seconds that occurred between this pallet and previous pallet';

COMMENT ON COLUMN pallet_analytics.net_delta_sec IS
    'Actual working time in seconds (gross_delta_sec - break_duration_sec)';

-- =====================================================
-- FUNCTION: calculate_break_duration
-- =====================================================
-- Purpose: Calculate total break time between two timestamps
-- Returns: Total seconds of breaks
-- =====================================================

CREATE OR REPLACE FUNCTION calculate_break_duration(
    p_start_time TIMESTAMPTZ,
    p_end_time TIMESTAMPTZ
)
RETURNS INTEGER AS $$
DECLARE
    v_total_break_sec INTEGER;
BEGIN
    -- Sum all break durations that overlap with the time range
    SELECT COALESCE(
        SUM(
            EXTRACT(EPOCH FROM (
                LEAST(break_end, p_end_time) - GREATEST(break_start, p_start_time)
            ))
        )::INTEGER,
        0
    ) INTO v_total_break_sec
    FROM breaks
    WHERE break_start < p_end_time
      AND break_end > p_start_time;

    RETURN v_total_break_sec;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: calculate_pallet_analytics (UPDATED)
-- =====================================================
-- Purpose: Calculate analytics INCLUDING break tracking
-- =====================================================

CREATE OR REPLACE FUNCTION calculate_pallet_analytics()
RETURNS TRIGGER AS $$
DECLARE
    v_previous_pallet_ts TIMESTAMPTZ;
    v_gross_delta_sec INTEGER;
    v_break_duration_sec INTEGER;
    v_net_delta_sec INTEGER;
BEGIN
    -- Find most recent pallet with SAME harvest_culture
    SELECT pallet_ts INTO v_previous_pallet_ts
    FROM raw_pallets
    WHERE harvest_culture = NEW.harvest_culture
      AND pallet_ts < NEW.pallet_ts
    ORDER BY pallet_ts DESC
    LIMIT 1;

    -- Calculate deltas
    IF v_previous_pallet_ts IS NOT NULL THEN
        -- Gross delta (total time)
        v_gross_delta_sec := EXTRACT(EPOCH FROM (NEW.pallet_ts - v_previous_pallet_ts))::INTEGER;

        -- Calculate break duration between previous and current pallet
        v_break_duration_sec := calculate_break_duration(v_previous_pallet_ts, NEW.pallet_ts);

        -- Net delta (working time)
        v_net_delta_sec := v_gross_delta_sec - v_break_duration_sec;
    ELSE
        -- First pallet for this culture
        v_gross_delta_sec := NULL;
        v_break_duration_sec := 0;
        v_net_delta_sec := NULL;
    END IF;

    -- Insert analytics with break-adjusted values
    INSERT INTO pallet_analytics (
        pallet_id,
        pallet_ts,
        harvest_culture,
        cultivation_method,
        producer,
        delta_sec,              -- Keep for backwards compatibility
        gross_delta_sec,
        break_duration_sec,
        net_delta_sec,
        is_anomaly
    ) VALUES (
        NEW.id,
        NEW.pallet_ts,
        NEW.harvest_culture,
        NEW.cultivation_method,
        NEW.producer,
        v_net_delta_sec,        -- delta_sec = net (working time)
        v_gross_delta_sec,
        v_break_duration_sec,
        v_net_delta_sec,
        FALSE
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- FUNCTION: recalculate_all_analytics (UPDATED)
-- =====================================================
-- Purpose: Recalculate all analytics including break adjustments
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

    INSERT INTO pallet_analytics (
        pallet_id,
        pallet_ts,
        harvest_culture,
        cultivation_method,
        producer,
        gross_delta_sec,
        break_duration_sec,
        net_delta_sec,
        delta_sec,
        is_anomaly
    )
    SELECT
        id,
        pallet_ts,
        harvest_culture,
        cultivation_method,
        producer,
        gross_delta_sec,
        break_duration_sec,
        net_delta_sec,
        net_delta_sec AS delta_sec,  -- Backwards compatibility
        FALSE AS is_anomaly
    FROM (
        SELECT
            rp.id,
            rp.pallet_ts,
            rp.harvest_culture,
            rp.cultivation_method,
            rp.producer,
            CASE
                WHEN prev_pallet_ts IS NOT NULL THEN
                    EXTRACT(EPOCH FROM (rp.pallet_ts - prev_pallet_ts))::INTEGER
                ELSE
                    NULL
            END AS gross_delta_sec,
            CASE
                WHEN prev_pallet_ts IS NOT NULL THEN
                    calculate_break_duration(prev_pallet_ts, rp.pallet_ts)
                ELSE
                    0
            END AS break_duration_sec,
            CASE
                WHEN prev_pallet_ts IS NOT NULL THEN
                    EXTRACT(EPOCH FROM (rp.pallet_ts - prev_pallet_ts))::INTEGER
                    - calculate_break_duration(prev_pallet_ts, rp.pallet_ts)
                ELSE
                    NULL
            END AS net_delta_sec,
            prev_pallet_ts
        FROM (
            SELECT
                id,
                pallet_ts,
                harvest_culture,
                cultivation_method,
                producer,
                LAG(pallet_ts) OVER (PARTITION BY harvest_culture ORDER BY pallet_ts) AS prev_pallet_ts
            FROM raw_pallets
        ) rp
    ) AS pallet_with_breaks;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_end_time := clock_timestamp();

    RETURN QUERY SELECT
        v_count,
        EXTRACT(MILLISECONDS FROM (v_end_time - v_start_time))::INTEGER;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- HELPER VIEWS
-- =====================================================

-- View: Pallets with break impact
CREATE OR REPLACE VIEW v_pallet_analytics_with_breaks AS
SELECT
    pa.pallet_id,
    rp.pallet_ts,
    rp.harvest_culture,
    rp.operator,
    pa.gross_delta_sec,
    pa.break_duration_sec,
    pa.net_delta_sec,
    ROUND(pa.gross_delta_sec / 60.0, 2) AS gross_delta_minutes,
    ROUND(pa.break_duration_sec / 60.0, 2) AS break_duration_minutes,
    ROUND(pa.net_delta_sec / 60.0, 2) AS net_delta_minutes,
    CASE
        WHEN pa.gross_delta_sec > 0 THEN
            ROUND(100.0 * pa.break_duration_sec / pa.gross_delta_sec, 2)
        ELSE
            0
    END AS break_percentage
FROM pallet_analytics pa
JOIN raw_pallets rp ON rp.id = pa.pallet_id
WHERE pa.net_delta_sec IS NOT NULL
ORDER BY rp.pallet_ts DESC;

-- =====================================================
-- EXAMPLE QUERIES
-- =====================================================

-- Show pallets with break impact
-- SELECT * FROM v_pallet_analytics_with_breaks LIMIT 10;

-- Find pallets with high break percentage
-- SELECT * FROM v_pallet_analytics_with_breaks
-- WHERE break_percentage > 20
-- ORDER BY break_percentage DESC;

-- Summary by harvest culture (with break impact)
-- SELECT
--     harvest_culture,
--     COUNT(*) AS total_pallets,
--     ROUND(AVG(gross_delta_minutes), 2) AS avg_gross_minutes,
--     ROUND(AVG(break_duration_minutes), 2) AS avg_break_minutes,
--     ROUND(AVG(net_delta_minutes), 2) AS avg_net_minutes,
--     ROUND(AVG(break_percentage), 2) AS avg_break_percentage
-- FROM v_pallet_analytics_with_breaks
-- GROUP BY harvest_culture;

-- =====================================================
-- COMMENTS
-- =====================================================

COMMENT ON TABLE breaks IS
    'Break tracking data from Glide break app. Used to calculate net working time between pallets.';

COMMENT ON FUNCTION calculate_break_duration IS
    'Calculates total break duration (in seconds) between two timestamps, handling overlapping breaks.';
