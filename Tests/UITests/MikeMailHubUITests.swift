import XCTest
import AppKit

/// Requires full Xcode and macOS permission to enable the test runner's UI automation.
@MainActor
final class MikeMailHubUITests: XCTestCase {
    func testAutomaticReadDoesNotReverseUndoUntilSelectionChanges() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate(); defer { app.terminate() }
        let first = app.staticTexts["message-30000000-0000-4000-8000-000000000001"]
        let second = app.staticTexts["message-30000000-0000-4000-8000-000000000004"]
        XCTAssertTrue(first.waitForExistence(timeout: 8)); first.click()
        app.buttons["settings-link"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Konten"].click()
        settings.buttons["edit-account-10000000-0000-4000-8000-000000000001"].click()
        app.popUpButtons["mark-read-delay"].click(); app.menuItems["Nach 2 Sekunden"].click()
        app.buttons["save-account-settings"].click()
        wait(for: NSPredicate(format: "exists == false"), on: app.buttons["save-account-settings"])
        app.typeKey("w", modifierFlags: .command)
        wait(for: NSPredicate(format: "label == %@", "Ungelesen"), on: app.buttons["mark-read"])
        app.buttons["undo-mail-action"].click()
        wait(for: NSPredicate(format: "label == %@", "Gelesen"), on: app.buttons["mark-read"])
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Ungelesen"), object: app.buttons["mark-read"])
        unchanged.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 4), .completed)
        second.click(); first.click()
        wait(for: NSPredicate(format: "label == %@", "Ungelesen"), on: app.buttons["mark-read"])
        attachWindow(app, named: "CuMail - read rule respects explicit undo")
    }
    func testCuMailBulkReadAndUndoRestoreMixedStates() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate(); defer { app.terminate() }
        let first = app.staticTexts["message-30000000-0000-4000-8000-000000000001"]
        let second = app.staticTexts["message-30000000-0000-4000-8000-000000000004"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.click()
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        let actions = app.menuButtons["bulk-mail-actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        wait(for: NSPredicate(format: "enabled == true"), on: actions)
        actions.click(); app.menuItems["Als gelesen markieren"].click()
        let result = app.staticTexts["network-status"]
        wait(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "2 von 2", "2 von 2"), on: result)
        let undo = app.buttons["undo-mail-action"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.click()
        wait(for: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "2 Änderungen rückgängig", "2 Änderungen rückgängig"), on: result)
        first.click()
        wait(for: NSPredicate(format: "label == %@", "Gelesen"), on: app.buttons["mark-read"])
        second.click()
        wait(for: NSPredicate(format: "label == %@", "Ungelesen"), on: app.buttons["mark-read"])
        attachWindow(app, named: "CuMail - bulk action and exact undo")
    }
    func testPhaseEightAttachmentPreviewCancelSaveAndMicrosoftAbsent() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate(); defer { app.terminate() }
        let open = app.buttons["attachment-open-50000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let detail = app.scrollViews.containing(.button, identifier: open.identifier).firstMatch
        detail.scroll(byDeltaX: 0, deltaY: -2200)
        wait(for: NSPredicate(format: "enabled == true"), on: open)
        open.click()
        let save = app.buttons["attachment-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synthetischer Testanhang · kein Originaldokument"].exists)
        attachWindow(app, named: "Phase 8 - synthetic attachment preview")
        save.click()
        let cancel = app.buttons["Abbrechen"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.click()
        wait(for: NSPredicate(format: "enabled == true"), on: save)
        app.buttons["attachment-close"].click()
        wait(for: NSPredicate(format: "exists == false"), on: save)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.buttons["Konten"].click()
        XCTAssertFalse(settings.buttons["add-microsoft-account"].exists)
        XCTAssertTrue(settings.buttons["add-google-account"].exists)
        XCTAssertTrue(settings.buttons["add-imap-account"].exists)
        settings.buttons["Speicher"].click()
        XCTAssertTrue(settings.staticTexts["storage-temporary-bytes"].label.hasPrefix("0 KB"))
        attachWindow(app, named: "Phase 8 - temporary files removed")
    }
    func testPhaseFiveReplyAllAndForwardUseOriginalAccount() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let reply = app.buttons["compose-reply-all"]
        XCTAssertTrue(reply.waitForExistence(timeout: 8))
        let detail = app.scrollViews.containing(.button, identifier: "compose-reply-all").firstMatch
        detail.scroll(byDeltaX: 0, deltaY: -2400)
        wait(for: NSPredicate(format: "enabled == true"), on: reply)
        reply.click()
        let composers = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-"))
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        let composer = composers.firstMatch
        XCTAssertEqual(composer.staticTexts["compose-sender"].label, "werkstatt@example.com")
        XCTAssertTrue((composer.textFields["compose-subject"].value as? String)?.hasPrefix("Re:") == true)
        XCTAssertFalse((composer.textFields["compose-to"].value as? String ?? "").contains("werkstatt@example.com"))
        XCTAssertFalse(composer.buttons["compose-send"].isEnabled)
        app.typeKey("w", modifierFlags: .command)
        wait(for: NSPredicate { _, _ in composers.count == 0 }, on: app)
        app.buttons["compose-forward"].click()
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composers.firstMatch.staticTexts["compose-sender"].label, "werkstatt@example.com")
        XCTAssertTrue((composers.firstMatch.textFields["compose-subject"].value as? String)?.hasPrefix("Fwd:") == true)
        XCTAssertEqual(composers.firstMatch.textFields["compose-to"].value as? String, "")
        XCTAssertTrue((composers.firstMatch.textViews["compose-body"].value as? String)?.contains("Weitergeleitete Nachricht") == true)
        attachWindow(app, named: "Phase 5 - forward from original account")
    }
    func testPhaseFiveIndependentComposersAndDraftRecovery() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let newMessage = app.buttons["new-message"]
        XCTAssertTrue(newMessage.waitForExistence(timeout: 8))
        wait(for: NSPredicate(format: "enabled == true"), on: newMessage)
        app.typeKey("n", modifierFlags: .command)
        let composers = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composer-"))
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        let first = composers.element(boundBy: 0)
        pasteQuery("Phase 5 · Entwurf Eins", into: first.textFields["compose-subject"])
        pasteQuery("Erster unabhängiger Text. äöü", into: first.textViews["compose-body"])
        first.buttons["compose-save"].click()
        wait(for: NSPredicate(format: "label CONTAINS %@", "gesichert"), on: first.staticTexts["compose-status"])
        XCTAssertFalse(first.buttons["compose-send"].isEnabled, "Demo must never send")
        attachWindow(app, named: "Phase 5 - native composer")
        app.typeKey("n", modifierFlags: .command)
        wait(for: NSPredicate { _, _ in composers.count == 2 }, on: app)
        let second = composers.allElementsBoundByIndex.first { $0.identifier != first.identifier }!
        pasteQuery("Phase 5 · Entwurf Zwei", into: second.textFields["compose-subject"])
        pasteQuery("Zweiter unabhängiger Text.", into: second.textViews["compose-body"])
        second.buttons["compose-save"].click()
        wait(for: NSPredicate(format: "label CONTAINS %@", "gesichert"), on: second.staticTexts["compose-status"])
        XCTAssertEqual(first.textViews["compose-body"].value as? String, "Erster unabhängiger Text. äöü")
        XCTAssertEqual(second.textViews["compose-body"].value as? String, "Zweiter unabhängiger Text.")
        app.typeKey("w", modifierFlags: .command)
        first.textFields["compose-subject"].click(); app.typeKey("w", modifierFlags: .command)
        wait(for: NSPredicate { _, _ in composers.count == 0 }, on: app)
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(app.buttons["local-drafts"].waitForExistence(timeout: 8))
        app.buttons["local-drafts"].click()
        let firstDraft = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Phase 5 · Entwurf Eins")).firstMatch
        XCTAssertTrue(firstDraft.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0, "Drafts must use the main window, not a modal picker")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Phase 5 · Entwurf Zwei")).firstMatch.exists)
        firstDraft.click()
        XCTAssertTrue(app.buttons["local-draft-open"].waitForExistence(timeout: 5))
        app.buttons["local-draft-open"].click()
        XCTAssertTrue(composers.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(composers.firstMatch.textViews["compose-body"].value as? String, "Erster unabhängiger Text. äöü")
        attachWindow(app, named: "Phase 5 - recovered draft")
    }
    func testColumnsStayWithinWindowAndScrollBackToTopAfterResize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        defer { app.terminate() }
        let window = app.windows["inbox"]
        let first = app.staticTexts["message-30000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let sidebar = app.scrollViews.containing(.button, identifier: "sidebar-inbox").firstMatch
        let messages = app.scrollViews.containing(.any, identifier: "message-list").firstMatch
        // Expand all fixture accounts so the sidebar also has real overflow.
        XCTAssertEqual(sidebar.disclosureTriangles.count, 3)
        for triangle in sidebar.disclosureTriangles.allElementsBoundByIndex {
            for _ in 0..<8 where !sidebar.frame.contains(CGPoint(x: sidebar.frame.minX + 16, y: triangle.frame.midY)) {
                sidebar.scroll(byDeltaX: 0, deltaY: -200)
            }
            XCTAssertTrue(sidebar.frame.contains(CGPoint(x: sidebar.frame.minX + 16, y: triangle.frame.midY)))
            XCTAssertTrue(triangle.isHittable)
            // The label selects the account; the leading chevron expands it.
            // macOS reports the disclosure's AX frame wider than its visible
            // chevron. Anchor the click to the sidebar's 12-point content inset.
            sidebar.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 16, dy: triangle.frame.midY - sidebar.frame.minY)).click()
            assertSelected(triangle)
        }
        app.typeKey("1", modifierFlags: .command)
        assertValue("Alle Posteingänge", of: app.staticTexts["mailbox-title"])
        sidebar.scroll(byDeltaX: 0, deltaY: 4000)
        for _ in 0..<2 {
            let previousSize = window.frame.size
            app.menuBars.menuBarItems["Fenster"].click()
            app.menuItems["Zoomen"].click()
            wait(for: NSPredicate { _, _ in window.frame.size != previousSize }, on: window)
            // Zoom can also move the window between displays. Wait for its
            // scroll views to reach the new window before sending wheel events.
            wait(for: NSPredicate { _, _ in
                window.frame.contains(sidebar.frame) && window.frame.contains(messages.frame)
            }, on: window)
            for element in [app.staticTexts["mailbox-title"], app.buttons["settings-link"], app.buttons["search-coverage"]] {
                XCTAssertTrue(element.isHittable)
                XCTAssertTrue(window.frame.contains(element.frame), "Outside window: \(element.identifier), \(element.frame), window \(window.frame)")
            }
            sidebar.scroll(byDeltaX: 0, deltaY: -4000)
            sidebar.scroll(byDeltaX: 0, deltaY: 4000)
            let inbox = app.buttons["sidebar-inbox"]
            XCTAssertTrue(inbox.isHittable)
            XCTAssertTrue(sidebar.frame.contains(inbox.frame))
            for _ in 0..<3 { messages.scroll(byDeltaX: 0, deltaY: -400) }
            if messages.frame.height < 1000, first.exists {
                XCTAssertFalse(messages.frame.intersects(first.frame))
            }
            messages.scroll(byDeltaX: 0, deltaY: 4000)
            XCTAssertTrue(first.isHittable)
            XCTAssertTrue(messages.frame.contains(first.frame))
            print("SCROLL window=\(window.frame) sidebar=\(sidebar.frame) messages=\(messages.frame); both first rows fully reachable")
        }
        attachWindow(app, named: "Scroll regression - compact window")
    }
    func testPhaseFourSearchFiltersCoverageAndTextDeletion() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        let first = app.staticTexts["message-30000000-0000-4000-8000-000000000001"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let search = app.searchFields["mail-search"]
        app.typeKey("f", modifierFlags: .command); pasteQuery("from:Lena has:attachment", into: search)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        wait(for: NSPredicate(format: "exists == false"), on: app.staticTexts["message-30000000-0000-4000-8000-000000000003"])
        XCTAssertFalse(app.buttons["search-online"].isEnabled)
        app.buttons["search-filters"].click()
        let draft = app.descendants(matching: .any).matching(identifier: "search-filter-query").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 3))
        attachWindow(app, named: "Phase 4 - search filters")
        pasteQuery("after:2026-02-30", into: draft)
        XCTAssertTrue(app.staticTexts["search-filter-error"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["apply-search-filters"].isEnabled)
        pasteQuery("filename:Materialstudie", into: draft)
        wait(for: NSPredicate(format: "enabled == true"), on: app.buttons["apply-search-filters"])
        app.buttons["apply-search-filters"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        selectAppearance("Hell", in: app); app.typeKey("w", modifierFlags: .command)
        attachWindow(app, named: "Phase 4 - local field search - light")
        app.buttons["search-coverage"].click()
        XCTAssertTrue(app.staticTexts["Suchabdeckung"].waitForExistence(timeout: 3))
        attachWindow(app, named: "Phase 4 - search coverage")
        app.staticTexts["mailbox-title"].click()
        assertValue("filename:Materialstudie", of: search)
        selectAppearance("Dunkel", in: app); app.typeKey("w", modifierFlags: .command)
        // Capture a freshly composed dark window and verify the saved appearance
        // across launch; live appearance transitions can yield partial screenshots.
        app.terminate(); app.launch(); app.activate()
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey("f", modifierFlags: .command); pasteQuery("filename:Materialstudie", into: search)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        attachWindow(app, named: "Phase 4 - local field search - dark")
        app.typeKey("f", modifierFlags: .command); search.typeKey("a", modifierFlags: .command); search.typeText(XCUIKeyboardKey.delete.rawValue)
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey(",", modifierFlags: .command); selectSettingsTab("Konten", in: app)
        let account = "10000000-0000-4000-8000-000000000001"
        app.buttons["edit-account-\(account)"].click()
        app.checkBoxes["text-index-enabled"].click(); app.buttons["save-account-settings"].click()
        wait(for: NSPredicate(format: "exists == false"), on: app.buttons["save-account-settings"])
        selectSettingsTab("Speicher", in: app)
        assertValue("1 von 10 Nachrichten", of: app.staticTexts["text-coverage"])
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("f", modifierFlags: .command); search.typeText("Kupferton")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        // Clear texts from an unfiltered view too: automatic demo selection must
        // not recreate an extract immediately after deletion.
        search.typeKey("a", modifierFlags: .command); search.typeText(XCUIKeyboardKey.delete.rawValue)
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey(",", modifierFlags: .command); selectSettingsTab("Konten", in: app)
        app.menuButtons["account-index-actions-\(account)"].click()
        app.menuItems["Textextrakte löschen …"].click()
        XCTAssertTrue(app.buttons["confirm-local-action"].waitForExistence(timeout: 3))
        app.buttons["confirm-local-action"].click()
        selectSettingsTab("Speicher", in: app)
        assertValue("0 von 10 Nachrichten", of: app.staticTexts["text-coverage"])
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("f", modifierFlags: .command); search.typeText("Kupferton")
        wait(for: NSPredicate(format: "exists == false"), on: first)
        app.terminate()
    }
    func testPhaseThreeConversationHTMLAndConfirmedDemoActions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        let subject = app.staticTexts["message-subject"]
        assertValue("Die nächste Version nimmt Form an", of: subject)
        let firstID = "30000000-0000-4000-8000-000000000001"
        let replyID = "30000000-0000-4000-8000-000000000009"
        let reply = app.buttons["thread-message-\(replyID)"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5)); reply.click()
        assertValue("Danke für die Materialmuster", of: subject)
        app.buttons["thread-message-\(firstID)"].click()
        assertValue("Die nächste Version nimmt Form an", of: subject)

        let mark = app.buttons["mark-read"], flag = app.buttons["toggle-flag"]
        app.typeKey("u", modifierFlags: [.command, .shift])
        wait(for: NSPredicate(format: "label == %@", "Ungelesen"), on: mark)
        app.typeKey("u", modifierFlags: [.command, .shift])
        wait(for: NSPredicate(format: "label == %@", "Gelesen"), on: mark)
        flag.click()
        wait(for: NSPredicate(format: "label == %@", "Als Favorit markieren"), on: flag)
        flag.click()
        wait(for: NSPredicate(format: "label == %@", "Favorit entfernen"), on: flag)

        selectAppearance("Hell", in: app)
        app.typeKey("w", modifierFlags: .command)

        let format = app.descendants(matching: .any).matching(identifier: "body-format").firstMatch
        let html = format.descendants(matching: .any).matching(NSPredicate(format: "label == 'HTML'")).firstMatch
        XCTAssertTrue(html.waitForExistence(timeout: 5)); html.click()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["remote-images"].exists)
        XCTAssertFalse(app.buttons["Für diese Nachricht laden"].exists)
        attachWindow(app, named: "Phase 3 - safe HTML and conversation - light")
        selectAppearance("Dunkel", in: app)
        app.typeKey("w", modifierFlags: .command)
        attachWindow(app, named: "Phase 3 - safe HTML and conversation - dark")
        let exampleLink = app.webViews.firstMatch.links.firstMatch
        XCTAssertTrue(exampleLink.waitForExistence(timeout: 5))
        let detailScroll = app.scrollViews.containing(.staticText, identifier: "message-subject").firstMatch
        for _ in 0..<4 where !exampleLink.isHittable { detailScroll.scroll(byDeltaX: 0, deltaY: -250) }
        XCTAssertTrue(exampleLink.isHittable); exampleLink.click()
        XCTAssertTrue(app.buttons["Im Browser öffnen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "https://example.com/demo")).firstMatch.exists)
        app.buttons["Abbrechen"].click()
        format.descendants(matching: .any).matching(NSPredicate(format: "label == 'Text'")).firstMatch.click()

        let archive = app.buttons["archive-message"]
        XCTAssertTrue(archive.isEnabled); archive.click()
        XCTAssertFalse(app.buttons["confirm-message-move"].exists)
        wait(for: NSPredicate(format: "exists == false"), on: app.staticTexts["message-\(firstID)"])
        app.buttons["sidebar-role-archive"].click()
        assertValue("Die nächste Version nimmt Form an", of: subject)
        app.buttons["trash-message"].click()
        XCTAssertFalse(app.buttons["confirm-message-move"].exists)
        app.buttons["sidebar-role-trash"].click()
        assertValue("Die nächste Version nimmt Form an", of: subject)
        app.typeKey("1", modifierFlags: .command)
        wait(for: NSPredicate(format: "exists == false"), on: app.staticTexts["message-\(firstID)"])
        app.terminate()
    }
    func testIMAPAccountFormValidatesAndCancelsWithoutConnecting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch(); app.activate()
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey(",", modifierFlags: .command)
        selectSettingsTab("Konten", in: app)
        let add = app.buttons["add-imap-account"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
        let connect = app.buttons["imap-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 3)); XCTAssertFalse(connect.isEnabled)
        let address = app.textFields["imap-address"]
        address.click(); address.typeText("reader@example.invalid")
        assertValue("reader@example.invalid", of: app.textFields["imap-username"])
        let host = app.textFields["imap-host"]
        host.click(); host.typeText("https://mail.example.invalid")
        let password = app.secureTextFields["imap-password"]
        XCTAssertTrue(password.exists)
        password.click(); password.typeText("synthetic-only")
        app.checkBoxes["imap-consent"].click()
        XCTAssertFalse(connect.isEnabled)
        host.click(); host.typeKey("a", modifierFlags: .command); host.typeText("mail.example.invalid")
        wait(for: NSPredicate(format: "enabled == true"), on: connect)
        attachSettings(app, named: "Phase 2 - IMAP account form - synthetic fields")
        app.buttons["imap-cancel"].click()
        wait(for: NSPredicate(format: "exists == false"), on: connect)
        selectSettingsTab("Speicher", in: app)
        assertValue("3 / 10", of: app.staticTexts["storage-counts"])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.buttons["sync-mail"].isEnabled)
        app.terminate()
    }

    func testReadNavigateAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        let title = app.staticTexts["mailbox-title"]
        let subject = app.staticTexts["message-subject"]
        let firstMessage = app.staticTexts["message-30000000-0000-4000-8000-000000000001"]
        let lakeMessage = app.staticTexts["message-30000000-0000-4000-8000-000000000003"]
        let search = app.searchFields["mail-search"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        assertValue("Alle Posteingänge", of: title)
        assertValue("Die nächste Version nimmt Form an", of: subject)

        selectAppearance("Hell", in: app)
        app.typeKey("w", modifierFlags: .command)
        attachWindow(app, named: "Native demo - light inbox")

        app.typeKey("2", modifierFlags: .command)
        assertValue("Ungelesen", of: title)
        XCTAssertTrue(lakeMessage.waitForExistence(timeout: 3))
        lakeMessage.click()
        assertValue("Am Samstag an den See?", of: subject)

        app.typeKey("f", modifierFlags: .command)
        search.typeText("Materialstudie")
        assertValue("Materialstudie", of: search)
        XCTAssertTrue(firstMessage.waitForExistence(timeout: 3))
        wait(for: NSPredicate(format: "exists == false"), on: lakeMessage)
        firstMessage.click()
        assertValue("Die nächste Version nimmt Form an", of: subject)
        app.typeKey("f", modifierFlags: .command)
        search.typeKey("a", modifierFlags: .command)
        search.typeText(XCUIKeyboardKey.delete.rawValue)
        assertValue("", of: search)
        app.typeKey("1", modifierFlags: .command)
        assertValue("Alle Posteingänge", of: title)

        selectAppearance("Dunkel", in: app)
        app.typeKey("w", modifierFlags: .command)
        attachWindow(app, named: "Native demo - dark inbox")
        app.terminate()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        assertValue("Die nächste Version nimmt Form an", of: subject)
        app.typeKey(",", modifierFlags: .command)
        let dark = appearanceChoice("Dunkel", in: app)
        XCTAssertTrue(dark.waitForExistence(timeout: 3))
        assertSelected(dark)
        appearanceChoice("System", in: app).click()
        app.typeKey("w", modifierFlags: .command)
        app.terminate()
    }

    func testPersistentAccountSettingsAndLocalMaintenance() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["MIKE_MAIL_UI_TEST_ID"] = UUID().uuidString
        app.launch()
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey(",", modifierFlags: .command)
        selectSettingsTab("Konten", in: app)
        let accountID = "10000000-0000-4000-8000-000000000001"
        let edit = app.buttons["edit-account-\(accountID)"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3)); edit.click()
        let name = app.textFields["account-display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Mein Testatelier")
        app.checkBoxes["text-index-enabled"].click()
        app.buttons["save-account-settings"].click()
        wait(for: NSPredicate(format: "exists == false"), on: name)
        selectSettingsTab("Speicher", in: app)
        assertValue("3 / 10", of: app.staticTexts["storage-counts"])
        assertValue("1 von 10 Nachrichten", of: app.staticTexts["text-coverage"])
        attachSettings(app, named: "Phase 1 - encrypted storage")
        app.terminate(); app.launch()
        assertValue("Die nächste Version nimmt Form an", of: app.staticTexts["message-subject"])
        app.typeKey(",", modifierFlags: .command)
        selectSettingsTab("Konten", in: app)
        edit.click()
        assertValue("Mein Testatelier", of: name)
        assertSelected(app.checkBoxes["text-index-enabled"])
        app.checkBoxes["text-index-enabled"].click()
        app.buttons["save-account-settings"].click()
        wait(for: NSPredicate(format: "exists == false"), on: name)
        selectSettingsTab("Speicher", in: app)
        assertValue("0 von 10 Nachrichten", of: app.staticTexts["text-coverage"])
        selectSettingsTab("Konten", in: app)
        app.buttons["remove-account-\(accountID)"].click()
        app.buttons["confirm-local-action"].click()
        wait(for: NSPredicate(format: "exists == false"), on: edit)
        selectSettingsTab("Speicher", in: app)
        assertValue("2 / 6", of: app.staticTexts["storage-counts"])
        app.buttons["rebuild-index"].click(); app.buttons["confirm-local-action"].click()
        assertValue("2 / 6", of: app.staticTexts["storage-counts"])
        wait(for: NSPredicate(format: "enabled == true"), on: app.buttons["clear-local-data"])
        app.buttons["clear-local-data"].click(); app.buttons["confirm-local-action"].click()
        assertValue("0 / 0", of: app.staticTexts["storage-counts"])
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["mailbox-title"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        selectSettingsTab("Speicher", in: app)
        assertValue("0 / 0", of: app.staticTexts["storage-counts"])
        app.buttons["restore-demo-data"].click()
        assertValue("3 / 10", of: app.staticTexts["storage-counts"])
        app.buttons["clear-local-data"].click(); app.buttons["confirm-local-action"].click()
        assertValue("0 / 0", of: app.staticTexts["storage-counts"])
        app.terminate()
    }

    private func selectSettingsTab(_ name: String, in app: XCUIApplication) {
        let tab = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 3)); tab.click()
    }
    /// XCUITest's key mapping drops ':' on the current Swiss keyboard layout.
    /// Paste through the real field editor, retaining the user's clipboard in RAM only.
    private func pasteQuery(_ value: String, into field: XCUIElement) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); if !saved.isEmpty { board.writeObjects(saved) } }
        field.click(); field.typeKey("a", modifierFlags: .command)
        board.clearContents(); board.setString(value, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        assertValue(value, of: field)
    }
    private func attachSettings(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func appearanceChoice(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let picker = app.descendants(matching: .any).matching(identifier: "appearance-picker").firstMatch
        return picker.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func selectAppearance(_ name: String, in app: XCUIApplication) {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        selectSettingsTab("Darstellung", in: app)
        let choice = appearanceChoice(name, in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: 3))
        app.activate()
        choice.click()
        assertSelected(choice)
    }

    private func assertSelected(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(for: NSPredicate(format: "value == 1 OR value == %@ OR selected == true", "1"), on: element, file: file, line: line)
    }

    private func assertValue(_ value: String, of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        wait(for: NSPredicate(format: "value == %@", value), on: element, file: file, line: line)
    }

    private func wait(for predicate: NSPredicate, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed {
            let state = XCTAttachment(string: XCUIApplication().debugDescription)
            state.name = "Demo accessibility state at failure"
            state.lifetime = .keepAlways
            add(state)
        }
        XCTAssertEqual(result, .completed,
                       "Expected \(predicate) for \(element)", file: file, line: line)
    }

    private func attachWindow(_ app: XCUIApplication, named name: String) {
        let window = app.windows["inbox"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        // Allow the native appearance transition to finish compositing before capturing pixels.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
