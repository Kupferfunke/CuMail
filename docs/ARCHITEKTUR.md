# Architektur

CuMail verbindet eine native SwiftUI/AppKit-Oberfläche mit getrennten
Komponenten für Mailanbieter, Speicherung, HTML-Darstellung und MCP-Zugriff.

Betreff und Nachrichtentext verwenden native AppKit-Editoren mit getrennten
Rechtschreib- und Undo-Zuständen. Die Sprachwahl und Autokorrektur sind
App-Einstellungen; Empfängerfelder bleiben von Textkorrekturen ausgeschlossen.
Empfängervorschläge stammen aus dem verschlüsselten lokalen Verlauf und werden
nach letzter tatsächlicher Verwendung sortiert.

| Komponente | Aufgabe |
|---|---|
| `MailDomain` | Konten, Nachrichten, Ordner, Kennungen und Speicherregeln |
| `MailApplication` | Anwendungsabläufe und Verträge für Provider und Speicherung |
| `MailIMAP` | IMAP-Lesen und -Aktionen sowie SMTP-Versand |
| `MailGoogle` | Gmail-API und OAuth über AppAuth |
| `MailPersistence` | Verschlüsselter lokaler Index, Entwürfe und Warteschlangen |
| `MailSecurity` | Zugangsdaten und Schlüsselbundanbindung |
| `MailRendering` | Bereinigung und Darstellung von HTML-Inhalten |
| `MailMCP` | Begrenzte KI-Werkzeuge und Prüfung der aktuellen Freigaben |
| `MailDemo` | Ausschliesslich synthetische Daten für Entwicklung und Tests |

Originalnachrichten bleiben beim jeweiligen Anbieter. Lokal liegen Metadaten,
ein Suchindex, optional freigegebene Textextrakte sowie bewusst angelegte eigene
Entwürfe und Auftragsbelege. Vollständige externe Postfächer werden nicht als
allgemeines Rohmailarchiv in das Projekt kopiert.

Passwörter, OAuth-Zustände und Datenbankschlüssel werden über den eigenen
Schlüsselbunddienst gespeichert. Das Git-Repository enthält nur den Code
für diese Mechanismen, keine eingerichteten Konten oder gespeicherten Schlüssel.

Die lokale Bridge transportiert MCP-Nachrichten über einen privaten Unix-Socket.
Der optionale Tunnel verbindet ausgehend zu einem externen Dienst. Zugriffsumfang
und Schreibrechte werden in der App pro Konto bzw. Ordner getrennt kontrolliert.

Schreibaufträge werden vor der Ausführung gespeichert. Unklare Providerergebnisse
werden geprüft, bevor davon abhängige Aktionen weiterlaufen. Das soll doppelte
Schreib- und Sendeversuche nach Verbindungsabbrüchen verhindern.

Die Drittanbieterabhängigkeiten sind in den Paketmanifesten und Lockdateien
festgehalten. Ihre Lizenztexte befinden sich unter `App/Resources/Licenses/`
und bei den jeweiligen Vendor-Komponenten.
