-- M2-B2: prepara item de pedido com snapshot oficial de comissao.
-- Funcao interna, sem escrita em pedidos/pedido_itens/produtos.

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
    RAISE EXCEPTION 'empresa invalida'
      USING ERRCODE = '22023';
  END IF;

  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'item_id invalido'
      USING ERRCODE = '22023';
  END IF;

  IF p_produto_id IS NULL OR btrim(p_produto_id) = '' THEN
    RAISE EXCEPTION 'produto invalido'
      USING ERRCODE = '22023';
  END IF;

  IF p_quantidade IS NULL OR p_quantidade::text IN ('NaN','Infinity','-Infinity') OR p_quantidade <= 0 THEN
    RAISE EXCEPTION 'quantidade invalida'
      USING ERRCODE = '22023';
  END IF;

  IF p_preco_unitario IS NULL OR p_preco_unitario::text IN ('NaN','Infinity','-Infinity') OR p_preco_unitario < 0 THEN
    RAISE EXCEPTION 'preco_unitario invalido'
      USING ERRCODE = '22023';
  END IF;

  SELECT p.*
  INTO v_prod
  FROM public.produtos p
  WHERE p.id = p_produto_id
    AND p.empresa_id = p_empresa_id
    AND p.ativo IS TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'produto nao encontrado ou inativo'
      USING ERRCODE = 'P0002';
  END IF;

  -- Defesa adicional: nunca materializar snapshot oficial inconsistente.
  IF v_prod.comm_type IS NULL THEN
    IF v_prod.comm_pct IS NOT NULL
       OR v_prod.comm_meta IS NOT NULL
       OR v_prod.preco_base_comissao IS NOT NULL THEN
      RAISE EXCEPTION 'configuracao oficial de comissao inconsistente'
        USING ERRCODE = '22023';
    END IF;
  ELSIF v_prod.comm_type = 'pct' THEN
    IF v_prod.comm_pct IS NULL OR v_prod.comm_pct < 0
       OR v_prod.comm_meta IS NOT NULL
       OR v_prod.preco_base_comissao IS NOT NULL THEN
      RAISE EXCEPTION 'configuracao oficial percentual inconsistente'
        USING ERRCODE = '22023';
    END IF;
  ELSIF v_prod.comm_type = 'caixa' THEN
    IF v_prod.comm_pct IS NOT NULL
       OR v_prod.comm_meta IS NULL OR v_prod.comm_meta < 0
       OR v_prod.preco_base_comissao IS NULL OR v_prod.preco_base_comissao < 0 THEN
      RAISE EXCEPTION 'configuracao oficial caixa inconsistente'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    RAISE EXCEPTION 'tipo oficial de comissao invalido'
      USING ERRCODE = '22023';
  END IF;

  v_total := round(p_quantidade * p_preco_unitario, 2);

  RETURN QUERY SELECT
    p_item_id,
    v_prod.id,
    v_prod.nome,
    p_quantidade,
    p_preco_unitario,
    v_total,
    1::smallint,
    v_prod.comm_type,
    v_prod.comm_pct,
    v_prod.comm_meta,
    v_prod.preco_base_comissao;
END;
$function$;

-- Funcao interna do motor. Nao expor ao frontend autenticado.
REVOKE ALL ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.m2_preparar_item_snapshot(uuid, uuid, text, numeric, numeric) TO postgres, service_role;
