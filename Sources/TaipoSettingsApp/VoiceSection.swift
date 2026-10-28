import CryptoKit
import Foundation
import SwiftUI
import TaipoIME

/// Spec 012 Behavior 6: the "語音輸入" switch (default off), model status and download.
@MainActor
final class VoiceModel: ObservableObject {
    @Published var enabled = VoiceSettings.isEnabled() {
        didSet { VoiceSettings.setEnabled(enabled) }
    }
    @Published var installed = VoiceSettings.isModelInstalled()
    @Published var progress: Double?
    @Published var message = ""

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var status: String {
        if let progress { return String(format: "下載中 %.0f%%", progress * 100) }
        return installed ? "Breeze-ASR-25 q5_0（已安裝）" : "未安裝"
    }

    /// Downloads to a temporary name, checks size and SHA-256, then moves it into place.
    func download() {
        guard task == nil else { return }
        progress = 0
        message = ""
        let task = URLSession.shared.downloadTask(with: VoiceSettings.modelDownloadURL) { location, response, error in
            // The temporary file is deleted when this handler returns, so verify and move it here.
            let result = Result { try Self.install(location: location, response: response, error: error) }
            Task { @MainActor in self.finish(result) }
        }
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in if self.task != nil { self.progress = fraction } }
        }
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Result<Void, Error>) {
        task = nil
        observation = nil
        progress = nil
        installed = VoiceSettings.isModelInstalled()
        switch result {
        case .success:
            message = "下載完成"
            VoiceSettings.setEnabled(enabled)  // tells the input method to load the model if the switch is on
        case let .failure(error):
            message = "下載失敗：\(error.localizedDescription)"
        }
    }

    struct DownloadError: LocalizedError {
        let errorDescription: String?
    }

    nonisolated static func install(location: URL?, response: URLResponse?, error: Error?) throws {
        if let error { throw error }
        guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError(errorDescription: "伺服器回應 \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
        guard size == VoiceSettings.modelBytes else {
            throw DownloadError(errorDescription: "檔案大小不符（\(size ?? 0) bytes）")
        }
        guard try sha256(location) == VoiceSettings.modelSHA256 else {
            throw DownloadError(errorDescription: "SHA-256 不符")
        }
        let dir = VoiceSettings.modelDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent(VoiceSettings.modelFileName + ".part")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: location, to: partial)
        if FileManager.default.fileExists(atPath: VoiceSettings.modelURL.path) {
            _ = try FileManager.default.replaceItemAt(VoiceSettings.modelURL, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: VoiceSettings.modelURL)
        }
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct VoiceSection: View {
    @StateObject private var model = VoiceModel()

    var body: some View {
        Section("語音輸入（完全在本機執行）") {
            Toggle("按住右 Shift 說話，放開後送出文字", isOn: $model.enabled)
            HStack {
                LabeledContent("模型", value: model.status)
                if model.progress != nil {
                    Button("取消") { model.cancel() }
                } else {
                    Button(model.installed ? "重新下載模型" : "下載模型") { model.download() }
                }
            }
            if let progress = model.progress { ProgressView(value: progress) }
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
            Text("模型約 1.1 GB，存到 ~/Library/Application Support/Taipo/models/。開關關閉或模型未安裝時，右 Shift 照常運作，輸入法也不載入模型。錄音只留在記憶體，不存檔。第一次使用時系統會詢問麥克風權限。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { model.installed = VoiceSettings.isModelInstalled() }
    }
}
