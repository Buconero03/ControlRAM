# Advanced Memory Engine 0.5 R22 — Comando API per i processi Windows

**RIDUCI_PROCESSO.cmd** permette di richiedere una prova su un processo Windows anche senza un comando interno dell'app. L'API AME avvia il controller C++ esistente, espone stato e misure e restituisce un esito distinto dalla semplice applicazione del tentativo. Guida e contratto pubblico: **[API_PROCESSI.md](API_PROCESSI.md)**.

La nuova interfaccia e `Start-AmeProcessReduction` / `Get-AmeProcessReduction` / `Stop-AmeProcessReduction` / `Close-AmeProcessReduction`, con identita lette dalla DLL nativa. Anche il pannello usa lo stesso generatore di comandi. Motore R10 e DLL ABI 1 restano invariati: il metodo continua a essere una riduzione del working set, con beneficio temporaneo da verificare, senza un rilascio universale delle cache interne.

Il comando e esplicito e richiede l'arresto del pannello/agente precedente. L'agente automatico dei browser mantiene le regole R21: questa revisione non applica automaticamente il trim a tutti i processi. Corretto anche il ripristino dello storico con date UTC gia convertite in DateTime da PowerShell, in ambienti con fuso orario diverso da UTC.

# Advanced Memory Engine 0.5 R21 — Agente automatico

**AUTOMATICO.cmd** avvia AME in background senza pannello. Osserva i processi e la pressione RAM, sceglie una scheda inattiva di un sito che hai autorizzato nell'estensione Chrome o Firefox, chiede al browser di scaricarla e verifica la memoria per cinque minuti. Il risultato e lo storico restano consultabili; non devi selezionare ogni volta un processo o copiare i log.

**Prima configurazione e comandi: [AUTOMATICO.md](AUTOMATICO.md).** Inizialmente nessun sito e autorizzato. Nell'estensione **0.5.0** premi Collega, poi Autorizza automatico sul sito corrente soltanto per pagine ricaricabili senza lavoro da conservare. Le autorizzazioni sono per dominio esatto, non per tutti i siti del browser.

L'agente analizza anche le altre applicazioni, ma il rilascio automatico integrato riguarda Chrome e Firefox. Per ChatGPT e Claude desktop non c'e ancora un comando verificato di rilascio delle cache interne. L'agente non esegue trim generici, non chiude o sospende applicazioni e non impone limiti Job Object.

**STATO_AUTOMATICO.cmd** apre la consultazione; chiuderla lascia attivo l'agente. **FERMA_AUTOMATICO.cmd** lo arresta. **ABILITA_AVVIO_WINDOWS.cmd** e facoltativo e lo avvia al prossimo accesso. **AVVIA.cmd** mantiene il pannello manuale quando l'agente e fermo; con agente attivo apre la consultazione, senza avviare un secondo controller.

Rimane disponibile il confronto osservazionale introdotto in R20: 15 minuti senza comandi AME e 15 dopo gli interventi, con costo AME incluso. Guida: **[VERIFICA_BENEFICIO.md](VERIFICA_BENEFICIO.md)**. Questo confronto manuale e distinto dalla verifica automatica di cinque minuti; nessuno dei due certifica un risparmio causale o maggiore velocita. Motore R10, API R1, runtime e bridge R19 sono riutilizzati quando validati.

La R19 corregge il trasporto nativo dopo il primo contatto. Il client della named pipe usa I/O overlapped con un evento separato per ogni operazione, per permettere lettura e scrittura contemporanee. Il collegamento Firefox della R18 resta incluso. In alto trovi due stati distinti: **Chrome: COLLEGATO / NON COLLEGATO** e **Firefox: COLLEGATO / NON COLLEGATO**. La registrazione Windows pronta non viene presentata come collegamento riuscito. **Collegato** compare nell'estensione soltanto dopo che il pannello ha ricevuto, verificato e acquisito l'elenco schede. Il popup aggiorna lo stato ogni secondo mentre resta aperto. Le attese hanno una scadenza e gli errori compaiono nel registro visibile, con diagnosi esportabile anche senza collegamento riuscito.

