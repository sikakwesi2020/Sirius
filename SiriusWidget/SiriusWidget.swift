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
            if family == .systemSmall { compact }
            else { expanded }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.015, green: 0.04, blue: 0.09), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .widgetURL(URL(string: entry.activity?.deepLink ?? "sirius://home"))
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
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
