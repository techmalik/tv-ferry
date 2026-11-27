import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var settings: ConnectionSettings
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @LocalState private var kind: TransportKind = .ftp
    @LocalState private var host = ""
    @LocalState private var name = ""
    @LocalState private var ftpPort = ""
    @LocalState private var adbPort = ""
    @LocalState private var user = ""
    @LocalState private var password = ""
    @LocalState private var testing = false
    @LocalState private var testResult: String?
    @LocalState private var testOK = false
    @LocalState private var scanning = false
    @LocalState private var found: [String]?
    @LocalState private var adbPath: String?
    @LocalState private var installingADB = false
    @LocalState private var installError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to your TV").font(.title2.weight(.semibold))

            Picker("Connect with", selection: $kind) {
                ForEach(TransportKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: kind) { _, _ in testResult = nil; found = nil }

            if kind == .ftp {
                Text("On the TV, open **File Manager+ → Access from network** and press **Start service**. Enter the address, port and password it shows.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                adbIntro
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Living Room TV (optional)"))
                HStack {
                    TextField("TV IP address", text: $host, prompt: Text("192.168.1.191"))
                    Button(scanning ? "Searching…" : "Find TV") { scan() }.disabled(scanning || Int(portText) == nil)
                }
                if let found {
                    if found.isEmpty {
                        Text(kind == .ftp ? "No File Manager+ server found on port \(portText). Is the service started on the TV?"
                                          : "Nothing answered on port \(portText). Is Network debugging on, and is the TV switched on?")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        HStack {
                            Text("Found:").font(.caption)
                            ForEach(found, id: \.self) { ip in Button(ip) { host = ip }.controlSize(.small) }
                        }
                    }
                }
                if kind == .ftp {
                    TextField("Port", text: $ftpPort, prompt: Text("8782"))
                    TextField("Username", text: $user, prompt: Text("leave blank if the TV shows none"))
                    SecureField("Password", text: $password)
                } else {
                    TextField("Port", text: $adbPort, prompt: Text("5555"))
                }
            }

            if let r = testResult {
                Label(r, systemImage: testOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(testOK ? .green : .red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(kind == .ftp
                 ? "Tip: untick \"Random password\" on the TV so the password stays the same, and give the TV a fixed IP in your router so you only set this up once."
                 : "Tip: give the TV a fixed IP in your router so you only set this up once. Network debugging lets this Mac (and anything else you allow on the TV) manage the TV, so only use it on your home Wi-Fi.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing || draft == nil || !toolReady)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(draft == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            kind = settings.kind
            host = settings.host
            name = settings.tvName
            ftpPort = String(settings.port)
            adbPort = String(settings.adbPort)
            user = settings.user
            password = settings.password
            adbPath = ADBClient.locate()?.path
        }
    }

    @ViewBuilder private var adbIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sends files whenever the TV is on: nothing has to be open on the TV. Set it up once:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("1. On the TV: **Settings → System → About**, then select **Build** seven times to turn on Developer options. (On some TVs it's under Device Preferences → About.)\n2. **Developer options →** turn on **Network debugging** (sometimes called **ADB debugging**).\n3. Enter the TV's IP below and press **Test Connection**. When the TV asks, tick **Always allow from this computer** and choose **Allow**.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let adbPath {
                    Label("adb is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        .help(adbPath)
                } else if installingADB {
                    ProgressView().controlSize(.small)
                    Text("Downloading adb from Google…").font(.caption)
                } else {
                    Button("Download adb") { installADB() }
                    Text("Google's free adb tool, needed once.").font(.caption).foregroundStyle(.secondary)
                    Link("Terms", destination: ADBClient.termsURL).font(.caption)
                }
            }
            if let installError {
                Text(installError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var portText: String { (kind == .ftp ? ftpPort : adbPort).trimmingCharacters(in: .whitespaces) }
    private var toolReady: Bool { kind == .ftp || adbPath != nil }

    private var draft: Remote? {
        guard let p = Int(portText) else { return nil }
        let ftpP = kind == .ftp ? p : (Int(ftpPort) ?? settings.port)
        let adbP = kind == .adb ? p : (Int(adbPort) ?? settings.adbPort)
        let r = Remote(kind: kind, ftp: FTPConfig(host: host, port: ftpP, user: user, password: password), adbPort: adbP)
        return r.isComplete ? r : nil
    }

    private func test() {
        guard let r = draft else { return }
        testing = true; testResult = nil
        Task {
            let err = await RemoteFS.test(r)
            testing = false
            testOK = err == nil
            testResult = err ?? "Connected to the TV."
        }
    }

    private func scan() {
        guard let p = Int(portText) else { return }
        scanning = true; found = nil
        let wantBanner = kind == .ftp
        Task {
            let ips = await NetworkScanner.scan(port: p, expectFTPGreeting: wantBanner)
            scanning = false
            found = ips
            if ips.count == 1 { host = ips[0] }
        }
    }

    private func installADB() {
        installingADB = true; installError = nil
        Task {
            do {
                try await ADBClient.install()
                adbPath = ADBClient.locate()?.path
            } catch {
                installError = "Couldn't download adb: \(error.localizedDescription)"
            }
            installingADB = false
        }
    }

    private func save() {
        guard let r = draft else { return }
        settings.tvName = name.trimmingCharacters(in: .whitespaces)
        settings.kind = r.kind
        settings.host = r.host
        settings.port = r.ftp.port
        settings.adbPort = r.adbPort
        settings.user = r.ftp.user
        settings.password = r.ftp.password
        dismiss()
        onDone()
    }
}
