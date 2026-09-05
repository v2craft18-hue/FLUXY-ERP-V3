-- Completa a auditoria da intenção p_solicitar_nf já recebida por criar_pedido.
-- Não muda o status comercial do pedido, comissão, versão ou fluxo de aprovação.
-- Apenas transforma solicitar_nf=true, no INSERT, em uma solicitação de NF auditável.

CREATE OR REPLACE FUNCTION public.stamp_nf_request_on_order_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id uuid;
  v_actor text;
BEGIN
  IF COALESCE(NEW.solicitar_nf, false)
     AND NEW.nf_status IS NULL
     AND COALESCE(NEW.nf_numero, '') = '' THEN

    v_user_id := public.get_user_id();

    IF v_user_id IS NOT NULL THEN
      SELECT COALESCE(NULLIF(trim(u.nome), ''), NULLIF(trim(u.email), ''), v_user_id::text)
      INTO v_actor
      FROM public.usuarios u
      WHERE u.id = v_user_id
        AND u.empresa_id = NEW.empresa_id;
    END IF;

    NEW.nf_status := 'aguardando';
    NEW.nf_solicitada_em := COALESCE(NEW.nf_solicitada_em, now());
    NEW.nf_solicitada_por := COALESCE(
      NULLIF(trim(NEW.nf_solicitada_por), ''),
      v_actor,
      v_user_id::text,
      'sistema'
    );
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_stamp_nf_request_on_order_insert ON public.pedidos;
CREATE TRIGGER trg_stamp_nf_request_on_order_insert
BEFORE INSERT ON public.pedidos
FOR EACH ROW
EXECUTE FUNCTION public.stamp_nf_request_on_order_insert();

REVOKE ALL ON FUNCTION public.stamp_nf_request_on_order_insert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.stamp_nf_request_on_order_insert() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stamp_nf_request_on_order_insert() TO service_role;
