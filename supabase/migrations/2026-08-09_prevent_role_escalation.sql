-- Migration: prevent_role_escalation
-- Causa: policies de UPDATE/INSERT em usuarios nao validavam a role da
-- linha nova, permitindo que um GERENTE promovesse qualquer usuario para
-- ADM, ou movesse um usuario para outra empresa via update direto.
-- Correcao: trigger BEFORE INSERT/UPDATE. service_role e isento pois a
-- validacao de negocio ja ocorre dentro da funcao criar-usuario.
CREATE OR REPLACE FUNCTION public.prevent_privilege_escalation() RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.role IN ('adm','gerente','ger') AND get_user_role() <> 'adm' THEN
      RAISE EXCEPTION 'Apenas administradores podem criar usuarios com este papel.';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.role IS DISTINCT FROM OLD.role AND get_user_role() <> 'adm' THEN
      RAISE EXCEPTION 'Apenas administradores podem alterar o papel de um usuario.';
    END IF;
    IF NEW.empresa_id IS DISTINCT FROM OLD.empresa_id THEN
      RAISE EXCEPTION 'Nao e permitido mover um usuario para outra empresa.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_prevent_privilege_escalation ON public.usuarios;
CREATE TRIGGER trg_prevent_privilege_escalation
BEFORE INSERT OR UPDATE ON public.usuarios
FOR EACH ROW EXECUTE FUNCTION public.prevent_privilege_escalation();

