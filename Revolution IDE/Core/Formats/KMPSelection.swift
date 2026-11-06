import Foundation

/// Identifies a selected item inside a KMP document, for the inspector + 2D canvas highlighting.
enum KMPSelection: Hashable {
    case ktpt(Int), enpt(Int), enph(Int), itpt(Int), itph(Int), ckpt(Int), ckph(Int)
    case ckptLeft(Int), ckptRight(Int)
    /// Enemy/item path points are edited as a "tunnel" (see `KMPEditorView.tunnelEdges`): each
    /// stored point is drawn as its centre plus two edge handles sitting `radius` away along the
    /// path, and the point's radius is half the distance between those two handles.
    case enptLeft(Int), enptRight(Int), itptLeft(Int), itptRight(Int)
    case gobj(Int), poti(route: Int, point: Int?), area(Int), came(Int), jgpt(Int), cnpt(Int), mspt(Int), stgi

    /// The point a tunnel-edge handle belongs to, marquee straighten/equalise, ground snap, and
    /// the inspector all care about the point itself, not which of its two derived handles was hit
    /// (dragging a handle only changes the radius; see `KMPEditorView.applyDelta`).
    var asPoint: KMPSelection {
        switch self {
        case .enptLeft(let i), .enptRight(let i): return .enpt(i)
        case .itptLeft(let i), .itptRight(let i): return .itpt(i)
        default: return self
        }
    }
}
