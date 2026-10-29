# AME 0.5 — Integrazione

Il pannello WinForms avvia un solo motore Windows alla volta e legge JSONL tramite ReportTail. Il passaggio observe -> recover/recover-test richiede prima lo stop dell'osservatore. Alla fine il pannello passa in pausa, conservando il risultato. Il monitoraggio riparte solo dal pulsante dedicato.

--recover conserva pressione 85%/30s e le altre guardie. --recover-test richiede esattamente un --allow-process PID:creation_filetime e una --allow-exe FULL_PATH, durata massima 180s. Deroga soltanto alla pressione globale, non alla validita delle metriche o alle guardie del processo. RecoverGate limita la prova a una azione; il controller finisce dopo il primo tentativo e l'eventuale feedback. Un fallimento della chiamata o un controllo fresco fallito non viene ripetuto nella prova.

recover_session: single_test, selected (PID e creation_filetime), allowed_images.
recover_target: PID, creation_filetime, elapsed_seconds, reason, pressure, single_test, low_activity_seconds, cpu_percent e page_faults_per_second (null se non noti).
recover_state: pressione, completati, feedback, disabled/reason, max_actions, single_test e motivi aggregati (campioni-processo).
recover_intent: scritto e flushato prima della chiamata API.
recover_applied/skipped/guard/incomplete/assessed: esito dichiarato dal controller.
recover_no_action: prova fermata o scaduta prima dell'idoneita; non implica chiamata API.
recover_feedback: delta con segno, residenza privata e disponibile sistema. Causation=false, latency_measured=false, hard_faults_only=false.

La valutazione corrente del motore R10 avviene a 300 s e considera tutti i campioni dell ultimo minuto: almeno 16 MiB di riduzione residente e oltre il 20% della riduzione massima. Ricrescita rapida e beneficio troppo piccolo possono concludere prima la misura. Disponibile di sistema, CPU e fault restano contesto osservato; non sono prove di velocita o beneficio causale.

L'inventario e completo ogni dieci secondi; le metriche delle identita selezionate arrivano ogni due. I dati in pausa sono storici e non permettono nuovi interventi finche non viene riavviato il monitoraggio. Le guardie vengono ricontrollate con handle vivo prima di EmptyWorkingSet, senza una transazione atomica fra tutti i controlli.

Il pannello Windows non dipende dal bridge Chrome o da ProcessLens. Per liberare le allocazioni di una cache serve una API/integrazione nell'app; il solo controllo esterno del working set non fornisce tale capacita.

## Pannello R15 e strategia

strategy-model.ps1 mantiene un journal osservativo per eseguibile, separato dal blocco negativo per identita di windows-model.ps1. strategy-history.json viene aggiornato soltanto da recover_assessed autorizzati; nessuna inferenza di cache eliminabile. Le prove mantengono il motore R10 e il controllo API dell'identita.

release-support.ps1 aggiunge la sezione browser nel pannello ordinario; browser-panel.ps1 conserva funzioni e stato nello scope script per restare utilizzabile anche dopo l'inizializzazione da una funzione. La misura del browser non necessita di un secondo motore AME. Poll-Browser viene eseguito dal timer del pannello anche quando observe e in pausa. Un pendingBrowser blocca nuove prove native; il loop browser non invia discard quando una prova nativa e attiva o in transizione. browser_feedback/browser_assessed riportano variazioni aggregate, non MB attribuiti alla singola scheda.

Il resoconto della demo API continua a descrivere i Job Object su fixture. La verifica delle identita usa la API nativa R1; il rilascio di contenuto delle schede usa il contratto pubblico Chrome e il bridge gia presente, senza assegnare il browser a un nuovo Job Object.


## R22: API generale di controllo dei processi

Il modulo process-reduction-api.ps1 espone Start/Get/Stop/Close-AmeProcessReduction. Non richiede un plugin della singola app per tentare una riduzione residente. Get-AmeProcessTarget usa la DLL ABI 1 per catturare l'identita; Start la ricontrolla prima di creare un processo figlio e prima dell'avvio. Build e modulo sono confrontati con la validazione R22. Il mutex del pannello esclude un agente/pannello concorrente, mentre il motore mantiene il proprio mutex di mutazione.

Il lettore correla recover_session, identita, percorso, intento e conferma; non considera il successo della chiamata una misura RAM. Richiede una valutazione valida dopo 300 s per gli esiti mantenuti, conserva differenze con segno, segnali di attivita e misure incomplete. Usa lo storico negativo del pannello. Il modulo non aggiunge export alla DLL C: orchestra il controller nativo R10 gia esistente. reduce-process.ps1 e il chiamante senza GUI; New-AmeReductionStartInfo e condivisa con il pannello. Guida completa: API_PROCESSI.md.
