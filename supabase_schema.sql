-- SmartSpend Database Schema
-- Run this in your Supabase SQL Editor to set up the database.

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── Categories ──────────────────────────────────────────────────────────────
CREATE TABLE categories (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  icon       TEXT NOT NULL,
  color_hex  TEXT NOT NULL,
  type       TEXT NOT NULL CHECK (type IN ('expense', 'income')),
  is_default BOOLEAN DEFAULT TRUE
);

-- Seed default expense categories
INSERT INTO categories (name, icon, color_hex, type) VALUES
  ('Food & Dining',  '🍔', 'FF6B35', 'expense'),
  ('Transport',      '🚗', '4ECDC4', 'expense'),
  ('Shopping',       '🛍️', 'A855F7', 'expense'),
  ('Entertainment',  '🎬', 'F59E0B', 'expense'),
  ('Health',         '💊', '10B981', 'expense'),
  ('Utilities',      '💡', '3B82F6', 'expense'),
  ('Others',         '📦', '6B7280', 'expense');

-- Seed default income categories
INSERT INTO categories (name, icon, color_hex, type) VALUES
  ('Salary',     '💼', '27AE60', 'income'),
  ('Freelance',  '💻', '2980B9', 'income'),
  ('Investment', '📈', 'F39C12', 'income'),
  ('Others',     '💰', '8E44AD', 'income');

-- ─── Budgets ─────────────────────────────────────────────────────────────────
CREATE TABLE budgets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category_id TEXT NOT NULL,
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  month       INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
  year        INTEGER NOT NULL,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id, category_id, month, year)
);

-- ─── Expenses ────────────────────────────────────────────────────────────────
CREATE TABLE expenses (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category_id TEXT NOT NULL,
  amount      NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  description TEXT DEFAULT '',
  date        DATE NOT NULL,
  location_id UUID,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW(),
  type            TEXT NOT NULL DEFAULT 'expense' CHECK (type IN ('expense', 'income')),
  wallet_id       TEXT NOT NULL DEFAULT 'default_account',
  savings_goal_id TEXT,
  source          TEXT DEFAULT 'manual', -- 'manual' | 'ocr' | 'voice'
  merchant_name   TEXT,
  batch_id        TEXT, -- groups line items saved from the same receipt scan, or the two legs of a wallet transfer; not a UUID since transfer batch ids are timestamp-based strings
  location_name   TEXT, -- snapshot of the place name at record time, kept even if never saved as a location (or the saved location is later deleted)
  receipt_image_url TEXT -- storage URL of the scanned receipt photo, so Receipt History can display it again later
);

-- MIGRATION (run this against an existing database that predates the columns
-- above — e.g. one created before wallets/savings-goals/OCR were added):
--
-- ALTER TABLE expenses
--   ADD COLUMN IF NOT EXISTS type TEXT NOT NULL DEFAULT 'expense' CHECK (type IN ('expense', 'income')),
--   ADD COLUMN IF NOT EXISTS wallet_id TEXT NOT NULL DEFAULT 'default_account',
--   ADD COLUMN IF NOT EXISTS savings_goal_id TEXT,
--   ADD COLUMN IF NOT EXISTS source TEXT DEFAULT 'manual',
--   ADD COLUMN IF NOT EXISTS merchant_name TEXT,
--   ADD COLUMN IF NOT EXISTS batch_id TEXT,
--   ADD COLUMN IF NOT EXISTS location_name TEXT,
--   ADD COLUMN IF NOT EXISTS receipt_image_url TEXT;

