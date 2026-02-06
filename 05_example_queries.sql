-- =====================================================
-- PALLET ANALYTICS SYSTEM - EXAMPLE QUERIES
-- =====================================================
-- Purpose: Common queries for dashboards and analysis
-- =====================================================

-- =====================================================
-- REAL-TIME MONITORING
-- =====================================================

-- Latest 20 pallets with analytics
SELECT
    rp.pallet_ts,
    rp.shift,
    rp.operator,
    pa.delta_sec,
    ROUND(pa.delta_sec / 60.0, 2) AS delta_minutes,
    pa.is_anomaly
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
ORDER BY rp.pallet_ts DESC
LIMIT 20;

-- Current shift status (last pallet produced)
SELECT
    rp.shift,
    MAX(rp.pallet_ts) AS last_pallet_time,
    COUNT(*) AS pallets_today
FROM raw_pallets rp
WHERE DATE(rp.pallet_ts) = CURRENT_DATE
GROUP BY rp.shift
ORDER BY MAX(rp.pallet_ts) DESC;

-- Real-time anomalies (today)
SELECT
    rp.pallet_ts,
    rp.shift,
    rp.operator,
    pa.delta_sec,
    ROUND(pa.delta_sec / 60.0, 2) AS delta_minutes
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE pa.is_anomaly = TRUE
  AND DATE(rp.pallet_ts) = CURRENT_DATE
ORDER BY rp.pallet_ts DESC;

-- =====================================================
-- SHIFT ANALYSIS
-- =====================================================

-- Today's shift performance
SELECT
    shift,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec), 2) AS avg_delta_sec,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes,
    MIN(delta_sec) AS min_delta_sec,
    MAX(delta_sec) AS max_delta_sec,
    COUNT(*) FILTER (WHERE is_anomaly = TRUE) AS anomalies
FROM pallet_analytics
WHERE DATE(pallet_ts) = CURRENT_DATE
  AND delta_sec IS NOT NULL
GROUP BY shift
ORDER BY shift;

-- Shift comparison (last 7 days)
SELECT
    shift,
    DATE(pallet_ts) AS production_date,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '7 days'
  AND delta_sec IS NOT NULL
GROUP BY shift, DATE(pallet_ts)
ORDER BY production_date DESC, shift;

-- Best and worst performing shifts (last 30 days)
SELECT
    shift,
    DATE(pallet_ts) AS production_date,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
  AND delta_sec IS NOT NULL
GROUP BY shift, DATE(pallet_ts)
ORDER BY avg_delta_minutes ASC
LIMIT 10;

-- =====================================================
-- OPERATOR ANALYSIS
-- =====================================================

-- Operator performance (last 7 days)
SELECT
    rp.operator,
    rp.shift,
    COUNT(*) AS total_pallets,
    ROUND(AVG(pa.delta_sec) / 60.0, 2) AS avg_delta_minutes,
    MIN(pa.delta_sec) AS min_delta_sec,
    MAX(pa.delta_sec) AS max_delta_sec
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE rp.pallet_ts >= CURRENT_DATE - INTERVAL '7 days'
  AND rp.operator IS NOT NULL
  AND pa.delta_sec IS NOT NULL
GROUP BY rp.operator, rp.shift
ORDER BY rp.operator, rp.shift;

-- Top 5 fastest operators
SELECT
    rp.operator,
    COUNT(*) AS total_pallets,
    ROUND(AVG(pa.delta_sec) / 60.0, 2) AS avg_delta_minutes
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE rp.operator IS NOT NULL
  AND pa.delta_sec IS NOT NULL
  AND rp.pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY rp.operator
HAVING COUNT(*) >= 10  -- At least 10 pallets
ORDER BY AVG(pa.delta_sec) ASC
LIMIT 5;

-- =====================================================
-- TREND ANALYSIS
-- =====================================================

-- Daily production volume (last 30 days)
SELECT
    DATE(pallet_ts) AS production_date,
    COUNT(*) AS total_pallets,
    COUNT(DISTINCT shift) AS shifts_active
FROM raw_pallets
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY DATE(pallet_ts)
ORDER BY production_date DESC;

-- Hourly production pattern (last 7 days)
SELECT
    EXTRACT(HOUR FROM pallet_ts) AS hour_of_day,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '7 days'
  AND delta_sec IS NOT NULL
GROUP BY EXTRACT(HOUR FROM pallet_ts)
ORDER BY hour_of_day;

-- Day of week analysis (last 90 days)
SELECT
    TO_CHAR(pallet_ts, 'Day') AS day_of_week,
    EXTRACT(DOW FROM pallet_ts) AS day_number,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '90 days'
  AND delta_sec IS NOT NULL
