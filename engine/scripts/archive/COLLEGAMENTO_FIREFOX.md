# AME R19 — Firefox 0.5.0

## Installazione di prova

1. Scollega le estensioni AME, chiudi il pannello, copia i file aggiornati nella cartella AME esistente conservando build/reports/exports.
2. Apri AVVIA.cmd. R19 ricompila/verifica il collegamento nativo e il lettore delle misure; la prima apertura puo richiedere piu tempo.
3. In Rilascio nelle app premi Prepara collegamento browser, se compare, oppure Ripara collegamento. Il componente Windows viene registrato per Chrome e Firefox nella cartella corrente.
4. Premi Cartella Firefox: il percorso di browser/firefox/manifest.json viene copiato negli appunti e il file evidenziato in Esplora file.
5. In Firefox 140 o successivo apri about:debugging#/runtime/this-firefox > Carica componente aggiuntivo temporaneo. Seleziona quel manifest.json.
6. Apri l'icona AME nella barra Firefox e premi Collega ad AME. Nel popup compare il clic, poi l'attesa della conferma. Nel pannello deve comparire Firefox: COLLEGATO, con il numero di schede ricevute.

La registrazione Windows pronta indica soltanto che Firefox puo trovare il componente. Il collegamento e pronto dopo hello/welcome/elenco/conferma. Chrome e Firefox possono essere collegati insieme. Selezionando una scheda Firefox, la RAM misurata e quella di tutti i processi Firefox della sessione desktop; Chrome viene misurato separatamente. I MB della singola scheda non sono noti.

## Uso e background

Con Firefox aperto puoi chiudere il popup. L'estensione mantiene il collegamento e riprova ogni circa 30 secondi se AME viene chiuso e riaperto. Scollega interrompe i tentativi. Il collegamento non esegue scaricamenti automatici: scegli e conferma una scheda nel pannello.

Questa distribuzione non e firmata da Mozilla. L'installazione temporanea viene rimossa al riavvio di Firefox: va ricaricata. Per renderla permanente servira una versione firmata, che non viene promessa come gia disponibile.

## Risultati e diagnosi

COLLEGATO non significa RAM ridotta. SCARICAMENTO SCHEDA CONFERMATO attesta lo stato discarded della scheda dopo tabs.discard. Le misure successive mostrano la variazione aggregata e il risultato a cinque minuti, oppure il ritorno della scheda/la misura incompleta. I processi possono restare attivi. Il loro numero non dimostra un beneficio e nessun processo viene nascosto.

Esporta diagnosi produce ZIP con LEGGIMI.txt e RIEPILOGO.json. Il riepilogo distingue le prove native sui processi dagli scaricamenti confermati dal browser e contiene gli esiti di durata. Scarica diagnosi collegamento nel popup produce AME-collegamento-Firefox.json, utile quando non si raggiunge il componente Windows.

## Differenze nel codice

- Manifest Firefox: background.scripts con moduli, ID gecko ame@advancedmemoryengine.local.
- Manifest nativo: allowed_extensions, registro HKCU Software\Mozilla\NativeMessagingHosts nelle viste 32/64 bit.
- Host: Firefox passa percorso del manifest e ID. Sono accettati soltanto il manifest nella cartella del binario corrente e l'ID AME; Chrome conserva il controllo del proprio origin.
- tabs.discard in Firefox risolve senza un oggetto risultato. AME non scambia questa differenza per un errore: legge nuovamente la scheda e richiede discarded=true.
- autoDiscardable mancante in Firefox usa il default documentato, ma false esplicito rimane escluso. Chrome continua a richiedere true. Restano esclusi pagine attive, fissate, con audio, private, in caricamento, siti protetti e richieste senza conferma/sessione/revisione valide.
- BrowserBridge riceve i messaggi del solo eseguibile nativo previsto. Il pannello associa il browser all'ID dell'estensione, rifiuta dichiarazioni incoerenti e conserva Browser nella selezione e negli esiti. Le misure con scope Chrome/Firefox diverso non vengono confrontate.

Riferimenti: [Native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging), [Background](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/manifest.json/background), [tabs.discard](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/discard), [Installazione temporanea](https://extensionworkshop.com/documentation/develop/temporary-installation-in-firefox/).

Le prove locali e i limiti di validazione sono in VALIDATION.md. Il collegamento reale Windows/Firefox deve ancora essere verificato sul PC.


## Automatico R21

Avvia **AUTOMATICO.cmd** invece del pannello manuale. Premi **Collega** nell'estensione 0.5.0 e usa **Autorizza automatico sul sito corrente** per i soli siti ricaricabili. Poi puoi chiudere il popup: l'agente valuta le schede autorizzate e mantiene lo storico. Guida completa: [AUTOMATICO.md](AUTOMATICO.md). Il caricamento temporaneo di Firefox va ripetuto dopo un riavvio del browser.
