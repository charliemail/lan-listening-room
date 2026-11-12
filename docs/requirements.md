# Mac 區網音樂房間：Claude 實作規劃

版本：1.0｜日期：2026-11-05

## 0. 給 Claude 的執行指示

請依此文件在使用者的 Mac 專案中實作原生 macOS App。先讀取專案既有 AGENTS.md／CLAUDE.md 與程式碼，再執行。若為空目錄，建立最小可建置專案。不要先建立完整介面才驗證音訊。

- 按 Phase 0 → 4 執行。每階段完成可驗證結果後，持續進行下一階段，不需為例行可逆操作反覆詢問。
- 保持範圍：不加入聊天、麥克風通話、播放清單、帳號、雲端服務或跨平台支援。
- 外部 API、SDK、套件版本與權限設定以實作當日官方文件和本機 SDK 為準；不要猜測不存在的 Swift API。
- 遇到硬體、擷取權限或雙機條件不足，完成可獨立驗證的部分，留下明確操作步驟與待驗證清單，不得把 mock 或單機測試標示為雙機成功。
- 音源或依賴遭遇實質阻礙時，先做有限度實驗、記錄證據與替代方案；不要無限更換框架、擅自改成麥克風收音或繞過受保護內容。
- 每階段記錄：已完成、建置／測試命令、實測證據、限制與下一步。功能修改同步更新 README。

## 1. 產品目標與已定案需求

在同一區網，安裝相同 App 的 Mac 使用者能發現房間、輸入名字並加入。房間同一時間僅有一位主持人；主持人分享自己 Mac 上 YouTube／Spotify 等應用程式的播放聲音，其他成員戴耳機收聽。主持權可以交給其他成員。

| 項目 | MVP 定義 |
|---|---|
| 平台 | 原生 macOS，優先 Apple Silicon；最低版本暫定 macOS 14，Phase 0 按 API 與測試機確認 |
| 人數 | 每房最多 10 人，包含主持人；須實測，不能視為已達效能保證 |
| 網路 | 可互通的區網；不需要雲端或外部 STUN／TURN |
| 名稱 | 建立／加入前必填暱稱；建房另填房名 |
| 音源 | 指定應用程式的輸出聲音，優先驗證瀏覽器 YouTube 和 Spotify 桌面版 |
| 聽眾 | 不需登入音樂服務；直接接收主持人分享的音訊 |
| 音量 | 每位聽眾可調整本機音量／靜音，不影響其他人 |
| 主持權 | 主持人邀請指定成員；對方接受後交接 |
| 建房者離開 | 房間結束；正常離開顯示提示，異常中斷由逾時判定 |
| 儲存 | 不錄音、不保存音訊；只保留必要本機偏好 |

「主持權移交」是改由新主持人分享自己的音源，不包含移交 YouTube／Spotify 登入狀態、曲目、播放進度或遠端操控來源播放器。

## 2. 第一版體驗與邊界

### 2.1 畫面

1. 入口：暱稱、區網權限狀態、房間清單、建立／加入；探索失敗時可手動輸入位址與連接埠（仍須網路可達）。
2. 房間：房名、成員清單、建房者／主持人標示、分享狀態、本機音量、離開。
3. 主持人控制：選擇來源 App、開始／停止分享、交接邀請與結果。

以繁體中文介面為預設。暱稱去除前後空白後 1～24 個字元，房名 1～40 字元；統一用 Swift Character 計數，另限制協定欄位位元組長度。允許同名，畫面用短 ID 輔助識別；不可把名字當權限 ID。

### 2.2 限制須直接呈現

- 擷取範圍為應用程式，不保證是單一瀏覽器分頁；提示可能混入該 App 其他分頁聲音。
- 主持人聽來源 App 的原始播放，不額外播放自己的回傳串流，避免雙重聲音。
- 允許主持人與聽眾有延遲；不承諾所有裝置同步播放。此版本以各自戴耳機為情境。
- 切換主持人或音源可有短暫靜音；新主持人未開始分享時顯示「等待分享」。
- 暫停歌曲時沒有聲音是正常狀態，不得只因沒有音訊樣本就判定成員掉線。
- 公司 Wi-Fi 的裝置隔離、跨 VLAN 或防火牆可能阻擋探索／連線；手動位址無法繞過網路隔離。

## 3. 建議架構與技術決策

### 3.1 原生優先

- Swift + SwiftUI；UI 狀態 MainActor，房間狀態用 actor 或單一序列執行模型管理。
- Bonjour + Network.framework（NWBrowser／NWListener）負責探索與本機控制連線。
- ScreenCaptureKit 負責來源擷取；AVAudioEngine／AVAudioConverter 等處理播放與格式轉換，依最終傳輸方案調整。
- 不另開 Node.js、Electron、Docker 或常駐背景服務。

