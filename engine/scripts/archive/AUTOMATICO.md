# AME R21: usarlo in automatico

L'agente osserva tutti i processi senza tenere aperto il pannello. Per ora il metodo automatico di rilascio riguarda le schede di Chrome e Firefox. Le altre applicazioni sono visibili nell'analisi, con indicazione del metodo mancante. Non occorre selezionare ogni processo o inviare i log per farlo funzionare.

## Prima apertura

1. Ferma l'eventuale agente precedente con **FERMA_AUTOMATICO.cmd**, premi Scollega nelle estensioni e chiudi i vecchi pannelli AME. Estrai lo ZIP e copia i file nella tua cartella AME, sostituendo i sorgenti. Puoi conservare build, reports ed exports. Non spostare la cartella mentre l'agente e attivo.
2. Apri **AUTOMATICO.cmd**. Alla prima apertura verifica e, se necessario, compila i componenti Windows. Questa preparazione richiede il compilatore gia usato per AME e puo durare; gli avvii successivi riutilizzano le verifiche valide. Quando compare **AGENTE ATTIVO**, la finestra si chiude. Nessun processo viene scaricato per il solo avvio.
3. In Chrome apri `chrome://extensions`, ricarica AME e verifica **0.5.0**. Se necessario carica come estensione non pacchettizzata la cartella **browser/chrome** della stessa installazione. In Firefox carica **browser/firefox/manifest.json** da `about:debugging#/runtime/this-firefox`. Il caricamento temporaneo Firefox va ripetuto dopo aver riavviato Firefox; il pacchetto non e firmato per un'installazione permanente.
4. Nell'estensione premi **Collega ad AME**. Attendi **Collegato** e **Agente automatico attivo**. Il collegamento resta attivo con il popup chiuso, finche browser e agente sono aperti. Se l'agente manca, l'estensione ritenta circa ogni 30 secondi; il browser puo ritardare il tentativo.
5. Apri un sito con pagine ricaricabili senza lavoro non salvato e premi **Autorizza automatico sul sito corrente**. E un permesso iniziale che vale per le schede HTTPS di quel dominio esatto, anche future, fino a revoca. Un sottodominio diverso richiede il proprio permesso. L'estensione conserva l'elenco nel profilo browser. Non autorizzare domini con moduli, editor o contenuti che non vuoi ricaricare: AME non puo riconoscere ogni modifica non salvata. I siti protetti da AME restano esclusi.

Ora puoi chiudere il popup e il pannello di consultazione. Per un avvio davvero senza finestre dopo la configurazione, usa facoltativamente **ABILITA_AVVIO_WINDOWS.cmd**: crea un collegamento nella cartella di avvio dell'utente, al prossimo accesso Windows. Non installa un servizio di sistema e non richiede amministratore. Il collegamento dipende dal percorso della cartella; dopo averla spostata riabilita l'avvio dalla nuova posizione.

## Quando decide di intervenire

Le impostazioni iniziali richiedono RAM occupata almeno all'85% per 30 secondi consecutivi e scheda autorizzata inattiva da almeno 15 minuti. Telemetria Windows, identita e inventario browser devono essere aggiornati e completi. Schede attive, fissate, con audio, private, gia scaricate, non ricaricabili, in caricamento e siti protetti restano esclusi. L'estensione ricontrolla lo stato e il permesso immediatamente prima del comando al browser. Se manca l'orario dell'ultima attivita non indovina l'inattivita.

Tra le schede idonee sceglie la meno recente. Invia una sola richiesta, ne aspetta la conferma e misura per cinque minuti prima di un altro intervento. Default: almeno dieci minuti fra richieste, massimo due richieste all'ora e otto nelle 24 ore. Intenti e tentativi incerti contano nei limiti anche dopo un riavvio. Non invia di nuovo una richiesta senza risposta.

Non interviene solo per abbassare una cifra mentre la memoria disponibile e sufficiente. Puo restare in osservazione a lungo: lo stato spiega se attende pressione, autorizzazioni, inattivita, dati o una pausa dello storico.

## Come leggere il risultato

Apri **STATO_AUTOMATICO.cmd**. Mostra agente attivo/fermo, collegamenti, motivi di attesa, ultimo risultato e fino a venti gruppi di applicazioni per RAM privata. Il conteggio generale riguarda tutto l'inventario; la tabella e un riepilogo. Dati non disponibili appaiono N/D.

- **Richiesta inviata:** nessuna riduzione ancora confermata.
- **Scaricamento confermato:** il browser dichiara la scheda scaricata. La scheda rimane nella barra e verra ricaricata quando la riusi.
- **Misura in corso:** differenza di RAM privata residente del browser, meno il consumo privato residente misurato dell'agente e dei componenti AME della stessa installazione. I numeri mantengono il segno: possono essere negativi.
- **Riduzione osservata per la durata prevista:** nell'ultimo minuto della verifica la differenza netta rimane almeno 64 MiB, soglia iniziale configurabile. Non certifica che AME ne sia l'unica causa o che il PC sia piu veloce. Le misure riguardano tutti i processi di quel browser nella sessione Windows, non i MB della sola scheda.
- **Beneficio breve/piccolo o attivita aumentata:** il sito viene evitato per 24 ore. Aumenti osservati di CPU, fault totali o letture I/O sono segnali di costo, quando i contatori sono confrontabili; non misurano soltanto letture da disco o hard fault.
- **Misura incompleta/esito sconosciuto:** non viene inventato un risultato. Una conferma tardiva viene conservata, senza riprendere o ripetere la richiesta. Le misure incerte impongono una pausa. Dopo un esito non negativo il sito resta comunque in pausa per un'ora.

