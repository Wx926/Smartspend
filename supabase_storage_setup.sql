-- ─── Receipt image storage (Receipt History "view photo" feature) ───────────
-- Run this once in the Supabase SQL Editor (Dashboard → SQL Editor → New query).

-- One column on expenses to reference the uploaded receipt photo/PDF.
ALTER TABLE expenses ADD COLUMN IF NOT EXISTS receipt_image_url TEXT;

-- Public bucket: images are served via a plain public URL (no signed-URL
-- expiry to manage) — path is "{user_id}/{batch_id}.{ext}", not guessable,
-- which is an acceptable trade-off for a personal expense-tracking demo app.
INSERT INTO storage.buckets (id, name, public)
VALUES ('receipts', 'receipts', true)
ON CONFLICT (id) DO NOTHING;

-- Authenticated users can upload/overwrite only inside their own user_id folder.
CREATE POLICY "Users can upload their own receipt images"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'receipts' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Users can overwrite their own receipt images"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'receipts' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "Users can delete their own receipt images"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'receipts' AND (storage.foldername(name))[1] = auth.uid()::text);

-- Public read (bucket is already public, but explicit policy avoids relying
-- solely on the bucket-level flag).
CREATE POLICY "Public can view receipt images"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'receipts');
