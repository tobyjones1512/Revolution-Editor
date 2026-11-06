import Foundation
import Combine

/// User-made Mario Kart Wii objects. The game can't load new object types, so each one borrows a
/// retail "host" object: placing it uses the host's ID and drops a `.brres` named after the host
/// (its MDL0 named the same) into the track, replacing the host's model there. The hosts are
/// plain decorations whose files hold only a model and textures, no animations or effects the
/// game would look up and miss. One custom object per host per track.
nonisolated struct CustomObject: Codable, Identifiable, Hashable {
    struct Host: Hashable {
        let resource: String
        let title: String
        /// The host's no-collision version, and its solid one (a fixed tree-trunk-sized cylinder).
        let decorativeID: UInt16, solidID: UInt16
    }

    static let hosts: [Host] = [
        Host(resource: "gardentreeDS", title: "Slot A (DS Peach Gardens tree)", decorativeID: 0x150, solidID: 0x151),
        Host(resource: "DKtreeA64", title: "Slot B (N64 DK's Jungle Parkway tree)", decorativeID: 0x157, solidID: 0x158),
        Host(resource: "TownTreeDS", title: "Slot C (DS Delfino Square tree)", decorativeID: 0x163, solidID: 0x15B),
    ]

    var id = UUID()
    var name: String
    var hostResource: String
    var solid: Bool

    var host: Host? { Self.hosts.first { $0.resource == hostResource } }
    var objectID: UInt16? { host.map { solid ? $0.solidID : $0.decorativeID } }
    /// What gets installed into the track.
    var trackFilePath: [String] { [hostResource + ".brres"] }
}

@MainActor final class CustomObjectStore: ObservableObject {
    static let shared = CustomObjectStore()

    @Published private(set) var objects: [CustomObject] = []

    private let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Revolution IDE/Custom Objects", isDirectory: true)
    private var indexURL: URL { folder.appendingPathComponent("objects.json") }

    private init() {
        objects = (try? JSONDecoder().decode([CustomObject].self, from: Data(contentsOf: indexURL))) ?? []
    }

    func modelData(for object: CustomObject) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent("\(object.id).brres"))
    }

    /// Converts the .obj (and its .mtl/textures) into the host-named .brres and saves the object.
    func add(name: String, host: CustomObject.Host, solid: Bool, objURL: URL) throws {
        let (text, sourceURL) = try ModelFile.objSource(objURL)
        guard let result = OBJToBRRES.convert(objText: text, objURL: sourceURL, modelName: host.resource) else {
            throw WSError.badStructure("Couldn't build a model from that .obj, it has no triangles, or one material covers more than \(MDL0Writer.maxVerticesPerMesh / 3) triangles.")
        }
        let doc = BRRESDocument()
        doc.resources.append(contentsOf: result.textures)
        doc.resources.append(result.model)
        let object = CustomObject(name: name, hostResource: host.resource, solid: solid)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try doc.serialize().write(to: folder.appendingPathComponent("\(object.id).brres"), options: .atomic)
        objects.append(object)
        try save()
    }

    func remove(_ object: CustomObject) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(object.id).brres"))
        objects.removeAll { $0.id == object.id }
        try? save()
    }

    private func save() throws {
        try JSONEncoder().encode(objects).write(to: indexURL, options: .atomic)
    }
}
