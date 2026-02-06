# Setup Guide - Step by Step

Follow these steps to set up your Pallet Analytics System.

## Prerequisites

- Supabase account (free tier works fine)
- Glide account with an app
- Basic understanding of SQL (helpful but not required)

## Step-by-Step Setup

### 1. Create Supabase Project

1. Go to https://app.supabase.com
2. Click **"New Project"**
3. Fill in:
   - **Name**: `pallet-analytics` (or your preferred name)
   - **Database Password**: Choose a strong password (save it!)
   - **Region**: Select closest to your location
4. Click **"Create new project"**
5. Wait 2-3 minutes for project to be ready

### 2. Run SQL Scripts

1. In Supabase dashboard, click **"SQL Editor"** in left sidebar
2. Click **"New query"**
3. Copy the entire content of `01_schema.sql` and paste it
4. Click **"Run"** (or press Cmd/Ctrl + Enter)
5. You should see: "Success. No rows returned"

Repeat for:
- `02_functions.sql`
- `03_triggers.sql`
- `04_batch_processing.sql` (optional, for daily summaries)

### 3. Verify Installation

Run this query to verify tables exist:

```sql
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('raw_pallets', 'pallet_analytics', 'daily_shift_summary')
ORDER BY table_name;
```

You should see all three tables listed.

### 4. Get Supabase Credentials

