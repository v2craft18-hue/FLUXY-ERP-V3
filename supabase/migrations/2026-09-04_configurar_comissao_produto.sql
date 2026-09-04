-- M1B-A: Backend da configuracao oficial de comissao por produto (STAGING)
-- Adiciona auditoria e RPC exclusiva ADM. Nao configura produtos existentes.

BEGIN;

ALTER TABLE public.produtos
  ADD COLUMN IF NOT EXISTS comm_config_atualizado_em timestamptz,
  ADD COLUMN IF NOT EXISTS comm_config_atualizado_por text;

CREATE OR REPLACE FUNCTION public.configurar_comissao_produto(
  p_produto_id text,
  p_comm_type text,
  p_comm_pct numeric,
  p_comm_meta numeric,
  p_preco_base_comissao numeric
)
RETURNS TABLE (
  produto_id text,
  comm_type text,
  comm_pct numeric,
  comm_meta numeric,
  preco_base_comissao numeric,
  comm_config_atualizado_em timestamptz,
  comm_config_atualizado_por text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_empresa uuid;
  v_produto_empresa uuid;
  v_por text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'USUÁRIO NÃO AUTENTICADO';
  END IF;

  v_role := get_user_role();
  IF v_role IS DISTINCT FROM 'adm' THEN
    RAISE EXCEPTION 'ACESSO NEGADO: SOMENTE ADM PODE CONFIGURAR COMISSÃO';
  END IF;

  v_empresa := get_user_empresa_id();

  SELECT p.empresa_id
    INTO v_produto_empresa
    FROM public.produtos p
    WHERE p.id = p_produto_id
      AND p.empresa_id = v_empresa;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUTO NÃO ENCONTRADO OU NÃO PERTENCE À EMPRESA ATUAL';
  END IF;

  IF p_comm_type IS NULL
     AND p_comm_pct IS NULL
     AND p_comm_meta IS NULL
     AND p_preco_base_comissao IS NULL THEN
    NULL;
  ELSIF p_comm_type = 'pct'
        AND p_comm_pct IS NOT NULL
        AND p_comm_pct >= 0
        AND p_comm_meta IS NULL
        AND p_preco_base_comissao IS NULL THEN
    NULL;
  ELSIF p_comm_type = 'caixa'
        AND p_comm_pct IS NULL
        AND p_comm_meta IS NOT NULL
        AND p_comm_meta >= 0
        AND p_preco_base_comissao IS NOT NULL
        AND p_preco_base_comissao >= 0 THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'COMBINAÇÃO INVÁLIDA DE COMM_TYPE/COMM_PCT/COMM_META/PRECO_BASE_COMISSAO';
  END IF;

  SELECT COALESCE(u.nome, u.email)
    INTO v_por
    FROM public.usuarios u
    WHERE u.auth_uid = auth.uid();

  IF v_por IS NULL THEN
    v_por := auth.uid()::text;
  END IF;

  UPDATE public.produtos p
    SET comm_type = p_comm_type,
        comm_pct = p_comm_pct,
        comm_meta = p_comm_meta,
        preco_base_comissao = p_preco_base_comissao,
        comm_config_atualizado_em = now(),
        comm_config_atualizado_por = v_por
    WHERE p.id = p_produto_id
      AND p.empresa_id = v_empresa;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FALHA AO ATUALIZAR CONFIGURAÇÃO DE COMISSÃO';
  END IF;

  RETURN QUERY
    SELECT p.id,
           p.comm_type,
           p.comm_pct,
           p.comm_meta,
           p.preco_base_comissao,
           p.comm_config_atualizado_em,
           p.comm_config_atualizado_por
      FROM public.produtos p
      WHERE p.id = p_produto_id
        AND p.empresa_id = v_empresa;
END;
$$;

REVOKE ALL ON FUNCTION public.configurar_comissao_produto(
  text,
  text,
  numeric,
  numeric,
  numeric
) FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.configurar_comissao_produto(
  text,
  text,
  numeric,
  numeric,
  numeric
) FROM anon;

GRANT EXECUTE ON FUNCTION public.configurar_comissao_produto(
  text,
  text,
  numeric,
  numeric,
  numeric
) TO authenticated;

COMMIT;
