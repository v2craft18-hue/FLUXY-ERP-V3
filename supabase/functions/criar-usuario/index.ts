// Edge Function: criar-usuario
// Cria um novo usuario dentro da MESMA empresa do usuario autenticado.
// Regras de seguranca: role/empresa_id do chamador sao lidos do banco via
// JWT, nunca do body. Somente ADMIN/GERENTE podem criar usuarios da MESMA
// empresa. Nenhuma senha e transportada; um link de definicao de senha e
// retornado. Acoes sensiveis sao registradas em public.auditoria.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  }

  const ROLES_GERENCIAIS = ['adm', 'gerente', 'ger']
  const ROLES_RESTRITAS_A_ADMIN = ['adm', 'gerente', 'ger']
  const ROLES_VALIDOS = ['adm', 'gerente', 'ger', 'vend', 'entr']

  Deno.serve(async (req) => {
      if (req.method === 'OPTIONS') {
        return new Response(null, { status: 204, headers: CORS_HEADERS })
          }
  if (req.method !== 'POST') {
    return json({ error: 'Metodo nao permitido.', code: 'METHOD_NOT_ALLOWED' }, 405)
      }

  const authHeader = req.headers.get('Authorization') || ''
  const token = authHeader.replace(/^Bearer\s+/i, '')
  if (!token) {
    return json({ error: 'Token de autenticacao ausente.', code: 'NO_TOKEN' }, 401)
}

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
})

  const { data: callerAuth, error: callerAuthErr } = await sb.auth.getUser(token)
  if (callerAuthErr || !callerAuth || !callerAuth.user) {
    return json({ error: 'Sessao invalida ou expirada.', code: 'INVALID_SESSION' }, 401)
}
  const callerUid = callerAuth.user.id

  const { data: callerRow, error: callerRowErr } = await sb
    .from('usuarios')
    .select('id, empresa_id, role, ativo, status')
    .eq('auth_uid', callerUid)
    .maybeSingle()

  if (callerRowErr || !callerRow) {
    return json({ error: 'Usuario solicitante nao encontrado.', code: 'CALLER_NOT_FOUND' }, 403)
}
  if (!callerRow.ativo || callerRow.status === 'desligado' || callerRow.status === 'bloqueado') {
    return json({ error: 'Usuario solicitante esta inativo.', code: 'CALLER_INACTIVE' }, 403)
}
  if (!ROLES_GERENCIAIS.includes(callerRow.role)) {
    return json({ error: 'Apenas administradores e gerentes podem realizar esta acao.', code: 'FORBIDDEN_ROLE' }, 403)
}

  const empresaId = callerRow.empresa_id

  let body
  try {
    body = await req.json()
} catch {
    return json({ error: 'Body invalido. Envie JSON.', code: 'INVALID_BODY' }, 400)
}

  const acao = body.acao

  if (acao === 'resetar_senha') {
    return handleResetSenha(sb, body, callerRow, callerUid, empresaId)
}

  if (acao !== 'criar') {
    return json({ error: "Acao invalida. Use 'criar' ou 'resetar_senha'.", code: 'INVALID_ACTION' }, 400)
}

  const nome = body.nome
  const email = body.email
  const role = body.role
  const telefone = body.telefone

  if (!nome || !email || !role) {
    return json({ error: 'Campos obrigatorios ausentes: nome, email, role.', code: 'MISSING_FIELDS' }, 400)
}

  if (!ROLES_VALIDOS.includes(role)) {
    return json({ error: 'Papel (role) invalido.', code: 'INVALID_ROLE' }, 400)
}

  if (callerRow.role !== 'adm' && ROLES_RESTRITAS_A_ADMIN.includes(role)) {
    return json({ error: 'Somente administradores podem criar usuarios com este papel.', code: 'FORBIDDEN_ROLE_ESCALATION' }, 403)
}

  const emailLower = email.trim().toLowerCase()
  const emailRx = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
  if (!emailRx.test(emailLower)) {
    return json({ error: 'E-mail invalido.', code: 'INVALID_EMAIL' }, 400)
}

  const { data: usuarioExistente, error: existErr } = await sb
    .from('usuarios')
    .select('id, empresa_id, auth_uid, nome, role')
    .eq('email', emailLower)
    .maybeSingle()

  if (existErr) {
    console.error('[criar-usuario] Erro ao verificar usuario existente:', existErr.message)
    return json({ error: 'Erro interno ao verificar usuario.', code: 'CHECK_USER_ERROR' }, 500)
}

  if (usuarioExistente && usuarioExistente.empresa_id !== empresaId) {
    return json({ error: 'Este e-mail ja esta vinculado a outra empresa.', code: 'EMAIL_OTHER_EMPRESA' }, 409)
}

  if (usuarioExistente && usuarioExistente.auth_uid) {
    return json({ error: 'Este e-mail ja possui uma conta de acesso ativa.', code: 'EMAIL_ALREADY_LINKED' }, 409)
}

  const { data: existingUsers, error: listErr } = await sb.auth.admin.listUsers()
  if (listErr) {
    console.error('[criar-usuario] Erro ao listar usuarios:', listErr.message)
    return json({ error: 'Erro interno ao verificar e-mail.', code: 'AUTH_LIST_ERROR' }, 500)
}
  const authExistente = (existingUsers && existingUsers.users ? existingUsers.users : []).find(
    (u) => u.email && u.email.toLowerCase() === emailLower
  )

  let authUid

  if (authExistente) {
    const { data: mapExistente } = await sb
      .from('usuarios_auth_map')
      .select('usuario_id')
      .eq('auth_uid', authExistente.id)
      .maybeSingle()
    if (mapExistente) {
      return json({ error: 'Este e-mail ja possui uma conta de acesso vinculada.', code: 'EMAIL_ALREADY_LINKED' }, 409)
}
    authUid = authExistente.id
    await sb.auth.admin.updateUserById(authUid, {
      app_metadata: { role: role, empresa_id: empresaId },
    })
    } else {

    const senhaTemporaria = crypto.randomUUID() + crypto.randomUUID()
    const { data: authData, error: authErr } = await sb.auth.admin.createUser({
      email: emailLower,
      password: senhaTemporaria,
      email_confirm: true,
      app_metadata: { role: role, empresa_id: empresaId },
      user_metadata: { nome: nome.trim() },
})
    if (authErr || !authData || !authData.user) {
      console.error('[criar-usuario] Erro ao criar auth user:', authErr ? authErr.message : 'sem detalhe')
      return json({ error: 'Erro ao criar credenciais de acesso. Tente novamente.', code: 'AUTH_CREATE_ERROR' }, 500)
}
    authUid = authData.user.id
}

  let usuarioId

  if (usuarioExistente) {
    const { data: updRow, error: updErr } = await sb
      .from('usuarios')
      .update({ auth_uid: authUid, role: role, ativo: true, status: 'ativo' })
      .eq('id', usuarioExistente.id)
      .select('id')
      .single()
    if (updErr || !updRow) {
      if (!authExistente) await sb.auth.admin.deleteUser(authUid)
      console.error('[criar-usuario] Erro ao vincular usuario existente:', updErr ? updErr.message : 'sem detalhe')
      return json({ error: 'Erro ao vincular usuario existente.', code: 'LINK_USER_ERROR' }, 500)
}
    usuarioId = updRow.id
} else {

    const { data: novoUsuario, error: insErr } = await sb
      .from('usuarios')
      .insert({
        empresa_id: empresaId,
        nome: nome.trim(),
        email: emailLower,
        role: role,
        ativo: true,
        status: 'ativo',
        auth_uid: authUid,
        telefone: telefone ? telefone.trim() : null,
})
      .select('id')
      .single()
    if (insErr || !novoUsuario) {
      if (!authExistente) await sb.auth.admin.deleteUser(authUid)
      console.error('[criar-usuario] Erro ao criar usuario:', insErr ? insErr.message : 'sem detalhe')
      return json({ error: 'Erro ao criar perfil do usuario. Tente novamente.', code: 'USER_INSERT_ERROR' }, 500)
}
    usuarioId = novoUsuario.id
}

  const { error: mapErr } = await sb
    .from('usuarios_auth_map')
    .upsert({ auth_uid: authUid, usuario_id: usuarioId, empresa_id: empresaId }, { onConflict: 'auth_uid' })
  if (mapErr) {
    console.error('[criar-usuario] Erro ao criar auth map:', mapErr.message)
}

  const { data: linkData, error: linkErr } = await sb.auth.admin.generateLink({
    type: 'recovery',
    email: emailLower,
})
  if (linkErr) {
    console.error('[criar-usuario] Erro ao gerar link de senha:', linkErr.message)
}

  await sb.from('auditoria').insert({
    empresa_id: empresaId,
    actor_auth_uid: callerUid,
    actor_usuario_id: callerRow.id,
    acao: usuarioExistente ? 'usuario_vinculado' : 'usuario_criado',
    alvo_usuario_id: usuarioId,
    detalhe: { role: role, email: emailLower },
})

  console.log('[criar-usuario] Usuario processado com sucesso:', usuarioId)

  return json({
    message: usuarioExistente ? 'Usuario existente vinculado com sucesso.' : 'Usuario criado com sucesso.',
    usuario_id: usuarioId,
    auth_uid: authUid,
    action_link: linkData && linkData.properties ? linkData.properties.action_link : null,
    vinculado_existente: !!usuarioExistente,
}, usuarioExistente ? 200 : 201)
})

