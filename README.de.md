# DeepSeek Off-Peak Menubar

🌐 [English](README.md) · **Deutsch**

Eine kleine **macOS-Menüleisten-App**, die zeigt, ob gerade die günstigen
**DeepSeek-Off-Peak-Preise** gelten – inklusive Countdown bis zum Wechsel,
Kontoguthaben und den tatsächlichen Kosten deiner DeepSeek-Harness-Sessions.

> **Inoffiziell.** Dieses Projekt steht in keiner Verbindung zu DeepSeek und wird
> nicht von DeepSeek unterstützt. Der Name wird nur beschreibend verwendet.
> Alle Preisangaben sind Schätzungen auf Basis der öffentlichen Preisseite.

Universalbinary (Intel + Apple Silicon), macOS 13 oder neuer.
Keine Laufzeit-Abhängigkeiten – nur `swiftc` (Xcode Command Line Tools) und
optional `zstd` für die Verbrauchsauswertung.

## Aktuelle Preisregeln (Stand Sep 2026)

Quelle: <https://api-docs.deepseek.com/quick_start/pricing/>

| Zeit | Tarif |
|---|---|
| Mo–Fr 01:00–04:00 UTC | **Peak** (100 %) |
| Mo–Fr 06:00–10:00 UTC | **Peak** (100 %) |
| alle anderen Zeiten | **Off-Peak** (50 % Rabatt) |
| Wochenende (Sa/So) | ganztägig **Off-Peak** (seit 23.08.2026) |

Die App rechnet intern in UTC und zeigt die Zeiten in deiner lokalen Zeitzone an
(z. B. Deutschland Sommerzeit: Peak 03–06 und 08–12 Uhr).

> **Hinweis zur Peking-Formulierung:** „Wochenende = Sa/So Peking-Zeit, ganztägig
> off-peak“ ist zur UTC-Logik der App äquivalent, weil alle Fenstergrenzen auf
> ganzen UTC-Stunden liegen. Der Selbsttest (`--selftest`) prüft das automatisch:
> 1.152 Stichproben (alle 15 Minuten, 21.08.–02.09.2026, also über das
> Inkrafttretens-Wochenende des 23.08.2026 hinweg) liefern identische Tarife.

## Bedienung

- **Menüleisten-Text**: nur farbiger Punkt + Countdown, z. B. `● 9h30`
  (grün = off-peak, orange = Peak) – Countdown bis zum nächsten Tarifwechsel.
  Bewusst **ohne Doppelpunkt**: `9h30` statt `9:30`, damit es nicht wie eine
  Uhrzeit aussieht (`9h30`, `1d5h`, `45m`, `42s`).
