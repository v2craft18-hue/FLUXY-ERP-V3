-- Route data is company-readable, but only administrators/managers may mutate it.
-- Replaces the legacy ALL policy that allowed every company user to write.

DROP POLICY IF EXISTS admin_gerencia_rotas ON public.rotas;
DROP POLICY IF EXISTS rotas_select_empresa ON public.rotas;
DROP POLICY IF EXISTS rotas_insert_admin_ger ON public.rotas;
DROP POLICY IF EXISTS rotas_update_admin_ger ON public.rotas;
DROP POLICY IF EXISTS rotas_delete_admin_ger ON public.rotas;

CREATE POLICY rotas_select_empresa
ON public.rotas
FOR SELECT
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
);

CREATE POLICY rotas_insert_admin_ger
ON public.rotas
FOR INSERT
TO authenticated
WITH CHECK (
  empresa_id = (SELECT public.get_user_empresa_id())
  AND (SELECT public.get_user_role()) IN ('adm','ger')
);

CREATE POLICY rotas_update_admin_ger
ON public.rotas
FOR UPDATE
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
  AND (SELECT public.get_user_role()) IN ('adm','ger')
)
WITH CHECK (
  empresa_id = (SELECT public.get_user_empresa_id())
  AND (SELECT public.get_user_role()) IN ('adm','ger')
);

CREATE POLICY rotas_delete_admin_ger
ON public.rotas
FOR DELETE
TO authenticated
USING (
  empresa_id = (SELECT public.get_user_empresa_id())
  AND (SELECT public.get_user_role()) IN ('adm','ger')
);
