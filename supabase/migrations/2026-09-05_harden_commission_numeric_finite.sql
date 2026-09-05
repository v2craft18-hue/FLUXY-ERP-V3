-- Hardening de integridade: rejeita NaN/Infinity/-Infinity em valores de comissao.
-- STAGING: protege produtos oficiais, snapshots M2 e helpers internos.

BEGIN;

-- ============================================================================
-- PRODUTOS: constraints oficiais devem aceitar apenas numericos finitos >= 0.
-- ============================================================================
ALTER TABLE public.produtos
  DROP CONSTRAINT IF EXISTS produtos_comm_pct_check,
  DROP CONSTRAINT IF EXISTS produtos_comm_meta_check,
  DROP CONSTRAINT IF EXISTS produtos_preco_base_comissao_check;

ALTER TABLE public.produtos
  ADD CONSTRAINT produtos_comm_pct_check
    CHECK (
      comm_pct IS NULL
      OR (
        comm_pct::text NOT IN ('NaN','Infinity','-Infinity')
        AND comm_pct >= 0
      )
    ),
  ADD CONSTRAINT produtos_comm_meta_check
    CHECK (
      comm_meta IS NULL
      OR (
        comm_meta::text NOT IN ('NaN','Infinity','-Infinity')
        AND comm_meta >= 0
      )
    ),
  ADD CONSTRAINT produtos_preco_base_comissao_check
    CHECK (
      preco_base_comissao IS NULL
      OR (
        preco_base_comissao::text NOT IN ('NaN','Infinity','-Infinity')
        AND preco_base_comissao >= 0
      )
    );

-- ============================================================================
-- PEDIDO_ITENS M2: endurece forma da regra e valores calculados.
-- ============================================================================
ALTER TABLE public.pedido_itens
  DROP CONSTRAINT IF EXISTS chk_comm_snapshot_rule_shape,
  DROP CONSTRAINT IF EXISTS chk_valor_liquido_item_nonneg,
  DROP CONSTRAINT IF EXISTS chk_comissao_item_nonneg;

ALTER TABLE public.pedido_itens
  ADD CONSTRAINT chk_comm_snapshot_rule_shape
    CHECK (
      comm_snapshot_version IS DISTINCT FROM 1
      OR CASE
        WHEN comm_type_snapshot IS NULL THEN
          comm_pct_snapshot IS NULL
          AND comm_meta_snapshot IS NULL
          AND preco_base_snapshot IS NULL
          AND comissao_item IS NULL
        WHEN comm_type_snapshot = 'pct' THEN
          comm_pct_snapshot IS NOT NULL
          AND comm_pct_snapshot::text NOT IN ('NaN','Infinity','-Infinity')
          AND comm_pct_snapshot >= 0
          AND comm_meta_snapshot IS NULL
          AND preco_base_snapshot IS NULL
        WHEN comm_type_snapshot = 'caixa' THEN
          comm_pct_snapshot IS NULL
          AND comm_meta_snapshot IS NOT NULL
          AND comm_meta_snapshot::text NOT IN ('NaN','Infinity','-Infinity')
          AND comm_meta_snapshot >= 0
          AND preco_base_snapshot IS NOT NULL
          AND preco_base_snapshot::text NOT IN ('NaN','Infinity','-Infinity')
          AND preco_base_snapshot >= 0
        ELSE FALSE
      END
    ),
  ADD CONSTRAINT chk_valor_liquido_item_nonneg
    CHECK (
      valor_liquido_item IS NULL
      OR (
        valor_liquido_item::text NOT IN ('NaN','Infinity','-Infinity')
        AND valor_liquido_item >= 0
      )
    ),
  ADD CONSTRAINT chk_comissao_item_nonneg
    CHECK (
      comissao_item IS NULL
      OR (
        comissao_item::text NOT IN ('NaN','Infinity','-Infinity')
        AND comissao_item >= 0
      )
    );

