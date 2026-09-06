-- Complete the existing rotas table so the current UI model can be persisted.
ALTER TABLE public.rotas
  ADD COLUMN IF NOT EXISTS numero text,
  ADD COLUMN IF NOT EXISTS obs text NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS ped_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS criado_por uuid;

UPDATE public.rotas
SET numero='ROTA-'||upper(substr(id::text,1,6))
WHERE numero IS NULL OR btrim(numero)='';

ALTER TABLE public.rotas ALTER COLUMN numero SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS rotas_empresa_numero_uidx
  ON public.rotas(empresa_id,numero);

ALTER TABLE public.rotas
  DROP CONSTRAINT IF EXISTS rotas_ped_ids_array_check,
  ADD CONSTRAINT rotas_ped_ids_array_check CHECK (jsonb_typeof(ped_ids)='array');

CREATE INDEX IF NOT EXISTS rotas_empresa_data_idx
  ON public.rotas(empresa_id,data) WHERE deleted=false;
