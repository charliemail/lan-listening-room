# 開發步驟與各階段驗證

來源需求：[requirements.md](requirements.md)（原始規劃 v1.0，2026-11-05）
狀態：草案，待確認「前置條件」與「待決策」後開始 Phase 0。

## 證據分級（所有回報一律使用）

| 標記 | 意義 |
|---|---|
| 🔨 已建置 | 指令實際跑過、成功，附指令 |
| ✅ 自動測試 | `swift test` / `xcodebuild test` 通過，附測試名稱 |
| 🎧 真機實測 | 真的在 N 台 Mac 上聽到 / 操作過，附機型、OS、App 版本、時長 |
| ⏳ 待驗證 | 寫好但缺硬體 / 權限 / 機器，不可算完成 |

mock、單機 loopback、`localhost` 自己連自己，一律只能算 🔨 或 ✅，不得標 🎧 雙機。

---

## 前置條件（2026-11-05 本機檢查結果）

| 項目 | 現況 | 影響 |
|---|---|---|
| macOS | 26.5.2 (25F84)，arm64 | OK |
| Swift | 6.3.3（Xcode 內建） | OK |
| Xcode | 26.6 (17F113)，macOS SDK 26.5，已 `xcode-select` 切換 | OK |
| 測試 Mac 數量 | 未知 | Phase 0 出口需 2 台、Phase 2 出口需 3 台 |
| 簽章 | 未知（Apple ID / Developer ID） | 本機開發簽章即可；正式公證列待辦 |


---

## 專案結構（最小）

```
lan-listening-room/
├── LANListen.xcodeproj         # Xcode 建立（macOS App, SwiftUI）
├── LANListen/                  # App target：Views、Audio、Networking 的平台相依碼
├── RoomCore/                   # 本機 Swift Package：純邏輯，CLT 可 `swift test`
│   ├── Sources/RoomCore/       #   Protocol 訊息、Codec(framing)、PresenterStateMachine、BoundedBuffer
│   └── Tests/RoomCoreTests/
├── docs/  requirements.md · development-plan.md · architecture.md · testing.md · compatibility.md
└── README.md
```

理由：高風險邏輯（主持權狀態機、封包解析、buffer 上限）放進不依賴 UI/權限的 package，沒 Xcode 也能跑測試；平台碼留在 App target，不拆過多套件。

---

## Phase 0：最高風險驗證與選型

目標：先證明「真實 App 音訊 → 另一台 Mac 耳機」可行，再決定傳輸。不做房間、不做正式 UI。

### 步驟
| # | 工作 | 產出 |
|---|---|---|
| 0.1 | 建立最小 macOS SwiftUI App + `RoomCore` package；確認 Deployment Target（暫定 14，依 SCK 音訊 API 實際可用版本調整） | 可建置專案、README 建置指令 |
| 0.2 | 設定 Info.plist / entitlements：`NSLocalNetworkUsageDescription`、`NSBonjourServices`(`_lanlisten._tcp`)、Sandbox network client+server；**不加**麥克風權限 | entitlements 檔、權限矩陣初稿 |
| 0.3 | `AudioCaptureService`：`SCShareableContent` 列出 App → `SCContentFilter` 指定 App → `capturesAudio=true`、`excludesCurrentProcessAudio=true`、48kHz 立體聲；`.audio` output 讀 `CMSampleBuffer` 實際格式 | 擷取 debug 畫面：來源格式、RMS/峰值電平 |
| 0.4 | 用本機測試音源（自產 1kHz 正弦 / 自有音檔）驗證「非靜音有效音訊」，再測 Safari/Chrome YouTube、Spotify 桌面版 | compatibility.md 來源矩陣 |
| 0.5 | WebRTC 限時實驗（建議上限 1～2 天）：找可固定版本的 macOS WebRTC 二進位，驗證「外部 PCM 注入 → 遠端輸出」、立體聲、可否關 AEC/AGC/NS、無外網 host candidate | 實驗紀錄：套件來源、版本/commit、授權、是否需 ObjC++ / 自編 |
| 0.6 | 若 0.5 需維護自訂 fork 或無法注入 → 改走 AAC 路線：`AVAudioConverter` PCM→AAC-LC（~160kbps）、`NWConnection` TLS 單播、手動 IP:Port、接收端 `AVAudioConverter` 解碼 + `AVAudioEngine` 有界播放緩衝 | `AudioTransport` 單一實作 |
| 0.7 | 寫 docs/architecture.md：選型決策、證據、代價（延遲、TCP 隊頭阻塞） | ADR |

