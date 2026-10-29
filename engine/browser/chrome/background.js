import { blocked, defaultProtected, validateRequest, automaticBlocked } from './policy.js';
const api = globalThis.browser || globalThis.chrome;
const browserName = api.runtime.id === 'ame@advancedmemoryengine.local' ? 'Firefox' : 'Chrome';
const host = 'it.ame.browser', PROTOCOL = 4, MAX_TABS = 300;
const ACK_TIMEOUT = 15000, HEALTH_TIMEOUT = 30000;
const RECONNECT_ALARM = 'ame-reconnect', RETRY_MS = 30000;
let autoReconnect = false, nextAttemptAt = 0, operations = Promise.resolve();
let port = null, session = '', timer = null, watchdog = null;
let inventoryStage='not_started';
let automaticHostCount=0, agentMode=false, tabEpoch=0, policyEpoch=0;
api.storage.onChanged?.addListener((changes,area)=>{if(area==='local' && (changes.automaticHosts || changes.protectedHosts))policyEpoch++;});
let phase = 'disconnected', status = 'Apri AME e premi Collega.', lastError = '', lastAck = 0;
let documents = new Map(), used = new Set(), returns = new Map(), busy = false;
let snapshotOwner = null, nextSequence = 0, pendingSnapshot = null, welcomeAt = 0, connectingAt = 0;
let journal = [], persistChain = Promise.resolve(), journalFailure = ''; 
const restored = api.storage.session.get('connectionJournal').then(data => {
  if (Array.isArray(data.connectionJournal)) journal = data.connectionJournal.slice(-99);
  record('worker_started', 'Estensione avviata. Ripristino delle preferenze di collegamento.');
}).catch(() => { record('journal_unavailable', 'Storico della sessione non disponibile.'); });
// Listeners are registered synchronously; persisted opt-in survives worker/browser restarts.
// A single serialized queue prevents a late reconnect from undoing an explicit disconnect.
function enqueue(work) {
  const result = operations.then(work);
  operations = result.catch(() => {});
  return result;
}
function backgroundFailure(error) {
  lastError = 'Collegamento automatico non disponibile: '+String(error.message).slice(0,240);
  change('error',lastError,'background_error');
}
async function stopBackground(message) {
  autoReconnect=false;disconnect();
  change('disconnected',message,'manual_disconnect');
  await api.alarms.clear(RECONNECT_ALARM);
  await api.storage.local.set({connectionEnabled:false,connectionNextAttempt:0});
}
async function attempt(reason, force=false) {
  checkHealth();
  if (!autoReconnect || port || (!force && Date.now()<nextAttemptAt)) return;
  nextAttemptAt=Date.now()+RETRY_MS;
  // Persist the cooldown before spawning a native host, also across worker restarts.
  await api.storage.local.set({connectionNextAttempt:nextAttemptAt});
  connect(reason);
}
const initialized = restored.then(async()=>{
  const saved=await api.storage.local.get(['connectionEnabled','connectionNextAttempt']);
  autoReconnect=saved.connectionEnabled===true;
  await automaticHosts();
  const due=Number(saved.connectionNextAttempt);
  nextAttemptAt=Number.isFinite(due)?Math.min(due,Date.now()+RETRY_MS):0;
  if(autoReconnect){
    await api.alarms.create(RECONNECT_ALARM,{periodInMinutes:0.5});
    record('background_enabled','Collegamento automatico attivo anche con il riquadro chiuso.');
    await attempt('background');
  }else await api.alarms.clear(RECONNECT_ALARM);
}).catch(backgroundFailure);
operations=initialized;
function wake(){void enqueue(()=>attempt('background')).catch(backgroundFailure);}
api.alarms.onAlarm.addListener(alarm=>{if(alarm.name===RECONNECT_ALARM) wake();});
api.runtime.onStartup.addListener(wake);
api.runtime.onInstalled.addListener(wake);
function record(code, detail) {
  journal.push({utc:new Date().toISOString(),code,detail:String(detail).slice(0,500)});
  journal = journal.slice(-100);
  const copy = structuredClone(journal);
  persistChain = persistChain.then(() => api.storage.session.set({connectionJournal:copy})).catch(() => {journalFailure='Salvataggio dello storico non disponibile; esporta il registro prima di ricaricare l estensione.';});
}
function state() {
  checkHealth();
  return {phase,status,connected:phase==='connected',lastError,lastAck,journalFailure,logs:journal.slice(-100),version:'0.5.0',protocol:PROTOCOL,browser:browserName,inventoryStage,autoReconnect,nextAttemptAt,automaticHostCount,agentMode};
}
function change(next, message, code=next) {
  const different=phase!==next || status!==message;
  phase=next;status=message;
  if(different) record(code,message);
}
function fail(code, message) {
  lastError=message;disconnect();change('error',message+(autoReconnect?' Riprovo in background; puoi premere Scollega per fermarmi.':''),code);
}
function checkHealth() {
  if(!port) return;
  const now=Date.now();
  if(!welcomeAt && now-connectingAt>=ACK_TIMEOUT) {fail('hello_timeout','AME non ha risposto entro 15 secondi. Verifica il registro nel pannello.');return;}
  if(welcomeAt && !lastAck && now-welcomeAt>=ACK_TIMEOUT) {fail('initial_inventory_timeout','Lettura o conferma iniziale delle schede non completata entro 15 secondi. Ricollega il profilo e consulta il registro.');return;}
  if(pendingSnapshot && now-pendingSnapshot.sent>=ACK_TIMEOUT) {fail('inventory_timeout','AME non ha confermato l’elenco schede entro 15 secondi. Consulta il registro del collegamento.');return;}
  if(lastAck && now-lastAck>=HEALTH_TIMEOUT) fail('health_timeout','Collegamento scaduto: AME non conferma piu gli aggiornamenti. Premi Collega per riprovare.');
}
async function protectedHosts() {
  const data = await api.storage.local.get('protectedHosts');
  return [...new Set([...defaultProtected, ...(Array.isArray(data.protectedHosts) ? data.protectedHosts : [])])];
}
async function automaticHosts() {
  const data=await api.storage.local.get('automaticHosts');
  const hosts=Array.isArray(data.automaticHosts)?data.automaticHosts.filter(h=>typeof h==='string' && h.length<=253).slice(0,64):[];
  automaticHostCount=hosts.length;return hosts;
}
function revision(tab) {
  let doc = documents.get(tab.id);
  if (!doc || doc.url !== tab.url) { doc = { url: tab.url, revision: crypto.randomUUID() }; documents.set(tab.id, doc); }
  return doc.revision;
}
function send(message, expected = port) {
  if (!expected || expected !== port) return false;
  try { expected.postMessage({ ...message, session });return true; }
  catch(e) {fail('send_failed','Invio al componente Windows fallito: '+String(e.message).slice(0,240));return false;}
}
async function snapshot() {
  if (!port || !welcomeAt || snapshotOwner === port || pendingSnapshot) return;
  const expected=port, expectedSession=session;
  snapshotOwner=expected;inventoryStage='reading_protections';
  record('inventory_start','Leggo le protezioni prima dell elenco schede.');
  try {
    const hosts=await protectedHosts();
    const allowed=await automaticHosts();
    if(expected!==port || expectedSession!==session)return;
    inventoryStage='querying_tabs';record('inventory_query','Richiedo l elenco delle schede al browser.');
    const tabs=await api.tabs.query({});
    if(expected!==port || expectedSession!==session) return;
    inventoryStage='building_snapshot';record('inventory_read','Lettura completata: '+tabs.length+' schede.');
    const seen=new Set(tabs.map(t=>t.id));
    for(const id of documents.keys()) if(!seen.has(id)) documents.delete(id);
    const sequence=++nextSequence;
    const items=[];let bytes=1000;const encoder=new TextEncoder();
    for(const tab of tabs.slice(0,MAX_TABS)) {
      let host='';try{host=new URL(tab.url).hostname;}catch{}
      const item={id:tab.id,title:String(tab.title||'Scheda').slice(0,160),revision:revision(tab),blocked:blocked(tab,hosts,browserName),discarded:tab.discarded===true,lastAccessed:tab.lastAccessed||null,host,auto_allowed:allowed.includes(host)};
      const size=encoder.encode(JSON.stringify(item)).length+1;if(bytes+size>240000)break;
      bytes+=size;items.push(item);
    }
    pendingSnapshot={sequence,sent:Date.now(),count:items.length};
    const transmitted=send({type:'snapshot',protocol:PROTOCOL,sequence,total:tabs.length,truncated:items.length<tabs.length,automatic_policy_revision:1,tabs:items},expected);
    if(transmitted){if(pendingSnapshot)inventoryStage='awaiting_ack';record('inventory_sent','Elenco inviato al componente Windows: sequenza '+sequence+', '+items.length+' schede. Attendo conferma.');}
  } catch(e) {
    if(expected===port) fail('snapshot_failed','Lettura delle schede fallita: '+String(e.message).slice(0,240));
  } finally {if(snapshotOwner===expected) snapshotOwner=null;}
}
function disconnect() {
  const old=port;port=null;session='';documents.clear();used.clear();returns.clear();
  pendingSnapshot=null;snapshotOwner=null;welcomeAt=0;lastAck=0;nextSequence=0;agentMode=false;
  if(timer) clearInterval(timer);timer=null;
  if(watchdog) clearInterval(watchdog);watchdog=null;
  if(old) try{old.disconnect();}catch{}
}
function connect(reason) {
  checkHealth();
  if(port) return;
  inventoryStage='not_started';lastError='';session=crypto.randomUUID();connectingAt=Date.now();documents.clear();used.clear();
  record(reason==='manual'?'connect_clicked':'background_attempt',reason==='manual'?'Collega premuto: avvio il componente Windows.':'Tentativo di collegamento in background.');
  change('connecting','Avvio del collegamento Windows...');
  try {
    const expected=api.runtime.connectNative(host);port=expected;
    expected.onDisconnect.addListener(()=>{
      const error=api.runtime.lastError || expected.error;
      if(port===expected) fail('native_disconnect','Collegamento Windows interrotto: '+(error?.message||'AME o il componente locale ha chiuso la connessione.'));
    });
    expected.onMessage.addListener(message=>{if(expected===port) void onNative(message,expected);});
    watchdog=setInterval(checkHealth,1000);
    send({type:'hello',protocol:PROTOCOL,extension:api.runtime.id,version:'0.5.0',connectionReason:reason,browser:browserName,autoReconnect,capabilities:['automatic-site-policy-v1']});
  } catch(e) {fail('native_connect_failed','Impossibile avviare il componente Windows: '+String(e.message).slice(0,240));}
}
async function onNative(message,expected) {
  if(message?.session!==session && message?.type!=='discard') return;
  if(message?.type==='stop_connection') {
    if(message.protocol!==PROTOCOL) return;
    void enqueue(()=>{if(expected===port) return stopBackground('Scollegato dal pannello AME. Premi Collega per riattivare il background.');}).catch(backgroundFailure);
    return;
  }
  if(message?.type==='connection_error') {
    fail(String(message.code||'hub_rejected'), 'AME ha rifiutato il collegamento: '+String(message.reason||'Consulta il registro Windows.').slice(0,300));return;
  }
  if(message?.type==='welcome') {
    if(message.protocol!==PROTOCOL || welcomeAt) {fail('protocol_mismatch','Versioni non compatibili: aggiorna AME e ricarica l’estensione.');return;}
    agentMode=message.agent_mode==='automatic_authorized_sites';
    welcomeAt=Date.now();change('syncing','AME ha risposto. Attendo la conferma dell’elenco schede...');
    timer=setInterval(()=>void snapshot(),10000);
    await snapshot();return;
  }
  if(message?.type==='inventory_ack') {
    if(message.protocol!==PROTOCOL || !pendingSnapshot || message.sequence!==pendingSnapshot.sequence || message.count!==pendingSnapshot.count) {
      fail('invalid_inventory_ack','Conferma dell’elenco non valida. Consulta il registro Windows.');return;
    }
    inventoryStage='confirmed';lastAck=Date.now();const count=pendingSnapshot.count;pendingSnapshot=null;
    change('connected','Collegato: AME ha ricevuto '+count+' schede. '+(agentMode?'Agente automatico attivo: valuta soltanto i siti autorizzati.':'Scegli l’intervento nel pannello Windows.'),'inventory_confirmed');return;
  }
  if(message?.type==='refresh') {await snapshot();return;}
  if (message?.type !== 'discard') return;
  checkHealth();
  if(expected!==port || phase!=='connected') return;
  const expectedSession = session;
  let error = validateRequest(message, expectedSession, Date.now());
  if (!error && used.has(message.request)) error = 'Richiesta gia elaborata';
  if (!error && busy) error = 'Un intervento e gia in corso';
  if (error) { send({ type:'result', request:message.request, tab:message.tab, outcome:'declined', reason:error }, expected); return; }
  if (used.size >= 1000) { send({type:'result',request:message.request,tab:message.tab,outcome:'declined',reason:'Limite sessione raggiunto: ricollega'},expected); return; }
  used.add(message.request); busy = true;
  const began = Date.now(), expectedTabEpoch=tabEpoch, expectedPolicyEpoch=policyEpoch;
  try {
    const hosts = await protectedHosts();
    const tab = await api.tabs.get(message.tab);
    if (expected !== port || expectedSession !== session) return;
    error = validateRequest(message, session, Date.now()) || blocked(tab, hosts, browserName);
    if(!error && message.authorization==='site_policy_v1')error=automaticBlocked(tab,await automaticHosts(),Date.now(),browserName);
    if(expected!==port || expectedSession!==session)return;
    if(tabEpoch!==expectedTabEpoch || policyEpoch!==expectedPolicyEpoch)error='Stato schede o autorizzazioni cambiato durante il controllo';
    if (!error && revision(tab) !== message.revision) error = 'La pagina e cambiata: aggiorna la selezione';
    if (error) throw new Error(error);
    const result = await api.tabs.discard(tab.id);
    const after = await api.tabs.get(tab.id);
    if (expected !== port || expectedSession !== session) return;
    // Discard is confirmed by state, never merely by resolved Promise.
    if ((browserName==='Chrome' && !result) || after.discarded !== true) throw new Error('Il browser non ha confermato lo scaricamento');
    returns.set(tab.id,{request:message.request,start:null});
    send({ type:'result', request:message.request, tab:tab.id, outcome:'discarded', operation_ms:Date.now()-began },expected);
  } catch(e) {
    send({ type:'result', request:message.request, tab:message.tab, outcome:'declined', reason:String(e.message).slice(0,240) },expected);
  } finally { busy=false; await snapshot(); }
}
api.runtime.onMessage.addListener((message, sender, respond) => {
  // Accept controls only from our popup, never from a tab or another extension.
  if (sender.id !== api.runtime.id || sender.tab || sender.url !== api.runtime.getURL('popup.html')) return;
  if (message?.type === 'connect' || message?.type === 'disconnect') {
    void enqueue(async()=>{
      if(message.type==='disconnect'){
        await stopBackground('Scollegato su tua richiesta. Collegamento automatico disattivato.');
      }else{
        record('connect_requested','Richiesta Collega ricevuta.');
        await api.storage.local.set({connectionEnabled:true});
        autoReconnect=true;
        await api.alarms.create(RECONNECT_ALARM,{periodInMinutes:0.5});
        await attempt('manual',true);
      }
      return state();
    }).then(respond).catch(error=>{backgroundFailure(error);respond(state());});
    return true;
  }
  if (message?.type === 'status') {void initialized.then(()=>respond(state()));return true; }
  if (['allow-automatic-current','revoke-automatic-current'].includes(message?.type)) {
    policyEpoch++;
    void enqueue(async()=>{
      const [tab]=await api.tabs.query({active:true,currentWindow:true});const u=new URL(tab.url);
      if(!/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(u.hostname) || !u.hostname.includes('.') || u.hostname.includes('..') || u.hostname.length>253)throw new Error('Nome del sito non supportato per l automatico.');
      if(u.protocol!=='https:')throw new Error('Autorizzazione automatica disponibile solo su siti HTTPS.');
      const hosts=await protectedHosts();
      if(message.type==='allow-automatic-current' && hosts.some(h=>u.hostname===h || u.hostname.endsWith('.'+h)))throw new Error('Questo sito e protetto in AME: nessuna autorizzazione automatica.');
      let allowed=await automaticHosts();allowed=allowed.filter(h=>h!==u.hostname);
      if(message.type==='allow-automatic-current'){if(allowed.length>=64)throw new Error('Limite di 64 siti autorizzati raggiunto.');allowed.push(u.hostname);}
      await api.storage.local.set({automaticHosts:allowed});automaticHostCount=allowed.length;
      record('automatic_policy_changed','Autorizzazione automatica del sito aggiornata.');await snapshot();
      return {...state(),notice:message.type==='allow-automatic-current'?'Automatico autorizzato per '+u.hostname+'. Solo schede inattive da almeno 15 minuti, con agente attivo e pressione RAM.':'Automatico revocato per '+u.hostname+'. Una richiesta gia eseguita non puo essere annullata.'};
    }).then(respond).catch(e=>respond({...state(),notice:String(e.message)}));return true;
  }
  if (message?.type === 'protect-current') {
    policyEpoch++;
    void (async () => {
      const [tab] = await api.tabs.query({ active:true, currentWindow:true });
      const u = new URL(tab.url);
      if (!['https:','http:'].includes(u.protocol)) throw new Error('Sito non supportato');
      const data = await api.storage.local.get('protectedHosts');
      const hosts = Array.isArray(data.protectedHosts) ? data.protectedHosts : [];
      await api.storage.local.set({protectedHosts:[...new Set([...hosts,u.hostname])]});
      await snapshot();record('site_protected','Protezione del sito corrente aggiornata.');respond({...state(),notice:'Sito protetto in AME: '+u.hostname});
    })().catch(e => respond({...state(),notice:String(e.message)}));
    return true;
  }
});
api.tabs.onUpdated.addListener((id,change) => {
  tabEpoch++;
  if (change.status === 'loading' || change.url) documents.delete(id);
  const pending = returns.get(id);
  if (pending && (change.discarded === false || change.status === 'loading') && pending.start === null) pending.start = Date.now();
  if (pending && pending.start !== null && change.status === 'complete') {
    send({type:'tab-return',tab:id,request:pending.request,load_observed_ms:Date.now()-pending.start}); returns.delete(id);
  }
});
api.tabs.onRemoved.addListener(id => { tabEpoch++; documents.delete(id); returns.delete(id); });
api.tabs.onActivated.addListener(() => { tabEpoch++; if(port) void snapshot(); });
