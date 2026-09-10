-- Compatibilidade controlada para pedidos gerenciais criados antes do M2.
-- Pedidos novos continuam obrigados a possuir snapshots oficiais de comissão.

CREATE OR REPLACE FUNCTION public.aprovar_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer,
  p_observacao text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_empresa_id uuid;
  v_role text;
  v_insert_count integer;
  v_existing_request record;
  v_pedido record;
  v_now timestamptz;
  v_user_nome text;
  v_nova_versao integer;
  v_update_count integer;
  v_item_count integer;
  v_legacy_item_count integer;
  v_item_update_count integer;
  v_itens_snapshot jsonb;
  v_comissoes jsonb;
  v_comissao_total numeric;
  v_resultado jsonb;
BEGIN
  v_user_id := public.get_user_id();
  v_empresa_id := public.get_user_empresa_id();
  v_role := public.get_user_role();

  IF v_user_id IS NULL OR v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuário ou empresa não identificados';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('adm', 'ger') THEN
    RAISE EXCEPTION 'papel não autorizado para aprovar pedido: %', v_role;
  END IF;
  IF p_request_id IS NULL OR p_pedido_id IS NULL OR p_versao IS NULL THEN
    RAISE EXCEPTION 'request_id, pedido_id e versão são obrigatórios';
  END IF;

  INSERT INTO public.pedido_requests (request_id, empresa_id, tipo_operacao, resultado)
  VALUES (p_request_id, v_empresa_id, 'aprovar_pedido', NULL)
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
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'aprovar_pedido' THEN
      RAISE EXCEPTION 'request_id pertence a outra empresa/operação';
    END IF;
    IF v_existing_request.resultado IS NOT NULL THEN
      RETURN v_existing_request.resultado;
    END IF;
    RAISE EXCEPTION 'request_id em processamento, tente novamente';
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
    RAISE EXCEPTION 'pedido excluído não pode ser aprovado';
  END IF;
  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE = 'PT412';
  END IF;
  IF v_pedido.status IS DISTINCT FROM 'pendente_ger' THEN
    RAISE EXCEPTION 'pedido não está pendente de aprovação gerencial (status atual: %)', v_pedido.status;
  END IF;

  SELECT
    count(*)::integer,
    count(*) FILTER (
      WHERE i.comm_snapshot_version IS NULL
        AND i.comm_type_snapshot IS NULL
        AND i.comm_pct_snapshot IS NULL
        AND i.comm_meta_snapshot IS NULL
        AND i.preco_base_snapshot IS NULL
        AND i.valor_liquido_item IS NULL
    )::integer,
    jsonb_agg(
      jsonb_build_object(
        'item_id', i.id,
        'comm_snapshot_version', i.comm_snapshot_version,
        'comm_type_snapshot', i.comm_type_snapshot,
        'comm_pct_snapshot', i.comm_pct_snapshot,
        'comm_meta_snapshot', i.comm_meta_snapshot,
        'preco_base_snapshot', i.preco_base_snapshot,
        'valor_liquido_item', i.valor_liquido_item,
        'quantidade', i.quantidade
      ) ORDER BY i.id
    )
  INTO v_item_count, v_legacy_item_count, v_itens_snapshot
  FROM public.pedido_itens i
  WHERE i.pedido_id = p_pedido_id
    AND i.empresa_id = v_empresa_id;

  IF v_item_count < 1 OR v_itens_snapshot IS NULL THEN
    RAISE EXCEPTION 'pedido sem itens não pode ser aprovado';
  END IF;

  IF v_pedido.criado_em < timestamptz '2026-09-05 00:00:00+00'
     AND v_legacy_item_count = v_item_count THEN
    -- Legado puro: preserva a comissão já gravada no pedido (inclusive zero).
    -- Não recaptura regra atual do produto e não fabrica snapshot histórico.
    v_comissao_total := COALESCE(v_pedido.comissao, 0);
  ELSE
    SELECT
      COALESCE(jsonb_object_agg(c.item_id::text, c.comissao_item), '{}'::jsonb),
      COALESCE(sum(c.comissao_item), 0)
    INTO v_comissoes, v_comissao_total
    FROM public.m2_calcular_comissoes_pedido_snapshot(v_itens_snapshot) c;

    UPDATE public.pedido_itens i
    SET comissao_item = (v_comissoes ->> i.id::text)::numeric
    WHERE i.pedido_id = p_pedido_id
      AND i.empresa_id = v_empresa_id;
    GET DIAGNOSTICS v_item_update_count = ROW_COUNT;

    IF v_item_update_count <> v_item_count THEN
      RAISE EXCEPTION 'falha ao gravar comissão de todos os itens';
    END IF;
  END IF;

  v_now := now();
  v_nova_versao := v_pedido.versao + 1;

  SELECT u.nome INTO v_user_nome
  FROM public.usuarios u
  WHERE u.id = v_user_id
    AND u.empresa_id = v_empresa_id;
  v_user_nome := COALESCE(NULLIF(btrim(v_user_nome), ''), v_user_id::text);

  UPDATE public.pedidos p
  SET status = 'aprovado_ger',
      aprovado_em = v_now,
      gerente_aprov_id = v_user_id,
      gerente_aprov_nome = v_user_nome,
      gerente_obs = p_observacao,
      comissao = v_comissao_total,
      versao = v_nova_versao
  WHERE p.id = p_pedido_id
    AND p.empresa_id = v_empresa_id
    AND p.status = 'pendente_ger'
    AND p.versao = p_versao;
  GET DIAGNOSTICS v_update_count = ROW_COUNT;

  IF v_update_count <> 1 THEN
    RAISE EXCEPTION 'falha ao aprovar pedido: status ou versão podem ter mudado concorrentemente'
      USING ERRCODE = 'PT412';
  END IF;

  v_resultado := jsonb_build_object(
    'pedido_id', p_pedido_id,
    'status', 'aprovado_ger',
    'aprovado_em', v_now,
    'gerente_aprov_id', v_user_id,
    'gerente_aprov_nome', v_user_nome,
    'gerente_obs', p_observacao,
    'comissao', v_comissao_total,
    'versao', v_nova_versao
  );

  UPDATE public.pedido_requests
  SET resultado = v_resultado
  WHERE request_id = p_request_id
    AND empresa_id = v_empresa_id
    AND tipo_operacao = 'aprovar_pedido';

  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.aprovar_pedido(uuid, uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aprovar_pedido(uuid, uuid, integer, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.aprovar_pedido(uuid, uuid, integer, text) TO authenticated, service_role;
