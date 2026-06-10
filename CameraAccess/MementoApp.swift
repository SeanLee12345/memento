import SwiftUI

#if DEBUG
import DebugBridgeCore
#if canImport(UIKit)
import DebugBridgeUI
#endif
#endif

@main
struct MementoApp: App {
  @Environment(\.scenePhase) private var scenePhase

  init() {
    DATGlassesManager.shared.configureAtStartup()

    #if DEBUG
    Task { @MainActor in
      #if canImport(UIKit)
      DebugBridgeUIWiring.installAll()
      DebugOverlayWindow.shared.install(
        recording: ProcessInfo.processInfo.arguments.contains("--gstack-recording")
      )
      #endif
      StateServer.shared.start()
    }
    #endif
  }

  var body: some Scene {
    WindowGroup {
      StreamSessionView()
        .tint(.appPrimary)
        .onOpenURL { url in
          Task {
            await DATGlassesManager.shared.handleOpenURL(url)
          }
        }
        .onChange(of: scenePhase) { _, phase in
          DATGlassesManager.shared.noteScenePhase(phase)
          if phase == .active {
            Task {
              await DATGlassesManager.shared.resumeAfterExternalAppReturn()
            }
          }
        }
    }
  }
}
