import CryptoKit
import Foundation

public enum OAuthClientAuth: String, Sendable {
    case basicSecret
    case formSecret
    case pkce

    public var requiresClientSecret: Bool {
        self == .basicSecret || self == .formSecret
    }
}

public enum OAuthPKCE {
    public static func randomToken(byteCount: Int = 32) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OAuthForm {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }
}

public struct OAuthGrant: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String?
    public var expiresAt: Date?
    public var scope: String?

    public var scopes: Set<String> {
        Set((scope ?? "").split { $0 == "," || $0.isWhitespace }.map(String.init))
    }
}

public enum OAuthGrantError: Error, Equatable {
    case provider(String)
    case invalid
}

extension OAuthGrant {
    public static func parse(_ data: Data, now: Date = Date()) throws -> OAuthGrant {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw OAuthGrantError.invalid
        }
        if let error = object["error"] as? String, let description = object["error_description"] as? String {
            throw OAuthGrantError.provider("\(error): \(description)")
        }
        if object["access_token"] == nil, let user = object["authed_user"] as? [String: Any] {
            object = user
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthGrantError.invalid
        }
        let scope: String?
        if let text = object["scope"] as? String {
            scope = text
        } else if let list = object["scope"] as? [String] {
            scope = list.joined(separator: " ")
        } else {
            scope = nil
        }
        return OAuthGrant(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            tokenType: object["token_type"] as? String,
            expiresAt: (object["expires_in"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) },
            scope: scope
        )
    }
}

public enum OAuthTokenRequest {
    public static func make(
        to endpoint: URL,
        auth: OAuthClientAuth,
        clientID: String,
        clientSecret: String?,
        fields: [(String, String)]
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let secret = clientSecret.flatMap { $0.isEmpty ? nil : $0 }
        switch auth {
        case .basicSecret:
            let credentials = Data("\(clientID):\(secret ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONValue.object(Dictionary(fields, uniquingKeysWith: { $1 }).mapValues { .string($0) }).data()
        case .formSecret, .pkce:
            var all = fields + [("client_id", clientID)]
            if let secret { all.append(("client_secret", secret)) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(OAuthForm.encode(all).utf8)
        }
        return request
    }
}