### 自動測試（✅）
- `AudioFormatAdapter`：用合法 fixture（44.1k/48k、interleaved/non-interleaved、mono/stereo）轉成 48k stereo，frame 數與聲道正確。
- AAC 路線：encode→decode 往返後非靜音、frame 邊界與 magic cookie 存在。
- 指令：`cd RoomCore && swift test`、`xcodebuild test -scheme LANListen`

### 真機驗證（🎧）
| 檢查 | 方法 | 通過條件 |
|---|---|---|
| 收到「有效」音訊 | debug 顯示 RMS；播放時 > 靜音門檻、暫停時 ≈ 0 | 不以 callback 次數代替 |
| 只擷取指定 App | 同時開 Music 與 Safari，只選 Safari | 遠端只聽到 Safari |
| 不含麥克風 / 本 App | 對麥克風說話；本 App 發提示音 | 遠端都聽不到 |
| 立體聲 | 左右聲道測試音 | 遠端左右正確 |
| 雙機 10 分鐘 | A 分享、B 耳機聽 | 連續 10 分鐘無中斷，記 CPU / 記憶體 / 流量 |
| 停止即斷 | A 按停止 | B 1 秒內靜音，`nettop` 無持續流量 |
| 延遲 | 脈衝音 + 兩台錄影或同時錄音比對 | 記錄數值與方法，不當成保證 |

### 出口
- 🎧 兩台 Mac 真實聽到指定 App 音訊 ≥ 10 分鐘，停止後不再送音。
- Spotify / YouTube 受限時寫入 compatibility.md，用可行來源繼續。
- **全部真實音訊路線都失敗 → 停止，回報阻礙，不進 Phase 1。**

### Phase 0 結案狀態（2026-11-06，同日更正）
**更正**：雙機音訊在 Phase 0 已由使用者實測打通（🎧）：0.0.1 (3) 時 A 截圖「聽眾 1、ICE connected、opus 2 ch、170 kbps、分享已經過 6:17」，B（第二台 Mac）實際收聽並回報重連殘音、開頭破音兩個問題（已於 0.0.1 (3) 修正）。下方「延後」的記錄有誤，以本段為準。
未留下的證據：10 分鐘完整時長、B 端補幀／緩衝數字、兩台機型與網路環境——屬紀錄缺漏，不影響「WebRTC 可穿過真實區網」這個結論。

以下為更正前的原記錄：
- 使用者決定：**未完成雙機 10 分鐘即進入 Phase 1**。Phase 0 出口條件標為 ⏳ 延後，不視為通過。
- 已有證據：🎧 單機擷取（Chrome）、權限、系統音量不影響擷取；🔨 WebRTC loopback ×2、單機兩實例收聽／重連／輸出裝置切換。
- 為何可先進 Phase 1：Phase 1 是控制面（探索、配對、成員），不依賴音訊傳輸選型。
- **約束：進 Phase 2（把音訊接進房間）前必須補完雙機 10 分鐘**；若失敗需回頭重評 WebRTC / AAC，屆時 Phase 1 不受影響。
- 2026-11-06 使用者再次決定：**不先做雙機 10 分鐘，直接進 Phase 2**；併入 Phase 2 出口（3 台 30 分鐘）驗證。已告知風險：若屆時 WebRTC 在真實網路不可行，Phase 2 傳輸部分需重做。

### Phase 2 設計（2026-11-06）
- 信令走協調者控制連線（取代實驗用手動 IP／明文 TCP 信令）。
- 房間狀態新增 `stream`（streamID、播歌者、epoch）：只有播歌者能開始／停止；**播歌者一換人，stream 立即清空**，新播歌者需自己按開始。
- 協調者只轉送「目前 stream 的播歌者 → 成員的 offer」與「成員 → 播歌者的 answer」，其餘拒絕；SDP 上限 32 KiB。
- 播歌者對每位成員各一條 PeerConnection（慢聽眾只影響自己那條）；晚加入者由播歌者看到新成員後自動補 offer。
- 聽眾只接受 streamID 與發送者都符合目前 snapshot 的 offer；stream 清空或換 ID 立即關閉舊連線。
- 切換來源只重啟擷取，不換 stream（聽眾不斷線）。
- 輸出裝置變更（耳機拔除、預設裝置改變、選定裝置消失）→ 暫停本機播放並提示，按「繼續播放」恢復。