**R19:** il registro Chrome e sempre visibile anche in Processi e strategia, accanto agli interventi sui processi. Premi Collega una volta: la preferenza viene conservata e l’estensione mantiene o ritenta il collegamento con il popup chiuso, con Chrome aperto. Se AME non e disponibile riprova ogni 30 secondi circa; Chrome puo ritardare il tentativo. Scollega, nell’estensione o nel pannello R22, disattiva il background. Nessun intervento RAM viene avviato dal collegamento.

**Estensioni e cartelle:** copia i file nella cartella AME esistente, apri AVVIA.cmd, poi in chrome://extensions premi Ricarica sulla scheda AME. La versione dell'estensione deve essere **0.5.0** e il pannello **R22**. In Rilascio nelle app premi **Ripara collegamento** se la registrazione punta a un'altra cartella; poi nell'estensione premi **Collega ad AME**. Se usi una nuova cartella, carica browser/chrome di quella cartella al posto della vecchia estensione. Il protocollo 4 richiede entrambi i componenti aggiornati.

Le guide [COLLEGAMENTO_CHROME.md](COLLEGAMENTO_CHROME.md) e [COLLEGAMENTO_FIREFOX.md](COLLEGAMENTO_FIREFOX.md) descrivono installazione, stati e risultati. Se Chrome e gia collegato con l’estensione 0.3.2/protocollo 4, quella connessione resta compatibile; per la nuova interfaccia carica 0.5.0 dalla cartella di questa installazione. Firefox usa il proprio manifest e ID.

Il pulsante principale **Strategia RAM** valuta da 1 a 5 processi, usa gli esiti precedenti e indica un metodo supportato dall'applicazione. La nuova colonna **Metodo consigliato** rende visibile questa scelta. **Prova temporanea** rimane il tentativo sul working set: non viene eseguito implicitamente dalla strategia.

Il pannello contiene **Processi e strategia**, **Rilascio nelle app** e **Verifica beneficio**. Per Chrome e Firefox, la seconda usa tabs.discard per chiedere al browser di scaricare una scheda inattiva e sacrificabile. La scheda resta nella barra e si ricarica quando la riusi. E un rilascio del contenuto gestito dal browser; non garantisce un risparmio permanente e non offre una quantita fissa di MB.

Per gli eseguibili diversi da Chrome e Firefox viene indicato **Nessun rilascio interno integrato**. La API nativa continua a verificare le identita prima delle richieste. Non vengono creati automaticamente Job Object sulle applicazioni esistenti. Non e stata aggiunta una API universale che possa eliminare le cache interne di qualunque programma.

La strategia conserva fino a 512 esiti negli ultimi 7 giorni, distinti per percorso dell'applicazione e fonte della prova. Distingue beneficio breve/piccolo, riduzione residente osservata per 5 minuti e riduzione accompagnata da ritorno dell'app/aumento di attivita. Un esito positivo sul working set non viene presentato come minori allocazioni o maggiore velocita. Il blocco di 30 minuti sulla stessa identita dopo un esito negativo rimane attivo per le prove temporanee.

Alla prima apertura importa automaticamente fino a 5 report recover recenti gia presenti in reports: massimo 8 MiB per file e 32 MiB totali. Importa soltanto esiti finali di prove concluse, con identita/percorso corrispondenti alla selezione. Non tratta prove incomplete come positive. Lo storico e reports/strategy-history.json; le diagnosi private dell'utente non sono incluse nel pacchetto.

## Installazione e aggiornamento

Premi Scollega nelle estensioni AME e chiudi i pannelli prima dell’aggiornamento, per lasciare libero il componente nativo durante la compilazione. Estrai lo ZIP e copia il contenuto di AdvancedMemoryEngine-v0.5.0 nella cartella esistente, sostituendo i file e conservando build, reports ed exports. Apri **AVVIA.cmd**: usa la propria cartella, senza digitare percorsi. Per passare dalla R18 alla R19 serve una nuova compilazione/verifica del componente nativo. Dopo AVVIA, Prepara collegamento browser esegue otto scambi consecutivi per ciascun browser, prima di registrarlo. AVVIA la esegue una sola volta. Se la build R10, il bridge R19 e il pannello R22 sono gia validati e gli hash corrispondono, li riutilizza. Un aggiornamento del solo pannello non ricompila il motore. Una build precedente o non valida richiede Visual Studio 2022 o MinGW x64 e la verifica completa. L'API viene preparata anche da **AVVIA.cmd**, con gli stessi compilatori. Se hai gia eseguito la demo R13 con gli stessi sorgenti, la build viene riusata. Monitoraggio e prove temporanee funzionano anche senza Chrome; non serve avviare come amministratore.

