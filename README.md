# LAN Listen

同一個區網內的 Mac 一起聽音樂：一個人分享自己 Mac 上某個 App（YouTube 瀏覽器、Spotify…）播出的聲音，房間裡其他人戴耳機收聽。不需雲端、不需帳號。

狀態：**0.3.0（Phase 4 打包）**。功能完整、單機多視窗已驗證；多台 Mac 完整驗收待做（見 [docs/testing.md](docs/testing.md)）。
需求：[docs/requirements.md](docs/requirements.md)（含後續變更，見 [docs/development-plan.md](docs/development-plan.md)「需求變更」）。

---

## 給使用者

### 安裝
1. 拿 `release/LANListen-<版本>.zip`（**不是** `LANListen-Dev-…`，那是測試版），解壓後把 LAN Listen 拖進「應用程式」。
2. 第一次開啟會被系統擋下（尚未經 Apple 公證）：按「完成」→「系統設定 → 隱私權與安全性」最下方按「**強制打開**」→ 輸入密碼。
3. 系統會詢問兩個權限：
   | 權限 | 用途 | 何時需要 |
   |---|---|---|
   | 區域網路 | 搜尋與連線房間 | 所有人 |
   | 螢幕與系統錄音 | 擷取來源 App 的聲音（只取聲音，不處理畫面） | 只有要播歌的人 |
   不需要麥克風。拒絕後要到「系統設定 → 隱私權與安全性」對應項目開啟，並完全結束（⌘Q）後重開。

### 使用
**建房**：輸入暱稱 → 房名 → 連接埠（預設 47900，留空自動）→ 建立。畫面會顯示 6 位數**驗證碼**（可「複製」），告訴要加入的人。

**加入**：輸入暱稱 →「區網中的房間」點加入 → 輸入驗證碼。搜尋不到時，用「手動加入」輸入房主畫面上的位址、連接埠、驗證碼。

**三個角色**
| 角色 | 一開始 | 能做什麼 | 換人 | 離開／被踢 |
|---|---|---|---|---|
| 建房者 | 開房的人 | 房間在他的 Mac 上；不能被踢 | 不能換 | 房間關閉，所有人離開 |
| 房主 | 建房者 | 看／更新驗證碼、踢人、轉移房主 | 房主邀請、對方接受 | 房主權回建房者 |
| 播歌者 | 建房者 | 分享音樂、交棒 | 播歌者邀請、對方接受 | 播歌權回房主 |

**播歌**（播歌者）：「音樂」區選來源 App →「開始分享」→ 在該 App 播放。分享中可直接換來源，聽眾不斷線。交棒後你的分享自動停止，新播歌者要自己按開始。

**收聽**：自動開始。可選輸出裝置（例如指定耳機）、調整本機音量／靜音，只影響自己。耳機拔除或輸出裝置改變時會自動暫停，按「繼續播放」恢復，避免外放。

### 限制
- 擷取的是**整個 App**，不是單一瀏覽器分頁；同一瀏覽器其他分頁的聲音也會被分享。
- 聽眾會比原音晚一點，不保證所有人同步；設計情境是各自戴耳機。
- 公司 Wi-Fi 若有裝置隔離、跨 VLAN 或防火牆，可能搜尋不到或連不上；手動位址也無法穿過隔離。
- YouTube／Spotify 是測試對象，不是保證；受保護內容可能無法擷取（不會嘗試繞過）。分享音樂前請自行確認服務條款與著作權。
- 電腦睡眠時會自動離開房間；建房者睡眠會關閉房間。

### 安全說明
- 房間控制訊息（暱稱、成員、驗證碼）在區網內**未加密**傳送；同網段的人可能側錄。驗證碼外流時，房主可隨時「更新驗證碼」。
- **音樂內容有加密**（WebRTC DTLS-SRTP）。
- 驗證碼連錯 5 次鎖 30 秒。

