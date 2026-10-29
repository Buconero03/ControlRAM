# AME Resource API R1

API nativa Windows 10/11 x64, implementata in C++17 con interfaccia C esportata dalla DLL `ame-resource-api.dll`. ABI versione 1. Lavora insieme ai Job Object Windows: aggiunge identita verificata, lettura dei consumi, calcolo degli andamenti e notifiche di memoria. Non richiede un driver kernel.

Questa prima versione fornisce gestione e osservazione. Non libera allocazioni, non applica EmptyWorkingSet, non cambia priorita CPU/memoria e non stima MB recuperabili. Lo storico degli esiti e la scelta adattiva degli interventi sono sviluppi successivi. Il pannello R14 carica la DLL all'avvio e usa AmeReadProcessIdentity prima di accettare una richiesta e di avviare il relativo motore R10. Non associa le selezioni ai Job Object. Il bridge C# carica il percorso assoluto della DLL validata, controlla ABI 1 e legge una struttura UTF-16 di 65552 byte. Solo la API di identita e esposta al pannello; non esistono chiamate di associazione o mutazione nel bridge.

## Compilazione e prima esecuzione

Apri **DEMO_API.cmd** dalla cartella principale: usa la propria cartella, compila la DLL e l'esempio con Visual Studio Build Tools o MinGW-w64 x64, esegue la verifica e mostra il risultato. Non serve digitare il percorso e non serve avviare come amministratore.

Dalla R13, alla fine si apre automaticamente **resoconto.html** nel browser predefinito. La pagina mostra memoria osservata, avviso Windows, operazioni cronologiche, risultati delle richieste, controlli e codice sorgente con numeri di riga. Le sezioni del codice sono espandibili e il resoconto contiene tutto il necessario per rileggerle senza rete. Non usa script o librerie web.

