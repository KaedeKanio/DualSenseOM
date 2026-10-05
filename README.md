[README.md](https://github.com/user-attachments/files/33075829/README.md)
# DualSenseOM

DualSenseOM 是一款 macOS 選單列 App，使用 Apple GameController 讀取 DualSense 手把輸入，並以 OSC 與虛擬 MIDI 傳送給 TouchDesigner、Resolume Arena、Ableton Live 等創作軟體。

由 NeoLo（羅苰榤）設計。作者頁面：[github.com/KaedeKanio](https://github.com/KaedeKanio)

## 功能

- 最多連接並分開設定兩支 DualSense 手把。
- 透過 OSC 傳送搖桿、板機、按鍵、觸控板、陀螺儀、加速度計、電池與連線狀態。
- 每支手把使用獨立 OSC 埠，資料可分開接收。
- 提供每支手把各自的完整 MIDI 與 MIDI Learn 虛擬輸出。
- 可從 OSC 控制手把燈色、握把震動與 Adaptive Trigger。
- 不需要另外安裝手把驅動程式。

## 系統需求

- macOS 13 或更新版本。
- Sony DualSense 手把；需先在 macOS 藍牙設定中配對，或以 USB 連接。
- 支援 Apple Silicon 與 Intel 的通用 App。

## 快速開始

1. 依照[安裝教學](INSTALLATION.md)下載、安裝並首次開啟 App。
2. 連接 DualSense，從選單列開啟 DualSenseOM，確認手把狀態已連線。
3. 在 TouchDesigner 建立 OSC In CHOP，手把 1 預設接收埠為 `9991`，手把 2 為 `9992`。
4. 若要從 TouchDesigner 控制手把，OSC Out CHOP 預設送至手把 1 的接收埠 `9993`，手把 2 的接收埠 `9994`。
5. MIDI 軟體可選擇 `DualSenseOM MIDI 1/2`（完整狀態）或 `DualSenseOM MIDI Learn 1/2`（只送變更）。

設定頁可調整目的 IP 與埠號；不同手把的 OSC 埠可分開設定。更多 OSC 位址與 MIDI 對照請查看 GitHub 專案中的 `OSC-ADDRESSES.md` 與 `MIDI-SETUP.md`。

## 下載與安全提示

請從專案的 GitHub Releases 下載發布者提供的 ZIP 或 DMG。此資料夾中的 `.app` 本身不是安裝程式，也不包含 DMG。

目前這份 App 使用 ad-hoc 簽署，尚未使用 Developer ID 簽署或 Apple notarization。首次開啟時，macOS 可能會提醒無法確認開發者或無法檢查惡意軟體。請只在確認檔案來自可信任的 DualSenseOM 發布來源後，依照[安裝教學](INSTALLATION.md)手動允許開啟。Apple 對未 notarize App 的說明：[Safely open apps on your Mac](https://support.apple.com/en-us/102445)。

## 版本資訊

請以 GitHub Releases 標示的最新版本為準。每次發布前，請確認上傳的 App 版本與 Release 標題一致。

## 授權

此打包資料夾未附 LICENSE。請查看 GitHub 原始碼專案的授權檔案，並依該授權使用或散布。
