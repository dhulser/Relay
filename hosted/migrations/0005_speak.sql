-- Speak: seconds of speech generated for each member, per day, alongside the
-- minutes they listened. The meter writes it in its own statement, so a
-- deploy that lands before this migration only loses this count.
ALTER TABLE usage_daily ADD COLUMN speak_seconds INTEGER NOT NULL DEFAULT 0;
