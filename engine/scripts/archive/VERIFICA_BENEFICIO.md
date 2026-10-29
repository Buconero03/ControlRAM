# Verificare se AME aggiunge un beneficio

La R20 integra il confronto nel normale pannello, nella sezione **Verifica beneficio**. Non serve avviare DEMO_API.cmd. Il confronto non modifica Job Object, quote o priorita e non esegue EmptyWorkingSet. La sola azione e lo scaricamento, confermato da te, di 1-5 schede attraverso l'estensione gia collegata.

## Procedura

1. Chiudi il vecchio pannello, aggiorna i file nella stessa cartella e apri **AVVIA.cmd**. Conserva build, reports ed exports. Se la build R19 e gia validata viene riutilizzata; il pannello R20 e il nuovo lettore vengono verificati. L'estensione resta 0.4.1/protocollo 4.
2. In **Rilascio nelle app**, collega Chrome o Firefox. Attendi lo stato COLLEGATO con l'elenco delle schede. Se necessario usa Prepara collegamento browser. Questo collegamento non riduce da solo la RAM.
3. In Chrome attiva **Impostazioni > Prestazioni > Risparmio memoria**. Scegli un livello e mantienilo uguale nelle due fasi. Firefox usa la propria gestione nativa: mantieni la stessa configurazione. Il programma registra la tua conferma delle impostazioni, ma non le verifica automaticamente.
4. Apri **Verifica beneficio**, premi **Aggiorna profili e schede** e scegli il profilo. Spunta 1-5 schede disponibili e ricaricabili, senza lavoro da salvare. Le schede protette o gia scaricate non sono selezionabili. ChatGPT e Claude sono protetti dall'estensione per impostazione predefinita.
5. Nel campo **Attivita da ripetere** descrivi il lavoro delle due fasi, ad esempio: "Chrome Risparmio memoria Massimo; ChatGPT e YouTube in uso; cinque articoli inattivi". Conferma le due caselle.
6. Premi **1. Misura senza interventi**. Per 15 minuti AME misura, senza chiedere scaricamenti. Il browser conserva il proprio comportamento automatico. Lascia inattive le schede scelte e mantieni lo stesso insieme di pagine e applicazioni. Il tempo residuo e visibile.
7. Dopo la fase 1 premi, entro 5 minuti, **2. Scarica e misura**. Il clic autorizza lo scaricamento delle sole schede scelte e ancora idonee. Ogni richiesta attende la conferma prima della successiva; non ci sono retry. Le protezioni e la revisione della pagina vengono ricontrollate anche dall'estensione. Se il browser ha gia scaricato tutte le schede, AME dichiara che non c'e altro da scaricare.
8. Dopo le conferme iniziano altri 15 minuti di sola misura. Il pannello mostra le letture aggiornate ogni circa 5 secondi. **Annulla confronto** ferma nuove richieste; una richiesta gia inviata puo completarsi e la sua conferma viene comunque registrata.
9. Leggi l'esito e poi torna alle schede. Il tempo segnalato dal browser fino al caricamento completato viene aggiunto al report, quando disponibile. Non misura la prontezza di ChatGPT o di un'altra app web, ne viene confrontato con una latenza iniziale misurata.
10. **Esporta confronto** crea uno ZIP con il risultato e i campioni. E disponibile anche mentre la prova e in corso. La normale **Esporta diagnosi** include anche i report comparison recenti.

I 30 minuti sono due finestre di osservazione: il comando di scaricamento non viene eseguito per 30 minuti. Il confronto continua anche quando l'inventario ordinario termina dopo dieci minuti o viene messo in pausa. Gli altri interventi del pannello restano bloccati durante entrambe le fasi e nell'attesa della fase 2. Il mutex condiviso impedisce avvii concorrenti dei controller nativi AME nella stessa sessione Windows.

## Cosa misura il risultato

- Memoria privata residente aggregata di tutti i processi del browser nella stessa sessione Windows, inclusi altri profili aperti. Non attribuisce MB alla singola scheda.
- Consumo privato residente del pannello PowerShell e dei processi ame.exe / ame-browser-host.exe di questa installazione. I percorsi sono verificati. La memoria condivisa non viene conteggiata come costo privato.
- L'estensione e inclusa nel browser in entrambe le fasi. L'osservatore AME e presente anche nella fase iniziale: non e un benchmark del browser con AME completamente assente.
- Mediane degli ultimi cinque minuti delle due fasi. La differenza netta osservata sottrae **per intero** il costo privato residente misurato di AME nella seconda fase: e un budget conservativo, non una stima causale del risparmio fisico del PC.
- Per la soglia pratica di 500 MiB, tutti i campioni dei quindici minuti dopo l'azione devono essere almeno 500 MiB sotto il minimo dell'ultimo tratto della fase 1, includendo il costo di AME. Un picco di ricrescita impedisce il superamento della soglia, anche se le letture finali sono basse.
- Commit del browser e variazione della RAM disponibile del PC rimangono separati. Quest'ultima risente delle altre applicazioni.
- CPU normalizzata sull'intero PC, page fault totali e letture I/O del browser: mediane finali e picchi campionati nelle due fasi. Se cambiano identita dei processi, i contatori cumulativi non vengono sottratti tra processi diversi. Dati insufficienti rimangono N/D.

Gli avvisi di attivita sono segnali pratici: aumento della mediana CPU oltre 1 punto percentuale, fault oltre 100/s o letture oltre 1 MiB/s; oppure picchi superiori alla fase iniziale di 5 punti CPU, 1000 fault/s o 4 MiB/s. Non sono soglie scientifiche di rallentamento. I page fault includono soft e hard, le letture I/O comprendono altre operazioni oltre al disco e i picchi tra campioni possono sfuggire. Non si misura la latenza dell'app o il costo completo della riattivazione. Nessun esito certifica maggiore velocita.

## Quando il confronto viene interrotto

Cambio o chiusura delle pagine, sessione del collegamento cambiata, elenco non aggiornato, campioni distanti oltre 12 secondi, sospensione o tempo inverso, metriche mancanti, browser scomparso, scrittura del report fallita, rifiuto o conferma assente. La riapertura anticipata di una scheda interrompe la misura della durata e attiva il blocco di 30 minuti per quella scheda/sessione gia usato dal pannello. Un risultato arrivato dopo annullamento o timeout viene registrato senza riprendere la coda.

## Come decidere se continuare

Un solo confronto prima/dopo registra un'osservazione, non isola tutte le cause. Il processo puo cambiare anche per il comportamento nativo del browser. Un calo del browser non prova un equivalente risparmio fisico dell'intero computer.

Ripeti almeno tre volte con le stesse pagine, impostazioni e attivita, includendo una sessione con molte schede inattive e una con il tuo lavoro abituale. Dopo ogni prova ripristina manualmente le pagine che vuoi includere nella successiva. Valuta il caricamento al ritorno e la reattivita effettiva. La R20 non abilita ottimizzazioni automatiche sulla base di un singolo confronto e non aggrega prove con carichi diversi come se fossero identiche.

Per ChatGPT e Claude desktop resta indicato **Nessun rilascio interno integrato**. Il nuovo confronto non dimostra una riduzione dei loro consumi e non aggiunge una API universale di liberazione delle cache.

I report sono locali, limitati a 4 MiB per confronto, e contengono anche identita/percorso dei processi, titoli delle schede scelte e descrizione delle attivita. Non vengono inviati automaticamente alla chat o a servizi esterni.
