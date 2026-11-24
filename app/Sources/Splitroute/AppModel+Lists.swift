import CryptoKit
import Foundation

// Lists: each edit is one database transaction on the stored config, so nothing is lost to a stale copy; the service
// gets the result in its next snapshot. What the user types is made canonical by the service's parser first.

extension AppModel {
    /// Loads what the settings window needs; the release list names need the network.
    func loadSettings() async {
        refreshLaunchAtLogin()
        reloadLocal()
        guard let c = config else { return }
        if let names = try? await Fetch.releaseNames(c.listsURL) {
            available = names
            catalog = names.map(Catalog.describe)
        }
    }

    /// Whether the lists are applied. Off, only the default route is left.
    var routingOn: Bool { !(config?.disabled ?? false) }

    func setRoutingOn(_ on: Bool) async {
        await edit("routing") { try self.update { var c = $0; c.disabled = !on; return c } }
    }

    // MARK: Per-list edits

    /// `tunnel` names the tunnel for the tunnel action; nil means the default tunnel.
    func setAction(_ name: String, _ a: Action, tunnel: String? = nil) async {
        await edit("list:\(name)") { try self.update { try $0.settingAction(name, a, tunnel: tunnel) } }
    }

    func setBlockQUIC(_ on: Bool) async {
        await edit("blockQUIC") { try self.update { var c = $0; c.blockQUIC = on; return c } }
    }

