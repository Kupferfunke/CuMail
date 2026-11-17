# Vorbereitung für GitHub

Stand: 17. November 2026. Geplanter Zugriff: **öffentliches Repository**,
mit kostenloser privater Nutzung unter der CuMail Personal Use License 1.0.
Dieser Bericht bestätigt noch keinen erfolgreichen GitHub-Upload.

## Enthalten

Quellcode der macOS-App 0.25.2 (Build 45), Kernpaket, Services,
synthetische Tests, Markenressourcen, Paket-Lockdateien, Buildskripte und
Drittanbieterlizenzen. Ein neuer Git-Start übernimmt keine früheren Git-Objekte.

## Entfernt oder ausgeschlossen

- Persönliche Einrichtungs- und Abnahmeberichte sowie alle bisherigen
  Projekt-Screenshots und Prüfprotokolle.
- Die persönliche öffentliche Google-Client-ID und das zugehörige
  Rückleitungsschema. Eigene Werte werden nur in lokale Builddateien eingesetzt.
- Der echte Name in einer synthetischen Testsignatur; ersetzt durch einen
  erfundenen Beispielnamen.
- Buildprodukte, Caches, Mail-/Datenbankdateien, Archive, lokale Einstellungen
  und mögliche Schlüsseldateien.

## Durchgeführte Prüfungen

- Inhaltsprüfung auf bekannte Tokenformate, private Schlüssel, feste
  Geheimniszuweisungen, persönliche Kontaktdaten, lokale Benutzerpfade und
  persönliche Verbindungskennungen; auffällige Testwerte einzeln geprüft.
- Entropieprüfung auf ungewöhnliche feste Zeichenketten im eigenen Quellcode.
- Prüfung von Bild-/PDF-Metadaten auf persönliche Angaben; eigene PNG-Markenbilder
  zusätzlich visuell geprüft.
- Python-, Shell- und Plist-Syntax sowie Swift-Syntax der geänderten Quelldateien.
- Vier isolierte Konfigurationsprüfungen: ohne Google-ID, mit synthetischer ID,
  ungültiger ID und Schutz gegen Überschreiben der gemeinsamen Plist.
- Gitleaks 8.30.1: Dateiscan und Scan der gesamten bereinigten Git-Historie
  ohne Geheimnisfund. Ausgabe und Berichte sind geschwärzt; keine pauschalen
  Ausnahmen für Testverzeichnisse.

Keine echten Zugangsdaten in der bereinigten Kopie gefunden. Synthetische
Testkennwörter und Testtokens bleiben erhalten, damit die Tests aussagekräftig sind.

## Prüfgrenzen

Ein vollständiger App-Build und die gesamte Testsuite wurden in dieser Sitzung
nicht ausgeführt. Die vorbereiteten Commit-/Push-Hooks verlangen Gitleaks
und brechen ohne verfügbaren Scanner ab.

Die Prüfung kann unbekannte Geheimnisformate oder Sicherheitslücken in der
App nicht generell ausschliessen. Neue Dateien müssen vor jedem Upload erneut
geprüft werden. Das ursprüngliche Entwicklungsprojekt und die installierte App
wurden nicht verändert.
