// Checking for a newer CacheBar: once a day (and from Settings), the latest GitHub
// release is compared with this build's version. A newer one is announced once per
// version; clicking the notification (or the menu item) opens its release page.
// Nothing is downloaded or installed. The request carries only a generic
// User-Agent with the app's version.
import AppKit
import Foundation

let updateCheckEvery: TimeInterval = 24 * 3600 / timeScale

struct Release: Equatable {
    let version: String
    let page: URL
}

enum Updates {
    /// CACHEBAR_UPDATE_URL points elsewhere (tests: a file:// JSON fixture).
    static var feed: URL {
        URL(string: appEnv["CACHEBAR_UPDATE_URL"] ?? "")
            ?? URL(string: "https://api.github.com/repos/michieltimmerman/cachebar/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    }

    /// "v1.2.3" / "1.2.3-beta" → [1, 2, 3]; nil when it isn't a version.
    static func numbers(_ v: String) -> [Int]? {
        let core = (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: "-").first ?? ""
        let parts = core.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// a > b, comparing numerically; a pre-release of the same numbers is not newer.
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = numbers(a), let y = numbers(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The latest published release, or an error message; `done` runs on main.
    static func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var req = URLRequest(url: feed, timeoutInterval: 30)
        req.setValue("CacheBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result<Release, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(Failure("HTTP \(http.statusCode)"))
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = (json["html_url"] as? String).flatMap(URL.init(string:)) {
                result = .success(Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page))
            } else {
                result = .failure(Failure("unexpected answer"))
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Opens a release page; CACHEBAR_OPEN_DRY_RUN=1 only logs it (tests).
    static func open(_ url: URL) {
        debug("opening \(url.absoluteString)")
        if appEnv["CACHEBAR_OPEN_DRY_RUN"] == "1" { return }
        NSWorkspace.shared.open(url)
    }
}
