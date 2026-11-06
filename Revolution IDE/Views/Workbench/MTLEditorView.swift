import SwiftUI
import AppKit

/// A simple viewer for Wavefront `.mtl` material libraries.
/// Parses the materials and displays their names, diffuse colors, and resolves
/// diffuse texture paths to show a grid of images when available.
struct MTLEditorView: View {
    @ObservedObject var box: MTLDocumentBox
    
    private var materials: [(name: String, mtl: OBJImporter.MTLMaterial)] {
        let parsed = OBJImporter.parseMTL(box.text)
        return parsed.map { (name: $0.key, mtl: $0.value) }.sorted(by: { $0.name < $1.name })
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if materials.isEmpty {
                    Text("No materials were found in this .mtl file.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding()
                } else {
                    Text("Materials (\(materials.count))")
                        .font(.headline)
                        .padding(.horizontal)
                    
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(materials, id: \.name) { mat in
                            MaterialCard(name: mat.name, mtl: mat.mtl, baseURL: box.url?.deletingLastPathComponent())
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MaterialCard: View {
    let name: String
    let mtl: OBJImporter.MTLMaterial
    let baseURL: URL?
    
    @State private var textureImage: NSImage?
    @State private var didTryLoad = false
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(radius: 1, y: 1)
                
                if let img = textureImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else if let color = mtl.diffuseColor {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: NSColor(calibratedRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1.0)))
                        .padding(4)
                } else {
                    VStack {
                        Image(systemName: "photo.badge.xmark")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        if mtl.diffuseTexturePath != nil {
                            Text("Image not found")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 140)
            .onAppear {
                if !didTryLoad {
                    didTryLoad = true
                    textureImage = loadImage()
                }
            }
            
            Text(name)
                .font(.callout).bold()
                .lineLimit(1)
                .truncationMode(.middle)
            
            if let path = mtl.diffuseTexturePath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            } else if mtl.diffuseColor != nil {
                Text("Flat Colour")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Diffuse")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
    
    private func loadImage() -> NSImage? {
        guard let path = mtl.diffuseTexturePath else { return nil }
        
        // Try local file system URL if the workspace gives us one
        if let url = baseURL?.appendingPathComponent(path), let image = NSImage(contentsOf: url) {
            return image
        }
        
        return nil
    }
}

