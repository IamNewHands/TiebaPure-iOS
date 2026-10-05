import Foundation

/// Destination parsed from an externally supplied link: the custom
/// tiebapure:// scheme or a validated tieba.baidu.com HTTPS URL.
enum ExternalRoute: Equatable, Identifiable {
    private static let maximumForumNameCharacters = 100

    case thread(id: Int64, postID: UInt64?)
    case forum(name: String)

    var id: String {
        switch self {
        case let .thread(id, postID):
            return "thread-\(id)-\(postID.map(String.init) ?? "")"
        case let .forum(name):
            return "forum-\(name)"
        }
    }

    /// Accepted shapes:
    /// - tiebapure://thread/<id>[?pid=<postID>]
    /// - tiebapure://forum/<名字> and tiebapure://forum?kw=<名字>
    /// - tiebapure://open?url=<percent-encoded HTTPS tieba.baidu.com URL>
    /// - https://tieba.baidu.com/p/<id>[?pid=…] (including *.tieba.baidu.com)
    /// - https://tieba.baidu.com/f?kw=<名字>
    static func parse(_ url: URL) -> ExternalRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "tiebapure":
            return parseCustomScheme(components)
        case "https":
            return parseWebURL(components)
        default:
            return nil
        }
    }

    /// Wraps a supported Tieba webpage in the app's custom URL scheme. This is
    /// shared with the Safari Action Extension so unsupported or deceptive
    /// hosts never reach the containing app.
    static func importURL(forWebURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", parse(url) != nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "tiebapure"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }

    private static func parseCustomScheme(_ components: URLComponents) -> ExternalRoute? {
        guard components.user == nil, components.password == nil else {
            return nil
        }
        let pathParts = components.path.split(separator: "/").map(String.init)
        switch components.host?.lowercased() {
        case "thread":
            guard let idText = pathParts.first, let id = Int64(idText), id > 0 else {
                return nil
            }
            return .thread(id: id, postID: queryPostID(components))
        case "forum":
            let name = pathParts.first ?? queryValue(components, name: "kw") ?? ""
            return forumRoute(name: name)
        case "open":
            guard let nested = queryValue(components, name: "url"),
                  let nestedURL = URL(string: nested),
                  let nestedComponents = URLComponents(url: nestedURL, resolvingAgainstBaseURL: false) else {
                return nil
            }
            return parseWebURL(nestedComponents)
        default:
            return nil
        }
    }

    private static func parseWebURL(_ components: URLComponents) -> ExternalRoute? {
        guard components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "tieba.baidu.com" || host.hasSuffix(".tieba.baidu.com") || host == "tiebac.baidu.com" else {
            return nil
        }
        let pathParts = components.path.split(separator: "/").map(String.init)
        if pathParts.count >= 2, pathParts[0] == "p",
           let id = Int64(pathParts[1]), id > 0 {
            return .thread(id: id, postID: queryPostID(components))
        }
        if pathParts.first == "f" || components.path.isEmpty || components.path == "/",
           let keyword = queryValue(components, name: "kw") {
            return forumRoute(name: keyword)
        }
        return nil
    }

    private static func forumRoute(name: String) -> ExternalRoute? {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("吧") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalized.isEmpty == false,
              normalized.count <= maximumForumNameCharacters else { return nil }
        return .forum(name: normalized)
    }

    private static func queryPostID(_ components: URLComponents) -> UInt64? {
        for name in ["pid", "post_id"] {
            if let value = queryValue(components, name: name),
               let id = UInt64(value),
               id > 0,
               id <= UInt64(Int64.max) {
                return id
            }
        }
        return nil
    }

    private static func queryValue(_ components: URLComponents, name: String) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }
}
