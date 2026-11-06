import SwiftUI

/// Real-geometry viewer for a Wavefront `.obj` (or converted `.dae`), same SceneKit preview the
/// BRRES model viewer uses, textured from the companion .mtl when there is one.
struct OBJEditorView: View {
    @ObservedObject var box: OBJDocumentBox

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model = box.model {
                SceneKitMeshPreviewView(model: model, textureLookup: box.textureLookup, selectedMeshIndex: .constant(-1))
                    .frame(minHeight: 360)
                    .layoutPriority(1)
                    .border(Color.gray.opacity(0.3))
                Text("\(box.triangleCount) triangles, \(model.meshes.count) material\(model.meshes.count == 1 ? "" : "s"), \(box.textureLookup.count) textured from the .mtl (drag to orbit, scroll/pinch to zoom). View-only: this app doesn't write .obj files.")
                    .font(.caption).foregroundStyle(.secondary)
                if !box.missingTextures.isEmpty {
                    Label("Couldn't find: \(box.missingTextures.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("No triangles were found in this .obj file.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
