import SwiftUI
import TaipoCore
import TaipoDecision
import TaipoIME

/// "Taipo" (~/Applications): the desktop switch for the on-device decision model (Spec 004 D6).
@main
struct TaipoSettingsApp: App {
    /// Owned by the app so the live inspector receives events even before its tab is opened.
    @StateObject private var inspector = InspectorModel()

    var body: some Scene {
        WindowGroup("Taipo") {
            TabView {
                SettingsView().tabItem { Label("設定", systemImage: "gearshape") }
                InspectorView(model: inspector).tabItem { Label("即時檢視", systemImage: "waveform.path.ecg") }
            }
            .frame(minWidth: 760, minHeight: 600)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var enabled = DecisionSettings.isEnabled() {
        didSet { DecisionSettings.setEnabled(enabled) }
    }
    @Published var learning = LearningSettings.isEnabled() {
        didSet { LearningSettings.setEnabled(learning) }
    }
    @Published var learnedCount = UserDictionaryStore.entryCount()
    @Published var clearMessage = ""
    @Published var status = "尚未載入"
    @Published var keys = "5k4ek7is"
    @Published var rows: [Row] = []
    @Published var verdict = ""

    struct Row: Identifiable {
        let id: Int
        let text: String
        let engine: Double
        let lm: Double?
        let chosen: Bool
    }

    private var decoder: Decoder?
    private var clef: ClefMini?

    var modelInstalled: Bool {
        FileManager.default.fileExists(atPath: ClefMini.defaultDirectory.appendingPathComponent("config.json").path)
    }

    /// Spec 010: move user.json to the Trash and tell the input method to forget it.
    func clearLearning() {
        do {
            try UserDictionaryStore.clear()
            clearMessage = "已清除（檔案已移到垃圾桶）"
        } catch {
            clearMessage = "清除失敗：\(error.localizedDescription)"
        }
        learnedCount = UserDictionaryStore.entryCount()
    }

    func loadModel() async {
        guard clef == nil else { return }
        status = "載入中…"
        let start = Date()
        do {
            clef = try await ClefMini.load()
            status = String(format: "已載入（%.1f 秒）", Date().timeIntervalSince(start))
        } catch {
            status = "無法載入：\(error)"
        }
    }

    func run() async {
        do {
            if decoder == nil {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("taipo-settings-playground.json")
                decoder = try Decoder(lexicon: Lexicon.bundled(), userDictionaryURL: dir)
            }
            let candidates = Array(decoder!.candidates(for: keys, previousLanguage: nil).prefix(DecisionPolicy.maxCandidates))
            let ambiguous = DecisionPolicy.isAmbiguous(candidates)
            var lm: [Double]? = nil
            var choice: Int? = nil
            let start = Date()
            if let clef, ambiguous {
                lm = try await clef.languageScores(context: "", texts: candidates.map(\.text))
                choice = try await clef.choose(context: "", keys: keys, candidates: candidates)
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            rows = candidates.enumerated().map { i, c in
                Row(id: i, text: c.text, engine: c.score, lm: lm?[i], chosen: i == (choice ?? 0))
            }
            verdict = !ambiguous ? "引擎很確定，不會詢問模型"
                : clef == nil ? "有歧義；載入模型後才會詢問"
                : "模型選：\(candidates[choice ?? 0].text)（\(ms) ms）"
        } catch {
            verdict = "錯誤：\(error)"
        }
    }
}

struct SettingsView: View {
    @StateObject private var model = SettingsModel()
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Decision model（完全在本機執行）") {
                Toggle("引擎不確定時，用 Clef-mini 重新挑第一名", isOn: $model.enabled)
                LabeledContent("模型", value: model.modelInstalled ? "Qwen3-0.6B（已安裝）" : "未安裝")
                LabeledContent("狀態", value: model.status)
                Text("切換立即生效，不需重新啟動輸入法。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("學習") {
                Toggle("記住我的選擇", isOn: $model.learning)
                Text("開啟時，選了不是第一名的字，下次同樣的按鍵會優先排它，並存到 ~/Library/Application Support/Taipo/user.json。關閉後完全不記錄、不寫檔。切換立即生效。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    LabeledContent("目前紀錄", value: "\(model.learnedCount) 筆")
                    Button("清除學習紀錄…", role: .destructive) { confirmingClear = true }
                        .disabled(model.learnedCount == 0)
                }
                if !model.clearMessage.isEmpty {
                    Text(model.clearMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            VoiceSection()
            Section("試打") {
                HStack {
                    TextField("大千注音或英文按鍵", text: $model.keys)
                        .font(.body.monospaced())
                        .onSubmit { Task { await model.run() } }
                    Button("載入模型") { Task { await model.loadModel(); await model.run() } }
                        .disabled(!model.modelInstalled)
                    Button("解碼") { Task { await model.run() } }
                        .keyboardShortcut(.defaultAction)
                }
                Table(model.rows) {
                    TableColumn("候選") { row in Text(row.chosen ? "▶ \(row.text)" : row.text).bold(row.chosen) }
                    TableColumn("引擎分數") { row in Text(String(format: "%.1f", row.engine)) }
                    TableColumn("LM 分數") { row in Text(row.lm.map { String(format: "%.1f", $0) } ?? "—") }
                }
                .frame(minHeight: 160)
                Text(model.verdict).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("清除 \(model.learnedCount) 筆學習紀錄？", isPresented: $confirmingClear) {
            Button("清除", role: .destructive) { model.clearLearning() }
        } message: {
            Text("user.json 會移到垃圾桶，需要時可以從垃圾桶復原。輸入法立即回到沒學過的排序。")
        }
        .onAppear { model.learnedCount = UserDictionaryStore.entryCount() }
        .formStyle(.grouped)
        .padding()
        .task { await model.run() }
    }
}