### 3.2 控制與音訊分離

建房者同時是 coordinator（協調者），管理房間快照、成員及主持權。presenter（主持人）可為任一成員，與 coordinator 是不同角色。

- 控制：每位成員連 coordinator；使用具框架長度與大小限制的可靠連線、版本化訊息及加密配對。
- 媒體：presenter 直接向各聽眾單播；不經 coordinator 中繼。coordinator 只協調連線資訊與授權。
- 建房者即使已移交主持權，仍須保持在線；此版本不做 coordinator 遷移。
- 主持人不接收自己的音訊。10 人房內最多 9 路外送，需量測 CPU、上傳量與慢速接收端影響。

### 3.3 傳輸選型：Phase 0 必須定案

優先評估原生 WebRTC 音訊，但不要把它視為可直接接入 ScreenCaptureKit 的現成 Swift API。主要風險是外部 PCM 注入、音訊裝置模組（ADM）、macOS 二進位依賴與維護成本。

必須用可建置的極小實驗驗證：擷取 PCM → 外部音訊輸入 → 遠端輸出。記錄套件來源、固定版本／commit、授權、架構、最低 OS、是否需 ObjC++／自訂編譯。WebRTC 使用區網 host candidates，signaling 走 coordinator，不配置公共 STUN／TURN，測試無外網仍能建立媒體連線。

若 WebRTC 在有限實驗後需要維護大型自訂 fork，選擇替代方案：AVAudioConverter AAC-LC 編碼＋每位聽眾獨立 TLS 可靠連線＋有界播放緩衝。這是接受較高延遲的區網 MVP 折衷，須處理 TCP 隊頭阻塞、慢客戶端和 codec 初始化資料，不把它描述為低延遲保證。

不要同時實作兩套正式傳輸。用 AudioTransport 介面隔離所選實作；在 docs/architecture.md 記錄選型證據及代價。自訂 UDP、封包重傳與自行設計密碼學不在第一版範圍。

### 3.4 音樂品質

- 目標：48 kHz、立體聲；實際來源格式必須讀取並轉換，不可假定每個 buffer 都是固定格式。
- 壓縮碼率初始目標約 128～192 kbps，依選定 codec 能力確認，不承諾無損。
- WebRTC 路線需驗證立體聲及關閉／避開語音用降噪、AGC、AEC 對音樂的損害，不能假設設定一定暴露於 Swift SDK。
- 處理 CMSampleBuffer／AudioBufferList 的交錯方式、channel layout、時間戳、生命週期、重採樣與部分 frame。
- 音訊 callback 不做網路阻塞、同步檔案 I/O 或大量配置；使用有界佇列。
- AAC 路線須定義 format description／magic cookie 等解碼初始化、frame 邊界、時間戳與格式改變後的重建；不可直接把任意 buffer bytes 當可獨立解碼的音樂。

## 4. 協定、權限與失敗行為

### 4.1 識別與控制訊息

至少定義 protocolVersion、roomID、memberID、connectionID、requestID、roomRevision。memberID 由協調者綁定已建立連線；不採信客戶端自行聲稱的身分。控制訊息包含 hello、join、snapshot、memberJoined／Left、transferOffer／Accept／Reject、presenterChanged、streamStarted／Stopped、heartbeat、leave、roomClosed、error。

Bonjour 使用自訂服務類型（例如 _lanlisten._tcp），TXT 只放必要公開中繼資料及版本；不放 PIN、token 或私密名稱清單。控制封包使用明確 framing，限制最大長度（初始 64 KiB）、字串長度、成員數與頻率；未知版本清楚拒絕。

### 4.2 唯一主持人與交接

- coordinator 是唯一狀態寫入者，序列化主持權變更；房間內任何時刻恰有一個 presenterID（允許此人尚未分享）。
- 邀請只有現任主持人可發起；目標須在線且接受，邀請約 15 秒逾時，逾時保持原主持人。
- 接受時先驗證邀請仍對應目前主持人／revision；原子提交新 presenterID 並增加 presenterEpoch，再廣播結果及停止舊串流。
- 聽眾只接受符合當前 presenterID、presenterEpoch、streamID 的媒體 session。失效 session 立即關閉並清空緩衝，不能只仰賴舊主持人配合停止。
- 交接只移交資格；新主持人明確按開始分享後才擷取，不自動錄取聲音。
- 主持人離線：coordinator 將主持權收回自己並停止分享；若 coordinator 也離線則房間結束。不自動選到其他成員開始擷取。

### 4.3 配對與安全基線

