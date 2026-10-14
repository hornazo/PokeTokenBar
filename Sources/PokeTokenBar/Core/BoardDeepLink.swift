import Foundation

/// `poketokenbar://boards/join?code=XXXX-XXXX-XXXX`, opened from the trainer page's join view. The app
/// always asks before joining; a link only fills in the code.
enum BoardDeepLink: Equatable {
    case join(BoardCode)

    static func parse(_ url: URL) -> BoardDeepLink? {
        guard url.scheme?.lowercased() == "poketokenbar", url.host?.lowercased() == "boards",
              url.path == "/join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value.flatMap(BoardCode.init) else { return nil }
        return .join(code)
    }
}
