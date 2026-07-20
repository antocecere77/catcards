# CatCards — Piano Multilingua (IT · EN · FR · ES · DE)

## Decisioni prese
- Lingua rilevata dal dispositivo, **default inglese**, cambiabile da ⚙️ Opzioni.
- **Scelta B**: pregresso uniformato — soprannomi e descrizioni da lista fissa per TUTTE le carte, in tutte le lingue. Testi e voci AI dei pregressi vanno in pensione.
- **Soprannomi**: lista fissa di 80 (i 21 storici + 59 nuovi), traduzioni parallele nelle 5 lingue (stessa identità ovunque). Auto-assegnato dal seriale, **modificabile** dalla scheda carta scegliendo dalla lista.
- **Descrizioni buffe**: lista fissa di 50 ×5 lingue, assegnate dal seriale.
- **Nomi propri dei gatti**: mai tradotti.
- **Audio a mattoncini**: annuncio montato da 3 pezzi — frasi fisse (per lingua, globali) + soprannome (globale, condiviso) + nome (unico file per carta, riusato in ogni lingua). File condivisi su Supabase Storage, generati una tantum dall'admin. Costo marginale per carta nuova: 1 clip di una parola.
- **Niente AI a runtime per i testi**. L'AI resta per: disegno carta, analisi foto (statistiche/razza), ritratti personaggi/boss, generazione una tantum dei mattoncini audio.

## Tappe (ognuna è una release autonoma)

### Tappa 1 — Motore lingua + carta + liste
- Rilevamento lingua, salvataggio, selettore in ⚙️.
- Dizionario centrale T() e infrastruttura.
- Carta ridisegnata in lingua (nomi statistiche, rarità, HP).
- Liste complete: 80 soprannomi ×5 e 50 descrizioni ×5.
- Assegnazione deterministica dal seriale + editor soprannome nella scheda carta.
- Migrazione scelta B: le carte esistenti passano alla lista (ridisegno + ripubblicazione automatica).
- Annuncio scritto da template in lingua.

### Tappa 2 — Interfaccia essenziale
- Menu, schede, pulsanti, toast, errori, schermata 🔒 e barra utente ×5 lingue.
- Da qui l'app è usabile da un non-italiano.

### Tappa 3 — Audio a mattoncini
- Azione manuale (2 min): creare il bucket pubblico `audio` su Supabase Storage.
- Pulsante admin «🎙️ Genera audio globali»: frasi fisse ×5 + 80 soprannomi ×5 → upload su Storage (una tantum, pochi €).
- Clip-nome per carta: alla creazione + pulsante admin «genera nomi mancanti» per il pregresso e i bot.
- playAnnuncio a montaggio (frase → nome → soprannome) con pause da annunciatore.
- Bonus: si sentono anche gli annunci di avversari e bot.

### Tappa 4 — Telecronaca + personaggi + regole
- ~80 frasi di battaglia ×5, con 3-4 varianti sulle frasi chiave.
- I 5 personaggi (Zio Rocco, Mister Felini, Coach Baffo, Mister Baratto, Mister Incanto) con personalità resa in ogni lingua.
- Regole complete, missioni, medaglie, Catdex, cibi e minigiochi ×5.

### Tappa 5 — Boss e mondo misto
- 64 boss: nomi, soprannomi e storie ×5 (i boss sono personaggi: si traducono).
- Annunci boss coi mattoncini.
- Le carte altrui si vedono nella lingua di chi guarda (soprannome/descrizione dal numero di lista, non dal testo).

## Costi una tantum stimati
- ~415 clip globali (frasi + soprannomi ×5) + ~70 clip-nome (pregresso + bot): pochi euro in totale.
- A regime: 1 clip-nome per carta nuova (centesimi ogni 100 carte).

## Cosa non cambia
Statistiche, Elo, economia, tabelle server (nick/descr sono già colonne): la lingua è presentazione.
