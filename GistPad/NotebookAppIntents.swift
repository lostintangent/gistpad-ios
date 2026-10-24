import AppIntents
import GistPadPlatform

struct GistPadAppIntentPackages: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [GistPadPlatformIntents.self] }
}

struct GistPadShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenTodayIntent(),
      phrases: ["Open Today in \(.applicationName)", "Open my daily note in \(.applicationName)"],
      shortTitle: "Open Today", systemImageName: "calendar")
    AppShortcut(
      intent: OpenNoteIntent(),
      phrases: ["Open \(\.$target) in \(.applicationName)"],
      shortTitle: "Open Note", systemImageName: "doc.text")
    AppShortcut(
      intent: AddToTodayIntent(),
      phrases: ["Add to Today in \(.applicationName)", "Capture in \(.applicationName)"],
      shortTitle: "Add to Today", systemImageName: "square.and.pencil")
  }
}
