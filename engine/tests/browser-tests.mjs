import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { blocked } from '../browser/chrome/policy.js';

const event = () => {
  const listeners=[];
  return {addListener(fn){listeners.push(fn);},emit(...args){return listeners.map(fn=>fn(...args));}};
};
let number=0;
async function fixture({acknowledge=true,localStore={},automatic=false,dormant=false,firefox=false}={}) {
  const manifest=JSON.parse(await readFile(new URL('../browser/chrome/manifest.json',import.meta.url)));
  const config=JSON.parse(await readFile(new URL('../browser/config.json',import.meta.url)));
  assert.equal(manifest.permissions.includes('debugger'),false);
  const id=firefox?config.firefox_extension_id:config.extension_id;
  const sent=[];const sessionStore={};const alarms=new Map();
  let currentPort;const newPort=()=>currentPort={onMessage:event(),onDisconnect:event(),postMessage(m){sent.push(structuredClone(m));},disconnect(){}};
  const tab={id:42,url:'https://example.org/article',title:'Pagina statica',active:false,pinned:false,audible:false,incognito:false,discarded:false,autoDiscardable:true,status:'complete'};
  let discards=0, mutateGet=null, confirm=true;
  globalThis.chrome={runtime:{id,onMessage:event(),onStartup:event(),onInstalled:event(),getURL:p=>(firefox?'moz-extension://test-firefox/':'chrome-extension://'+id+'/')+p,connectNative:newPort},
    alarms:{onAlarm:event(),create:async(name,info)=>alarms.set(name,info),clear:async name=>alarms.delete(name)},
    storage:{session:{get:async()=>structuredClone(sessionStore),set:async d=>Object.assign(sessionStore,structuredClone(d))},local:{get:async()=>structuredClone(localStore),set:async d=>Object.assign(localStore,structuredClone(d))}},tabs:{
      query:async()=>[structuredClone(tab)],
      get:async()=>{if(mutateGet)mutateGet(tab);return structuredClone(tab);},
      discard:async()=>{discards++; if(confirm)tab.discarded=true; return firefox?undefined:structuredClone(tab);},
      onUpdated:event(),onRemoved:event(),onActivated:event()}};
  globalThis.browser=firefox?globalThis.chrome:undefined;
  if(firefox) delete tab.autoDiscardable;
  await import('../browser/'+(firefox?'firefox':'chrome')+'/background.js?test='+number++);
  const control=type=>new Promise(resolve=>chrome.runtime.onMessage.emit({type},{id,url:chrome.runtime.getURL('popup.html')},resolve));
  if(dormant){await control('status');return {sent,control,until,localStore,alarms,get currentPort(){return currentPort;}};}
  if(automatic) await until(()=>sent.some(m=>m.type==='hello'));
  else await control('connect');
  const port=currentPort;const session=sent.find(m=>m.type==='hello').session;
  port.onMessage.emit({type:'welcome',protocol:4,session});
  async function until(predicate) {
    for(let i=0;i<100;i++){if(predicate())return;await new Promise(resolve=>setImmediate(resolve));}
    assert.fail('Evento atteso non ricevuto');
  }
  await until(()=>sent.some(m=>m.type==='snapshot'));
  const snapshot=sent.find(m=>m.type==='snapshot');
  if(acknowledge) port.onMessage.emit({type:'inventory_ack',protocol:4,session,sequence:snapshot.sequence,count:snapshot.tabs.length});
  return {tab,sent,port,session,control,until,snapshot,sessionStore,localStore,alarms,get currentPort(){return currentPort;},
    request:()=>({type:'discard',session,request:randomUUID(),tab:42,revision:snapshot.tabs[0].revision,deadline:Date.now()+8000,confirmed:true}),
    setGet(fn){mutateGet=fn;},setConfirm(v){confirm=v;},get discards(){return discards;}};
}
test('protected states and sites are excluded',()=>{
  const base={id:1,url:'https://example.org',active:false,pinned:false,audible:false,incognito:false,discarded:false,autoDiscardable:true,status:'complete'};
  assert.equal(blocked(base),'');
  for(const changes of [{active:true},{pinned:true},{audible:true},{incognito:true},{discarded:true},{autoDiscardable:false},{autoDiscardable:undefined},{status:'loading'},{url:'chrome://settings'},{url:'https://docs.google.com/document/1'},{url:'https://sub.chatgpt.com'}]) assert.ok(blocked({...base,...changes}));
});
test('manual command confirms discarded state and detects page return',async()=>{
  const f=await fixture();
  try {
    const m=f.request();f.port.onMessage.emit(m);
    await f.until(()=>f.sent.some(e=>e.type==='result'));
    assert.equal(f.discards,1);assert.equal(f.sent.find(e=>e.type==='result').outcome,'discarded');
    chrome.tabs.onUpdated.emit(42,{discarded:false,status:'loading'});
    chrome.tabs.onUpdated.emit(42,{status:'complete'});
    const result=f.sent.find(e=>e.type==='tab-return');assert.equal(result.request,m.request);assert.ok(result.load_observed_ms>=0);
  } finally {await f.control('disconnect');}
});
for(const [name,modify] of [
  ['activation before action', f=>f.setGet(t=>{t.active=true;})],
  ['navigation before action', f=>f.setGet(t=>{t.url='https://example.org/other';})],
  ['page load before action',f=>chrome.tabs.onUpdated.emit(42,{status:'loading'})],
  ['browser does not confirm discard',f=>f.setConfirm(false)]
]) test(name+' is declined',async()=>{
  const f=await fixture();try{
    modify(f);f.port.onMessage.emit(f.request());await f.until(()=>f.sent.some(e=>e.type==='result'));
    assert.equal(f.sent.find(e=>e.type==='result').outcome,'declined');
    if(name!=='browser does not confirm discard')assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});
test('expired, wrong session and unconfirmed requests do not mutate',async()=>{
  const f=await fixture();try{
    for(const edit of [{deadline:Date.now()-1},{session:randomUUID()},{confirmed:false}]){
      const m={...f.request(),...edit};f.port.onMessage.emit(m);
      await f.until(()=>f.sent.some(e=>e.type==='result'&&e.request===m.request));
    }
    assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});
test('same request cannot repeat discard',async()=>{
  const f=await fixture();try{
    const m=f.request();f.port.onMessage.emit(m);await f.until(()=>f.sent.some(e=>e.type==='result'));
    f.port.onMessage.emit(m);await f.until(()=>f.sent.filter(e=>e.type==='result').length===2);
    assert.equal(f.discards,1);assert.match(f.sent.filter(e=>e.type==='result')[1].reason,/gia elaborata/);
  }finally{await f.control('disconnect');}
});
test('disconnect while obtaining tab blocks the pending action',async()=>{
  const f=await fixture();try{
    f.setGet(()=>f.control('disconnect'));f.port.onMessage.emit(f.request());
    await new Promise(resolve=>setImmediate(resolve));assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});
test('web page sender cannot connect the native host',async()=>{
  const f=await fixture();try{
    f.control('disconnect');const previous=f.sent.length;
    chrome.runtime.onMessage.emit({type:'connect'},{id:chrome.runtime.id,tab:{id:42},url:'https://example.org'},()=>{});
    assert.equal(f.sent.length,previous);
  }finally{await f.control('disconnect');}
});

test('hello alone is not a connected state; exact rendered inventory acknowledgement is required',async()=>{
  const f=await fixture({acknowledge:false});try{
    let s=await f.control('status');assert.equal(s.connected,false);assert.equal(s.phase,'syncing');
    f.port.onMessage.emit({type:'inventory_ack',protocol:4,session:f.session,sequence:f.snapshot.sequence,count:f.snapshot.tabs.length});
    s=await f.control('status');assert.equal(s.connected,true);assert.ok(s.lastAck);assert.ok(s.logs.some(e=>e.code==='inventory_confirmed'));
  }finally{await f.control('disconnect');}
});
test('missing inventory acknowledgement expires visibly and never discards',async()=>{
  const f=await fixture({acknowledge:false}), originalNow=Date.now;try{
    Date.now=()=>originalNow()+16000;
    const s=await f.control('status');assert.equal(s.connected,false);assert.equal(s.phase,'error');assert.match(s.lastError,/15 secondi/);
    f.port.onMessage.emit(f.request());assert.equal(f.discards,0);assert.ok(s.logs.some(e=>['inventory_timeout','initial_inventory_timeout'].includes(e.code)));
  }finally{Date.now=originalNow;await f.control('disconnect');}
});
test('connected state expires without fresh acknowledgements',async()=>{
  const f=await fixture(),originalNow=Date.now;try{
    Date.now=()=>originalNow()+31000;const s=await f.control('status');assert.equal(s.connected,false);assert.equal(s.phase,'error');assert.ok(s.logs.some(e=>e.code==='health_timeout'));
  }finally{Date.now=originalNow;await f.control('disconnect');}
});
test('wrong sequence, count or protocol cannot confirm connection',async()=>{
  for(const edit of [{sequence:999},{count:999},{protocol:3}]){
    const f=await fixture({acknowledge:false});try{
      f.port.onMessage.emit({type:'inventory_ack',protocol:4,session:f.session,sequence:f.snapshot.sequence,count:1,...edit});
      const s=await f.control('status');assert.equal(s.connected,false);assert.equal(s.phase,'error');assert.ok(s.logs.some(e=>e.code==='invalid_inventory_ack'));
    }finally{await f.control('disconnect');}
  }
});
test('hub rejection and native error are retained with reasons',async()=>{
  const f=await fixture();try{
    f.port.onMessage.emit({type:'connection_error',session:f.session,code:'message_rejected',reason:'Scheda non valida'});
    let s=await f.control('status');assert.match(s.lastError,/Scheda non valida/);assert.equal(s.connected,false);
    await f.control('connect');chrome.runtime.lastError={message:'Specified native messaging host not found.'};f.currentPort.onDisconnect.emit();delete chrome.runtime.lastError;
    s=await f.control('status');assert.match(s.lastError,/host not found/);assert.ok(s.logs.some(e=>e.code==='message_rejected'));
  }finally{await f.control('disconnect');}
});
test('query failures become actionable connection errors',async()=>{
  const f=await fixture();try{
    chrome.tabs.query=async()=>{throw new Error('query failed');};f.port.onMessage.emit({type:'refresh',session:f.session});
    await new Promise(resolve=>setImmediate(resolve));const s=await f.control('status');assert.equal(s.connected,false);assert.match(s.lastError,/query failed/);
  }finally{await f.control('disconnect');}
});
test('rapid reconnect ignores messages from the previous session',async()=>{
  const f=await fixture();try{
    const old=f.session;await f.control('disconnect');await f.control('connect');
    f.port.onMessage.emit({type:'inventory_ack',protocol:4,session:old,sequence:1,count:1});
    const s=await f.control('status');assert.equal(s.phase,'connecting');assert.equal(s.connected,false);
  }finally{await f.control('disconnect');}
});
test('connection journal is bounded and contains no tab titles or URLs',async()=>{
  const f=await fixture();try{
    for(let i=0;i<60;i++){await f.control('disconnect');await f.control('connect');}
    const s=await f.control('status');assert.ok(s.logs.length<=100);const log=JSON.stringify(s.logs);assert.ok(!log.includes('example.org'));assert.ok(!log.includes('Pagina statica'));
  }finally{await f.control('disconnect');}
});

test('hanging initial tab query times out instead of waiting forever',async()=>{
  const f=await fixture(),originalNow=Date.now;try{
    await f.control('disconnect');chrome.tabs.query=()=>new Promise(()=>{});await f.control('connect');
    const session=f.sent.filter(e=>e.type==='hello').at(-1).session;
    f.currentPort.onMessage.emit({type:'welcome',protocol:4,session});
    await new Promise(resolve=>setImmediate(resolve));
    Date.now=()=>originalNow()+16000;
    const s=await f.control('status');assert.equal(s.connected,false);assert.ok(s.logs.some(e=>e.code==='initial_inventory_timeout'));assert.equal(s.inventoryStage,'querying_tabs');
  }finally{Date.now=originalNow;await f.control('disconnect');}
});
test('a stopped connection cannot publish a late query into a new session',async()=>{
  const f=await fixture();try{
    let finishQuery;chrome.tabs.query=()=>new Promise(resolve=>{finishQuery=resolve;});
    f.port.onMessage.emit({type:'refresh',session:f.session});await new Promise(resolve=>setImmediate(resolve));
    await f.control('disconnect');await f.control('connect');
    const before=f.sent.length;finishQuery([f.tab]);await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.sent.length,before);assert.equal((await f.control('status')).phase,'connecting');
  }finally{await f.control('disconnect');}
});

test('background opt-in reconnects without a popup and without memory actions',async()=>{
  const f=await fixture();const originalNow=Date.now;
  try{
    assert.equal(f.localStore.connectionEnabled,true);
    assert.equal(f.alarms.get('ame-reconnect').periodInMinutes,0.5);
    f.port.onDisconnect.emit();
    chrome.alarms.onAlarm.emit({name:'ame-reconnect'});
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.sent.filter(m=>m.type==='hello').length,1,'retry cooldown must hold');
    Date.now=()=>originalNow()+31000;
    chrome.alarms.onAlarm.emit({name:'ame-reconnect'});
    await f.until(()=>f.sent.filter(m=>m.type==='hello').length===2);
    const hello=f.sent.filter(m=>m.type==='hello').at(-1);
    assert.equal(hello.connectionReason,'background');assert.notEqual(hello.session,f.session);
    const next=f.currentPort;
    next.onMessage.emit({type:'welcome',protocol:4,session:hello.session});
    await f.until(()=>f.sent.some(m=>m.type==='snapshot'&&m.session===hello.session));
    const snapshot=f.sent.filter(m=>m.type==='snapshot').at(-1);
    next.onMessage.emit({type:'inventory_ack',protocol:4,session:hello.session,sequence:snapshot.sequence,count:snapshot.tabs.length});
    assert.equal((await f.control('status')).connected,true);
    chrome.alarms.onAlarm.emit({name:'ame-reconnect'});chrome.runtime.onStartup.emit();
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.sent.filter(m=>m.type==='hello').length,2,'no duplicate ports');
    assert.equal(f.discards,0);
  }finally{Date.now=originalNow;await f.control('disconnect');}
});
test('worker restart restores opt-in without opening popup',async()=>{
  const localStore={connectionEnabled:true,connectionNextAttempt:0};
  const f=await fixture({localStore,automatic:true});
  try{assert.equal(f.sent[0].connectionReason,'background');assert.equal((await f.control('status')).connected,true);assert.equal(f.discards,0);}
  finally{await f.control('disconnect');}
});
test('explicit disconnect cancels pending background retries and persists opt-out',async()=>{
  const f=await fixture();
  try{
    f.port.onDisconnect.emit();await f.control('disconnect');
    assert.equal(f.localStore.connectionEnabled,false);assert.equal(f.alarms.size,0);
    chrome.alarms.onAlarm.emit({name:'ame-reconnect'});chrome.runtime.onStartup.emit();chrome.runtime.onInstalled.emit();
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.sent.filter(m=>m.type==='hello').length,1);
    const s=await f.control('status');assert.equal(s.autoReconnect,false);assert.equal(s.phase,'disconnected');
  }finally{await f.control('disconnect');}
});
test('hub disconnect disables background only for the current session',async()=>{
  const f=await fixture();try{
    f.port.onMessage.emit({type:'stop_connection',protocol:4,session:randomUUID()});
    await new Promise(resolve=>setImmediate(resolve));assert.equal(f.localStore.connectionEnabled,true);
    f.port.onMessage.emit({type:'stop_connection',protocol:4,session:f.session});
    await f.until(()=>f.localStore.connectionEnabled===false);
    assert.equal(f.alarms.size,0);assert.equal((await f.control('status')).connected,false);assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});
test('manual disconnect wins over an in-flight reconnect storage write',async()=>{
  const f=await fixture();const now=Date.now;let release;
  try{
    f.port.onDisconnect.emit();Date.now=()=>now()+31000;
    const originalSet=chrome.storage.local.set;
    chrome.storage.local.set=async value=>{
      if(value.connectionNextAttempt>0) await new Promise(resolve=>{release=resolve;});
      return originalSet(value);
    };
    chrome.alarms.onAlarm.emit({name:'ame-reconnect'});await f.until(()=>release);
    const stopped=f.control('disconnect');release();await stopped;
    assert.equal(f.localStore.connectionEnabled,false);assert.equal((await f.control('status')).phase,'disconnected');
    assert.equal(f.alarms.size,0);assert.equal(f.discards,0);
  }finally{Date.now=now;await f.control('disconnect');}
});
test('failed preference storage is visible and does not spawn a reconnect host',async()=>{
  const f=await fixture();try{
    await f.control('disconnect');
    chrome.storage.local.set=async()=>{throw new Error('storage denied');};
    const s=await f.control('connect');assert.match(s.status,/storage denied/);
    assert.equal(s.connected,false);assert.equal(f.sent.filter(m=>m.type==='hello').length,1);
  }finally{chrome.storage.local.set=async()=>{};await f.control('disconnect');}
});

test('fresh worker stays disconnected after opt-out without opening the popup',async()=>{
  const f=await fixture({localStore:{connectionEnabled:false},dormant:true});
  try{
    chrome.runtime.onStartup.emit();chrome.runtime.onInstalled.emit();chrome.alarms.onAlarm.emit({name:'ame-reconnect'});
    await new Promise(resolve=>setImmediate(resolve));assert.equal(f.sent.length,0);assert.equal(f.alarms.size,0);
    assert.equal((await f.control('status')).autoReconnect,false);
  }finally{await f.control('disconnect');}
});
test('worker restart honors persisted retry cooldown then reconnects on alarm',async()=>{
  const originalNow=Date.now;
  const f=await fixture({localStore:{connectionEnabled:true,connectionNextAttempt:Date.now()+25000},dormant:true});
  try{
    assert.equal(f.sent.length,0);assert.equal(f.alarms.size,1);
    Date.now=()=>originalNow()+31000;chrome.alarms.onAlarm.emit({name:'ame-reconnect'});
    await f.until(()=>f.sent.some(m=>m.type==='hello'));assert.equal(f.sent[0].connectionReason,'background');
  }finally{Date.now=originalNow;await f.control('disconnect');}
});

test('Firefox uses its own identity and confirms a void-returning discard by actual tab state',async()=>{
  const f=await fixture({firefox:true});try{
    const hello=f.sent.find(m=>m.type==='hello');assert.equal(hello.browser,'Firefox');assert.equal(hello.extension,'ame@advancedmemoryengine.local');
    assert.equal(f.snapshot.tabs[0].blocked,'');assert.equal((await f.control('status')).browser,'Firefox');
    f.port.onMessage.emit(f.request());await f.until(()=>f.sent.some(e=>e.type==='result'));
    assert.equal(f.discards,1);assert.equal(f.sent.find(e=>e.type==='result').outcome,'discarded');
  }finally{await f.control('disconnect');}
});
test('Firefox declines active, protected or unconfirmed tab state without inventing a successful discard',async()=>{
  for(const mode of ['active','protected','not_discarded']){
    const f=await fixture({firefox:true});try{
      if(mode==='active')f.setGet(t=>{t.active=true;});
      if(mode==='protected')f.setGet(t=>{t.url='https://docs.google.com/document';});
      if(mode==='not_discarded')f.setConfirm(false);
      f.port.onMessage.emit(f.request());await f.until(()=>f.sent.some(e=>e.type==='result'));
      assert.equal(f.sent.find(e=>e.type==='result').outcome,'declined');
      assert.equal(f.discards,mode==='not_discarded'?1:0);
    }finally{await f.control('disconnect');}
  }
});
test('Firefox background remains connected with no popup and records native port errors',async()=>{
  const f=await fixture({firefox:true,automatic:true,localStore:{connectionEnabled:true}});try{
    assert.equal((await f.control('status')).connected,true);assert.equal(f.discards,0);
    f.port.error={message:'Firefox host unavailable'};f.port.onDisconnect.emit();
    const s=await f.control('status');assert.equal(s.connected,false);assert.match(s.lastError,/Firefox host unavailable/);
    assert.equal(s.autoReconnect,true);
  }finally{await f.control('disconnect');}
});
test('Firefox and Chrome packages share logic but declare the correct browser background and IDs',async()=>{
  const firefox=JSON.parse(await readFile(new URL('../browser/firefox/manifest.json',import.meta.url)));
  const chrome=JSON.parse(await readFile(new URL('../browser/chrome/manifest.json',import.meta.url)));
  assert.equal(firefox.browser_specific_settings.gecko.id,'ame@advancedmemoryengine.local');
  assert.deepEqual(firefox.background,{scripts:['background.js'],type:'module'});assert.equal(firefox.background.service_worker,undefined);
  assert.equal(chrome.background.service_worker,'background.js');assert.equal(chrome.key.length>0,true);
  for(const file of ['background.js','policy.js','popup.js'])assert.equal(await readFile(new URL('../browser/firefox/'+file,import.meta.url),'utf8'),await readFile(new URL('../browser/chrome/'+file,import.meta.url),'utf8'));
});

test('inventory diagnosis records read, send and exact acknowledgement as distinct stages',async()=>{
  const f=await fixture({acknowledge:false});try{
    let s=await f.control('status');assert.equal(s.inventoryStage,'awaiting_ack');assert.equal(s.connected,false);
    for(const code of ['inventory_start','inventory_query','inventory_read','inventory_sent'])assert.ok(s.logs.some(e=>e.code===code));
    f.port.onMessage.emit({type:'inventory_ack',protocol:4,session:f.session,sequence:f.snapshot.sequence,count:f.snapshot.tabs.length});
    s=await f.control('status');assert.equal(s.inventoryStage,'confirmed');assert.equal(s.connected,true);assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});

for(const firefox of [false,true])test((firefox?'Firefox':'Chrome')+' automatic release requires persisted exact-site permission and old inactive tab',async()=>{
  const f=await fixture({firefox,localStore:{automaticHosts:['example.org']}});try{
    f.tab.lastAccessed=Date.now()-16*60000;
    const m={...f.request(),confirmed:false,authorization:'site_policy_v1'};
    f.port.onMessage.emit(m);await f.until(()=>f.sent.some(e=>e.type==='result'));
    assert.equal(f.discards,1);assert.equal(f.sent.find(e=>e.type==='result').outcome,'discarded');
    assert.equal((await f.control('status')).automaticHostCount,1);
  }finally{await f.control('disconnect');}
});
for(const [name,change] of [
  ['missing permission',f=>{f.localStore.automaticHosts=[];}],
  ['subdomain not authorized',f=>{f.localStore.automaticHosts=['org'];}],
  ['recent activity',f=>{f.tab.lastAccessed=Date.now()-60000;}],
  ['unknown inactivity',f=>{delete f.tab.lastAccessed;}],
  ['active tab',f=>{f.tab.active=true;}],
  ['permission revoked during lookup',f=>f.setGet(()=>{f.localStore.automaticHosts=[];})],
  ['automatic command pretending manual confirmation',()=>{}]
])test('automatic release declines '+name,async()=>{
  const f=await fixture({localStore:{automaticHosts:['example.org']}});try{
    f.tab.lastAccessed=Date.now()-16*60000;change(f);
    f.port.onMessage.emit({...f.request(),confirmed:name==='automatic command pretending manual confirmation',authorization:'site_policy_v1'});
    await f.until(()=>f.sent.some(e=>e.type==='result'));assert.equal(f.discards,0);assert.equal(f.sent.find(e=>e.type==='result').outcome,'declined');
  }finally{await f.control('disconnect');}
});
test('popup site authorization persists and can be revoked without allowing protected sites',async()=>{
  const f=await fixture();try{
    let s=await f.control('allow-automatic-current');assert.match(s.notice,/autorizzato/);assert.deepEqual(f.localStore.automaticHosts,['example.org']);
    s=await f.control('revoke-automatic-current');assert.equal(s.automaticHostCount,0);assert.deepEqual(f.localStore.automaticHosts,[]);
    f.tab.url='https://chatgpt.com/';s=await f.control('allow-automatic-current');assert.match(s.notice,/protetto/);assert.deepEqual(f.localStore.automaticHosts,[]);
  }finally{await f.control('disconnect');}
});
test('automatic agent welcome reports background analysis rather than manual selection',async()=>{
  const f=await fixture({acknowledge:false});try{
    // Fresh connection, previous session must not affect this one.
    await f.control('disconnect');await f.control('connect');const port=f.currentPort;
    const hello=f.sent.filter(m=>m.type==='hello').at(-1);
    port.onMessage.emit({type:'welcome',protocol:4,session:hello.session,agent_mode:'automatic_authorized_sites'});
    await f.until(()=>f.sent.filter(m=>m.type==='snapshot').length===2);
    const snap=f.sent.filter(m=>m.type==='snapshot').at(-1);
    port.onMessage.emit({type:'inventory_ack',protocol:4,session:hello.session,sequence:snap.sequence,count:snap.tabs.length});
    const s=await f.control('status');assert.equal(s.agentMode,true);assert.match(s.status,/Agente automatico attivo/);assert.equal(f.discards,0);
  }finally{await f.control('disconnect');}
});
test('large UTF8 inventories stay inside native frame bounds and report truncation',async()=>{
  const f=await fixture();try{
    const tabs=Array.from({length:300},(_,i)=>({...f.tab,id:i+1,title:'界'.repeat(160),url:'https://'+'a'.repeat(63)+'.'+'b'.repeat(63)+'.'+'c'.repeat(63)+'.example.org/'}));
    chrome.tabs.query=async()=>structuredClone(tabs);f.port.onMessage.emit({type:'refresh',session:f.session});
    await f.until(()=>f.sent.filter(m=>m.type==='snapshot').length===2);
    const snap=f.sent.filter(m=>m.type==='snapshot').at(-1);assert.ok(Buffer.byteLength(JSON.stringify(snap))<262144);assert.equal(snap.truncated,true);assert.ok(snap.tabs.length>0 && snap.tabs.length<300);
  }finally{await f.control('disconnect');}
});
test('activation while automatic permission lookup is pending invalidates the earlier tab read',async()=>{
  const f=await fixture({localStore:{automaticHosts:['example.org']}});try{
    f.tab.lastAccessed=Date.now()-16*60000;
    const get=chrome.storage.local.get;
    chrome.storage.local.get=async key=>{if(key==='automaticHosts')chrome.tabs.onActivated.emit({tabId:42});return get(key);};
    f.port.onMessage.emit({...f.request(),confirmed:false,authorization:'site_policy_v1'});
    await f.until(()=>f.sent.some(e=>e.type==='result'));assert.equal(f.discards,0);assert.equal(f.sent.find(e=>e.type==='result').outcome,'declined');
  }finally{await f.control('disconnect');}
});