### 排障
| 症狀 | 可能原因 | 處理 |
|---|---|---|
| 房間清單一直空的 | 未允許區域網路權限；不同網段；公司網路隔離 | 系統設定 → 隱私權與安全性 → 區域網路；改用手動加入 |
| 手動加入連不上 | 防火牆擋住連接埠；位址選到 VPN（utun） | 關 VPN、用 en0 位址；系統設定 → 網路 → 防火牆允許 LAN Listen |
| 播歌者按開始後紅字「沒有螢幕與系統錄音權限」 | 權限未開 | 依紅字開啟後 ⌘Q 重開 |
| 「無法連到播歌者」 | 兩台之間 UDP 被擋 | 換到同一個 Wi-Fi／有線網路，關 VPN |
| 收聽中突然沒聲音、出現「已暫停本機播放」 | 輸出裝置改變（耳機拔除） | 確認輸出後按「繼續播放」 |
| 歌曲暫停時沒聲音 | 正常 | 不會因此斷線 |
| 剛連上前 1～2 秒聲音較小 | 刻意淡入，遮住連線暖機 | 正常 |

---

## 給開發者

### 環境
- macOS 14+（開發機 26.5.2，Apple Silicon）、Xcode 26.6、Swift 6.3
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 依賴（SPM 自動下載）：[stasel/WebRTC](https://github.com/stasel/WebRTC) 156.0.0（BSD）

### 兩個 App（同一份原始碼，分開打包）
| | 正式版 `LANListen` | 測試版 `LANListenDev` |
|---|---|---|
| 顯示名稱 | LAN Listen | LAN Listen Dev |
| Bundle ID | `local.lanlisten.LANListen` | `local.lanlisten.LANListen.dev`（權限、設定各自獨立） |
| 內容 | 只有房間 | 加上「雙機實驗」「擷取測試」除錯分頁（`DEV_TOOLS`，`LANListen/Dev/` 只編進測試版） |
| zip | `release/LANListen-<版本>-<建置號>.zip` | `release/LANListen-Dev-<版本>-<建置號>.zip` |

### 建置與測試
```bash
xcodegen generate
```
```bash
xcodebuild -project LANListen.xcodeproj -scheme LANListen -configuration Debug -derivedDataPath build/DerivedData build
```
```bash
cd Packages/RoomCore && swift test
```

### 打包（Release，兩個 App 各一個 zip）
```bash
zsh scripts/package.sh
```
腳本會先跑 RoomCore 測試，失敗就不打包；兩個 App 用 Release 設定建置、驗證簽章後輸出到 `release/`。

### 簽章
- 目前用本機自簽憑證 `LANListen Dev`（鑰匙圈存取 → 憑證輔助程式 → 製作憑證，類型「程式碼簽署」）。讓「螢幕與系統錄音」授權在重新建置後保留；ad-hoc 簽章每次建置都會失效。別台 Mac 要建置需建立同名憑證，或改 `project.yml` 的 `CODE_SIGN_IDENTITY`。
- Release 已關閉 `get-task-allow`。
- ⏳ **未完成**：Developer ID 簽署與 Apple 公證（需付費 Apple Developer 帳號）。完成前，其他人開啟都要「強制打開」。屆時另需評估 Hardened Runtime 與內嵌 WebRTC.framework 的程式庫驗證。

### 目錄
| 路徑 | 用途 |
|---|---|
| `LANListen/Room/` | 房間：協調者、加入、搜尋、音訊、畫面 |
| `LANListen/Audio/`、`LANListen/Transport/` | 擷取、輸出裝置、WebRTC 音訊裝置與共用設定 |
| `LANListen/Dev/` | 測試版專用除錯畫面與 Phase 0 實驗 |
| `Packages/RoomCore/` | 房間規則、協定、限速（純 Swift，含 47 個測試） |
| `Packages/RTCAudioDeviceShim/` | 讓 Swift 使用 WebRTC 自訂音訊裝置（macOS 版缺 header） |
| `Experiments/WebRTCProbe/` | 單機 WebRTC loopback 驗證 |
| `scripts/package.sh` | Release 打包 |
| `design/app-icon-source.webp`、`scripts/app-icon.sh` | App 圖示原稿與產生腳本：換圖後執行 `zsh scripts/app-icon.sh`（自動去掉黑底圓角外側、套 macOS 824/1024 版面、輸出所有尺寸） |
| `docs/` | 需求、計畫、架構、測試、相容性 |
