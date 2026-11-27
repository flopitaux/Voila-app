import AppKit
import SwiftUI

extension MeetingLink.Service {
    /// The service's own icon, taken from its app when it is installed on this Mac (Zoom,
    /// Microsoft Teams, Webex, or Google Meet installed as a web app). Nil otherwise.
    @MainActor
    var appIcon: NSImage? {
        if let cached = ServiceIconCache.icons[self] { return cached }
        let icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        ServiceIconCache.icons[self] = icon
        return icon
    }

    private var appURL: URL? { InstalledApp.url(bundleIDs: bundleIDs, names: appNames) }

    private var bundleIDs: [String] {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: ["Cisco-Systems.Spark", "com.webex.meetingmanager", "com.cisco.webexmeetingsapp"]
        case .meet, .other: []
        }
    }

    private var appNames: [String] {
        switch self {
        case .meet: ["Google Meet", "Meet"]
        default: []
        }
    }
}

@MainActor
private enum ServiceIconCache {
    /// Looked up once per service (a nil is remembered too).
    static var icons: [MeetingLink.Service: NSImage?] = [:]
}

/// The meeting service's own icon, or a generic camera when its app isn't installed.
struct ServiceIcon: View {
    var service: MeetingLink.Service
    var size: CGFloat
    /// The camera symbol to fall back on ("video" or "video.fill").
    var fallback = "video.fill"

    var body: some View {
        if let icon = service.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.62, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}

/// Finds an app on this Mac, to borrow its icon.
enum InstalledApp {
    static func url(bundleIDs: [String], names: [String]) -> URL? {
        for id in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        // Web apps (Google Meet, LinkedIn) get a per-install bundle id: look for them by name.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["Applications/Chrome Apps.localized", "Applications/Edge Apps.localized",
                       "Applications/Brave Browser Apps.localized", "Applications/Arc Apps.localized", "Applications"]
            .map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/Applications")]
        for name in names {
            for folder in folders {
                let url = folder.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}

/// LinkedIn's own icon when it is installed as an app, else a small "in" badge in its blue.
struct LinkedInIcon: View {
    var size: CGFloat

    @MainActor private static let appIcon: NSImage? = InstalledApp
        .url(bundleIDs: ["com.linkedin.LinkedIn"], names: ["LinkedIn"])
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        if let icon = Self.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Text("in")
                .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color(red: 0.04, green: 0.40, blue: 0.76),
                            in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }
}

/// A guest's picture (from the organization's directory), or their initials on a soft colour.
struct Avatar: View {
    var name: String
    var photo: URL?
    var size: CGFloat

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private var placeholder: some View {
        let tint = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }.isMultiple(of: 2) ? Theme.tint : Theme.tint2
        return Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
    }

    var body: some View {
        if let photo {
            AsyncImage(url: photo) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholder
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            placeholder
        }
    }
}
