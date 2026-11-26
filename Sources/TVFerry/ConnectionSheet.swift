import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var settings: ConnectionSettings
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @LocalState private var host = ""
    @LocalState private var port = ""
    @LocalState private var user = ""
    @LocalState private var password = ""
    @LocalState private var testing = false
    @LocalState private var testResult: String?
    @LocalState private var testOK = false
    @LocalState private var scanning = false
    @LocalState private var found: [String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to your TV").font(.title2.weight(.semibold))
            Text("On the TV, open **File Manager+ → Access from network** and press **Start service**. Enter the address, port and password it shows.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form {
                HStack {
                    TextField("TV IP address", text: $host, prompt: Text("192.168.1.191"))
                    Button(scanning ? "Searching…" : "Find TV") { scan() }.disabled(scanning || Int(port) == nil)
                }
                if let found {
                    if found.isEmpty {
                        Text("No File Manager+ server found on port \(port). Is the service started on the TV?")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        HStack {
                            Text("Found:").font(.caption)
                            ForEach(found, id: \.self) { ip in Button(ip) { host = ip }.controlSize(.small) }
                        }
                    }
                }
                TextField("Port", text: $port, prompt: Text("8782"))
                TextField("Username", text: $user, prompt: Text("leave blank if the TV shows none"))
                SecureField("Password", text: $password)
            }

            if let r = testResult {
                Label(r, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testOK ? .green : .red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Tip: untick \"Random password\" on the TV so the password stays the same, and give the TV a fixed IP in your router so you only set this up once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing || draft == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            host = settings.host
            port = String(settings.port)
            user = settings.user
            password = settings.password
        }
    }

    private var draft: FTPConfig? {
        guard let p = Int(port.trimmingCharacters(in: .whitespaces)) else { return nil }
        let c = FTPConfig(host: host, port: p, user: user, password: password)
        return c.isComplete ? c : nil
    }

    private func test() {
        guard let c = draft else { return }
        testing = true; testResult = nil
        Task {
            let err = await FTPClient.test(config: c)
            testing = false
            testOK = err == nil
            testResult = err ?? "Connected to the TV."
        }
    }

    private func scan() {
        guard let p = Int(port) else { return }
        scanning = true; found = nil
        Task {
            let ips = await NetworkScanner.scan(port: p)
            scanning = false
            found = ips
            if ips.count == 1 { host = ips[0] }
        }
    }

    private func save() {
        guard let c = draft else { return }
        settings.host = c.trimmedHost
        settings.port = c.port
        settings.user = c.user
        settings.password = c.password
        dismiss()
        onDone()
    }
}
