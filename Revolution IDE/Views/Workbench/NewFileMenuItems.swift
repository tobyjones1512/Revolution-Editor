import SwiftUI

/// The File > New menu (and a folder's right-click New), grouped so it stays short: a few
/// general kinds of file, then one submenu per enabled game.
struct NewFileMenuItems: View {
    let workbench: WorkbenchState
    /// Where the save panel starts (a folder's right-click New); nil for File > New.
    var directory: URL? = nil
    @AppStorage(GameTools.marioKartWii.defaultsKey) private var marioKartWiiTools = true
    @AppStorage(GameTools.marioKartDoubleDash.defaultsKey) private var doubleDashTools = true

    var body: some View {
        if marioKartWiiTools {
            Menu("Mario Kart Wii") {
                Button("Course Data (KMP)...") { workbench.newKMP(in: directory) }
                Button("Battle Arena Course Data (KMP)...") { workbench.newBattleKMP(in: directory) }
                Button("Collision (KCL) from Model...") { workbench.newKCLFromOBJ(in: directory) }
                    .help("Collision from a .obj or .dae, with surfaces guessed from its material and texture names.")
                NewSkyboxMenu(workbench: workbench, directory: directory)
            }
        }
        if doubleDashTools {
            Menu(GameTools.marioKartDoubleDash.displayName) {
                Button("Track from Model...") { workbench.newDoubleDashCourse = NewDoubleDashCourseRequest(directory: directory) }
                    .help("A slot's course archives from an .obj or .dae: model, collision, minimap, sky, a start point and an intro camera.")
                Button("Course Data (BOL)...") { workbench.newBOL(in: directory) }
                Button("Battle Arena Course Data (BOL)...") { workbench.newBattleBOL(in: directory) }
                Button("Collision (BCO) from Model...") { workbench.newBCOFromOBJ(in: directory) }
                    .help("Collision from a .obj or .dae, with surfaces guessed from its material names.")
                Menu("Sky") {
                    Button("Custom...") { workbench.newDoubleDashSky(in: directory) }
                        .help("A sky model (_sky.bmd) from your own .obj or .dae, textures fitted to the sky's memory budget.")
                    if DoubleDashDisc.linkedISO != nil {
                        Menu("From Game") {
                            ForEach(MKDDSlots.slots.filter { !$0.battle }) { slot in
                                Button(slot.title) { workbench.newDoubleDashSky(from: slot, in: directory) }
                            }
                        }
                        .help("Copies the sky of any Double Dash course from your linked disc.")
                    }
                }
            }
        }
        if marioKartWiiTools || doubleDashTools { Divider() }
        Menu("Model") {
            Button("Empty Model (BRRES)...") { workbench.newBRRES(in: directory) }
            Button("Model (BRRES) from .obj/.dae...") { workbench.newBRRESFromOBJ(in: directory) }
        }
        Menu("Archive") {
            Button("SZS Archive...") { workbench.newSZSArchive(in: directory) }
            Button("ARC Archive...") { workbench.newARCArchive(in: directory) }
        }
        Menu("Wii Homebrew") {
            Button("Project...") { workbench.showNewHomebrew = true }
                .help("A C or C++ project built with your own devkitPro install and run in Dolphin.")
            Button("UI Design (.wiiui)...") { workbench.newUIDesign(in: directory) }
                .help("A visual screen layout for a homebrew app, turned into C when you build.")
            Button("Node Graph (.wiinodes)...") { workbench.newNodeGraph(in: directory) }
            Button("Sprite Actor (.wiinodes)...") { workbench.newSpriteActor(in: directory) }
                .help("Visual, node-based logic for a homebrew app, turned into C when you build.")
        }
        Button("Message Table (BMG)...") { workbench.newBMG(in: directory) }
        Button("Music (BRSTM) from Audio...") { workbench.newBRSTMFromAudio(in: directory) }
        Divider()
        Button("Text File...") { workbench.newTextFile(in: directory) }
    }
}
