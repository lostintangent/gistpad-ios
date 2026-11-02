import AppIntents
import GistPadPlatform
import SwiftUI
import WidgetKit

@main
struct GistPadWidgetBundle: WidgetBundle {
  var body: some Widget {
    LauncherWidget()
    LockScreenTodayWidget()
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
    guard current.state != .unavailable,
      let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current.date))
    else {
      completion(Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(900))))
      return
    }
    // An entry appears right at its date, but a reload waits on the system, so tomorrow is drawn ahead.
    let tomorrow = LauncherEntry(date: midnight, snapshot: current.snapshot, state: current.state)
    completion(Timeline(entries: [current, tomorrow], policy: .atEnd))
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

struct LockScreenTodayEntry: TimelineEntry {
  let date: Date
}

/// The mark never changes, so one entry serves for good.
struct LockScreenTodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> LockScreenTodayEntry { LockScreenTodayEntry(date: .now) }

  func getSnapshot(in context: Context, completion: @escaping (LockScreenTodayEntry) -> Void) {
    completion(placeholder(in: context))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenTodayEntry>) -> Void) {
    completion(Timeline(entries: [placeholder(in: context)], policy: .never))
  }
}

/// One round button under the Lock Screen's clock, GistPad's notebook mark in the Lock Screen's tint.
struct LockScreenTodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "GistPadLockScreenToday", provider: LockScreenTodayProvider()) { _ in
      GeometryReader { proxy in
        Image("TodayMark")
          .resizable()
          .scaledToFit()
          .frame(height: proxy.size.height / 2)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background { AccessoryWidgetBackground() }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text("Today's note"))
      .widgetURL(GistPadLink.today.url)
      // The Lock Screen drops container backgrounds, so the disc lives in the content.
      .containerBackground(for: .widget) { Color.clear }
    }
    .configurationDisplayName("Today")
    .description("Open today's note.")
    .supportedFamilies([.accessoryCircular])
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

#Preview("Today", as: .accessoryCircular) {
  LockScreenTodayWidget()
} timeline: {
  LockScreenTodayEntry(date: .now)
}