---

## Phase 1：房間與身分

### 步驟
| # | 工作 |
|---|---|
| 1.1 | `RoomCore` 協定：版本化 Codable 訊息（hello/join/snapshot/memberJoined/Left/heartbeat/leave/roomClosed/error…），4-byte 長度前綴 framing，上限 64 KiB，字串/成員數/頻率上限 |
| 1.2 | `CoordinatorServer`：`NWListener` + Bonjour `_lanlisten._tcp`（TXT 只放 protocolVersion、房名、建房者短 ID）；actor 序列化房間狀態；memberID 由伺服器發配並綁連線 |
| 1.3 | 房間驗證碼：App 隨機 6 位數、房主可更新；猜錯限速。房主踢人、房主轉移（邀請／接受／15 秒逾時）。~~PIN／指紋配對~~（2026-11-06 需求變更取消） |
| 1.4 | `RoomDiscovery`：`NWBrowser` 列房間；手動 IP:Port 備援 |
| 1.5 | UI：入口（暱稱 1～24 字、房名 1～40 字、區網權限狀態）、房間（成員、建房者/主持人標示、短 ID、「尚未分享」） |
| 1.6 | 心跳 3s / 逾時 12s（集中設定）；建房者離開 → roomClosed；異常 → 逾時判定 |

### 自動測試（✅）
- Codec：拆包、黏包、長度 > 64 KiB、長度為 0、未知 protocolVersion、壞 JSON、未完成 join 就送其他訊息 → 皆明確拒絕不 crash。
- 名稱驗證：前後空白、emoji 組合字（Character 計數）、byte 上限。
- 驗證碼：正確／錯誤、更新後舊碼失效且不影響現有成員、連錯限速。
- 房主權限：非房主踢人／更新驗證碼／轉移被拒；不能踢自己、不能踢建房者（含轉移後）；轉移接受、拒絕、逾時、目標已離開、重複接受。
- 心跳逾時：以注入時鐘測 12s 判定。

### 真機驗證（🎧 2 台）
| 情境 | 通過條件 |
|---|---|
| 探索 | B 看到 A 的房間，首次出現區網權限提示 |
| 同名 | 兩人都叫「小明」，短 ID 不同，各自離開互不影響 |
| 驗證碼 | 錯碼被拒、對碼可進；房主更新後舊碼進不來、已在房內的人不受影響；日誌無驗證碼 |
| 踢人 | 被踢者顯示已被移出；其他人成員清單即時更新 |
| 轉移房主 | 接受後新房主看到驗證碼與踢人按鈕、原房主看不到；拒絕／逾時維持原狀 |
| 建房者正常離開 | B 顯示「房間已結束」 |
| 建房者強制關 App / 拔網路 | B ≤ 12～15s 顯示結束 |
| 拒絕區網權限 | 顯示設定指引，不反覆彈窗 |
| 手動位址 | 關 Bonjour 時可用 IP:Port 加入 |

### 出口
🎧 兩台真機可發現／加入；同名不衝突；錯驗證碼被拒；踢人與轉移房主生效；協調者離開全員收到結束或逾時。

### 需求變更（2026-11-06，使用者決定）
原需求 §4.3「房間 PIN + TLS + 指紋核對」**取消**；新增「房主」角色，與「播歌者」（原需求的主持人）分開。

**三個角色（2026-11-06 定案）**
| 角色 | 初始 | 權限 | 換人方式 | 離開／被踢時 |
|---|---|---|---|---|
| 建房者 | 開房的人，固定 | 房間跑在他的 Mac；不可被踢 | 不可換 | 房間關閉 |
| 房主 | 建房者 | 更新驗證碼、踢人（不含自己與建房者）、轉移房主 | 房主邀請、對方接受 | 房主權回建房者 |
| 播歌者 | 建房者 | 唯一可分享音訊；交棒 | **播歌者自己邀請**、對方接受；房主不介入 | 播歌權回房主 |

