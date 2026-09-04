-- M1A: Schema oficial de comissao em produtos (STAGING)
-- Additive, reversivel. NULL = regra ainda nao configurada.
-- NAO faz backfill. NAO altera RPCs. NAO altera pedidos/pedido_itens.

ALTER TABLE public.produtos
  ADD COLUMN comm_type text NULL,
  ADD COLUMN comm_pct numeric(7,4) NULL,
  ADD COLUMN comm_meta numeric(12,2) NULL,
  ADD COLUMN preco_base_comissao numeric(12,2) NULL;

ALTER TABLE public.produtos
  ADD CONSTRAINT produtos_comm_type_check
    CHECK (comm_type IS NULL OR comm_type IN ('pct','caixa'));

ALTER TABLE public.produtos
  ADD CONSTRAINT produtos_comm_pct_check
    CHECK (comm_pct IS NULL OR comm_pct >= 0);

ALTER TABLE public.produtos
  ADD CONSTRAINT produtos_comm_meta_check
    CHECK (comm_meta IS NULL OR comm_meta >= 0);

ALTER TABLE public.produtos
  ADD CONSTRAINT produtos_preco_base_comissao_check
    CHECK (preco_base_comissao IS NULL OR preco_base_comissao >= 0);
