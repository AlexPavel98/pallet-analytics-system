# Glide to Supabase API Integration Guide

## Overview
Since direct PostgreSQL connection doesn't work, we'll use Supabase's REST API to send pallet data from Glide.

## Setup Instructions

### Step 1: Get Your Supabase Credentials

You need:
- **Project URL**: `https://xxxxx.supabase.co`
- **service_role key**: `eyJ...` (the long key)

### Step 2: Create API Action in Glide

#### For Pallet Submission:

1. **In your Glide pallet form**, go to the **Submit button**
2. Add action: **"Call API"** or **"Webhook"**
3. Configure as follows:

**Method**: `POST`

**URL**:
```
https://YOUR_PROJECT_URL/rest/v1/raw_pallets
```
Replace `YOUR_PROJECT_URL` with your actual Supabase URL (e.g., `https://vkfxqkilbyduveqnqhwt.supabase.co`)

**Headers**:
```
apikey: YOUR_SERVICE_ROLE_KEY
Authorization: Bearer YOUR_SERVICE_ROLE_KEY
Content-Type: application/json
Prefer: return=minimal
```

Replace `YOUR_SERVICE_ROLE_KEY` with your actual service_role key.

**Body** (JSON format):
```json
{
  "pallet_ts": "{{creation_date_and_time}}",
  "harvest_culture": "{{harvest_culture}}",
  "cultivation_method": "{{cultivation_method}}",
  "source": "{{source}}",
  "supplier": "{{supplier}}",
  "producer": "{{producer}}",
  "production_type": "{{production_type}}",
  "operator": "{{user_email}}"
}
```

**Field Mapping** (Replace `{{...}}` with your actual Glide field names):
- `{{creation_date_and_time}}` → Your timestamp field (format: ISO 8601)
- `{{harvest_culture}}` → Your harvest culture field
- `{{cultivation_method}}` → Your cultivation method field
- `{{source}}` → Your source field
- `{{supplier}}` → Your supplier field
- `{{producer}}` → Your producer field
- `{{production_type}}` → Your production type field
- `{{user_email}}` → Logged-in user's email

### Step 3: Test the Integration

1. Fill out your Glide form
2. Submit it
3. Go to Supabase SQL Editor
4. Run:
```sql
SELECT * FROM raw_pallets ORDER BY created_at DESC LIMIT 1;
```
5. You should see your new pallet!

6. Check analytics were calculated:
```sql
SELECT * FROM pallet_analytics ORDER BY created_at DESC LIMIT 1;
```

---

## For Break Tracking App

### Create API Action for Breaks:

**Method**: `POST`

**URL**:
```
https://YOUR_PROJECT_URL/rest/v1/breaks
```

**Headers**: (same as above)
```
apikey: YOUR_SERVICE_ROLE_KEY
Authorization: Bearer YOUR_SERVICE_ROLE_KEY
Content-Type: application/json
Prefer: return=minimal
```

**Body**:
```json
{
  "break_start": "{{start_time}}",
  "break_end": "{{end_time}}",
  "operator": "{{user_email}}"
}
```

**Field Mapping**:
- `{{start_time}}` → Your "Start time" field
- `{{end_time}}` → Your "End time" field
- `{{user_email}}` → Logged-in user

---

## Timestamp Format

Glide timestamps should be in ISO 8601 format:
- `2024-02-07T10:30:00Z`
- Or with timezone: `2024-02-07T10:30:00+01:00`

Most Glide date/time fields automatically format correctly.

---

## Troubleshooting

### Error: "Invalid API key"
- Check that you're using **service_role key**, not anon key
- Make sure there are no extra spaces in the key

### Error: "Column does not exist"
- Check field names in JSON body match Supabase column names exactly
- Run `SELECT * FROM raw_pallets LIMIT 0;` in Supabase to see column names

### Error: "Not null violation"
- Required fields: `pallet_ts`, `harvest_culture`
- Make sure these are filled in Glide form

### Data inserted but no analytics calculated
- Check trigger is active: `SELECT * FROM pg_trigger WHERE tgname = 'trigger_calculate_pallet_analytics';`
- Manually recalculate: `SELECT * FROM recalculate_all_analytics();`

---

## Viewing Data in Glide

To show analytics data back in Glide:

### Option 1: Query API (Read data)

**Method**: `GET`

**URL**:
```
https://YOUR_PROJECT_URL/rest/v1/pallet_analytics?select=*&order=pallet_ts.desc&limit=20
```

**Headers**:
```
apikey: YOUR_SERVICE_ROLE_KEY
Authorization: Bearer YOUR_SERVICE_ROLE_KEY
```

This returns last 20 pallets with analytics as JSON.

### Option 2: Use Glide's API column

Create a **"Call API"** column in Glide that fetches from:
```
https://YOUR_PROJECT_URL/rest/v1/pallet_analytics?harvest_culture=eq.{{harvest_culture}}&order=pallet_ts.desc
```

This shows analytics for specific harvest culture.

---

## Next Steps

1. Set up pallet submission API call
2. Test with one pallet
3. Verify in Supabase
4. Set up break tracking API call
5. Create dashboard queries in Glide

---

## Security Note

**IMPORTANT**:
- Never expose service_role key in client-side code
- Glide Actions are server-side, so this is safe
- Consider using Row Level Security (RLS) in Supabase for production
