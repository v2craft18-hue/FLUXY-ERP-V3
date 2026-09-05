-- M2-B4 fix: qualifica campos do CTE para evitar conflito com parametros de saida PL/pgSQL.

CREATE OR REPLACE FUNCTION public.m2_calcular_comissoes_pedido_snapshot(
  p_itens jsonb
)
RETURNS TABLE (
  item_id uuid,
  comissao_item numeric
)
LANGUAGE plpgsql
IMMUTABLE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_qtd integer;
  v_qtd_ids integer;
  v_invalidos integer;
  v_sem_regra integer;
BEGIN
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'lista de itens invalida ou vazia' USING ERRCODE = '22023';
  END IF;

  WITH parsed AS (
    SELECT *
    FROM jsonb_to_recordset(p_itens) AS x(
      item_id uuid,
      comm_snapshot_version smallint,
      comm_type_snapshot text,
      comm_pct_snapshot numeric,
      comm_meta_snapshot numeric,
      preco_base_snapshot numeric,
      valor_liquido_item numeric,
      quantidade numeric
    )
  )
  SELECT
    count(*)::integer,
    count(DISTINCT pr.item_id)::integer,
    count(*) FILTER (
      WHERE pr.item_id IS NULL
         OR pr.comm_snapshot_version IS DISTINCT FROM 1
         OR pr.valor_liquido_item IS NULL
         OR pr.valor_liquido_item::text IN ('NaN','Infinity','-Infinity')
         OR pr.valor_liquido_item < 0
         OR pr.quantidade IS NULL
         OR pr.quantidade::text IN ('NaN','Infinity','-Infinity')
         OR pr.quantidade <= 0
    )::integer,
    count(*) FILTER (WHERE pr.comm_type_snapshot IS NULL)::integer
  INTO v_qtd, v_qtd_ids, v_invalidos, v_sem_regra
  FROM parsed pr;

  IF v_invalidos > 0 THEN
    RAISE EXCEPTION 'item sem snapshot M2 valido' USING ERRCODE = '22023';
  END IF;

  IF v_qtd_ids <> v_qtd THEN
    RAISE EXCEPTION 'item_id duplicado na comissao' USING ERRCODE = '22023';
  END IF;

  IF v_sem_regra > 0 THEN
    RAISE EXCEPTION 'comissao oficial nao configurada para todos os itens'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    x.item_id,
    public.m2_calcular_comissao_item(
      x.comm_type_snapshot,
      x.comm_pct_snapshot,
      x.comm_meta_snapshot,
      x.preco_base_snapshot,
      x.valor_liquido_item,
      x.quantidade
    ) AS comissao_item
  FROM jsonb_to_recordset(p_itens) AS x(
    item_id uuid,
    comm_snapshot_version smallint,
    comm_type_snapshot text,
    comm_pct_snapshot numeric,
    comm_meta_snapshot numeric,
    preco_base_snapshot numeric,
    valor_liquido_item numeric,
    quantidade numeric
  )
  ORDER BY x.item_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.m2_calcular_comissoes_pedido_snapshot(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_calcular_comissoes_pedido_snapshot(jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_calcular_comissoes_pedido_snapshot(jsonb) TO postgres, service_role;
