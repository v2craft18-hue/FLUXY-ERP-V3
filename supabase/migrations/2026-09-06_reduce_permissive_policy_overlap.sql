-- Reduce redundant permissive SELECT-policy overlap without changing access rules.

-- These ALL policies already provide the exact same SELECT predicate.
DROP POLICY IF EXISTS usuarios_veem_cobracas ON public.cobracas;
DROP POLICY IF EXISTS usuarios_veem_itens ON public.pedido_itens;
DROP POLICY IF EXISTS usuarios_veem_rotas ON public.rotas;

-- For produtos, keep broad company-scoped SELECT for signed-in users, while
-- splitting the admin/manager ALL policy into write-only operations.
DROP POLICY IF EXISTS admin_gerencia_produtos ON public.produtos;

CREATE POLICY admin_insere_produtos
ON public.produtos
FOR INSERT
TO PUBLIC
WITH CHECK (
  empresa_id = public.get_user_empresa_id()
  AND public.get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])
);

CREATE POLICY admin_atualiza_produtos
ON public.produtos
FOR UPDATE
TO PUBLIC
USING (
  empresa_id = public.get_user_empresa_id()
  AND public.get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])
)
WITH CHECK (
  empresa_id = public.get_user_empresa_id()
  AND public.get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])
);

CREATE POLICY admin_deleta_produtos
ON public.produtos
FOR DELETE
TO PUBLIC
USING (
  empresa_id = public.get_user_empresa_id()
  AND public.get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])
);
