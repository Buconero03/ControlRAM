import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';

test('actual popup refreshes an open window, reports failure and ignores late replies',async()=>{
  const code=await readFile(new URL('../browser/chrome/popup.js',import.meta.url),'utf8');
  const elements=new Map(), requests=[], intervals=[], timeouts=new Map();let next=0;
  function element(id){if(!elements.has(id))elements.set(id,{textContent:'',dataset:{},disabled:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;}});return elements.get(id);}
  const context=vm.createContext({document:{getElementById:element},window:{addEventListener(){}},
    chrome:{runtime:{sendMessage:message=>new Promise((resolve,reject)=>requests.push({message,resolve,reject}))}},
    setInterval:fn=>{intervals.push(fn);return intervals.length;},clearInterval(){},
    setTimeout:fn=>{const id=++next;timeouts.set(id,fn);return id;},clearTimeout:id=>timeouts.delete(id),Date,Promise,Error});
  const flush=async()=>{await new Promise(resolve=>setImmediate(resolve));};
  vm.runInContext(code,context);
  requests.shift().resolve({phase:'syncing',connected:false,status:'Attendo elenco',logs:[]});await flush();
  assert.equal(element('status').textContent,'ATTENDO LE SCHEDE — Attendo elenco');
  intervals[0]();requests.shift().resolve({phase:'connected',connected:true,status:'Elenco confermato',lastAck:Date.now(),logs:[]});await flush();
  assert.equal(element('status').textContent,'COLLEGATO — Elenco confermato');assert.equal(element('connect').disabled,true);
  intervals[0]();const old=requests.shift();
  element('disconnect').listeners.click();requests.shift().resolve({phase:'disconnected',connected:false,status:'Scollegato',logs:[]});await flush();
  old.resolve({phase:'connected',connected:true,status:'Risposta vecchia',logs:[]});await flush();
  assert.equal(element('status').textContent,'NON COLLEGATO — Scollegato');
  intervals[0]();requests.shift().resolve({phase:'error',autoReconnect:true,status:'AME chiuso',logs:[]});await flush();
  assert.equal(element('disconnect').disabled,false,'Retrying background must remain stoppable');
  assert.match(element('background').textContent,/Collegamento in background attivo/);
  element('connect').listeners.click();assert.match(element('status').textContent,/Collega premuto/);assert.match(element('log').textContent,/Richiesta di collegamento/);
  requests.shift().resolve({phase:'connecting',autoReconnect:true,status:'Attendo AME',logs:[]});await flush();
  intervals[0]();requests.shift().reject(new Error('worker terminated'));await flush();
  assert.match(element('status').textContent,/worker terminated/);assert.equal(element('connect').disabled,false);
  intervals[0]();const hung=requests.shift();for(const fn of [...timeouts.values()])fn();await flush();
  assert.match(element('status').textContent,/5 secondi/);assert.equal(element('connect').disabled,false);
  hung.resolve({phase:'connected',status:'too late'});await flush();
  assert.match(element('status').textContent,/5 secondi/);
});
