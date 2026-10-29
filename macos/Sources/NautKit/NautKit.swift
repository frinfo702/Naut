import CNaut
import Foundation

/// Rendering. Pure functions over libnaut; safe from any thread.
public enum Markdown {
    /// An HTML fragment: the contents of `<main>`.
    public static func html(_ source: String) -> String {
        withBytes(source) { take(naut_render_html($0, $1)) }
    }

    /// A complete page with styles and scripts. Published pages want the
    /// outline sidebar (`toc`); the app draws its own.
    public static func page(_ source: String, title: String, toc: Bool) -> String {
        withBytes(title) { titlePtr, titleLen in
            var opts = naut_page_options_s(title: titlePtr, title_len: titleLen, toc: toc)
            return withBytes(source) { take(naut_render_page($0, $1, &opts)) }
        }
    }

    public static func outline(_ source: String) -> [Heading] {
        let json = withBytes(source) { take(naut_outline_json($0, $1)) }
        return (try? JSONDecoder().decode([Heading].self, from: Data(json.utf8))) ?? []
    }
}

public struct Heading: Decodable, Hashable, Sendable {
    public let level: Int
    public let text: String
    /// The element id in rendered HTML, for scrolling to it.
    public let id: String
}

/// Publishing to Cloudflare. Every call blocks on the network (and, for
/// provision, on Terraform), so they run on a detached task.
public struct Cloudflare: Sendable {
    public var accountID: String
    public var apiToken: String

    public init(accountID: String, apiToken: String) {
        self.accountID = accountID
        self.apiToken = apiToken
    }

    public struct Site: Codable, Hashable, Sendable {
        public let namespaceID: String
        public let url: URL

        enum CodingKeys: String, CodingKey {
            case namespaceID = "namespace_id"
            case url
        }
    }

    /// Create or update the KV namespace and Worker. `workdir` keeps the
    /// Terraform state and must survive between runs.
    public func provision(workdir: URL) async throws -> Site {
        let path = workdir.path
        let json = try await run { cf, out in naut_cloudflare_provision(cf, path, out) }
        return try JSONDecoder().decode(Site.self, from: Data(json.utf8))
    }

    public func put(_ site: Site, key: String, value: String) async throws {
        _ = try await run { cf, out in
            withBytes(value) { naut_cloudflare_put(cf, site.namespaceID, key, $0, $1, out) }
        }
    }

    public func delete(_ site: Site, key: String) async throws {
        _ = try await run { cf, out in naut_cloudflare_delete(cf, site.namespaceID, key, out) }
    }

    private func run(
        _ body: @escaping @Sendable (UnsafePointer<naut_cloudflare_s>, UnsafeMutablePointer<naut_string_s>) -> Bool
    ) async throws -> String {
        try await Task.detached { [accountID, apiToken] in
            try accountID.withCString { account in
                try apiToken.withCString { token in
                    var cf = naut_cloudflare_s(account_id: account, api_token: token)
                    var out = naut_string_s()
                    let ok = body(&cf, &out)
                    let message = take(out)
                    guard ok else { throw PublishError(message: message) }
                    return message
                }
            }
        }.value
    }
}

public struct PublishError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

private func withBytes<R>(_ string: String, _ body: (UnsafePointer<CChar>?, Int) -> R) -> R {
    var string = string
    return string.withUTF8 { buf in
        body(buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, buf.count)
    }
}

/// Copy a library-owned string into Swift and free it.
private func take(_ s: naut_string_s) -> String {
    defer { naut_string_free(s) }
    guard let ptr = s.ptr, s.len > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: ptr, count: s.len), as: UTF8.self)
}
