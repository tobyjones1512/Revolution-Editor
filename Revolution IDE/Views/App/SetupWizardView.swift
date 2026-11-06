import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// First-launch setup: which games to show tools for, then the keys, emulator and devkitPro the app
/// can use. Every step can be skipped and revisited in Settings. Debug builds can rerun it from the Window menu.
struct SetupWizardView: View {
	static let completedKey = "setup.completed"
	static var needed: Bool { !UserDefaults.standard.bool(forKey: completedKey) }

	@Environment(\.openWindow) private var openWindow
	@Environment(\.dismissWindow) private var dismissWindow
	@ObservedObject private var keys = KeyManager.shared
	@ObservedObject private var emulator = EmulatorLauncher.shared
	@State private var step = 0
	@State private var devkitRoot = DevkitPro.root
	@AppStorage(GameTools.marioKartWii.defaultsKey) private var marioKartWii = true
	@AppStorage(GameTools.marioKartDoubleDash.defaultsKey) private var doubleDash = true
	@AppStorage(GameTools.nsmbw.defaultsKey) private var nsmbw = true

	private let lastStep = 4

	var body: some View {
		VStack(spacing: 0) {
			Group {
				switch step {
				case 0: intro
				case 1: games
				case 2: keysStep
				case 3: emulatorStep
				default: homebrewStep
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
			.padding(.horizontal, 36).padding(.top, 36)
			footer.padding(20)
		}
		.frame(width: 520, height: 520)
		.background(.regularMaterial)
		.ignoresSafeArea()
	}

	// MARK: Steps

	private func heading(_ title: String, _ detail: String) -> some View {
		VStack(spacing: 6) {
			Text(title).font(.title2.bold())
			Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
		}
		.padding(.bottom, 16)
	}

	private var intro: some View {
		VStack(spacing: 14) {
			Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
				.shadow(color: .black.opacity(0.25), radius: 8, y: 4)
			heading("Welcome to Revolution Editor", "A few quick questions to get set up. Everything here can be skipped and changed later in Settings.")
		}
	}

	private var games: some View {
		VStack {
			heading("Which games do you mod?", "Tools for a game that is switched off stay out of your menus.")
			Form {
				Toggle(GameTools.marioKartWii.displayName, isOn: $marioKartWii)
				Toggle(isOn: $doubleDash) { gameLabel(GameTools.marioKartDoubleDash, badge: ("Beta", .blue)) }
				Toggle(isOn: $nsmbw) { gameLabel(GameTools.nsmbw, badge: ("Pre-Alpha", .orange)) }
			}
			.formStyle(.grouped).scrollDisabled(true)
		}
	}

	private func gameLabel(_ game: GameTools, badge: (String, Color)) -> some View {
		HStack(spacing: 6) {
			Text(game.displayName)
			Text(badge.0).font(.caption2.bold())
				.padding(.horizontal, 6).padding(.vertical, 2)
				.background(badge.1.opacity(0.2), in: Capsule())
				.foregroundStyle(badge.1)
		}
	}

	private var keysStep: some View {
		VStack {
			heading("Disc keys", "Wii discs are encrypted. Choose your own key.bin so the app can open them. The Korean key is only needed for Korean discs. Nothing is bundled or downloaded.")
			Form {
				StatusRow(title: "key.bin (common key)", detail: keys.commonKeyPath, placeholder: "Not loaded") {
					Button("Choose...") {
						PanelPresenter.openFile { url in if let url { try? keys.loadCommonKey(from: url) } }
					}
				}
				StatusRow(title: "kkey.bin (Korean key, optional)", detail: keys.koreanKeyPath, placeholder: "Not loaded") {
					Button("Choose...") {
						PanelPresenter.openFile { url in if let url { try? keys.loadKoreanKey(from: url) } }
					}
				}
			}
			.formStyle(.grouped).scrollDisabled(true)
		}
	}

	private var emulatorStep: some View {
		VStack {
			heading("Emulator", "Revolution Editor runs your courses and homebrew in your own copy of Dolphin.")
			Form {
				StatusRow(title: "Dolphin", detail: emulator.dolphinAppURL?.path, placeholder: "Not found") {
					Button("Choose...") {
						PanelPresenter.openFile(configure: {
							$0.allowedContentTypes = [.application]
							$0.directoryURL = URL(fileURLWithPath: "/Applications")
						}) { url in if let url { emulator.rememberManuallyChosen(url) } }
					}
				}
			}
			.formStyle(.grouped).scrollDisabled(true)
			Link("Get Dolphin", destination: URL(string: "https://dolphin-emu.org/download/")!)
		}
	}

	private var homebrewStep: some View {
		VStack {
			heading("Wii homebrew", "Building homebrew apps needs devkitPro (devkitPPC and libogc). Skip this if you only edit game files.")
			Form {
				StatusRow(title: "devkitPro", detail: devkitRoot?.path, placeholder: "Not found") {
					Button("Choose...") {
						PanelPresenter.openFile(configure: {
							$0.canChooseFiles = false
							$0.canChooseDirectories = true
							$0.directoryURL = URL(fileURLWithPath: "/opt")
						}) { url in
							if let url, DevkitPro.isValid(url) { UserDefaults.standard.set(url.path, forKey: DevkitPro.pathKey) }
							devkitRoot = DevkitPro.root
						}
					}
				}
			}
			.formStyle(.grouped).scrollDisabled(true)
			Link("How to install devkitPro", destination: DevkitPro.installURL)
		}
	}

	// MARK: Footer

	private var footer: some View {
		HStack {
			Button("Back") { step -= 1 }.opacity(step == 0 ? 0 : 1).disabled(step == 0)
			Spacer()
			HStack(spacing: 6) {
				ForEach(0...lastStep, id: \.self) { Circle().fill($0 == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7) }
			}
			Spacer()
			if step < lastStep {
				Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
			} else {
				Button("Get Started") { finish() }.keyboardShortcut(.defaultAction)
			}
		}
		.controlSize(.large)
	}

	private func finish() {
		UserDefaults.standard.set(true, forKey: Self.completedKey)
		openWindow(id: "welcome")
		dismissWindow(id: "setup")
	}
}
