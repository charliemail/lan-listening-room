import ScreenCaptureKit
import SwiftUI

/// Phase 0 debug screen: proves real, non-silent audio arrives from one chosen app.
@MainActor @Observable
final class CaptureProbeModel {
    /// -60 dBFS. Below this the source counts as silent (paused), not broken.
    static let silenceRMS: Float = 0.001

    var apps: [SourceApp] = []
    var selectedBundleID: String?
    var isCapturing = false
    var levels = AudioLevels()
    var totalCallbacks = 0
    var audibleSeconds = 0.0
    var silentSeconds = 0.0
    var errorMessage: String?

    private let capture = AudioCaptureService()
    private var pollTask: Task<Void, Never>?

    init() {
        capture.onStop = { [weak self] error in
            Task { @MainActor in self?.handleStop(error) }
        }
    }

    func refreshApps() async {
        do {
            apps = try await AudioCaptureService.shareableApps()
            if selectedBundleID == nil || !apps.contains(where: { $0.bundleID == selectedBundleID }) {
                selectedBundleID = apps.first?.bundleID
            }
            errorMessage = nil
        } catch {
            errorMessage = AudioCaptureService.describe(error)
        }
    }

    func start() async {
        guard let bundleID = selectedBundleID, !isCapturing else { return }
        totalCallbacks = 0; audibleSeconds = 0; silentSeconds = 0
        do {
            try await capture.start(bundleID: bundleID)
            isCapturing = true
            errorMessage = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.poll()
                }
            }
        } catch {
            errorMessage = AudioCaptureService.describe(error)
        }
    }

    func stop() async {
        pollTask?.cancel()
        pollTask = nil
        await capture.stop()
        isCapturing = false
        levels = AudioLevels()
    }

    private func poll() {
        let next = capture.drainLevels()
        totalCallbacks += next.callbacks
        let seconds = Double(next.frames) / 48_000
        if next.rms.contains(where: { $0 > Self.silenceRMS }) {
            audibleSeconds += seconds
        } else {
            silentSeconds += seconds
        }
        levels = next
    }

    private func handleStop(_ error: Error) {
        pollTask?.cancel()
        pollTask = nil
        isCapturing = false
        errorMessage = "擷取已停止：" + AudioCaptureService.describe(error)
    }
}

struct CaptureProbeView: View {
    @Bindable var model: CaptureProbeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("音源擷取測試（Phase 0）").font(.title2.bold())
            Text("擷取範圍是整個 App，不是單一瀏覽器分頁；同一 App 其他分頁的聲音也會被收進來。")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Picker("來源 App", selection: $model.selectedBundleID) {
                    ForEach(model.apps) { Text($0.name).tag(Optional($0.bundleID)) }
                }
                .disabled(model.isCapturing)
                Button("重新整理") { Task { await model.refreshApps() } }
                    .disabled(model.isCapturing)
            }

            Button(model.isCapturing ? "停止擷取" : "開始擷取") {
                Task { model.isCapturing ? await model.stop() : await model.start() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedBundleID == nil)

            GroupBox("即時電平") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.levels.rms.enumerated()), id: \.offset) { index, rms in
                        LevelRow(label: index == 0 ? "L" : index == 1 ? "R" : "Ch\(index + 1)",
                                 rms: rms, peak: model.levels.peak[safe: index] ?? 0)
                    }
                    if model.levels.rms.isEmpty { Text("尚無音訊").foregroundStyle(.secondary) }
                    Divider()
                    Text("格式：\(model.levels.format)")
                    Text("callback 次數：\(model.totalCallbacks)")
                    Text(String(format: "有聲：%.1f 秒　靜音：%.1f 秒（門檻 -60 dBFS）", model.audibleSeconds, model.silentSeconds))
                }
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.refreshApps() }
    }
}

private struct LevelRow: View {
    let label: String
    let rms: Float
    let peak: Float

    var body: some View {
        HStack {
            Text(label).frame(width: 30, alignment: .leading)
            ProgressView(value: Double(max(0, (dB(rms) + 60) / 60)))
            Text(String(format: "%6.1f dB  峰值 %6.1f", dB(rms), dB(peak))).frame(width: 190, alignment: .trailing)
        }
    }

    private func dB(_ v: Float) -> Float { v > 0 ? max(-99, 20 * log10(v)) : -99 }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
