import AppIntents
import GistPadPlatform
import SwiftUI
import WidgetKit

@main
struct GistPadWidgetBundle: WidgetBundle {
  var body: some Widget {
    LauncherWidget()
    AddToTodayControl()
    OpenTodayControl()
    NewGistControl()
  }
}

struct GistPadWidgetIntentPackages: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [GistPadPlatformIntents.self] }
}

struct LauncherEntry: TimelineEntry {
  let date: Date
  let snapshot: LibrarySnapshot?
  let state: LauncherWidgetState
}

struct LauncherProvider: TimelineProvider {
  func placeholder(in context: Context) -> LauncherEntry {
    LauncherEntry(date: .now, snapshot: .preview(), state: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
    completion(context.isPreview
      ? LauncherEntry(date: .now, snapshot: .preview(), state: .available) : entry())
  }

  /// The app reloads the widget when the library changes, so the timeline only turns the day over,
  /// or retries soon when the snapshot couldn't be read, such as before first unlock.
  func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
    let current = entry()
    let calendar = Calendar.current
    let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current.date))
      ?? current.date.addingTimeInterval(3600)
    let retry = current.state == .unavailable ? current.date.addingTimeInterval(900) : midnight
    completion(Timeline(entries: [current], policy: .after(min(midnight, retry))))
  }

  private func entry() -> LauncherEntry {
    do {
      let snapshot = try LibrarySnapshot.read()
      return LauncherEntry(
        date: .now, snapshot: snapshot,
        state: snapshot?.accountID == nil ? .signedOut : .available)
    } catch {
      return LauncherEntry(date: .now, snapshot: nil, state: .unavailable)
    }
  }
}

struct LauncherWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: LauncherWidgetView.kind, provider: LauncherProvider()) { entry in
      LauncherWidgetView(snapshot: entry.snapshot, date: entry.date, state: entry.state)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("GistPad")
    .description("Open today's note, a recent gist or start a new one.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct AddToTodayControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "GistPadAddToToday") {
      ControlWidgetButton(action: ShowAddToTodayIntent()) {
        Label("Add to Today", systemImage: "calendar.badge.plus")
      }
    }
    .displayName("Add to Today")
    .description("Capture a thought or task in today's note.")
  }
}

struct OpenTodayControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "GistPadOpenToday") {
      ControlWidgetButton(action: OpenTodayIntent()) {
        Label("Open Today", systemImage: "calendar")
      }
    }
    .displayName("Open Today")
    .description("Open today's note.")
  }
}

struct NewGistControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "GistPadNewGist") {
      ControlWidgetButton(action: NewGistIntent()) {
        Label("New Gist", systemImage: "square.and.pencil")
      }
    }
    .displayName("New Gist")
    .description("Start a new gist.")
  }
}

#Preview("Launcher", as: .systemSmall) {
  LauncherWidget()
} timeline: {
  LauncherEntry(date: .now, snapshot: .preview(), state: .available)
  LauncherEntry(date: .now, snapshot: nil, state: .signedOut)
}

#Preview("Launcher", as: .systemMedium) {
  LauncherWidget()
} timeline: {
  LauncherEntry(date: .now, snapshot: .preview(), state: .available)
  LauncherEntry(date: .now, snapshot: nil, state: .signedOut)
}
