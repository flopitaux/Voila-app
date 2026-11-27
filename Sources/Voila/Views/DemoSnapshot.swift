#if DEBUG
import AppKit
import SwiftUI

/// Renders the meeting views to PNG files without a screen (`VOILA_DEMO_SNAPSHOT=<folder>`,
/// with `VOILA_DEMO=1`), for visual checks when windows can't be captured.
@MainActor
enum DemoSnapshot {
    static func write(to folder: String, model: AppModel) {
        func save(_ view: some View, _ name: String) {
            let renderer = ImageRenderer(content: view.environment(model).font(.voila(13)).background(Theme.background))
            renderer.scale = 2
            guard let tiff = renderer.nsImage?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        // ImageRenderer leaves scroll views blank, so the topics also go to a text file.
        let summary = model.calendar.meetings.map { "\($0.id) | \($0.title) | \($0.timeRange)\n\($0.topics)" }
            .joined(separator: "\n---\n")
        try? summary.write(toFile: folder + "/meetings.txt", atomically: true, encoding: .utf8)
        save(TodayAgenda().frame(width: 380).padding(8), "today.png")
        save(TodayAgenda(startOnTomorrow: true).frame(width: 380).padding(8), "tomorrow.png")
        for meeting in model.calendar.meetings where meeting.hasGuests {
            save(MeetingCardView(meetings: [meeting], onJoin: { _ in }, onOpenCalendar: { _ in }, onClose: {}),
                 "card-\(meeting.id).png")
        }
    }
}
#endif