區網不是可信邊界。MVP 採房間 PIN（建房時產生，透過當面／其他管道告知）與標準 TLS／WebRTC DTLS-SRTP；不手寫加密。

- 首次 TLS 配對需明確顯示並核對 coordinator 憑證指紋或等價短驗證碼，再在加密連線內送 PIN；不可用「接受任意憑證」的驗證 callback 當正式信任方案。首次核對完成後可 pin 該房間憑證。
- coordinator 對 PIN 嘗試限速；不把 PIN 寫入日誌、Bonjour 或明文網路。
- 媒體端點／WebRTC fingerprint 必須經已驗證控制連線分發、綁定成員及 epoch。自訂 TLS 媒體連線使用短效授權 token，驗證接收者、streamID 和有效期。
- 只開啟必要區網 listener，不做路由器埠映射或外網轉送；測試紀錄實際網路行為。

### 4.4 生命週期

心跳預設每 3 秒、約 12 秒未回應標記斷線，值集中配置。協調者斷線／睡眠後房間結束，成員停止播放；喚醒後回房間列表重新建立／加入，不暗中建立第二個協調者。一般成員短線先清理舊 session，提供重新加入；MVP 不承諾無縫續接。

來源 App 關閉、擷取權限撤銷、輸出裝置切換時顯示可操作錯誤；耳機拔除時優先暫停本機輸出並提示，避免意外改用喇叭。離開或停止分享必須釋放 capture、媒體、buffer 和 observer。

## 5. macOS 權限與發佈

Phase 0 依最低 macOS 和 SDK 確認：區網使用描述、NSBonjourServices、擷取授權流程與 Sandbox 的 client／server 網路能力。不複製不適用 macOS 的 iOS multicast entitlement；不要求麥克風權限，因為本產品不收麥克風。

只建立需要的音訊輸出處理，不傳送／保存畫面。若框架內部需內容篩選或 display 參照，依官方支援方式處理，說明實際系統授權文案，不承諾「永遠不需螢幕錄製權限」。授權拒絕後不反覆彈窗，提供設定指引。

第一版先採本機建置／直接分發測試，非 App Store 上架專案。README 分清開發測試簽章與正式 Developer ID 簽署／公證；缺帳號時列為待完成，不宣稱已簽署或通過公證。優先維持標準 Sandbox，只有具體相容性證據才變更並記錄。

YouTube／Spotify 是相容性測試對象，不是保證清單。受保護內容不可擷取時顯示限制，不實作繞過。公開分發或商用前另確認來源服務條款與分享用途，技術可行不等於取得轉播授權。

## 6. 建議模組

可依專案慣例調整名稱，不強制過度拆分套件：

- App／Views：入口、房間、來源選擇、狀態及設定。
- Domain：Room、Member、PresenterState、TransferOffer、StreamDescriptor。
- Networking：RoomDiscovery、CoordinatorServer、RoomClient、ProtocolCodec、Pairing。
- Audio：AudioCaptureService、AudioTransport、AudioPlaybackService、AudioFormatAdapter。
- Diagnostics：OSLog、連線／buffer 指標與錯誤分類；不可記錄音訊、PIN、token。

SwiftUI 預覽可使用 fake service，但正式路徑不得默默回退至 fake；權限／網路錯誤必須真的呈現。

## 7. 分階段實作

### Phase 0：最高風險驗證與選型

1. 確認本機 macOS、Xcode、Swift、測試 Mac 數量及架構；建立可建置最小 App。
2. 建立來源清單與 ScreenCaptureKit 擷取，先用使用者自有／可擷取測試音源驗證音量，再測 YouTube、Spotify。
3. 驗證立體聲、排除本 App 音訊、沒有麥克風輸入；不以「收到 callback」代替「收到非靜音有效音訊」。
4. 完成選定傳輸的兩台 Mac 音訊實驗；初期允許手動位址，不先做完整房間。
5. 記錄來源／OS／權限矩陣，以及 WebRTC PCM 注入或 AAC 路線的選型理由。

出口：兩台 Mac 真實聽到指定 App 音訊至少 10 分鐘，停止後不再送音；若 Spotify 不可用，明列限制並繼續完成已驗證來源的產品功能。若所有真實音訊路線均不可行，停止擴建 UI，提出具體阻礙。

### Phase 1：房間與身分

完成暱稱、房名、Bonjour 探索、PIN／指紋配對、加入與離開、成員列表、單一協調者狀態、版本相容檢查、手動位址與錯誤提示。此階段可顯示尚未分享音樂。

出口：兩台真機可發現／加入；同名成員不衝突；錯誤 PIN／不信任指紋拒絕加入；協調者離開全員收到結束或逾時。