## Usare il rilascio nelle app

1. Apri **AVVIA.cmd** e spunta i processi da valutare, poi premi **Strategia RAM**. Per Chrome e Firefox si apre **Rilascio nelle app**. Puoi anche aprire direttamente quella sezione.
2. Se compare **Prepara collegamento browser**, premilo per verificare il componente Windows e registrarlo. Se vedi gia la tabella, **Verifica collegamento** controlla la registrazione e **Ripara collegamento** la riallinea alla cartella corrente.
3. In Chrome apri **chrome://extensions**, abilita **Modalita sviluppatore**, premi **Carica estensione non pacchettizzata** e scegli **browser/chrome** di questa installazione. Se era gia caricata dalla stessa cartella, premi **Ricarica** e verifica la versione **0.5.0**. Apri l'estensione e premi **Collega ad AME**. Attendi **Collegato: AME ha ricevuto N schede**; nel pannello comparira **Profili pronti: 1** e l'elenco.
4. Nel pannello scegli una scheda non protetta e premi **Scarica scheda inattiva**. Conferma solo se e ricaricabile e non contiene lavoro non salvato. Schede attive, fissate, con audio, private, in caricamento e siti protetti restano esclusi. L'estensione ricontrolla lo stato e la revisione prima dell'azione.
5. Vedi subito richiesta inviata, conferma o rifiuto. Dopo la conferma, RAM privata e commit aggregati del browser scelto si aggiornano ogni circa 5 secondi per 5 minuti. Il ritorno della scheda termina la verifica e sconsiglia di scaricarla nuovamente per 30 minuti nella stessa sessione.

Per un problema di collegamento trovi il registro direttamente in **Rilascio nelle app**: premi **Esporta diagnosi** per ottenere lo ZIP, anche con zero profili. Nell'estensione **Scarica diagnosi collegamento** salva un JSON degli ultimi eventi. Se Chrome non riesce neppure ad avviare il componente Windows, il motivo disponibile appare nel registro dell'estensione. Non e necessario cercare righe nei dettagli dei processi.

Le misure riguardano **tutti i processi del browser scelto nella sessione desktop**, senza attribuzione alla singola scheda o al PID selezionato nella prima sezione. Letture parziali, cambi nel numero di processi, perdita del collegamento o campioni oltre 12 secondi interrompono la valutazione. Un numero di processi invariato non dimostra identita invariata: gli aggregati sono osservazioni contestuali, senza prova causale. La misura continua anche se l'osservatore nativo e in pausa. Non si avvia una prova temporanea mentre e in corso uno scaricamento o una misura Chrome.

## Collegare Firefox

1. In **Rilascio nelle app**, premi **Prepara collegamento browser** se necessario, oppure **Ripara collegamento**. Registra sia Chrome sia Firefox per l'utente corrente.
2. Premi **Cartella Firefox**: apre e copia il percorso del manifest della cartella aggiornata.
3. In Firefox apri **about:debugging#/runtime/this-firefox**, premi **Carica componente aggiuntivo temporaneo** e seleziona **browser/firefox/manifest.json**.
4. Apri AME nella barra Firefox e premi **Collega ad AME**. Attendi **Firefox: COLLEGATO** nel programma e l'elenco di schede Firefox.
5. Scegli una scheda ricaricabile, premi **Scarica scheda inattiva** e conferma. La misura riguarda Firefox; non include la RAM di Chrome.

Firefox richiede versione 140 o successiva. Il componente locale non e ancora firmato da Mozilla: il caricamento temporaneo dura fino alla chiusura/riavvio di Firefox e va ripetuto nella sessione successiva. Con Firefox aperto, il collegamento continua con il popup chiuso e ritrova AME riaperto. Per un'installazione permanente servira un pacchetto firmato; non si disabilitano i controlli di Firefox.

## Capire se ha ridotto la memoria

