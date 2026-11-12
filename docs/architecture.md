# 架構與選型紀錄

## ADR-001 音訊傳輸：WebRTC vs AAC+TLS

狀態：**WebRTC 暫定採用，待雙機驗證**（2026-11-05）。限時 1～2 天，結果決定 `AudioTransport` 唯一實作。

### 候選套件
| 項目 | 值 |
|---|---|
| 來源 | https://github.com/stasel/WebRTC （預編 xcframework，SPM binaryTarget） |
| 版本 | 156.0.0（WebRTC M156），`exact` 鎖定 |
| checksum | `43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46`（下載後 `shasum -a 256` 實測一致） |
| 授權 | BSD-3（WebRTC project） |
| 架構 | macos-x86_64_arm64 universal |
| 大小 | zip 46 MB |

### 靜態檢查證據（🔨，未執行）
1. **外部 PCM 注入介面**：macOS slice 的 headers **沒有** `RTCAudioDevice.h`（iOS slice 有），但 macOS 二進位內含 `ObjCAudioDeviceModule` 與 `initWithEncoderFactory:decoderFactory:audioDevice:`（`strings` 確認）。
   → 做法：從 iOS slice 複製同版本 `RTCAudioDevice.h`（BSD，保留版權）到 shim target，以 ObjC 建立 factory。**屬非官方支援的 macOS 用法**，升版需重驗。
2. **立體聲**：上游 `sdk/objc/native/src/objc_audio_device.mm` 中 `StereoRecordingIsAvailable` / `StereoPlayoutIsAvailable` 固定回 `false`；`SetStereo*` 回 `-1`。
3. **直接傳 buffer 的 bug**：`OnDeliverRecordedData` 在 `io_data != nullptr` 路徑以 `num_frames` 當 sample 數，立體聲交錯資料只送一半。→ 一律走 `renderBlock` 路徑（以 `frames × channels` 配置）。
4. **語音處理**：macOS headers 無 `RTCAudioProcessingModule`，只能用 `goog*` constraints 要求關閉 AEC/AGC/NS/HPF，是否生效需實測。
5. **ObjC++ / 自編**：不需要，ObjC shim 一個 `.m` 即可。

### 實驗：`Experiments/WebRTCProbe`
同機兩個 PeerConnection（僅 host candidates，無 STUN/TURN）。送端只在**左聲道**送 440 Hz（rms≈0.354），收端量左右聲道。

| 判斷 | 通過條件 |
|---|---|
| PCM 注入可行 | 收端 L rms > 0.05 |
| 立體聲保留 | R/L < 0.1（≈1 代表被降混成單聲道） |
| 語音處理已關 | 穩態 L 電平漂移 < 3 dB |

結果（2026-11-05，使用者本機執行 `webrtc-loopback 12`，macOS 26.5.2 arm64）：🔨 **單機 loopback 三項通過**

| 判斷 | 實測 |
|---|---|
| PCM 注入 | 收端 L rms 0.3536（送 0.354），PASS |
| 立體聲 | R 0.0000，R/L = 0.000，PASS（未被降混；L/R 未對調） |
| 語音處理 | 穩態漂移 0.01 dB，PASS（NS 會壓穩態音，此處未發生 → `goog*` constraints 有效） |
| Opus 協商 | 雙方 `channels=2`、`stereo=1;sprop-stereo=1;maxaveragebitrate=160000` |
| 碼率 | 241,802 bytes / ≈12 s ≈ **161 kbps**，627 封包（20 ms/包），遺失 0 |
| 補幀 | concealedSamples 1,962 / 577,440（0.34%，集中於啟動暖機） |

重跑（同日第 2 次）：三項再次通過（avg L 0.3527、R/L 0.000、漂移 -0.00 dB），625 封包、遺失 0。差異：t=8s L 降至 0.3440，concealedSamples 4,142（0.72%，比第 1 次多約 2,180 samples ≈ 45 ms）。封包零遺失，推測是測試程式以 `Thread.sleep` 自行計時造成送端時序抖動、收端 jitter buffer 補幀，而非網路問題；正式擷取由 SCK 時脈驅動。雙機實驗需持續追蹤 concealedSamples。

限制：同機兩個 PeerConnection，**不是雙機實測**；測試音是正弦波，不是音樂。

**暫定結論：WebRTC 路線續行**，下一步做「SCK 擷取 → WebRTC → 另一台 Mac」雙機實驗，通過才正式定案。

### 決策規則
- 三項全過 → WebRTC 進入雙機實驗。
- 注入可行但立體聲失敗 → 評估：接受單聲道 or 改 AAC。需使用者決定（需求 §3.4 目標為立體聲）。
- 注入不可行或需維護自編 fork → 改 AAC-LC + TLS（需求 §3.3 替代方案）。

## 擷取

ScreenCaptureKit，`SCContentFilter(display:including:[app])`，`capturesAudio`、48 kHz、2 ch、`excludesCurrentProcessAudio`。不掛 `.screen` output，不處理畫面。
備註：macOS 14.4+ 另有 Core Audio process tap 可擷取單一程序音訊；需求指定 SCK，若 SCK 權限體驗不佳再評估。
