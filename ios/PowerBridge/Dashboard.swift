import SwiftUI
import UniformTypeIdentifiers

private let canvas = Color(red: 0.035, green: 0.055, blue: 0.08)
private let panel = Color(red: 0.075, green: 0.10, blue: 0.14)
private let accent = Color(red: 0.55, green: 0.95, blue: 0.74)

struct Dashboard: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairing = false
    @State private var confirmation: String?
    @State private var showConfirm = false
    @State private var showForget = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if store.computers.isEmpty { onboarding }
                    else {
                        computers
                        hero
                        bootPicker
                        actions
                        if let pending = store.status?.pending { countdown(pending) }
                        if !store.notice.isEmpty { message(store.notice, icon: "info.circle") }
                        activity
                        Button("Forget this computer", role: .destructive) { showForget = true }
                            .font(.footnote).frame(maxWidth: .infinity)
                    }
                    Text("POWERBRIDGE  /  YOUR PC, WITHIN REACH")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 18)
                }.padding(24)
            }
            .background(canvas).toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh() }
            .sheet(isPresented: $showPairing) { PairingView() }
            .confirmationDialog("Confirm power action", isPresented: $showConfirm, titleVisibility: .visible) {
                Button(confirmTitle, role: confirmation == "shutdown" ? .destructive : nil) {
                    if confirmation == "wake" { store.startWake() }
                    else if let action = confirmation { Task { await store.perform(action) } }
                }
            } message: {
                Text(confirmation == "wake" ? "Wake the PC. If an OS is selected, keep this app open; it may restart the PC after it wakes. Save any work first." : "Save your work. The PC will \(confirmation == "shutdown" ? "shut down" : "restart") after \(store.delay) seconds. \(store.chosenOS.isEmpty ? "Normal boot order will be used unless a one-time boot was already set." : "Next boot: \(store.chosenOS.capitalized).")")
            }
            .alert("Forget this computer?", isPresented: $showForget) {
                Button("Forget", role: .destructive) {
                    do { try store.forget() } catch { store.notice = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This removes pairing from this iPhone. Rotate the PC secret to revoke access from other copies.") }
            .task(id: "\(store.selectedID)-\(scenePhase == .active)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { store.stopWake() } }
        }
    }
    private var confirmTitle: String {
        switch confirmation { case "wake": return "Wake computer"; case "shutdown": return "Shut down"; default: return "Restart computer" }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("YOUR DESK. ANYWHERE.").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(accent)
                Text("PowerBridge").font(.system(size: 31, weight: .bold, design: .rounded))
            }
            Spacer()
            Button { showPairing = true } label: {
                Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).background(panel, in: Circle())
            }.accessibilityLabel("Pair a computer or relay")
        }
    }
    private var computers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(store.computers) { pc in
                    Button { store.select(pc.id) } label: {
                        Label(pc.name, systemImage: "desktopcomputer")
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(store.selectedID == pc.id ? accent.opacity(0.15) : panel, in: Capsule())
                            .foregroundStyle(store.selectedID == pc.id ? accent : .white)
                    }.disabled(store.busy || store.waking)
                }
            }
        }
    }
    private var hero: some View {
        VStack(spacing: 18) {
            HStack {
                Label(store.status == nil ? "UNREACHABLE" : "ONLINE", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundStyle(store.status == nil ? Color.secondary : accent)
                Spacer()
                if store.status?.dry_run == true { Text("TEST MODE").font(.caption2.bold()).foregroundStyle(.orange) }
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
            }
            ZStack {
                Circle().stroke(accent.opacity(0.07), lineWidth: 24).frame(width: 150, height: 150)
                Circle().stroke(accent.opacity(0.25), lineWidth: 1).frame(width: 125, height: 125)
                Image(systemName: "desktopcomputer").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(accent)
            }.padding(.vertical, 9)
            VStack(spacing: 5) {
                Text(store.selected?.name ?? "My PC").font(.title2.bold())
                Text(store.status.map { "\($0.os.capitalized) · encrypted connection" } ?? "Ready when you are")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if store.status == nil { Text(store.connection).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }.padding(22).frame(maxWidth: .infinity).background(panel, in: RoundedRectangle(cornerRadius: 28))
    }
    private var bootPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("NEXT OPERATING SYSTEM").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5); Spacer(); Image(systemName: "arrow.triangle.branch") }.foregroundStyle(.secondary)
            HStack(spacing: 10) {
                osButton("Default", value: "", icon: "arrow.forward")
                osButton("Linux", value: "linux", icon: "terminal")
                osButton("Windows", value: "windows", icon: "square.split.2x2")
            }
            Text(store.chosenOS.isEmpty ? "Use the PC’s normal boot order. An existing BootNext setting still takes priority." : "One-time selection. Shutdown prepares the next wake; Restart switches now.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func osButton(_ title: String, value: String, icon: String) -> some View {
        let selected = store.chosenOS == value
        let unavailable = !value.isEmpty && store.status != nil && !(store.status?.boot_targets.contains(value) ?? false)
        return Button { store.chosenOS = value } label: {
            VStack(spacing: 9) { Image(systemName: icon).font(.title3); Text(title).font(.caption.weight(.semibold)) }
                .frame(maxWidth: .infinity).padding(.vertical, 17)
                .background(selected ? accent : panel, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(selected ? canvas : .white).opacity(unavailable ? 0.35 : 1)
        }.disabled(unavailable || store.busy || store.waking || store.status?.pending != nil)
    }
    private var actions: some View {
        VStack(spacing: 12) {
            Button { confirmation = "wake"; showConfirm = true } label: {
                HStack { Image(systemName: "power"); Text(store.waking ? "Waiting for your PC…" : "Wake computer").fontWeight(.bold); Spacer(); Image(systemName: "arrow.up.right") }
                    .padding(20).background(accent, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(canvas)
            }.disabled(store.busy || store.waking || store.status != nil)
            if store.waking { Button("Stop waiting") { store.stopWake() }.font(.subheadline) }
            HStack(spacing: 12) {
                actionButton("Restart", icon: "arrow.clockwise", action: "restart")
                actionButton("Shut down", icon: "power.circle", action: "shutdown")
            }
            HStack {
                Label("Safety countdown", systemImage: "timer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Countdown", selection: $store.delay) {
                    Text("10 sec").tag(10); Text("30 sec").tag(30); Text("1 min").tag(60); Text("5 min").tag(300); Text("30 min").tag(1800)
                }.pickerStyle(.menu).disabled(store.busy || store.waking)
            }
        }
    }
    private func actionButton(_ title: String, icon: String, action: String) -> some View {
        Button { confirmation = action; showConfirm = true } label: {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 19)
                .background(panel, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(action == "shutdown" ? Color(red: 1, green: 0.56, blue: 0.55) : .white)
        }.disabled(store.status == nil || store.status?.pending != nil || store.busy || store.waking)
    }
    private func countdown(_ p: Pending) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(p.action.capitalized) scheduled").font(.subheadline.bold())
                Text(Date(timeIntervalSince1970: TimeInterval(p.at)), style: .relative).font(.caption.monospacedDigit())
            }
            Spacer()
            Button("Cancel") { Task { await store.perform("cancel") } }.buttonStyle(.bordered).disabled(store.busy)
        }.padding(18).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }
    private func message(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16))
    }
    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("RECENT ACTIVITY").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
            if let events = store.status?.history, !events.isEmpty {
                ForEach(Array(events.prefix(5).enumerated()), id: \.offset) { _, event in
                    HStack(alignment: .top) {
                        Image(systemName: "clock").foregroundStyle(accent)
                        Text(event.message).font(.caption)
                        Spacer()
                        Text(Date(timeIntervalSince1970: TimeInterval(event.time)), style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else { Text("Your power actions will appear here.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 26) {
            Image(systemName: "desktopcomputer.and.arrow.down").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(accent).padding(.top, 26)
            Text("Leave your desk.\nStay in control.").font(.system(size: 37, weight: .bold, design: .rounded))
            Text("Wake your computer, switch between Linux and Windows, or shut down for the night.").font(.body).foregroundStyle(.secondary)
            message("1. Install the companion on your PC.\n2. Import its private pairing.json file.\n3. Add a relay for reliable wake-up.", icon: "link")
            Button { showPairing = true } label: { Text("Pair my computer").bold().frame(maxWidth: .infinity).padding(18).background(accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(canvas) }
            if !store.notice.isEmpty { message(store.notice, icon: "info.circle") }
        }
    }
}

struct PairingView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = ""
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Import the pairing.json generated by your PC companion. Pair Linux and Windows using the same machine ID to combine them into one computer.")
                    Button("Choose pairing file", systemImage: "doc.badge.plus") { importing = true }
                }
                Section("Or paste pairing JSON") {
                    TextEditor(text: $text).frame(minHeight: 180).font(.system(.caption, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                Section { Text("This file grants control of your PC. Import only files you created on a trusted computer. Credentials are saved in this iPhone’s Keychain.").font(.caption) }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red) } }
                Button("Save pairing") {
                    do { try store.importPairing(text); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(text.isEmpty)
            }.navigationTitle("Pair securely").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                    do {
                        let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 16384 else { throw PBError.message("Pairing file too large") }
                        text = try String(contentsOf: url, encoding: .utf8)
                    } catch { self.error = error.localizedDescription }
                }
        }.preferredColorScheme(.dark)
    }
}