- **COLLEGATO** significa soltanto che AME e browser comunicano e hanno confermato l'elenco.
- **SCARICAMENTO SCHEDA CONFERMATO** significa che il contenuto della scheda e stato scaricato dal browser. La scheda resta nella barra e si ricarica al ritorno.
- **Misure RAM prima/dopo e a 5 minuti** indicano quanto varia la RAM del browser scelto e se il beneficio dura. I MB non vengono attribuiti alla singola scheda.
- Un processo puo rimanere aperto con meno RAM. AME non nasconde processi nell'inventario e il numero dei processi non viene usato come prova di beneficio.

La diagnosi distingue **prove sui processi applicate** da **scaricamenti schede confermati** e include gli esiti della memoria del browser. Un log di collegamento senza un intervento confermato non viene dichiarato riduzione RAM. Una riduzione osservata non garantisce maggiore velocita o risparmio permanente.

## Prima prova temporanea: un processo

1. Spunta **un processo** nella colonna Seleziona e premi **Prova temporanea**. Evidenziare una riga non equivale a spuntarla. Per questa prova scegli un'app che puoi lasciare inattiva e poi usare normalmente.
2. **Durante l'attesa lascia AME in primo piano.** L'app scelta deve raggiungere 60 secondi consecutivi di bassa attivita: CPU inferiore allo 0,1% dell'intero PC e meno di 10 page fault/s. Un'app in primo piano e la sua famiglia sono escluse dall'azione. Il conteggio parte dalla richiesta, non dall'apertura del pannello.
3. Se appare **Intervento applicato**, puoi tornare a usare l'app. AME continua a misurare la RAM, ma il ritorno dell'app o della sua famiglia in primo piano blocca altri interventi e annulla il resto della coda.
4. Attendi il risultato a **cinque minuti dall'intervento**. Non serve leggere i log: il pannello mostra la RAM ancora ridotta, il minimo mantenuto nell'ultimo minuto e l'esito. Se la RAM ritorna quasi tutta o mancano campioni validi, termina prima con la spiegazione.
5. **Ferma e pausa** interrompe anche la misura. Una prova fermata prima della valutazione finale viene indicata come incompleta.

Il comando funziona anche dalla pausa: richiede un inventario nuovo e verifica di nuovo PID, tempo di creazione e percorso. Se l'inventario non arriva entro 20 secondi o l'identita cambia, la richiesta viene rifiutata visibilmente.

Ogni richiesta concede fino a **3 minuti per diventare idonea**. Se non avviene, termina con **Nessun intervento** e il motivo. Dopo un'azione, concede 5 minuti di sola misura e al massimo 6 secondi di margine: complessivamente circa 8 minuti per processo. La soglia globale RAM dell'85% non e richiesta dal pulsante manuale. Le altre protezioni rimangono attive prima dell'azione.

## Cosa succede dopo il clic

Il riquadro sotto l'elenco mostra sempre il processo corrente (nome, PID e posizione nella coda). Un riepilogo separato mantiene visibili tutti i processi richiesti, anche se la loro riga nell'inventario e fuori dallo schermo.

- **RICHIESTA RICEVUTA / NON ANCORA AVVIATO:** nessun intervento sul processo indicato. La scritta specifica quale processo viene gestito prima.
- **NESSUN INTERVENTO ANCORA:** verifica in corso, motivo dell'attesa e secondi rimasti. Per esempio: bassa attivita 22/60 s.
- **INTERVENTO ESEGUITO:** Windows ha eseguito l'azione; segue la misura prima/dopo.
- **RAM DIMINUITA:** quantita in meno, RAM prima e RAM all'ultimo campione. Si aggiorna circa ogni due secondi durante la verifica di cinque minuti. E un risultato osservato gia disponibile, mentre la sua durata e ancora in verifica.
- **RAM RISALITA / INVARIATA:** il confronto con la misura precedente all'intervento viene mostrato con il verso corretto.
- **Annullato / Nessun intervento:** nessuna azione sul processo indicato. Quando un avviso blocca gli altri processi, le loro righe cambiano immediatamente; non rimangono in falsa attesa.
- **Misura incompleta:** l'osservazione e terminata prima della valutazione. L'ultima riduzione misurata resta visibile, senza dichiararla stabile a cinque minuti.

Se una misura manca, viene indicata come non disponibile. Il pannello non trasforma un dato mancante in zero RAM. I dettagli tecnici restano nel registro facoltativo.

## Perche a volte non interviene e sembra aspettare a lungo

