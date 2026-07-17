# Fluxy ERP

Sistema ERP single-page para gestão comercial de distribuidoras.  
PWA installável — funciona offline — otimizado para Android WebView.

## Stack

- **Frontend:** HTML5 + CSS3 + JavaScript (ES5/6 vanilla — sem frameworks)
- **Storage:** localStorage (client-side, sem backend)
- **PWA:** Service Worker v1.2 + Web App Manifest
- **Deploy:** Vercel (static, zero config)

## Módulos

| Módulo | Roles |
|---|---|
| Dashboard | ADM, GER, VEND, ENTR |
| Pedidos / Nova Venda | ADM, GER, VEND |
| Clientes / Minha Rota | ADM, GER, VEND |
| Produtos | ADM, GER, VEND |
| Rotas & Entregas | ADM, GER, ENTR |
| Cobranças | ADM, GER, VEND, ENTR |
| Financeiro | ADM, GER |
| Gerente / Aprovações | ADM, GER, VEND (read-only) |
| Notas Fiscais | ADM, GER, VEND |
| Comissões | ADM, GER, VEND |
| Relatórios | ADM, GER |
| Usuários | ADM |
| Configurações | ADM, GER |

## Deploy — Vercel (recomendado)

### Opção A — Interface web

1. Fork ou faça upload deste repositório no GitHub
2. Acesse [vercel.com](https://vercel.com) → **New Project**
3. Importe o repositório
4. Clique **Deploy** — zero configuração necessária

### Opção B — CLI

```bash
npm i -g vercel
cd fluxy-erp
vercel --prod
```

### Opção B — GitHub Pages

1. Repositório → **Settings** → **Pages**
2. Source: `Deploy from a branch` → `main` → `/ (root)`
3. URL: `https://seu-usuario.github.io/fluxy-erp`

## Estrutura

```
/
├── index.html          ← App completo (HTML + CSS + JS embutidos, ~580kb)
├── sw.js               ← Service Worker (cache-first, offline support)
├── manifest.json       ← PWA manifest (ícones, shortcuts, display)
├── vercel.json         ← Headers de segurança + roteamento
├── .gitignore
├── assets/
│   ├── icon-192.png    ← PWA icon 192×192
│   ├── icon-512.png    ← PWA icon 512×512
│   └── screenshot-mobile.png
└── README.md
```

## Login padrão (primeiro acesso)

```
Email: admin@fluxy.com
Senha: admin123
```

> ⚠️ **Troque a senha do admin imediatamente após o primeiro login.**  
> Todos os dados ficam no `localStorage` do dispositivo — não há backend.

## Roles de acesso

| Role | Código | Descrição |
|---|---|---|
| Administrador | `ADM` | Acesso total |
| Gerente | `GER` | Aprovações, financeiro, rotas |
| Vendedor | `VEND` | Pedidos, clientes, comissões |
| Entregador | `ENTR` | Rotas, cobranças, entregas |

## Variáveis de ambiente

Nenhuma. O sistema é 100% client-side.

## Offline

O Service Worker faz cache do `index.html` e `sw.js`.  
Após o primeiro carregamento, o app funciona completamente offline.  
Para forçar atualização, incremente `CACHE_VERSION` em `sw.js`.

## Licença

Proprietário — Fluxy ERP © 2026
