import SwiftUI
import UniformTypeIdentifiers

/// The main window: the TV and Send-to folders in a sidebar, the queue on the right.
struct ContentView: View {
    @ObservedObject var settings: ConnectionSettings
    @ObservedObject var queue: TransferQueue
    @ObservedObject var monitor: ConnectionMonitor

    @LocalState private var showConnection = false
    @LocalState private var showBrowser = false
    @LocalState private var dropTargeted = false
    @LocalState private var showImporter = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Divider()
            mainPane.background(Palette.content)
        }
        .tint(Palette.accent)
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls: urls, to: settings.remoteFolder)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !queue.items.isEmpty {
                RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: 3).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { r in
            if case let .success(urls) = r { queue.add(urls: urls, to: settings.remoteFolder) }
        }
        .sheet(isPresented: $showConnection) {
            ConnectionSheet(settings: settings) { monitor.check() }
        }
        .sheet(isPresented: $showBrowser) {
            RemoteBrowser(config: settings.remote, startPath: settings.remoteFolder) { chosen in
                settings.choose(folder: chosen)
            }
        }
        .onAppear {
            if settings.host.isEmpty { showConnection = true } else { monitor.check() }
        }
        .onChange(of: queue.lastNotice) { _, n in
            guard let n else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if queue.lastNotice == n { queue.lastNotice = nil } }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("TV")
            Button { showConnection = true } label: {
                HStack(spacing: 10) {
                    TVTile(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            StatusDot(color: monitor.color)
                            Text(monitor.text).font(.caption)
                                .foregroundStyle(monitor.status == .ok ? Palette.success : Palette.textSecondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9).fill(Palette.sidebarCard))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Connection settings for \(settings.remote.display) (\(settings.kind.label))")

            sectionLabel("SEND TO").padding(.top, 14)
            ForEach(settings.recentFolders, id: \.self) { folder in
                folderRow(folder)
            }
            Button { showBrowser = true } label: {
                Label("Browse the TV…", systemImage: "plus").font(.system(size: 13))
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
            .disabled(!settings.remote.isComplete)

            Spacer()

            Toggle("Skip files already on the TV", isOn: $settings.skipExisting)
                .toggleStyle(.checkbox).font(.caption).padding(.horizontal, 8).padding(.bottom, 6)
            HStack {
                Button("Connection…") { showConnection = true }.controlSize(.small)
                Spacer()
                Button { FeedbackWindowController.shared.show() } label: { Image(systemName: "bubble.left.and.bubble.right") }
                    .buttonStyle(.borderless).help("Send feedback to \(AppInfo.author)")
                    .accessibilityLabel("Send feedback")
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 10).padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 4)
    }

    private func folderRow(_ folder: String) -> some View {
        let selected = folder == settings.remoteFolder
        return Button { settings.choose(folder: folder) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .foregroundStyle(selected ? Color.white : Palette.accent)
                Text(ConnectionSettings.folderTitle(folder)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color.white : Palette.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder)
        .contextMenu {
            if !selected {
                Button("Remove from Sidebar") { settings.recentFolders.removeAll { $0 == folder } }
            }
        }
    }

    // MARK: Main pane

    private var mainPane: some View {
        VStack(spacing: 0) {
            header
            if queue.items.isEmpty {
                dropZone.padding(.horizontal, 20).padding(.bottom, 20)
            } else {
                queueTable
            }
            if let n = queue.lastNotice {
                HStack {
                    Image(systemName: "info.circle")
                    Text(n).lineLimit(2)
                    Spacer()
                }
                .font(.callout).foregroundStyle(Palette.warning)
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Palette.warningRow)
            }
        }
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ConnectionSettings.folderTitle(settings.remoteFolder))
                        .font(.system(size: 20, weight: .bold)).lineLimit(1)
                    Text(QueueSummary.text(queue, settings: settings))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if queue.needsChoiceCount > 1 {
                    Button("Convert All (\(queue.needsChoiceCount))") { queue.convertAll() }
                }
                if queue.failedCount > 0 { Button("Retry Failed") { queue.retryFailed() } }
                if queue.items.contains(where: { $0.state.isFinished }) {
                    Button("Clear Finished") { queue.clearFinished() }
                }
                if queue.paused {
                    Button("Resume") { queue.resume() }
                } else if queue.isRunning {
                    Button("Pause") { queue.pause() }
                }
                Button("Add Files…") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.to.line.compact").font(.system(size: 40, weight: .light))
                .foregroundStyle(dropTargeted ? Palette.accent : .secondary)
            Text("Drop movies, files or folders here").font(.title3.weight(.medium))
            Text("They'll go to \(settings.remoteFolder) on \(settings.displayName).\nYou can also drop files on the TV Ferry icon in the Dock.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.callout)
            Button("Choose Files…") { showImporter = true }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .foregroundStyle(dropTargeted ? Palette.accent : Palette.border)
        )
    }

    private var queueTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("NAME").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 36)
                Text("SIZE").frame(width: 64, alignment: .leading)
                Text("STATUS").frame(width: 186, alignment: .leading)
                Color.clear.frame(width: 20, height: 1)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 32).padding(.bottom, 6)
            Divider().padding(.horizontal, 20)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        TransferRow(item: item, queue: queue)
                        Divider().padding(.leading, 56)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
    }
}