La coda e seriale. Ogni processo ha fino a 3 minuti per raggiungere le condizioni; i 60 secondi di bassa attivita devono essere consecutivi e ripartono se CPU/fault superano le soglie. La R14 mostra esplicitamente quel motivo e i valori del campione. Se l'app o la sua famiglia e in primo piano, il pannello spiega di portare AME in primo piano. Ogni motore di recupero ricomincia la propria osservazione: il tempo raccolto prima in observe o su altri elementi della coda non viene trasferito.

Con tre processi non idonei, l'attesa puo arrivare a circa 9 minuti senza alcuna azione. I 5 minuti aggiuntivi servono solo dopo un intervento per verificare se la RAM risale. Questi tempi dipendono dalla policy attuale, non dalla velocita dei Job Object. Non sono stati accorciati in questa revisione; servira un motore persistente che valuti insieme le selezioni e mantenga misure fresche e continue per ridurre le attese senza fingere inattivita.

## Come leggere il risultato

- **RAM ridotta a 5 minuti:** nell'ultimo minuto tutti i campioni conservano almeno 16 MiB e piu del 20% della riduzione massima. Il pannello mostra anche quanta riduzione resta all'ultimo campione. Questo e un dato osservato, non una promessa di durata futura.
- **RAM ridotta dopo il ritorno dell'app in primo piano:** stessa verifica, ma l'app o la sua famiglia e tornata in primo piano durante l'osservazione. Gli altri interventi sono annullati. Questo segnale non dimostra quanto lavoro abbia effettivamente svolto il singolo processo.
- **RAM ridotta con aumento di attivita/fault:** la riduzione residente rimane, ma il programma non dichiara un miglioramento delle prestazioni. Nessun altro intervento nella coda.
- **RAM quasi tutta tornata:** dopo almeno cinque secondi resta al massimo il 20% della riduzione massima per almeno quattro secondi consecutivi. Un picco isolato non basta per interrompere anticipatamente.
- **Riduzione troppo piccola:** nei primi cinque secondi la riduzione massima e inferiore a 16 MiB.
- **Riduzione non mantenuta stabilmente:** a cinque minuti l'ultimo minuto non soddisfa i limiti minimi, anche se l'ultimo campione da solo sembra buono.
- **Misura incompleta:** stop, campioni mancanti o troppo distanti, tempo inverso, identita persa o altre metriche necessarie non disponibili. Non viene conteggiata come riduzione mantenuta.
- **Nessun intervento:** l'azione non e stata eseguita. Una variazione della RAM del PC durante l'attesa non prova un recupero AME.

A fine coda sono separati **Interventi applicati**, **RAM ridotta a 5 minuti** e **Misure incomplete**. Gli esiti dei singoli processi rimangono nella colonna Stato / risultato. La coda passa in pausa e viene esportata automaticamente una diagnosi unica.

## Selezione, limiti e apprendimento dagli esiti negativi

Puoi spuntare da **1 a 5 processi**: richieste seriali, a partire da quello con piu RAM privata residente. Una sola azione per identita nella coda, senza retry. Cinque richieste possono richiedere circa 40 minuti, oltre al piccolo margine dei campioni finali. Un timeout senza azione passa alla prossima identita; un esito negativo, incompleto, un errore o un avviso durante la misura annulla il resto della coda.

**Ordinamento RAM:** la lista mette in cima i processi con piu RAM privata residente. Cliccando sull'intestazione **RAM privata MiB** o spuntando/deselezionando una casella viene riordinata dal maggiore al minore; le selezioni rimangono associate a PID, tempo di creazione e percorso. La sesta casella viene rifiutata con una spiegazione. I valori non disponibili restano in fondo. Il riordino usa i byte numerici, senza aggiornare artificialmente l'eta delle misure.

Il programma verifica proprietario, sessione, identita, percorso, criticita, primo piano, memoria e attivita prima di agire. La protezione conserva l'app in primo piano, i suoi processi collegati e i processi con lo stesso eseguibile dell'app. Le console condivise (cmd, conhost, PowerShell e terminale) possono essere protette nella propria catena di processi, ma non collegano piu tutte le istanze dello stesso eseguibile tra applicazioni diverse. Questo evita che una console di Chrome estenda la protezione a Claude o ad altre app indipendenti. Sono esclusi processi Windows, controller AME, identita non verificabili, processi con meno di 128 MiB privati residenti o piu di 2 GiB di working set. La lista e le autorizzazioni originali non vengono sostituite se un PID viene riutilizzato.

