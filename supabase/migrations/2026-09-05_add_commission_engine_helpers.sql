-- M2-B1: funcoes auxiliares puras do motor oficial de comissao.
-- Nao altera pedidos, pedido_itens ou produtos. Nao substitui RPCs de lifecycle.

-- ============================================================================
-- COMISSAO DE UM ITEM A PARTIR DO SNAPSHOT JA CONGELADO
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
  IF p_valor_liquido IS NULL OR p_valor_liquido < 0 THEN
    RAISE EXCEPTION 'valor_liquido invalido'
      USING ERRCODE = '22023';
  END IF;

  IF p_quantidade IS NULL OR p_quantidade <= 0 THEN
    RAISE EXCEPTION 'quantidade invalida'
      USING ERRCODE = '22023';
  END IF;

  -- Produto capturado sem regra oficial configurada.
  IF p_comm_type IS NULL THEN
    IF p_comm_pct IS NOT NULL OR p_comm_meta IS NOT NULL OR p_preco_base IS NOT NULL THEN
      RAISE EXCEPTION 'snapshot sem tipo possui parametros de comissao'
        USING ERRCODE = '22023';
    END IF;
    RETURN NULL;
  END IF;

  IF p_comm_type = 'pct' THEN
    IF p_comm_pct IS NULL OR p_comm_pct < 0
       OR p_comm_meta IS NOT NULL OR p_preco_base IS NOT NULL THEN
      RAISE EXCEPTION 'snapshot percentual invalido'
        USING ERRCODE = '22023';
    END IF;

    RETURN round(p_valor_liquido * p_comm_pct / 100, 2);
  END IF;

  IF p_comm_type = 'caixa' THEN
    IF p_comm_pct IS NOT NULL
       OR p_comm_meta IS NULL OR p_comm_meta < 0
       OR p_preco_base IS NULL OR p_preco_base < 0 THEN
      RAISE EXCEPTION 'snapshot caixa invalido'
        USING ERRCODE = '22023';
    END IF;

    v_preco_liquido_unitario := p_valor_liquido / p_quantidade;

    RETURN round(
      (
        p_comm_meta
        + greatest(0::numeric, v_preco_liquido_unitario - p_preco_base)
      ) * p_quantidade,
      2
    );
  END IF;

  RAISE EXCEPTION 'tipo de comissao invalido: %', p_comm_type
    USING ERRCODE = '22023';
END;
$function$;

-- ============================================================================
-- RATEIO DETERMINISTICO DO DESCONTO DO CABECALHO ENTRE OS ITENS
--
-- Entrada p_itens:
-- [
--   {"item_id":"uuid", "total_item":100.00},
--   {"item_id":"uuid", "total_item":50.00}
-- ]
--
-- Usa largest remainder em CENTAVOS:
-- 1. calcula a cota exata de cada linha;
-- 2. aplica floor em centavos;
-- 3. distribui os centavos restantes pelas maiores fracoes;
-- 4. desempata por item_id ASC.
--
-- Assim nunca depende da ordem do array e a soma dos descontos fecha exatamente.
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
    RAISE EXCEPTION 'lista de itens invalida ou vazia'
      USING ERRCODE = '22023';
  END IF;

  IF p_desconto IS NULL OR p_desconto < 0 THEN
    RAISE EXCEPTION 'desconto invalido'
      USING ERRCODE = '22023';
  END IF;

  -- Todo valor financeiro do motor M2 e normalizado para centavos.
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
    count(*) FILTER (WHERE id IS NULL OR total IS NULL OR total < 0)::integer,
    coalesce(sum(total), 0)
  INTO v_qtd, v_qtd_distintos, v_qtd_invalidos, v_subtotal
  FROM parsed;

  IF v_qtd_invalidos > 0 THEN
    RAISE EXCEPTION 'item de rateio invalido'
      USING ERRCODE = '22023';
  END IF;

  IF v_qtd_distintos <> v_qtd THEN
    RAISE EXCEPTION 'item_id duplicado no rateio'
      USING ERRCODE = '22023';
  END IF;

  IF v_subtotal = 0 THEN
    IF v_desconto_cents <> 0 THEN
      RAISE EXCEPTION 'desconto maior que zero com subtotal zero'
        USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    SELECT
      (e.value->>'item_id')::uuid,
      0::numeric,
      0::numeric
    FROM jsonb_array_elements(p_itens) AS e(value)
    ORDER BY (e.value->>'item_id')::uuid;
    RETURN;
  END IF;

  IF v_desconto > v_subtotal THEN
    RAISE EXCEPTION 'desconto maior que subtotal'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH parsed AS (
    SELECT
      (e.value->>'item_id')::uuid AS id,
      round((e.value->>'total_item')::numeric, 2) AS total
    FROM jsonb_array_elements(p_itens) AS e(value)
  ),
  quotas AS (
    SELECT
      id,
      total,
      (v_desconto_cents::numeric * total / v_subtotal) AS quota_cents
    FROM parsed
  ),
  bases AS (
    SELECT
      id,
      total,
      floor(quota_cents)::bigint AS base_cents,
      quota_cents - floor(quota_cents) AS fracao
    FROM quotas
  ),
  meta AS (
    SELECT
      coalesce(sum(base_cents), 0)::bigint AS soma_base
    FROM bases
  ),
  ranked AS (
    SELECT
      b.id,
      b.total,
      b.base_cents,
      row_number() OVER (ORDER BY b.fracao DESC, b.id ASC) AS rn,
      (v_desconto_cents - m.soma_base)::bigint AS extras
    FROM bases b
    CROSS JOIN meta m
  ),
  allocated AS (
    SELECT
      id,
      total,
      base_cents + CASE WHEN rn <= extras THEN 1 ELSE 0 END AS desconto_cents
    FROM ranked
  )
  SELECT
    a.id,
    (a.desconto_cents::numeric / 100),
    round(a.total - (a.desconto_cents::numeric / 100), 2)
  FROM allocated a
  ORDER BY a.id;
END;
$function$;

-- Funcoes internas do motor. Nao expor como RPC publica ao frontend.
REVOKE ALL ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_calcular_comissao_item(text, numeric, numeric, numeric, numeric, numeric) TO postgres, service_role;

REVOKE ALL ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_ratear_desconto_itens(jsonb, numeric) TO postgres, service_role;
