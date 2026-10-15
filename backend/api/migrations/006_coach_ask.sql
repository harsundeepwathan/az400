-- "Ask your data" (Pro): questions answered from the user's own digest.
alter table ai_requests drop constraint ai_requests_kind_check;
alter table ai_requests add constraint ai_requests_kind_check check (kind in ('meal_scan', 'coach_summary', 'coach_ask'));
