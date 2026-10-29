# R22 FIX1 — avvio su Windows PowerShell 5.1

Questa correzione risolve il blocco `Measure-Object ... private_working_set_bytes`
nel controllo del consumo di AME. La compilazione nativa nel log ricevuto era
riuscita; l’avvio si fermava durante il test dell’agente automatico.

## Installazione sulla cartella R22 esistente

1. Chiudi i pannelli AME; se l’agente automatico è attivo, usa `FERMA_AUTOMATICO.cmd`.
2. Estrai lo ZIP. Copia il contenuto della cartella interna
   `AdvancedMemoryEngine-v0.5.0` dentro la cartella omonima del tuo progetto R22,
   accettando la sostituzione dei file. Non eliminare le tue cartelle `build`,
   `reports` o altre cartelle di dati già presenti.
3. Riapri il comando che usavi: `AVVIA.cmd` per il pannello,
   `AUTOMATICO.cmd` per l’agente oppure `RIDUCI_PROCESSO.cmd` per la prova manuale.
   Il programma riesegue i controlli necessari sui file aggiornati.

## Modifica

`agent-runtime.ps1` proietta i valori numerici di memoria privata residente e CPU
prima di sommarli. In Windows PowerShell 5.1 `Measure-Object -Property` non
interpreta le chiavi delle hashtable come le proprietà degli oggetti di telemetria.
La correzione conserva i controlli sui dati mancanti, le soglie RAM/CPU e l’arresto
quando il budget viene superato.

`tests/test-auto-agent.ps1` verifica ora anche le somme di più componenti AME con
hashtable, oggetti e righe miste, l’esclusione di altri processi, lo zero reale e i
dati sconosciuti. I controlli esistenti non sono stati rimossi.

## Limiti della verifica

Il test dell’agente passa con 82 controlli in PowerShell 7 su Linux. La verifica
reale con Windows PowerShell 5.1 deve essere eseguita dal launcher sul PC Windows.
I sorgenti nativi, la DLL e la logica degli interventi RAM non cambiano rispetto a
R22. Questa correzione riguarda il controllo dei consumi di AME e il suo avvio.

Le righe `PASS` e i report delle prove nella cartella temporanea non dimostrano
una riduzione della RAM delle tue applicazioni. Per quella servono i risultati
misurati di un intervento reale. L’agente automatico conserva l’ambito attuale:
schede Chrome/Firefox autorizzate; l’API manuale può provare il working set di un
processo idoneo senza garantire una riduzione duratura o delle allocazioni interne.
