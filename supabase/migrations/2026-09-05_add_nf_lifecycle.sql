-- Lifecycle oficial para solicitação e registro LOCAL de NF no STAGING.
-- O registro local NÃO representa autorização/transmissão SEFAZ.
-- Preserva status/comissão do pedido fora da transição explícita para nota_fiscal.

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS nf_chave_local text NULL,
  ADD COLUMN IF NOT EXISTS nf_solicitada_em timestamptz NULL,
  ADD COLUMN IF NOT EXISTS nf_solicitada_por text NULL,
  ADD COLUMN IF NOT EXISTS nf_emitida_em timestamptz NULL,
  ADD COLUMN IF NOT EXISTS nf_emitida_por text NULL;

CREATE OR REPLACE FUNCTION public.solicitar_nf_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer
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
  v_actor text;
  v_now timestamptz := now();
  v_nova_versao integer;
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
    RAISE EXCEPTION 'role não autorizada para solicitar NF: %', v_role;
  END IF;
  IF p_request_id IS NULL OR p_pedido_id IS NULL OR p_versao IS NULL THEN
    RAISE EXCEPTION 'request_id, pedido_id e versao são obrigatórios';
  END IF;

  INSERT INTO public.pedido_requests(request_id, empresa_id, tipo_operacao, resultado)
  VALUES (p_request_id, v_empresa_id, 'solicitar_nf_pedido', NULL)
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
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'solicitar_nf_pedido' THEN
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
  IF COALESCE(v_pedido.deleted,false) THEN
    RAISE EXCEPTION 'pedido excluído não pode solicitar NF';
  END IF;
  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE = 'PT412';
  END IF;
  IF v_pedido.status NOT IN ('aprovado','aprovado_ger') THEN
    RAISE EXCEPTION 'NF só pode ser solicitada para pedido aprovado (status atual: %)', v_pedido.status;
  END IF;
  IF COALESCE(v_pedido.nf_numero,'') <> '' OR v_pedido.nf_status = 'gerada' THEN
    RAISE EXCEPTION 'pedido já possui NF registrada';
  END IF;
  IF v_role = 'vend' AND v_pedido.vendedor_id IS DISTINCT FROM v_user_id::text THEN
    RAISE EXCEPTION 'vendedor não autorizado a solicitar NF deste pedido';
  END IF;

  SELECT COALESCE(NULLIF(trim(u.nome),''), NULLIF(trim(u.email),''), v_user_id::text)
  INTO v_actor
  FROM public.usuarios u
  WHERE u.id = v_user_id
    AND u.empresa_id = v_empresa_id;
  v_actor := COALESCE(v_actor, v_user_id::text);
  v_nova_versao := v_pedido.versao + 1;

  UPDATE public.pedidos
  SET solicitar_nf = true,
      nf_status = 'aguardando',
      nf_solicitada_em = v_now,
      nf_solicitada_por = v_actor,
      versao = v_nova_versao
  WHERE id = p_pedido_id
    AND empresa_id = v_empresa_id
    AND versao = p_versao;
  GET DIAGNOSTICS v_update_count = ROW_COUNT;

  IF v_update_count <> 1 THEN
    RAISE EXCEPTION 'falha ao solicitar NF: versão pode ter mudado concorrentemente'
      USING ERRCODE = 'PT412';
  END IF;

  v_resultado := jsonb_build_object(
    'pedido_id', p_pedido_id,
    'status', v_pedido.status,
    'nf_status', 'aguardando',
    'solicitar_nf', true,
    'nf_solicitada_em', v_now,
    'nf_solicitada_por', v_actor,
    'versao', v_nova_versao
  );

  UPDATE public.pedido_requests
  SET resultado = v_resultado
  WHERE request_id = p_request_id
    AND empresa_id = v_empresa_id
    AND tipo_operacao = 'solicitar_nf_pedido';

  RETURN v_resultado;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_nf_local_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer,
  p_nf_numero text,
  p_nf_chave_local text DEFAULT NULL
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
  v_actor text;
  v_now timestamptz := now();
  v_nova_versao integer;
  v_update_count integer;
  v_nf_numero text;
  v_nf_chave text;
  v_resultado jsonb;
