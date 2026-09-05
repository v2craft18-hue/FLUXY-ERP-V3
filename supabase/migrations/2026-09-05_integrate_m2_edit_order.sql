-- M2-C2: integra snapshots oficiais ao editar_pedido preservando identidade de item.
-- item_id e a identidade principal; fallback por produto_id so quando inequivoco.

CREATE OR REPLACE FUNCTION public.editar_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer,
  p_itens jsonb,
  p_desconto numeric DEFAULT 0,
  p_observacoes text DEFAULT ''::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_empresa_id uuid;
  v_role text;
  v_insert_count integer;
  v_existing_request record;
  v_pedido record;
  v_now timestamptz;
  v_nome_usuario text;
  v_editado_por text;
  v_item jsonb;
  v_produto_id text;
  v_quantidade numeric;
  v_preco_unitario numeric;
  v_item_id uuid;
  v_item_id_text text;
  v_item_existe boolean;
  v_old_item record;
  v_produto record;
  v_prepared record;
  v_candidate_count integer;
  v_candidate_id uuid;
  v_seen_existing uuid[] := ARRAY[]::uuid[];
  v_final_ids uuid[] := ARRAY[]::uuid[];
  v_item_ord integer := 0;
  v_preparados_base jsonb := '[]'::jsonb;
  v_preparados jsonb := '[]'::jsonb;
  v_rateio_input jsonb;
  v_subtotal numeric := 0;
  v_desconto_input numeric := 0;
  v_desconto_max numeric := 0;
  v_desconto_final numeric := 0;
  v_total numeric := 0;
  v_status_novo text;
  v_versao_nova integer;
  v_update_count integer;
  v_resultado jsonb;
