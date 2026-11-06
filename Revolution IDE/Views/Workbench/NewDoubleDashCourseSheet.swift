import SwiftUI

/// File > New > Mario Kart: Double Dash!! > Course from Model: builds a slot's course archives
/// from a course model (and optional sky), the Double Dash counterpart of starting a Wii track
/// (see `MKDDTrackBuilder.newCourse`).
struct NewDoubleDashCourseRequest: Identifiable {
    let id = UUID()
    /// Where the archives go (nil: ask).
    let directory: URL?
}

struct NewDoubleDashCourseSheet: View {
    let request: NewDoubleDashCourseRequest
    @EnvironmentObject var workbench: WorkbenchState
    @Environment(\.dismiss) private var dismiss
    @State private var slot = MKDDSlots.slots.first { $0.archive == "Luigi2" }!
    @State private var courseModel: URL?
    @State private var skyModel: URL?
    @State private var scale = 1.0
    @State private var discURL = DoubleDashDisc.linkedISO
    @State private var destination: URL?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Double Dash Track").font(.headline)
            Text("Makes a slot's course archives from your model: the model (textures fitted to the GameCube's memory), collision from the same model with surfaces guessed from material names, a minimap, a start point and an intro camera. Then open the archive to draw the enemy route and checkpoints, and use Make Testable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Replaces", selection: $slot) {
                    ForEach(MKDDSlots.slots) { Text($0.title + ($0.battle ? " (battle)" : "")).tag($0) }
                }
                fileRow("Course model", $courseModel, required: true)
                fileRow("Sky model", $skyModel, required: false)
                LabeledContent("Scale") {
                    TextField("", value: $scale, format: .number.precision(.fractionLength(0...3))).frame(width: 60)
                }
                LabeledContent("Double Dash disc") {
                    HStack {
                        Text(discURL?.lastPathComponent ?? "Not linked, minimap drawn to fit").foregroundStyle(discURL == nil ? .secondary : .primary).lineLimit(1)
                        Button("Choose...") {
                            PanelPresenter.openFile(configure: { $0.allowsOtherFileTypes = true }) { url in
                                guard let url else { return }
                                DoubleDashDisc.link(url); discURL = url
                            }
                        }
                    }
                }
                .help("Each slot's minimap area is fixed in the game. With your disc linked, the minimap uses the slot's real area, so markers line up.")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Saved as \(slot.archives.map(\.name).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Building..." : "Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || courseModel == nil || !(0.01...100).contains(scale))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func fileRow(_ label: String, _ url: Binding<URL?>, required: Bool) -> some View {
        LabeledContent(label) {
            HStack {
                Text(url.wrappedValue?.lastPathComponent ?? (required ? "Choose an .obj or .dae" : "None (no sky)"))
                    .foregroundStyle(url.wrappedValue == nil ? .secondary : .primary).lineLimit(1)
                if !required, url.wrappedValue != nil { Button("Clear") { url.wrappedValue = nil } }
                Button("Choose...") {
                    PanelPresenter.openFile(configure: { $0.allowedContentTypes = ModelFile.contentTypes }) { picked in
                        if let picked { url.wrappedValue = picked }
                    }
                }
            }
        }
    }

    private func create() {
        guard let courseModel else { return }
        if let directory = request.directory ?? destination {
            build(courseModel, into: directory)
        } else {
            PanelPresenter.openFile(configure: { $0.canChooseDirectories = true; $0.canChooseFiles = false; $0.prompt = "Save Here" }) { dir in
                guard let dir else { return }
                destination = dir
                build(courseModel, into: dir)
            }
        }
    }

    private func build(_ courseModel: URL, into directory: URL) {
        working = true
        error = nil
        let (slot, sky, scale) = (slot, skyModel, Float(scale))
        Task.detached(priority: .userInitiated) {
            let (minimap, why) = DoubleDashDisc.minimap(for: slot)
            do {
                var out = try MKDDTrackBuilder.newCourse(slot: slot, courseModel: courseModel, skyModel: sky, scale: scale, minimap: minimap, musicID: slot.musicID)
                if let why { out.report.append("(\(why).)") }
                for (name, archive) in out.archives { try archive.write(to: directory.appendingPathComponent(name), options: .atomic) }
                await MainActor.run { [out] in
                    workbench.log("New Double Dash course for \(slot.title):")
                    out.report.forEach { workbench.log("  " + $0) }
                    workbench.refreshFolderTree()
                    working = false
                    dismiss()
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; working = false }
            }
        }
    }
}
