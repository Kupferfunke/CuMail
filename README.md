# CuMail

Native macOS-Mail-App von KupferFunke. SwiftUI/AppKit-Oberfläche mit IMAP,
SMTP, Gmail, verschlüsseltem lokalen Index und einem optionalen MCP-Zugang.

**Free for private use:** kostenlos für private, nichtkommerzielle Nutzung
durch Privatpersonen. Geschäftliche oder organisatorische Nutzung benötigt
eine separate Erlaubnis. Der Quellcode ist öffentlich einsehbar; es gilt die
[CuMail Personal Use License 1.0](LICENSE).

## Dokumentation

- [Bedienungsanleitung](docs/BEDIENUNG.md): Postfächer, Suche, Versand, Signaturen und KI-Zugang.
- [Architektur](docs/ARCHITEKTUR.md): Komponenten, Datenhaltung und Schnittstellen.
- [Versionshinweise](CHANGELOG.md): neue Funktionen und Fehlerbehebungen.
- [Sicherheitshinweise](SECURITY.md) und [Prüfbericht](UPLOAD_REVIEW.md).
- [Drittanbieterlizenzen](THIRD_PARTY_NOTICES.md).

Quellstand: **0.26.0, Build 46**. Dieses Repository ist eine bereinigte
Quellcodekopie. Es enthält keine eingerichteten Konten, privaten Mailbestände,
Zugangsschlüssel, lokalen Signierzertifikate oder bisherigen Git-Objekte.
Die Tests verwenden synthetische Postfächer und ausdrücklich erfundene Werte.

## Neu in 0.26.0

- Rechtschreibprüfung in Betreff und Nachrichtentext: Deutsch, Englisch oder
  automatische Spracherkennung, mit separat abschaltbarer Autokorrektur.
- Empfängervorschläge nach letzter tatsächlicher Verwendung.
- Zuverlässige Empfängerauswahl und Unterstützung mehrerer Adressen mit Semikolon;
  ältere Entwürfe mit angehängtem Komma und Leerzeichen sind wieder versendbar.

Dieses Release enthält den Quellcode; eine fertige, notarisierte macOS-Installationsdatei
wird nicht mitgeliefert. Die Build-Anleitung folgt unten.

## Voraussetzungen und Build

- macOS ab 15 und eine kompatible Xcode-/Swift-Toolchain.
- Internetzugang zum erstmaligen Laden der in `Package.resolved` fixierten Pakete.
- Für einen lokal signierten App-Build wird eine eigene Entwicklungsidentität
  im macOS-Schlüsselbund angelegt bzw. wiederverwendet.

```sh
./Scripts/build-local.sh
```

Die App liegt danach in `build/CuMail.app`. Das Buildskript installiert und
startet sie nicht. Ein Entwicklungsbuild verwendet dieselbe Bundle-ID wie
eine vorhandene Installation; nicht ungeprüft parallel zur täglichen App starten.

## Eigene Google-Registrierung

Die persönliche Google-Client-ID wurde entfernt. IMAP/SMTP benötigen sie nicht.
Für Gmail muss eine eigene passende native Google-OAuth-Registrierung bestehen.
Die öffentliche Client-ID und ihr Rückleitungsschema werden ausschliesslich
in das gebaute App-Bundle eingesetzt:

```sh
CUMAIL_GOOGLE_CLIENT_ID='DEINE_CLIENT_ID.apps.googleusercontent.com' ./Scripts/build-local.sh
```

Kein Google-Passwort oder Client-Secret in diese Variable eintragen. Ein Build
ohne diese Variable enthält keine Google-Registrierung. Die App übernimmt
die konfigurierte öffentliche Client-ID aus ihrer `Info.plist`.

Für Xcode zunächst eine ignorierte lokale Plist erzeugen:

```sh
python3 Scripts/configure-google.py --client-id 'DEINE_CLIENT_ID.apps.googleusercontent.com' --output Config/Info.local.plist
xcodebuild -project MikeMailHub.xcodeproj -scheme MikeMailHub INFOPLIST_FILE=Config/Info.local.plist build
```

Der Beispielwert muss durch eine gültige eigene Client-ID ersetzt werden.
Die OAuth-Hilfsfunktion benötigt eine numerische Google-Projektnummer am Anfang.

## Tests

```sh
./Scripts/test-core.sh
./Scripts/test-app.sh
```

Die optionalen echten Schlüsselbundtests nur in einer geeigneten
Entwicklungsumgebung ausdrücklich einschalten. Keine Live-Mailtests ausführen,
um einen Upload zu prüfen.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `App/` | SwiftUI/AppKit-Oberfläche, Ressourcen und Lizenzen |
| `Packages/MikeMailCore/` | Domain, Provider, Speicherung, Sicherheit und MCP |
| `Services/` | Lokale Bridge und Schlüsselbunddienst |
| `Tests/`, `Fixtures/` | Synthetische Testdaten und Tests |
| `Vendor/GRDB/` | Mitgelieferte GRDB-Quellen und Lizenz |
| `Scripts/`, `Config/` | Build-, Prüf- und nicht persönliche App-Konfiguration |

Passwörter und OAuth-Zustände gehören in den Schlüsselbund. Reale Nachrichten,
Entwürfe und Suchindizes gehören nicht ins Repository. MCP- und Cloudzugriff
müssen in der App separat eingerichtet und für konkrete Konten freigegeben werden.

## Sicher committen

Gitleaks aus dem offiziellen Projekt installieren und die lokalen Prüfungen aktivieren:

```sh
git config core.hooksPath .githooks
gitleaks dir . --redact
gitleaks git . --redact --log-opts=--all
```

Die Hooks verweigern Commit und Push, wenn Gitleaks fehlt oder einen Treffer meldet.
Dieses Repository ist öffentlich. Automatische Prüfungen ersetzen keine
inhaltliche Prüfung neuer Dateien. Weitere Regeln stehen in [SECURITY.md](SECURITY.md).

Die Rechte an eigenem Code und Markenmaterial bleiben beim Rechteinhaber.
Die private Nutzung und kostenlose Weitergabe sind im Rahmen der [Lizenz](LICENSE)
erlaubt. Diese Lizenz ist keine uneingeschränkte Open-Source-Lizenz.
Drittanbieter behalten ihre jeweiligen Lizenzen; siehe
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
