# User preferences

How the user (Mattia, MatrixDJ96) wants to collaborate. These are observed
patterns from the porting session 2026-05-01 / 2026-05-02 and explicit
statements. Update as new preferences emerge.

## Communication

- **Italiano è la lingua primaria**. Tutto il dialogo assistente↔user è in
  italiano. Identifier di codice (variabili, package names, file paths,
  command flags) restano in inglese — non tradurli mai.
- **Diacritiche obbligatorie**: scrivere `però`, `città`, `così`, mai
  `pero`, `citta`, `cosi`. Vale per ogni testo italiano (commit messages
  e doc inclusi se in italiano — usiamo inglese per i doc tecnici per
  convenzione internazionale).
- **`★ Insight` blocks** (con il quadro Unicode e le linee orizzontali) per
  contenuto educativo / esplicativo:
  ```
  ★ Insight ─────────────────────────────────────
  [2-3 punti chiave specifici al codebase / al cambiamento appena fatto]
  ─────────────────────────────────────────────────
  ```
  Non usare per scopi banali. Usa quando una scelta merita di essere
  motivata o quando spieghi un meccanismo non ovvio.
- **Tono terso, ma rigoroso**. Niente paragrafi di scusa o auto-apologia.
  Quando sbagliato → ammetti in una frase, fixa, vai avanti.

## Metodologia

- **Surgical, una cosa per volta**. Il piano `2026-05-01-aurora-dx-style-
  porting.md` è suddiviso in 9 fasi proprio per questo. Ogni Phase tocca un
  dominio. Non infilare 3 domini in una commit.
- **Pre-flight locale prima del push**. L'utente ha PC e rete a casa che
  reggono pre-flight in 3-5 min — quasi sempre vale la pena spenderli per
  evitare 6 job CI rossi (15 min total, costo CI minutes pubblici).
- **Pausa per conferma utente prima di azioni non reversibili**: ogni
  `git push`, `podman rmi`, `gh release`, `git reset` deve avere una
  conferma esplicita. Non auto-eseguire.
- **Fix-forward, niente debt**: quando emerge un'issue durante una review
  o per una domanda dell'utente, fixarla **subito** in un commit separato
  (Conventional Commits `refactor(...)`), non lasciar accumulare.
- **Skip quando l'upstream lo fa meglio**: la Phase 5 (Cockpit) è il caso
  canonico — Bazzite ship cockpit come container quadlet, infinitamente
  meglio di quanto produrremmo noi. Saltare è una vittoria, non una
  rinuncia.

## Standard di qualità

- **Verifica claim upstream leggendo il codice**, non i commenti. Il
  bazzite-dx `vscode.repo gpgcheck=0` aveva un `FIXME` decennale che il
  reale codice F44/dnf5 ha già risolto — l'utente avrebbe scoperto solo
  rebuildando. Il pattern "leggi il codice, fai un test rapido" è la
  difesa.
- **Niente bypass di safety**: mai `|| true` per nascondere errori, mai
  `--no-verify`, mai `--force`, mai `rm -rf /var`. Se un step fallisce è
  perché c'è un bug — debug, non workaround.
- **Better than upstream when possible**: bazzite-mx ha ora 17 vantaggi
  documentati su bazzite-dx (vedi
  [`wins-over-upstream.md`](wins-over-upstream.md)). Aspirazione: ogni
  Phase aggiunge ≥1 vantaggio reale.

## Decision-making

- **Provenance citation always**. Quando proponi un pacchetto / pattern /
  fix, citare "da Aurora-DX riga X", "da Bazzite-DX file Y", "mia proposta
  basata su Z". L'utente ha pizzicato hallucination di provenance più
  volte; trasparenza = fiducia.
- **Tradeoff esplicito**. Ogni proposta ha trade-off; metterli in tabella
  costo/valore + raccomandazione esplicita ("mio consiglio: X"). Non
  scaricare la decisione lasciando 3 opzioni equivalenti.
