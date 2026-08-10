-- ============================================================================
-- BASELINE DA PRODUCAO EXISTENTE (FOTOGRAFIA / RECONSTRUCAO, NAO INCREMENTAL)
-- ============================================================================
-- Arquivo: supabase/migrations/0000_baseline_producao.sql
-- Projeto Supabase: FLUXY ERP V3 (ref: kufuggixwyjgxhpsvmpe) - AWS sa-east-1
-- Data da captura: 2026-08-10
-- Metodo: inspecao READ-ONLY dos catalogos do Postgres (information_schema,
--         pg_catalog) executada diretamente em producao. NENHUM comando de
--         escrita foi executado em producao para gerar este arquivo.
--
-- ATENCAO - LEIA ANTES DE USAR:
-- 1) Este arquivo é uma BASELINE (fotografia do estado atual), NAO uma
--    migration incremental. NAO deve ser aplicado sobre o banco de
--    PRODUCAO (ele já tem essa estrutura). Ele existe para permitir
--    reconstruir a mesma estrutura em um projeto NOVO (STAGING) do zero.
-- 2) O banco de producao nunca usou o mecanismo de migrations do Supabase
--    CLI (o schema "supabase_migrations" nao existe em producao). Por isso
--    nao havia nenhum registro versionado da maior parte do schema antes
--    deste arquivo.
-- 3) Nenhum segredo, senha, token, JWT ou service_role key está ou jamais
--    esteve neste arquivo. Apenas estrutura (DDL) e definicoes de
--    funcoes/policies, que sao seguras para versionar.
-- 4) auth.*, storage.* e demais schemas gerenciados pelo proprio Supabase
--    NAO estao incluidos aqui (sao criados automaticamente em qualquer
--    projeto novo do Supabase).
-- ============================================================================

-- ============================================================================
-- EXTENSOES
-- ============================================================================
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_stat_statements with schema extensions;
-- plpgsql (pg_catalog) e supabase_vault (vault) já vêm por padrão em todo
-- projeto Supabase novo; não requerem criação manual.

-- ============================================================================
-- TABELAS (ordem respeita dependencias de FK)
-- ============================================================================

-- ---------- empresas ----------
create table if not exists public.empresas (
  id uuid not null default gen_random_uuid() primary key,
  nome text not null,
  razao_social text,
  cnpj text,
  email text,
  telefone text,
  plano text default 'basico'::text,
  status text default 'ativo'::text,
  ativo boolean default true,
  criado_em timestamptz default now()
);

-- ---------- usuarios ----------
create table if not exists public.usuarios (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  auth_uid uuid,
  legacy_id text default ''::text,
  nome text not null,
  email text,
  role text default 'vend'::text,
  telefone text,
  plano text default 'basico'::text,
  status text default 'ativo'::text,
  ativo boolean default true,
  deleted boolean default false,
  deleted_at timestamptz,
  criado_em timestamptz default now(),
  constraint usuarios_auth_uid_key unique (auth_uid)
);

-- ---------- usuarios_auth_map ----------
create table if not exists public.usuarios_auth_map (
  id uuid not null default gen_random_uuid() primary key,
  auth_uid uuid not null,
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  role text default 'adm'::text,
  criado_em timestamptz default now(),
  constraint usuarios_auth_map_auth_uid_key unique (auth_uid)
);

-- ---------- clientes ----------
create table if not exists public.clientes (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  nome text not null default ''::text,
  fantasia text default ''::text,
  tipo text default 'pf'::text,
  doc text default ''::text,
  ie text default ''::text,
  rg text default ''::text,
  tel text default ''::text,
  tel2 text default ''::text,
  email text default ''::text,
  contato text default ''::text,
  obs text default ''::text,
  rua text default ''::text,
  numero text default ''::text,
  complemento text default ''::text,
  bairro text default ''::text,
  cidade text default ''::text,
  estado text default ''::text,
  cep text default ''::text,
  limite_cred numeric default 0,
  prazo_pag integer default 0,
  tabela_preco text default 'padrao'::text,
  desconto_max numeric default 0,
  vend_id text default ''::text,
  whatsapp text default ''::text,
  ativo boolean default true,
  criado_em timestamptz default now()
);

-- ---------- produtos (ATENCAO: id e TEXT, nao uuid, ao contrario das demais tabelas) ----------
create table if not exists public.produtos (
  id text not null default (gen_random_uuid())::text primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  nome text not null default ''::text,
  descricao text default ''::text,
  codigo text default ''::text,
  cod_barras text default ''::text,
  sku text default ''::text,
  categoria text default ''::text,
  marca text default ''::text,
  unidade text default 'UN'::text,
  ncm text default ''::text,
  cfop text default '5102'::text,
  cst_icms text default '102'::text,
  aliq_icms numeric default 0,
  preco numeric default 0,
  preco_min numeric default 0,
  preco_custo numeric default 0,
  preco_atacado numeric default 0,
  margem numeric default 0,
  estoque numeric default 0,
  estoque_min numeric default 0,
  estoque_max numeric default 0,
  estoque_reservado numeric default 0,
  peso_bruto numeric default 0,
  peso_liq numeric default 0,
  origem text default '0'::text,
  ativo boolean default true,
  criado_em timestamptz default now()
);