1. In Supabase dashboard, click **"Settings"** (gear icon)
2. Click **"API"** in left menu
3. Copy these values (you'll need them for Glide):
   - **Project URL**: `https://xxxxx.supabase.co`
   - **anon/public key**: Long string starting with `eyJ...`
   - **service_role key**: Another long string (keep this SECRET!)

### 5. Connect Glide to Supabase

#### Option A: If Glide has native Supabase integration

1. In Glide, go to **Data** tab
2. Click **"Add Source"** or **"+"**
3. Select **"Supabase"**
4. Enter:
   - **URL**: Your Project URL
   - **API Key**: Use **service_role key** (for write access)
5. Click **"Connect"**
6. Select `raw_pallets` table

#### Option B: If using Supabase REST API

1. In Glide, add **"Call API"** action
2. Configure:
   - **Method**: POST
   - **URL**: `https://YOUR_PROJECT.supabase.co/rest/v1/raw_pallets`
   - **Headers**:
     ```
     apikey: YOUR_SERVICE_ROLE_KEY
     Authorization: Bearer YOUR_SERVICE_ROLE_KEY
     Content-Type: application/json
     Prefer: return=minimal
     ```
   - **Body**:
     ```json
     {
       "pallet_ts": "{{current_timestamp}}",
       "shift": "{{shift_value}}",
       "operator": "{{operator_name}}"
     }
     ```

### 6. Test the System

#### Test 1: Insert sample data

In Supabase SQL Editor:

```sql
-- Insert 3 test pallets in morning shift
INSERT INTO raw_pallets (pallet_ts, shift, operator) VALUES
    (NOW() - INTERVAL '10 minutes', 'morning', 'TestUser'),
    (NOW() - INTERVAL '5 minutes', 'morning', 'TestUser'),
    (NOW(), 'morning', 'TestUser');
```

#### Test 2: Verify analytics were calculated

```sql
SELECT
    rp.pallet_ts,
    rp.shift,
    pa.delta_sec,
    ROUND(pa.delta_sec / 60.0, 2) AS delta_minutes
FROM raw_pallets rp
JOIN pallet_analytics pa ON pa.pallet_id = rp.id
WHERE rp.shift = 'morning'
ORDER BY rp.pallet_ts DESC
LIMIT 3;
```

Expected results:
- First row: `delta_sec` should be ~300 (5 minutes)
- Second row: `delta_sec` should be ~300 (5 minutes)
- Third row: `delta_sec` = NULL (first pallet)

✅ If you see this, your system is working!

### 7. Configure Glide Form

1. Create a form in Glide for pallet entry
2. Add fields:
   - **Timestamp**: Use **Now** component (auto-filled)
   - **Shift**: Dropdown with options: "morning", "afternoon", "night"
   - **Operator**: Text input or user email
3. On form submit, write to `raw_pallets` table

### 8. Create Dashboard (Optional)

#### In Glide:

1. Add a new screen
2. Add **Collection** component
3. Connect to `pallet_analytics` table (via Supabase)
4. Show columns:
   - `pallet_ts`
   - `shift`
   - `delta_sec` (or calculate `delta_sec / 60` for minutes)
   - `is_anomaly`

#### In Supabase (for external dashboards):

Use queries from `05_example_queries.sql`:
- Today's performance
- Shift comparison
- Operator statistics

### 9. Enable Daily Summaries (Optional)

If you want automated daily reports:

```sql
-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule daily summary at 1 AM
SELECT cron.schedule(
    'generate-daily-pallet-summary',
    '0 1 * * *',
    $$SELECT generate_daily_summary(CURRENT_DATE - INTERVAL '1 day')$$
);
```

### 10. Security Setup (Important!)

#### For production use:

1. In Supabase, go to **Authentication** → **Policies**
2. Enable RLS (Row Level Security) on tables:

```sql
-- Enable RLS
ALTER TABLE raw_pallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE pallet_analytics ENABLE ROW LEVEL SECURITY;

-- Allow Glide to insert (using service_role key bypasses RLS)
-- Allow public to read analytics
CREATE POLICY "Allow public read access"
    ON pallet_analytics FOR SELECT
    USING (true);
```

## Troubleshooting

### Problem: Analytics not being created

**Solution**: Check if trigger is active:
```sql
SELECT * FROM pg_trigger WHERE tgname = 'trigger_calculate_pallet_analytics';
```

If empty, re-run `03_triggers.sql`.

### Problem: "Permission denied" error

**Solution**: Use **service_role key** instead of anon key in Glide.

### Problem: Wrong delta_sec values

**Solution**: Recalculate all analytics:
```sql
SELECT * FROM recalculate_all_analytics();
```

### Problem: Glide not connecting

**Solution**:
1. Check if Project URL is correct
2. Ensure service_role key is copied correctly (no spaces)
3. Try using REST API approach instead

## What's Next?

1. **Monitor**: Check dashboard daily
2. **Tune**: Adjust anomaly threshold (`detect_anomalies(300)` → change 300)
3. **Expand**: Add more fields (product type, quality, etc.)
4. **AI Analysis**: Use `pallet_analytics` data for predictions

## Need Help?

1. Check Supabase logs: Dashboard → Logs → Database
2. Review error messages in SQL Editor
3. Test queries from `05_example_queries.sql`
4. Verify data: `SELECT * FROM raw_pallets ORDER BY created_at DESC LIMIT 5;`

## Common Adjustments

### Change shift names

Edit your INSERT statements and Glide dropdown to match your shifts:
- "day", "night"
- "shift-a", "shift-b", "shift-c"
- "6am-2pm", "2pm-10pm", "10pm-6am"

### Add more fields to raw_pallets

```sql
ALTER TABLE raw_pallets
ADD COLUMN product_type TEXT,
ADD COLUMN quality_score INTEGER;

-- Also add to pallet_analytics for denormalization
ALTER TABLE pallet_analytics
ADD COLUMN product_type TEXT;
```

Update trigger function accordingly.

## Success Checklist

- [ ] Supabase project created
- [ ] All 4 SQL files executed successfully
- [ ] Test data inserted and analytics calculated correctly
- [ ] Glide connected to Supabase
- [ ] Form in Glide writes to `raw_pallets`
- [ ] Dashboard shows `pallet_analytics` data
- [ ] (Optional) Daily summaries scheduled
- [ ] (Optional) Row Level Security configured

🎉 **Congratulations!** Your pallet analytics system is ready for production!