- **Concise verdict over long debate**. Quando review trova issue:
  "PROCEED to Phase X" / "FIX FIRST" / "DESIGN DISCUSSION". Niente paragrafo
  di prefazione.
- **Niente default opinionati**: se una scelta è stilistica (font, theme,
  formatter), lasciarla all'utente. AmyOS impone scelte → non è il nostro
  modello. Bazzite-DX stripped di opinioni → è il nostro modello.

## Git / CI

- **Conventional Commits + Co-Authored-By trailer** su ogni commit
  Claude-assistito. Subject ≤ 70 char, body ricco con WHY + scoperte +
  pre-flight outcome.
- **SSH per origin remote** (memoria persistente, è nei `.claude` /
  preferences globali utente).
- **Push solo dopo conferma esplicita** ("vai", "procedi"). Mai pushare
  preemptivamente anche dopo pre-flight verde.
- **Commit splitting per concern**: una feature + una refactor = due
  commit, non uno solo. Granularità migliore per `git revert` futuro.
- **Documentation commits dovrebbero matchare paths-ignore**: `**.md`,
  `LICENSE`, `docs/**` skippano CI. Se un commit "doc" tocca anche file
  fuori da quei pattern (es: `.claude/settings.json`, `.gitignore`),
  CI gira comunque — calcolarlo prima.

## Comportamenti aspettati di Claude

- **Honest about uncertainty**. "Non lo so, lo verifico" è meglio di una
  proposta confidente ma sbagliata.
- **Anticipa le domande di rigore**. L'utente farà sempre "dove l'hai
  preso?" e "perché?". Includere già la provenance nella prima proposta.
- **Run-and-notify, non polling sleep**. Per build/CI lunghi: usare
  `run_in_background: true` e aspettare la notifica del harness. Mai
  loop di sleep.
- **Cleanup dopo verifiche**. Se hai pre-flightato in locale e CI è
  verde, rimuovi l'immagine pre-flight (`podman rmi`) per liberare disk.
  Tieni la base Bazzite cached (riusabile per Phase successive).
- **Aggiorna CLAUDE.md / `.claude/docs/` proattivamente** quando emergono
  nuove convenzioni / gotchas / preferenze. La conoscenza non deve restare
  solo nel transcript — questo è il "auto memory" del progetto.

## Cose specifiche dell'utente

- **Ambiente**: Bazzite (atomic Fedora) come daily driver. Conosce bene
  l'ecosistema ublue.
- **PC potente + fibra a casa**, build locale è economica. Quando in
  trasferta (mobile / mobile internet), preferisce CI-only. Lui lo
  segnala esplicitamente.
- **GitHub username**: MatrixDJ96. Email: mattyro96@gmail.com. Repo
  `MatrixDJ96/bazzite-mx`. Sa esattamente cosa fanno gh CLI / cosign /
  podman / buildah — niente spiegazioni elementari.
- **Apprezza la spiegazione delle scelte** (insight blocks), ma non i
  paragrafi enciclopedici. Misura: 3-5 righe per insight, max.

## Anti-patterns da evitare

- **Non dare proposte come liste senza raccomandazione** ("opzione A, B, C
  — comanda tu" senza dire quale tu raccomandi). L'utente vuole il tuo
  judgement, anche se poi può sovvertirlo.
- **Non shipping in fretta senza verificare provenance**. La Phase 4 v1
  aveva GitKraken come "IDE" — sbagliato semanticamente. Una passata di
  "is this actually correct taxonomy?" prima del commit l'avrebbe colto.
- **Non ignorare le domande dell'utente con un tirare avanti**. Quando
  pone una domanda di scope ("serve davvero questa Phase?"), pausare e
  rispondere. Non procedere col piano originale ignorando il dubbio.
- **Non usare emoji** nel codice / nei commit / nei file (unless
  esplicitamente richiesto). Plain text e Markdown standard.
- **Non gonfiare i commit body con boilerplate**. Solo informazione
  rilevante: scope, why, discovery, pre-flight outcome, references.
