# OBS Touch Control

Pannello di controllo touch per OBS Studio, scritto in Rust con GTK4 + libadwaita.
Comunica con OBS tramite il server WebSocket integrato (protocollo v5, OBS ≥ 30.2).

## Funzioni

- **Pannello**: schermata personale con pulsanti grandi scelti da te, mescolando scene,
  scorciatoie e muto delle sorgenti audio. *Modifica* → aggiungi (+), sposta (◀ ▶),
  rinomina (✎), rimuovi (🗑). Stato live: scena in onda/anteprima, sorgente silenziata.
- **Scene**: griglia di riquadri; tocco = passa alla scena (in Studio Mode imposta l'anteprima).
  Scena in onda in rosso, anteprima in verde.
- **Controlli**: diretta, registrazione (+ pausa), camera virtuale, replay buffer (+ salva),
  Studio Mode e transizione. Timer live su diretta e registrazione, conferma opzionale prima dello stop.
- **Scorciatoie**: tutte le hotkey esposte da OBS, raggruppate e ricercabili, con preferiti (★).
  Le hotkey registrate per singola sorgente (muto, mostra/nascondi elemento, ...) aprono un
  selettore della sorgente.
- **Audio**: fader del volume e pulsante muto per ogni sorgente audio.
- Riconnessione automatica, schermo intero (F11), aggiornamento manuale (F5).

## Layout responsive

Tutte le griglie sono `GtkFlowBox` omogenei: il numero di colonne si ricalcola a ogni
ridimensionamento come larghezza disponibile ÷ larghezza minima del riquadro.

- La larghezza minima è definita in `src/style.css` per tre densità (Impostazioni →
  *Dimensione riquadri*: piccoli / medi / grandi).
- Sotto i 640sp la finestra entra in modalità `compact`: riquadri più piccoli, margini ridotti,
  selettore delle pagine in basso.

## Requisiti

- Rust (edition 2024), GTK ≥ 4.12, libadwaita ≥ 1.6 (pacchetti di sviluppo)
- In OBS: *Strumenti → Impostazioni server WebSocket → Abilita server WebSocket*

## Installazione (desktop app)

```sh
./install.sh             # compila e installa in ~/.local (binario, icona, voce di menu)
./install.sh --uninstall # rimuove
```

Poi avvia **OBS Touch Control** dal menu applicazioni. Per provarla senza installare:
`cargo run --release`.

Configurazione salvata in `~/.config/obs-touch-control/config.json` (permessi 0600;
la password WebSocket è salvata in chiaro).

## Limiti noti

- Le hotkey *push-to-talk* / *push-to-mute* sono nascoste: l'API di OBS simula pressione e
  rilascio istantanei, quindi non servono a nulla.
- L'API WebSocket espone solo il **nome interno** delle hotkey, non la descrizione mostrata in
  OBS. Plugin come Advanced Scene Switcher appaiono quindi come "Macro trigger hotkey 1" ecc.:
  tieni premuto (o clic destro) su un riquadro per **rinominarlo**.
- Per le hotkey per sorgente il selettore propone tutte le sorgenti/scene plausibili; se una
  sorgente non ha quella hotkey OBS risponde con un errore (mostrato come notifica).

## Licenza

[MIT](LICENSE): puoi usare, modificare, fare fork e ridistribuire liberamente, anche per scopi commerciali, mantenendo la nota di copyright.