-- ---------- pedidos ----------
create table if not exists public.pedidos (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  numero text not null default ''::text,
  cliente_id text default ''::text,
  cliente_nome text default ''::text,
  vendedor_id text default ''::text,
  status text default 'rascunho'::text,
  subtotal numeric default 0,
  desconto numeric default 0,
  total numeric default 0,
  observacoes text default ''::text,
  pagamento text default 'Dinheiro'::text,
  nf_numero text default ''::text,
  nf_status text,
  comissao numeric default 0,
  solicitar_nf boolean default false,
  deleted boolean default false,
  criado_em timestamptz default now(),
  constraint pedidos_empresa_numero_uniq unique (empresa_id, numero)
);
-- NOTA IMPORTANTE: pedidos.vendedor_id e TEXT e armazena usuarios.id::text
-- (confirmado por inspecao dos dados reais em producao). NAO ha FK formal
-- entre pedidos.vendedor_id e usuarios.id porque os tipos nao sao iguais
-- (text vs uuid). Isso já era assim antes desta baseline; documentado aqui
-- para que o staging reproduza o mesmo comportamento.

-- ---------- pedido_itens ----------
create table if not exists public.pedido_itens (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  pedido_id uuid not null references public.pedidos(id) on delete cascade,
  produto_id text default ''::text,
  produto_nome text default ''::text,
  quantidade numeric default 0,
  preco_unitario numeric default 0,
  desconto_item numeric default 0,
  total_item numeric default 0,
  criado_em timestamptz default now()
);

-- ---------- cobracas ----------
create table if not exists public.cobracas (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  pedido_id text default ''::text,
  cli_id text default ''::text,
  cli_nome text default ''::text,
  vend_id text default ''::text,
  valor numeric default 0,
  valor_pago numeric default 0,
  desconto numeric default 0,
  juros numeric default 0,
  multa numeric default 0,
  forma_pag text default 'Dinheiro'::text,
  parcela integer default 1,
  total_parcelas integer default 1,
  status text default 'aberta'::text,
  vencimento date,
  pago_em timestamptz,
  obs text default ''::text,
  deleted boolean default false,
  criado_em timestamptz default now()
);

-- ---------- rotas ----------
create table if not exists public.rotas (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id) on delete cascade,
  nome text default ''::text,
  data date,
  entregador_id text default ''::text,
  status text default 'aberta'::text,
  ativo boolean default true,
  criado_em timestamptz default now()
);

-- ---------- auditoria ----------
create table if not exists public.auditoria (
  id uuid not null default gen_random_uuid() primary key,
  empresa_id uuid not null references public.empresas(id),
  actor_auth_uid uuid,
  actor_usuario_id uuid,
  acao text not null,
  alvo_usuario_id uuid,
  detalhe jsonb,
  created_at timestamptz not null default now()
);

-- ============================================================================
-- INDICES ADICIONAIS (alem dos criados implicitamente por PK/UNIQUE acima)
-- ============================================================================
create index if not exists auditoria_created_at_idx on public.auditoria using btree (created_at desc);
create index if not exists auditoria_empresa_id_idx on public.auditoria using btree (empresa_id);
create index if not exists idx_clientes_empresa on public.clientes using btree (empresa_id);
create index if not exists idx_cobracas_empresa on public.cobracas using btree (empresa_id);
create index if not exists idx_itens_empresa on public.pedido_itens using btree (empresa_id);
create index if not exists idx_itens_pedido on public.pedido_itens using btree (pedido_id);
create index if not exists idx_pedidos_empresa on public.pedidos using btree (empresa_id);
create index if not exists idx_pedidos_empresa_vendedor on public.pedidos using btree (empresa_id, vendedor_id);
create index if not exists idx_produtos_empresa on public.produtos using btree (empresa_id);
create index if not exists idx_rotas_empresa on public.rotas using btree (empresa_id);
create index if not exists idx_usuarios_auth on public.usuarios using btree (auth_uid);
create index if not exists idx_usuarios_empresa on public.usuarios using btree (empresa_id);

-- ============================================================================
-- FUNCOES
-- ============================================================================
CREATE OR REPLACE FUNCTION public.get_user_empresa_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT u.empresa_id FROM public.usuarios u WHERE u.auth_uid = auth.uid() LIMIT 1),
    NULLIF(((auth.jwt() -> 'app_metadata') ->> 'empresa_id'), '')::uuid
  )
$function$;

CREATE OR REPLACE FUNCTION public.get_user_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT u.role FROM public.usuarios u WHERE u.auth_uid = auth.uid() LIMIT 1),
    ((auth.jwt() -> 'app_metadata') ->> 'role')
  )
$function$;

