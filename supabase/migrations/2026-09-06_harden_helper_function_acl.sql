-- Security hardening: remove anonymous/public direct EXECUTE on identity helpers
-- while preserving authenticated access required by existing RLS policies.
-- Trigger function is not part of the public/authenticated RPC surface.

REVOKE ALL ON FUNCTION public.get_user_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_user_id() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_user_id() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_user_role() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_user_role() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_user_empresa_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_user_empresa_id() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_user_empresa_id() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.prevent_privilege_escalation() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.prevent_privilege_escalation() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.prevent_privilege_escalation() TO service_role;
