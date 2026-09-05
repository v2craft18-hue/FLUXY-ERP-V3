from pathlib import Path
import re

p = Path('index.html')
s = p.read_text(encoding='utf-8')

old = """    nfNumero:     row.nf_numero || '',
    nfStatus:     row.nf_status || null,
    commVal:      row.comissao == null ? null : Number(row.comissao),
    solicitarNF:  row.solicitar_nf || false,
    criadoEm:     row.criado_em,"""
new = """    nfNumero:       row.nf_numero || '',
    nfChave:        row.nf_chave_local || '',
    nfStatus:       row.nf_status || null,
    nfSolicitada:   row.solicitar_nf || false,
    solicitarNF:    row.solicitar_nf || false,
    nfSolicitadaEm: row.nf_solicitada_em || null,
    nfSolicitadaPor:row.nf_solicitada_por || '',
    nfEmitidaEm:    row.nf_emitida_em || null,
    nfEmitidaPor:   row.nf_emitida_por || '',
    commVal:        row.comissao == null ? null : Number(row.comissao),
    criadoEm:       row.criado_em,"""
if s.count(old) != 1:
    raise SystemExit('NF mapping anchor count=%d' % s.count(old))
s = s.replace(old, new, 1)

start = s.index('function confirmarSolicitarNF(pedId){')
end = s.index('function emitirNF(pedId){', start)
new_confirm = """async function confirmarSolicitarNF(pedId){
  var peds=getPeds();
  var p=null;
  for(var i=0;i<peds.length;i++) if(peds[i].id===pedId){p=peds[i];break;}
  if(!p){ toast('Pedido não encontrado.','err'); return; }
  if(!p._sbId || p.versao==null){ toast('Pedido sem vínculo ou versão do servidor. Atualize os dados e tente novamente.','err'); return; }

  var res=await _lifecycleRpc({
    action:'solicitar_nf_pedido',
    pedidoId:pedId,
    busyKey:'solicitarNF:'+pedId,
    rpcName:'solicitar_nf_pedido',
    args:{p_pedido_id:p._sbId,p_versao:p.versao}
  });
  if(!res.ok) return;

  logHist('NF solicitada',pedId+' por '+(SESS.nome||SESS.userId));
  closeModal();
  toast('📨 Solicitação enviada! ADM irá registrar a NF.','ok');
  safeRender('pedidos',renderPed);
  applyRoleNav();
}

"""
s = s[:start] + new_confirm + s[end:]

if s.count('function emitirNF(pedId){') != 1:
    raise SystemExit('emitirNF declaration count=%d' % s.count('function emitirNF(pedId){'))
s = s.replace('function emitirNF(pedId){', 'async function emitirNF(pedId){', 1)

emit_start = s.index('async function emitirNF(pedId){')
gen_marker = '  // Generate NF number\n'
gen_pos = s.index(gen_marker, emit_start)
guard = """  if(!p._sbId || p.versao==null){
    toast('Pedido sem vínculo ou versão do servidor. Atualize os dados e tente novamente.','err');
    return;
  }

"""
s = s[:gen_pos] + guard + s[gen_pos:]

emit_start = s.index('async function emitirNF(pedId){')
formatted = "  var nfKeyFormatted=nfKey.replace(/(.{4})/g,'$1 ').trim();"
fmt_pos = s.index(formatted, emit_start)
rpc_block = """  var nfRpc=await _lifecycleRpc({
    action:'registrar_nf_local_pedido',
    pedidoId:pedId,
    busyKey:'registrarNFLocal:'+pedId,
    rpcName:'registrar_nf_local_pedido',
    args:{p_pedido_id:p._sbId,p_versao:p.versao,p_nf_numero:nfNum,p_nf_chave_local:nfKey}
  });
  if(!nfRpc.ok) return;
  // Replay idempotente pode devolver a NF originalmente gravada.
  // O documento exibido usa sempre os valores autoritativos do servidor.
  if(nfRpc.data){
    if(nfRpc.data.nf_numero) nfNum=String(nfRpc.data.nf_numero);
    if(nfRpc.data.nf_chave_local) nfKey=String(nfRpc.data.nf_chave_local);
  }
"""
s = s[:fmt_pos] + rpc_block + s[fmt_pos:]

emit_start = s.index('async function emitirNF(pedId){')
mut_start = s.index('  var idx=-1;', emit_start)
modal_marker = '  // Show NF result modal\n'
mut_end = s.index(modal_marker, mut_start)
replacement = """  logHist('NF local registrada',pedId+' · NF '+nfNum);
  closeModal();

"""
s = s[:mut_start] + replacement + s[mut_end:]

old = "else if(st==='emitida') nEm++;"
new = "else if(st==='emitida'||st==='gerada') nEm++;"
if s.count(old) != 1:
    raise SystemExit('NF KPI emitted anchor count=%d' % s.count(old))
s = s.replace(old, new, 1)

old = "var stColor=nfSt==='autorizada'?'#10B981':nfSt==='emitida'?'#3B82F6':nfSt==='rejeitada'?'#EF4444':'#F59E0B';"
new = "var stColor=nfSt==='autorizada'?'#10B981':(nfSt==='emitida'||nfSt==='gerada')?'#3B82F6':nfSt==='rejeitada'?'#EF4444':'#F59E0B';"
if s.count(old) != 1:
    raise SystemExit('NF color anchor count=%d' % s.count(old))
s = s.replace(old, new, 1)

old = "var stLabel=nfSt==='autorizada'?'✅ Autorizada':nfSt==='emitida'?'🧾 Emitida':nfSt==='rejeitada'?'❌ Rejeitada':'⏳ Aguardando';"
new = "var stLabel=nfSt==='autorizada'?'✅ Autorizada':(nfSt==='emitida'||nfSt==='gerada')?'🧾 Registrada localmente':nfSt==='rejeitada'?'❌ Rejeitada':'⏳ Aguardando';"
if s.count(old) != 1:
    raise SystemExit('NF label anchor count=%d' % s.count(old))
s = s.replace(old, new, 1)

s = s.replace('NF Gerada (ambiente local)', 'NF registrada (ambiente local)')

p.write_text(s, encoding='utf-8')
