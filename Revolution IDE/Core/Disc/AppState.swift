import Foundation
import SwiftUI
import Combine

/// App-wide state for the disc tools: the open disc, the log panel at the bottom of the window,
/// and busy/progress tracking for long operations. Changes are written straight into the file
/// that was opened with Open ISO; there is no separate working copy.
@MainActor
final class AppState: ObservableObject {
    @Published var discURL: URL?
    @Published var wiiDisc: WiiDisc?
    @Published var gcDisc: GameCubeDisc?
    @Published var rootNode: DiscNode?

    @Published var selection: DiscNode?
    @Published var logLines: [String] = ["Wii/GCN Disc Scrubber, open an ISO to begin."]
    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var progressLabel = ""
    @Published var errorMessage: String?

    let keyManager = KeyManager.shared

    var isWiiDisc: Bool { wiiDisc != nil }
    var isGameCubeDisc: Bool { gcDisc != nil }

    init() {
        if keyManager.restoredCommonKeyOnLaunch, let path = keyManager.commonKeyPath {
            logLines.append("Remembered key.bin from a previous session: \(path)")
        }
        if keyManager.restoredKoreanKeyOnLaunch, let path = keyManager.koreanKeyPath {
            logLines.append("Remembered kkey.bin from a previous session: \(path)")
        }
    }

