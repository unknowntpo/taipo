import SwiftUI
import TaipoCore
import TaipoIME

/// Spec 007: live view of how the IME picks candidates, fed by `InspectorFeed`.
@MainActor
final class InspectorModel: ObservableObject {
    @Published var enabled = InspectorFeed.isEnabled() {
        didSet {
            InspectorFeed.setEnabled(enabled)
            if !enabled { current = nil; timeline = [] }
        }
    }
    @Published var current: InspectorEvent?
    @Published var lastDecision: InspectorEvent?
    @Published var timeline: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let time = Date()
        let event: InspectorEvent
    }

    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(forName: InspectorFeed.name, object: nil, queue: .main) { [weak self] note in
            guard let event = InspectorEvent(userInfo: note.userInfo) else { return }
            MainActor.assumeIsolated { self?.receive(event) }
        }
    }

    private func receive(_ event: InspectorEvent) {
        guard enabled else { return }
        switch event.kind {
        case .decode, .deepen: current = event
        case .decision: lastDecision = event; current = event
        case .commit, .voice: break
        }
        timeline.insert(Entry(event: event), at: 0)
        if timeline.count > 60 { timeline.removeLast() }
    }
}

struct InspectorView: View {
    @ObservedObject var model: InspectorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("即時檢視（打的字會即時傳給這個 App，只在本機；除錯完請關閉）", isOn: $model.enabled)
            if !model.enabled {
                ContentUnavailableView("即時檢視已關閉", systemImage: "eye.slash",
                                       description: Text("打開後，切到 Taipo 輸入法在任何 App 打字，這裡會即時顯示它怎麼挑字。"))
            } else if let event = model.current {
                KeycapRow(keys: event.keys)
                CandidateBars(event: event)
                Timeline(entries: model.timeline)
            } else {
                ContentUnavailableView("等待輸入", systemImage: "keyboard",
                                       description: Text("切到 Taipo 輸入法，在任何 App 開始打字。"))
            }
        }
        .padding()
    }
}

/// The typed keys as Dachen keycaps: the key, and the Zhuyin symbol printed on it.
struct KeycapRow: View {
    let keys: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    VStack(spacing: 0) {
                        Text(Layout.zhuyinSymbol(for: key) ?? " ").font(.system(size: 15, weight: .semibold))
                        Text(key == " " ? "␣" : String(key)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .frame(width: 30, height: 38)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary))
                }
            }
        }
        .frame(height: 42)
    }
}

/// Candidates with engine score bars (blue) and, after a decision, language-model bars (green).
struct CandidateBars: View {
    let event: InspectorEvent

    var body: some View {
        let scored = event.rows.compactMap(\.score)
        let lms = event.rows.compactMap(\.lm)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(String(format: "%.1f ms", event.millis)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let note = event.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(event.rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .center, spacing: 10) {
                    Text(index == event.chosen ? "▶" : "\(index + 1)").frame(width: 18).foregroundStyle(index == event.chosen ? .green : .secondary)
                    Text(row.text).font(.body.weight(index == event.chosen ? .bold : .regular)).frame(width: 150, alignment: .leading).lineLimit(1)
                    VStack(alignment: .leading, spacing: 2) {
                        Bar(value: row.score, range: scored, color: .blue, label: row.score.map { String(format: "引擎 %.1f", $0) } ?? "原文")
                        if !lms.isEmpty { Bar(value: row.lm, range: lms, color: .green, label: row.lm.map { String(format: "LM %.1f", $0) } ?? "—") }
                    }
                    .frame(width: 220)
                    Text(detail(row)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }

    private var title: String {
        switch event.kind {
        case .decode: "每鍵解碼"
        case .deepen: "停頓後深度搜尋"
        case .decision: "Decision model（Clef-mini）"
        case .commit: "送出"
        case .voice: "語音輸入"
        }
    }

    private func detail(_ row: InspectorEvent.Row) -> String {
        var parts = [row.source]
        if !row.edits.isEmpty { parts.append("修正：" + row.edits.joined(separator: "、")) }
        if row.segments.count > 1 { parts.append("切法：" + row.segments.joined(separator: " | ")) }
        return parts.joined(separator: "　")
    }
}

/// A bar whose length is the score's position between the lowest and highest score shown.
struct Bar: View {
    let value: Double?
    let range: [Double]
    let color: Color
    let label: String

    var body: some View {
        GeometryReader { geo in
            let fraction: Double = {
                guard let value, let lo = range.min(), let hi = range.max() else { return 0 }
                return hi == lo ? 1 : 0.08 + 0.92 * (value - lo) / (hi - lo)
            }()
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12))
                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7)).frame(width: geo.size.width * fraction)
                Text(label).font(.system(size: 10).monospacedDigit()).padding(.leading, 4)
            }
        }
        .frame(height: 14)
    }
}

struct Timeline: View {
    let entries: [InspectorModel.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("時間軸").font(.headline)
            List(entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.time, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(label(entry.event.kind)).font(.caption.bold()).frame(width: 64, alignment: .leading)
                    Text(entry.event.keys.replacingOccurrences(of: " ", with: "␣")).font(.caption.monospaced()).lineLimit(1).frame(width: 150, alignment: .leading)
                    Text([.commit, .voice].contains(entry.event.kind) ? (entry.event.note ?? "") : (entry.event.rows.first?.text ?? "")).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f ms", entry.event.millis)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if let note = entry.event.note, ![.commit, .voice].contains(entry.event.kind) { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func label(_ kind: InspectorEvent.Kind) -> String {
        switch kind {
        case .decode: "解碼"
        case .deepen: "深度搜尋"
        case .decision: "模型"
        case .commit: "送出"
        case .voice: "語音"
        }
    }
}
