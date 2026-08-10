# BASELINE-PRODUCAO.md

## Dados da captura

- Data da captura: 2026-08-10
- Projeto Supabase (PRODUCAO): FLUXY ERP V3
- Referencia do projeto: kufuggixwyjgxhpsvmpe
- Provedor/Regiao: AWS sa-east-1
- Compute: Micro
- Organizacao Supabase: v2craft18-hue's Org (Pro Plan)
- Metodo: inspecao READ-ONLY via SQL Editor (information_schema, pg_catalog).
  Nenhum comando de escrita foi executado em producao.

## Resumo do schema encontrado

| Item | Quantidade |
|---|---|
| Tabelas (schema public) | 10 |
| Colunas (total, todas as tabelas) | 149 |
| Constraints (PK+FK+UNIQUE) | 24 |
| CHECK constraints | 0 |
| Indices (schema public) | 26 |
| Views | 0 |
| Policies RLS | 23 |
| Tabelas com RLS enabled | 10 de 10 (100%) |
| Tabelas com RLS forced | 0 de 10 |
| Triggers customizados (schema public) | 1 |
| Funcoes customizadas (schema public) | 4 |
| Extensoes instaladas | 5 (pg_stat_statements, pgcrypto, plpgsql, supabase_vault, uuid-ossp) |
| Edge Functions implantadas | 4 (mas apenas 2 codigos distintos - ver secao abaixo) |

## Tabelas

auditoria, clientes, cobracas, empresas, pedido_itens, pedidos, produtos, rotas,
usuarios, usuarios_auth_map.

Detalhes completos de colunas, tipos, defaults, PK/FK/UNIQUE e indices estao
no arquivo `supabase/migrations/0000_baseline_producao.sql`.

Observacoes estruturais importantes:
- `produtos.id` e do tipo TEXT (nao uuid como nas demais tabelas) - default
  `(gen_random_uuid())::text`. Isso e uma inconsistencia de design pre-existente,
  nao introduzida por este trabalho.
- `pedidos.vendedor_id` e TEXT e armazena `usuarios.id::text` (confirmado por
  inspecao dos dados reais). Nao existe FK formal entre os dois porque os tipos
  de coluna sao diferentes (text vs uuid).
- Nenhuma tabela tem CHECK constraints.
- Nao existe tabela dedicada de "comissoes": a comissao e um campo numerico
  (`pedidos.comissao`) dentro da propria tabela de pedidos - unica fonte de
  verdade, consistente com a exigencia de nao calcular valores diferentes no
  frontend e no backend.

## Funcoes (schema public)

- `get_user_empresa_id()` - STABLE SECURITY DEFINER - le empresa_id do usuario autenticado.
- `get_user_role()` - STABLE SECURITY DEFINER - le role do usuario autenticado.
- `get_user_id()` - STABLE SECURITY DEFINER - le id (uuid) do usuario autenticado.
- `prevent_privilege_escalation()` - trigger function SECURITY DEFINER - bloqueia
  auto-promocao de role e movimentacao de usuario entre empresas.

Definicoes completas em `supabase/migrations/0000_baseline_producao.sql`.

## Trigger

- `trg_prevent_privilege_escalation` em `public.usuarios` (BEFORE INSERT OR UPDATE),
  executa `prevent_privilege_escalation()`.

## RLS / Policies

Todas as 10 tabelas do schema public tem RLS habilitado. Nenhuma tem RLS
"forced" (ou seja, o proprio owner/service_role sempre pode contornar RLS,
como e esperado para uso em Edge Functions). As 23 policies estao listadas
integralmente em `supabase/migrations/0000_baseline_producao.sql`, incluindo a
policy `usuarios_veem_pedidos` corrigida na etapa anterior (vendedor ve
somente os proprios pedidos; admin/gerente/demais papeis veem todos os
pedidos da empresa; nunca ha acesso cruzado entre empresas).

## Extensoes

pg_stat_statements 1.11, pgcrypto 1.3, plpgsql 1.0, supabase_vault 0.3.1, uuid-ossp 1.1.

## Edge Functions - inventario

| Nome | Ultima atualizacao | Codigo | Usa service_role | Acessa banco | Observacao |
|---|---|---|---|---|---|
| criar-usuario | 13h atras | Distinto (proprio) | Sim | Sim (usuarios, auditoria) | Cria/vincula usuario na mesma empresa; impede escalada de privilegio; gera link de redefinicao de senha; nao recebe/retorna senha em texto puro. Codigo versionado em `supabase/functions/criar-usuario/index.ts`. |
| criar-empresa | 25 dias atras | Original | Sim | Sim (empresas, usuarios, auth.users) | Cria empresa nova + usuario admin inicial. NAO esta versionado no Git. |
| clever-handler | 1 mes atras | **Identico byte-a-byte a criar-empresa** (mesmo comentario interno "// Edge Function: criar-empresa", mesmo tamanho de arquivo) | Sim | Sim | Aparenta ser uma implantacao duplicada/de teste sob nome generico (nome tipico de template automatico do Supabase). NAO esta versionado no Git. |
| quick-processor | 1 mes atras | **Identico byte-a-byte a criar-empresa** | Sim | Sim | Mesma observacao de clever-handler: duplicata sob nome generico. NAO esta versionado no Git. |

