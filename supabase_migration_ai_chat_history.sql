-- Run this in your Supabase project's SQL Editor.
-- Adds the `ai_chat_sessions` table for the AI Advisor's chat history
-- (New Chat / Recents, with star and delete). Purely additive — does not
-- touch any existing table or data.

CREATE TABLE IF NOT EXISTS ai_chat_sessions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title      TEXT NOT NULL,
  messages   JSONB NOT NULL DEFAULT '[]',
  is_starred BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE ai_chat_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ai_chat_sessions_own" ON ai_chat_sessions FOR ALL USING (auth.uid() = user_id);
