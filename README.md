# 在 macOS 26.5 中國 SKU 上啟用 Apple Intelligence 感謝codex

已驗證可用的功能包括：

```text
System Settings 裡 Apple Intelligence & Siri 頁面
Apple Intelligence 主開關
Writing Tools
Image Playground
Photos Clean Up / 照片擦除
Siri SAE 模式
```

Siri 的應用名稱仍然是 `Siri`。新版 Apple Intelligence 行為是 Siri 圖標變成新樣式，不是把 App 直接改名成 Apple Intelligence。

## 原理

核心鏈路是：

```text
IOPlatformExpertDevice.region-info
IOPlatformExpertDevice.country-of-origin
  -> MobileGestalt RegionInfo / RegionCode
  -> eligibilityd
  -> generativeexperiencesd / modelcatalogd
  -> System Settings / Siri / Image Playground / Writing Tools
```

中國 SKU 的自然狀態通常是：

```text
IOPlatformExpertDevice.region-info = CH/A
IOPlatformExpertDevice.country-of-origin = CHN
MobileGestalt RegionCode = CH
```

只改某個 App、某個 UI、某個 plist 都不穩，因為每個新進程還會重新從 MobileGestalt / IORegistry 讀到底層中國 SKU 身份。新版 `CodexRegionSpoof.kext` 會在內核側同時修正兩個根 IORegistry 值：

```text
region-info = LL/A
country-of-origin = USA
```

這樣新進程自然讀到：

```text
RegionInfo = LL/A
RegionCode = LL
```

然後再配合 eligibility plist 和 Siri SAE 狀態修正，讓 Apple Intelligence 的各條鏈路一起通過。

## 文件

```text
enable_apple_intelligence_oneclick.sh
tools/CodexRegionSpoof.kext
```

如果 GitHub 上的 kext executable 以 base64 文本形式保存為：

```text
tools/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof.b64
```

一鍵腳本會在本地自動還原成真正的：

```text
tools/CodexRegionSpoof.kext/Contents/MacOS/CodexRegionSpoof
```

`enable_apple_intelligence_oneclick.sh` 是自包含腳本，不再調用舊的子腳本。舊的 LLDB、Image Playground、eligibility 分析腳本只是研究過程備份，不是教程主流程。

## 風險與前提

這是系統級修改，會涉及：

```text
SIP / authenticated-root
Reduced Security
第三方 kext
/private/var/db/eligibilityd/*.plist
sealed system snapshot（僅 --all / --fix-siri-icon 時）
```

你需要能接受：

```text
降低啟動安全策略
允許 kext 載入
重啟
必要時手動恢復
```

如果只是想穩定使用已經開放地區的 Apple Intelligence，不應該使用這套方法。

## 第一步：Recovery 設置

關機，長按 Touch ID / 電源鍵進入啟動選項，進入 Recovery。

打開 Terminal，執行：

```bash
csrutil disable
csrutil authenticated-root disable
```

然後打開 Startup Security Utility：

```text
Security Policy
  -> Reduced Security
  -> 勾選 Allow user management of kernel extensions from identified developers
```

重啟回 macOS。

## 第二步：系統外部條件

建議先調整成非中國環境：

```text
Apple ID：非中國區
系統 Region：United States 或其他支援地區
系統語言：English / en-US 優先
Siri 語言：English (United States) 優先
網絡：非中國出口
```

這些不是唯一 gate，但能減少後續 CloudSubscriptionFeatures / Siri / asset readiness 的變量。

## 第三步：安裝並執行一鍵腳本

在 repo 目錄執行：

```bash
cd /path/to/enableappleai
chmod +x enable_apple_intelligence_oneclick.sh
./enable_apple_intelligence_oneclick.sh
```

腳本會正常觸發 sudo 密碼提示，不會保存密碼。

如果 `/Library/Extensions/CodexRegionSpoof.kext` 還不存在，腳本會自動從：

```text
tools/CodexRegionSpoof.kext
```

複製到：

