# Pallet Analytics System

A production-ready analytics system for tracking pallet production times using Supabase and Glide.

## System Overview

**Data Flow:**
```
Glide (Input) → raw_pallets (Storage) → pallet_analytics (Calculated) → Dashboard/AI
```

**Core Principle:**
- Glide is READ-ONLY (no calculations)
- All logic happens in Supabase backend
- One pallet = One row
- Real-time processing + Daily aggregations

## Features

✅ **Real-time Processing**: Automatic calculation on each pallet insert
✅ **Shift-based Analytics**: Delta calculations per shift
✅ **Anomaly Detection**: Flag unusual time gaps
✅ **Daily Summaries**: Automated aggregation for reporting
✅ **Production Ready**: Indexes, constraints, error handling

## Database Schema

### Tables

1. **raw_pallets** - Input data from Glide
   - `id` (UUID)
   - `pallet_ts` (timestamp with timezone)
   - `shift` (text) - e.g., "morning", "afternoon", "night"
   - `operator` (text, optional)
   - `created_at` (timestamp)

2. **pallet_analytics** - Calculated metrics
   - `id` (UUID)
   - `pallet_id` (FK to raw_pallets)
   - `pallet_ts` (denormalized)
   - `shift` (denormalized)
   - `delta_sec` (integer) - Time difference vs previous pallet in same shift
   - `is_anomaly` (boolean)
   - `created_at` (timestamp)

3. **daily_shift_summary** - Daily aggregations
   - `summary_date` (date)
   - `shift` (text)
   - `total_pallets`, `avg_delta_sec`, `min_delta_sec`, `max_delta_sec`
   - `anomaly_count`

## Installation

### Step 1: Set up Supabase

