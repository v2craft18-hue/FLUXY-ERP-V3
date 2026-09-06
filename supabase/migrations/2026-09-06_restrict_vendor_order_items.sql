-- Restrict pedido_itens SELECT visibility to match pedidos visibility.
-- ADM/GER keep company-wide visibility; vendor sees only items from own orders.
-- Direct write semantics remain the same as the previous ALL policy.

DROP POLICY IF EXISTS usuarios_gerenciam_itens ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_select_visiveis ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_insert_empresa ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_update_empresa ON public.pedido_itens;
DROP POLICY IF EXISTS pedido_itens_delete_empresa ON public.pedido_itens;

CREATE POLICY pedido_itens_select_visiveis
ON public.pedido_itens
FOR SELECT
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
  AND (
    lower(COALESCE((SELECT public.get_user_role()), '')) NOT IN ('vend','vendedor')
    OR EXISTS (
      SELECT 1
      FROM public.pedidos p
      WHERE p.id = pedido_itens.pedido_id
        AND p.empresa_id = pedido_itens.empresa_id
        AND p.vendedor_id = (SELECT public.get_user_id())::text
    )
  )
);

CREATE POLICY pedido_itens_insert_empresa
ON public.pedido_itens
FOR INSERT
TO authenticated
WITH CHECK (
  empresa_id = (SELECT public.get_user_empresa_id())
);

CREATE POLICY pedido_itens_update_empresa
ON public.pedido_itens
FOR UPDATE
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
)
WITH CHECK (
  empresa_id = (SELECT public.get_user_empresa_id())
);

CREATE POLICY pedido_itens_delete_empresa
ON public.pedido_itens
FOR DELETE
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
);
