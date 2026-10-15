import Foundation
import Security

/// Test pairing is injected locally before signing, never shipped in CI artifacts.
struct PhoneRelayPairing {
    let token: String
    let root: SecCertificate

    static func load() -> PhoneRelayPairing? {
        guard let url = Bundle.main.url(forResource: "GlitchifyRelayPairing", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let token = raw["token"] as? String, token.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let der = raw["root"] as? Data,
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return PhoneRelayPairing(token: token, root: certificate)
    }
    func verify(_ trust: SecTrust) -> Bool {
        // Fixed identity plus a private, app-local anchor. Normal TLS signature,
        // validity and hostname checks still run; system trust is not modified.
        guard SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "glitchify.local" as CFString)) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}
