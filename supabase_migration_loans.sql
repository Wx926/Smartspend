-- Run this in your Supabase project's SQL Editor.
-- Adds the `loans` table for the Loan/Debt tracking feature (mirrors
-- savings_goals but inverted: principal owed instead of a target saved).
-- Purely additive — does not touch any existing table or data.

CREATE TABLE IF NOT EXISTS loans (
  id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name                        TEXT NOT NULL,
  principal_amount            NUMERIC(12,2) NOT NULL CHECK (principal_amount > 0),
  paid_amount                 NUMERIC(12,2) DEFAULT 0,
  is_completed                BOOLEAN DEFAULT FALSE,
  auto_repay_enabled          BOOLEAN DEFAULT FALSE,
  auto_repay_amount           NUMERIC(12,2),
  auto_repay_source_wallet_id TEXT,
  auto_repay_day_of_month     INTEGER,
  last_auto_repay_date        DATE,
  created_at                  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE loans ENABLE ROW LEVEL SECURITY;

CREATE POLICY "loans_own" ON loans FOR ALL USING (auth.uid() = user_id);