1. Go to [Supabase Dashboard](https://app.supabase.com)
2. Create a new project or select existing one
3. Go to **SQL Editor** in the left sidebar

### Step 2: Run SQL Scripts in Order

Execute these files in the SQL Editor:

```sql
-- 1. Create tables and indexes
-- Copy and paste: 01_schema.sql

-- 2. Create calculation functions
-- Copy and paste: 02_functions.sql

-- 3. Create triggers
-- Copy and paste: 03_triggers.sql

-- 4. Create batch processing (optional)
-- Copy and paste: 04_batch_processing.sql
```

### Step 3: Connect Glide to Supabase

1. In Glide, go to **Data** → **Add Source** → **Supabase**
2. Enter your Supabase credentials:
   - **URL**: `https://YOUR_PROJECT.supabase.co`
   - **Anon Key**: Found in Settings → API
3. Map Glide table to `raw_pallets`
4. Map columns:
   - Timestamp → `pallet_ts`
   - Shift → `shift`
   - Operator → `operator`

### Step 4: Configure Real-time Updates (Optional)

Enable real-time in Supabase:
1. Go to **Database** → **Replication**
2. Enable replication for `pallet_analytics` table

## Usage

### Inserting Data from Glide

When a new pallet is created in Glide, it automatically:
1. Inserts into `raw_pallets`
2. Trigger fires `calculate_pallet_analytics()`
3. Calculates `delta_sec` vs previous pallet in same shift
4. Inserts result into `pallet_analytics`

### Querying Analytics

```sql
-- Get latest 10 pallets with analytics
SELECT
    rp.pallet_ts,
    rp.shift,
    rp.operator,
    pa.delta_sec,
    pa.is_anomaly
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
ORDER BY rp.pallet_ts DESC
LIMIT 10;

-- Get shift summary for today
SELECT * FROM get_shift_summary('morning', CURRENT_DATE, CURRENT_DATE + INTERVAL '1 day');

-- Get daily summary for last 7 days
SELECT *
FROM daily_shift_summary
WHERE summary_date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY summary_date DESC, shift;
```

### Manual Operations

```sql
-- Recalculate all analytics (if needed)
SELECT * FROM recalculate_all_analytics();

-- Detect anomalies (threshold: 5 minutes = 300 seconds)
SELECT * FROM detect_anomalies(300);

-- Generate daily summary for yesterday
SELECT * FROM generate_daily_summary(CURRENT_DATE - INTERVAL '1 day');
```

## Scheduled Jobs (Optional)

To enable automated tasks, you need `pg_cron` extension:

1. In Supabase dashboard, go to **SQL Editor**
2. Run: `CREATE EXTENSION IF NOT EXISTS pg_cron;`
3. Schedule jobs (examples in `04_batch_processing.sql`):

```sql
-- Daily summary at 1 AM
SELECT cron.schedule(
    'generate-daily-pallet-summary',
    '0 1 * * *',
    $$SELECT generate_daily_summary(CURRENT_DATE - INTERVAL '1 day')$$
);

-- Hourly anomaly detection
SELECT cron.schedule(
    'detect-pallet-anomalies',
    '0 * * * *',
    $$SELECT detect_anomalies(300)$$
);
```

## Architecture Decisions

### Why Triggers Instead of Edge Functions?

- **Lower latency**: Database trigger = milliseconds
- **Guaranteed execution**: Runs in same transaction
- **Simpler deployment**: No external service needed
- **Atomic operations**: Either both succeed or both fail

### Why Denormalize pallet_ts and shift?

- **Query performance**: No JOIN needed for analytics queries
- **Index efficiency**: Direct filtering on analytics table
- **Trade-off**: 16 extra bytes per row for 10x faster queries

### Why delta_sec is NULL for first pallet?

- **Mathematical accuracy**: No previous pallet = no delta
- **AI interpretation**: Let AI layer decide how to handle
- **Prevents errors**: Avoids arbitrary "0" or "-1" values

## Performance Considerations

### Indexes

Critical indexes created:
- `idx_raw_pallets_shift_ts` - For finding previous pallet (MOST CRITICAL)
- `idx_pallet_analytics_shift_ts` - For shift-based queries
- `idx_pallet_analytics_pallet_id` - For JOIN operations

### Expected Performance

- **Insert + Calculate**: < 10ms (with proper indexes)
- **Query last 100 pallets**: < 5ms
- **Daily summary generation**: < 100ms for 10,000 pallets

### Scaling

This system can handle:
- **1,000+ pallets/day** easily
- **10,000+ pallets/day** with proper indexing
- **100,000+ pallets/day** requires partitioning (contact for guidance)

## Testing

### Test Data Insertion

```sql
-- Insert test pallets for morning shift
INSERT INTO raw_pallets (pallet_ts, shift, operator) VALUES
    ('2024-01-15 08:00:00+00', 'morning', 'John'),
    ('2024-01-15 08:05:30+00', 'morning', 'John'),
    ('2024-01-15 08:11:00+00', 'morning', 'John');

-- Check analytics were calculated
SELECT
    rp.pallet_ts,
    rp.shift,
    pa.delta_sec,
    pa.delta_sec / 60.0 AS delta_minutes
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE rp.shift = 'morning'
ORDER BY rp.pallet_ts;

-- Expected results:
-- Row 1: delta_sec = NULL (first pallet)
-- Row 2: delta_sec = 330 (5 min 30 sec)
-- Row 3: delta_sec = 330 (5 min 30 sec)
```

## Troubleshooting

### Analytics not being created

```sql
-- Check if trigger exists
SELECT * FROM pg_trigger WHERE tgname = 'trigger_calculate_pallet_analytics';

-- Check if function exists
SELECT * FROM pg_proc WHERE proname = 'calculate_pallet_analytics';

-- Re-create trigger if needed
DROP TRIGGER IF EXISTS trigger_calculate_pallet_analytics ON raw_pallets;
-- Then run 03_triggers.sql again
```

### Incorrect delta_sec values

```sql
-- Recalculate all analytics
SELECT * FROM recalculate_all_analytics();

-- Verify specific shift
SELECT
    pallet_ts,
    shift,
    delta_sec,
    LAG(pallet_ts) OVER (PARTITION BY shift ORDER BY pallet_ts) AS prev_ts
FROM pallet_analytics
WHERE shift = 'morning'
ORDER BY pallet_ts;
```

## Next Steps

1. **Dashboard Integration**: Connect Power BI / Metabase / Grafana to `pallet_analytics`
2. **AI Analysis**: Use `pallet_analytics` for ML predictions
3. **Alerting**: Set up notifications for anomalies
4. **Mobile App**: Show real-time analytics from `pallet_analytics` table

## Security Notes

- Glide should use **Service Role Key** for write access to `raw_pallets`
- Dashboard/AI should use **Anon Key** with Row Level Security (RLS)
- Never expose Service Role Key in frontend code

## Support

For issues or questions:
1. Check Supabase logs in Dashboard → Logs
2. Test queries in SQL Editor
3. Review this README's Troubleshooting section

## License

MIT