```text
/Library/Extensions/CodexRegionSpoof.kext
```

並修正 owner / permission。

## 可選：修 Siri Launchpad 圖標

如果 Apple Intelligence 已經可用，但 Launchpad 裡 Siri 圖標仍是舊圖標，可以執行：

```bash
./enable_apple_intelligence_oneclick.sh --all
```

或只做圖標修正：

```bash
./enable_apple_intelligence_oneclick.sh --fix-siri-icon
```

這一步會掛載可寫 system volume，刪除 Siri App 的：

```text
CFBundleIconName
```

讓 Launchpad 從 `CFBundleIconFile = AppIcon` 回退到：

```text
/System/Applications/Siri.app/Contents/Resources/AppIcon.icns
```

然後執行：

```bash
bless --create-snapshot
```

所以必須重啟後才會看到圖標變化。

## 腳本具體做了什麼

`enable_apple_intelligence_oneclick.sh` 會做以下事情：

1. 檢查 SIP / authenticated-root 狀態。
2. 檢查 root IORegistry 的 `region-info` / `country-of-origin`。
3. 安裝並載入 `CodexRegionSpoof.kext`。
4. 安裝開機自動載入 kext 的 LaunchDaemon：

   ```text
   /Library/LaunchDaemons/local.codex.region-spoof-loader.plist
   /Library/Scripts/Codex/load-region-spoof.sh
   ```

5. 修改 Apple Intelligence 相關 eligibility domains。
6. 將 Siri SAE orchestration mode 設成 `4`。
7. 重啟相關服務：

   ```text
   eligibilityd
   generativeexperiencesd
   modelcatalogd
   System Settings
   SiriPreferenceExtension
   SiriNCService
   SystemUIServer
   Dock
   cfprefsd
   ```

8. 發送 availability / eligibility notification。
9. 恢復 Siri menu bar extra。
10. 如果使用 `--all`，修正 Siri Launchpad 圖標來源並建立新 snapshot。

## Eligibility 修改內容

腳本會把 Apple Intelligence 相關 domain 設為：

```text
os_eligibility_answer_t = 4
```

注意：`4 = ELIGIBLE`。

目標 domains：

```text
OS_ELIGIBILITY_DOMAIN_GREYMATTER
OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS
OS_ELIGIBILITY_DOMAIN_PERSONAL_QA
OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS
OS_ELIGIBILITY_DOMAIN_TERBIUM
OS_ELIGIBILITY_DOMAIN_AI_LABELING
OS_ELIGIBILITY_DOMAIN_IRON
OS_ELIGIBILITY_DOMAIN_STRONTIUM
OS_ELIGIBILITY_DOMAIN_SWIFT_ASSIST
OS_ELIGIBILITY_DOMAIN_XCODE_LLM
```

同時會把已觀測到的 status inputs 設為：

```text
3
```

例如：

```text
OS_ELIGIBILITY_INPUT_DEVICE_REGION_CODE = 3
OS_ELIGIBILITY_INPUT_DEVICE_CLASS = 3
OS_ELIGIBILITY_INPUT_COUNTRY_LOCATION = 3
OS_ELIGIBILITY_INPUT_GENERATIVE_MODEL_SYSTEM = 3
```

修改後會鎖定 plist：

```bash
chflags uchg /private/var/db/eligibilityd/eligibility.plist
chflags uchg /private/var/db/os_eligibility/eligibility.plist
```

## Siri SAE 修改內容

腳本會寫：

```text
com.apple.assistant.backedup
  SiriAvailability
    isAvailable = true
    desiredOrchestrationMode = 4
    unavailabilityReasons = 0
```

這會讓 Siri 走 System Assistant Experience / Apple Intelligence 相關路徑。

## 驗證

執行：

```bash
./enable_apple_intelligence_oneclick.sh --verify-only
```

理想輸出裡應該看到：

