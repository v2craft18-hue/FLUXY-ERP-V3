-- M2-B3.1: alinha o helper com a politica atual do criar_pedido.
-- Desconto NULL/negativo => 0; maximo 80% do subtotal; normalizado em centavos.

CREATE OR REPLACE FUNCTION public.m2_preparar_pedido_snapshot(
  p_empresa_id uuid,
  p_itens jsonb,
  p_desconto numeric
)
RETURNS TABLE (
  item_ord integer,
  item_id uuid,
  produto_id text,
  produto_nome text,
  quantidade numeric,
  preco_unitario numeric,
  total_item numeric,
  desconto_item numeric,
  valor_liquido_item numeric,
  comm_snapshot_version smallint,
  comm_type_snapshot text,
  comm_pct_snapshot numeric,
  comm_meta_snapshot numeric,
  preco_base_snapshot numeric
)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path TO 'public'
AS $function$
DECLARE
  v_desconto_input numeric;
BEGIN
  IF p_empresa_id IS NULL THEN
    RAISE EXCEPTION 'empresa invalida' USING ERRCODE = '22023';
  END IF;

  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'lista de itens invalida ou vazia' USING ERRCODE = '22023';
  END IF;

  IF p_desconto IS NOT NULL
     AND p_desconto::text IN ('NaN','Infinity','-Infinity') THEN
    RAISE EXCEPTION 'desconto invalido' USING ERRCODE = '22023';
  END IF;

  v_desconto_input := round(COALESCE(p_desconto, 0), 2);
  IF v_desconto_input < 0 THEN
    v_desconto_input := 0;
  END IF;

  RETURN QUERY
  WITH entrada AS MATERIALIZED (
    SELECT
      e.ord::integer AS item_ord,
      gen_random_uuid() AS item_id,
      e.value
    FROM jsonb_array_elements(p_itens) WITH ORDINALITY AS e(value, ord)
  ),
  preparados AS MATERIALIZED (
    SELECT
      i.item_ord,
      s.item_id,
      s.produto_id,
      s.produto_nome,
      s.quantidade,
      s.preco_unitario,
      s.total_item,
      s.comm_snapshot_version,
      s.comm_type_snapshot,
      s.comm_pct_snapshot,
      s.comm_meta_snapshot,
      s.preco_base_snapshot
    FROM entrada i
    CROSS JOIN LATERAL public.m2_preparar_item_snapshot(
      p_empresa_id,
      i.item_id,
      i.value->>'produto_id',
      (i.value->>'quantidade')::numeric,
      (i.value->>'preco_unitario')::numeric
    ) s
  ),
  totais AS MATERIALIZED (
    SELECT COALESCE(sum(pr.total_item), 0)::numeric AS subtotal
    FROM preparados pr
  ),
  politica AS MATERIALIZED (
    SELECT
      t.subtotal,
      LEAST(
        v_desconto_input,
        floor(t.subtotal * 0.8 * 100) / 100
      )::numeric AS desconto_final
    FROM totais t
  ),
  rateio_input AS MATERIALIZED (
    SELECT jsonb_agg(
      jsonb_build_object(
        'item_id', pr.item_id,
        'total_item', pr.total_item
      )
      ORDER BY pr.item_ord
    ) AS itens
    FROM preparados pr
  ),
  rateio AS MATERIALIZED (
    SELECT r.item_id, r.desconto_item, r.valor_liquido_item
    FROM rateio_input ri
    CROSS JOIN politica pol
    CROSS JOIN LATERAL public.m2_ratear_desconto_itens(ri.itens, pol.desconto_final) r
  )
  SELECT
    pr.item_ord,
    pr.item_id,
    pr.produto_id,
    pr.produto_nome,
    pr.quantidade,
    pr.preco_unitario,
    pr.total_item,
    rr.desconto_item,
    rr.valor_liquido_item,
    pr.comm_snapshot_version,
    pr.comm_type_snapshot,
    pr.comm_pct_snapshot,
    pr.comm_meta_snapshot,
    pr.preco_base_snapshot
  FROM preparados pr
  JOIN rateio rr ON rr.item_id = pr.item_id
  ORDER BY pr.item_ord;
END;
$function$;

REVOKE ALL ON FUNCTION public.m2_preparar_pedido_snapshot(uuid, jsonb, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_preparar_pedido_snapshot(uuid, jsonb, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_preparar_pedido_snapshot(uuid, jsonb, numeric) TO postgres, service_role;
