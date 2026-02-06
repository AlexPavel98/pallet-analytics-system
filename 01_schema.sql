-- =====================================================
-- PALLET ANALYTICS SYSTEM - SCHEMA
-- =====================================================
-- Purpose: Store raw pallet data and calculated analytics
-- Data Flow: Glide → raw_pallets → pallet_analytics
-- =====================================================

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================
-- TABLE: raw_pallets
-- =====================================================
-- Purpose: Store raw pallet data from Glide (READ-ONLY source)
-- No calculations allowed here - pure input data only
-- =====================================================

CREATE TABLE IF NOT EXISTS raw_pallets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pallet_ts TIMESTAMPTZ NOT NULL,  -- When pallet was produced
    shift TEXT NOT NULL,               -- Shift identifier (e.g., "morning", "afternoon", "night")
    operator TEXT,                     -- Optional operator name
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- TABLE: pallet_analytics
-- =====================================================
-- Purpose: Store calculated analytics for each pallet
-- All calculations happen in the backend, not in Glide
-- =====================================================

CREATE TABLE IF NOT EXISTS pallet_analytics (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pallet_id UUID NOT NULL REFERENCES raw_pallets(id) ON DELETE CASCADE,
    pallet_ts TIMESTAMPTZ NOT NULL,   -- Denormalized for query performance
    shift TEXT NOT NULL,               -- Denormalized for query performance
    delta_sec INTEGER,                 -- Time difference vs previous pallet in SAME shift (NULL for first pallet)
    is_anomaly BOOLEAN DEFAULT FALSE,  -- Flag for anomaly detection (future use)
    created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Constraints
    CONSTRAINT unique_pallet_analytics UNIQUE (pallet_id)
);

-- =====================================================
-- INDEXES FOR PERFORMANCE
-- =====================================================
-- Critical for lookup of previous pallet in same shift
-- =====================================================

-- Index for finding previous pallet in same shift (most critical query)
CREATE INDEX IF NOT EXISTS idx_raw_pallets_shift_ts
    ON raw_pallets(shift, pallet_ts DESC);

-- Index for analytics queries
CREATE INDEX IF NOT EXISTS idx_pallet_analytics_shift_ts
    ON pallet_analytics(shift, pallet_ts DESC);

-- Index for time-based queries
CREATE INDEX IF NOT EXISTS idx_pallet_analytics_created_at
    ON pallet_analytics(created_at DESC);

-- Foreign key index
CREATE INDEX IF NOT EXISTS idx_pallet_analytics_pallet_id
    ON pallet_analytics(pallet_id);

-- =====================================================
-- COMMENTS
-- =====================================================

COMMENT ON TABLE raw_pallets IS
    'Raw pallet data from Glide. No calculations allowed. One row per pallet.';

COMMENT ON TABLE pallet_analytics IS
    'Calculated analytics for each pallet. All calculations happen in backend.';

COMMENT ON COLUMN pallet_analytics.delta_sec IS
    'Time difference in seconds between current pallet and previous pallet in SAME shift. NULL for first pallet in shift.';

COMMENT ON COLUMN pallet_analytics.is_anomaly IS
    'Boolean flag for anomaly detection. Can be updated by AI/ML layer later.';
