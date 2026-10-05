# DualSenseOM 安裝與使用教學

## 下載與安裝

1. 從 DualSenseOM GitHub 專案的 **Releases** 下載最新 ZIP 或 DMG。若發布頁提供多個版本，請選擇最新且與目前 macOS 相容的版本。
2. 若下載的是 ZIP，雙擊解壓縮；若下載的是 DMG，打開磁碟映像檔。
3. 將 `DualSenseOM.app` 拖曳到「應用程式」資料夾。
4. 在「系統設定 → 藍牙」配對 DualSense，或使用 USB 連接。
5. 從「應用程式」開啟 DualSenseOM。它會出現在選單列，不一定會在 Dock 顯示常駐圖示。

## 首次開啟時的 macOS 安全提示

目前提供的 App 尚未 notarize。若 macOS 阻止開啟，只有在確認 App 是從可信任的官方發布來源下載後才繼續：

1. 在 Finder 的「應用程式」資料夾找到 `DualSenseOM.app`。
2. 按住 Control 鍵並點按 App，選擇「打開」，再於確認視窗選擇「打開」。
3. 若沒有出現「打開」選項，先嘗試一般開啟一次，再前往「系統設定 → 隱私權與安全性」，向下找到該 App 的安全提示，按「仍要打開」，並確認。

只對你信任且來源可確認的 App 使用「仍要打開」。不要為了安裝而停用 Gatekeeper 或執行不明來源的終端機指令。Apple 官方說明：[在 Mac 上安全地打開 App](https://support.apple.com/zh-tw/102445)。

## 連接手把

1. 確認手把已透過藍牙或 USB 連到 Mac。
2. 從選單列開啟 DualSenseOM，確認對應手把顯示「已連線」。
3. 若連接兩支手把，可在設定中指定手把 1／2；OSC 埠與 MIDI 輸出會依指定的手把分開。

## TouchDesigner：接收手把 OSC

1. 建立一個或兩個 **OSC In CHOP**。
2. 手把 1 的 Network Port 設為 `9991`；手把 2 設為 `9992`。
3. 在 DualSenseOM 的 OSC 設定中確認 Target IP 指向接收端。TouchDesigner 與 App 在同一台 Mac 時，通常使用 `127.0.0.1`。
4. 若修改過輸出埠，OSC In CHOP 也要改成相同的埠。

## TouchDesigner：送 OSC 回手把

建立 **OSC Out CHOP**，將目的 IP 設為執行 DualSenseOM 的 Mac：

- 手把 1：UDP 埠 `9993`
- 手把 2：UDP 埠 `9994`

在 DualSenseOM 的進階設定中開啟對應的 OSC 功能。RGB 燈色使用 `/led/r`、`/led/g`、`/led/b`；握把震動使用 `/haptic`，數值範圍 `0–1`，送 `0` 停止。兩個接收埠分別控制指定的手把。

更多板機、震動與其他 OSC 位址，請查看 GitHub 原始碼專案的 `OSC-ADDRESSES.md`。如果有多個 CHOP 要共同控制同一個 `/haptic`，請先在 TouchDesigner 合併訊號，再送入單一 OSC Out CHOP，避免其中一路的 `0` 關掉另一路的震動。

## MIDI：TouchDesigner、Resolume、Ableton

在接收軟體的 MIDI 裝置清單中選擇：

- `DualSenseOM MIDI 1` 或 `DualSenseOM MIDI 2`：持續傳送完整狀態，適合 TouchDesigner。
- `DualSenseOM MIDI Learn 1` 或 `DualSenseOM MIDI Learn 2`：只在控制值變更時傳送，適合 Resolume Arena、Ableton Live 的 MIDI Learn。

若來源沒有出現在清單中，先確認 DualSenseOM 已開啟並在進階設定中啟用 MIDI，然後重新開啟或重新掃描 MIDI 軟體的輸入裝置。

## 常見問題

**OSC 沒有資料**

- 確認手把已連線、OSC 已啟用，且 OSC In CHOP 埠號與 App 的目的埠一致。
- 同一台 Mac 使用 `127.0.0.1`；跨裝置時使用執行 TouchDesigner 的 Mac 在區域網路中的 IP。
- 確認沒有其他程式占用相同接收埠。

**OSC 回傳燈色或震動沒有作用**

- 確認 OSC Out CHOP 的目標是執行 DualSenseOM 的 Mac，並使用 `9993` 或 `9994`。
- 確認進階設定已開啟相應功能，並確認接收埠沒有被其他程式占用。
- 握把震動是整支手把共同輸出，不能分成左右握把區域。

**MIDI Learn 一直抓到感測器數值**

- 在進階設定關閉 MIDI motion 輸出，再執行 MIDI Learn。
- 優先使用 `DualSenseOM MIDI Learn` 作為只送變更的來源。

## 移除

先結束 DualSenseOM，再從「應用程式」資料夾將 `DualSenseOM.app` 移至垃圾桶。若希望清除儲存的網路與控制器偏好設定，也可在 Finder 的「前往資料夾」輸入 `~/Library/Preferences/`，移除 `com.NeoLo.DualSenseTD.plist`。刪除偏好設定會清除使用者保存的設定。
