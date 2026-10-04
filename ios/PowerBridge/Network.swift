import Foundation
import CryptoKit
import Security
import Darwin

final class PinnedDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let pin: String
    init(pin: String) { self.pin = pin.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).hex == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum API {
    static func request(_ e: Endpoint, command: String? = nil, target: String = "", delay: Int = 10) async throws -> PCStatus {
        let path = command == nil ? "/v1/status" : "/v1/action"
        let base = e.url.hasSuffix("/") ? String(e.url.dropLast()) : e.url
        guard let url = URL(string: base + path), let secret = Data(hex: e.secret) else {
            throw PBError.message("Invalid pairing")
        }
        let body = try command.map { try JSONSerialization.data(withJSONObject: ["action": $0, "target": target, "delay": delay], options: [.sortedKeys]) } ?? Data()
        let method = command == nil ? "GET" : "POST"
        let stamp = String(Int(Date().timeIntervalSince1970))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let payload = [method,path,stamp,nonce,Data(SHA256.hash(data: body)).hex].joined(separator: "\n")
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: secret))).hex
        var req = URLRequest(url: url); req.httpMethod = method
        if command != nil { req.httpBody = body }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(stamp, forHTTPHeaderField: "X-PB-Time")
        req.setValue(nonce, forHTTPHeaderField: "X-PB-Nonce")
        req.setValue(sig, forHTTPHeaderField: "X-PB-Signature")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: PinnedDelegate(pin: e.pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw PBError.message(info?["error"] as? String ?? "PC returned an error")
        }
        return try JSONDecoder().decode(PCStatus.self, from: data)
    }
    static func online(_ pc: Computer) async throws -> (Endpoint, PCStatus) {
        var reason = "No PC endpoint paired. Import pairing.json from your PC."
        for e in pc.endpoints where e.role == "pc" {
            try Task.checkCancellation()
            do { return (e, try await request(e)) }
            catch { reason = error.localizedDescription }
        }
        throw PBError.message("PC unreachable: \(reason)")
    }
    static func wake(_ pc: Computer) async throws -> String {
        if let e = pc.endpoints.first(where: { $0.role == "relay" }) {
            let state = try await request(e, command: "wake")
            if state.dry_run { throw PBError.message("Relay is in test mode; no wake packet was sent.") }
            return "Wake packet sent by relay."
        }
        try directWake(pc)
        return "Wake packet sent. Delivery does not confirm the PC is awake."
    }
    static func directWake(_ pc: Computer) throws {
        #if DIRECT_WOL
        guard let mac = Data(hex: pc.mac.replacingOccurrences(of: ":", with: "")), mac.count == 6 else {
            throw PBError.message("Invalid MAC address")
        }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PBError.message("Cannot open wake socket") }
        defer { close(fd) }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw PBError.message("Broadcast permission unavailable")
        }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(9).bigEndian
        guard pc.broadcast.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw PBError.message("Invalid broadcast IPv4 address")
        }
        var packet = Data(repeating: 255, count: 6)
        for _ in 0..<16 { packet.append(mac) }
        for _ in 0..<3 {
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { throw PBError.message("Wake broadcast failed. Check Wi-Fi, local network permission, and the multicast entitlement.") }
        }
        #else
        throw PBError.message("Pair an always-on relay to wake your PC. Direct wake is available in the optional Apple multicast-entitled build; see README.")
        #endif
    }
}
