import SwiftUI

struct TPLEditorView: View {
    @ObservedObject var box: TPLDocumentBox

    var body: some View {
        HSplitView {
            List(Array(box.doc.images.enumerated()), id: \.offset,
                 selection: Binding(get: { box.selectedIndex }, set: { box.selectedIndex = $0 })) { i, img in
                HStack {
                    Image(systemName: img.rgba != nil ? "photo" : "exclamationmark.triangle")
                    Text(img.name ?? "Image \(i)")
                    Spacer()
                    Text("\(img.width)x\(img.height)").font(.caption).foregroundStyle(.secondary)
                }
                .tag(i)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 240)
            .help("A TPL is a raw texture bank, a list of standalone Wii/GCN-format images, without a model/BRRES wrapping them. This app can view and export these to PNG but doesn't re-encode/save changes back to TPL.")

            if let idx = box.selectedIndex, box.doc.images.indices.contains(idx) {
                detail(box.doc.images[idx])
            } else {
                Text("Select an image.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if box.selectedIndex == nil { box.selectedIndex = box.doc.images.indices.first }
        }
    }

    @ViewBuilder
    private func detail(_ img: TPLImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(img.width)\u{00D7}\(img.height), \(String(describing: img.format))")
                    .foregroundStyle(.secondary).font(.caption)
                if let rgba = img.rgba, let nsImage = ImageUtil.nsImage(fromRGBA: rgba, width: img.width, height: img.height) {
                    Image(nsImage: nsImage)
                        .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 512, maxHeight: 512)
                        .border(Color.gray.opacity(0.3))
                    Button("Export PNG...") { exportPNG(nsImage, name: img.name) }
                } else {
                    Text("Couldn't decode this image (unsupported format, or its palette is missing).")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func exportPNG(_ nsImage: NSImage, name: String?) {
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? "image"
        PanelPresenter.saveFile(configure: { $0.nameFieldStringValue = base + ".png" }) { url in
            guard let url, let tiff = nsImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
}