兩種轉移各自獨立，各最多一個待回應邀請，15 秒逾時。

| 項目 | 規格 |
|---|---|
| 進房 | 區網內搜尋到的房間，輸入目前驗證碼即可加入；不做加密配對，控制連線為明文 TCP |
| 驗證碼 | 建房時 App 隨機產生 6 位數字，每間房都有；只有目前房主看得到；房主可隨時更新，舊碼立即失效，已在房內的人不受影響 |
| 房主權限 | 更新驗證碼、踢人、轉移房主（播歌權見上表，房主不管） |
| 不可被踢 | 房主自己、**建房者**（轉移後亦然；踢建房者等於關房、全員被迫離開） |
| 建房者離開 | 只能自己按離開，並先確認「離開後房間會關閉，所有人都會離開」 |
| 轉移房主 | 房主邀請成員 → 對方接受才轉移；拒絕或 15 秒逾時維持原狀 |
| 被踢 | 被踢者顯示「已被房主移出」；知道目前驗證碼仍可再進（無帳號，無法可靠封鎖），房主可踢人後更新驗證碼 |
| 建房者 | 房間跑在建房者的 Mac 上。轉移的是房主權限，房間不搬家；**建房者離開即房間結束**，即使他已不是房主（沿用原需求，不做協調者遷移） |

為何驗證碼直接送、不做挑戰-回應：6 位數只有 100 萬組，側錄到挑戰-回應後瞬間可離線試完，等於沒保護，只增加複雜度。實際防護靠：
- 猜錯限速：同一來源連錯 5 次鎖 30 秒（線上暴力猜要數月）。
- 房主可隨時更新驗證碼。

已告知並接受的風險：
| 風險 | 處理 |
|---|---|
| 驗證碼被同網段側錄 | 接受；房主可更新 |
| 暱稱／成員清單明文 | 敏感度低，接受 |
| 音樂內容 | WebRTC 預設 DTLS-SRTP 加密，不需額外處理 |
| 區網內主動攔截竄改（MITM） | 第一版接受；這是不做配對的代價 |

### 實作細節（2026-11-06）

**加入流程**
1. 加入者連到協調者 → 送 `join(protocolVersion, nickname, code)`。
2. 協調者檢查版本與驗證碼：錯碼回 `error(wrongCode)` 並關閉，計入限速；版本不符回 `error(unsupportedVersion)`。
3. 通過 → 發配 memberID（伺服器產生，綁這條連線）→ 新成員收 `snapshot`，其他人收 `memberJoined`。
4. 房主操作（`refreshCode`、`kick`、`transferOffer`）由協調者檢查「送出者是否為目前房主」，依序套用並遞增 `roomRevision`。

**模組**
| 位置 | 內容 | 驗證 |
|---|---|---|
| `Packages/RoomCore`（純 Swift） | 訊息定義、4-byte 長度 framing（上限 64 KiB）、名稱規則、房間狀態機（房主權限、驗證碼、踢人、轉移）、猜錯限速、心跳逾時（可注入時鐘） | `swift test` |
| `LANListen/Room/CoordinatorServer` | `NWListener` + Bonjour（TXT：版本、房名、建房者短 ID）、連線綁 memberID | 單機兩實例 + 雙機 |
| `LANListen/Room/RoomClient` | `NWConnection`、加入、心跳、房主操作 | 同上 |
| `LANListen/Room/RoomDiscovery` | `NWBrowser` 列房間 | 同上 |
| UI | 入口（暱稱、房間清單、建房、手動位址）、房間（成員、房主／建房者標示、短 ID、驗證碼與更新、踢人、轉移、離開） | 人工 |

Phase 1 只做轉移的「權限交接」；交接後的音訊切換（epoch、舊串流失效）在 Phase 3。
「雙機實驗」分頁暫時保留為除錯用，Phase 2 由正式房間取代；WebRTC 信令屆時改走協調者的控制連線。

---

## Phase 2：整合音訊

