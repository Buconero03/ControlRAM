# ControlRAM (v0.5.0 R22)

> **Architettura di Ottimizzazione Dinamica Multi-Lane per la Memoria RAM e la CPU su Windows 10 e Windows 11.**

**Lingua / Language:** [Italiano](README.md) | [English](README_EN.md)

[![Stato Progetto](https://img.shields.io/badge/Stato-Sperimentale%20%2F%20In%20Sviluppo-orange.svg)](#-dichiarazione-sullo-stato-sperimentale)
[![Piattaforma](https://img.shields.io/badge/OS-Windows%2010%20%7C%20Windows%2011%20x64-blue.svg)](#requisiti-di-sistema)
[![Core Nativo](https://img.shields.io/badge/Core-C%2B%2B20%20Native%20DLL-green.svg)](#architettura-del-software)
[![Interfaccia](https://img.shields.io/badge/UI-WinForms%20Lightweight%20Dashboard-purple.svg)](#come-avviare-il-progetto)
[![Efficacia Riscontrata](https://img.shields.io/badge/RAM%20Liberata-20%25%20--%2030%25%20Reale-brightgreen.svg)](#riscontro-reale-sul-campo-e-benefici-misurati)

---

## ⚠️ DICHIARAZIONE SULLO STATO SPERIMENTALE

> [!WARNING]
> **ATTENZIONE: PROGETTO SPERIMENTALE E NON ANCORA STABILE.**
> AdvancedMemoryEngine (AME) è attualmente un **progetto sperimentale (versione preview 0.5.0 R22)** e **NON è ancora considerato un software stabile o definitivo**.
> 
> * **Efficacia reale riscontrata sul campo:** Il software è attualmente in uso quotidiano attivo e dimostra un'efficacia tangibile, riuscendo a **ridurre la RAM tra il 20% e il 30%** a seconda del numero e della tipologia dei processi ottimizzati.
> * **L'incognita aperta sul lungo periodo (CPU e API interne):** Sebbene il beneficio sulla memoria sia concreto e misurabile, **non è ancora chiaro se tutto questo ciclo continuo di compattazione e demotion possa, alla lunga andare, avere effetti negativi o causare affaticamento/stress al processore (CPU), oppure provocare instabilità in qualche API o runtime interno di Windows.**
> * Chiunque decida di provare o adottare AME lo fa in un contesto di sperimentazione attiva, con la consapevolezza che si tratta di un lavoro di ricerca aperto e che gli effetti sul lungo termine sono ancora oggetto di studio e osservazione.

---

## 💡 Perché Esiste AME e Cosa Fa

Sui moderni sistemi operativi Windows, è frequente trovarsi con la memoria RAM fisica satura (85%–95%) anche disponendo di 16 GB o 32 GB. Questo accade perché:
1. **Applicazioni Desktop in background** (client di messaggistica, agenti AI, app UWP, servizi) continuano a trattenere megabyte o gigabyte di memoria operativa (*Working Set*) anche quando l'utente non le utilizza da ore.
2. **I Browser web moderni (Chrome, Edge, Firefox)** creano decine di sottoprocessi dedicati (renderers, GPU, audio, utility) che occupano porzioni massive di memoria residente.
3. **Macchine Virtuali e Container (WSL2 / `vmmemWSL` / Docker)** accumulano file di cache del kernel Linux che per impostazione predefinita non vengono restituiti a Windows, arrivando a divorare da soli oltre 2–3 GB di RAM.
4. **La Memoria Compressa del kernel Windows NT** agisce come barriera protettiva contro il crash da disco, ma quando la RAM supera l'88–90% si blocca per autodifesa, impedendo qualsiasi liberazione spontanea.

**AME non è un pulitore di RAM convenzionale** (che invoca ciecamente comandi distruttivi o svuota la cache di sistema a caso causando rallentamenti). AME è un **motore decisionale Multi-Lane** che osserva costantemente il sistema e interviene con intelligenza gerarchica:
* Compatta la memoria dei soli processi inattivi da lungo tempo;
* Abbassa la priorità di scheduling della CPU tramite **EcoQoS** solo per compiti di sfondo;
* Rispetta e protegge l'applicazione attiva in primo piano;
* Ripristina istantaneamente priorità e memoria non appena l'utente torna a interagire con un'applicazione.

---

## 📊 Riscontro Reale sul Campo ed Efficacia Misurata

> [!IMPORTANT]
> **Testimonianza e Risultati nell'Uso Quotidiano:**
> Nel normale utilizzo sul campo su macchine da lavoro e sviluppo con 16 GB di RAM e decine di processi aperti:
> * Si registra costantemente un **abbattimento della pressione RAM compreso tra il 20% e il 30%** rispetto al valore di partenza a parità di programmi aperti.
> * Su una macchina con RAM al 90% (~14.4 GB occupati), l'intervento coordinato del motore riporta tipicamente la memoria occupata tra il **65% e il 72%**, liberando istantaneamente da **2.5 a oltre 4.0 Gigabyte di memoria fisica reale**.
> * Nei sistemi con WSL2 / Docker attivi, la combinazione tra AME e lo scaricamento della cache Linux (`drop_caches`) ha dimostrato il recupero di **oltre 1.900 MB di RAM** da un singolo processo virtuale (`vmmemWSL`).
> 
> **Il rovescio della medaglia:** Nonostante questo guadagno effettivo prevenga l'eccessivo paging su disco e restituisca respiro al sistema, la natura sperimentale del software impone cautela: non possiamo ancora dare per scontato che questo continuo lavoro di riorganizzazione della memoria sia privo di effetti collaterali a lungo termine sul processore o sulle API del sistema operativo.

---

## 🔍 Analisi Tecnica: Il Comportamento del Processore (CPU) e le Incognite sulle API Interne

Poiché il programma interviene a basso livello sul sistema operativo, è fondamentale analizzare con la massima trasparenza sia ciò che è noto a livello architetturale, sia **i dubbi e le incognite aperte che solo il tempo e test prolungati potranno chiarire**.

### 1. Cosa Sappiamo sull'Hardware e sui Guard Rail
* **Integrità fisica della CPU:** A livello fisico di silicio, un'applicazione in User Mode non può "bruciare" o rompere un microprocessore moderno (Intel Core / AMD Ryzen), in quanto i circuiti hardware interni (PROCHOT, sensori termici e regolatori di voltaggio) impediscono sovratensioni o temperature fuori specifica. AME non modifica tensioni né frequenze.
* **Le API Ufficiali Utilizzate:** Il motore non inietta DLL esterne né installa driver kernel instabili, ma si affida a funzioni Win32 documentate da Microsoft (`SetProcessWorkingSetSizeEx`, `SetPriorityClass`, `SetProcessInformation`, `GlobalMemoryStatusEx`).
* **La modalità EcoQoS:** L'abbassamento della priorità per i processi di sfondo idonei sfrutta l'Efficiency Mode di Windows 11, indirizzando i compiti non prioritari verso i core ad alta efficienza (E-core) per ridurre teoricamente calore e wattaggio.
* **I Guard Rail di protezione:** Per impedire che i processi vengano compattati all'infinito (thrashing), AME adotta cooldown forzati da 120s a 600s, controlli di inattività e l'esclusione categorica della finestra in primo piano.

### 2. ⚠️ Le Incognite Aperte: Cosa NON è ancora chiaro a lungo andare

Nonostante le protezioni e la conformità alle API standard, trattandosi di un progetto **sperimentale e non ancora stabile**, rimangono aperte questioni cruciali su cui non esistono ancora risposte certe:

1. **Possibile affaticamento o sovraccarico dello scheduler CPU:**
   Anche se EcoQoS mira al risparmio energetico, il continuo cambio di stato di priorità, lo spostamento di thread tra P-core ed E-core e la gestione ciclica di centinaia di processi potrebbero, alla lunga andare, generare un carico "nascosto" o micro-ritardi nello scheduler del kernel Windows, con un impatto complessivo sulla CPU ancora da quantificare nel tempo.
2. **Reattività e usura delle API interne dei programmi di terze parti:**
   Non tutte le applicazioni desktop o i framework software (Electron, runtime .NET, JVM, motori grafici) sono progettati per subire continui svuotamenti forzati del proprio Working Set. Non è chiaro se richiamare ripetutamente queste API interne possa, a lungo termine, provocare comportamenti anomali, micro-blocchi, *memory leak* secondari o instabilità interna nei processi gestiti.
3. **Cicli cumulativi di Page Fault e memoria virtuale:**
   Ogni volta che la memoria di un processo viene compattata, se quel processo si risveglia improvvisamente deve ricaricare le proprie pagine. Se questo ciclo dovesse ripetersi con troppa frequenza su determinati carichi, l'aumento cumulativo di page fault potrebbe gravare sulla CPU e sul sottosistema di memoria virtuale.

> [!CAUTION]
> **Conclusioni sulla sicurezza:**  
> AME riesce effettivamente a liberare il 20–30% di RAM ed è un alleato prezioso contro la saturazione della memoria, ma **la sua natura sperimentale richiede consapevolezza**: gli effetti sul medio-lungo periodo sul processore e sull'ecosistema di API interne di Windows rimangono un campo di indagine aperto. L'utilizzo è consigliato a utenti consapevoli, appassionati e sviluppatori disposti a monitorare e condividere feedback.

---

## 🏛️ Architettura a 5 Corsie (Multi-Lane Engine)

```
┌────────────────────────────────────────────────────────────────────────┐
│                   AdvancedMemoryEngine (AME v0.5.0 R22)                 │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
       ┌─────────────────────────────┼─────────────────────────────┐
       ▼                             ▼                             ▼
┌──────────────┐              ┌──────────────┐              ┌──────────────┐
│    LANE 1    │              │    LANE 2    │              │    LANE 3    │
│  Windows OS  │              │ Dev Runtimes │              │  Subprocessi │
│  Background  │              │  & Language  │              │   Browser    │
│  Processes   │              │   Servers    │              │ (OS Level)   │
└──────┬───────┘              └──────┬───────┘              └──────┬───────┘
       │                             │                             │
       ▼                             ▼                             ▼
 [Stage 14 Trim]               [Stage 10 Trim]               [Stage 10 Trim]
 Priority: VeryLow             Priority: Low                 Working Set Trim
 EcoQoS: Attivo                EcoQoS: ESCLUSO               Zero Estensioni
 Memory: Trim WS               (Zero Lag su IDE)             Autonomo al 100%
       │                             │                             │
       └─────────────────────────────┼─────────────────────────────┘
                                     │
       ┌─────────────────────────────┴─────────────────────────────┐
       ▼                                                           ▼
┌──────────────┐                                            ┌──────────────┐
│    LANE 4    │                                            │    LANE 5    │
│  Web Tabs    │                                            │ Virtual VM & │
│ (Estensione) │                                            │ Linux / WSL2 │
└──────┬───────┘                                            └──────┬───────┘
       │                                                           │
       ▼                                                           ▼
 Tab Discarding                                              `drop_caches`
 Domini Autorizzati                                          `autoMemoryReclaim`
 Salvataggio Dati                                            `vmmemWSL` Trim
```

1. **Lane 1 — Processi Windows di Sfondo (Stage 14):**
   Interviene su software desktop, app AI e servizi in background (es. `chatgpt.exe`, `claude.exe`, `searchhost.exe`, app UWP), riducendone il working set e attivando EcoQoS.
2. **Lane 2 — Runtime di Sviluppo & IDE (Stage 10):**
   Riconosce selettivamente ambienti come `python.exe`, `node.exe`, `language_server.exe`, `antigravity.exe`, `code.exe`, `pwsh.exe`. Compatta la memoria ma **non attiva il throttling CPU**, garantendo che la compilazione e l'autocompletamento non subiscano mai rallentamenti.
3. **Lane 3 — Sottoprocessi Browser a livello OS:**
   Monitora autonomamente i processi figli di Chrome, Edge, Firefox e Brave (schede di rendering inattive, utility, crashpad) liberando memoria senza richiedere alcuna estensione installata.
4. **Lane 4 — Ibernazione Schede Web (Tab Discarding via Estensione):**
   Corsia opzionale che usa il Native Messaging Host per comunicare con l'estensione AME su Chrome o Firefox. Consente di ibernare le singole pagine web inattive da oltre 15 minuti, solo per i siti esplicitamente autorizzati dall'utente.
5. **Lane 5 — Ambienti di Virtualizzazione (WSL2 / Docker / `vmmemWSL`):**
   Interagisce con il sottosistema Linux e Hyper-V per forzare lo svuotamento della cache disco interna (`drop_caches`), recuperando gigabyte di RAM trattenuti da container e distribuzioni Linux.
6. **Modalità Gioco (RAM Clamping Mix A+B):**
   Consente di selezionare un processo bersaglio particolarmente avido di memoria e imporre un limite rigido (*Clamp*) in MiB tramite un mix dinamico di compattazione e monitoraggio continuo.

---

## 🚀 Come Avviare il Progetto

Il progetto è strutturato per essere avviato tramite semplici script `.cmd` situati nella directory principale, senza necessità di configurazioni complesse.

### Requisiti di Sistema
* **Sistema Operativo:** Windows 10 (64-bit) Build 19041+ o Windows 11 (consigliato).
* **Shell:** Windows PowerShell 5.1 (inclusa in Windows) oppure PowerShell 7+.
* **Compilatore (solo per prima compilazione o modifiche al codice C++):**
  * Microsoft Visual Studio 2022 (con carico di lavoro "Sviluppo desktop con C++") oppure MinGW-w64 (GCC 11+).
  * *Nota: Se la DLL nativa `build/ame.dll` è già presente e validata, la compilazione viene saltata automaticamente.*

---

### File di Avvio Principali

| File | Modalità | Descrizione |
| :--- | :--- | :--- |
| [`AUTOMATICO.cmd`](AUTOMATICO.cmd) | **Motore Background (Daemon)** | Avvia il cuore pulsante di AME in una finestra di console. Monitora costantemente la telemetria di memoria e CPU, applica gli interventi di bilanciamento e scrive lo stato in tempo reale. Può essere lasciato ridotto a icona. |
| [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) | **Cruscotto Grafico (Dashboard GUI)** | Apre l'interfaccia grafica moderna ad altissima efficienza (WinForms a tema Deep Cyber Slate, consumo <25 MB di RAM). Mostra 5 card KPI (incluso l'uso totale della CPU di sistema), la tabella dei processi ottimizzati e i pulsanti d'azione rapida. |
| [`engine/AVVIA.cmd`](engine/AVVIA.cmd) | **Bootstrap & Validazione** | Esegue la suite completa di verifica della build nativa e dei test di integrità (83 controlli automatici). Utile dopo modifiche al codice sorgente. |

### Procedura Consigliata per il Primo Utilizzo:
1. Fai doppio clic su [`AUTOMATICO.cmd`](AUTOMATICO.cmd) per avviare il motore di monitoraggio in background.
2. Fai doppio clic su [`STATO_AUTOMATICO.cmd`](STATO_AUTOMATICO.cmd) per aprire la dashboard visiva.
3. Dalla Dashboard puoi:
   * Monitorare la percentuale di RAM e CPU usata in tempo reale;
   * Cliccare su **"Ottimizza Ora"** per un recupero immediato di memoria su tutti i processi inattivi;
   * Cliccare su **"Svuota Compressione"** per liberare la memoria compressa del kernel;
   * Cliccare su **"Modalità Gioco (Clamp)"** per bloccare la RAM di un processo specifico;
   * Cliccare su **"Ferma e Ripristina"** per chiudere AME e ripristinare istantaneamente tutti i processi alle priorità standard di Windows.

---

## 🛠️ Configurazione Consigliata per WSL2 / Docker

Se utilizzi Docker Desktop o WSL2 (Ubuntu, Debian, ecc.), crea o modifica il file `.wslconfig` nella tua cartella utente (`C:\Users\<TuoUtente>\.wslconfig`):

```ini
[wsl2]
# Tetto massimo invalicabile di RAM per la VM (evita che superi 1.8 GB)
memory=1.8GB
# Limita i core virtuali assegnati a Linux
processors=6
# Dimensione dello swap su disco
swap=2GB
# Funzione nativa di Windows 11: sgonfia gradualmente la cache quando i container tornano inattivi
autoMemoryReclaim=gradual
# Rilascia anche lo spazio su disco virtuale (VHD) non utilizzato
sparseVhd=true
```

Dopo aver salvato il file, apri un prompt dei comandi ed esegui `wsl --shutdown` per rendere attive le nuove impostazioni.

---

## ❓ Domande Frequenti (FAQ)

#### D: La dashboard dice "Osservo tutti i processi; attendo pressione RAM persistente. Nessun intervento necessario o ancora idoneo." Si è bloccato?
> **R:** No, è il normale stato di riposo (*standby*). AME interviene solo quando la RAM supera la soglia di guardia (configurabile, predefinita 80–85%) e rimane sopra la soglia per almeno 30 secondi. Se i processi idonei sono già stati ottimizzati di recente, AME li protegge con un periodo di cooldown per non stressare la CPU.

#### D: Se chiudo la Dashboard, AME continua a funzionare?
> **R:** Sì. La finestra grafica (`STATO_AUTOMATICO.cmd`) è un visualizzatore indipendente. Il motore vero e proprio continua a girare nella finestra console di `AUTOMATICO.cmd`. Se chiudi anche la console, il monitoraggio si arresta.

#### D: Come posso disinstallare o rimuovere AME?
> **R:** AME è completamente **portabile (portable software)**. Non scrive chiavi nascoste nel Registro di sistema e non installa servizi permanenti. Per rimuoverlo, basta cliccare su "Ferma e Ripristina" (o chiudere i file `.cmd`) ed eliminare la cartella. Tutti i processi tornano immediatamente al loro stato originale di Windows.

---

## 📄 Licenza e Note Legali

Questo progetto è distribuito sotto licenza aperta per scopi di studio, test e benchmark di efficienza del sistema operativo Windows.

*Microsoft, Windows, Windows NT, Hyper-V e WSL sono marchi registrati di Microsoft Corporation.*  
*Google Chrome è un marchio registrato di Google LLC. Mozilla Firefox è un marchio registrato di Mozilla Foundation.*
