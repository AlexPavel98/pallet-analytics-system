-- =====================================================
-- PALLET ANALYTICS SYSTEM - TRIGGERS
-- =====================================================
-- Purpose: Automatic real-time processing of pallet data
-- =====================================================

-- =====================================================
-- TRIGGER: trigger_calculate_pallet_analytics
-- =====================================================
-- Purpose: Automatically calculate analytics when new pallet is inserted
-- Fires: AFTER INSERT on raw_pallets
-- Calls: calculate_pallet_analytics() function
-- =====================================================

CREATE TRIGGER trigger_calculate_pallet_analytics
    AFTER INSERT ON raw_pallets
    FOR EACH ROW
    EXECUTE FUNCTION calculate_pallet_analytics();

-- =====================================================
-- COMMENTS
-- =====================================================

COMMENT ON TRIGGER trigger_calculate_pallet_analytics ON raw_pallets IS
    'Automatically calculates delta_sec and creates pallet_analytics record when new pallet is inserted from Glide';
