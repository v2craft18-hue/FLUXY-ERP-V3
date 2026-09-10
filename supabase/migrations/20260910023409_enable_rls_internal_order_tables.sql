-- Internal order bookkeeping must never be accessed directly by browser roles.
-- Lifecycle RPCs are SECURITY DEFINER and remain the only application path.
ALTER TABLE public.pedido_numeracao ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pedido_requests ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.pedido_numeracao FROM anon, authenticated;
REVOKE ALL ON TABLE public.pedido_requests FROM anon, authenticated;
