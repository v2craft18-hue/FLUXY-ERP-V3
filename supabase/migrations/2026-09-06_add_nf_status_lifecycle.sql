-- Persist post-registration NF status changes that were previously local-only.
-- This records administrative workflow state; it does not transmit to SEFAZ.

ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS nf_autorizada_em timestamptz,
  ADD COLUMN IF NOT EXISTS nf_rejeitada_em timestamptz,
  ADD COLUMN IF NOT EXISTS nf_cancelada_em timestamptz,
  ADD COLUMN IF NOT EXISTS nf_status_atualizado_por text;

CREATE OR REPLACE FUNCTION public.atualizar_nf_status_pedido(
  p_request_id uuid,
  p_pedido_id uuid,
  p_versao integer,
  p_nf_status text,
  p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_empresa_id uuid;
  v_role text;
  v_actor text;
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
  IF v_role IS DISTINCT FROM 'adm' THEN
    RAISE EXCEPTION 'somente administrador pode atualizar o status da NF';
  END IF;
  IF p_request_id IS NULL OR p_pedido_id IS NULL OR p_versao IS NULL THEN
    RAISE EXCEPTION 'request_id, pedido_id e versão são obrigatórios';
  END IF;
  IF p_nf_status IS NULL OR p_nf_status NOT IN ('autorizada','rejeitada','cancelada') THEN
    RAISE EXCEPTION 'status de NF inválido: %',p_nf_status;
  END IF;

  INSERT INTO public.pedido_requests(request_id,empresa_id,tipo_operacao,resultado)
  VALUES(p_request_id,v_empresa_id,'atualizar_nf_status_pedido',NULL)
  ON CONFLICT(request_id) DO NOTHING;
  GET DIAGNOSTICS v_insert_count=ROW_COUNT;

  IF v_insert_count=0 THEN
    SELECT * INTO v_existing_request
    FROM public.pedido_requests
    WHERE request_id=p_request_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'request_id inconsistente'; END IF;
    IF v_existing_request.empresa_id IS DISTINCT FROM v_empresa_id
       OR v_existing_request.tipo_operacao IS DISTINCT FROM 'atualizar_nf_status_pedido' THEN
      RAISE EXCEPTION 'request_id pertence a outra empresa/operação';
    END IF;
    IF v_existing_request.resultado IS NOT NULL THEN
      RETURN v_existing_request.resultado;
    END IF;
    RAISE EXCEPTION 'request_id em processamento, tente novamente';
  END IF;

  SELECT * INTO v_pedido
  FROM public.pedidos
  WHERE id=p_pedido_id AND empresa_id=v_empresa_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'pedido não encontrado nesta empresa'; END IF;
  IF COALESCE(v_pedido.deleted,false) THEN
    RAISE EXCEPTION 'pedido excluído não pode ter NF atualizada';
  END IF;
  IF v_pedido.versao IS DISTINCT FROM p_versao THEN
    RAISE EXCEPTION 'conflito de versão: pedido foi alterado por outra operação'
      USING ERRCODE='PT412';
  END IF;
  IF COALESCE(v_pedido.nf_numero,'')='' THEN
    RAISE EXCEPTION 'pedido ainda não possui NF registrada';
  END IF;
  IF p_nf_status IN ('autorizada','rejeitada')
     AND v_pedido.nf_status NOT IN ('gerada','emitida') THEN
    RAISE EXCEPTION 'NF só pode ser autorizada ou rejeitada após o registro (status atual: %)',
      v_pedido.nf_status;
  END IF;
  IF p_nf_status='cancelada' AND v_pedido.nf_status IS DISTINCT FROM 'autorizada' THEN
    RAISE EXCEPTION 'somente NF autorizada pode ser cancelada';
  END IF;

  SELECT COALESCE(NULLIF(btrim(u.nome),''),NULLIF(btrim(u.email),''),v_user_id::text)
  INTO v_actor
  FROM public.usuarios u
  WHERE u.id=v_user_id AND u.empresa_id=v_empresa_id;
  v_actor:=COALESCE(v_actor,v_user_id::text);
  v_nova_versao:=v_pedido.versao+1;

  UPDATE public.pedidos
  SET nf_status=p_nf_status,
      nf_autorizada_em=CASE WHEN p_nf_status='autorizada' THEN v_now ELSE nf_autorizada_em END,
      nf_rejeitada_em=CASE WHEN p_nf_status='rejeitada' THEN v_now ELSE nf_rejeitada_em END,
      nf_cancelada_em=CASE WHEN p_nf_status='cancelada' THEN v_now ELSE nf_cancelada_em END,
      nf_status_atualizado_por=v_actor,
      versao=v_nova_versao
  WHERE id=p_pedido_id AND empresa_id=v_empresa_id AND versao=p_versao;
  GET DIAGNOSTICS v_update_count=ROW_COUNT;
  IF v_update_count<>1 THEN
    RAISE EXCEPTION 'falha ao atualizar NF: versão pode ter mudado concorrentemente'
      USING ERRCODE='PT412';
  END IF;

  INSERT INTO public.auditoria(
    empresa_id,actor_auth_uid,actor_usuario_id,acao,detalhe
  ) VALUES (
    v_empresa_id,auth.uid(),v_user_id,'pedido_nf_status_atualizado',
    jsonb_build_object(
      'pedido_id',p_pedido_id,'nf_numero',v_pedido.nf_numero,
      'status_anterior',v_pedido.nf_status,'status_novo',p_nf_status,
      'motivo',NULLIF(btrim(COALESCE(p_motivo,'')),'')
    )
  );

  v_resultado:=jsonb_build_object(
    'pedido_id',p_pedido_id,'nf_numero',v_pedido.nf_numero,
    'nf_status',p_nf_status,'nf_status_atualizado_por',v_actor,
    'nf_status_atualizado_em',v_now,'versao',v_nova_versao
  );
  UPDATE public.pedido_requests SET resultado=v_resultado
  WHERE request_id=p_request_id AND empresa_id=v_empresa_id
    AND tipo_operacao='atualizar_nf_status_pedido';
  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.atualizar_nf_status_pedido(
  uuid,uuid,integer,text,text
) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.atualizar_nf_status_pedido(
  uuid,uuid,integer,text,text
) FROM anon;
GRANT EXECUTE ON FUNCTION public.atualizar_nf_status_pedido(
  uuid,uuid,integer,text,text
) TO authenticated,service_role;
