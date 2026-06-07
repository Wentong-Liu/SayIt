import Foundation
import CryptoKit

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(digest).base64URLEncodedString()
    }

    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return PKCE(verifier: Data(bytes).base64URLEncodedString())
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
