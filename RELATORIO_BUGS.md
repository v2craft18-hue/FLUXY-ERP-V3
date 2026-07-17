# 🐛 Relatório — Migração do backend para o Supabase `fxxawkgoawtuostlhnzc`

## Resumo
- **Auditoria completa do fluxo de cadastro:** feita antes de qualquer alteração
- **Edge Functions usadas pelo sistema:** 1 (apenas `criar-empresa`)
- **Status:** ✅ Backend completo gerado — ⚠️ 4 passos manuais no Dashboard (ver `INSTALACAO_SUPABASE.md`)

---

## Auditoria do fluxo de cadastro (dependências do backend)

**Signup** (`submitSignup`) → `_sb.functions.invoke('criar-empresa')` → a função
cria, nesta ordem: empresa em `empresas` → usuário em **Authentication**
(com `app_metadata: {role, empresa_id}`) → perfil em `usuarios` (com `auth_uid`)
→ vínculo em `usuarios_auth_map` (`auth_uid`/`usuario_id`/`empresa_id`/`role`),
com rollback completo em cada etapa. Depois o app faz `signInWithPassword`
(sessão real → RLS libera) e auto-login.

**Login** (`doLogin`) → `signInWithPassword` → lê perfil em `usuarios` por
`auth_uid` → fallback para `app_metadata` do JWT.

**Cadastro de cliente** (`saveCli`) → `_cliUpsertSb` → upsert em `clientes`
(onConflict: id). **Reload** → `hydrateAllFromSb` → SELECT em `empresas`,
`usuarios`, `clientes`, `produtos`, `pedidos` filtrando `empresa_id`.

Nenhuma outra Edge Function, webhook ou trigger é chamada pelo código.
Triggers SQL: **nenhuma é obrigatória** para o funcionamento (a de auditoria
do script antigo era opcional e foi removida por referenciar colunas erradas).

---

## O que foi gerado/alterado

### 1. `supabase/migrations/000_schema_completo.sql` (NOVO)
Todas as 9 tabelas com as colunas **exatas** que o app envia (extraídas dos
conversores `_cliToSb`, `_prodToSb`, `_pedidoToSb`, `_pedidoItemToSb`,
`_cobrToSb`, `_usuarioToSb` e da Edge Function). Detalhes importantes:
- `pedidos` com `UNIQUE(empresa_id, numero)` — sem isso o upsert do app falha (42P10)
- `produtos.id` é TEXT — o app insere produtos novos com id local não-UUID
- `pedidos.cliente_id`, `clientes.vend_id`, `cobracas.pedido_id` etc. são TEXT
  (recebem ids/números legados do app)
- `usuarios` com `auth_uid`, `legacy_id`, `deleted`, `deleted_at` (todos usados pelo app)

### 2. `supabase/migrations/rls-policies.sql` (já corrigido na etapa anterior)
Compatível com o schema novo: `get_user_empresa_id()` por `usuarios.auth_uid`
com fallback pro JWT, policies para todas as tabelas incluindo `pedido_itens`.

### 3. `supabase/functions/criar-empresa/index.ts` (verificada, sem alteração)
Ela usa `Deno.env.get('SUPABASE_URL')` e `SUPABASE_SERVICE_ROLE_KEY`, que o
Supabase injeta automaticamente no projeto onde for publicada — ou seja, ao
fazer deploy no `fxxawkgoawtuostlhnzc` ela já opera nele, sem editar nada.
Cria: Authentication ✓, empresa ✓, `usuarios` com `auth_uid` ✓, `usuarios_auth_map` ✓.

### 4. `index.html`
- URL trocada para `https://fxxawkgoawtuostlhnzc.supabase.co` (0 referências ao projeto antigo)
- `SBKEY` com marcador `COLE_AQUI_A_ANON_KEY...` + guard que loga erro claro
  no console enquanto a chave não for colada (a anon key é do seu Dashboard,
  não há como eu obtê-la)
- Mantido o guard de `empresaId` inválido em `_cliUpsertSb` (etapa anterior)
- Sintaxe JS validada após as edições

### 5. `INSTALACAO_SUPABASE.md` (NOVO)
Passo a passo: schema → RLS → deploy da função → anon key → checklist de teste.

---

## Validação realizada

**Estática (neste ambiente):** script cruzou automaticamente cada coluna
enviada pelo app × schema gerado — clientes (27/27), produtos (27/27),
pedidos (16/16), pedido_itens (8/8), cobracas (19/19), usuarios (13/13),
empresas (8/8), usuarios_auth_map (4/4). UNIQUE do upsert presente, RLS sem
colunas fantasmas, Edge Function agnóstica de projeto. ✅

**Ao vivo:** ⚠️ eu não tenho acesso de rede ao seu Supabase a partir daqui,
então o teste real (criar empresa → login → cadastrar cliente → ver na tabela
→ recarregar) precisa ser feito por você seguindo o checklist do
`INSTALACAO_SUPABASE.md`. As mensagens de console `[Fluxy/...]` confirmam
cada etapa.
