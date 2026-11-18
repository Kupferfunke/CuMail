# Prüfung der öffentlichen Quellcodefassung

Stand: 18. November 2026. Quellstand **0.26.0 (Build 46)** für das öffentliche
Repository [Kupferfunke/CuMail](https://github.com/Kupferfunke/CuMail), mit
kostenloser privater Nutzung unter der CuMail Personal Use License 1.0.

## Enthalten

Quellcode der macOS-App, Kernpaket, Services,
synthetische Tests, Markenressourcen, Paket-Lockdateien, Buildskripte und
Drittanbieterlizenzen. Die erste Veröffentlichung übernahm keine früheren
privaten Git-Objekte. Das Update ergänzt die Empfänger- und Rechtschreibfunktionen
sowie öffentliche Versionshinweise und Bedienungsdokumentation.

## Entfernt oder ausgeschlossen

- Persönliche Einrichtungs- und Abnahmeberichte sowie alle bisherigen
  Projekt-Screenshots und Prüfprotokolle.
- Die persönliche öffentliche Google-Client-ID und das zugehörige
  Rückleitungsschema. Eigene Werte werden nur in lokale Builddateien eingesetzt.
- Der echte Name in einer synthetischen Testsignatur; ersetzt durch einen
  erfundenen Beispielnamen.
- Buildprodukte, Caches, Mail-/Datenbankdateien, Archive, lokale Einstellungen
  und mögliche Schlüsseldateien.

## Prüfungen der ersten Veröffentlichung

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

## Zusätzliche Prüfungen für 0.26.0

- Gezielter Abgleich der neuen Quelldateien und Tests mit dem Entwicklungsstand.
  Die öffentliche Google-Konfiguration, anonymisierte Testsignatur und bisherigen
  Ausschlüsse wurden beibehalten.
- Prüfung der Änderungen auf persönliche Angaben und der gesamten bereinigten
  Fassung mit Gitleaks 8.30.1, ohne Geheimnisfund.
- Swift-Syntaxprüfung der neuen und geänderten Swift-Dateien sowie Prüfung von
  App-Plist, Xcode-Projekt und Dokumentationslinks.
- Vier isolierte Prüfungen der Google-Buildkonfiguration, einschliesslich der
  Versionswerte 0.26.0 / 46 und des Schutzes der gemeinsamen Vorlage.
- Vorhandene Entwicklungsprotokolle geprüft: 74 App-Tests erfolgreich;
  227 Kernprüfungen erfasst, davon zwei optionale Prüfungen ausgelassen und
  225 erfolgreich. Das Release-Buildprotokoll meldet einen erfolgreichen Build.
  Die internen Protokolle selbst werden nicht veröffentlicht.

Keine echten Zugangsdaten in der bereinigten Kopie gefunden. Synthetische
Testkennwörter und Testtokens bleiben erhalten, damit die Tests aussagekräftig sind.

## Prüfgrenzen

Ein vollständiger App-Build und die gesamte Testsuite wurden für den öffentlichen
Export nicht nochmals ausgeführt; die oben genannten Gesamtergebnisse stammen
aus den vorhandenen Entwicklungsprotokollen. Die Commit-/Push-Hooks verlangen Gitleaks
und brechen ohne verfügbaren Scanner ab.

Die Prüfung kann unbekannte Geheimnisformate oder Sicherheitslücken in der
App nicht generell ausschliessen. Neue Dateien müssen vor jedem Upload erneut
geprüft werden. Das ursprüngliche Entwicklungsprojekt und die installierte App
wurden nicht verändert.