BEGIN
  v_user_id := public.get_user_id();
  v_empresa_id := public.get_user_empresa_id();
  v_role := public.get_user_role();

  IF v_user_id IS NULL OR v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuário ou empresa não identificados';
  END IF;

  IF v_role IS NULL OR v_role NOT IN ('adm','ger','vend') THEN
    RAISE EXCEPTION 'role não autorizada para editar pedido: %', v_role;
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'p_request_id não pode ser NULL';
  END IF;

  INSERT INTO public.pedido_requests (request_id, empresa_id, tipo_operacao, resultado)
  VALUES (p_request_id, v_empresa_id, 'editar_pedido', NULL)
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
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'editar_pedido' THEN
      RAISE EXCEPTION 'request_id pertence a outra empresa/operação';
    END IF;

    IF v_existing_request.resultado IS NOT NULL THEN
      RETURN v_existing_request.resultado;
    END IF;

    RAISE EXCEPTION 'request_id em processamento, tente novamente';
  END IF;

  IF p_pedido_id IS NULL THEN
    RAISE EXCEPTION 'p_pedido_id não pode ser NULL';
  END IF;
  IF p_versao IS NULL THEN
    RAISE EXCEPTION 'p_versao não pode ser NULL';
  END IF;

  SELECT * INTO v_pedido
  FROM public.pedidos
  WHERE id = p_pedido_id
    AND empresa_id = v_empresa_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido não encontrado nesta empresa';
  END IF;

  IF COALESCE(v_pedido.deleted, false) THEN
    RAISE EXCEPTION 'pedido excluído não pode ser editado';
  END IF;

  IF v_pedido.status NOT IN ('aprovado','aprovado_ger','pendente_ger') THEN
    RAISE EXCEPTION 'status do pedido não permite edição: %', v_pedido.status;
  END IF;

  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE = 'PT412';
  END IF;

  v_now := now();

  IF v_role = 'vend' THEN
    IF v_pedido.vendedor_id IS DISTINCT FROM v_user_id::text THEN
      RAISE EXCEPTION 'vendedor não autorizado a editar este pedido';
    END IF;
    IF v_pedido.criado_em IS NULL
       OR v_now - v_pedido.criado_em > interval '5 minutes' THEN
      RAISE EXCEPTION 'janela de edição de 5 minutos expirada';
    END IF;
  END IF;

  SELECT u.nome INTO v_nome_usuario
  FROM public.usuarios u
  WHERE u.id = v_user_id
    AND u.empresa_id = v_empresa_id;

  IF v_nome_usuario IS NOT NULL AND length(trim(v_nome_usuario)) > 0 THEN
    v_editado_por := v_nome_usuario;
  ELSE
    v_editado_por := v_user_id::text;
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

  -- Valida e prepara a lista final sem tocar nas linhas existentes.
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_itens)
  LOOP
    v_item_ord := v_item_ord + 1;
    v_produto_id := v_item->>'produto_id';

    IF v_produto_id IS NULL OR length(trim(v_produto_id)) = 0 THEN
      RAISE EXCEPTION 'produto_id inválido em item';
    END IF;

    IF (v_item->>'quantidade') IS NULL THEN
      RAISE EXCEPTION 'quantidade obrigatória em item (produto_id=%)', v_produto_id;
    END IF;
    v_quantidade := (v_item->>'quantidade')::numeric;
    IF v_quantidade::text IN ('NaN','Infinity','-Infinity') OR v_quantidade <= 0 THEN
      RAISE EXCEPTION 'quantidade inválida (produto_id=%)', v_produto_id;
    END IF;

    IF (v_item->>'preco_unitario') IS NULL THEN
      RAISE EXCEPTION 'preco_unitario obrigatório em item (produto_id=%)', v_produto_id;
    END IF;
    v_preco_unitario := (v_item->>'preco_unitario')::numeric;
    IF v_preco_unitario::text IN ('NaN','Infinity','-Infinity') OR v_preco_unitario < 0 THEN
      RAISE EXCEPTION 'preco_unitario inválido (produto_id=%)', v_produto_id;
    END IF;

    v_item_id_text := NULLIF(btrim(COALESCE(v_item->>'item_id','')), '');
    v_item_existe := false;
    v_item_id := NULL;

    IF v_item_id_text IS NOT NULL THEN
      v_item_id := v_item_id_text::uuid;

      IF v_item_id = ANY(v_final_ids) THEN
        RAISE EXCEPTION 'item_id duplicado no payload: %', v_item_id;
      END IF;

      SELECT * INTO v_old_item
      FROM public.pedido_itens oi
      WHERE oi.id = v_item_id
        AND oi.pedido_id = p_pedido_id
        AND oi.empresa_id = v_empresa_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'item_id não pertence ao pedido atual: %', v_item_id;
      END IF;

      IF v_old_item.produto_id IS DISTINCT FROM v_produto_id THEN
        RAISE EXCEPTION 'não é permitido trocar produto mantendo o mesmo item_id';
      END IF;

      v_item_existe := true;
    ELSE
      SELECT count(*)::integer, min(oi.id)
      INTO v_candidate_count, v_candidate_id
      FROM public.pedido_itens oi
      WHERE oi.pedido_id = p_pedido_id
        AND oi.empresa_id = v_empresa_id
        AND oi.produto_id = v_produto_id
        AND NOT (oi.id = ANY(v_seen_existing));

      IF v_candidate_count > 1 THEN
        RAISE EXCEPTION 'item_id obrigatório: múltiplas linhas existentes para produto %', v_produto_id;
      ELSIF v_candidate_count = 1 THEN
        v_item_id := v_candidate_id;
        SELECT * INTO v_old_item
        FROM public.pedido_itens oi
        WHERE oi.id = v_item_id
          AND oi.pedido_id = p_pedido_id
          AND oi.empresa_id = v_empresa_id;
        v_item_existe := true;
      ELSE
        v_item_id := gen_random_uuid();
        v_item_existe := false;
      END IF;
    END IF;

    IF v_item_existe THEN
      v_seen_existing := array_append(v_seen_existing, v_item_id);
    END IF;
    v_final_ids := array_append(v_final_ids, v_item_id);

    -- Snapshot válido existente nunca é sobrescrito.
    IF v_item_existe
       AND v_old_item.comm_snapshot_version = 1
       AND v_old_item.comm_type_snapshot IN ('pct','caixa') THEN
      SELECT p.id, p.nome, p.ativo INTO v_produto
      FROM public.produtos p
      WHERE p.id = v_produto_id
        AND p.empresa_id = v_empresa_id;

      IF NOT FOUND OR v_produto.ativo IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'produto inativo ou indisponível: %', v_produto_id;
      END IF;

      v_preparados_base := v_preparados_base || jsonb_build_array(
        jsonb_build_object(
          'item_ord', v_item_ord,
          'item_id', v_item_id,
          'existed', true,
          'produto_id', v_produto_id,
          'produto_nome', v_produto.nome,
          'quantidade', v_quantidade,
          'preco_unitario', v_preco_unitario,
          'total_item', round(v_quantidade * v_preco_unitario, 2),
          'comm_snapshot_version', 1,
          'comm_type_snapshot', v_old_item.comm_type_snapshot,
          'comm_pct_snapshot', v_old_item.comm_pct_snapshot,
          'comm_meta_snapshot', v_old_item.comm_meta_snapshot,
          'preco_base_snapshot', v_old_item.preco_base_snapshot
        )
      );
    ELSE
      -- Item novo, legado ou capturado sem regra: recaptura a configuração oficial atual.
      SELECT * INTO v_prepared
      FROM public.m2_preparar_item_snapshot(
        v_empresa_id,
        v_item_id,
        v_produto_id,
        v_quantidade,
        v_preco_unitario
      );

      v_preparados_base := v_preparados_base || jsonb_build_array(
        jsonb_build_object(
          'item_ord', v_item_ord,
          'item_id', v_item_id,
          'existed', v_item_existe,
          'produto_id', v_prepared.produto_id,
          'produto_nome', v_prepared.produto_nome,
          'quantidade', v_prepared.quantidade,
          'preco_unitario', v_prepared.preco_unitario,
          'total_item', v_prepared.total_item,
          'comm_snapshot_version', v_prepared.comm_snapshot_version,
          'comm_type_snapshot', v_prepared.comm_type_snapshot,
          'comm_pct_snapshot', v_prepared.comm_pct_snapshot,
          'comm_meta_snapshot', v_prepared.comm_meta_snapshot,
          'preco_base_snapshot', v_prepared.preco_base_snapshot
        )
      );
    END IF;
  END LOOP;

  SELECT COALESCE(sum(x.total_item),0)
  INTO v_subtotal
  FROM jsonb_to_recordset(v_preparados_base) AS x(
    item_ord integer, item_id uuid, existed boolean,
    produto_id text, produto_nome text, quantidade numeric,
    preco_unitario numeric, total_item numeric,
    comm_snapshot_version smallint, comm_type_snapshot text,
    comm_pct_snapshot numeric, comm_meta_snapshot numeric,
    preco_base_snapshot numeric
  );

  v_desconto_input := round(COALESCE(p_desconto,0),2);
  IF v_desconto_input < 0 THEN v_desconto_input := 0; END IF;
  v_desconto_max := floor(v_subtotal * 0.8 * 100) / 100;
  v_desconto_final := LEAST(v_desconto_input, v_desconto_max);

  SELECT jsonb_agg(
    jsonb_build_object('item_id',x.item_id,'total_item',x.total_item)
    ORDER BY x.item_ord
  )
  INTO v_rateio_input
  FROM jsonb_to_recordset(v_preparados_base) AS x(
    item_ord integer, item_id uuid, existed boolean,
    produto_id text, produto_nome text, quantidade numeric,
    preco_unitario numeric, total_item numeric,
    comm_snapshot_version smallint, comm_type_snapshot text,
    comm_pct_snapshot numeric, comm_meta_snapshot numeric,
    preco_base_snapshot numeric
  );

  SELECT jsonb_agg(
    to_jsonb(x) || jsonb_build_object(
      'desconto_item', r.desconto_item,
      'valor_liquido_item', r.valor_liquido_item
    )
    ORDER BY x.item_ord
  )
  INTO v_preparados
  FROM jsonb_to_recordset(v_preparados_base) AS x(
    item_ord integer, item_id uuid, existed boolean,
    produto_id text, produto_nome text, quantidade numeric,
    preco_unitario numeric, total_item numeric,
    comm_snapshot_version smallint, comm_type_snapshot text,
    comm_pct_snapshot numeric, comm_meta_snapshot numeric,
    preco_base_snapshot numeric
  )
  JOIN public.m2_ratear_desconto_itens(v_rateio_input, v_desconto_final) r
    ON r.item_id = x.item_id;

  SELECT COALESCE(sum(x.valor_liquido_item),0)
  INTO v_total
  FROM jsonb_to_recordset(v_preparados) AS x(
    item_ord integer, item_id uuid, existed boolean,
    produto_id text, produto_nome text, quantidade numeric,
    preco_unitario numeric, total_item numeric,
    comm_snapshot_version smallint, comm_type_snapshot text,
    comm_pct_snapshot numeric, comm_meta_snapshot numeric,
    preco_base_snapshot numeric, desconto_item numeric,
    valor_liquido_item numeric
  );

  -- Toda edição de aprovado volta para pendente; pendente continua pendente.
  v_status_novo := 'pendente_ger';
  v_versao_nova := v_pedido.versao + 1;

  -- Aplica UPDATE/INSERT preservando IDs existentes.
  FOR v_item IN SELECT * FROM jsonb_array_elements(v_preparados)
  LOOP
    v_item_id := (v_item->>'item_id')::uuid;

    IF COALESCE((v_item->>'existed')::boolean,false) THEN
      UPDATE public.pedido_itens i
      SET produto_nome = v_item->>'produto_nome',
          quantidade = (v_item->>'quantidade')::numeric,
          preco_unitario = (v_item->>'preco_unitario')::numeric,
          desconto_item = (v_item->>'desconto_item')::numeric,
          total_item = (v_item->>'total_item')::numeric,
          comm_snapshot_version = (v_item->>'comm_snapshot_version')::smallint,
          comm_type_snapshot = NULLIF(v_item->>'comm_type_snapshot',''),
          comm_pct_snapshot = NULLIF(v_item->>'comm_pct_snapshot','')::numeric,
          comm_meta_snapshot = NULLIF(v_item->>'comm_meta_snapshot','')::numeric,
          preco_base_snapshot = NULLIF(v_item->>'preco_base_snapshot','')::numeric,
          valor_liquido_item = (v_item->>'valor_liquido_item')::numeric,
          comissao_item = NULL
      WHERE i.id = v_item_id
        AND i.pedido_id = p_pedido_id
        AND i.empresa_id = v_empresa_id;
    ELSE
      INSERT INTO public.pedido_itens (
        id, empresa_id, pedido_id, produto_id, produto_nome,
        quantidade, preco_unitario, desconto_item, total_item, criado_em,
        comm_snapshot_version, comm_type_snapshot, comm_pct_snapshot,
        comm_meta_snapshot, preco_base_snapshot, valor_liquido_item, comissao_item
      ) VALUES (
        v_item_id, v_empresa_id, p_pedido_id,
        v_item->>'produto_id', v_item->>'produto_nome',
        (v_item->>'quantidade')::numeric,
        (v_item->>'preco_unitario')::numeric,
        (v_item->>'desconto_item')::numeric,
        (v_item->>'total_item')::numeric,
        v_now,
        (v_item->>'comm_snapshot_version')::smallint,
        NULLIF(v_item->>'comm_type_snapshot',''),
        NULLIF(v_item->>'comm_pct_snapshot','')::numeric,
        NULLIF(v_item->>'comm_meta_snapshot','')::numeric,
        NULLIF(v_item->>'preco_base_snapshot','')::numeric,
        (v_item->>'valor_liquido_item')::numeric,
        NULL
      );
    END IF;
  END LOOP;

  -- Remove somente itens realmente omitidos da lista final.
  DELETE FROM public.pedido_itens i
  WHERE i.pedido_id = p_pedido_id
    AND i.empresa_id = v_empresa_id
    AND NOT (i.id = ANY(v_final_ids));

  UPDATE public.pedidos p
  SET subtotal = v_subtotal,
      desconto = v_desconto_final,
      total = v_total,
      comissao = NULL,
      observacoes = COALESCE(p_observacoes,''),
      versao = v_versao_nova,
      editado_em = v_now,
      editado_por = v_editado_por,
      status = v_status_novo,
      aprovado_em = NULL,
      gerente_aprov_id = NULL,
      gerente_aprov_nome = NULL
  WHERE p.id = p_pedido_id
    AND p.empresa_id = v_empresa_id
    AND p.versao = p_versao;

  GET DIAGNOSTICS v_update_count = ROW_COUNT;

  IF v_update_count <> 1 THEN
    RAISE EXCEPTION 'falha ao atualizar pedido: versão pode ter mudado concorrentemente'
      USING ERRCODE = 'PT412';
  END IF;

  v_resultado := jsonb_build_object(
    'pedido_id', p_pedido_id,
    'status', v_status_novo,
    'subtotal', v_subtotal,
    'desconto', v_desconto_final,
    'total', v_total,
    'comissao', NULL,
    'observacoes', COALESCE(p_observacoes,''),
    'versao', v_versao_nova,
    'editado_em', v_now,
    'editado_por', v_editado_por
  );

  UPDATE public.pedido_requests
  SET resultado = v_resultado
  WHERE request_id = p_request_id
    AND empresa_id = v_empresa_id
    AND tipo_operacao = 'editar_pedido';

  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.editar_pedido(uuid, uuid, integer, jsonb, numeric, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.editar_pedido(uuid, uuid, integer, jsonb, numeric, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.editar_pedido(uuid, uuid, integer, jsonb, numeric, text) TO authenticated, service_role;
