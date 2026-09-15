-- $20 a month per person was a placeholder, and generous when a whole company
-- runs on one key: about fifty hours of Local mode each. $5 still covers
-- roughly twelve hours a month, which is more than most people talk on calls
-- in another language.
--
-- Only rows still sitting on the old default are moved; an admin who has
-- chosen a number keeps it. New orgs get the value from the bootstrap
-- endpoint, which sets it explicitly rather than relying on the column
-- default (SQLite cannot alter one in place).
UPDATE orgs SET member_cap_cents = 500, updated_at = unixepoch() * 1000
 WHERE member_cap_cents = 2000;