async function handleResetSenha(sb, body, callerRow, callerUid, empresaId) {
  const usuarioId = body.usuario_id
  if (!usuarioId) {
    return json({ error: 'Campo obrigatorio ausente: usuario_id.', code: 'MISSING_FIELDS' }, 400)
}

  const { data: alvo, error: alvoErr } = await sb
    .from('usuarios')
    .select('id, email, empresa_id, auth_uid, role')
    .eq('id', usuarioId)
    .maybeSingle()

  if (alvoErr || !alvo) {
    return json({ error: 'Usuario nao encontrado.', code: 'USER_NOT_FOUND' }, 404)
}

  if (alvo.empresa_id !== empresaId) {
    return json({ error: 'Voce nao tem permissao para redefinir a senha deste usuario.', code: 'FORBIDDEN_CROSS_TENANT' }, 403)
}

  // GERENTE nao pode resetar senha de ADMIN nem de outro GERENTE (evita escalada/sequestro de conta privilegiada).
  // Apenas ADMIN pode resetar senha de contas com papel administrativo/gerencial.
  if (callerRow.role !== 'adm' && ROLES_RESTRITAS_A_ADMIN.includes(alvo.role)) {
    return json({ error: 'Somente administradores podem redefinir a senha de administradores ou gerentes.', code: 'FORBIDDEN_ROLE_ESCALATION' }, 403)
  }

  if (!alvo.auth_uid) {
    return json({ error: 'Este usuario ainda nao possui uma conta de acesso vinculada.', code: 'NO_AUTH_ACCOUNT' }, 400)
}

  const { data: linkData, error: linkErr } = await sb.auth.admin.generateLink({
    type: 'recovery',
    email: alvo.email,
})
  if (linkErr || !linkData) {
    console.error('[criar-usuario] Erro ao gerar link de redefinicao:', linkErr ? linkErr.message : 'sem detalhe')
    return json({ error: 'Erro ao gerar link de redefinicao de senha.', code: 'RESET_LINK_ERROR' }, 500)
}

  await sb.from('auditoria').insert({
    empresa_id: empresaId,
    actor_auth_uid: callerUid,
    actor_usuario_id: callerRow.id,
    acao: 'senha_resetada',
    alvo_usuario_id: usuarioId,
    detalhe: {},
})

  return json({
    message: 'Link de redefinicao de senha gerado com sucesso.',
    usuario_id: usuarioId,
    action_link: linkData.properties ? linkData.properties.action_link : null,
}, 200)
}

function json(data, status) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: Object.assign({ 'Content-Type': 'application/json' }, CORS_HEADERS),
})
}
