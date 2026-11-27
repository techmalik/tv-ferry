import SwiftUI

/// Browse the TV's storage and pick the folder files should go into.
struct RemoteBrowser: View {
    let config: Remote
    let startPath: String
    var onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @LocalState private var path = "/"
    @LocalState private var entries: [RemoteEntry] = []
    @LocalState private var loading = false
    @LocalState private var error: String?
    @LocalState private var selection: RemoteEntry.ID?
    @LocalState private var newFolderName = ""
    @LocalState private var showNewFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { go(parent) } label: { Image(systemName: "chevron.up") }
                    .disabled(path == "/").help("Up one folder")
                Text(path).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                Button { newFolderName = ""; showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                    .help("New folder")
            }

            ZStack {
                List(selection: $selection) {
                    ForEach(entries) { e in
                        HStack {
                            Image(systemName: e.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(e.isDirectory ? Color.accentColor : .secondary)
                            Text(e.name).foregroundStyle(e.isDirectory ? .primary : .secondary)
                            Spacer()
                            if let s = e.size, !e.isDirectory {
                                Text(Fmt.bytes(s)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if e.isDirectory { go(join(path, e.name)) } }
                        .tag(e.id)
                    }
                }
                if loading { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.center).padding()
                } else if !loading && entries.isEmpty {
                    Text("Empty folder").foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 300)

            Text("Double-click a folder to open it.").font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send Files Here") { onChoose(path); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .onAppear { go(startPath) }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var parent: String {
        let comps = path.split(separator: "/").dropLast()
        return "/" + comps.joined(separator: "/")
    }

    private func join(_ a: String, _ b: String) -> String { a == "/" ? "/" + b : a + "/" + b }

    private func go(_ p: String) {
        path = "/" + p.split(separator: "/").joined(separator: "/")
        load()
    }

    private func load() {
        loading = true; error = nil; entries = []
        let target = path
        Task {
            do {
                let list = try await RemoteFS.list(target, on: config)
                guard target == path else { return }
                entries = list
            } catch {
                guard target == path else { return }
                // The saved folder may not exist yet: fall back to the top level.
                if target != "/" { go("/"); return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func createFolder() {
        let name = NameSanitizer.sanitize(newFolderName)
        guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let target = join(path, name)
        Task {
            do {
                try await RemoteFS.makeDirectory(target, on: config)
                go(target)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
