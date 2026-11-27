import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var queue: TransferQueue

    @LocalState private var showConnection = false
    @LocalState private var showBrowser = false
    @LocalState private var dropTargeted = false
    @LocalState private var showImporter = false
    @LocalState private var status: ConnStatus = .unknown

    enum ConnStatus: Equatable { case unknown, checking, ok, failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if queue.items.isEmpty {
                dropZone.padding(20)
            } else {
                queueList
            }
            Divider()
            footer
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls: urls, to: settings.remoteFolder)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !queue.items.isEmpty {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { queue.add(urls: urls, to: settings.remoteFolder) }
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(settings: settings) { checkConnection() }
        }
        .sheet(isPresented: $showBrowser) {
            RemoteBrowser(config: settings.config, startPath: settings.remoteFolder) { chosen in
                settings.remoteFolder = chosen
            }
        }
        .onAppear {
            if settings.host.isEmpty { showConnection = true } else { checkConnection() }
        }
        .onChange(of: queue.lastNotice) { _, n in
            guard n != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { queue.lastNotice = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(settings.host.isEmpty ? "No TV set up" : settings.config.display).font(.headline)
                }
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Connection…") { showConnection = true }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Send to").font(.caption).foregroundStyle(.secondary)
                Text(settings.remoteFolder).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.head)
            }
            Button("Change…") { showBrowser = true }.disabled(!settings.config.isComplete)
            Button { FeedbackWindowController.shared.show() } label: { Image(systemName: "bubble.left.and.bubble.right") }
                .buttonStyle(.borderless).help("Send feedback to \(AppInfo.author)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch status {
        case .ok: return .green
        case .failed: return .red
        case .checking: return .yellow
        case .unknown: return .gray
        }
    }

    private var statusText: String {
        switch status {
        case .ok: return "Connected — File Manager+ is listening"
        case .checking: return "Checking…"
        case .failed(let m): return m
        case .unknown: return "Start \"Access from network\" on the TV"
        }
    }

    private func checkConnection() {
        guard settings.config.isComplete else { status = .unknown; return }
        status = .checking
        let cfg = settings.config
        Task {
            if let err = await FTPClient.test(config: cfg) { status = .failed(err) } else { status = .ok }
        }
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line.compact").font(.system(size: 44, weight: .light))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text("Drop movies, files or folders here").font(.title3.weight(.medium))
            Text("They'll be sent to \(settings.remoteFolder) on the TV.\nYou can also drop files on the TV Ferry icon in the Dock.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            Button("Choose Files…") { showImporter = true }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
    }

    // MARK: Queue

    private var queueList: some View {
        List {
            ForEach(queue.items) { item in
                TransferRow(item: item, queue: queue)
            }
        }
        .listStyle(.inset)
    }

    // MARK: Footer

    private var footer: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 12) {
                if let n = queue.lastNotice {
                    Text(n).font(.caption).foregroundStyle(.orange).lineLimit(1)
                } else if queue.pendingCount > 0 {
                    Text("\(queue.pendingCount) to send · \(Fmt.bytes(queue.remainingBytes)) left"
                         + (queue.currentSpeed > 0 ? " · \(Fmt.bytes(Int64(queue.currentSpeed)))/s · \(Fmt.eta(Double(queue.remainingBytes) / queue.currentSpeed))" : ""))
                        .font(.callout).monospacedDigit()
                } else if !queue.items.isEmpty {
                    Text(queue.failedCount > 0 ? "Finished with \(queue.failedCount) problem(s)" : "All done").font(.callout)
                } else {
                    Toggle("Skip files already on the TV", isOn: $settings.skipExisting).toggleStyle(.checkbox).font(.callout)
                }
                Spacer()
                if !queue.items.isEmpty {
                    Button("Add Files…") { showImporter = true }
                    if queue.needsChoiceCount > 1 {
                        Button("Convert All (\(queue.needsChoiceCount))") { queue.convertAll() }
                    }
                    if queue.failedCount > 0 { Button("Retry Failed") { queue.retryFailed() } }
                    Button("Clear Finished") { queue.clearFinished() }
                        .disabled(!queue.items.contains { $0.state.isFinished })
                    if queue.paused {
                        Button("Resume") { queue.resume() }.keyboardShortcut(.defaultAction)
                    } else if queue.isRunning {
                        Button("Pause") { queue.pause() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let queue: TransferQueue

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.localURL.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.remoteName).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.bytes(item.size)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if item.state == .uploading || item.state == .checking {
                    ProgressView(value: item.state == .checking ? nil : item.fraction)
                        .progressViewStyle(.linear)
                }
                if item.state == .converting {
                    ProgressView(value: item.convertProgress).progressViewStyle(.linear).tint(.orange)
                }
                if item.state == .needsChoice, let issue = item.issue {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(issue.summary, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The picture may freeze or go black while the sound keeps playing. Converting makes a TV-friendly copy (your original isn't changed).")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Convert & Send") { queue.choose(item, convert: true) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Button("Send As Is") { queue.choose(item, convert: false) }
                                .controlSize(.small)
                        }
                    }
                }
                HStack(spacing: 6) {
                    statusLabel
                    if item.wasRenamed {
                        Text("· renamed for Android from \"\(item.originalName)\"")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            actions
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) }
            Button("Copy TV Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.remotePath, forType: .string)
            }
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch item.state {
        case .queued:
            Text(item.convert ? "Waiting · will convert for the TV" : "Waiting").font(.caption).foregroundStyle(.secondary)
        case .needsChoice:
            Text("Your choice needed").font(.caption).foregroundStyle(.orange)
        case .converting:
            Text("Converting for the TV… \(Int(item.convertProgress * 100))%")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .checking: Text("Checking the TV…").font(.caption).foregroundStyle(.secondary)
        case .uploading:
            Text("\(Int(item.fraction * 100))% · \(Fmt.bytes(item.bytesSent)) of \(Fmt.bytes(item.size))"
                 + (item.speed > 0 ? " · \(Fmt.bytes(Int64(item.speed)))/s · \(Fmt.eta(Double(item.size - item.bytesSent) / item.speed))" : "")
                 + (item.resumedFrom > 0 ? " · resumed" : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .done:
            Label(item.convert ? "Sent · converted for the TV" : "Sent", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .skipped(let why): Label(why, systemImage: "equal.circle").font(.caption).foregroundStyle(.secondary)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                .lineLimit(2).help(why)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.state {
        case .queued, .checking, .uploading, .converting, .needsChoice:
            Button { queue.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel")
        case .failed, .cancelled:
            Button { queue.retry(item) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.borderless).help("Retry (resumes where it stopped)")
        default: EmptyView()
        }
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s left" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s left" }
        return "\(s / 3600)h \(s % 3600 / 60)m left"
    }
}
