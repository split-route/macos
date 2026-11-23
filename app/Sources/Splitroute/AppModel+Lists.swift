import CryptoKit
import Foundation

// Lists: each edit is one database transaction on the stored config, so nothing is lost to a stale copy; the service
// gets the result in its next snapshot. What the user types is made canonical by the service's parser first.

extension AppModel {
    /// Loads what the settings window needs; the release list names need the network.
    func loadSettings() async {
        reloadLocal()
        guard let c = config else { return }
        if let names = try? await Fetch.releaseNames(c.listsURL) {
            available = names
            catalog = names.map(Catalog.describe)
        }
    }

    func setEnabled(_ on: Bool) async {
        busy = true
        defer { busy = false }
        do { try store?.update { var c = $0; c.disabled = !on; return c } } catch { actionError = error.localizedDescription }
        await changed()
    }

    // MARK: Per-list edits

    /// `tunnel` names the tunnel for the tunnel action; nil means the default tunnel.
    func setAction(_ name: String, _ a: Action, tunnel: String? = nil) async {
        await edit("list:\(name)") { try self.update { try $0.settingAction(name, a, tunnel: tunnel) } }
    }

    func removeList(_ name: String) async {
        await edit("list:\(name)") { try self.update { try $0.removing(name) } }
    }

    func moveList(_ name: String, to position: Int) async {
        await edit("list:\(name)") { try self.update { try $0.moving(name, to: position) } }
    }

    func enableRelease(_ name: String, _ a: Action = .direct) async {
        await edit("lists") {
            try self.update { try $0.enablingRelease(name, a) }
            Task { await self.refreshDownloads(force: true) } // the list's file is needed now
        }
    }

    func refreshImport(_ name: String) async {
        await edit("list:\(name)") {
            try self.store?.forceImport(name)
            Task { await self.refreshDownloads() }
        }
    }

    /// The release list's title and description; nil for custom lists, imports and release lists the release hasn't described.
    func info(_ name: String) -> ListInfo? { catalog.first { $0.name == name } }

    /// Creates a custom list from a file's text. Returns the entry counts, or the error.
    func createFromFile(name: String, action: Action, text: String) async -> (edit: EntryEdit?, error: String?) {
        var counts: EntryEdit?
        let e = await attempt {
            let r = try await Daemon.parseEntries(text, format: "custom", wantLines: true)
            var ed = EntryEdit()
            try self.update { c in
                let (c2, e2) = try c.creating(name, action).settingEntries(name, r.lines ?? [])
                ed = e2
                return c2
            }
            ed.skipped = (r.skipped ?? 0) > 0 ? r.skipped : nil
            counts = ed
        }
        return (counts, e)
    }

    /// Returns the error, or nil when the import was added. It is downloaded at once.
    func importList(name: String, url: String, action: Action) async -> String? {
        let e = await attempt {
            try self.update { try $0.importing(name, action, url: url) }
        }
        if e == nil { Task { await self.refreshDownloads() } }
        return e
    }

    /// Saves a custom list from the editor: creates it (original nil) or applies the rename, action and entries that
    /// changed. These are separate edits, so on an error the ones before it are kept; the returned name is the list's
    /// name afterwards (nil if it wasn't created).
    func saveCustom(original: String?, name: String, action: Action, entries: [String]) async -> (name: String?, error: String?) {
        var current = original
        let old = original.flatMap { o in config?.lists.first { $0.name == o } }
        if current == nil {
            if let e = await attempt({ try self.update { try $0.creating(name, action) } }) { return (nil, e) }
            current = name
        }
        if let c = current, c != name {
            if let e = await attempt({ try self.update { try $0.renaming(c, to: name) } }) { return (c, e) }
            current = name
        }
        if let old, old.action != action {
            if let e = await attempt({ try self.update { try $0.settingAction(name, action, tunnel: nil) } }) { return (current, e) }
        }
        if old?.entries ?? [] != entries {
            if let e = await attempt({
                let canon = try await self.canonical(entries)
                try self.update { try $0.settingEntries(name, canon).0 }
            }) { return (current, e) }
        }
        return (current, nil)
    }