-- ============================================================================
-- RPC OFICIAL DE PRODUTO: mesma semantica, agora rejeitando especiais numericos.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.configurar_comissao_produto(
  p_produto_id text,
  p_comm_type text,
  p_comm_pct numeric,
  p_comm_meta numeric,
  p_preco_base_comissao numeric
)
RETURNS TABLE (
  produto_id text,
  comm_type text,
  comm_pct numeric,
  comm_meta numeric,
  preco_base_comissao numeric,
  comm_config_atualizado_em timestamptz,
  comm_config_atualizado_por text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_empresa uuid;
  v_produto_empresa uuid;
  v_por text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'USUÁRIO NÃO AUTENTICADO';
  END IF;

  v_role := get_user_role();
  IF v_role IS DISTINCT FROM 'adm' THEN
    RAISE EXCEPTION 'ACESSO NEGADO: SOMENTE ADM PODE CONFIGURAR COMISSÃO';
  END IF;

  v_empresa := get_user_empresa_id();

  SELECT p.empresa_id
    INTO v_produto_empresa
    FROM public.produtos p
    WHERE p.id = p_produto_id
      AND p.empresa_id = v_empresa;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUTO NÃO ENCONTRADO OU NÃO PERTENCE À EMPRESA ATUAL';
  END IF;

  IF p_comm_type IS NULL
     AND p_comm_pct IS NULL
     AND p_comm_meta IS NULL
     AND p_preco_base_comissao IS NULL THEN
    NULL;
  ELSIF p_comm_type = 'pct'
        AND p_comm_pct IS NOT NULL
        AND p_comm_pct::text NOT IN ('NaN','Infinity','-Infinity')
        AND p_comm_pct >= 0
        AND p_comm_meta IS NULL
        AND p_preco_base_comissao IS NULL THEN
    NULL;
  ELSIF p_comm_type = 'caixa'
        AND p_comm_pct IS NULL
        AND p_comm_meta IS NOT NULL
        AND p_comm_meta::text NOT IN ('NaN','Infinity','-Infinity')
        AND p_comm_meta >= 0
        AND p_preco_base_comissao IS NOT NULL
        AND p_preco_base_comissao::text NOT IN ('NaN','Infinity','-Infinity')
        AND p_preco_base_comissao >= 0 THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'COMBINAÇÃO INVÁLIDA DE COMM_TYPE/COMM_PCT/COMM_META/PRECO_BASE_COMISSAO';
  END IF;

  SELECT COALESCE(u.nome, u.email)
    INTO v_por
    FROM public.usuarios u
    WHERE u.auth_uid = auth.uid();

  IF v_por IS NULL THEN
    v_por := auth.uid()::text;
  END IF;

  UPDATE public.produtos p
    SET comm_type = p_comm_type,
        comm_pct = p_comm_pct,
        comm_meta = p_comm_meta,
        preco_base_comissao = p_preco_base_comissao,
        comm_config_atualizado_em = now(),
        comm_config_atualizado_por = v_por
    WHERE p.id = p_produto_id
      AND p.empresa_id = v_empresa;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FALHA AO ATUALIZAR CONFIGURAÇÃO DE COMISSÃO';
  END IF;

  RETURN QUERY
    SELECT p.id,
           p.comm_type,
           p.comm_pct,
           p.comm_meta,
           p.preco_base_comissao,
           p.comm_config_atualizado_em,
           p.comm_config_atualizado_por
      FROM public.produtos p
      WHERE p.id = p_produto_id
        AND p.empresa_id = v_empresa;
END;
$$;

REVOKE ALL ON FUNCTION public.configurar_comissao_produto(text, text, numeric, numeric, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.configurar_comissao_produto(text, text, numeric, numeric, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.configurar_comissao_produto(text, text, numeric, numeric, numeric) TO authenticated, service_role;

-- ============================================================================
-- HELPER DE CALCULO: rejeita especiais em qualquer operando numerico.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.m2_calcular_comissao_item(
  p_comm_type text,
  p_comm_pct numeric,
  p_comm_meta numeric,
  p_preco_base numeric,
  p_valor_liquido numeric,
  p_quantidade numeric
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_preco_liquido_unitario numeric;
BEGIN
  IF p_valor_liquido IS NULL
     OR p_valor_liquido::text IN ('NaN','Infinity','-Infinity')
     OR p_valor_liquido < 0 THEN
    RAISE EXCEPTION 'valor_liquido invalido' USING ERRCODE = '22023';
  END IF;

  IF p_quantidade IS NULL
     OR p_quantidade::text IN ('NaN','Infinity','-Infinity')
     OR p_quantidade <= 0 THEN
    RAISE EXCEPTION 'quantidade invalida' USING ERRCODE = '22023';
  END IF;

  IF p_comm_type IS NULL THEN
    IF p_comm_pct IS NOT NULL OR p_comm_meta IS NOT NULL OR p_preco_base IS NOT NULL THEN
      RAISE EXCEPTION 'snapshot sem tipo possui parametros de comissao' USING ERRCODE = '22023';
    END IF;
    RETURN NULL;
  END IF;

  IF p_comm_type = 'pct' THEN
    IF p_comm_pct IS NULL
       OR p_comm_pct::text IN ('NaN','Infinity','-Infinity')
       OR p_comm_pct < 0
       OR p_comm_meta IS NOT NULL
       OR p_preco_base IS NOT NULL THEN
      RAISE EXCEPTION 'snapshot percentual invalido' USING ERRCODE = '22023';
    END IF;
    RETURN round(p_valor_liquido * p_comm_pct / 100, 2);
  END IF;

  IF p_comm_type = 'caixa' THEN
    IF p_comm_pct IS NOT NULL
       OR p_comm_meta IS NULL
       OR p_comm_meta::text IN ('NaN','Infinity','-Infinity')
       OR p_comm_meta < 0
       OR p_preco_base IS NULL
       OR p_preco_base::text IN ('NaN','Infinity','-Infinity')
       OR p_preco_base < 0 THEN
      RAISE EXCEPTION 'snapshot caixa invalido' USING ERRCODE = '22023';
    END IF;

    v_preco_liquido_unitario := p_valor_liquido / p_quantidade;
    RETURN round((p_comm_meta + greatest(0::numeric, v_preco_liquido_unitario - p_preco_base)) * p_quantidade, 2);
  END IF;

  RAISE EXCEPTION 'tipo de comissao invalido: %', p_comm_type USING ERRCODE = '22023';
END;
$function$;

-- ============================================================================
-- HELPER DE RATEIO: rejeita desconto/total especiais.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.m2_ratear_desconto_itens(
  p_itens jsonb,
  p_desconto numeric
)
RETURNS TABLE (
  item_id uuid,
  desconto_item numeric,
  valor_liquido_item numeric
)
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_qtd integer;
  v_qtd_distintos integer;
  v_qtd_invalidos integer;
  v_subtotal numeric;
  v_desconto numeric;
  v_desconto_cents bigint;
BEGIN
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'lista de itens invalida ou vazia' USING ERRCODE = '22023';
  END IF;

  IF p_desconto IS NULL
     OR p_desconto::text IN ('NaN','Infinity','-Infinity')
     OR p_desconto < 0 THEN
    RAISE EXCEPTION 'desconto invalido' USING ERRCODE = '22023';
  END IF;

  v_desconto := round(p_desconto, 2);
  v_desconto_cents := round(v_desconto * 100)::bigint;

  WITH parsed AS (
    SELECT
      CASE WHEN jsonb_typeof(e.value) = 'object' AND e.value ? 'item_id'
        THEN (e.value->>'item_id')::uuid ELSE NULL END AS id,
      CASE WHEN jsonb_typeof(e.value) = 'object' AND e.value ? 'total_item'
        THEN round((e.value->>'total_item')::numeric, 2) ELSE NULL END AS total
    FROM jsonb_array_elements(p_itens) AS e(value)
  )
  SELECT
    count(*)::integer,
    count(DISTINCT id)::integer,
    count(*) FILTER (
      WHERE id IS NULL
         OR total IS NULL
         OR total::text IN ('NaN','Infinity','-Infinity')
         OR total < 0
    )::integer,
    coalesce(sum(total), 0)
  INTO v_qtd, v_qtd_distintos, v_qtd_invalidos, v_subtotal
  FROM parsed;

  IF v_qtd_invalidos > 0 THEN
    RAISE EXCEPTION 'item de rateio invalido' USING ERRCODE = '22023';
  END IF;

  IF v_qtd_distintos <> v_qtd THEN
    RAISE EXCEPTION 'item_id duplicado no rateio' USING ERRCODE = '22023';
  END IF;

  IF v_subtotal = 0 THEN
    IF v_desconto_cents <> 0 THEN
      RAISE EXCEPTION 'desconto maior que zero com subtotal zero' USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT (e.value->>'item_id')::uuid, 0::numeric, 0::numeric
    FROM jsonb_array_elements(p_itens) AS e(value)
    ORDER BY (e.value->>'item_id')::uuid;
    RETURN;
  END IF;

  IF v_desconto > v_subtotal THEN
    RAISE EXCEPTION 'desconto maior que subtotal' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH parsed AS (
    SELECT
      (e.value->>'item_id')::uuid AS id,
      round((e.value->>'total_item')::numeric, 2) AS total
    FROM jsonb_array_elements(p_itens) AS e(value)
  ),
  quotas AS (
    SELECT id, total, (v_desconto_cents::numeric * total / v_subtotal) AS quota_cents
    FROM parsed
  ),
  bases AS (
    SELECT id, total, floor(quota_cents)::bigint AS base_cents,
           quota_cents - floor(quota_cents) AS fracao
    FROM quotas
  ),
  meta AS (
    SELECT coalesce(sum(base_cents), 0)::bigint AS soma_base FROM bases
  ),
  ranked AS (
    SELECT b.id, b.total, b.base_cents,
           row_number() OVER (ORDER BY b.fracao DESC, b.id ASC) AS rn,
           (v_desconto_cents - m.soma_base)::bigint AS extras
    FROM bases b CROSS JOIN meta m
  ),
  allocated AS (
    SELECT id, total,
           base_cents + CASE WHEN rn <= extras THEN 1 ELSE 0 END AS desconto_cents
    FROM ranked
  )
  SELECT a.id,
         (a.desconto_cents::numeric / 100),
         round(a.total - (a.desconto_cents::numeric / 100), 2)
  FROM allocated a
  ORDER BY a.id;
END;
$function$;

-- ============================================================================
-- HELPER DE PREPARO: rejeita especiais no input e na configuracao do produto.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.m2_preparar_item_snapshot(
  p_empresa_id uuid,
  p_item_id uuid,
  p_produto_id text,
  p_quantidade numeric,
  p_preco_unitario numeric
)
RETURNS TABLE (
  item_id uuid,
  produto_id text,
  produto_nome text,
  quantidade numeric,
  preco_unitario numeric,
  total_item numeric,
  comm_snapshot_version smallint,
  comm_type_snapshot text,
  comm_pct_snapshot numeric,
  comm_meta_snapshot numeric,
  preco_base_snapshot numeric
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_prod public.produtos%ROWTYPE;
  v_total numeric;
BEGIN
  IF p_empresa_id IS NULL THEN
    RAISE EXCEPTION 'empresa invalida' USING ERRCODE = '22023';
  END IF;
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'item_id invalido' USING ERRCODE = '22023';
  END IF;
  IF p_produto_id IS NULL OR btrim(p_produto_id) = '' THEN
    RAISE EXCEPTION 'produto invalido' USING ERRCODE = '22023';
  END IF;
  IF p_quantidade IS NULL OR p_quantidade::text IN ('NaN','Infinity','-Infinity') OR p_quantidade <= 0 THEN
    RAISE EXCEPTION 'quantidade invalida' USING ERRCODE = '22023';
  END IF;
  IF p_preco_unitario IS NULL OR p_preco_unitario::text IN ('NaN','Infinity','-Infinity') OR p_preco_unitario < 0 THEN
    RAISE EXCEPTION 'preco_unitario invalido' USING ERRCODE = '22023';
  END IF;

  SELECT p.* INTO v_prod
  FROM public.produtos p
  WHERE p.id = p_produto_id
    AND p.empresa_id = p_empresa_id
    AND p.ativo IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'produto nao encontrado ou inativo' USING ERRCODE = 'P0002';
  END IF;

  IF v_prod.comm_type IS NULL THEN
    IF v_prod.comm_pct IS NOT NULL OR v_prod.comm_meta IS NOT NULL OR v_prod.preco_base_comissao IS NOT NULL THEN
      RAISE EXCEPTION 'configuracao oficial de comissao inconsistente' USING ERRCODE = '22023';
    END IF;
  ELSIF v_prod.comm_type = 'pct' THEN
    IF v_prod.comm_pct IS NULL
       OR v_prod.comm_pct::text IN ('NaN','Infinity','-Infinity')
       OR v_prod.comm_pct < 0
       OR v_prod.comm_meta IS NOT NULL
       OR v_prod.preco_base_comissao IS NOT NULL THEN
      RAISE EXCEPTION 'configuracao oficial percentual inconsistente' USING ERRCODE = '22023';
    END IF;
  ELSIF v_prod.comm_type = 'caixa' THEN
    IF v_prod.comm_pct IS NOT NULL
       OR v_prod.comm_meta IS NULL
       OR v_prod.comm_meta::text IN ('NaN','Infinity','-Infinity')
       OR v_prod.comm_meta < 0
       OR v_prod.preco_base_comissao IS NULL
       OR v_prod.preco_base_comissao::text IN ('NaN','Infinity','-Infinity')
       OR v_prod.preco_base_comissao < 0 THEN
      RAISE EXCEPTION 'configuracao oficial caixa inconsistente' USING ERRCODE = '22023';
    END IF;
  ELSE
    RAISE EXCEPTION 'tipo oficial de comissao invalido' USING ERRCODE = '22023';
  END IF;

  v_total := round(p_quantidade * p_preco_unitario, 2);

  RETURN QUERY SELECT
    p_item_id, v_prod.id, v_prod.nome, p_quantidade, p_preco_unitario, v_total,
    1::smallint, v_prod.comm_type, v_prod.comm_pct, v_prod.comm_meta, v_prod.preco_base_comissao;
END;
$function$;

-- ACLs: helpers internos continuam indisponiveis para anon/authenticated.
REVOKE ALL ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) TO postgres, service_role;

REVOKE ALL ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) TO postgres, service_role;

REVOKE ALL ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) TO postgres, service_role;

COMMIT;
