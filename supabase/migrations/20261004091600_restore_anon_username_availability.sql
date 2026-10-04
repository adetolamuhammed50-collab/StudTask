-- Username availability is required before authentication during signup.
-- The function only returns whether a username exists; it does not expose profile rows.
grant execute on function public.is_username_available(text) to anon;
