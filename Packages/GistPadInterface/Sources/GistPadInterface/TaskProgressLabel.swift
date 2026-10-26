#if os(iOS)
import SwiftUI

private struct TaskCompletionMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(InterfaceTheme.taskCompletion)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct TaskProgressLabel: View {
    let progress: LibraryTaskProgress
    var isOverdue = false
    var usesPrimaryInk = false
    var showsIndicator = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var ringSize = 14

    var body: some View {
        HStack(spacing: 4) {
            if showsIndicator {
                if progress.remaining == 0 {
                    TaskCompletionMark(size: ringSize)
                } else {
                    ZStack {
                        Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: Double(progress.completed) / Double(progress.total))
                            .stroke(ink, style: .init(lineWidth: 2, lineCap: .round))
                            .padding(1)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: ringSize, height: ringSize)
                    .accessibilityHidden(true)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: progress.completed)
                }
            }
            Text(verbatim: "\(progress.completed.formatted())/\(progress.total.formatted())")
                .font(.footnote)
                .monospacedDigit()
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var ink: Color {
        if isOverdue && progress.remaining > 0 { return InterfaceTheme.overdue }
        return usesPrimaryInk ? Color(uiColor: .label) : .secondary
    }

    private var accessibilitySummary: Text {
        let summary = Text("\(progress.completed) of \(progress.total) tasks complete", bundle: .module)
        if isOverdue && progress.remaining > 0 {
            let status = Text("Unfinished tasks", bundle: .module)
            return Text("\(summary), \(status)", bundle: .module)
        }
        return summary
    }
}
#endif