### 步驟
| # | 工作 |
|---|---|
| 2.1 | 控制訊息加 streamStarted/Stopped、StreamDescriptor（streamID、presenterEpoch、格式、媒體端點、短效 token） |
| 2.2 | 只有 presenter 能開始；coordinator 驗證後廣播；presenter 對每位聽眾開獨立連線（最多 9 路） |
| 2.3 | 慢聽眾隔離：每路獨立有界佇列，滿了丟最舊並記指標，必要時斷該聽眾；不得阻塞擷取 callback |
| 2.4 | 晚加入：snapshot 帶目前 stream → 直接接入 |
| 2.5 | 本機音量 / 靜音（`AVAudioMixerNode`），偏好存 UserDefaults |
| 2.6 | 輸出裝置變更 / 耳機拔除 → 暫停本機輸出並提示；來源 App 關閉 / 權限撤銷 → 可操作錯誤 |
| 2.7 | 停止 / 離開釋放 SCStream、連線、buffer、observer |

### 自動測試（✅）
- BoundedBuffer：上限不被突破、溢位策略、stream 切換清空。
- 慢客戶端：模擬一路不讀，其他路照常送、擷取端不阻塞。
- token 驗證：錯接收者 / 錯 streamID / 過期 → 拒絕。

### 真機驗證（🎧 ≥ 3 台）
| 情境 | 通過條件 |
|---|---|
| 1 主持 + 2 聽眾 30 分鐘 | 記錄中斷次數、CPU、記憶體、上傳量；記憶體不持續上升 |
| 一位聽眾拔網路 | 另一位不中斷 |
| 晚加入 / 靜音加入 | 正常收聽；靜音不影響他人 |
| 暫停歌曲 | 不被判斷線 |
| 停止分享 | 所有聽眾無殘音 |
| 拔耳機 / 切藍牙 | 不外放、不 crash |
| 關掉外網（路由器 WAN 拔線） | 區網仍可建房傳音 |

### 出口
🎧 3 台連續 30 分鐘；單一聽眾斷線不阻塞他人；停止後無殘留舊音。

---

## Phase 3：主持權與異常

### 收尾狀態（2026-11-06，0.2.0 (10)）
多數項目已隨 Phase 1／2 完成；本次補齊缺口。
| 需求 | 狀態 |
|---|---|
| 邀請／接受／拒絕／逾時、交接競態、重複命令冪等 | ✅ RoomCore 自動測試 |
| epoch／streamID 防舊串流（協調者＋聽眾兩層） | ✅ 自動測試；換播歌者即清空 stream |
| 來回交接 10 次只接受一位播歌者 | ✅ 自動測試 `tenHandoversNeverLeaveTwoPresenters`；手動 H1 ⏳ |
| 播歌者掉線收回、協調者失聯結束 | ✅ |
| **睡眠：協調者睡眠房間結束、成員睡眠離開，喚醒回列表** | ✅ 本次新增（`NSWorkspace.willSleepNotification`）；手動 H2、H3 ⏳ |
| 資源清理（擷取、連線、紫色錄製圖示） | ✅ 單機 Q7、Q8 |

### 步驟
| # | 工作 |
|---|---|
| 3.1 | `PresenterStateMachine`（RoomCore，純邏輯）：presenterID、presenterEpoch、roomRevision、pendingOffer(15s) |
| 3.2 | transferOffer / Accept / Reject / 逾時；Accept 時驗證 offer 仍對應目前 presenter+revision，原子提交、epoch+1、廣播、通知舊 presenter 停止 |
| 3.3 | 聽眾只接受符合 presenterID+epoch+streamID 的媒體；不符立即關閉清緩衝 |
| 3.4 | 新主持人需手動按「開始分享」；顯示「等待分享」 |
| 3.5 | 主持人掉線 → 主持權回 coordinator、停止分享；coordinator 掉線 → 房間結束 |
| 3.6 | requestID 冪等：重複命令回同結果 |

### 自動測試（✅，本階段重點）
- 非主持人發 offer → 拒。
- 同一 offer 重複 accept → 冪等。
- 兩個 offer 競態 / 同時 accept → 只有一位成功。
- 過期 offer（15s 後 / revision 已變）accept → 拒，原主持人不變。
- 目標離線 → offer 失效。
- 舊 epoch 的 streamStarted / 媒體 → 拒。
- 主持人斷線 → presenter 回 coordinator、epoch+1。

