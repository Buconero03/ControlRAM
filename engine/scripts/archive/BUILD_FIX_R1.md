# Build e percorsi — AME 0.4

Estrai questa versione in una cartella nuova. Apri PowerShell nella cartella che contiene test-windows.ps1 e hub.ps1. Gli script ricavano i percorsi dalla propria cartella: non devi incollare il percorso di una vecchia sessione.

La build collega user32.lib, oltre a psapi.lib, ws2_32.lib e advapi32.lib. È inclusa la correzione dei precedenti simboli GetForegroundWindow e GetWindowThreadProcessId mancanti.

Se la build segnala un eseguibile occupato o LNK1104 su build\ame.exe, chiudi pannello e console AME di questa installazione, poi riesegui test-windows.ps1. Un programma in esecuzione non può essere sovrascritto dal linker.

Non sostituire sorgenti in una vecchia installazione attiva. Non serve installare Chrome per hub.ps1.