-- ─── Locations ───────────────────────────────────────────────────────────────
CREATE TABLE locations (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name          TEXT NOT NULL,
  address       TEXT,
  latitude      DOUBLE PRECISION NOT NULL,
  longitude     DOUBLE PRECISION NOT NULL,
  category_hint TEXT,
  visit_count   INTEGER DEFAULT 0,
  is_routine    BOOLEAN DEFAULT FALSE,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE expenses
  ADD CONSTRAINT fk_expense_location
  FOREIGN KEY (location_id) REFERENCES locations(id) ON DELETE SET NULL;

-- ─── User Location History ───────────────────────────────────────────────────
CREATE TABLE user_location_history (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  location_id        UUID REFERENCES locations(id) ON DELETE SET NULL,
  latitude           DOUBLE PRECISION NOT NULL,
  longitude          DOUBLE PRECISION NOT NULL,
  arrived_at         TIMESTAMPTZ NOT NULL,
  left_at            TIMESTAMPTZ,
  dwell_time_minutes INTEGER,
  triggered_alert    BOOLEAN DEFAULT FALSE
);

-- ─── Alert Logs ──────────────────────────────────────────────────────────────
CREATE TABLE alert_logs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type        TEXT NOT NULL CHECK (type IN ('green','yellow','red','location')),
  title       TEXT NOT NULL,
  message     TEXT NOT NULL,
  category_id TEXT,
  is_read     BOOLEAN DEFAULT FALSE,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ─── AI Insights ─────────────────────────────────────────────────────────────
CREATE TABLE ai_insights (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  content    TEXT NOT NULL,
  type       TEXT NOT NULL CHECK (type IN ('advice','forecast','tip')),
  month      INTEGER,
  year       INTEGER,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Savings Goals ───────────────────────────────────────────────────────────
CREATE TABLE savings_goals (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name           TEXT NOT NULL,
  target_amount  NUMERIC(12,2) NOT NULL CHECK (target_amount > 0),
  current_amount NUMERIC(12,2) DEFAULT 0,
  deadline       DATE,
  is_completed   BOOLEAN DEFAULT FALSE,
  created_at     TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Warranties (FR 4.11 – 4.15) ────────────────────────────────────────────
CREATE TABLE warranties (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  expense_id      UUID REFERENCES expenses(id) ON DELETE SET NULL,
  vendor_name     TEXT,
  duration_months INTEGER,
  expiry_date     DATE,
  status          TEXT CHECK (status IN ('green', 'yellow', 'red', 'unknown')),
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Helper RPC: increment visit count ───────────────────────────────────────
CREATE OR REPLACE FUNCTION increment_visit_count(loc_id UUID)
RETURNS VOID AS $$
  UPDATE locations SET visit_count = visit_count + 1 WHERE id = loc_id;
$$ LANGUAGE sql SECURITY DEFINER;

-- ─── Row Level Security ───────────────────────────────────────────────────────
-- Enable RLS on all user-data tables
ALTER TABLE budgets               ENABLE ROW LEVEL SECURITY;
ALTER TABLE expenses              ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations             ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_location_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE alert_logs            ENABLE ROW LEVEL SECURITY;
ALTER TABLE ai_insights           ENABLE ROW LEVEL SECURITY;
ALTER TABLE savings_goals         ENABLE ROW LEVEL SECURITY;

-- Categories are public read-only
CREATE POLICY "categories_read_all" ON categories FOR SELECT USING (TRUE);

-- Budgets: users own their data
CREATE POLICY "budgets_own" ON budgets FOR ALL USING (auth.uid() = user_id);

-- Expenses: users own their data
CREATE POLICY "expenses_own" ON expenses FOR ALL USING (auth.uid() = user_id);

-- Locations: users own their data
CREATE POLICY "locations_own" ON locations FOR ALL USING (auth.uid() = user_id);

-- Location history: users own their data
CREATE POLICY "location_history_own" ON user_location_history FOR ALL USING (auth.uid() = user_id);

-- Alert logs: users own their data
CREATE POLICY "alert_logs_own" ON alert_logs FOR ALL USING (auth.uid() = user_id);

-- AI insights: users own their data
CREATE POLICY "ai_insights_own" ON ai_insights FOR ALL USING (auth.uid() = user_id);

-- Savings goals: users own their data
CREATE POLICY "savings_goals_own" ON savings_goals FOR ALL USING (auth.uid() = user_id);

-- Warranties: users own their data
ALTER TABLE warranties ENABLE ROW LEVEL SECURITY;
CREATE POLICY "warranties_own" ON warranties FOR ALL USING (auth.uid() = user_id);