```text
IOPlatformExpertDevice.region-info = <4c4c2f41...>
IOPlatformExpertDevice.country-of-origin = <"USA">
CodexRegionSpoof loaded
OS_ELIGIBILITY_DOMAIN_GREYMATTER              4
OS_ELIGIBILITY_DOMAIN_FOUNDATION_MODELS       4
OS_ELIGIBILITY_DOMAIN_PERSONAL_QA             4
OS_ELIGIBILITY_DOMAIN_SIRI_WITH_APP_INTENTS   4
OS_ELIGIBILITY_DOMAIN_STRONTIUM               4
SiriAvailability.desiredOrchestrationMode = 4
```

也可以看 kext loader 日誌：

```bash
sudo tail -100 /var/log/codex-region-spoof-loader.log
```

成功時應該能看到類似：

```text
CodexRegionSpoof: set region-info LL/A ok=1, country-of-origin USA ok=1
```

## 功能驗證

重啟後依序檢查：

```text
System Settings -> Apple Intelligence & Siri
Apple Intelligence toggle 是否可見
Writing Tools 是否出現在文字選單 / 輸入場景
Image Playground 是否能進入創作界面
Photos 是否有 Clean Up / 擦除
Siri 是否走新版界面
```

如果使用了 `--all`，Launchpad 裡 Siri 圖標需要重啟後再判斷。

## 常見問題

### 1. Settings 左側剛開始是 Apple Intelligence，點擊後又變 Siri

這通常表示不同進程讀到的 availability cache 不一致。重點先看 root region：

```bash
./enable_apple_intelligence_oneclick.sh --verify-only
```

如果 `region-info` 仍然是 `CH/A`，或 `country-of-origin` 仍然是 `CHN`，說明 kext 沒有成功載入或沒有在 boot 後重新載入。

### 2. Image Playground 出界面但功能用不了

早期 UI patch 可以讓界面出現，但不能讓底層模型資產 ready。現在應優先檢查：

```text
region-info
country-of-origin
eligibility
generativeexperiencesd
modelcatalogd
UAF / model assets
```

如果 root region 已是 `LL/A`，再等待或重啟一次，讓 modelcatalog / MobileAsset 重新評估。

### 3. Siri menu bar 圖標不能添加

腳本會寫：

```text
com.apple.systemuiserver menuExtras = /System/Library/CoreServices/Siri.bundle
```

並重啟 `SystemUIServer`。如果仍不出現，重啟後再試。

### 4. Launchpad 還是舊 Siri 圖標

先確認你是否執行過：

```bash
./enable_apple_intelligence_oneclick.sh --all
```

然後重啟。這一步改的是 sealed system snapshot，沒有重啟前 live root 還是舊 snapshot。

### 5. 可以重新打開 Full Security / authenticated-root 嗎

如果你還依賴 `CodexRegionSpoof.kext` 開機自動修正 root region，就不能直接恢復 Full Security；否則 kext 無法載入，系統會回到中國 SKU root region。

如果未來 Apple 官方放開，或你不再需要這套修正，可以先移除 LaunchDaemon 和 kext，再考慮恢復安全策略。

## 還原

停用開機 kext loader：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/local.codex.region-spoof-loader.plist 2>/dev/null
sudo rm -f /Library/LaunchDaemons/local.codex.region-spoof-loader.plist
sudo rm -f /Library/Scripts/Codex/load-region-spoof.sh
```

移除 kext：

```bash
sudo kmutil unload -p /Library/Extensions/CodexRegionSpoof.kext 2>/dev/null || true
sudo rm -rf /Library/Extensions/CodexRegionSpoof.kext
```

Eligibility 備份在：

```text
/private/var/db/eligibilityd_source_backup/
```

SiriAvailability 備份在：

```text
./backups/siri-availability/
```

Siri Launchpad 圖標備份在：

```text
~/Documents/Codex/siri-launchpad-icon-backups/
```

恢復 eligibility plist 時需要先：

```bash
sudo chflags nouchg /private/var/db/eligibilityd/eligibility.plist
sudo chflags nouchg /private/var/db/os_eligibility/eligibility.plist
```

然後把備份拷回去，修正 owner / permission，最後重啟。
