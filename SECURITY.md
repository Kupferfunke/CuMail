# Umgang mit vertraulichen Daten

- Dieses Repository ist öffentlich. Jede hochgeladene Datei und jeder Commit
  muss als weltweit sichtbar und kopierbar behandelt werden.
- Keine echten Mailinhalte, Anhänge, Signaturen, Kontolisten, Screenshots,
  Support-/Testprotokolle oder lokalen Konfigurationen committen.
- Passwörter, API-Schlüssel, OAuth-Tokens und private Signierschlüssel gehören
  weder in Quellcode noch in Beispiele, Commit-Nachrichten oder Issues.
- `.gitignore` schützt nur bislang unversionierte Dateien. Bereits erfasste
  Dateien und alte Commits müssen ebenfalls geprüft werden.
- Vor Commit und Push laufen bei aktivierten `.githooks` lokale Gitleaks-Prüfungen
  mit geschwärzter Ausgabe. Ohne Scanner wird abgebrochen.
- Synthetische Testkennwörter sind erfundene Werte, keine nutzbaren Zugangsdaten.
  Keine allgemeinen Ausnahmen für ganze Test- oder Quellverzeichnisse ergänzen.
- Bei einem tatsächlichen Geheimnisfund: Upload stoppen, betroffene Zugangsdaten
  erneuern und die betroffenen Git-Objekte bereinigen. Ein Folgecommit allein
  entfernt nichts aus der Historie.

Die Upload-Prüfung ist eine Suche nach vertraulichen Daten. Sie ist kein
vollständiges Sicherheitsgutachten über das Laufzeitverhalten der Anwendung.