    func applyPreset(_ id: String) async {
        await edit("preset") {
            guard let p = Presets.all.first(where: { $0.id == id }) else { throw StoreError("Unknown preset \"\(id)\".") }
            try self.update { try $0.applying(p) }
            Task { await self.refreshDownloads(force: true) }
        }
    }

    /// Sets the release URL (nil: the default).
    func setBaseURL(_ url: String?) async {
        await edit("baseURL") {
            try self.update { var c = $0; c.baseURL = url?.nilIfEmpty; return c }
            Task { await self.refreshDownloads(force: true) }
        }
    }

    // MARK: Helpers

    func update(_ f: (Config) throws -> Config) throws {
        guard let store else { throw StoreError("The settings database isn't open.") }
        try store.update(f)
    }

    /// The service's canonical form of each line; one that isn't an entry fails the whole edit.
    func canonical(_ lines: [String]) async throws -> [String] {
        let c = try await Daemon.canonEntries(lines)
        if let bad = c.first(where: { $0.error != nil }) { throw StoreError(bad.error ?? "Not an entry.") }
        return c.map { $0.entry ?? $0.line }
    }

    // MARK: Downloads: release lists and imports

    /// Downloads what is due: imports whose refresh time passed (or that were asked for), and the release lists once a
    /// day (or now, when `force`, or when one has no saved copy). A failed download keeps the last good copy.
    func refreshDownloads(force: Bool = false) async {
        guard !refreshing, let store, let link, let cfg = config else { return }
        refreshing = true
        defer { refreshing = false }
        var changedAny = false
        for st in (try? store.imports()) ?? [] where st.isDue() {
            if await download(st, store: store) { changedAny = true }
        }
        let names = cfg.lists.filter { !$0.custom && $0.importSource == nil }.map(\.name)
        let missing = names.contains { files.releaseText($0) == nil }
        if !names.isEmpty, force || missing || lastRelease.map({ Date().timeIntervalSince($0) >= Self.releaseEvery }) ?? true {
            let r = await Fetch.releaseLists(cfg.listsURL, names: names, files: files)
            releaseWarnings = r.warnings
            if r.warnings.isEmpty || !r.replaced.isEmpty {
                lastRelease = Date()
                UserDefaults.standard.set(lastRelease, forKey: "releaseFetchedAt")
            }
            if !r.replaced.isEmpty { changedAny = true }
        }
        if changedAny { link.markDirty() }
        reloadLocal()
        await pushSnapshot()
    }

    /// Downloads one import and stores it if it parsed to something useful. Returns whether the entries changed.
    private func download(_ st: ImportState, store: Store) async -> Bool {
        do {
            guard let url = URL(string: st.url) else { throw StoreError("The address isn't valid.") }
            let f = try await Fetch.importList(url, etag: st.etag, lastModified: st.lastModified)
            let hash = AppFiles.sha256(f.body)
            if f.notModified || (hash == st.sha256 && st.entries > 0) {
                try store.markChecked(name: st.name, url: st.url, etag: f.etag, lastModified: f.lastModified, error: "")
                return false
            }
            let text = String(decoding: f.body, as: UTF8.self)
            let r = try await Daemon.parseEntries(text, format: "import", wantLines: true)
            let ok = try store.saveDownload(name: st.name, url: st.url, lines: r.lines ?? [], etag: f.etag, lastModified: f.lastModified,
                                            sha256: hash, skipped: r.skipped ?? 0)
            return ok
        } catch {
            // A failure keeps the last good copy.
            try? store.markChecked(name: st.name, url: st.url, etag: "", lastModified: "", error: error.localizedDescription)
            return false
        }
    }
}
