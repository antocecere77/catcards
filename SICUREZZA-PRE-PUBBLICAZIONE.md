# CatCards — Messa in sicurezza pre-pubblicazione

> Tappa OBBLIGATORIA prima di aprire l'app al pubblico o metterla su uno store.
> Non urgente finché i giocatori sono cerchia ristretta (Antonio, Lia) + bot: in quella fase
> il modello "client-autoritativo" è godibile e non fa danni. Diventa indispensabile con utenti sconosciuti.

## Principio di fondo
Oggi il telefono **dichiara** al server ("ho vinto", "aggiungimi punti") e il server si fida.
Obiettivo: il telefono **chiede** e il server **decide**. Cambiato questo, gran parte dei buchi sparisce.

## Cosa è GIÀ solido (non toccare)
- Accesso Google/Supabase: JWT firmati, non falsificabili.
- Gate admin (`auth.jwt() ->> 'email'`): verificato server-side, a prova di manomissione.
- Chiave Gemini: ognuno usa la propria, nel proprio browser (nessuna chiave condivisa da proteggere).
- Bucket Storage audio pubblico = sola lettura per il mondo, scrittura solo admin: NON è una falla (asset di gioco, come il CDN suoni di qualsiasi videogioco).

## I 3 punti da chiudere

### 1. Risultati e punteggio autoritativi lato server  (il pezzo grosso)
- **Edge Function `/fight`**: il client chiede "fai combattere X vs Y"; il server:
  1. carica le carte dal DB (statistiche vere);
  2. verifica eligibilità (proprietà, riposo, ±5, non all'asta, 1 tentativo/giorno boss...);
  3. simula la battaglia con **seme casuale del server**;
  4. applica Elo/punti/strisce/riposo in modo **atomico**;
  5. restituisce vincitore + log dei colpi.
- Il client si limita ad **animare** il log: non decide più nulla → impossibile forgiare vittorie o punti-da-incontro.
- Erba gatta e scommesse = input validati dal server.
- **Costo:** riscrivere ~300 righe di motore battaglia (poteri, mosse, RNG) in TypeScript nella Edge Function.
  Lavoro singolo più grande del progetto (paragonabile al Mercato). Richiede setup una tantum delle Edge Functions / CLI Supabase.

### 2. Rate-limiting e validazione RPC economiche
- **Ritirare `wallet_delta`** come funzione client-callable (oggi chiunque può accreditarsi punti a mano).
- Punti cambiano solo via percorsi controllati: premi incontro (dentro `/fight`), scommesse/aste (già server), codici regalo (già server).
- Premi "di traguardo" client-side (missioni, Catdex, medaglie): **`reward_ledger`** sul server — ogni premio riscuotibile una sola volta, tetto giornaliero. Danno da cheat limitato a poche decine di punti, non infinito.
- **Rate-limiting:** guardie dentro le funzioni (max N incontri/ora, max N operazioni economiche/ora) con tabellina di contatori temporali.

### 3. Passata RLS  (il client non deve scrivere niente "di valore" direttamente)
- **`cards`**: bloccare la PATCH diretta su colonne sensibili (elo, wins, losses, strisce) → si toccano SOLO dalle funzioni server (trigger che blocca modifiche fuori dai definer). Al client resta il cosmetico (pubblica/ritira, soprannome).
- **Orfani reclamabili**: rimuovere (potenziale furto di carte).
- **`trades / auctions / bids / matches`**: insert solo via RPC (revoca insert diretto), letture con scope giusto.
- **`meta`, `profiles`**: già sola lettura client — confermare.

## Sequenza e tempi
- Ordine: **1 → 3 → 2** (prima la battaglia sul server rende autoritativi risultati + punti-incontro; poi si chiudono le porte RLS; infine tetti sui premi residui e rate-limiting).
- Stima: **2-3 sessioni dedicate**, il grosso sul punto 1.
- Prerequisito manuale (Antonio): attivare le Edge Functions su Supabase / installare la CLI (guida al momento).

## Stato: DA FARE — pre-pubblicazione