    /// Where traffic that matches no list goes; `tunnel` names a tunnel for the tunnel action (nil: the selected one).
    func setFinal(_ a: Action, tunnel: String? = nil) async {
        await edit("final") { try self.update { try $0.settingFinal(a, tunnel: tunnel) } }
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

    /// Changes an import's address and description. A new address is downloaded at once.
    func updateImport(name: String, newName: String, url: String, description: String) async -> String? {
        let old = config?.lists.first { $0.name == name }?.importSource?.url
        let e = await attempt {
            if newName != name {
                guard let cfg = self.config, let store = self.store else { throw StoreError("The settings database isn't open.") }
                _ = try cfg.renaming(name, to: newName) // the same checks as any rename
                try store.renameList(name, to: newName)
            }
            try self.update { c in
                var c2 = c
                if url != old { c2 = try c2.settingImportURL(newName, to: url) }
                return try c2.settingDescription(newName, description)
            }
        }
        if e == nil, url != old { Task { await self.refreshDownloads() } }
        return e
    }

    /// Downloads one ready-made list again, now.
    func refreshRelease(_ name: String) async {
        await edit("list:\(name)") { await self.refreshDownloads(force: true, only: name) }
    }

    func refreshImport(_ name: String) async {
        await edit("list:\(name)") {
            try self.store?.forceImport(name)
            Task { await self.refreshDownloads() }
        }
    }

    /// A service older than this app ignores a rule-set's bytes and would answer "no entries": say what to do instead.
    func requireRuleSetSupport() throws {
        if (service?.apiRev ?? 0) < Daemon.requiredAPIRev {
            throw StoreError("The service is older than this app and can't read rule-sets (.srs) yet. Restart it in Settings (Restart service), then try again.")
        }
    }

    /// The release list's title and description; nil for custom lists, imports and release lists the release hasn't described.
    func info(_ name: String) -> ListInfo? { catalog.first { $0.name == name } }

    /// Creates a custom list from a file's text. Returns the entry counts, or the error.
    func createFromFile(name: String, action: Action, text: String, binary: Data? = nil, description: String? = nil) async -> (edit: EntryEdit?, error: String?) {
        var counts: EntryEdit?
        let e = await attempt {
            let r: WireEntries
            if let binary { try self.requireRuleSetSupport(); r = try await Daemon.parseEntries(data: binary, format: "custom", wantLines: true) }
            else { r = try await Daemon.parseEntries(text, format: "custom", wantLines: true) }
            var ed = EntryEdit()
            try self.update { c in
                let (c2, e2) = try c.creating(name, action, description: description).settingEntries(name, r.lines ?? [])
                ed = e2
                return c2
            }
            ed.skipped = (r.skipped ?? 0) > 0 ? r.skipped : nil
            counts = ed
        }
        return (counts, e)
    }

    /// Returns the error, or nil when the import was added. It is downloaded at once.
    func importList(name: String, url: String, action: Action, description: String? = nil) async -> String? {
        let e = await attempt {
            try self.update { try $0.importing(name, action, url: url, description: description) }
        }
        if e == nil { Task { await self.refreshDownloads() } }
        return e
    }

    /// Saves a custom list from the editor: creates it (original nil) or applies the rename, action and entries that
    /// changed. These are separate edits, so on an error the ones before it are kept; the returned name is the list's
    /// name afterwards (nil if it wasn't created).
    func saveCustom(original: String?, name: String, action: Action, entries: [String], description: String? = nil) async -> (name: String?, error: String?) {
        var current = original
        let old = original.flatMap { o in config?.lists.first { $0.name == o } }
        if current == nil {
            if let e = await attempt({ try self.update { try $0.creating(name, action, description: description) } }) { return (nil, e) }
            current = name
        }
        if let c = current, c != name {
            if let e = await attempt({ try self.update { try $0.renaming(c, to: name) } }) { return (c, e) }
            current = name
        }
        if let old, old.description != description?.nilIfEmpty {
            if let e = await attempt({ try self.update { try $0.settingDescription(name, description) } }) { return (current, e) }
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
    func refreshDownloads(force: Bool = false, only: String? = nil) async {
        guard !refreshing, let store, let link, let cfg = config else { return }
        refreshing = true
        defer { refreshing = false }
        var changedAny = false
        let due = only == nil ? ((try? store.imports()) ?? []).filter { $0.isDue() } : []
        let names = cfg.lists.filter { !$0.custom && $0.importSource == nil && $0.action != .none && (only == nil || $0.name == only) }.map(\.name)
        let missing = names.contains { files.releaseText($0) == nil }
        let fetchRelease = !names.isEmpty && (force || missing || lastRelease.map { Date().timeIntervalSince($0) >= Self.releaseEvery } ?? true)
        // Every list about to download shows as started at once, before the first byte.
        for st in due { downloads[st.name] = .running(nil) }
        // A daily refresh of a saved list stays quiet; one the user asked for shows its progress.
        if fetchRelease { for n in names where only != nil || files.releaseText(n) == nil { downloads[n] = .running(nil) } }
        for st in due {
            if await download(st, store: store) { changedAny = true }
        }
        if fetchRelease {
            let r = await Fetch.releaseLists(cfg.listsURL, names: names, files: files) { [weak self] name, state in
                Task { @MainActor in self?.setDownload(name, state) }
            }
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

    /// A late progress report never overrides a finished or failed state: only a running list takes one.
    func setDownload(_ name: String, _ state: Fetch.DownloadState?) {
        switch state {
        case .running: if case .running = downloads[name] { downloads[name] = state }
        case .failed, nil: downloads[name] = state
        }
    }

    /// Downloads one import and stores it if it parsed to something useful. Returns whether the entries changed.
    private func download(_ st: ImportState, store: Store) async -> Bool {
        do {
            guard let url = URL(string: st.url) else { throw StoreError("The address isn't valid.") }
            let f = try await Fetch.importList(url, etag: st.etag, lastModified: st.lastModified) { [weak self] p in
                Task { @MainActor in self?.setDownload(st.name, .running(p)) }
            }
            let hash = AppFiles.sha256(f.body)
            if f.notModified || (hash == st.sha256 && st.entries > 0) {
                try store.markChecked(name: st.name, url: st.url, etag: f.etag, lastModified: f.lastModified, error: "")
                setDownload(st.name, nil)
                return false
            }
            if Daemon.isRuleSet(f.body) { try requireRuleSetSupport() }
            let r = Daemon.isRuleSet(f.body)
                ? try await Daemon.parseEntries(data: f.body, format: "import", wantLines: true)
                : try await Daemon.parseEntries(String(decoding: f.body, as: UTF8.self), format: "import", wantLines: true)
            let ok = try store.saveDownload(name: st.name, url: st.url, lines: r.lines ?? [], etag: f.etag, lastModified: f.lastModified,
                                            sha256: hash, skipped: r.skipped ?? 0)
            setDownload(st.name, nil)
            return ok
        } catch {
            // A failure keeps the last good copy.
            try? store.markChecked(name: st.name, url: st.url, etag: "", lastModified: "", error: error.localizedDescription)
            setDownload(st.name, .failed(error.localizedDescription))
            return false
        }
    }
}