### Phase 2：整合音訊

將 Phase 0 音訊接入正式房間；只有主持人可開始；晚加入成員取得目前 session 並收聽。完成本機音量／靜音、切換來源、停止、慢聽眾隔離、buffer 上限與輸出裝置處理。

出口：至少 3 台 Mac（1 主持人、2 聽眾）連續播放 30 分鐘；單一聽眾斷線不阻塞其他人；停止後不殘留舊音。

### Phase 3：主持權與異常

完成邀請接受／拒絕／逾時、epoch 防舊串流、交接競態、主持人掉線回收、協調者失聯結束、重複命令冪等與資源清理。

出口：來回交接 10 次，每次僅接受一位主持人的音訊；新主持人未按開始時保持靜音；舊 session／過期接受訊息不能恢復舊主持權。

### Phase 4：打包與驗收

整理 UI、圖示占位、權限說明、建置／安裝文件、雙機操作指南與相容性表；檢查 Release 建置。可用多少真機就測多少，未完成的 10 人壓測清楚列為待驗證。

## 8. 驗收與測試

### 8.1 自動測試重點

只針對高風險邏輯寫必要測試：

- 主持權狀態機：同時接受、過期 offer、重複 request、目標離線、舊 epoch、非主持人越權。
- 協定解析：拆包／黏包、超大長度、未知版本、格式錯誤、未驗證成員。
- buffer 與清理：上限、慢客戶端、stream 切換清空、離開釋放；音訊格式處理可用合法 fixture。

不為單純 UI 文案或系統權限彈窗建立鏡像測試；權限及真實聲音用人工實測。

### 8.2 真機清單

| 情境 | 預期結果 |
|---|---|
| 兩台 Mac 同區網 | 可探索、配對、加入及收聽 |
| 不同服務同時播放 | 只傳指定來源 App；記錄實測邊界 |
| YouTube／Spotify | 分開記錄成功、靜音或受限制，附版本 |
| 晚加入／靜音加入 | 正常接入，靜音不影響其他人 |
| 來源暫停／停止／關閉 | 正確區分安靜與故障，沒有無限重連 |
| 主持權交接與過期封包 | 舊串流失效，新主持人唯一 |
| 建房者非主持人後離開 | 房間仍按規則結束 |
| 權限拒絕／撤銷 | 可理解錯誤，不 crash 或反覆提示 |
| Wi-Fi 中斷／睡眠／喚醒 | 及時停止舊 session，能重新加入 |
| 耳機／藍牙切換 | 不 crash，避免意外外放 |
| 無外網但區網可達 | 使用本機測試音源仍可建房及傳音 |
| 3 人 30 分鐘／10 人負載 | 記錄實際音訊中斷、CPU、記憶體、流量及設備數 |

延遲先設工程目標：穩定區網端到端約 300～1000 ms，容許按傳輸路線調整；不把目標當實測。使用已知脈衝或測試音量測擷取到遠端播放的時間差，標示方法、裝置和藍牙影響。記憶體／buffer 不應隨播放時間持續增加；音訊／網路佇列必須有界。

## 9. 交付物與完成定義

交付可建置的 Xcode 專案及所需來源、固定的依賴解析結果、README.md、docs/architecture.md、docs/testing.md、docs/compatibility.md。README 包含：最低 OS、工具版本、開啟／建置命令、授權、建立／加入、PIN／配對、指定音源、移交與排障。

完成報告必須區分「已建置」「自動測試通過」「真機實測」「尚待驗證」；列出實際指令和限制。沒有 Mac／Xcode 不能宣稱 macOS 建置通過，沒有雙機不能宣稱區網音訊成功。

最終 MVP 的必要條件：暱稱必填、真實區網探索與加入、實際來源音訊傳送、單一主持權與移交、可停止及離開、權限錯誤可處理、文件與實測證據完整。自動 coordinator 遷移、分頁級擷取、曲目同步、多平台及 App Store 上架均保留後續。

## 10. 官方參考（實作時再次確認）

- ScreenCaptureKit：https://developer.apple.com/documentation/screencapturekit
- Apple 擷取範例：https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- 排除本 App 音訊：https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio
- Bonjour Listener：https://developer.apple.com/documentation/network/nwlistener
- 區網隱私：https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- WebRTC 原生開發：https://webrtc.github.io/webrtc-org/native-code/
- WebRTC ADM 原始文件：https://webrtc.googlesource.com/src/+/55a59337c87614f49c87b846ecf3393b2241d5a6/modules/audio_device/g3doc/audio_device_module.md

上述是架構規劃與起始參考，並非對來源服務相容性、具體 SDK API 或效能的既成驗證。
