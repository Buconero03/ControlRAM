# Aggiornamento Tecnico: Ultime Modifiche (ControlRAM v0.5.0 R22)

> **Repository:** [Buconero03/ControlRAM](https://github.com/Buconero03/ControlRAM)  
> **Copertura commit:** da `63d32ba` a `ca479d5` + utility di diagnosi servicing Windows  
> **Stato:** Validazione R22 superata (`83` check agente automatico, `47` check API processi)

---

## 1. Riepilogo delle Novità Introdotte

Dopo l'introduzione della *Cascade Decompression* (documentata in [`CHANGELOG_LATEST_MODIFICATIONS.md`](CHANGELOG_LATEST_MODIFICATIONS.md)), il progetto **ControlRAM (AdvancedMemoryEngine v0.5.0 R22)** ha ricevuto sei aggiornamenti principali su avvio UAC, controllo reale di Windows Defender, affidabilità I/O concorrente e protezione da memory leak del kernel Windows:

1. **Launcher Amministratore dedicato e correzione avvio finestre**
2. **Windows Defender Governor con parametri corretti, verifica reale ed elevazione UAC da Dashboard**
3. **Resilienza alla concorrenza I/O su `status.json` e chiusura pulita**
4. **Watchdog in tempo reale per Kernel Pool & Handle Leak (Dashboard + Console)**
5. **Auto-bonifica sicura per leak persistenti di `TiWorker.exe` + sblocco manuale UAC**
6. **Diagnostica guidata Windows Servicing (DISM / SFC / `CBS.log`)**

---

## 2. Dettaglio Tecnico delle Modifiche

### 2.1 Launcher Standard e Avvio come Amministratore (`63d32ba`, `2f3a67e`)
* **Problema risolto:** l'auto-elevazione inline nei file batch usava sequenze `\"\"` che causavano un `ParserError` di PowerShell e chiudevano subito la finestra del prompt all'avvio.
* **Soluzione:**
  * Ripristinati [`AUTOMATICO.cmd`](AUTOMATICO.cmd) e [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) all'esecuzione diretta e immediata.
  * Introdotto [`AVVIA_COME_AMMINISTRATORE.cmd`](AVVIA_COME_AMMINISTRATORE.cmd) supportato dallo script dedicato [`engine/start-elevated.ps1`](engine/start-elevated.ps1), che gestisce il prompt UAC con `-WorkingDirectory`, `-Verb RunAs`, `-NoExit` e cattura l'eventuale annullamento dell'utente senza chiudere bruscamente la console.

### 2.2 Windows Defender Governor Reale e Elevazione UAC (`3bec052`, `a3d690c`)
* **Problema risolto:**
  * `Set-MpPreference` veniva invocato con un nome di parametro errato (`-DisableCpuThrottleOnIdle` invece di `-DisableCpuThrottleOnIdleScans`) e senza `-EnableLowCpuPriority $true`.
  * Un blocco `catch {}` silenzioso mascherava sia il fallimento del comando sia la mancanza di privilegi Amministratore, mostrando falsamente lo stato attivo in verde nella Dashboard.
* **Soluzione in [`engine/agent-runtime.ps1`](engine/agent-runtime.ps1), [`engine/agent-dashboard.ps1`](engine/agent-dashboard.ps1) e [`engine/apply-defender-limit.ps1`](engine/apply-defender-limit.ps1):**
  * Aggiunta `Get-AmeDefenderRealStatus`: verifica direttamente tramite `Get-MpPreference` i valori reali (`ScanAvgCPULoadFactor <= 15`, `ThrottleForScheduledScanOnly = False`, `DisableCpuThrottleOnIdleScans = False`, `EnableLowCpuPriority = True`) prima di impostare `DefenderOptimized = $true`.
  * Corretto `Set-MpPreference` aggiungendo `-EnableLowCpuPriority $true` e `-AllowSwitchToAsyncInspection $true`, esclusioni per le directory workspace/build/reports e pulizia cache firme dinamiche via `MpCmdRun.exe -RemoveDefinitions -DynamicSignatures`.
  * Se l'agente gira come Utente Standard, cliccando **`Limita Defender`** dalla Dashboard viene lanciato [`engine/apply-defender-limit.ps1`](engine/apply-defender-limit.ps1) con richiesta **UAC**, seguito da una nuova verifica reale tramite bus IPC.
  * Compattata la visualizzazione nella card **MEMORIA E RISPARMIO** della Dashboard per evitare troncamenti verticali del testo.

### 2.3 Resilienza Concorrenza File I/O & Shutdown (`7daf0a6`)
* **Problema risolto:** durante l'arresto e ripristino, la lettura rapida di `status.json` da parte della console mentre il worker in background eseguiva `[IO.File]::Replace` poteva generare un `IOException` (*Sharing Violation*).
* **Soluzione in [`engine/agent-state.ps1`](engine/agent-state.ps1) e [`engine/start-agent.ps1`](engine/start-agent.ps1):**
  * Aggiunto un ciclo di retry (fino a 6 tentativi con pausa di 50 ms) su `IOException` in `Read-AgentJson` e `Write-AgentJson`.
  * Protetta con `try/catch` la sequenza di arresto `Request-AgentStop` e aggiunta disiscrizione sicura di `PowerShell.Exiting` in chiusura.

### 2.4 Watchdog Kernel Pool & Handle Leak (`707ce45`)
* **Motivazione:** individuare immediatamente eventuali saturazioni di RAM non visibili nella lista processi (es. crescita anomala di *Kernel Non-Paged Pool* / *Paged Pool* dovuta a file handle aperti in massa da componenti di sistema come `TiWorker.exe`).
* **Soluzione in [`engine/agent-runtime.ps1`](engine/agent-runtime.ps1), [`engine/agent-dashboard.ps1`](engine/agent-dashboard.ps1), [`engine/agent-config.json`](engine/agent-config.json) e [`engine/agent-model.ps1`](engine/agent-model.ps1):**
  * Aggiunta `Update-AmeKernelAndHandleTelemetry`: ogni 30 secondi interroga `psapi.dll!GetPerformanceInfo` (Non-Paged Pool, Paged Pool, handle totali) e controlla il processo con il numero più alto di handle.
  * Soglie configurabili: `kernel_pool_monitor` (`true`), `kernel_nonpaged_alert_mib` (`1024`), `process_handle_leak_threshold` (`100000`).
  * Quando superate, la Dashboard mostra `ALLERTA KERNEL: <MiB> MiB NP` in ambra/rosso nella card **MEMORIA E RISPARMIO** con nome processo/handle nella sottoriga, aggiorna la barra di stato e la console evidenzia `[ALLERTA]` in rosso.

### 2.5 Auto-Bonifica `TiWorker.exe` & Utility Manuale (`707ce45`, `ca479d5`)
* **Auto-bonifica automatica ([`engine/agent-runtime.ps1`](engine/agent-runtime.ps1), [`engine/agent-config.json`](engine/agent-config.json)):**
  * Nuove opzioni: `kernel_leak_auto_remediate` (`true`), `kernel_leak_remediate_handles` (`150000`), `kernel_leak_persist_seconds` (`120`).
  * Se `TiWorker` supera `150.000` handle aperti per almeno `120` secondi consecutivi con Non-Paged Pool `>= 1.024 MiB` (cooldown minimo `300s`) e l'agente è in esecuzione come Amministratore, termina automaticamente il processo incastrato e registra l'evento `AUTO-BONIFICA KERNEL`.
* **Sblocco manuale 1-click:** creati [`SBLOCCA_LEAK_TIWORKER.cmd`](SBLOCCA_LEAK_TIWORKER.cmd) e [`engine/fix-tiworker-leak.ps1`](engine/fix-tiworker-leak.ps1) per terminare tramite UAC un processo `TiWorker.exe` con oltre `50.000` handle mostrando i valori di RAM e Kernel Pool prima/dopo.

### 2.6 Diagnostica Windows Servicing (`DIAGNOSI_SERVICING.cmd`)
* Creati [`DIAGNOSI_SERVICING.cmd`](DIAGNOSI_SERVICING.cmd) ed [`engine/diagnose-servicing.ps1`](engine/diagnose-servicing.ps1) per eseguire con elevazione UAC il controllo di `TrustedInstaller`/`wuauserv`, segnali di riavvio in sospeso, `DISM /ScanHealth` (ed eventuale `/RestoreHealth`), `sfc /scannow`, errori recenti in `CBS.log` ed eventi Setup, salvando il report locale in `engine/reports/servicing-diagnosi.txt` (escluso dal tracciamento Git via `.gitignore`).

---

## 3. Riepilogo File Coinvolti

| File | Stato | Funzione Principale |
| :--- | :--- | :--- |
| [`AUTOMATICO.cmd`](AUTOMATICO.cmd), [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) | Modificati | Avvio diretto e stabile di console e Dashboard |
| [`AVVIA_COME_AMMINISTRATORE.cmd`](AVVIA_COME_AMMINISTRATORE.cmd), [`engine/start-elevated.ps1`](engine/start-elevated.ps1) | Aggiunti | Avvio con elevazione UAC pulita e `-NoExit` |
| [`engine/apply-defender-limit.ps1`](engine/apply-defender-limit.ps1) | Aggiunto | Helper UAC per applicare e verificare `Set-MpPreference` |
| [`engine/agent-runtime.ps1`](engine/agent-runtime.ps1) | Modificato | Verifica reale Defender, Watchdog Kernel Pool/Handle e Auto-Bonifica `TiWorker` |
| [`engine/agent-dashboard.ps1`](engine/agent-dashboard.ps1) | Modificato | UAC su click Defender, allerta Kernel Pool/Leak e layout Card 4 |
| [`engine/agent-state.ps1`](engine/agent-state.ps1), [`engine/start-agent.ps1`](engine/start-agent.ps1) | Modificati | Retry I/O concorrente su `status.json`, evidenziazione `[ALLERTA]`/`[AZIONE]` |
| [`engine/agent-config.json`](engine/agent-config.json), [`engine/agent-model.ps1`](engine/agent-model.ps1) | Modificati | Configurazione e stato Watchdog Kernel Pool & Auto-Bonifica |
| [`SBLOCCA_LEAK_TIWORKER.cmd`](SBLOCCA_LEAK_TIWORKER.cmd), [`engine/fix-tiworker-leak.ps1`](engine/fix-tiworker-leak.ps1) | Aggiunti | Utility UAC per sbloccare `TiWorker.exe` con leak di handle |
| [`DIAGNOSI_SERVICING.cmd`](DIAGNOSI_SERVICING.cmd), [`engine/diagnose-servicing.ps1`](engine/diagnose-servicing.ps1) | Aggiunti | Diagnosi Windows Servicing (`DISM`, `SFC`, `CBS.log`) |
| [`engine/build/windows-validation.json`](engine/build/windows-validation.json) | Modificato | Checksum SHA-256 aggiornati dopo validazione R22 |
| [`.gitignore`](.gitignore) | Modificato | Esclusione report `.txt` locali in `engine/reports/` |
| [`README.md`](README.md), [`README_IT.md`](README_IT.md) | Modificati | Badge e parole chiave/topic di indicizzazione |
