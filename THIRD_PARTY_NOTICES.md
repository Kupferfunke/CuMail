# Drittanbieter und Markenassets

## Tatsächlich im App-Bundle

| Bestandteil | Herkunft | Lizenz / Hinweis |
|---|---|---|
| Josefin Sans statisch 700 | Benutzer-CI, ursprünglich [Google Fonts](https://github.com/google/fonts/tree/main/ofl/josefinsans) | SIL OFL 1.1, vollständiger Text in App/Resources/Fonts/JosefinSans-OFL.txt |
| Barlow Bold 700 | Benutzer-CI, ursprünglich [Google Fonts](https://github.com/google/fonts/tree/main/ofl/barlow) | SIL OFL 1.1, App/Resources/Fonts/Barlow-OFL.txt |
| IBM Plex Mono Regular 400 | Benutzer-CI, ursprünglich [Google Fonts](https://github.com/google/fonts/tree/main/ofl/ibmplexmono) | SIL OFL 1.1, App/Resources/Fonts/IBMPlexMono-OFL.txt |
| KupferFunke Logos/Signet/Icon | Originaldateien aus dem bereitgestellten KupferFunke-CI | Benutzerbereitgestelltes Markenmaterial; keine pauschale Open-Source-Lizenz behauptet. |
| SwiftUI, AppKit, WebKit, Foundation, Observation, CoreText | Installiertes Apple SDK/Systemframeworks | Apple-Plattformbedingungen; kein separat heruntergeladenes Drittanbieter-SDK |
| Swift Testing | Installierte Swift-/Xcode-Toolchain | Nur Tests, nicht als Mailbibliothek ausgeliefert |

Die Original-Josefin-Datei heisst JosefinSans-Bold.ttf und hat OS/2-Gewicht 700, behält intern aber den PostScript-Namen **JosefinSans-Thin**. Die Datei wurde nicht verändert. Der Code berücksichtigt den tatsächlich registrierten Namen; die sichtbare Logo-Wortmarke verwendet unveränderte Vektorpfade. IBM Plex Mono hat den PostScript-Namen **IBMPlexMono-Regular**.

## Ergänzt in Phase 1

| Bestandteil | Exakter Stand | Lizenz und Einbau |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift/tree/v7.12.0) | 7.12.0, Revision `92a554cd0d5e8d67cb18993c6054e73fe42c066c` | MIT; unveränderte Quellen in Vendor/GRDB, nur offizieller SQLCipher-Paketweg angepasst; vollständige Lizenz in App/Resources/Licenses/GRDB-MIT.txt |
| [SQLCipher.swift Community](https://github.com/sqlcipher/SQLCipher.swift/tree/4.20.0) | 4.20.0, Revision `e7415c5e6b4fd9b78874bb956aad8a42b08e9966` | Offizielles dynamisches XCFramework, macOS arm64/x86_64; Community BSD-Lizenz samt SQLite-Hinweisen unverändert in App/Resources/Licenses/SQLCipher-Community.md |
| Security.framework, CryptoKit, OSLog | Apple SDK/System | Keychain, sichere Zufallsbytes, SHA-256 für Migration/Cursor, Ereigniscodes |

SwiftPM-Checksum des offiziellen SQLCipher-Archivs: `1505174fe7f8a0fe81d6ebf87a64b17701b500c12a445ef6b68b9159f012d747`. `Package.resolved` liegt für App, Kernpaket und Xcode vor. Laufzeitprüfung: `PRAGMA cipher_version` meldet `4.20.0 community`. Das lokale Buildskript bettet das Framework ein und signiert die Kopie ad-hoc; es verändert keine Upstream-Quelle.


## Phase 2

[SwiftMail 1.16.0](https://github.com/Cocoanetics/SwiftMail/releases/tag/1.16.0) ist unverändert am Release-Commit `88c45cbd31b347b373f7c87e197be63eb95efbc2` eingebunden (BSD-2-Clause, Oliver Drobnik). SwiftPM benötigt hier einen Commit-Pin, da das Release selbst die NIOIMAP-Revision `14ad3887dab9ca5aba38ee0ace18fddf40e9491f` verwendet. Der Leseadapter, Synchronisationsregeln und UI gehören zur App; Protokoll- und MIME-Verarbeitung bleiben in der Bibliothek.

Die Paket-Lockdateien dokumentieren die aufgelösten Abhängigkeiten. Vollständige LICENSE-/NOTICE-Dateien aus deren Wurzelverzeichnissen sowie BoringSSL liegen unter `App/Resources/Licenses/Dependencies/` und werden unverändert ins App-Bundle kopiert. Der aufgelöste Graph umfasst auch Werkzeuge/Testabhängigkeiten der Upstream-Pakete; nicht alle Produkte werden in die App gelinkt.

## Phase 3

[SwiftSoup 2.14.3](https://github.com/scinfu/SwiftSoup/releases/tag/2.14.3), Commit `e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f`, wird unverändert für HTML-Parsing und Allowlist-Bereinigung verwendet. MIT-Lizenz vollständig in `App/Resources/Licenses/Dependencies/swiftsoup/LICENSE`. Die App ergänzt Grenzen, URL-Prüfung, CSP, WebKit-Netzwerksperre und kontrollierte Navigation. Der aufgelöste Graph umfasst jetzt 24 Remote-Pakete; alle drei Lockfiles haben identische Pins.

## Phase 6

[AppAuth 3.0.0](https://github.com/openid/AppAuth-iOS/releases/tag/3.0.0) ist für den nativen Google-Anmeldeablauf eingebunden. Apache-2.0, vollständige Lizenz unter `App/Resources/Licenses/AppAuth-Apache-2.0.txt`. AppAuth verwaltet Authorization Code, PKCE/state und Token-Erneuerung; die App speichert seinen Zustand im bestehenden Keychain-Dienst. macOS ab 12 laut Paket, App-Ziel weiterhin macOS 15. AppAuth wird unverändert über SwiftPM eingebunden. Keine zusätzliche Google-Sign-In-eigene Keychain nötig.

MSAL wurde nicht eingebunden. Der MCP SDK kam später in Phase 10 hinzu.

## Phase 8 / Microsoft-Rückbau

Keine neue Drittanbieterbibliothek. AppAuth 3.0.0 bleibt für Gmail. Microsoft-Code und dessen Paketprodukt wurden entfernt; MSAL wurde nie ausgeliefert. Anhangdekodierung verwendet bestehendes SwiftMail und Foundation, Vorschau und Export Apples QuickLookUI, CoreGraphics/ImageIO und Foundation/AppKit.

## Phase 10

[Offizieller Swift MCP SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1), Revision `a0ae212ebf6eab5f754c3129608bc5557637e605`, unverändert über SwiftPM. Upstream-Lizenzübergang mit Apache-2.0 für neue/freigegebene Beiträge und weiterhin MIT für nicht umgestellte Altbeiträge; vollständiger gemischter Lizenztext unter `App/Resources/Licenses/Dependencies/swift-sdk/LICENSE`. Transitive neue Abhängigkeit EventSource 1.6.0, Revision `bb4b61273b5a976bb571859c17f903ebc3439df1`, MIT unter `Dependencies/eventsource/LICENSE.md`. SwiftNIO 2.105.0 war bereits im aufgelösten Graph und wird zusätzlich direkt für den privaten Unix-Socket verwendet. Alle drei Lockfiles enthalten dieselben 27 Remote-Pins.

[OpenAI tunnel-client 0.0.19](https://github.com/openai/tunnel-client/releases/tag/v0.0.19), Revision `01d67bb4da0d8359b808b4761f8db171ab682cd7`, wird als offizielles macOS-Binary im App-Bundle ausgeliefert. Der Build prüft die SHA-256-Summe des Releasearchivs und signiert die lokale Kopie mit derselben Entwicklungsidentität wie die App. Upstream-Quellen bleiben unverändert. Vollständige LICENSE, NOTICE und gebündelte Fremdlizenzen liegen in `Contents/Resources/OpenAITunnelLicenses`. Die Cloudflare-Begleitdatei wird nicht ausgeliefert oder gestartet. Arm64-Archiv SHA-256 `2243d024b77af8ee4b4ab7a1447949e5fc8d82bcd2d51b178927f2da9e47ecfd`; amd64-Archiv `dff97674c77cac59e6ab3d901e6cff50fb17a5784c01d8959d1f4adb3afdf4bf`. Der Download allein richtet weder Tunnel noch Zugangsschlüssel ein.
