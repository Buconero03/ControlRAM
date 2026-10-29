# Collegamento AME R19 e Chrome 0.5.0

## Aggiornamento e utilizzo

1. Chiudi AME. Copia il contenuto del pacchetto nella cartella AME che usi gia, sostituendo i file e conservando build, reports ed exports.
2. Apri AVVIA.cmd. Il pannello deve indicare R19. In Processi e strategia trovi il registro Chrome sempre visibile accanto ai risultati dei processi. Rilascio nelle app mantiene il registro e i comandi completi.
3. Usa Cartella Chrome nel pannello per aprire e copiare il percorso corretto. In chrome://extensions carica quella cartella; se era gia la stessa, premi Ricarica sulla scheda AME e verifica la versione 0.5.0. Se hai cambiato cartella, carica browser/chrome della nuova installazione.
4. In AME premi Verifica collegamento. Se indica un percorso diverso o una registrazione mancante, premi Ripara collegamento. Se il componente non e stato ancora verificato, usa Prepara collegamento Chrome.
5. Nel popup AME di Chrome premi Collega ad AME. Il clic viene mostrato subito nel popup; quando la richiesta raggiunge AME compare anche nel registro Windows. Solo dopo la conferma dell’elenco vedrai Collegato e il numero di schede.

Dopo il primo Collega puoi chiudere il popup. Con Chrome aperto, la preferenza salvata permette di ritrovare AME anche dopo il riavvio del browser o del programma. Se AME e chiuso, il tentativo viene ripetuto ogni 30 secondi circa; Chrome puo ritardarlo o rinviarlo al risveglio del PC. Non vengono aperti popup. Scollega disattiva i tentativi automatici, anche nei successivi avvii; premi Collega per riattivarli.

**Se non vedi versione 0.5.0 e Registro collegamento nel popup, Chrome sta ancora usando una versione precedente.** Ricarica l’estensione e controlla che la cartella caricata sia quella aggiornata.

Il collegamento prepara la comunicazione. Per scaricare una scheda devi selezionarla nel pannello e confermare l'intervento. I risultati della memoria rimangono nel riquadro dell'intervento.

## Significato degli stati

| Stato | Significato |
| --- | --- |
| Avvio del collegamento Windows | Chrome sta aprendo il componente locale e attendendo la risposta di AME. |
| Attendo la conferma dell'elenco | AME ha risposto al saluto, ma non ha ancora confermato le schede. |
| Collegato: AME ha ricevuto N schede | AME ha validato e visualizzato l'elenco e Chrome ha ricevuto la conferma corrispondente. Anche un elenco vuoto e un esito valido. |
| Profili pronti: N | Numero di collegamenti del pannello che hanno fornito un elenco valido e recente. |
| Elenco non ricevuto / conferma mancante | Una fase non si e completata entro 15 secondi; il tentativo termina con un motivo. |
| Collegamento scaduto | Gli aggiornamenti non sono piu confermati; il background riprova se abilitato; Collega forza un nuovo tentativo. |
| Estensione precedente | Occorre ricaricare la versione 0.5.0. Pannelli o estensioni con protocollo 3 non sono compatibili con R19. |
| Registrazione rivolta a un'altra cartella | Chrome avvierebbe il componente di una vecchia installazione; Ripara collegamento aggiorna il percorso per l'utente corrente. |

La verifica della registrazione controlla i file e i riferimenti Windows. Il collegamento completo e confermato soltanto dallo scambio dell'elenco schede. Il registro resta visibile anche con zero profili, senza abilitare Mostra dettagli tecnici. Se Chrome non riesce nemmeno ad avviare il componente Windows, AME non puo ricevere il clic: il motivo e nel registro dell’estensione. Nessun errore locale viene presentato come un collegamento riuscito.

## Esportare un problema

- Nel pannello, Esporta diagnosi crea uno ZIP con registro, dettagli degli errori e riepilogo leggibile. Include gli ultimi eventi visibili anche se il normale report non era scrivibile.
- Nell'estensione, Scarica diagnosi collegamento salva AME-collegamento-Chrome.json. E utile soprattutto se Chrome non riesce ad avviare il componente Windows.
- In caso di problema persistente, invia entrambi i file. Contengono lo stato e le fasi completate; non occorre ricopiare righe dalla console.

Windows conserva il JSONL in reports/browser-*.jsonl, fino a 4 MiB per apertura del pannello. Il registro visibile contiene gli ultimi 100 eventi. L'estensione conserva fino a 100 eventi in memoria di sessione Chrome: esportali prima di ricaricare/disabilitare l'estensione o chiudere il browser. La diagnosi del collegamento non salva elenchi URL o contenuti delle pagine. I messaggi tecnici possono includere percorsi locali.

## Percorso nel codice

| File | Responsabilita |
| --- | --- |
| browser/chrome/background.js | Apre connectNative, gestisce sessione e timeout, invia snapshot numerati, accetta inventory_ack corrispondente e conserva il registro Chrome. Memorizza connectionEnabled e connectionNextAttempt in storage.local; un alarm periodico riattiva il worker per i tentativi, senza ripetere interventi RAM. |
| browser/chrome/popup.js | Aggiorna il popup ogni secondo, gestisce risposte scadute/fallite ed esporta il JSON. |
| src/browser_host.cpp | Trasporta messaggi JSON con lunghezza prefissata fra Chrome e la named pipe locale. |
| src/hub-runtime.cs / BrowserBridge | Verifica il percorso dell'host nativo e trasferisce i messaggi al thread del pannello tramite una coda. |
| browser-panel.ps1 / Poll-Browser | Valida saluto ed elenco, aggiorna la griglia, invia la conferma e rimuove le connessioni scadute. |
| browser-connection.ps1 | Mostra e salva gli stati, verifica la registrazione Windows ed esporta la diagnosi. |
| install-chrome.ps1 | Registra per l'utente corrente il manifest dell'host della cartella AME aperta. |

L'invio della conferma avviene dopo Update-BrowserGrid. Se il rendering fallisce, il catch salva il messaggio, la posizione e lo stack PowerShell, notifica l'estensione e chiude quel collegamento. Dopo una disconnessione i comandi non vengono ripetuti automaticamente.

Riferimenti del trasporto: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging) e [Chrome storage](https://developer.chrome.com/docs/extensions/reference/api/storage). Le verifiche eseguite e i limiti dell'ambiente di prova sono descritti in VALIDATION.md.

Background: [Ciclo di vita del service worker Chrome](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle) e [API alarms](https://developer.chrome.com/docs/extensions/reference/api/alarms). Minimo Chrome 121, permesso aggiuntivo alarms. Un collegamento native messaging aperto mantiene il worker; i tentativi falliti rispettano un intervallo persistente e non creano host duplicati.

Firefox ha una cartella e registrazione dedicate: vedere COLLEGAMENTO_FIREFOX.md. R19 mostra lo stato di ogni browser separatamente; le misure RAM usano il browser della selezione. Chrome 0.3.2/protocollo 4 continua a essere riconosciuto.


## Automatico R21

Avvia **AUTOMATICO.cmd** invece del pannello manuale. Premi **Collega** nell'estensione 0.5.0 e usa **Autorizza automatico sul sito corrente** per i soli siti ricaricabili. Poi puoi chiudere il popup: l'agente valuta le schede autorizzate e mantiene lo storico. Guida completa: [AUTOMATICO.md](AUTOMATICO.md). Il caricamento temporaneo di Firefox va ripetuto dopo un riavvio del browser.
