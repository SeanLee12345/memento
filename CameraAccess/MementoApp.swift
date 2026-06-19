import SwiftUI

@main
struct MementoApp: App {
  @Environment(\.scenePhase) private var scenePhase

  init() {
    DATGlassesManager.shared.configureAtStartup()
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