Il ritorno alla scheda durante la verifica termina l'osservazione con beneficio breve. Il tempo fino all'evento di caricamento non misura quando l'app e pronta. Cambi dei processi del browser sono segnalati; metriche mancanti, sospensione o intervalli oltre dodici secondi interrompono la verifica. Causalita, hard fault e latenza delle applicazioni restano non verificati. Il costo della finestra facoltativa di consultazione, avviata in un processo separato, non e incluso nel costo dell'agente.

L'ultimo esito resta visibile mentre l'agente torna in attesa ed e ripristinato dallo storico al riavvio. **Esporta diagnosi** raccoglie gli eventi e un riepilogo leggibile; non devi inviare log per autorizzare ogni azione. Il programma non carica registri online. I file locali possono contenere nomi, percorsi dei processi e domini autorizzati: controllali prima di condividerli.

## Comandi

| File | Effetto |
|---|---|
| AUTOMATICO.cmd | Prepara e avvia l'agente senza pannello |
| STATO_AUTOMATICO.cmd | Consulta stato e risultati; chiuderlo lascia attivo l'agente |
| FERMA_AUTOMATICO.cmd | Chiede l'arresto dell'agente; non chiude le applicazioni |
| ABILITA_AVVIO_WINDOWS.cmd | Avvia l'agente al prossimo accesso dell'utente |
| DISABILITA_AVVIO_WINDOWS.cmd | Rimuove l'avvio futuro; per la sessione attuale usa Ferma |
| AVVIA.cmd | Pannello manuale con agente fermo, consultazione con agente attivo |

Per revocare un dominio aprilo e premi **Revoca automatico sul sito corrente** nell'estensione. Per scollegare quel profilo premi **Scollega**. Una richiesta gia eseguita non puo essere annullata. Ferma l'agente prima di usare il confronto manuale **Verifica beneficio** o le prove temporanee sui processi: la stessa sessione Windows ammette un solo controller AME.

## Regole, storico e costo del programma

**Apri regole** apre `agent-config.json`. Le modifiche vengono lette al prossimo avvio: ferma e riavvia l'agente. Il file espone soglie, tempi, limiti di richieste e budget propri; valori fuori dagli intervalli previsti bloccano l'avvio. `automatic_browser_release: false` mantiene soltanto l'osservazione. Nessun dominio e autorizzato dal file: il permesso e nell'estensione del singolo profilo.

Default di costo: massimo 256 MiB di RAM privata residente di AME e CPU oltre il 2% dell'intero PC per 30 secondi consecutivi. Se il proprio consumo supera questi limiti, l'agente si ferma e registra il motivo; non termina altre app. I controlli periodici non sono un limite di memoria imposto dal kernel.

I file sono in `reports/agent`: stato aggiornato circa ogni cinque secondi, quattro registri fino a 2 MiB ciascuno, due inventari nativi fino a circa 8 MiB ciascuno e storico fino a 512 richieste negli ultimi sette giorni. Il controllo di dimensione dell'inventario e periodico e puo superare la soglia di una scrittura prima dell'arresto. Lo storico danneggiato blocca le azioni; il monitoraggio e la spiegazione restano disponibili. Le diagnosi esportate sono separate.

## Per chi vuole seguire il codice

`start-agent.ps1` valida i componenti e crea il processo nascosto. `agent.ps1` gestisce il ciclo e l'esclusione fra controller; il figlio `ame.exe --observe --inventory` raccoglie senza interventi. `agent-model.ps1` decide e valuta le misure. `agent-runtime.ps1` collega browser, registra l'intento prima dell'invio e correla le conferme. `src/comparison-metrics.cs` legge RAM e contatori da identita Windows verificate. `browser/*/policy.js` controlla di nuovo il permesso e lo stato prima di `tabs.discard`. `agent-state.ps1` pubblica lo stato con sostituzione atomica; `agent-dashboard.ps1` lo consulta senza essere necessario al ciclo.

Questa revisione implementa il ciclo automatico per il rilascio gia supportato dai browser. Non introduce un nuovo metodo di rilascio interno per ChatGPT, Claude o altre app, non sposta processi in una memoria virtuale proprietaria e non usa i Job Object della demo per imporre limiti alle applicazioni.

La validazione locale e svolta su Linux con PowerShell e test JavaScript: verifica regole, controller e misure sintetiche. L'esecuzione continua su Windows, WinForms e i risparmi effettivi sul tuo PC richiedono ancora verifica su Windows; non sono risultati dimostrati dai test simulati.


## Comando generale R22

La revisione R22 aggiunge RIDUCI_PROCESSO.cmd e l'API di controllo descritta in [API_PROCESSI.md](API_PROCESSI.md). La richiesta generale e esplicita: ferma prima questo agente. L'automatico dei browser descritto in questa guida non cambia e non effettua trim generici sulle altre app.
