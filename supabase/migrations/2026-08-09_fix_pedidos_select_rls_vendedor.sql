-- Migration: fix_pedidos_select_rls_vendedor
-- Data: 2026-08-09
--
-- CAUSA RAIZ ENCONTRADA:
-- A policy "usuarios_veem_pedidos" (SELECT) em public.pedidos so validava
-- empresa_id = get_user_empresa_id(). Nao havia NENHUMA diferenciacao por
-- papel (role) no banco. A regra "vendedor ve somente os proprios pedidos"
-- existia apenas no frontend (index.html -> renderPed() -> isVend() ->
-- filtro por vendId===SESS.userId). Isso significa que qualquer vendedor
-- autenticado podia ler os pedidos de TODOS os outros vendedores da mesma
-- empresa fazendo uma chamada direta a API REST do Supabase (bypassando o
-- React). Viola a exigencia de que a visibilidade seja garantida no
-- backend/RLS, nao apenas escondendo componentes na tela.
--
-- INVESTIGACAO REALIZADA ANTES DESTA MUDANCA (evidencias):
-- - pedidos.empresa_id uuid | pedidos.vendedor_id text | pedidos.id uuid
-- - usuarios.id uuid | usuarios.auth_uid uuid (unique) | usuarios.role text
-- - Confirmado via JOIN em producao (somente leitura, nenhuma linha alterada):
--   pedidos.vendedor_id = usuarios.id::text  (NAO e auth_uid, NAO e legacy_id)
-- - Roles em uso em producao: 'adm', 'ger', 'vend' (frontend tambem aceita
--   os nomes por extenso 'gerente'/'vendedor'/'entregador' como sinonimo)
-- - Funcoes ja existentes e no mesmo padrao (SECURITY DEFINER STABLE):
--   get_user_empresa_id(), get_user_role()
-- - Nao existia indice em pedidos.vendedor_id.
--
-- NOVA REGRA:
--   ADMIN / GERENTE / ENTREGADOR / qualquer outro papel != vendedor:
--       mantem o acesso amplo dentro da empresa (comportamento atual
--       preservado - nenhum acesso adicional concedido, nenhuma regra
--       operacional de ENTREGADOR removida).
--   VENDEDOR:
--       ve somente pedidos em que ele e o vendedor responsavel.
--   Empresa diferente:
--       sempre negado (condicao empresa_id = get_user_empresa_id() mantida
--       e obrigatoria em todos os casos).
--
-- ROLLBACK (documentado - executar manualmente se for necessario reverter):
--   DROP POLICY IF EXISTS usuarios_veem_pedidos ON public.pedidos;
--   CREATE POLICY usuarios_veem_pedidos ON public.pedidos FOR SELECT
--     USING (empresa_id = get_user_empresa_id());
--   DROP INDEX IF EXISTS idx_pedidos_empresa_vendedor;
--   DROP FUNCTION IF EXISTS public.get_user_id();

-- 1) Funcao de apoio (mesmo padrao de get_user_empresa_id()/get_user_role())
CREATE OR REPLACE FUNCTION public.get_user_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT u.id FROM public.usuarios u WHERE u.auth_uid = auth.uid() LIMIT 1
$function$;

-- 2) Nova policy de SELECT em pedidos
DROP POLICY IF EXISTS usuarios_veem_pedidos ON public.pedidos;

CREATE POLICY usuarios_veem_pedidos
ON public.pedidos
FOR SELECT
USING (
  empresa_id = get_user_empresa_id()
  AND (
    lower(coalesce(get_user_role(),'')) NOT IN ('vend','vendedor')
    OR vendedor_id = (get_user_id())::text
  )
);

-- 3) Indice de performance (empresa_id ja tinha indice; vendedor_id nao tinha)
CREATE INDEX IF NOT EXISTS idx_pedidos_empresa_vendedor
  ON public.pedidos (empresa_id, vendedor_id);