GROUP BY TO_CHAR(pallet_ts, 'Day'), EXTRACT(DOW FROM pallet_ts)
ORDER BY day_number;

-- =====================================================
-- ANOMALY ANALYSIS
-- =====================================================

-- Anomaly frequency by shift (last 30 days)
SELECT
    shift,
    COUNT(*) AS total_pallets,
    COUNT(*) FILTER (WHERE is_anomaly = TRUE) AS anomaly_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_anomaly = TRUE) / COUNT(*), 2) AS anomaly_percentage
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY shift
ORDER BY anomaly_percentage DESC;

-- Largest delays (top 20)
SELECT
    rp.pallet_ts,
    rp.shift,
    rp.operator,
    pa.delta_sec,
    ROUND(pa.delta_sec / 60.0, 2) AS delta_minutes
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE pa.delta_sec IS NOT NULL
  AND rp.pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
ORDER BY pa.delta_sec DESC
LIMIT 20;

-- =====================================================
-- AGGREGATED REPORTS
-- =====================================================

-- Weekly summary
SELECT
    DATE_TRUNC('week', pallet_ts) AS week_start,
    shift,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes,
    COUNT(*) FILTER (WHERE is_anomaly = TRUE) AS anomalies
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '12 weeks'
  AND delta_sec IS NOT NULL
GROUP BY DATE_TRUNC('week', pallet_ts), shift
ORDER BY week_start DESC, shift;

-- Monthly summary
SELECT
    DATE_TRUNC('month', pallet_ts) AS month_start,
    shift,
    COUNT(*) AS total_pallets,
    ROUND(AVG(delta_sec) / 60.0, 2) AS avg_delta_minutes,
    MIN(delta_sec) AS min_delta_sec,
    MAX(delta_sec) AS max_delta_sec
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '12 months'
  AND delta_sec IS NOT NULL
GROUP BY DATE_TRUNC('month', pallet_ts), shift
ORDER BY month_start DESC, shift;

-- =====================================================
-- DASHBOARD SUMMARY CARD
-- =====================================================

-- Single query for dashboard overview (today)
SELECT
    (SELECT COUNT(*) FROM raw_pallets WHERE DATE(pallet_ts) = CURRENT_DATE) AS total_pallets_today,
    (SELECT ROUND(AVG(delta_sec) / 60.0, 2) FROM pallet_analytics WHERE DATE(pallet_ts) = CURRENT_DATE AND delta_sec IS NOT NULL) AS avg_delta_minutes_today,
    (SELECT COUNT(*) FROM pallet_analytics WHERE DATE(pallet_ts) = CURRENT_DATE AND is_anomaly = TRUE) AS anomalies_today,
    (SELECT COUNT(DISTINCT shift) FROM raw_pallets WHERE DATE(pallet_ts) = CURRENT_DATE) AS active_shifts_today;

-- =====================================================
-- AI/ML READY DATASETS
-- =====================================================

-- Time series data for forecasting (last 90 days)
SELECT
    DATE(pallet_ts) AS date,
    EXTRACT(HOUR FROM pallet_ts) AS hour,
    shift,
    COUNT(*) AS pallet_count,
    AVG(delta_sec) AS avg_delta_sec,
    STDDEV(delta_sec) AS stddev_delta_sec
FROM pallet_analytics
WHERE pallet_ts >= CURRENT_DATE - INTERVAL '90 days'
  AND delta_sec IS NOT NULL
GROUP BY DATE(pallet_ts), EXTRACT(HOUR FROM pallet_ts), shift
ORDER BY date DESC, hour DESC;

-- Feature matrix for anomaly detection
SELECT
    pa.id,
    EXTRACT(DOW FROM pa.pallet_ts) AS day_of_week,
    EXTRACT(HOUR FROM pa.pallet_ts) AS hour_of_day,
    pa.shift,
    pa.delta_sec,
    pa.is_anomaly,
    -- Rolling average (last 10 pallets in same shift)
    AVG(pa2.delta_sec) OVER (
        PARTITION BY pa.shift
        ORDER BY pa.pallet_ts
        ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
    ) AS rolling_avg_10
FROM pallet_analytics pa
LEFT JOIN pallet_analytics pa2 ON pa2.shift = pa.shift AND pa2.pallet_ts < pa.pallet_ts
WHERE pa.pallet_ts >= CURRENT_DATE - INTERVAL '30 days'
  AND pa.delta_sec IS NOT NULL
ORDER BY pa.pallet_ts DESC;
