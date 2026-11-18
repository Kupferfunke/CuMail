# Versionshinweise

## 0.26.0 · 18. November 2026

Build 46. Das Indexschema bleibt unverändert.

### Neu

- Rechtschreibprüfung für Betreff und Nachrichtentext mit Deutsch, Englisch
  und automatischer Spracherkennung durch macOS.
- Automatische Korrektur beim Tippen separat ein- oder ausschalten.
- Dauerhafte Einstellungen unter **Allgemein → Rechtschreibung**, die auch
  bereits geöffnete Schreibfenster aktualisieren.
- Empfängervorschläge nach letzter tatsächlicher Verwendung; Häufigkeit und
  Adresse entscheiden bei gleichem Zeitpunkt.

### Behoben

- Die Empfängerauswahl hängt keinen überflüssigen Trenner mehr an.
- Alte Entwürfe mit abschliessendem Komma und Leerzeichen werden korrekt geprüft.
- Mehrere Adressen in An, Cc und Bcc können mit Semikolon getrennt werden;
  Kommas bleiben kompatibel. Ungültige Adressen und Header-Einschleusungen
  werden weiterhin abgewiesen.
- Empfängerfelder bleiben von automatischer Korrektur und Textersetzungen
  ausgeschlossen. Betreff und Nachricht besitzen getrennte Undo-Verläufe.

### Veröffentlichung

Kostenlos für private, nichtkommerzielle Nutzung gemäss [Lizenz](LICENSE).
Dieses Release stellt Quellcode bereit. Für Gmail wird eine eigene
Google-Registrierung benötigt; siehe [Einrichtung und Build](README.md).
Persönliche Kontokonfiguration, Maildaten und interne Abnahmeberichte sind
nicht Bestandteil der öffentlichen Fassung.

## 0.25.2 · 17. November 2026

Erste öffentliche, bereinigte Quellcodefassung (Build 45) mit deutscher
Bedienungsanleitung, Architekturübersicht und CuMail Personal Use License 1.0.
