# R22: comando AME per i processi Windows

Il comando esiste ora nella nostra interfaccia di controllo: **Start-AmeProcessReduction**. Puo avviare un tentativo su un'applicazione Windows anche quando quell'app non offre un plugin o un comando per liberare la memoria. Il suo punto di accesso pubblico e il modulo PowerShell **process-reduction-api.ps1**; il lavoro Windows viene eseguito dal controller C++ gia presente in **ame.exe**.

Questa revisione aggiunge l'API di controllo, il comando da console e il lettore degli esiti. Riutilizza il metodo residente del motore R10. Non introduce un nuovo algoritmo di gestione della RAM o un rilascio universale delle cache interne. La DLL **ame-resource-api.dll** resta all'ABI 1 e verifica le identita; i suoi export relativi ai Job Object restano invariati. Le nuove funzioni di controllo non sono nuovi export C della DLL.

## Prova senza pannello

1. Chiudi i pannelli AME. Se e attivo l'agente, usa **FERMA_AUTOMATICO.cmd** e attendi che risulti fermo. Un secondo controller viene rifiutato.
2. Apri **RIDUCI_PROCESSO.cmd**. Usa la propria cartella: non devi digitare percorsi. Alla prima apertura verifica o compila i componenti necessari, senza aprire il pannello.
3. Inserisci il PID di un'app che puoi lasciare inattiva, ricavandolo dalla colonna PID di Gestione attivita > Dettagli o dal pannello AME prima di chiuderlo. Il comando legge e mostra l'identita e il percorso effettivi; non accetta un nome di programma come selezione approssimativa.
4. Lascia l'app inattiva e tieni questa console in primo piano. Il controller ha fino a tre minuti per trovare le condizioni necessarie, inclusi sessanta secondi consecutivi di bassa attivita. Se non le trova, conclude senza un intervento confermato.
5. Dopo l'azione puoi riprendere a usare l'app. La misura prosegue fino a cinque minuti dall'intervento, oppure termina prima con il motivo. **Ctrl+C** richiede lo stop del controller; una modifica al working set gia applicata non viene annullata.

Il comando e generale per i processi ammessi, inclusi potenzialmente ChatGPT, Claude, editor e interpreti. Il nome dell'app non ne garantisce l'idoneita. Restano esclusi processi Windows, utenti/sessioni differenti, identita o criticita non verificabili, app in primo piano e relativa famiglia, meno di 128 MiB di RAM privata residente, oltre 2 GiB di working set, metriche mancanti o attivita eccessiva. Non cambia privilegi o protezioni per superarli.

**Richiesta ricevuta**, **intervento applicato**, **RAM diminuita**, **RAM risalita**, **misura incompleta** e **risultato finale** sono stati diversi. Il numero di MiB non viene impostato a zero quando manca la lettura. La differenza mantiene il segno: un valore negativo indica piu RAM residente rispetto a prima. Il commit viene mantenuto come metrica separata.

Il report e in `reports/recover-api-<identificativo>.jsonl`. Usa lo stesso formato nativo e la stessa diagnosi delle prove del pannello. Un beneficio negativo valido viene scritto nello storico condiviso: pannello e comando rispettano lo stesso blocco di trenta minuti per identita e percorso. Una richiesta incerta non viene ripetuta automaticamente.

## Funzioni pubbliche

| Funzione | Contratto |
|---|---|
| Get-AmeProcessTarget | Cattura PID, tempo di creazione e percorso tramite la DLL AME |
| Start-AmeProcessReduction | Ricontrolla identita, build e storico; avvia un solo controller su una sola identita |
| Get-AmeProcessReduction | Legge gli eventi incrementali e restituisce avanzamento, misure ed esito |
| Stop-AmeProcessReduction | Richiede lo stop tramite il file della richiesta, senza terminare l'app |
| Close-AmeProcessReduction | Chiude il lettore e il controller posseduto; da eseguire in finally |

Il chiamante carica `windows-model.ps1`, `resource-api-bridge.ps1` e `process-reduction-api.ps1`, inizializza la connessione con `Initialize-ResourceApi` e crea il target con `Get-AmeProcessTarget`. Passa quell'oggetto a `Start-AmeProcessReduction`, interroga `Get-AmeProcessReduction` e chiama sempre `Close-AmeProcessReduction` e `Client.Dispose()` in un blocco finally. **reduce-process.ps1** e un esempio completo eseguibile di questo contratto.

Le proprieta del risultato includono `Phase`, `Message`, `Applied` (conferma dell'azione), `Assessed`, `Final`, `BeforeBytes`, `AfterBytes`, `ResidentDropBytes` (prima meno dopo, con segno), `PrivateCommitDeltaBytes` (dopo meno prima), `Reason` e `Outcome`. `Applied=true` non dimostra da solo una riduzione; `Applied=false` su un errore significa assenza di conferma, non prova che il processo non sia mai stato modificato. Un intento senza conferma e una misura senza fine valida restano incompleti.

`CausationEstablished`, `ApplicationLatencyMeasured` e `InternalCacheReleaseVerified` restano falsi. La riduzione viene misurata sul processo, senza sottrarre il costo del comando AME e senza attribuire il delta disponibile dell'intero PC alla singola azione. Non va quindi chiamata beneficio netto del sistema.

Il pannello usa **New-AmeReductionStartInfo** dello stesso modulo per generare gli argomenti delle prove native. La verifica DLL dell'identita resta prima dell'avvio; il controller C++ ripete i controlli con un handle vivo prima dell'azione. I parametri non passano da una shell e non possono aggiungere altre identita o comandi.

## Cosa avviene in Windows

La richiesta arriva al motore C++ come `--recover-test`, con un solo `--allow-process PID:creation_filetime`, un solo percorso eseguibile e limite di 180 secondi per l'azione. Il motore controlla identita, proprietario, sessione, criticita, primo piano, memoria e attivita; registra l'intento e chiama **EmptyWorkingSet** una sola volta. Poi misura la RAM privata residente e il commit.

EmptyWorkingSet chiede a Windows di rimuovere pagine dal working set. Non decide quali oggetti dell'app sono inutili e non distrugge le sue cache. Le pagine necessarie possono tornare in RAM; la verifica e lo storico servono a rendere visibile questo comportamento. Non usa un driver kernel, non modifica i binari delle app e non assegna loro nuovi Job Object.

Fonti Microsoft per il comportamento di Windows:

- https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-emptyworkingset
- https://learn.microsoft.com/en-us/windows/win32/memory/working-set

## Rapporto con l'agente automatico

Questa API e richiamabile da un programma o da uno script senza interfaccia grafica. **La R22 non abilita un ciclo automatico indiscriminato sui processi del PC.** L'agente AUTOMATICO mantiene le regole R21 dei soli siti autorizzati nei browser; il comando generale e esplicito e non puo avviarsi in concorrenza con l'agente. Una successiva politica automatica per altre app dovra scegliere e autorizzare i processi e rispettare i risultati di questo comando.

Il codice e stato verificato localmente con letture ed eventi sintetici, controller sostitutivi e test degli argomenti realmente ricevuti da un processo figlio. In questo ambiente Linux non e stata eseguita una nuova riduzione su un'app Windows reale. I test locali non certificano quanti MiB duraturi otterrai sul tuo PC.
