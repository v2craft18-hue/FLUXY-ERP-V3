-- pedido_itens is read directly by the frontend, but writes are lifecycle-only.
-- Remove authenticated direct-write RLS policies so INSERT/UPDATE/DELETE can only
-- occur through trusted SECURITY DEFINER lifecycle RPCs (or service role/admin DB).

DROP POLICY IF EXISTS pedido_itens_insert_empresa ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_update_empresa ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_delete_empresa ON public.pedido_itens;
