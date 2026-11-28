import Design
import SwiftUI

/// Names a routing profile: a new (empty) one or a new name for an existing one.
struct ProfileSheet: View {
    enum Mode: Identifiable {
        case new, rename(String)
        var id: String { if case .rename(let n) = self { return "rename:\(n)" }; return "new" }
    }

    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var isNew: Bool { if case .new = mode { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(isNew ? "New profile" : "Rename profile").font(TypeScale.bodyStrong)
                TextField("Profile name", text: $name, prompt: Text("Work").foregroundColor(.secondary))
                    .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.leading).fieldBox().focused($focused).onSubmit(commit)
            }
            .padding(Space.xl)
            SheetButtons(error: error) {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Rename", action: commit).buttonStyle(SolidButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }
        .frame(width: 440)
        .onAppear {
            if case .rename(let old) = mode { name = old }
            focused = true
        }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            let failure: String?
            switch mode {
            case .new: failure = await model.createProfile(name)
            case .rename(let old): failure = await model.renameProfile(old, to: name)
            }
            if let failure { error = failure } else { dismiss() }
        }
    }
}

/// The profile dropdown of the Routing page: the profiles, each with rename and delete buttons, then New Profile.
struct ProfileMenu: View {
    enum Choice: Hashable { case profile(String), new }

    @EnvironmentObject private var model: AppModel
    @State private var sheet: ProfileSheet.Mode?
    @State private var deleting: String?

    private var options: [Choice] { model.profiles.map(Choice.profile) + [.new] }

    private func label(_ c: Choice) -> String {
        switch c {
        case .profile(let n): return n
        case .new: return "New Profile…"
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink.color).roundGlass(24)
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    var body: some View {
        SelectMenu(title: model.activeProfile, options: options, label: label, selected: .profile(model.activeProfile),
                   dot: { $0 == .profile(model.activeProfile) ? Accent.color : .clear },
                   group: { c in if case .profile = c { return "Profiles" } else { return "Manage" } }, maxTitleWidth: 160,
                   checkmark: false, titleDot: false, symbol: { $0 == .new ? "plus" : nil },
                   accessory: { c, close in
                       guard case .profile(let n) = c else { return nil }
                       return AnyView(HStack(spacing: 4) {
                           iconButton("pencil", "Rename “\(n)”") { close(); sheet = .rename(n) }
                           if model.profiles.count > 1 { iconButton("trash", "Delete “\(n)”") { close(); deleting = n } }
                       })
                   }) { c in
            switch c {
            case .profile(let n): Task { await model.switchProfile(n) }
            case .new: sheet = .new
            }
        }
        .sheet(item: $sheet) { mode in ProfileSheet(mode: mode).environmentObject(model).glassSheet() }
        .confirmationDialog("Delete the profile “\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { n in
            Button("Delete", role: .destructive) { Task { _ = await model.deleteProfile(n) } }
        } message: { n in
            Text("Its rules are deleted. Other profiles and the default route are not touched.")
        }
        .accessibilityLabel("Routing profile")
    }
}