Un esito negativo confermato blocca nuove richieste per **30 minuti** sulla stessa combinazione PID, tempo di creazione e percorso, anche riaprendo il pannello nella stessa cartella. Include la riduzione non mantenuta a cinque minuti. Gli esiti positivi, incompleti o senza azione non diventano esiti negativi. Lo storico e in reports/recovery-history.json, limitato a 512 record e 1 MiB; le scadenze vengono eliminate. Aggiornando conserva la cartella reports. Un file danneggiato viene conservato e blocca nuove richieste con una spiegazione; un errore di salvataggio blocca le richieste successive di quell'apertura. Lo storico non e condiviso con altre installazioni o con i comandi console diretti.

## Monitoraggio e automatico

**Pausa monitoraggio** arresta il motore; **Riprendi monitoraggio** aggiorna i dati. L'osservazione ordinaria si ferma dopo dieci minuti. **Automatico con pressione** agisce soltanto sulle identita scelte, dopo RAM >=85% per 30 secondi e bassa attivita per 60 secondi, con massimo tre interventi per sessione. Ogni azione deve completare la verifica di cinque minuti prima di permetterne un'altra. Le durate 5/15/60 minuti indicano la finestra per nuove azioni: un'osservazione gia avviata puo proseguire per completarsi, al massimo 306 secondi oltre quella finestra. Nessuna nuova azione durante l'estensione.

L'aumento della CPU o dei fault blocca ulteriori interventi ma conserva la sola misura. Il ritorno in primo piano dopo l'azione ha lo stesso comportamento; il primo piano continua invece a escludere un processo prima dell'azione. La perdita di identita/telemetria e lo stop interrompono anche la misura. I mutex impediscono due controller contemporanei nella stessa sessione Windows.

## Cosa misura e cosa non dimostra

Il metodo usa una sola chiamata EmptyWorkingSet su un processo idoneo. Riduce la residenza delle pagine, non le allocazioni richieste dall'app. Le pagine possono restare in cache o ritornare in RAM quando servono. Per ridurre il fabbisogno delle allocazioni occorre la collaborazione dell'applicazione, per esempio per rilasciare cache ricostruibili.

La RAM privata, il working set e il private commit del processo selezionato sono registrati circa ogni due secondi. I riepiloghi dopo l'azione sono immediato, 5, 15, 60, 180 e 300 secondi. Sono conservati baseline CPU/fault, picchi e segnalazioni di attivita. I page fault comprendono sia soft sia hard fault: non misurano da soli accessi al disco o rallentamenti. **La latenza dell'app non e misurata.** L'esito RAM rimasta ridotta non certifica maggiore velocita.

La RAM disponibile del PC e mostrata separatamente: altre app la possono aumentare o diminuire. Dalla R8 non determina il giudizio sulla riduzione residente del singolo processo. Queste misure non costituiscono un confronto controllato con una sessione senza AME e non stabiliscono un risparmio causale sull'intero PC.

Riferimenti: [Working set Microsoft](https://learn.microsoft.com/en-us/windows/win32/memory/working-set) e [EmptyWorkingSet](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset).

## Diagnosi e moduli facoltativi

**Mostra dettagli tecnici** rende visibili log, commit e fault; di default sono nascosti. **Esporta diagnosi** raccoglie fino ai dieci report piu recenti oppure i report della coda, con LEGGIMI.txt, RIEPILOGO.json e copie JSONL. Include il registro dei clic del pannello. Il clic accettato non equivale a un intervento applicato. Limite 128 MiB, sorgenti invariati, righe parziali omesse e problemi segnalati. Nessun invio automatico alla chat o ad altri servizi; i report possono contenere percorsi personali, PID e tempi di creazione.

Il programma non termina o sospende applicazioni, non modifica permanentemente quote o priorita e non cancella cache di altre app. start.ps1, start-optimize.ps1, start-demo-agent.ps1, hub-browser.ps1 e il modulo Chrome rimangono facoltativi. Il pannello Windows funziona senza estensioni browser. ProcessLens non e integrato.

Vedi VALIDATION.md per le prove locali, i limiti e la cronologia; INTEGRATION.md per i moduli precedenti.