BEGIN
  v_user_id := public.get_user_id();
  v_empresa_id := public.get_user_empresa_id();
  v_role := public.get_user_role();

  IF v_user_id IS NULL OR v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuário ou empresa não identificados';
  END IF;
  IF v_role IS NULL OR v_role NOT IN ('adm','ger') THEN
    RAISE EXCEPTION 'role não autorizada para registrar NF local: %', v_role;
  END IF;
  IF p_request_id IS NULL OR p_pedido_id IS NULL OR p_versao IS NULL THEN
    RAISE EXCEPTION 'request_id, pedido_id e versao são obrigatórios';
  END IF;

  v_nf_numero := trim(COALESCE(p_nf_numero,''));
  v_nf_chave := NULLIF(trim(COALESCE(p_nf_chave_local,'')), '');
  IF v_nf_numero = '' OR length(v_nf_numero) > 64 THEN
    RAISE EXCEPTION 'número de NF local inválido';
  END IF;
  IF v_nf_chave IS NOT NULL AND length(v_nf_chave) > 120 THEN
    RAISE EXCEPTION 'chave local de NF inválida';
  END IF;

  INSERT INTO public.pedido_requests(request_id, empresa_id, tipo_operacao, resultado)
  VALUES (p_request_id, v_empresa_id, 'registrar_nf_local_pedido', NULL)
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
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'registrar_nf_local_pedido' THEN
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
  IF COALESCE(v_pedido.deleted,false) THEN
    RAISE EXCEPTION 'pedido excluído não pode registrar NF';
  END IF;
  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE = 'PT412';
  END IF;
  IF v_pedido.status NOT IN ('aprovado','aprovado_ger') THEN
    RAISE EXCEPTION 'NF local só pode ser registrada para pedido aprovado (status atual: %)', v_pedido.status;
  END IF;
  IF COALESCE(v_pedido.nf_numero,'') <> '' OR v_pedido.nf_status = 'gerada' THEN
    RAISE EXCEPTION 'pedido já possui NF registrada';
  END IF;

  PERFORM 1
  FROM public.pedidos p
  WHERE p.empresa_id = v_empresa_id
    AND p.id <> p_pedido_id
    AND p.nf_numero = v_nf_numero
    AND COALESCE(p.deleted,false) = false;
  IF FOUND THEN
    RAISE EXCEPTION 'número de NF local já utilizado nesta empresa';
  END IF;

  SELECT COALESCE(NULLIF(trim(u.nome),''), NULLIF(trim(u.email),''), v_user_id::text)
  INTO v_actor
  FROM public.usuarios u
  WHERE u.id = v_user_id
    AND u.empresa_id = v_empresa_id;
  v_actor := COALESCE(v_actor, v_user_id::text);
  v_nova_versao := v_pedido.versao + 1;

  UPDATE public.pedidos
  SET nf_numero = v_nf_numero,
      nf_chave_local = v_nf_chave,
      nf_status = 'gerada',
      nf_emitida_em = v_now,
      nf_emitida_por = v_actor,
      status = 'nota_fiscal',
      versao = v_nova_versao
  WHERE id = p_pedido_id
    AND empresa_id = v_empresa_id
    AND versao = p_versao;
  GET DIAGNOSTICS v_update_count = ROW_COUNT;

  IF v_update_count <> 1 THEN
    RAISE EXCEPTION 'falha ao registrar NF local: versão pode ter mudado concorrentemente'
      USING ERRCODE = 'PT412';
  END IF;

  v_resultado := jsonb_build_object(
    'pedido_id', p_pedido_id,
    'status', 'nota_fiscal',
    'nf_numero', v_nf_numero,
    'nf_chave_local', v_nf_chave,
    'nf_status', 'gerada',
    'nf_emitida_em', v_now,
    'nf_emitida_por', v_actor,
    'versao', v_nova_versao
  );

  UPDATE public.pedido_requests
  SET resultado = v_resultado
  WHERE request_id = p_request_id
    AND empresa_id = v_empresa_id
    AND tipo_operacao = 'registrar_nf_local_pedido';

  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.solicitar_nf_pedido(uuid,uuid,integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.solicitar_nf_pedido(uuid,uuid,integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.solicitar_nf_pedido(uuid,uuid,integer) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.registrar_nf_local_pedido(uuid,uuid,integer,text,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.registrar_nf_local_pedido(uuid,uuid,integer,text,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.registrar_nf_local_pedido(uuid,uuid,integer,text,text) TO authenticated, service_role;
