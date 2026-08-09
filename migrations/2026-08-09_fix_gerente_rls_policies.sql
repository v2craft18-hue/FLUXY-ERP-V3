-- Migration: fix_gerente_rls_policies
-- Date: 2026-08-09
-- Author: Fluxy ERP remediation (Claude-assisted, approved by owner)
--
-- ROOT CAUSE:
-- get_user_role() returns the raw value stored in usuarios.role. In this
-- application the manager role is stored/used everywhere in the frontend
-- as 'ger' (see isGer() in index.html, the <option value="ger"> in the
-- user form, and role badges). However 5 RLS policies were written to
-- check role = ANY (ARRAY['adm','gerente']) -- the string 'gerente' never
-- actually occurs in the usuarios.role column. As a result every GERENTE
-- user was silently denied by these policies even though the app UI
-- allowed them to attempt the action.
--
-- Affected policies (BEFORE definitions, captured via pg_policies for
-- rollback / audit purposes):
--
-- 1) public.empresas / admin_atualiza_empresa (UPDATE)
--    USING: ((id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text])))
--
-- 2) public.usuarios / usuarios_atualizam_perfil (UPDATE)
--    USING: ((empresa_id = get_user_empresa_id()) AND ((auth_uid = auth.uid()) OR (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text]))))
--
-- 3) public.usuarios / admin_gerencia_usuarios (INSERT)
--    WITH CHECK: ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text])))
--
-- 4) public.clientes / usuarios_deletam_clientes (DELETE)
--    USING: ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text])))
--
-- 5) public.produtos / admin_gerencia_produtos (ALL)
--    USING: ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text])))
--    WITH CHECK: ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text])))
--
-- FIX (additive, non-destructive):
-- Widen the role array on each policy to also accept 'ger', without
-- touching get_user_role(), without removing the empresa_id tenant check,
-- and without changing behavior for 'adm' users. This does NOT grant any
-- cross-tenant access and does NOT change vendedor/entregador behavior.
--
-- Rollback: re-run the BEFORE definitions shown above using the same
-- ALTER POLICY statements.

ALTER POLICY "admin_atualiza_empresa" ON public.empresas
  USING ((id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])));

ALTER POLICY "usuarios_atualizam_perfil" ON public.usuarios
  USING ((empresa_id = get_user_empresa_id()) AND ((auth_uid = auth.uid()) OR (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text]))));

ALTER POLICY "admin_gerencia_usuarios" ON public.usuarios
  WITH CHECK ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])));

ALTER POLICY "usuarios_deletam_clientes" ON public.clientes
  USING ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])));

ALTER POLICY "admin_gerencia_produtos" ON public.produtos
  USING ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])))
  WITH CHECK ((empresa_id = get_user_empresa_id()) AND (get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])));
