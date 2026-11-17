import Foundation

public enum MailRoute: Equatable, Sendable { case message(MessageID), thread(ThreadID) }
public enum DeepLinkError: Error, Equatable { case invalid, forbidden, notFound }

public enum DeepLinkParser {
    /// Navigation only. OAuth callbacks and mailto are separate future contracts.
    public static func parse(_ raw: String) throws -> MailRoute {
        guard raw.utf8.count <= 128, !raw.contains("%"), !raw.contains("\\"),
              let url = URLComponents(string: raw), ["cumail", "mikemail"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { throw DeepLinkError.invalid }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, path[0].isEmpty, path[1].count == 36 else { throw DeepLinkError.invalid }
        do {
            switch url.host {
            case "message": return .message(try MessageID(string: String(path[1])))
            case "thread": return .thread(try ThreadID(string: String(path[1])))
            default: throw DeepLinkError.invalid
            }
        } catch { throw DeepLinkError.invalid }
    }

    public static func authorize(_ route: MailRoute, snapshot: MailSnapshot, allowedAccounts: Set<AccountID>) throws {
        let owner: AccountID?
        switch route {
        case .message(let id): owner = snapshot.messages.first(where: { $0.id == id })?.accountID
        case .thread(let id): owner = snapshot.threads.first(where: { $0.id == id })?.accountID
        }
        guard let owner else { throw DeepLinkError.notFound }
        guard allowedAccounts.contains(owner) else { throw DeepLinkError.forbidden }
    }
}
