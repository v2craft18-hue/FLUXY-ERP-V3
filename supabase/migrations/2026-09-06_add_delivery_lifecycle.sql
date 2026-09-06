-- Delivery lifecycle is server-authoritative. Order commercial status, NF and
-- commission snapshots are intentionally left untouched.

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS entrega_status text NOT NULL DEFAULT 'pendente',
  ADD COLUMN IF NOT EXISTS entrega_em timestamptz,
  ADD COLUMN IF NOT EXISTS entregador_id uuid,
  ADD COLUMN IF NOT EXISTS entregador_nome text,
  ADD COLUMN IF NOT EXISTS pagamento_entrega text,
  ADD COLUMN IF NOT EXISTS nao_entregue_motivo text,
  ADD COLUMN IF NOT EXISTS nao_entregue_obs text,
  ADD COLUMN IF NOT EXISTS nao_entregue_em timestamptz,
  ADD COLUMN IF NOT EXISTS nao_entregue_por text;

ALTER TABLE public.pedidos
  DROP CONSTRAINT IF EXISTS pedidos_entrega_status_check,
  ADD CONSTRAINT pedidos_entrega_status_check
    CHECK (entrega_status IN ('pendente','em_rota','entregue','nao_entregue')),
  DROP CONSTRAINT IF EXISTS pedidos_pagamento_entrega_check,
  ADD CONSTRAINT pedidos_pagamento_entrega_check
    CHECK (pagamento_entrega IS NULL OR pagamento_entrega IN
      ('pago_na_entrega','pendente_cobranca','nao_entregue'));

CREATE OR REPLACE FUNCTION public.atualizar_entrega_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer,
  p_entrega_status text,
  p_pagamento_entrega text DEFAULT NULL,
  p_motivo text DEFAULT NULL,
  p_observacao text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_empresa_id uuid;
  v_role text;
  v_user_nome text;
  v_pedido record;
  v_existing_request record;
  v_insert_count integer;
  v_update_count integer;
  v_now timestamptz := now();
  v_nova_versao integer;
  v_resultado jsonb;
