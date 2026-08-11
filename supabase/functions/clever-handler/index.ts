// Edge Function: criar-empresa
// Cria uma nova empresa e seu usuário administrador inicial.
// Requer service_role — nunca exposta ao cliente diretamente.
//
// Body esperado (JSON):
//   { nome_empresa, razao_social?, cnpj?, email_admin, senha_admin, nome_admin, telefone? }
//
// Resposta de sucesso (201):
//   { empresa_id, usuario_id, message }
//
// Resposta de erro (4xx / 5xx):
//   { error, code }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS })
  }

  if (req.method !== 'POST') {
    return json({ error: 'Método não permitido.', code: 'METHOD_NOT_ALLOWED' }, 405)
  }

  // ── Parse e validação do body ──────────────────────────────────────
  let body: Record<string, string>
  try {
    body = await req.json()
  } catch {
    return json({ error: 'Body inválido. Envie JSON.', code: 'INVALID_BODY' }, 400)
  }

  const { nome_empresa, razao_social, cnpj, email_admin, senha_admin, nome_admin, telefone } = body

  if (!nome_empresa || !email_admin || !senha_admin || !nome_admin) {
    return json({
      error: 'Campos obrigatórios ausentes: nome_empresa, email_admin, senha_admin, nome_admin.',
      code: 'MISSING_FIELDS',
    }, 400)
  }

  if (senha_admin.length < 6) {
    return json({ error: 'A senha deve ter no mínimo 6 caracteres.', code: 'PASSWORD_TOO_SHORT' }, 400)
  }

  const emailLower = email_admin.trim().toLowerCase()
  const emailRx = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  if (!emailRx.test(emailLower)) {
    return json({ error: 'E-mail inválido.', code: 'INVALID_EMAIL' }, 400)
  }

  // ── Cliente Supabase com service_role ──────────────────────────────
  const supabaseUrl  = Deno.env.get('SUPABASE_URL')!
  const serviceKey   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  // ── 1. Verificar se email já existe em auth.users ──────────────────
  const { data: existingUsers, error: listErr } = await sb.auth.admin.listUsers()
  if (listErr) {
    console.error('[criar-empresa] Erro ao listar usuários:', listErr.message)
    return json({ error: 'Erro interno ao verificar e-mail.', code: 'AUTH_LIST_ERROR' }, 500)
  }

  const emailJaExiste = (existingUsers?.users ?? []).some(
    (u) => u.email?.toLowerCase() === emailLower
  )
  if (emailJaExiste) {
    return json({ error: 'Este e-mail já está cadastrado no sistema.', code: 'EMAIL_EXISTS' }, 409)
  }

  // ── 2. Verificar CNPJ duplicado (se fornecido) ────────────────────
  if (cnpj) {
    const cnpjLimpo = cnpj.replace(/\D/g, '')
    if (cnpjLimpo.length > 0) {
      const { data: empCnpj } = await sb
        .from('empresas')
        .select('id')
        .eq('cnpj', cnpjLimpo)
        .maybeSingle()
      if (empCnpj) {
        return json({ error: 'CNPJ já cadastrado no sistema.', code: 'CNPJ_EXISTS' }, 409)
      }
    }
  }

  // ── 3. Criar empresa em public.empresas ───────────────────────────
  const { data: empresa, error: empErr } = await sb
    .from('empresas')
    .insert({
      nome:        nome_empresa.trim(),
      razao_social: razao_social?.trim() || nome_empresa.trim(),
      cnpj:         cnpj ? cnpj.replace(/\D/g, '') : null,
      email:        emailLower,
      telefone:     telefone?.trim() || null,
      plano:        'basico',
      status:       'ativo',
    })
    .select('id')
    .single()

  if (empErr || !empresa) {
    console.error('[criar-empresa] Erro ao criar empresa:', empErr?.message)
    return json({ error: 'Erro ao criar empresa. Tente novamente.', code: 'EMPRESA_INSERT_ERROR' }, 500)
  }

  const empresaId = empresa.id

  // ── 4. Criar usuário em auth.users ────────────────────────────────
  const { data: authData, error: authErr } = await sb.auth.admin.createUser({
    email:          emailLower,
    password:       senha_admin,
    email_confirm:  true,               // confirma e-mail automaticamente
    app_metadata:   { role: 'adm', empresa_id: empresaId },
    user_metadata:  { nome: nome_admin.trim() },
  })

  if (authErr || !authData?.user) {
    // Rollback: remove empresa criada
    await sb.from('empresas').delete().eq('id', empresaId)
    console.error('[criar-empresa] Erro ao criar auth user:', authErr?.message)
    return json({ error: 'Erro ao criar credenciais de acesso. Tente novamente.', code: 'AUTH_CREATE_ERROR' }, 500)
  }

  const authUid = authData.user.id

  // ── 5. Criar perfil em public.usuarios ────────────────────────────
  const { data: usuario, error: userErr } = await sb
    .from('usuarios')
    .insert({
      empresa_id: empresaId,
      nome:       nome_admin.trim(),
      email:      emailLower,
      role:       'adm',
      ativo:      true,
      status:     'ativo',
      auth_uid:   authUid,
      telefone:   telefone?.trim() || null,
      plano:      'basico',
    })
    .select('id')
    .single()

  if (userErr || !usuario) {
    // Rollback: remove auth user e empresa
    await sb.auth.admin.deleteUser(authUid)
    await sb.from('empresas').delete().eq('id', empresaId)
    console.error('[criar-empresa] Erro ao criar usuario:', userErr?.message)
    return json({ error: 'Erro ao criar perfil do usuário. Tente novamente.', code: 'USER_INSERT_ERROR' }, 500)
  }

  const usuarioId = usuario.id

  // ── 6. Criar mapeamento em public.usuarios_auth_map ─
  const { error: mapErr } = await sb
    .from('usuarios_auth_map')
    .insert({
      auth_uid:   authUid,
      usuario_id: usuarioId,
      empresa_id: empresaId,
      role:       'adm',
    })

  if (mapErr) {
    // Rollback completo
    await sb.from('usuarios').delete().eq('id', usuarioId)
    await sb.auth.admin.deleteUser(authUid)
    await sb.from('empresas').delete().eq('id', empresaId)
    console.error('[criar-empresa] Erro ao criar auth map:', mapErr?.message)
    return json({ error: 'Erro ao finalizar cadastro. Tente novamente.', code: 'MAP_INSERT_ERROR' }, 500)
  }

  // ── Sucesso ────────────────────────────────────────────────────────
  console.log('[criar-empresa] Empresa criada com sucesso:', empresaId, '| Admin:', usuarioId)

  return json({
    message:    'Empresa criada com sucesso.',
    empresa_id: empresaId,
    usuario_id: usuarioId,
  }, 201)
})

// ── Helper ─────────────────────────────────────────────────────────
function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  })
}
