-- M2-A: schema de snapshots oficiais de comissao por item de pedido.
-- Apenas estrutura. Sem backfill, sem alteracao de RPC e sem valores financeiros default.

ALTER TABLE public.pedido_itens
  ADD COLUMN comm_snapshot_version smallint NULL,
  ADD COLUMN comm_type_snapshot text NULL,
  ADD COLUMN comm_pct_snapshot numeric(7,4) NULL,
  ADD COLUMN comm_meta_snapshot numeric(12,2) NULL,
  ADD COLUMN preco_base_snapshot numeric(12,2) NULL,
  ADD COLUMN valor_liquido_item numeric(12,2) NULL,
  ADD COLUMN comissao_item numeric(12,2) NULL;

ALTER TABLE public.pedido_itens
  ADD CONSTRAINT chk_comm_snapshot_version
    CHECK (comm_snapshot_version IS NULL OR comm_snapshot_version = 1),

  ADD CONSTRAINT chk_comm_type_snapshot
    CHECK (comm_type_snapshot IS NULL OR comm_type_snapshot IN ('pct','caixa')),

  -- Itens legados (version NULL) permanecem integralmente sem dados M2.
  ADD CONSTRAINT chk_comm_snapshot_legacy_shape
    CHECK (
      comm_snapshot_version IS NOT NULL
      OR (
        comm_type_snapshot IS NULL
        AND comm_pct_snapshot IS NULL
        AND comm_meta_snapshot IS NULL
        AND preco_base_snapshot IS NULL
        AND valor_liquido_item IS NULL
        AND comissao_item IS NULL
      )
    ),

  -- Para version=1, a forma da regra capturada deve ser coerente.
  -- type NULL significa que o produto estava sem comissao oficial configurada.
  ADD CONSTRAINT chk_comm_snapshot_rule_shape
    CHECK (
      comm_snapshot_version IS DISTINCT FROM 1
      OR (
        comm_type_snapshot IS NULL
        AND comm_pct_snapshot IS NULL
        AND comm_meta_snapshot IS NULL
        AND preco_base_snapshot IS NULL
        AND comissao_item IS NULL
      )
      OR (
        comm_type_snapshot = 'pct'
        AND comm_pct_snapshot IS NOT NULL
        AND comm_pct_snapshot >= 0
        AND comm_meta_snapshot IS NULL
        AND preco_base_snapshot IS NULL
      )
      OR (
        comm_type_snapshot = 'caixa'
        AND comm_pct_snapshot IS NULL
        AND comm_meta_snapshot IS NOT NULL
        AND comm_meta_snapshot >= 0
        AND preco_base_snapshot IS NOT NULL
        AND preco_base_snapshot >= 0
      )
    ),

  -- Todo item processado pelo motor M2 deve ter valor liquido calculado.
  ADD CONSTRAINT chk_comm_snapshot_v1_liquido_required
    CHECK (
      comm_snapshot_version IS DISTINCT FROM 1
      OR valor_liquido_item IS NOT NULL
    ),

  ADD CONSTRAINT chk_valor_liquido_item_nonneg
    CHECK (valor_liquido_item IS NULL OR valor_liquido_item >= 0),

  ADD CONSTRAINT chk_comissao_item_nonneg
    CHECK (comissao_item IS NULL OR comissao_item >= 0);
