-- M2-C1: integra o motor oficial de snapshots/comissao ao criar_pedido.
-- Preserva auth, multiempresa, idempotencia, numeracao, modos e contrato de retorno.

CREATE OR REPLACE FUNCTION public.criar_pedido(
  p_request_id uuid,
  p_modo text,
  p_cliente_id uuid,
  p_itens jsonb,
  p_desconto numeric DEFAULT 0,
  p_observacoes text DEFAULT ''::text,
  p_pagamento text DEFAULT 'Dinheiro'::text,
  p_solicitar_nf boolean DEFAULT false,
  p_gerente_destino_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id          uuid;
  v_empresa_id       uuid;
  v_role             text;
  v_insert_count     integer;
  v_existing_request record;
  v_cliente_nome     text;
  v_preparados       jsonb;
  v_comissoes        jsonb := '{}'::jsonb;
  v_subtotal         numeric := 0;
  v_desconto_final   numeric := 0;
  v_total            numeric := 0;
  v_comissao_total   numeric := NULL;
  v_numero           text;
  v_pedido_id        uuid;
  v_status           text;
  v_criado_em        timestamptz;
  v_resultado        jsonb;
BEGIN
  -- AUTH / EMPRESA: nunca confiar em empresa_id do frontend.
  v_user_id    := public.get_user_id();
  v_empresa_id := public.get_user_empresa_id();
  v_role       := public.get_user_role();

  IF v_user_id IS NULL OR v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuário ou empresa não identificados';
  END IF;

  IF v_role IS NULL OR v_role NOT IN ('adm', 'ger', 'vend') THEN
    RAISE EXCEPTION 'role não autorizada para criar pedido: %', v_role;
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'p_request_id não pode ser NULL';
  END IF;

  -- IDEMPOTENCIA: reserva o request_id antes do trabalho de negocio.
  INSERT INTO public.pedido_requests (request_id, empresa_id, tipo_operacao, resultado)
  VALUES (p_request_id, v_empresa_id, 'criar_pedido', NULL)
  ON CONFLICT (request_id) DO NOTHING;

  GET DIAGNOSTICS v_insert_count = ROW_COUNT;

  IF v_insert_count = 0 THEN
    SELECT * INTO v_existing_request
    FROM public.pedido_requests
    WHERE request_id = p_request_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'request_id inconsistente';
    END IF;

    IF v_existing_request.empresa_id IS DISTINCT FROM v_empresa_id
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'criar_pedido' THEN
      RAISE EXCEPTION 'request_id pertence a outra empresa/operação';
    END IF;

    IF v_existing_request.resultado IS NOT NULL THEN
      RETURN v_existing_request.resultado;
    END IF;

    RAISE EXCEPTION 'request_id em processamento, tente novamente';
  END IF;

  -- MODO / STATUS: servidor decide.
  IF p_modo IS NULL OR p_modo NOT IN ('direto', 'gerente') THEN
    RAISE EXCEPTION 'p_modo inválido: %', p_modo;
  END IF;
  v_status := CASE WHEN p_modo = 'direto' THEN 'aprovado' ELSE 'pendente_ger' END;

  -- CLIENTE da mesma empresa.
  IF p_cliente_id IS NULL THEN
    RAISE EXCEPTION 'p_cliente_id não pode ser NULL';
  END IF;

  SELECT c.nome INTO v_cliente_nome
  FROM public.clientes c
  WHERE c.id = p_cliente_id
    AND c.empresa_id = v_empresa_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cliente não encontrado nesta empresa';
  END IF;

  -- gerente_destino_id: validacao multi-tenant, mantendo comportamento atual.
  IF p_gerente_destino_id IS NOT NULL THEN
    PERFORM 1
    FROM public.usuarios u
    WHERE u.id = p_gerente_destino_id
      AND u.empresa_id = v_empresa_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'gerente_destino_id inválido para esta empresa';
    END IF;
  END IF;

  IF p_itens IS NULL OR jsonb_typeof(p_itens) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_itens deve ser um array JSON';
  END IF;
  IF jsonb_array_length(p_itens) < 1 THEN
    RAISE EXCEPTION 'p_itens deve conter ao menos um item';
  END IF;

  IF p_desconto IS NOT NULL
     AND p_desconto::text IN ('NaN','Infinity','-Infinity') THEN
    RAISE EXCEPTION 'p_desconto inválido: valor não finito';
  END IF;

  -- M2: prepara todos os itens, gera IDs no servidor, captura snapshots oficiais,
  -- aplica a politica de desconto e calcula os valores liquidos por item.
  SELECT
    jsonb_agg(to_jsonb(pr) ORDER BY pr.item_ord),
    COALESCE(sum(pr.total_item), 0),
    COALESCE(sum(pr.desconto_item), 0),
    COALESCE(sum(pr.valor_liquido_item), 0)
  INTO v_preparados, v_subtotal, v_desconto_final, v_total
  FROM public.m2_preparar_pedido_snapshot(
    v_empresa_id,
    p_itens,
    p_desconto
  ) pr;

  IF v_preparados IS NULL OR jsonb_array_length(v_preparados) < 1 THEN
    RAISE EXCEPTION 'falha ao preparar itens do pedido';
  END IF;

  -- Pedido direto nasce aprovado: todos os itens precisam de regra valida.
  -- Pedido para gerente pode continuar pendente com regra ainda nao configurada.
  IF p_modo = 'direto' THEN
    SELECT
      COALESCE(jsonb_object_agg(c.item_id::text, c.comissao_item), '{}'::jsonb),
      COALESCE(sum(c.comissao_item), 0)
    INTO v_comissoes, v_comissao_total
    FROM public.m2_calcular_comissoes_pedido_snapshot(v_preparados) c;
  ELSE
    v_comissoes := '{}'::jsonb;
    v_comissao_total := NULL;
  END IF;

  -- Numeracao continua dentro da mesma transacao.
  v_numero := public.reservar_proximo_numero(v_empresa_id);
  v_pedido_id := gen_random_uuid();
  v_criado_em := now();

  INSERT INTO public.pedidos (
    id, empresa_id, numero, cliente_id, cliente_nome, vendedor_id,
    status, subtotal, desconto, total, comissao, observacoes, pagamento,
    solicitar_nf, gerente_destino_id, versao, deleted, criado_em
  ) VALUES (
    v_pedido_id, v_empresa_id, v_numero, p_cliente_id::text, v_cliente_nome,
    v_user_id::text, v_status, v_subtotal, v_desconto_final, v_total,
    v_comissao_total, COALESCE(p_observacoes, ''), COALESCE(p_pagamento, 'Dinheiro'),
    COALESCE(p_solicitar_nf, false), p_gerente_destino_id, 1, false, v_criado_em
  );

  INSERT INTO public.pedido_itens (
    id, empresa_id, pedido_id, produto_id, produto_nome,
    quantidade, preco_unitario, desconto_item, total_item, criado_em,
    comm_snapshot_version, comm_type_snapshot, comm_pct_snapshot,
    comm_meta_snapshot, preco_base_snapshot, valor_liquido_item, comissao_item
  )
  SELECT
    x.item_id,
    v_empresa_id,
    v_pedido_id,
    x.produto_id,
    x.produto_nome,
    x.quantidade,
    x.preco_unitario,
    x.desconto_item,
    x.total_item,
    v_criado_em,
    x.comm_snapshot_version,
    x.comm_type_snapshot,
    x.comm_pct_snapshot,
    x.comm_meta_snapshot,
    x.preco_base_snapshot,
    x.valor_liquido_item,
    CASE
      WHEN p_modo = 'direto' THEN (v_comissoes ->> (x.item_id::text))::numeric
      ELSE NULL
    END
  FROM jsonb_to_recordset(v_preparados) AS x(
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
  ORDER BY x.item_ord;

  v_resultado := jsonb_build_object(
    'pedido_id',          v_pedido_id,
    'numero',             v_numero,
    'status',             v_status,
    'subtotal',           v_subtotal,
    'desconto',           v_desconto_final,
    'total',              v_total,
    'comissao',           v_comissao_total,
    'criado_em',          v_criado_em,
    'versao',             1,
    'gerente_destino_id', p_gerente_destino_id
  );

  UPDATE public.pedido_requests
  SET resultado = v_resultado
  WHERE request_id = p_request_id
    AND empresa_id = v_empresa_id
    AND tipo_operacao = 'criar_pedido';

  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.criar_pedido(uuid, text, uuid, jsonb, numeric, text, text, boolean, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.criar_pedido(uuid, text, uuid, jsonb, numeric, text, text, boolean, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.criar_pedido(uuid, text, uuid, jsonb, numeric, text, text, boolean, uuid) TO authenticated, service_role;