- **Tooltip** (Maus draufhalten): ausführliche Erklärung mit Zustandswort.
- **Klick**: Menü mit
  - Status und Restzeit,
  - Heute-/Morgen-Zeitfenstern (lokale Uhrzeit),
  - Uhrzeit lokal + UTC,
  - **Guthaben** (Gesamt / geschenkt / aufgeladen, Stand-Uhrzeit),
  - „Guthaben jetzt aktualisieren“,
  - „Bei niedrigem Guthaben warnen“ (Schwelle in der Config),
  - „Guthaben in der Menüleiste anzeigen“,
  - **Verbrauch heute**: Sessions · Eingabe (Cache-%) · Ausgabe · Kosten,
  - Verbrauch letzte 7 Tage + gesamt (Unterzeile),
  - „Verbrauch jetzt aktualisieren“,
  - „Details im Terminal (--cost)“,
  - Link zu den DeepSeek-Preisen,
  - **DSH Web starten (alias „deepseek“)** – führt `deepseek` (= `npx
    @deepseek-ai/dsh web`, Alias aus `~/.bashrc`) in einem neuen
    Terminal-Fenster aus,
  - DSH Web im Browser öffnen (http://127.0.0.1:3080),
  - „Status in Zwischenablage kopieren“,
  - Benachrichtigung bei Tarifwechsel (ein/aus),
  - Erinnerungen vor dem Wechsel (ein/aus),
  - Autostart bei Anmeldung (ein/aus, App muss in `/Applications` liegen),
  - „Konfiguration bearbeiten …“ und „Standard-Zeitfenster wiederherstellen“,
  - Beenden.

## Guthaben (Restgeld) im Blick

Die App fragt das **offizielle** Guthaben-API ab (`GET
https://api.deepseek.com/user/balance`, [Doku](https://api-docs.deepseek.com/api/get-user-balance/)) –
mit deinem API-Key, der **nur lokal** bleibt. Es werden Gesamtbetrag,
geschenktes und aufgeladenes Guthaben (getrennt!) sowie die Währung (USD/CNY)
angezeigt; bei mehreren Währungen alle Konten.

Key-Quelle (in dieser Reihenfolge): `apiKey` (inline) → `apiKeyEnv`
(Umgebungsvariable) → `apiKeyFile` (Datei im `KEY=VALUE`-Format, z. B. deine
`.env`). Für dein Setup genügt in der Config:

```json
{ "apiKeyFile": "/Users/varnholt/Programmieren/deepseek-cli/.env" }
```

(die Datei enthält bereits `DEEPSEEK_API_KEY=…`). Hinweis: `DEEPSEEK_API_KEY` in
der Datei ist beim Start aus dem Finder heraus **nicht** als Umgebungsvariable
gesetzt – deshalb `apiKeyFile` verwenden. Abfrage-Intervall und Warnschwelle:

| Schlüssel | Bedeutung | Standard |
|---|---|---|
| `apiKey` / `apiKeyEnv` / `apiKeyFile` | Key inline / Env-Name / Pfad zur `.env`-Datei | `""` / `DEEPSEEK_API_KEY` / `""` |
| `balanceBaseURL` | API-Basis-URL | `"https://api.deepseek.com"` |
| `balanceRefreshMinutes` | Abfrage-Intervall | `15` |
| `balanceWarnBelow` | Warnschwelle (Gesamtbetrag) | `2` |
| `balanceWarnEnabled` | Benachrichtigung, sobald unterschritten | `true` |
| `showBalanceInTitle` | Guthaben zusätzlich in der Menüleiste | `false` |

Unterschreitet das Guthaben die Schwelle, kommt eine Benachrichtigung und die
Anzeige färbt sich rot (`⚠ Guthaben niedrig`). CLI-Variante:

```bash
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --balance
# → Guthaben (USD): 12,34 $ gesamt – geschenkt 2,00 $, aufgeladen 10,34 $
```

**Kosten:** DeepSeek bietet keine API für Kostenverläufe – im Blick behältst du
sie über (a) die Token-Zähler des Harness pro Antwort, (b) die
Token-Statistiken unter [platform.deepseek.com](https://platform.deepseek.com)
und (c) die Preistabelle inkl. Off-Peak-Rabatt (Link im Menü). Das Guthaben
selbst wird bei jeder Abfrage aktuell vom API geholt.

## Verbrauch & Kosten über mehrere Sessions

Die App liest die **DSH-Session-Logs** aus (`~/.dsh/sessions/*/*/session.jsonl.zstd`,
dekomprimiert über `zstd`) und rechnet jeden LLM-Aufruf einzeln:

- **Eingabe getrennt** nach Cache-Hit (`cacheReadTokens`) und Cache-Miss
  (`inputTokens`), Ausgabe inkl. Reasoning (`outputTokens`),
- **Modell-Preise** (Stand Sep 2026): `deepseek-v4-flash` $0,007/M Hit · $0,22/M
  Miss · $0,66/M Ausgabe (off-peak); `deepseek-v4-pro` entsprechend höher.
  Unbekannte Modelle zählen wie flash.
- **Off-Peak-Faktor je Request**: Liegt der Zeitstempel eines Aufrufs im
  (konfigurierten) Off-Peak-Fenster, kostet er die Hälfte – die App rechnet
  dadurch „effektiv“ und zeigt zusätzlich die Vergleichswerte „alles
  off-peak“ / „alles Peak“.

Menü: Abschnitt „Verbrauch“ mit **heute** und **letzte 7 Tage / gesamt**
(Sessions, Tokens, Cache-%, Kosten in $ und ≈ €). Die Auswertung läuft im
Hintergrund (Intervall siehe Config) und lässt sich manuell aktualisieren.
Detaillierte Liste je Session:

```bash
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --cost
```

Voraussetzung: das `zstd`-Kommandozeilenwerkzeug (`/usr/local/bin/zstd`, sonst
`brew install zstd`). EUR ist eine Näherung über `eurPerUsd`.

Hinweise zur Auswertung:

- Es werden alle Namensvarianten der Logs gelesen
  (`session.jsonl.zstd`, `session.v3.jsonl.zstd`, …); pro Session zählt nur die
  **neueste** Datei (die v3-Datei enthält den vollständigen Verlauf).
- Kopien/Forks derselben Session (gleiche `message.id`) werden nur einmal
  gezählt.
- Das Vision-Modell `deepseek-v4-flash-vision-exp` wird wie Flash abgerechnet
  (identische Preise laut Preisseite).

## Konfiguration (JSON)

Alle Zeitfenster, Erinnerungen **und Guthaben-Einstellungen** liegen in einer
Datei, die **live überwacht** wird – Änderungen übernimmt die App ohne Neustart
(Sekunde für Sekunde):

```
~/Library/Application Support/DeepSeekOffPeak/config.json
```

Pfad im Terminal anzeigen oder Standarddatei anlegen:

```bash
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --config-path
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --create-config
```

| Schlüssel | Bedeutung | Standard |
|---|---|---|
| `peakWindowsUtc` | Peak-Fenster in UTC-Stunden (`startHour` inklusiv, `endHour` exklusiv, ganzstündig, kein Fenster über Mitternacht) | `[1–4, 6–10]` |
| `weekendsOffPeak` | Wochenende ganztägig off-peak? | `true` |
| `weekendTimeZone` | Zeitzone, in der „Wochenende“ zählt | `"Asia/Shanghai"` |
| `notifyOnChange` | Benachrichtigung bei jedem Tarifwechsel | `true` |
| `remindersEnabled` | Erinnerungen kurz vor dem Wechsel | `true` |
| `remindBeforeEndMinutes` | Vorlauf (Min.) vor **Ende** des Off-Peak | `[15, 5]` |
| `remindBeforeStartMinutes` | Vorlauf (Min.) vor **Beginn** des Off-Peak | `[15, 5]` |
| `usageRefreshMinutes` | Intervall für die Verbrauchs-Auswertung | `5` |
| `eurPerUsd` | Umrechnung USD → EUR (0 = keine EUR-Anzeige) | `0.91` |

Beispiel:

```json
{
  "peakWindowsUtc": [ { "startHour": 2, "endHour": 5 } ],
  "weekendsOffPeak": false,
  "weekendTimeZone": "UTC",
  "remindBeforeEndMinutes": [ 30, 10 ],
  "remindBeforeStartMinutes": [ 10 ]
}
```

Fehlende Schlüssel fallen auf die Standardwerte zurück; ungültige Fenster oder
Schwellen werden automatisch herausgefiltert. Bei unlesbarem JSON nutzt die App
die Standardwerte und meldet den Fehler auf stderr. Über das Menü („Konfiguration
bearbeiten …“) öffnest du die Datei direkt in TextEdit (bewusst nicht in der
System-Standard-App, damit keine `.json`-Datei bei Xcode landet).

## Bauen

```bash
cd DeepSeekOffPeak
./build.sh
```

Ergebnis: `build/DeepSeekOffPeak.app`

## Starten

```bash
open DeepSeekOffPeak/build/DeepSeekOffPeak.app
```

Dauerhaft nutzen: die App nach `~/Applications` oder `/Applications` kopieren
(„Bei Anmeldung starten“ im Menü aktivieren).

## CLI

Ohne GUI nutzbar (z. B. für Skripte oder dein `deepseek-cli`-Prompt):

```bash
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --text            # eine Statuszeile
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --balance         # Guthaben-Abfrage
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --cost            # Verbrauch/Kosten aller Sessions
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --selftest        # Selbsttest der Logik
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --config-path     # Pfad der Konfigurationsdatei
DeepSeekOffPeak.app/Contents/MacOS/DeepSeekOffPeak --create-config   # Standard-Konfiguration anlegen
```

## Hinweise

- Ändert DeepSeek die Fenster, passt du sie in der Konfigurationsdatei an –
  kein Neukompilieren nötig.
- Benachrichtigungen erfordern die Freigabe durch macOS (beim ersten Start wird gefragt).
- Der API-Key für die Guthaben-Abfrage bleibt lokal in deiner Datei/Config;
  die App sendet ihn nur als Bearer-Header an `https://api.deepseek.com/user/balance`.
- „DSH Web starten“ legt ein ausführbares `.command`-Skript an
  (`~/Library/Application Support/DeepSeekOffPeak/start-dsh-web.command`) und
  öffnet es in Terminal – **ohne AppleScript**, daher ist **keine
  Automatisierungs-Berechtigung** unter Datenschutz & Sicherheit nötig.
  Voraussetzung ist der Alias `deepseek` in `~/.bashrc`
  (z. B. `alias deepseek='npx @deepseek-ai/dsh web'`); fehlt er, startet das
  Skript `npx @deepseek-ai/dsh web` direkt.
- App ist nicht notariell signiert – beim ersten Start ggf. Rechtsklick → „Öffnen“.

## Lokalisierung

Englisch ist die Basissprache, Deutsch wird als Übersetzung mitgeliefert. Weitere
Sprachen: `Resources/en.lproj/Localizable.strings` kopieren, Werte übersetzen, als
`Resources/<code>.lproj/` ablegen und den Code in `CFBundleLocalizations` in der
`Info.plist` ergänzen (siehe [CONTRIBUTING.md](CONTRIBUTING.md)). Die Sprache
lässt sich in der Config über `"language": "auto" | "en" | "de"` festlegen.

## Mehr von mir

Dieses Projekt ist Teil von **[pikasso.eu.org](https://pikasso.eu.org)** –
kleine, fokussierte Werkzeuge von TheArk. Die Repositories liegen unter
[github.com/pikasso-eu](https://github.com/pikasso-eu).

## Lizenz

[MIT](LICENSE) · © 2026 TheArk (pikasso.eu.org)