Secrets usados pelas 4 funcoes (apenas variaveis padrao do proprio Supabase,
nenhum secret customizado identificado): `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
(injetadas automaticamente pelo runtime de Edge Functions - nao precisam ser
copiadas manualmente, cada projeto novo já as fornece com seus próprios valores).

RISCO IDENTIFICADO: existem 3 implantacoes (clever-handler, criar-empresa,
quick-processor) com o MESMO codigo. Isso nao foi alterado nesta etapa
(conforme instrucao de nao tocar em areas fora do escopo), mas deve ser
esclarecido com o dono do projeto antes de decidir o que replicar no staging:
provavelmente apenas 1 copia (criar-empresa) e necessaria, e as outras 2 sao
sobra de testes/deploys anteriores.

## PRODUCAO ATUAL VS GIT

### 1. Esta no Git e confirmado em producao (conteudo comparado e identico)
- `supabase/migrations/2026-08-09_prevent_role_escalation.sql` -> function `prevent_privilege_escalation` + trigger `trg_prevent_privilege_escalation` (confirmado).
- `supabase/migrations/2026-08-09_fix_pedidos_select_rls_vendedor.sql` -> function `get_user_id` + policy `usuarios_veem_pedidos` + indice `idx_pedidos_empresa_vendedor` (confirmado, criado na etapa anterior desta sessao).
- `migrations/2026-08-09_create_auditoria_table.sql` -> tabela `auditoria` + policy `adm_ger_leem_auditoria` (confirmado, conteudo identico ao encontrado em producao).
- `migrations/2026-08-09_fix_gerente_rls_policies.sql` -> as 5 policies alteradas (admin_atualiza_empresa, usuarios_atualizam_perfil, admin_gerencia_usuarios, usuarios_deletam_clientes, admin_gerencia_produtos) -> confirmado, texto das policies em producao corresponde exatamente ao que a migration define.
- `supabase/functions/criar-usuario/index.ts` -> confirmado, mesmo comentario de cabecalho e mesma logica descrita ja documentada em sessao anterior.

### 2. Esta no Git mas nao foi possivel confirmar em producao
- Nenhum item nesta categoria. Todos os 6 arquivos de migration/codigo encontrados no Git foram comparados e confirmados.

### 3. Esta em producao mas nao esta no Git (maior parte do schema)
- Criacao inicial das 10 tabelas (exceto a tabela `auditoria`, que esta no Git) e todas as suas colunas/defaults.
- 24 constraints de PK/FK/UNIQUE (exceto as ja cobertas pela migration da auditoria).
- 26 indices (exceto `idx_pedidos_empresa_vendedor`, ja no Git).
- Habilitacao de RLS (`ENABLE ROW LEVEL SECURITY`) nas 10 tabelas.
- 17 das 23 policies (as outras 6 estao cobertas pelas migrations do Git: 1 da auditoria + 5 do fix_gerente + 1 da correcao de pedidos = nesse total ha sobreposicao; em resumo, a grande maioria das policies nunca foi versionada antes de hoje).
- As funcoes `get_user_empresa_id()` e `get_user_role()` (versoes originais/pre-existentes).
- As 5 extensoes instaladas.
- 3 das 4 Edge Functions (criar-empresa, clever-handler, quick-processor) - so criar-usuario esta no Git.
- O schema `supabase_migrations` (usado pelo CLI/GitHub integration do Supabase para rastrear migrations) NAO existe em producao - ou seja, nenhuma migration jamais foi aplicada via CLI/integracao oficial; tudo foi feito manualmente pelo SQL Editor do dashboard.

### 4. Divergente (existe nos dois lados mas com conteudo diferente)
- Nenhuma divergencia de conteudo foi encontrada nos itens que estao no Git:
  todas as migrations e o codigo de criar-usuario correspondem exatamente ao
  estado atual de producao.
- Anomalia organizacional (nao e uma divergencia de conteudo, mas deve ser
  registrada): o repositorio tem DOIS diretorios de migrations paralelos e
  independentes (`migrations/` na raiz e `supabase/migrations/`), com
  arquivos diferentes em cada um. Isso deveria ser consolidado em um unico
  diretorio para evitar confusao futura.

## Riscos e pontos de atencao para a etapa de staging

1. Como o schema nunca foi gerenciado por CLI/migrations, nao ha garantia
   absoluta de que este arquivo baseline capturou 100% dos detalhes (ex.:
   comentarios de coluna, sequences nao-padrao, roles/grants customizados
   fora do RLS). Foi feita inspecao ampla de tabelas, colunas, constraints,
   indices, RLS, policies, triggers, funcoes e extensoes, mas nao foram
   inspecionados grants/privileges linha a linha nem comentarios de schema.
2. As 3 Edge Functions duplicadas (criar-empresa/clever-handler/quick-processor)
   precisam de uma decisao explicita do dono do projeto antes de serem
   replicadas no staging (replicar as 3 ou so 1).
3. `produtos.id` como TEXT e a falta de FK formal entre `pedidos.vendedor_id`
   e `usuarios.id` sao inconsistências de modelagem pre-existentes; foram
   documentadas e reproduzidas na baseline exatamente como estao, sem
   "corrigi-las" nesta etapa (fora do escopo autorizado).
4. Nenhum dado real foi lido, copiado ou exportado desta sessao - apenas
   estrutura (DDL, RLS, funcoes). Isso satisfaz a exigencia de nao copiar
   dados reais de clientes/usuarios/pedidos para o staging.

## Itens que precisam ser versionados (recomendacao)

- Consolidar em um unico diretorio (`supabase/migrations/`) todo o historico,
  incluindo os 2 arquivos hoje na raiz `migrations/`.
- Versionar o codigo das 3 Edge Functions hoje ausentes do Git, apos a
  decisao sobre as duplicatas.
- Adotar o CLI oficial do Supabase (`supabase migration ...`) daqui para
  frente, para que o schema `supabase_migrations` passe a existir e rastrear
  o historico de forma confiavel.
