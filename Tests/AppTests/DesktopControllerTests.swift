import Foundation
import Testing
import MailDomain
import MailApplication
import MailDemo
@testable import MikeMailHub

@MainActor private final class NotificationDouble: DesktopNotifications {
    var status = DesktopPermission.notRequested
    var grant = true
    var requests = 0
    var posted: [DesktopNotification] = []
    var cleared = 0
    func permission() async -> DesktopPermission { status }
    func requestPermission() async throws -> Bool { requests += 1; status = grant ? .allowed : .denied; return grant }
    func post(_ value: DesktopNotification) async throws { posted.append(value) }
    func clear() { cleared += 1 }
}
@MainActor private final class LoginDouble: DesktopLoginItem {
    var state = LoginItemState.disabled
    var operations: [Bool] = []
    func setEnabled(_ enabled: Bool) async throws { operations.append(enabled); state = enabled ? .approvalRequired : .disabled }
}

@MainActor @Suite(.serialized) struct DesktopControllerTests {
    @Test func defaultsStayOffAndOnlyExplicitControlsAskForPermissionOrLogin() async throws {
        let notifications = NotificationDouble(), login = LoginDouble()
        let controller = DesktopController(notifications: notifications, login: login)
        await controller.refreshSystemStatus()
        #expect(!controller.preferences.automaticSync && !controller.preferences.notifications && !controller.preferences.dockBadge)
        #expect(notifications.requests == 0 && login.operations.isEmpty)
        await controller.setNotifications(true)
        #expect(notifications.requests == 1 && controller.preferences.notifications)
        await controller.setLogin(true)
        #expect(login.operations == [true] && controller.loginState == .approvalRequired)
        await controller.setLogin(false)
        #expect(login.operations == [true, false] && controller.loginState == .disabled)
        await controller.setNotifications(false)
        notifications.grant = false
        await controller.setNotifications(true)
        #expect(!controller.preferences.notifications && controller.permission == .denied)
    }
    @Test func notificationsDefaultToPrivateContentAndAccountExclusionsApply() async throws {
        let notifications = NotificationDouble(), data = try SyntheticFixtures.make(), item = data.snapshot.messages[0]
        let controller = DesktopController(notifications: notifications)
        controller.update(accounts: [item.accountID], unread: 12, ready: true)
        let event = InboxNotificationDelta(newest: item, count: 3)
        await controller.deliver(event); #expect(notifications.posted.isEmpty && notifications.requests == 0)
        await controller.setNotifications(true)
        await controller.deliver(event)
        let posted = try #require(notifications.posted.first)
        #expect(posted.title == "CuMail" && !posted.body.contains(item.subject) && !posted.body.contains(item.sender.name))
        #expect(try DeepLinkParser.parse(posted.route) == .message(item.id))
        controller.setAccountNotifications(item.accountID, enabled: false)
        await controller.deliver(event); #expect(notifications.posted.count == 1)
        controller.setAccountNotifications(item.accountID, enabled: true); controller.setPreview(true)
        await controller.deliver(event)
        #expect(notifications.posted.last?.body == item.subject)
        controller.setPreview(false); #expect(notifications.cleared >= 2)
        #expect(DesktopController.safePreview("safe\n\u{202E}text") == "safetext")
    }
    @Test func eventsCoalesceAndOfflineSleepBackoffAndOptOutPreventWork() async throws {
        let now = Date(), account = try AccountID()
        let controller = DesktopController(clock: { now })
        var calls = 0
        controller.maySync = { true }
        controller.synchronize = { _ in calls += 1; try? await Task.sleep(for: .milliseconds(50)); return .retry(after: 600) }
        controller.update(accounts: [account], unread: 0, ready: true)
        await controller.runDue(now: now.addingTimeInterval(6)); #expect(calls == 0)
        controller.setAutomaticSync(true)
        await controller.runDue(now: now.addingTimeInterval(6)); #expect(calls == 0)
        controller.setNetworkAvailable(true); controller.setSleeping(true)
        await controller.runDue(now: now.addingTimeInterval(6)); #expect(calls == 0)
        controller.setSleeping(false)
        let first = Task { await controller.runDue(now: now.addingTimeInterval(6)) }
        try await wait { controller.isRunning }
        await controller.runDue(now: now.addingTimeInterval(6))
        await first.value; #expect(calls == 1)
        controller.setNetworkAvailable(false); controller.setNetworkAvailable(true)
        controller.setSleeping(true); controller.setSleeping(false)
        await controller.runDue(now: now.addingTimeInterval(100)); #expect(calls == 1)
        controller.setAccountSync(account, enabled: false)
        await controller.runDue(now: now.addingTimeInterval(700)); #expect(calls == 1)
        controller.setAccountSync(account, enabled: true)
        await controller.runDue(now: now.addingTimeInterval(700)); #expect(calls == 2)
        controller.record(.authenticationRequired, account: account, now: now)
        await controller.runDue(now: now.addingTimeInterval(100_000)); #expect(calls == 2)
    }
    @Test func quittingCancelsTheOwnedCycleAndNoLaterWakeRestartsIt() async throws {
        var now = Date(), started = false, cancelled = false
        let account = try AccountID(), controller = DesktopController(clock: { now })
        controller.maySync = { true }
        controller.synchronize = { _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)); return .success }
            catch { cancelled = true; return .cancelled }
        }
        controller.update(accounts: [account], unread: 0, ready: true)
        controller.setAutomaticSync(true); controller.setNetworkAvailable(true)
        now = now.addingTimeInterval(6); controller.requestCycle()
        try await wait { started }
        await controller.stop()
        #expect(cancelled && !controller.isRunning && !controller.permitsUserReads)
        started = false; controller.setSleeping(false); controller.requestCycle()
        try await Task.sleep(for: .milliseconds(30)); #expect(!started)
    }
    @Test func preferencesSurviveRestartWithoutImplicitSystemChanges() throws {
        let suite = "ch.kupferfunke.MikeMailHub.test.preferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = try AccountID(), first = DesktopController(defaults: defaults)
        first.setAutomaticSync(true); first.setBadge(true); first.setAccountSync(account, enabled: false)
        let second = DesktopController(defaults: defaults)
        #expect(second.preferences.automaticSync && second.preferences.dockBadge)
        #expect(second.preferences.excludedSyncAccounts == [account])
        #expect(second.loginState == .disabled && !second.isRunning)
    }
    @Test func localRoutesSelectExactTargetsRejectMismatchesAndMetadataRefreshDoesNotReloadBody() async throws {
        let data = try SyntheticFixtures.make(), model = InboxModel(dataset: data)
        await model.start(autoSelectDemo: false); try await wait { !model.isLoading }
        let target = data.snapshot.messages[0]
        #expect(await model.openRoute(MailRoute.message(target.id).url.absoluteString, expectedAccount: target.accountID))
        try await wait { !model.contentLoading }
        #expect(model.selectedMessage?.id == target.id && !model.content.isEmpty)
        model.content = "Content must survive metadata-only refresh"
        model.reload(autoSelectDemo: false, preserveDisplayedContent: true)
        try await wait { !model.isLoading }
        #expect(model.selectedMessage?.id == target.id && model.content == "Content must survive metadata-only refresh")
        let foreignAccount = try AccountID(), missingMessage = try MessageID()
        #expect(await model.openRoute(MailRoute.message(target.id).url.absoluteString, expectedAccount: foreignAccount) == false)
        #expect(model.selectedMessage?.id == target.id)
        #expect(await model.openRoute("mikemail://send/\(target.id)") == false)
        #expect(await model.openRoute(MailRoute.message(missingMessage).url.absoluteString) == false)
        let thread = try #require(target.threadID)
        #expect(await model.openRoute(MailRoute.thread(thread).url.absoluteString))
        #expect(model.selectedMessage?.accountID == target.accountID)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
