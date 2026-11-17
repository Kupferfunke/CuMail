# CuMail bedienen

CuMail ist eine native macOS-Anwendung. Das öffentliche Repository enthält
Quellcode, keine gehosteten Postfächer und keine vorkonfigurierte Cloudinstanz.
Für den Build siehe die [README](../README.md).

## 1. Ein Postfach verbinden

In **Einstellungen → Konten** ein IMAP-Konto hinzufügen oder Gmail verbinden.
Für IMAP werden Adresse, Server, Port, TLS-Modus und Benutzername beim eigenen
Mailanbieter nachgeschlagen. Das Passwort direkt in der App eingeben.
Die Versandverbindung unter **Versand** separat einrichten und prüfen.
Eine Verbindungsprüfung versendet keine Nachricht.

Gmail verwendet die eigene öffentliche Google-OAuth-Registrierung des Builds.
Das Google-Passwort wird nur auf Googles Anmeldeseite eingegeben. Zunächst
«Nur lesen» wählen; «Lesen, ordnen und senden» bewusst freigeben, wenn nötig.
Ein Google-Projekt im Testmodus kann eine erneute Anmeldung verlangen.

## 2. Abgleichen, lesen und suchen

Mit **Synchronisieren** die Metadaten der eingerichteten Konten laden.
Ein grosser Erstabgleich benötigt Zeit; Abdeckung und Fortschritt beachten.
Ein leeres Suchergebnis beweist während eines unvollständigen Abgleichs nicht,
dass die Nachricht auf dem Server fehlt.

- **Alle Posteingänge** zeigt kontenübergreifend eingehende Nachrichten.
- **Ungelesen** und **Favoriten** schränken die Auswahl ein.
- Mit **⌘F** suchen; beispielsweise `from:Lena has:attachment after:2026-01-01`.
- «Auf Server suchen» startet bewusst eine Suche für einen IMAP-Ordner.
- Die optionale Inhaltssuche erfasst Textextrakte innerhalb der eingestellten
  Grenzen. Sie kann pausiert und ihre gespeicherten Extrakte können gelöscht werden.

Beim Öffnen lädt CuMail den benötigten Inhalt. Aus HTML-Mails können externe
HTTPS-Bilder abgerufen werden; dadurch kann der Bildanbieter einen Abruf erkennen.
Anhänge werden gezielt über **Vorschau** oder **Sichern …** geladen.

## 3. Schreiben und senden

**⌘N** erstellt eine neue Nachricht mit dem gewählten Absenderkonto.
Empfänger, Betreff, Text und Anhänge prüfen und erst dann **Senden** wählen.
Das Senden in der nativen App erfolgt mit diesem Klick.

Antworten und Weiterleitungen übernehmen den bereinigten Originalinhalt.
Unter **Einstellungen → Signaturen** lassen sich eigene HTML-Signaturen und
ein Standard pro Konto hinterlegen. Die Kontosignatur kann im Entwurf geändert werden.

Eigene Entwürfe erscheinen unter **Entwürfe**. **Versandstatus** zeigt offene
Prüfungen und Versandbelege. Bei unklarem Versandstatus nicht einfach nochmals
senden: zuerst den Status und den Gesendet-Ordner beim Anbieter prüfen.

## 4. Nachrichten ordnen

Lesestatus, Favoriten, Archiv und Verschieben sind kontoweise freizugeben.
Die App führt Schreibaktionen über eine dauerhafte Warteschlange aus; ein
unklares Serverergebnis kann eine Nachprüfung erfordern. Endgültiges Löschen
ist nicht als allgemeine Mailaktion vorgesehen. Verschieben in den Papierkorb
ist eine Änderung beim Mailanbieter.

## 5. Optionalen KI-Zugang einrichten

Unter **Einstellungen → KI-Zugang** genau die gewünschten Konten und Ordner
freigeben. Mailtexte, Antworten, neue Nachrichten, Mailaktionen und Sofortversand
haben zusätzliche Berechtigungen. Neue Konten erhalten diese Rechte nicht automatisch.

Für einen lokalen MCP-Client den mitgelieferten `MikeMailBridge`-Helfer als
stdio-Server konfigurieren. Den konkreten Pfad zeigt die App. Der lokale
Transport verwendet einen privaten Unix-Socket desselben macOS-Benutzers.

Eine ChatGPT-Verbindung benötigt einen selbst eingerichteten unterstützten
Tunnel, eigene Zugangsdaten und eine eigene Verbindung im KI-Client.
Das Repository enthält weder einen gemeinsamen Tunnel noch einen geteilten
API-Schlüssel. Ein ChatGPT-Konto oder dessen Verbindung wird nicht mitgeliefert.

Bei der Standardfreigabe wird eine KI-Nachricht zunächst zur Prüfung in der
Mac-App geöffnet. **Sofortversand** ist eine zusätzliche Option; damit kann
ein ausdrücklicher Sendeauftrag ohne weiteren Klick in der App ausgeführt werden.

**Alle Freigaben widerrufen** beendet den Zugang. Inhalte, die bereits an einen
KI-Dienst übermittelt wurden, werden dadurch dort nicht rückwirkend gelöscht.
Für den Zugriff müssen Mac und App laufen und erreichbar sein.

## 6. Bei Problemen

| Problem | Erster Schritt |
|---|---|
| Gmail-Anmeldung funktioniert nicht | Eigene Client-ID und Rückleitungsschema des Builds prüfen |
| Nachrichten fehlen in der Suche | Synchronisations- und Textabdeckung kontrollieren |
| Versandstatus unklar | Versandstatus und Gesendet-Ordner prüfen, nicht blind erneut senden |
| KI sieht kein Postfach | App öffnen, lokalen Zugang und konkrete Ordnerfreigaben prüfen |
| Cloudverbindung unterbrochen | Verbindung und eigene Tunnelkonfiguration prüfen |

Fehlerberichte dürfen nur bereinigte Fehlermeldungen und synthetische Beispiele
enthalten. Keine Mail-Screenshots, Passwörter, Tokens oder echten Mailtexte posten.
