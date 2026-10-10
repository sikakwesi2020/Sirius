import SwiftUI
import WidgetKit

private struct WidgetStudyActivity: Codable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subject: String
    let itemCount: Int
    let startsAt: Date
    let deepLink: String
}

private struct SiriusWidgetEntry: TimelineEntry {
    let date: Date
    let activity: WidgetStudyActivity?
}

private struct SiriusWidgetProvider: TimelineProvider {
    private let group = "group.fobia.readme.Maximus.Sirius"
    private let key = "scheduled-study-activities-v1"

    func placeholder(in context: Context) -> SiriusWidgetEntry {
        SiriusWidgetEntry(date: .now, activity: WidgetStudyActivity(
            id: "preview", kind: "quiz", title: "Operating Systems Review",
            subject: "Computer Science", itemCount: 15,
            startsAt: .now.addingTimeInterval(3600), deepLink: "sirius://quiz"
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SiriusWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SiriusWidgetEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = entry.activity.map { max($0.startsAt.addingTimeInterval(60), .now.addingTimeInterval(15 * 60)) }
            ?? .now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> SiriusWidgetEntry {
        let activities: [WidgetStudyActivity]
        if let data = UserDefaults(suiteName: group)?.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WidgetStudyActivity].self, from: data) {
            activities = decoded
        } else { activities = [] }
        let next = activities.filter { $0.startsAt >= Date().addingTimeInterval(-15 * 60) }
            .sorted { $0.startsAt < $1.startsAt }.first
        return SiriusWidgetEntry(date: .now, activity: next)
    }
}

private struct SiriusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SiriusWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: lockScreenInline
            case .accessoryCircular: lockScreenCircular
            case .accessoryRectangular: lockScreenRectangular
            case .systemSmall: compact
            default: expanded
            }
        }
        .containerBackground(for: .widget) {
            if isLockScreenFamily { Color.clear }
            else {
                LinearGradient(colors: [Color(red: 0.015, green: 0.04, blue: 0.09), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .widgetURL(URL(string: entry.activity?.deepLink ?? "sirius://home"))
    }

    private var isLockScreenFamily: Bool {
        family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular
    }

    private var lockScreenInline: some View {
        Label {
            if let activity = entry.activity {
                Text("\(activity.title) · \(activity.startsAt, style: .relative)")
            } else {
                Text("Sirius · Ready to study")
            }
        } icon: {
            Image(systemName: entry.activity?.kind == "quiz" ? "questionmark.app.fill" : "cube.fill")
        }
    }

    private var lockScreenCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                SiriusLockScreenCube().frame(width: 30, height: 30)
                if let activity = entry.activity {
                    Text(activity.startsAt, style: .timer)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.55)
                } else {
                    Text("STUDY").font(.system(size: 7, weight: .black, design: .monospaced))
                }
            }
            .widgetAccentable()
        }
    }

    private var lockScreenRectangular: some View {
        HStack(spacing: 9) {
            SiriusLockScreenCube().frame(width: 43, height: 43).widgetAccentable()
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.activity == nil ? "SIRIUS IS READY" : "UP NEXT")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                Text(entry.activity?.title ?? "Let's start learning")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(2)
                if let activity = entry.activity {
                    HStack(spacing: 4) {
                        Image(systemName: activity.kind == "quiz" ? "questionmark.circle.fill" : "headphones")
                        if activity.itemCount > 0 {
                            Text("\(activity.itemCount) \(activity.kind == "quiz" ? "questions" : "parts")")
                        }
                        Text("·")
                        Text(activity.startsAt, style: .relative)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                } else {
                    Text("Tap to wake your study companion")
                        .font(.system(size: 9, weight: .semibold)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SiriusWidgetCube().frame(width: 45, height: 45)
                Spacer()
                if let activity = entry.activity {
                    Image(systemName: activity.kind == "quiz" ? "questionmark" : "headphones")
                        .font(.system(size: 13, weight: .black)).foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
            Text(entry.activity?.title ?? "LET'S START LEARNING")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .lineLimit(2).foregroundStyle(.white)
            footer
        }
    }

    private var expanded: some View {
        HStack(spacing: 16) {
            SiriusWidgetCube().frame(width: 82, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.activity == nil ? "SIRIUS IS READY" : "UP NEXT")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(2).foregroundStyle(.white.opacity(0.55))
                Text(entry.activity?.title ?? "Let's learn something brilliant.")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(2).foregroundStyle(.white)
                if let subject = entry.activity?.subject, !subject.isEmpty {
                    Text(subject).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.56)).lineLimit(1)
                }
                footer
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var footer: some View {
        if let activity = entry.activity {
            HStack(spacing: 6) {
                if activity.itemCount > 0 {
                    Text(activity.kind == "quiz" ? "\(activity.itemCount) QUESTIONS" : "\(activity.itemCount) PARTS")
                }
                Text(activity.startsAt, style: .relative)
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.68))
        } else {
            Text("TAP TO STUDY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct SiriusLockScreenCube: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(.primary.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary, lineWidth: 1.5))
            HStack(spacing: 5) {
                Capsule().fill(.primary).frame(width: 3.5, height: 6)
                Capsule().fill(.primary).frame(width: 3.5, height: 6)
            }
            .offset(y: -4)
            SiriusLockSmile().stroke(.primary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 13, height: 6).offset(y: 6)
        }
        .rotation3DEffect(.degrees(-10), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(14), axis: (x: 0, y: 1, z: 0))
        .accessibilityHidden(true)
    }
}

private struct SiriusLockSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

private struct SiriusWidgetCube: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [.white, Color(white: 0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: .black.opacity(0.55), radius: 5, x: 4, y: 6)
            HStack(spacing: 8) {
                eye; eye
            }.offset(y: -6)
            Smile().stroke(.black, style: StrokeStyle(lineWidth: 3, lineCap: .round)).frame(width: 25, height: 12).offset(y: 11)
        }
        .rotation3DEffect(.degrees(-13), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(18), axis: (x: 0, y: 1, z: 0))
    }

    private var eye: some View {
        Circle().fill(.black).frame(width: 9, height: 12)
            .overlay(Circle().fill(.white).frame(width: 2.5, height: 2.5).offset(x: -2, y: -3))
    }

    private struct Smile: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                              control: CGPoint(x: rect.midX, y: rect.maxY))
            return path
        }
    }
}

@main
struct SiriusWidgetBundle: WidgetBundle {
    var body: some Widget { SiriusStudyWidget() }
}

private struct SiriusStudyWidget: Widget {
    let kind = "SiriusStudyWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SiriusWidgetProvider()) { entry in
            SiriusWidgetView(entry: entry)
        }
        .configurationDisplayName("Sirius Study")
        .description("See your next lesson or quiz and jump straight back in.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
