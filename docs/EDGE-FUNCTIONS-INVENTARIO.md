# Inventario de Edge Functions - FLUXY ERP V3

Documento gerado a partir de auditoria read-only do painel de producao do Supabase (projeto `kufuggixwyjgxhpsvmpe`) em comparacao com o repositorio Git. Nenhuma funcao foi apagada, alterada ou redeployada durante esta auditoria.

## Tabela de status

| FUNCAO | PRODUCAO | GIT | USADA PELO FRONTEND | STATUS |
|---|---|---|---|---|
| criar-empresa | SIM | SIM | SIM | necessaria |
| criar-usuario | SIM | SIM | SIM | necessaria |
| clever-handler | SIM | SIM | NAO ENCONTRADA no codigo atual | provavelmente orfa |
| quick-processor | SIM | SIM | NAO ENCONTRADA no codigo atual | provavelmente orfa |

## Observacoes

Observacao 1: clever-handler e uma copia de criar-empresa (mesmo cabecalho de comentario "// Edge Function: criar-empresa", mesma logica; unica diferenca e uma linha de comentario decorativa truncada). Total de invocacoes registradas: 0 desde o ultimo deploy.

Observacao 2: quick-processor e byte-a-byte identica a clever-handler, e portanto tambem e uma copia de criar-empresa. Total de invocacoes registradas: 0 desde o ultimo deploy.

Observacao 3: criar-usuario possui uso real confirmado (invocacoes registradas maior que 0) e ja estava versionada no Git antes desta auditoria.

Observacao 4: "Sem chamadas encontradas" refere-se apenas ao codigo atual do frontend (index.html) inspecionado nesta auditoria. Isso nao e uma certeza absoluta de que clever-handler e quick-processor nunca foram utilizadas historicamente.

Observacao 5: Nenhuma das quatro funcoes foi apagada. Nenhuma das quatro funcoes foi alterada. Nenhuma das quatro funcoes foi redeployada.

Observacao 6: Esta auditoria nao alterou producao, staging, banco de dados, RLS, secrets ou frontend.
