-- =====================================================================
-- BAGNO: tasti rapidi "5 / 10 / 15 / 30 minuti"
-- Supabase > SQL Editor > New query > incolla > Run
-- Aggiunge una sola colonna. Si può rieseguire senza danni.
-- =====================================================================

alter table public.bathroom_status
  add column if not exists minuti int check (minuti is null or minuti between 1 and 240);
