-- Whether members may pick their own translation model, or are held to the
-- one the admin chose. Off by default: a company's key should not be spent on
-- a larger model without someone deciding that.
--
-- Cost control does not depend on this. The meter charges each model at its
-- own rate, so a member who picks a bigger one simply reaches their monthly
-- limit sooner.
ALTER TABLE orgs ADD COLUMN allow_model_choice INTEGER NOT NULL DEFAULT 0;
