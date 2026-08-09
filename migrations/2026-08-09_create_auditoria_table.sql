-- Migration: create_auditoria_table
-- Date: 2026-08-09
-- Purpose: Add an audit trail table for sensitive user-management actions
-- (user creation, activation/deactivation, role changes, password resets,
-- auth_uid linking) as required by the security remediation spec.
--
-- IMPORTANT: This table is written to ONLY by Edge Functions using the
-- service_role key (server-side). It must NEVER receive passwords, tokens,
-- access_token/refresh_token values, or the service_role key itself.

create table if not exists public.auditoria (
    id uuid primary key default gen_random_uuid(),
    empresa_id uuid not null references public.empresas(id),
    actor_auth_uid uuid,
    actor_usuario_id uuid,
    acao text not null,
    alvo_usuario_id uuid,
    detalhe jsonb,
    created_at timestamptz not null default now()
  );

create index if not exists auditoria_empresa_id_idx on public.auditoria(empresa_id);
create index if not exists auditoria_created_at_idx on public.auditoria(created_at desc);

alter table public.auditoria enable row level security;

-- Only ADMIN and GERENTE of the same company may read the audit log.
-- No INSERT/UPDATE/DELETE policy is defined for the public/anon/authenticated
-- roles, so only the service_role key (used exclusively inside Edge
-- Functions, never in the frontend) can write audit rows.
create policy "adm_ger_leem_auditoria"
  on public.auditoria
  for select
  using (
      empresa_id = get_user_empresa_id()
      and get_user_role() = ANY (ARRAY['adm'::text, 'gerente'::text, 'ger'::text])
    );
