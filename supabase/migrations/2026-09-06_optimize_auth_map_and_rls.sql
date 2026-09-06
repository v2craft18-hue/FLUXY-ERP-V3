-- Low-risk performance hardening from Supabase advisor.
-- Adds covering FK indexes and prevents per-row auth.uid() re-evaluation.

CREATE INDEX IF NOT EXISTS usuarios_auth_map_empresa_id_idx
  ON public.usuarios_auth_map (empresa_id);

CREATE INDEX IF NOT EXISTS usuarios_auth_map_usuario_id_idx
  ON public.usuarios_auth_map (usuario_id);

ALTER POLICY usuarios_atualizam_perfil
ON public.usuarios
USING (
  empresa_id = public.get_user_empresa_id()
  AND (
    auth_uid = (SELECT auth.uid())
    OR public.get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])
  )
);

ALTER POLICY usuarios_veem_proprio_mapa
ON public.usuarios_auth_map
USING (auth_uid = (SELECT auth.uid()));
