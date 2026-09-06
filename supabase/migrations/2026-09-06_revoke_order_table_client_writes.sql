-- Defense in depth: pedidos and pedido_itens are lifecycle-RPC-only for writes.
-- Keep direct SELECT for frontend reads; remove all client-side mutation privileges.

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON TABLE public.pedidos
FROM anon, authenticated;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
ON TABLE public.pedido_itens
FROM anon, authenticated;
