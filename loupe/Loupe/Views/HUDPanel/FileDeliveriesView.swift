import SwiftUI
import UniformTypeIdentifiers

/// The files the running sessions have sent with SendUserFile
/// (`FileDeliveryService`), under the panel's header on every tab: one card
/// a call, newest first, with the session's name, the caption and a line a
/// file. A click on a file opens it in its default app; the × puts the card
/// away. The newest `shown` cards show; a line under them opens the rest in
/// a scrolling list. Nothing is drawn while there is no card.
struct FileDeliveriesSection: View {
    @ObservedObject var service: FileDeliveryService
    @Environment(\.fontScale) private var scale
    @State private var showAll = false

    static let shown = 3

    var body: some View {
        let all = service.deliveries
        if !all.isEmpty {
            // The ages ("3m") move on with the minute.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 4) {
                    if showAll && all.count > Self.shown {
                        ScrollView {
                            cards(all, now: context.date)
                        }
                        .frame(height: 230 * scale)
                    } else {
                        cards(Array(all.prefix(Self.shown)), now: context.date)
                    }
                    if all.count > Self.shown {
                        Button(action: { showAll.toggle() }) {
                            Text(showAll ? "Show the newest \(Self.shown) only"
                                         : "\(all.count - Self.shown) more sent earlier")
                                .font(.system(size: 10.5 * scale))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            Divider().opacity(0.5)
        }
    }

    private func cards(_ deliveries: [FileDelivery], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(deliveries) { delivery in
                FileDeliveryCard(delivery: delivery, name: service.sessionName(delivery), now: now, service: service)
            }
        }
    }
}

/// One SendUserFile call: the session's name with its machine and the
/// call's age, the caption, and its files.
private struct FileDeliveryCard: View {
    let delivery: FileDelivery
    let name: String
    let now: Date
    @ObservedObject var service: FileDeliveryService
    @Environment(\.fontScale) private var scale
    @State private var closeHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("\(delivery.host.machine) · \(LostTreeLineView.age(Int(max(now.timeIntervalSince(delivery.sentAt), 0))))")
                    .font(.custom("Fira Code", size: 9.5 * scale))
                    .foregroundColor(.secondary.opacity(0.7))
                Button(action: { service.dismiss(delivery) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(closeHovering ? 1 : 0.6))
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovering = $0 }
                .help("Put this card away. The files stay where the session wrote them.")
                .accessibilityLabel("Put this card away")
            }
            if !delivery.caption.isEmpty {
                Text(delivery.caption)
                    .font(.system(size: 11 * scale))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(delivery.files.enumerated()), id: \.offset) { _, file in
                FileDeliveryFileLine(delivery: delivery, file: file, service: service)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

/// One file of a call: the icon macOS gives its type, its name, and while it
/// is being fetched a spinner. A click opens it; a failure is said under it.
private struct FileDeliveryFileLine: View {
    let delivery: FileDelivery
    let file: String
    @ObservedObject var service: FileDeliveryService
    @Environment(\.fontScale) private var scale
    @State private var hovering = false

    private var key: String { FileDeliveryService.fileKey(delivery, file) }
    private var fileName: String { (file as NSString).lastPathComponent }

    /// The icon of the file's type, from the system: no list of types here.
    private var icon: NSImage {
        let type = UTType(filenameExtension: (file as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: { service.open(delivery, file: file) }) {
                HStack(spacing: 5) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14 * scale, height: 14 * scale)
                    Text(fileName)
                        .font(.custom("Fira Code", size: 10.5 * scale))
                        .foregroundColor(.accentColor)
                        .underline(hovering)
                        .lineLimit(1).truncationMode(.middle)
                    if service.opening.contains(key) {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(service.opening.contains(key))
            .onHover { hovering = $0 }
            .help(delivery.host == .iMac
                  ? "Copy it from the iMac and open it:\n\(file)"
                  : "Open it:\n\(file)")
            if let failure = service.failures[key] {
                Text(failure)
                    .font(.system(size: 10 * scale))
                    .foregroundColor(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19 * scale)
            }
        }
    }
}