### 真機驗證（🎧 ≥ 2，建議 3）
| 情境 | 通過條件 |
|---|---|
| 來回交接 10 次 | 每次只有一位主持人的聲音 |
| 交接後新主持人未按開始 | 全員靜音、顯示等待分享 |
| 舊主持人不配合停止（測試開關強制繼續送） | 聽眾仍拒收 |
| 邀請逾時 / 拒絕 | 原主持人不變 |
| 主持人強制退出 | 主持權回建房者、靜音 |
| 建房者（非主持人）離開 | 房間結束 |
| 睡眠 / 喚醒 | 舊 session 停止，可重新加入，無第二個 coordinator |

### 出口
🎧 交接 10 次每次只接受一位主持人音訊；未按開始保持靜音；過期訊息不能恢復舊主持權。

---

## Phase 4：打包與驗收

### 狀態（2026-11-06，0.3.0 (11)）
| 項目 | 狀態 |
|---|---|
| 正式版／測試版分開（兩個 target、`DEV_TOOLS`、`LANListen/Dev/`） | ✅ 已驗證正式版二進位不含除錯畫面符號與字串 |
| Release 建置與打包 `zsh scripts/package.sh` | ✅ 先跑測試；兩個 zip 分開輸出；Release 移除 `get-task-allow` |
| README（使用說明、角色、限制、安全、排障、開發者建置） | ✅ |
| 圖示 | ✅ 2026-11-12 使用者提供設計稿（0.3.0 (14)）；黑底圓角外側以邊角區域填色轉透明，套 macOS 824/1024 版面；正式版與測試版共用 |
| Developer ID 簽署＋公證 | ⏳ 需付費帳號 |
| 多台 Mac 最終驗收 | ⏳ 見 testing.md「最終驗收」F1～F13 |

### 步驟
1. UI 整理（繁中預設）、圖示占位、權限說明文案（以實際系統彈窗文字為準）。
2. Release 建置：`xcodebuild -scheme LANListen -configuration Release build`。
3. 文件：README（最低 OS、Xcode 版本、建置、授權、建立／加入、PIN 配對、選音源、交接、排障）、testing.md、compatibility.md。
4. 簽章：區分開發簽章與 Developer ID + 公證；沒帳號就列 ⏳。
5. **正式版／測試版分開**（2026-11-06 使用者要求）：同一份原始碼、兩個 target，各自打包，不合併。
   | | 正式版 | 測試版 |
   |---|---|---|
   | App 名稱 | LAN Listen | LAN Listen Dev |
   | Bundle ID | `local.lanlisten.LANListen` | `local.lanlisten.LANListen.dev`（權限、偏好設定各自獨立） |
   | 內容 | 只有「房間」 | 加上「雙機實驗」「擷取測試」、診斷數字 |
   | 區分方式 | — | 編譯旗標 `DEV_TOOLS`，正式版不編進除錯畫面 |
   | 打包 | `release/LANListen-<版本>-<建置號>.zip` | `release/LANListen-Dev-<版本>-<建置號>.zip` |
   時機：功能完整後（Phase 4）；在那之前維持單一開發版。

### 驗收
| 項目 | 通過條件 |
|---|---|
| Release 建置 | 🔨 乾淨環境 clone 後依 README 一次建置成功 |
| 另一台 Mac 安裝 | 🎧 依 README 可開啟（Gatekeeper 處理步驟寫清楚） |
| 全量自動測試 | ✅ 全綠 |
| 真機清單（需求 §8.2） | 每列標 🎧 或 ⏳，附機器數 |
| 10 人負載 | 有幾台測幾台，未達 10 人明列 ⏳ |

---

## 待決策（開工前請確認）

1. ~~Xcode~~：已完成（26.6）。
2. **可用 Mac 數量 / 機型 / OS**：決定 Phase 0、2 出口何時能 🎧。
3. **傳輸選型**：建議 WebRTC 限時 1～2 天實驗，不通就走 AAC + TLS（理由：macOS 上 WebRTC 外部 PCM 注入通常需碰 ADM 或自編，維護成本高；AAC 路線全用 Apple 原生框架、零第三方依賴，代價是延遲較高）。也可直接跳過 WebRTC 實驗走 AAC。
4. **最低 macOS 版本**：暫定 14；依 ScreenCaptureKit 音訊相關 API 實際可用版本在 0.1 定案。
5. **專案名稱 / Bundle ID**：暫定 `LANListen`、`com.<你的前綴>.lanlisten`。
