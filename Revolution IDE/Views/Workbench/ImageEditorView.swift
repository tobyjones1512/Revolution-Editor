import SwiftUI

/// Viewer for a plain image file (PNG/JPEG/GIF/TIFF/BMP/...) opened directly, view-only, same
/// stance as `.obj`/`.tpl`/`.brstm` (this app doesn't re-encode arbitrary images).
struct ImageEditorView: View {
    @ObservedObject var box: ImageDocumentBox

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if let image = box.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: image.size.width, height: image.size.height)
                    .padding()
            } else {
                Text("Couldn't decode this image.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            if let image = box.image {
                Text("\(Int(image.size.width))\u{00D7}\(Int(image.size.height)). \(ByteCountFormatter.string(fromByteCount: Int64(box.rawData.count), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(6)
            }
        }
    }
}
