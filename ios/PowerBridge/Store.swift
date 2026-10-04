import SwiftUI
import LocalAuthentication

@MainActor
final class Store: ObservableObject {
    @Published var computers: [Computer] = []
    @Published var selectedID: String = ""
    @Published var status: PCStatus?
    @Published var connection = "Not connected"
    @Published var notice = ""
    @Published var busy = false
    @Published var waking = false
    @Published var chosenOS = ""
    @Published var delay = 10
    var endpoint: Endpoint?
    var wakeTask: Task<Void, Never>?
    private var refreshing = false
    var selected: Computer? { computers.first { $0.id == selectedID } }
    init() {
        do { computers = try Vault.load(); selectedID = computers.first?.id ?? "" }
        catch { notice = error.localizedDescription }
    }
    func select(_ id: String) {
        stopWake(); selectedID = id; status = nil; endpoint = nil; chosenOS = ""
        connection = "Checking connection…"
    }
    func importPairing(_ text: String) throws {
        guard let data = text.data(using: .utf8), data.count <= 16384 else { throw PBError.message("Pairing file too large") }
        let incoming = try JSONDecoder().decode(Computer.self, from: data); try incoming.validate()
        var updated = computers
        if let i = updated.firstIndex(where: { $0.id == incoming.id }) {
            for e in incoming.endpoints {
                updated[i].endpoints.removeAll { $0.role == e.role && $0.os == e.os }
                updated[i].endpoints.append(e)
            }
            updated[i].mac = incoming.mac; updated[i].broadcast = incoming.broadcast; updated[i].name = incoming.name
        } else { updated.append(incoming) }
        try Vault.save(updated); computers = updated; select(incoming.id)
        notice = "Paired securely. Check the connection, then try a test-mode action."
    }
    func forget() throws {
        let updated = computers.filter { $0.id != selectedID }
        try Vault.save(updated); computers = updated; select(updated.first?.id ?? "")
    }
    func refresh() async {
        guard let pc = selected, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let (e,s) = try await API.online(pc)
            guard selectedID == pc.id else { return }
            endpoint = e; status = s; connection = "Connected securely"
        } catch {
            guard selectedID == pc.id else { return }
            endpoint = nil; status = nil; connection = error.localizedDescription
        }
    }
    func authenticate() async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Confirm this computer power action") else {
            throw PBError.message("Authentication cancelled")
        }
    }
    func perform(_ action: String) async {
        guard !busy, let pc = selected else { return }
        busy = true; defer { busy = false }
        do {
            if action != "cancel" { try await authenticate() }
            let (e,_) = try await API.online(pc)
            let result = try await API.request(e, command: action, target: action == "cancel" ? "" : chosenOS, delay: delay)
            if selectedID == pc.id { status = result; endpoint = e }
            notice = action == "cancel" ? "Countdown cancelled." : "Command accepted. You can cancel it before the countdown ends."
        } catch { notice = "\(error.localizedDescription) If the connection dropped after sending, refresh before retrying; the PC may have accepted the command." }
    }
    func startWake() {
        guard !busy, !waking, let pc = selected else { return }
        let target = chosenOS
        waking = true
        wakeTask = Task {
            defer { waking = false; wakeTask = nil }
            do {
                try await authenticate(); try Task.checkCancellation()
                notice = try await API.wake(pc)
                if target.isEmpty { return }
                notice = "Wake sent. Keep the app open while I wait for the PC, then switch to \(target.capitalized)."
                let deadline = Date().addingTimeInterval(150)
                while Date() < deadline {
                    try Task.checkCancellation()
                    if let (e, state) = try? await API.online(pc) {
                        try Task.checkCancellation()
                        guard !state.dry_run else { throw PBError.message("PC companion is in test mode. OS switch was not sent.") }
                        if state.os == target {
                            status = state; endpoint = e; notice = "Your PC is running \(target.capitalized)."; return
                        }
                        guard state.boot_targets.contains(target) else { throw PBError.message("Map the \(target) UEFI entry on the running OS first.") }
                        status = try await API.request(e, command: "boot", target: target, delay: 10)
                        endpoint = e; notice = "PC woke up. Restart into \(target.capitalized) scheduled in 10 seconds."; return
                    }
                    try await Task.sleep(for: .seconds(3))
                }
                throw PBError.message("PC did not become reachable within 150 seconds. Check power, Ethernet, firmware wake settings, and companion startup.")
            } catch is CancellationError { notice = "Stopped waiting. Any wake packet already sent cannot be recalled." }
            catch { notice = error.localizedDescription }
        }
    }
    func stopWake() { wakeTask?.cancel() }
}