    func log(_ s: String) {
        logLines.append(s)
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    // MARK: Opening

    func openISO(url: URL) {
        keyManager.autoLoad(nextTo: url)
        log("Opening \(url.lastPathComponent)...")
        do {
            let header = try Data(contentsOf: url, options: [.mappedIfSafe]).prefix(0x460)
            let wiiMagic = Data(header).be32(0x18)
            let gcMagic = Data(header).be32(0x1C)

            wiiDisc = nil
            gcDisc = nil
            rootNode = nil
            selection = nil

            if wiiMagic == WiiConstants.wiiMagic {
                let disc = try WiiDisc(url: url, commonKey: keyManager.commonKey, koreanKey: keyManager.koreanKey)
                wiiDisc = disc
                rootNode = disc.root
                discURL = url
                log("Loaded \(disc.gameTitle.isEmpty ? disc.gameID : disc.gameTitle) [\(disc.gameID)]. \(disc.partitions.count) partition(s) readable.")
                let used = disc.partitions.reduce(UInt64(0)) { $0 + $1.usedDataSize }
                log("Data size on disc: \(ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .binary))")
            } else if gcMagic == WiiConstants.gcMagic {
                let disc = try GameCubeDisc(url: url)
                gcDisc = disc
                rootNode = disc.root
                discURL = url
                log("Loaded GameCube disc \(disc.gameTitle) [\(disc.gameID)]. Read-only: replacing files isn't supported on GameCube discs.")
            } else {
                throw WSError.notAWiiOrGameCubeDisc
            }
        } catch {
            report(error)
        }
    }

    func reload() {
        guard let url = discURL else { return }
        openISO(url: url)
    }

    func report(_ error: Error) {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        errorMessage = msg
        log("ERROR: \(msg)")
    }

    // MARK: Background task helper

    private func runTask(label: String, reloadAfter: Bool = false, _ body: @escaping (@escaping (Double, String) -> Void) throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        progressLabel = label
        log(label)

        let progressHandler: (Double, String) -> Void = { [weak self] p, msg in
            Task { @MainActor in
                self?.progress = p
                self?.progressLabel = msg
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try body(progressHandler)
                await MainActor.run {
                    self?.log("Done: \(label)")
                    self?.isBusy = false
                    self?.progress = 1
                    if reloadAfter { self?.reload() }
                }
            } catch {
                await MainActor.run {
                    self?.isBusy = false
                    self?.report(error)
                }
            }
        }
    }

    // MARK: File extract / replace

    func extract(node: DiscNode, to destination: URL) {
        guard let disc = wiiDisc else {
            if let gc = gcDisc {
                runTask(label: "Extracting \(node.name)...") { _ in
                    let data = try gc.readFile(node: node)
                    try data.write(to: destination, options: .atomic)
                }
            }
            return
        }
        runTask(label: "Extracting \(node.name)...") { _ in
            try FileOperations.extract(disc: disc, node: node, to: destination)
        }
    }

    func replace(node: DiscNode, withDataAt sourceURL: URL) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Replacing \(node.name)...") { progress in
            let newData = try Data(contentsOf: sourceURL)
            try FileOperations.replace(discURL: discURL, disc: disc, node: node, newData: newData) { msg in
                progress(0, msg)
            }
        }
    }

    // MARK: Scrub / Unscrub / Trim

    func scrub(options: ScrubOptions, isoDestination: URL?, diffDestination: URL?) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Scrubbing (\(options.type == .trucha ? "TRUCHA" : "0xFF") mode)...") { progress in
            try Scrubber.run(disc: disc, sourceURL: discURL, options: options,
                              isoDestination: isoDestination, diffDestination: diffDestination, progress: progress)
        }
    }

    func unscrub(scrubbedURL: URL, diffURL: URL, destinationURL: URL) {
        runTask(label: "Unscrubbing image...") { progress in
            try Unscrubber.run(scrubbedURL: scrubbedURL, diffURL: diffURL, destinationURL: destinationURL, progress: progress)
        }
    }

    func trim(destinationURL: URL) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Trimming ISO...") { progress in
            try Trimmer.run(disc: disc, sourceURL: discURL, destinationURL: destinationURL, progress: progress)
        }
    }

    // MARK: Partition operations

    func deletePartition(index: Int) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Deleting partition \(index)...", reloadAfter: true) { _ in
            try PartitionOperations.deletePartition(discURL: discURL, disc: disc, partitionIndex: index) { msg in
                Task { @MainActor in self.log(msg) }
            }
        }
    }

    func resizePartition(index: Int, newDataSize: UInt64) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Resizing partition \(index)...", reloadAfter: true) { _ in
            try PartitionOperations.resizePartition(discURL: discURL, disc: disc, partitionIndex: index, newDataSize: newDataSize) { msg in
                Task { @MainActor in self.log(msg) }
            }
        }
    }

    func shrinkPartition(index: Int) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Shrinking partition \(index)...", reloadAfter: true) { _ in
            try PartitionOperations.shrinkPartition(discURL: discURL, disc: disc, partitionIndex: index) { msg in
                Task { @MainActor in self.log(msg) }
            }
        }
    }

    func shufflePartitions() {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Shuffling partitions...", reloadAfter: true) { _ in
            try PartitionOperations.shufflePartitions(discURL: discURL, disc: disc) { msg in
                Task { @MainActor in self.log(msg) }
            }
        }
    }

    func exportPartition(index: Int, to destination: URL) {
        guard let disc = wiiDisc else { return }
        runTask(label: "Exporting partition \(index)...") { progress in
            try PartitionOperations.exportPartition(disc: disc, partitionIndex: index, to: destination) { p in
                progress(p, "Exporting partition \(index)... \(Int(p * 100))%")
            }
        }
    }

    func importPartition(blobURL: URL, atOffset: UInt64, tableIndex: Int, kind: PartitionKind) {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Importing partition...", reloadAfter: true) { _ in
            try PartitionOperations.importPartition(discURL: discURL, blobURL: blobURL, atOffset: atOffset,
                                                      tableIndex: tableIndex, kind: kind,
                                                      existingEntries: disc.partitionTableEntries) { msg in
                Task { @MainActor in self.log(msg) }
            }
        }
    }

    func toggleBootMode() {
        guard let disc = wiiDisc, let discURL else { return }
        runTask(label: "Toggling boot mode...", reloadAfter: true) { _ in
            _ = try BootMode.toggle(discURL: discURL, currentByte: disc.bootMode)
        }
    }
}
