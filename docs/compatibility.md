# 相容性與實測矩陣

標記：🔨 已建置｜✅ 自動測試｜🎧 真機實測｜⏳ 待驗證

## 測試環境
| 機器 | 晶片 | macOS | 用途 |
|---|---|---|---|
| Mac A（開發機） | Apple Silicon (arm64) | 26.5.2 (25F84) | 擷取、WebRTC loopback |

## 音源擷取（ScreenCaptureKit，單機）

| 來源 | 版本 | 結果 | 證據 |
|---|---|---|---|
| Google Chrome — YouTube | ⏳ 版本未記 | 🎧 **可擷取** | 2026-11-05 截圖：播放 L -18.6 dB / R -16.6 dB，峰值 -7.9 dB；暫停 L/R -99 dB |
| Safari — YouTube | — | ⏳ | |
| Spotify 桌面版 | — | ⏳ | |
| 本機測試音源 | — | ⏳ | |

Chrome 實測細節：
- 實際格式：**48000 Hz · 2 ch · Float32 · non-interleaved**（SCK 依設定輸出）。
- 立體聲：L/R 電平不同（相差 2 dB），是真立體聲內容，不是複製的單聲道。
- callback ≠ 有聲：暫停時 callback 持續增加（2,140 → 2,861），電平 -99 dB、計入「靜音」秒數 → 證明不能用 callback 判斷有無音訊，也不能因靜音判斷斷線。
- 節奏：2,861 次 / 57.2 秒 ≈ 50 次/秒，約 960 frames/callback。

## 權限實測（2026-11-05）
- 系統彈窗原文：「『LANListen.app』想要錄製此電腦的螢幕內容和音訊。在『系統設定』的『隱私權與安全性』設定中授權此應用程式。」按鈕：打開「系統設定」／拒絕。
- 設定位置：系統設定 → 隱私權與安全性 → **螢幕與系統錄音**（上半「螢幕與系統錄音」清單）。
- **ad-hoc 簽章每次重新建置都會失去授權**：設定裡開關仍顯示開啟，但新 build 簽章不同被視為另一個 App，持續要求授權；執行中的舊程序在 bundle 被覆蓋後擷取也會被系統停止（「找不到任何要擷取的顯示器或視窗」，約 9 分鐘處）。解法：改用自簽程式碼簽署憑證 `LANListen Dev`，designated requirement 變為 `identifier "local.lanlisten.LANListen" and certificate leaf = H"785b62fd…b264"`，與程式內容無關。重建後授權保留：🎧 **已實測**（2026-11-05：授權 0.0.1 (1) 後改建置號重建為 0.0.1 (2)，cdhash `9aff4d48…` → `6170fe60…`，重開後無彈窗、可直接擷取 Chrome）。
- 修正：原本每次載入來源清單都會再彈窗；改為先 `CGPreflightScreenCaptureAccess`，每次啟動最多 `CGRequestScreenCaptureAccess` 一次，之後只顯示設定指引。

## 待驗證清單
| 項目 | 狀態 |
|---|---|
| 只擷取指定 App（同時開「音樂」） | ⏳ |
| 不含麥克風 / 本 App 聲音 | ⏳ |
| Spotify | ⏳ |
| 權限拒絕 / 撤銷後的錯誤提示 | ⏳ |
| 雙機 10 分鐘收聽 | ⏳ 需第二台 Mac |

## 傳輸（WebRTC M156）
| 測試 | 結果 |
|---|---|
| 單機 loopback × 2 次 | 🔨 PCM 注入、立體聲、無語音處理皆通過，詳見 [architecture.md](architecture.md) |
| 雙機 | 🎧 Phase 0 實驗分頁（0.0.1 (3)）打通：ICE connected、opus 2 ch、約 170 kbps、至少 6 分鐘；未記錄 B 端補幀與機型 |