CREATE OR REPLACE FUNCTION public.get_user_id()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT u.id FROM public.usuarios u WHERE u.auth_uid = auth.uid() LIMIT 1
$function$;

CREATE OR REPLACE FUNCTION public.prevent_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.role() = 'service_role' then RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' then IF NEW.role IN ('adm','gerente','ger') AND get_user_role() <> 'adm' then RAISE EXCEPTION 'Apenas administradores podem criar usuarios com este papel.';
    END IF;
  ELSIF TG_OP = 'UPDATE' then IF NEW.role IS DISTINCT FROM OLD.role AND get_user_role() <> 'adm' then RAISE EXCEPTION 'Apenas administradores podem alterar o papel de um usuario.';
    END IF;
    IF NEW.empresa_id IS DISTINCT FROM OLD.empresa_id then RAISE EXCEPTION 'Nao e permitido mover um usuario para outra empresa.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- ============================================================================
-- TRIGGERS
-- ============================================================================
DROP TRIGGER IF EXISTS trg_prevent_privilege_escalation ON public.usuarios;
CREATE TRIGGER trg_prevent_privilege_escalation BEFORE INSERT OR UPDATE ON public.usuarios FOR EACH ROW EXECUTE FUNCTION prevent_privilege_escalation();

-- ============================================================================
-- RLS - HABILITACAO (todas as 10 tabelas tem RLS ENABLED, nenhuma FORCED, em producao)
-- ============================================================================
alter table public.auditoria enable row level security;
alter table public.clientes enable row level security;
alter table public.cobracas enable row level security;
alter table public.empresas enable row level security;
alter table public.pedido_itens enable row level security;
alter table public.pedidos enable row level security;
alter table public.produtos enable row level security;
alter table public.rotas enable row level security;
alter table public.usuarios enable row level security;
alter table public.usuarios_auth_map enable row level security;

-- ============================================================================
-- RLS - POLICIES (23 policies confirmadas em producao via pg_policies)
-- ============================================================================

-- auditoria
create policy "adm_ger_leem_auditoria" on public.auditoria for select
  using (empresa_id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]));

-- clientes
create policy "usuarios_atualizam_clientes" on public.clientes for update
  using (empresa_id = get_user_empresa_id())
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_deletam_clientes" on public.clientes for delete
  using (empresa_id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]));
create policy "usuarios_gerenciam_clientes" on public.clientes for insert
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_veem_clientes" on public.clientes for select
  using (empresa_id = get_user_empresa_id());

-- cobracas
create policy "usuarios_gerenciam_cobracas" on public.cobracas for all
  using (empresa_id = get_user_empresa_id())
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_veem_cobracas" on public.cobracas for select
  using (empresa_id = get_user_empresa_id());

-- empresas
create policy "admin_atualiza_empresa" on public.empresas for update
  using (id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]));
create policy "nunca_deleta_empresa" on public.empresas for delete
  using (false);
create policy "usuarios_veem_propria_empresa" on public.empresas for select
  using (id = get_user_empresa_id());

-- pedido_itens
create policy "usuarios_gerenciam_itens" on public.pedido_itens for all
  using (empresa_id = get_user_empresa_id())
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_veem_itens" on public.pedido_itens for select
  using (empresa_id = get_user_empresa_id());

-- pedidos
create policy "sales_criam_pedidos" on public.pedidos for insert
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_atualizam_pedidos" on public.pedidos for update
  using (empresa_id = get_user_empresa_id())
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_veem_pedidos" on public.pedidos for select
  using (
    empresa_id = get_user_empresa_id()
    and (
      lower(coalesce(get_user_role(),'')) <> ALL (ARRAY['vend'::text,'vendedor'::text])
      or vendedor_id = (get_user_id())::text
    )
  );

-- produtos
create policy "admin_gerencia_produtos" on public.produtos for all
  using (empresa_id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]))
  with check (empresa_id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]));
create policy "usuarios_veem_produtos" on public.produtos for select
  using (empresa_id = get_user_empresa_id());

-- rotas
create policy "admin_gerencia_rotas" on public.rotas for all
  using (empresa_id = get_user_empresa_id())
  with check (empresa_id = get_user_empresa_id());
create policy "usuarios_veem_rotas" on public.rotas for select
  using (empresa_id = get_user_empresa_id());

-- usuarios
create policy "admin_gerencia_usuarios" on public.usuarios for insert
  with check (empresa_id = get_user_empresa_id() and get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text]));
create policy "usuarios_atualizam_perfil" on public.usuarios for update
  using (empresa_id = get_user_empresa_id() and (auth_uid = auth.uid() or get_user_role() = ANY (ARRAY['adm'::text,'gerente'::text,'ger'::text])));
create policy "usuarios_veem_colegas" on public.usuarios for select
  using (empresa_id = get_user_empresa_id());

-- usuarios_auth_map
create policy "usuarios_veem_proprio_mapa" on public.usuarios_auth_map for select
  using (auth_uid = auth.uid());

-- ============================================================================
-- FIM DA BASELINE
-- ============================================================================
