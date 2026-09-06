-- pedidos is read directly by the frontend, but all writes are lifecycle-only.
-- Remove authenticated direct INSERT/UPDATE policies to prevent bypassing
-- status transitions, optimistic versioning, commission rules and audit.

DROP POLICY IF EXISTS sales_criam_pedidos ON public.pedidos;
DROP POLICY IF EXISTS usuarios_atualizam_pedidos ON public.pedidos;
