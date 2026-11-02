import AppIntents
import GistPadPlatform
import OSLog
import SwiftUI
import WidgetKit

@main
struct GistPadWidgetBundle: WidgetBundle {
  var body: some Widget {
    TodayWidget()
    AddToTodayControl()
  }
}

struct GistPadWidgetIntentPackages: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [GistPadPlatformIntents.self] }
}

struct TodayEntry: TimelineEntry {
  let date: Date
  let snapshot: NotebookSystemSnapshot?
  let state: TodayWidgetState
}

struct TodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayEntry {
    TodayEntry(date: .now, snapshot: .preview(), state: .placeholder)
  }

  func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
    completion(context.isPreview
      ? TodayEntry(date: .now, snapshot: .preview(), state: .available) : entry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
    let current = entry()
    var calendar = Calendar(identifier: .gregorian)
    if let zone = current.snapshot?.today.timeZoneIdentifier,
      let timeZone = TimeZone(identifier: zone)
    {
      calendar.timeZone = timeZone
    }
    let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: current.date))
      ?? current.date.addingTimeInterval(3600)
    completion(Timeline(entries: [current], policy: .after(min(midnight, current.date.addingTimeInterval(900)))))
  }

  private func entry() -> TodayEntry {
    do {
      let snapshot = try SharedNotebookStore().read()
      return TodayEntry(
        date: .now, snapshot: snapshot,
        state: snapshot?.accountID == nil ? .signedOut : .available)
    } catch let error as CocoaError where error.code == .fileReadNoPermission {
      return TodayEntry(date: .now, snapshot: nil, state: .locked)
    } catch {
      Logger(subsystem: "dev.gistpad.GistPad", category: "Widget")
        .error("Widget snapshot failed: \(String(reflecting: type(of: error)), privacy: .public)")
      return TodayEntry(date: .now, snapshot: nil, state: .unavailable)
    }
  }
}

struct TodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: TodayWidgetView.kind, provider: TodayProvider()) { entry in
      TodayWidgetView(snapshot: entry.snapshot, date: entry.date, state: entry.state)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Today")
    .description("Keep your daily note close, and check off what matters.")
    .supportedFamilies([
      .systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular
    ])
  }
}

struct AddToTodayControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "GistPadAddToToday") {
      ControlWidgetButton(action: CaptureTodayIntent()) {
        Label("Add to Today", systemImage: "square.and.pencil")
      }
    }
    .displayName("Add to Today")
    .description("Capture a thought or task in today's note.")
  }
}

#Preview("Tasks", as: .systemSmall) {
  TodayWidget()
} timeline: {
  TodayEntry(date: .now, snapshot: .preview(), state: .available)
  TodayEntry(date: .now, snapshot: nil, state: .signedOut)
}

#Preview("Tasks", as: .systemMedium) {
  TodayWidget()
} timeline: {
  TodayEntry(date: .now, snapshot: .preview(), state: .available)
  TodayEntry(date: .now, snapshot: nil, state: .signedOut)
}

#Preview("Lock Screen", as: .accessoryRectangular) {
  TodayWidget()
} timeline: {
  TodayEntry(date: .now, snapshot: .preview(), state: .available)
}
