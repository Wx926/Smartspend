-- Run this in your Supabase project's SQL Editor.
-- Purely additive: adds missing columns/policies so locations, alerts, and
-- custom categories can actually sync to the cloud like expenses/budgets/
-- savings goals already do. Does not touch or delete any existing data.

-- ── Locations: add the columns the app has been sending all along ─────────
ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS category_ids TEXT[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS routine_override BOOLEAN;

-- ── Alert logs: add the location reference the app has been sending ───────
ALTER TABLE alert_logs
  ADD COLUMN IF NOT EXISTS location_id UUID REFERENCES locations(id) ON DELETE SET NULL;

-- ── Categories: allow per-user custom categories alongside the shared
-- defaults (user_id IS NULL = a default seeded category, visible to everyone;
-- user_id = a specific user = that user's own custom category) ────────────
ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

DROP POLICY IF EXISTS categories_read_all ON categories;
CREATE POLICY "categories_read" ON categories
  FOR SELECT USING (user_id IS NULL OR auth.uid() = user_id);
CREATE POLICY "categories_insert_own" ON categories
  FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "categories_update_own" ON categories
  FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "categories_delete_own" ON categories
  FOR DELETE USING (auth.uid() = user_id);
