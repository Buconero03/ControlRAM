export const defaultProtected = ['chatgpt.com','claude.ai','docs.google.com','drive.google.com','mail.google.com','outlook.live.com','outlook.office.com','teams.microsoft.com','meet.google.com'];
export function blocked(tab, protectedHosts = defaultProtected, browserName = 'Chrome') {
  if (!Number.isSafeInteger(tab.id) || tab.id < 0) return 'Scheda non identificabile';
  if (tab.active) return 'Scheda attiva nella sua finestra';
  if (tab.pinned) return 'Scheda fissata';
  if (tab.audible) return 'Audio recente';
  if (tab.incognito) return 'Navigazione privata';
  if (tab.discarded) return 'Gia scaricata dalla memoria';
  if (tab.autoDiscardable === false || (browserName !== 'Firefox' && tab.autoDiscardable !== true)) return 'Scaricamento automatico non autorizzato dal browser';
  if (tab.status !== 'complete') return 'Pagina in caricamento';
  let url;
  try { url = new URL(tab.url); } catch { return 'Pagina non identificabile'; }
  if (!['https:', 'http:'].includes(url.protocol)) return 'Pagina interna o non supportata';
  if (protectedHosts.some(host => url.hostname === host || url.hostname.endsWith('.' + host))) return 'Sito protetto';
  return '';
}
export function validateRequest(message, session, now) {
  if (!message || message.type !== 'discard' || message.session !== session) return 'Sessione non valida';
  if (typeof message.request !== 'string' || !/^[a-f0-9-]{36}$/.test(message.request)) return 'Richiesta non valida';
  if (!Number.isSafeInteger(message.tab) || typeof message.revision !== 'string') return 'Scheda non valida';
  if (!Number.isFinite(message.deadline) || message.deadline < now || message.deadline > now + 10000) return 'Richiesta scaduta';
  if (message.authorization === 'site_policy_v1') {
    if (message.confirmed !== false) return 'Autorizzazione automatica incoerente';
  } else if (message.authorization !== undefined || message.confirmed !== true) return 'Manca la conferma manuale';
  return '';
}
export function automaticBlocked(tab, allowedHosts, now, browserName='Chrome') {
  const protection=blocked(tab,defaultProtected,browserName);if(protection)return protection;
  let url;try{url=new URL(tab.url);}catch{return 'Pagina non identificabile';}
  if(url.protocol!=='https:')return 'Automatico disponibile solo su siti HTTPS autorizzati';
  if(!Array.isArray(allowedHosts) || !allowedHosts.includes(url.hostname))return 'Sito non autorizzato per interventi automatici';
  if(!Number.isFinite(tab.lastAccessed) || tab.lastAccessed<=0 || !Number.isFinite(now) || now-tab.lastAccessed<15*60*1000)return 'Scheda non inattiva da almeno 15 minuti o dato mancante';
  return '';
}
