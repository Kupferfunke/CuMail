# Synthetischer Datensatz

Die einzige ausführbare Quelle liegt in `Packages/MikeMailCore/Sources/MailDemo/SyntheticFixtures.swift`.

Drei erfundene Konten (Werkstatt, Persönlich, Projekte), zehn Nachrichten, drei reine Anhang-Metadatensätze. Acht Nachrichten liegen in Posteingängen, eine in Gesendet, eine im Archiv. Vier ungelesene Inbox-Mails, zwei Favoriten. Entwürfe/Papierkorb demonstrieren leere Zustände.

UUIDs, Zeitpunkt und Inhalt sind fest. Adressen ausschliesslich unter example.com; Personen/Absender und Nachrichten sind erfunden. Keine Datei ist ein echtes Attachment. Kein importiertes Postfach und keine Zugangsdaten.

Die Fixture-API wirft bei inkonsistenter Account-/Folder-/Thread-/Attachment-Zuordnung. Tests prüfen Determinismus, Metadatensuche, Sichtbarkeitsgrenzen und dass Lesen den Ungelesenstatus nicht verändert.