I file sono conservati in una nuova cartella **reports/api/API-data-ora-id/** per ogni esecuzione: esecuzione.jsonl e resoconto.html; se e stata necessaria la compilazione, anche verifica-compilazione.jsonl. Il registro JSONL contiene le chiamate realmente eseguite dal client, il risultato AME, il codice Windows, tempi monotoni, misure ed eventi. Le spiegazioni dei percorsi interni della DLL sono documentazione del codice, non una traccia di ogni singola istruzione Win32. I Getter versione/errore sono spiegati nel contratto e verificati dai controlli; il registro delle chiamate riguarda le sette operazioni che restituiscono AmeResult.

Il resoconto viene creato anche se la compilazione o la demo falliscono: indica l'errore e le eventuali chiamate registrate fino a quel momento. Se l'apertura automatica non riesce, il percorso resta stampato nella console. Per eseguire senza aprire una finestra: **demo-resource-api.ps1 -NoOpen**. Per rigenerare una pagina da un registro esistente, usare export-resource-api-report.ps1 con TracePath e OutputPath. Una riga finale parziale, una sequenza incoerente, un esito mancante o un errore non diventano una prova completa; misure/tassi mancanti rimangono non disponibili.

La demo crea un proprio processo, misura la memoria assegnata, imposta un avviso a 32 MiB e richiede al processo di assegnare altri 64 MiB. Verifica che Windows notifichi il superamento e che l'applicazione possa continuare ad assegnare memoria. Verifica poi un secondo processo, identita errate, appartenenza preesistente a un job e chiusura del gruppo senza terminazione dell'applicazione. I fixture vengono chiusi al termine. Nessuna applicazione gia aperta dall'utente viene associata o modificata.

La demo e anche una verifica di integrazione: non e una dimostrazione di RAM risparmiata. Fallisce esplicitamente se l'ambiente ospitante impedisce di creare processi fuori dal suo job. Il pannello ordinario resta avviabile con AVVIA.cmd.

I risultati compilati sono in `build/`: DLL, libreria di importazione (`ame-resource-api.lib` con MSVC o `libame-resource-api.a` con MinGW), esempio e test. Le successive aperture riutilizzano la build solo quando corrispondono ABI, revisione e hash di sorgenti/artefatti. `build-resource-api.ps1 -Force` ricompila; `-CheckOnly` restituisce soltanto lo stato di validazione senza eseguire programmi. La build MinGW richiede il relativo runtime disponibile nel PATH. CMake offre i target `ame_resource_api`, `ame_resource_demo` e `ame_resource_analysis_tests`, con test CTest dedicati.

## Chiamate disponibili

| Funzione | Comportamento |
|---|---|
| `AmeGetApiVersion` | Restituisce la versione ABI attuale, 1 |
| `AmeReadProcessIdentity` | Legge PID, tempo di creazione e percorso UTF-16 |
| `AmeCreateGroup` | Crea un Job Object privato, senza nome e senza limiti rigidi |
| `AmeAttachProcess` | Associa esplicitamente l'identita verificata al gruppo |
| `AmeSetCommitNotice` | Imposta una soglia di notifica per memoria assegnata; zero la disabilita |
| `AmeReadGroupSnapshot` | Legge memoria, contatori e tassi di variazione |
| `AmePollGroupEvent` | Restituisce un messaggio reale del kernel, senza attesa |
| `AmeCloseGroup` | Disabilita gli avvisi e rilascia il monitoraggio AME |
| `AmeGetLastWindowsError` | Legge il dettaglio Win32 dell'ultima chiamata sullo stesso thread |

## Contratto di associazione e chiusura

L'associazione a un Job Object Windows dura finche il processo termina: non esiste un detach durante l'esecuzione. `AmeCloseGroup` non stacca i processi e non li termina. Non viene impostato `KILL_ON_JOB_CLOSE`. Alla chiusura gli avvisi vengono disabilitati prima di rilasciare gli handle; un errore conserva il gruppo per permettere il retry. Gli altri processi continuano a funzionare anche se il controller termina. Dopo un crash del controller puo rimanere configurata una soglia di sola notifica fino alla fine dei membri; non blocca nuove allocazioni.

La R1 rifiuta processi gia associati a qualsiasi job, compresi altri gruppi AME. Non modifica job esterni e non tenta l'annidamento. Non promette quindi l'associazione di ogni applicazione Windows. Le applicazioni incompatibili restano osservabili tramite il motore AME esistente. I figli creati DOPO l'associazione non entrano automaticamente nel gruppo: e impostato `SILENT_BREAKAWAY_OK`. Ogni identita deve essere associata esplicitamente. Non viene inventata una famiglia di processi in base al solo nome dell'eseguibile.

Prima dell'associazione vengono ricontrollati PID/creazione/percorso sul medesimo handle, esecuzione ancora attiva, stesso proprietario, stessa sessione, criticita nota e assenza di percorso nella cartella Windows. Il controller non puo associare se stesso. Qualsiasi controllo non disponibile produce un errore. Per chiamare AssignProcessToJobObject Windows richiede anche il diritto PROCESS_TERMINATE; la DLL non invoca alcuna terminazione. Questi controlli sono una policy della libreria e non sostituiscono i permessi di Windows o l'autorizzazione del chiamante.

Un gruppo e un insieme esplicito di identita, non un nuovo processo e non una macchina virtuale. Massimo 16 gruppi aperti e 64 associazioni complessive per gruppo, inclusi membri gia terminati. Gli ID sono locali alla DLL caricata e non vengono riutilizzati durante la sua vita. Nessun handle Win32 del job viene esportato. Dopo unload/reload gli ID precedenti non sono validi. Chiudere tutti i gruppi prima di scaricare la DLL e serializzare l'unload con i chiamanti.

## Misure: cosa significano

- `private_commit_sum_bytes`: somma della memoria privata assegnata ai membri attivi misurabili. Non e tutta residente nella RAM fisica.
- `working_set_sum_bytes`: somma dei working set. Le pagine condivise possono essere contate piu volte: non e l'impronta fisica unica del gruppo e non va presentata come RAM liberabile.
- `cpu_time_100ns`, I/O e fault: contatori cumulativi del job, che includono anche i membri terminati. L'I/O non e soltanto disco e i fault non distinguono hard e soft.
- `AME_MEMORY_COMPLETE`: tutti i processi attivi del job sono stati misurati durante la lettura. Le letture non sono atomiche; una terminazione puo rendere il campione incompleto.
- `AME_RATES_VALID`: confronto disponibile tra campioni completi con la stessa composizione, a distanza di 1..6 secondi. Senza questo flag gli zeri nei campi calcolati NON significano attivita nulla. Una lettura iniziale, una nuova associazione, un processo terminato, un contatore inverso o un intervallo troppo lungo invalidano il confronto. Letture piu frequenti mantengono la baseline fino ad almeno un secondo.
- `cpu_percent_machine`: percentuale normalizzata sul numero di processori logici attivi del PC; non e la percentuale di un singolo core.
- `private_commit_change_bytes`: incremento o diminuzione misurata della memoria assegnata rispetto alla baseline. Non attribuisce causalmente la variazione ad AME.
- `AME_COMMIT_NOTICE_EXCEEDED`: confronto locale tra somma privata completa e soglia configurata. Non significa che sia arrivato un messaggio del kernel.

La soglia accetta zero oppure 1 MiB..1 TiB ed e impostata con JobObjectNotificationLimitInformation. Consente ulteriori allocazioni oltre la soglia. I messaggi di avvio/uscita non sono garantiti: usare sempre gli snapshot per conoscere lo stato corrente. Gli avvisi di questa classe sono documentati come garantiti alla completion port; `AmePollGroupEvent` legge e riconosce l'avviso con QueryInformationJobObject per consentire il successivo. I valori dell'avviso descrivono la violazione letta al momento del riconoscimento, non un campione storico salvato all'istante dell'accodamento. Un vecchio messaggio dopo la disabilitazione viene restituito come evento generico, senza inventare una violazione attuale.

## Uso da C/C++ e interoperabilita

Includere `ame_resource_api.h`, collegare la libreria d'importazione x64 e mantenere la DLL vicino all'eseguibile o in un percorso di caricamento affidabile. Il sorgente completo in `examples/resource_api_demo.cpp` chiama soltanto le funzioni pubbliche della DLL per la gestione del gruppo. Da C#, la stessa ABI e utilizzabile con P/Invoke (CallingConvention.Cdecl, campi e packing corrispondenti, stringhe UTF-16); un binding gestito non e incluso nella R1.

Ordine tipico: verificare versione, creare gruppo, leggere identita, associare, impostare avviso, leggere snapshot e messaggi, chiudere. Inizializzare il campo `size = sizeof(struct)` prima di ogni chiamata con una struttura. Non passare puntatori invalidi o buffer insufficienti. Controllare sempre `AmeResult`; i dati d'uscita sono utilizzabili solo con `AME_OK`. `AME_NO_EVENT` non e un errore e non contiene un evento valido.

Le funzioni non fanno propagare eccezioni C++ oltre la DLL. Le operazioni sono serializzate, senza thread interno e senza callback; il polling non blocca. Il client decide la frequenza, indicativamente 1..2 s per snapshot. Evitare cicli senza pausa sugli eventi e usare un worker per le chiamate dal pannello. Non chiamare dalla DllMain, da un signal handler o mentre si scarica la DLL.

## Fonti Windows e verifica

- [Job Objects e durata dell'associazione](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
- [AssignProcessToJobObject e diritti richiesti](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject)
- [Soglie di notifica](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_notification_limit_information)
- [Lettura della violazione](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_limit_violation_information)

La prova R12 condivisa dall'utente il 12 ottobre conferma compilazione MSVC x64, PASS 41 controlli dell'analisi e PASS 96 controlli della demo reale Windows, sia durante la validazione sia durante l'esempio. Riporta memoria assegnata 8 -> 72 MiB e avviso oltre 32 MiB, con processo ancora attivo. Conferma il funzionamento della base API, non un risparmio RAM o un guadagno prestazionale.

In questo ambiente Linux: analisi, produzione/lettura JSONL e resoconto verificati. Client R13 cross-compilato e collegato per Windows x64 con avvisi trattati come errori. Il resoconto R13 ricevuto il 12 ottobre conferma una sessione Windows completata in 1,386 s con 96 controlli e un avviso reale oltre 32 MiB. Il nuovo bridge R14 e stato verificato qui con contratti gestiti e handler reali del pannello, ma il suo caricamento Windows nel pannello e ancora da confermare sul PC. Il test di avvio locale usa un processo figlio sintetico dichiarato come tale, controlla gli argomenti con spazi e intercetta l'apertura invece di avviare un browser.

## Verifica del bridge del pannello R14

`tests/test-resource-api-client.ps1` verifica marshaling, UTF-16, identita cambiate, codici di errore, API non disponibile e blocco prima dell'avvio del motore con un backend sintetico esplicito. Su Windows, dopo la compilazione API, `tests/test-resource-api-client.ps1 -NativeWindows` aggiunge la lettura reale dell'identita del solo processo di test tramite DLL. L'inizializzazione ordinaria del pannello esegue comunque una lettura reale della propria identita: la riga API pronta compare soltanto se riesce. Gli eventi `resource_api/ready`, `identity_verified`, `identity_rejected` e `unavailable` entrano nel registro del pannello. La validazione dell'identita al clic non sostituisce i controlli nativi immediatamente precedenti al trimming.

## Strategia applicativa R15

AVVIA continua a caricare la API di identita nel pannello. La strategia aggiunge uno storico di prove e un percorso applicativo per Chrome nella sezione Rilascio nelle app. Questo percorso usa chrome.tabs.discard e il native messaging bridge gia presenti: non estende l'ABI R1, non assegna i renderer ai Job Object e non rende il trimming una liberazione delle allocazioni. Il journal della demo API resta separato dai report di azioni Chrome.