BEGIN
  v_user_id := public.get_user_id();
  v_empresa_id := public.get_user_empresa_id();
  v_role := public.get_user_role();

  IF v_user_id IS NULL OR v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuário ou empresa não identificados';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('adm','ger','entr') THEN
    RAISE EXCEPTION 'role não autorizada para atualizar entrega: %', v_role;
  END IF;
  IF p_request_id IS NULL OR p_pedido_id IS NULL OR p_versao IS NULL THEN
    RAISE EXCEPTION 'request_id, pedido_id e versão são obrigatórios';
  END IF;
  IF p_entrega_status IS NULL OR p_entrega_status NOT IN
    ('pendente','em_rota','entregue','nao_entregue') THEN
    RAISE EXCEPTION 'status de entrega inválido: %', p_entrega_status;
  END IF;
  IF p_entrega_status = 'entregue'
     AND (p_pagamento_entrega IS NULL
          OR p_pagamento_entrega NOT IN ('pago_na_entrega','pendente_cobranca')) THEN
    RAISE EXCEPTION 'forma de pagamento da entrega é obrigatória';
  END IF;
  IF p_entrega_status = 'nao_entregue'
     AND (p_motivo IS NULL OR btrim(p_motivo) = '') THEN
    RAISE EXCEPTION 'motivo da não entrega é obrigatório';
  END IF;

  INSERT INTO public.pedido_requests(request_id,empresa_id,tipo_operacao,resultado)
  VALUES (p_request_id,v_empresa_id,'atualizar_entrega_pedido',NULL)
  ON CONFLICT(request_id) DO NOTHING;
  GET DIAGNOSTICS v_insert_count = ROW_COUNT;

  IF v_insert_count = 0 THEN
    SELECT * INTO v_existing_request
    FROM public.pedido_requests
    WHERE request_id = p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'request_id inconsistente'; END IF;
    IF v_existing_request.empresa_id IS DISTINCT FROM v_empresa_id
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'atualizar_entrega_pedido' THEN
      RAISE EXCEPTION 'request_id pertence a outra empresa/operação';
    END IF;
    IF v_existing_request.resultado IS NOT NULL THEN
      RETURN v_existing_request.resultado;
    END IF;
    RAISE EXCEPTION 'request_id em processamento, tente novamente';
  END IF;

  SELECT * INTO v_pedido
  FROM public.pedidos
  WHERE id = p_pedido_id AND empresa_id = v_empresa_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido não encontrado nesta empresa'; END IF;
  IF COALESCE(v_pedido.deleted,false) THEN
    RAISE EXCEPTION 'pedido excluído não pode ter a entrega alterada';
  END IF;
  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE='PT412';
  END IF;
  IF v_pedido.status NOT IN ('aprovado','aprovado_ger','nota_fiscal','faturado','entregue') THEN
    RAISE EXCEPTION 'pedido ainda não está liberado para entrega (status atual: %)', v_pedido.status;
  END IF;
  IF v_role = 'entr' AND v_pedido.entregador_id IS NOT NULL
     AND v_pedido.entregador_id IS DISTINCT FROM v_user_id THEN
    RAISE EXCEPTION 'entregador não autorizado para este pedido';
  END IF;

  SELECT COALESCE(NULLIF(btrim(u.nome),''),v_user_id::text)
  INTO v_user_nome
  FROM public.usuarios u
  WHERE u.id=v_user_id AND u.empresa_id=v_empresa_id;
  v_user_nome := COALESCE(v_user_nome,v_user_id::text);
  v_nova_versao := v_pedido.versao + 1;

  UPDATE public.pedidos
  SET entrega_status = p_entrega_status,
      entrega_em = CASE WHEN p_entrega_status='entregue' THEN v_now ELSE NULL END,
      entregador_id = CASE
        WHEN p_entrega_status IN ('em_rota','entregue','nao_entregue')
          THEN COALESCE(v_pedido.entregador_id,v_user_id)
        ELSE v_pedido.entregador_id
      END,
      entregador_nome = CASE
        WHEN p_entrega_status IN ('em_rota','entregue','nao_entregue')
          THEN COALESCE(v_pedido.entregador_nome,v_user_nome)
        ELSE v_pedido.entregador_nome
      END,
      pagamento_entrega = CASE
        WHEN p_entrega_status='entregue' THEN p_pagamento_entrega
        WHEN p_entrega_status='nao_entregue' THEN 'nao_entregue'
        ELSE NULL
      END,
      nao_entregue_motivo = CASE WHEN p_entrega_status='nao_entregue' THEN btrim(p_motivo) ELSE NULL END,
      nao_entregue_obs = CASE WHEN p_entrega_status='nao_entregue' THEN NULLIF(btrim(p_observacao),'') ELSE NULL END,
      nao_entregue_em = CASE WHEN p_entrega_status='nao_entregue' THEN v_now ELSE NULL END,
      nao_entregue_por = CASE WHEN p_entrega_status='nao_entregue' THEN v_user_nome ELSE NULL END,
      versao = v_nova_versao
  WHERE id=p_pedido_id AND empresa_id=v_empresa_id AND versao=p_versao;
  GET DIAGNOSTICS v_update_count = ROW_COUNT;
  IF v_update_count <> 1 THEN
    RAISE EXCEPTION 'falha ao atualizar entrega: versão pode ter mudado concorrentemente'
      USING ERRCODE='PT412';
  END IF;

  INSERT INTO public.auditoria(
    empresa_id,actor_auth_uid,actor_usuario_id,acao,detalhe
  ) VALUES (
    v_empresa_id,auth.uid(),v_user_id,'pedido_entrega_atualizada',
    jsonb_build_object(
      'pedido_id',p_pedido_id,'status_anterior',v_pedido.entrega_status,
      'status_novo',p_entrega_status,'pagamento_entrega',
      CASE WHEN p_entrega_status='nao_entregue' THEN 'nao_entregue' ELSE p_pagamento_entrega END,
      'motivo',p_motivo,'observacao',p_observacao
    )
  );

  v_resultado := jsonb_build_object(
    'pedido_id',p_pedido_id,'entrega_status',p_entrega_status,
    'entrega_em',CASE WHEN p_entrega_status='entregue' THEN v_now ELSE NULL END,
    'entregador_id',CASE WHEN p_entrega_status IN ('em_rota','entregue','nao_entregue')
      THEN COALESCE(v_pedido.entregador_id,v_user_id) ELSE v_pedido.entregador_id END,
    'entregador_nome',CASE WHEN p_entrega_status IN ('em_rota','entregue','nao_entregue')
      THEN COALESCE(v_pedido.entregador_nome,v_user_nome) ELSE v_pedido.entregador_nome END,
    'pagamento_entrega',CASE
      WHEN p_entrega_status='entregue' THEN p_pagamento_entrega
      WHEN p_entrega_status='nao_entregue' THEN 'nao_entregue'
      ELSE NULL END,
    'versao',v_nova_versao
  );
  UPDATE public.pedido_requests SET resultado=v_resultado
  WHERE request_id=p_request_id AND empresa_id=v_empresa_id
    AND tipo_operacao='atualizar_entrega_pedido';
  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.atualizar_entrega_pedido(
  uuid,uuid,integer,text,text,text,text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.atualizar_entrega_pedido(
  uuid,uuid,integer,text,text,text,text
) FROM anon;
GRANT EXECUTE ON FUNCTION public.atualizar_entrega_pedido(
  uuid,uuid,integer,text,text,text,text
) TO authenticated,service_role;
