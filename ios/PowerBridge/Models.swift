import Foundation
import Security
import CryptoKit

struct Endpoint: Codable, Hashable {
    var url: String
    var secret: String
    var pin: String
    var role: String
    var os: String
}
struct Computer: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var mac: String
    var broadcast: String
    var endpoints: [Endpoint]
    func validate() throws {
        guard !id.isEmpty, !name.isEmpty, endpoints.count > 0, endpoints.count <= 8,
              mac.range(of: "^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", options: .regularExpression) != nil else {
            throw PBError.message("Invalid pairing file.")
        }
        for e in endpoints {
            guard let u = URL(string: e.url), u.scheme == "https", u.host != nil,
                  u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
                  u.path.isEmpty || u.path == "/",
                  ["pc", "relay"].contains(e.role),
                  Data(hex: e.secret)?.count == 32, Data(hex: e.pin)?.count == 32 else {
                throw PBError.message("Pairing must contain HTTPS, a valid secret, and a certificate fingerprint.")
            }
        }
    }
}
struct Pending: Codable { let action: String; let target: String; let at: Int }
struct Event: Codable, Identifiable {
    let time: Int; let message: String
    var id: String { "\(time)-\(message)" }
}
struct PCStatus: Codable {
    let name: String; let os: String; let role: String; let dry_run: Bool
    let uptime: Int; let boot_targets: [String]; let pending: Pending?; let history: [Event]
}
enum PBError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var output = Data(); var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            output.append(b); i = next
        }
        self = output
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum Vault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "PowerBridge", kSecAttrAccount as String: "computers"]
    }
    static func load() throws -> [Computer] {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return [] }
        guard code == errSecSuccess, let data = result as? Data else {
            throw PBError.message("Could not unlock saved pairing data (\(code)).")
        }
        return try JSONDecoder().decode([Computer].self, from: data)
    }
    static func save(_ computers: [Computer]) throws {
        let data = try JSONEncoder().encode(computers)
        let values: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var code = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if code == errSecItemNotFound {
            code = SecItemAdd(query.merging(values) { _, b in b } as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw PBError.message("Could not save pairing (\(code)).") }
    }
}