/// One file in the queue table.
struct TransferRow: View {
    @ObservedObject var item: TransferItem
    let queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            columns
            if item.state == .needsChoice, let issue = item.issue {
                Text(issue.summary + ". The picture may freeze or go black while the sound plays; converting makes a TV-friendly copy and leaves your original alone.")
                    .font(.caption).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(item.state == .needsChoice ? Palette.warningRow : Color.clear))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) }
            Button("Copy TV Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.remotePath, forType: .string)
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.localURL.path))
                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.remoteName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if item.wasRenamed {
                    Text("Renamed for Android from \"\(item.originalName)\"").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.bytes(item.size)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 64, alignment: .leading)
            status.frame(width: 186, alignment: .leading)
            actions.frame(width: 20)
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued:
            Text(item.convert ? "Waiting · will convert" : "Waiting").font(.caption).foregroundStyle(.secondary)
        case .needsChoice:
            HStack(spacing: 6) {
                Button("Convert") { queue.choose(item, convert: true) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .help("Convert & Send: make a TV-friendly copy and send that")
                Button("Send As Is") { queue.choose(item, convert: false) }.controlSize(.small)
                    .help("Send the original without converting it")
            }
        case .converting:
            VStack(alignment: .leading, spacing: 4) {
                ThinBar(value: item.convertProgress, tint: Palette.warning)
                Text("Converting for the TV… \(Int(item.convertProgress * 100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking the TV…").font(.caption).foregroundStyle(.secondary) }
        case .uploading:
            VStack(alignment: .leading, spacing: 4) {
                ThinBar(value: item.fraction)
                Text("\(Int(item.fraction * 100))%"
                     + (item.speed > 0 ? " · \(Fmt.bytes(Int64(item.speed)))/s · \(Fmt.eta(Double(item.size - item.bytesSent) / item.speed))" : "")
                     + (item.resumedFrom > 0 ? " · resumed" : ""))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        case .done:
            if item.verified {
                Label(item.convert ? "Sent · converted" : "Sent", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Palette.success)
            } else {
                Label("Sent · not checked", systemImage: "questionmark.circle.fill")
                    .font(.caption).foregroundStyle(Palette.warning)
                    .help("The upload finished without errors, but the TV wouldn't say how big the file is, so TV Ferry couldn't confirm every byte arrived.")
            }
        case .skipped(let why): Label(why, systemImage: "equal.circle").font(.caption).foregroundStyle(.secondary)
        case .cancelled: Label("Cancelled", systemImage: "xmark.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Palette.danger)
                .lineLimit(2).help(why)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.state {
        case .queued, .checking, .uploading, .converting, .needsChoice:
            Button { queue.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel").accessibilityLabel("Cancel")
        case .failed, .cancelled:
            Button { queue.retry(item) } label: { Image(systemName: "arrow.clockwise.circle.fill") }
                .buttonStyle(.borderless).help("Retry (resumes where it stopped)").accessibilityLabel("Retry")
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
