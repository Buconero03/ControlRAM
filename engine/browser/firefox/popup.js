const api = globalThis.browser || globalThis.chrome;
const status=document.getElementById('status'), log=document.getElementById('log'), notice=document.getElementById('notice');
let current=null, reading=false, generation=0;
function render(reply) {
  if(!reply) throw new Error('Risposta non disponibile');
  current=reply;status.textContent=({connected:'COLLEGATO',connecting:'COLLEGAMENTO IN CORSO',syncing:'ATTENDO LE SCHEDE',error:'NON COLLEGATO',disconnected:'NON COLLEGATO',unknown:'STATO NON DISPONIBILE'}[reply.phase]||'STATO NON DISPONIBILE')+' — '+reply.status;status.dataset.phase=reply.phase||'error';
  document.getElementById('connect').disabled=['connecting','syncing','connected'].includes(reply.phase);
  document.getElementById('disconnect').disabled=!reply.autoReconnect && !['connecting','syncing','connected'].includes(reply.phase);
  document.getElementById('background').textContent=reply.autoReconnect?'Collegamento in background attivo. Siti autorizzati all automatico: '+(reply.automaticHostCount||0)+'. Gli interventi richiedono l agente AME attivo.':'Background disattivato. Premi Collega per abilitarlo.';
  document.getElementById('ack').textContent=reply.lastAck?'Ultima conferma AME: '+new Date(reply.lastAck).toLocaleTimeString():'Nessun elenco ancora confermato da AME.';
  log.textContent=(reply.logs||[]).map(e=>e.utc+'  '+e.code+' — '+e.detail).join('\n');
  if(reply.notice || reply.journalFailure) notice.textContent=reply.notice || reply.journalFailure;
}
async function command(type) {
  if(reading && type==='status') return;
  const request=++generation;let timeout;reading=true;
  if(type==='connect') render({...current,phase:'connecting',status:'Collega premuto: attendo il componente Windows...',logs:[...(current?.logs||[]),{utc:new Date().toISOString(),code:'click',detail:'Richiesta di collegamento inviata.'}]});
  try{
    const reply=await Promise.race([api.runtime.sendMessage({type}),new Promise((_,reject)=>{timeout=setTimeout(()=>reject(new Error('L’estensione non risponde entro 5 secondi. Ricaricala da la pagina delle estensioni del browser.')),5000);})]);
    if(request===generation) render(reply);
  } catch(e){
    if(request===generation) render({...current,phase:'unknown',connected:false,lastAck:0,status:'Stato non disponibile: '+e.message});
  } finally {clearTimeout(timeout);if(request===generation) reading=false;}
}
document.getElementById('connect').addEventListener('click',()=>command('connect'));
document.getElementById('disconnect').addEventListener('click',()=>command('disconnect'));
document.getElementById('protect').addEventListener('click',()=>command('protect-current'));
document.getElementById('allowAutomatic').addEventListener('click',()=>command('allow-automatic-current'));
document.getElementById('revokeAutomatic').addEventListener('click',()=>command('revoke-automatic-current'));
document.getElementById('export').addEventListener('click',()=>{
  if(!current) return;
  const blob=new Blob([JSON.stringify({exported_utc:new Date().toISOString(),...current},null,2)],{type:'application/json'});
  const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='AME-collegamento-'+(current.browser||'Chrome')+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
});
command('status');
const refresh=setInterval(()=>command('status'),1000);
window.addEventListener('unload',()=>clearInterval(refresh));
