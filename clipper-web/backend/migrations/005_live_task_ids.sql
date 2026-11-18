-- Enlaza cada trozo clipeado con su directo, para poder juntar todos sus clips
-- en una sola vista mientras el directo sigue en marcha.
ALTER TABLE live_sessions
    ADD COLUMN IF NOT EXISTS task_ids JSONB NOT NULL DEFAULT '[]'::jsonb;
