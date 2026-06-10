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

## macOS 27 兼容性提示

macOS 27 目前仍按開發者 beta / 預覽版處理，屬於實驗支持，不保證所有 beta build 都可用。

macOS 27 的新 Siri AI 多了一層 `EnhancedSiriWaitlist` FeatureFlags gate。主腳本會在 macOS 27 或更新版本上自動寫入覆蓋 plist：

```text
/Library/Preferences/FeatureFlags/Domain/GenerativeModels.plist
EnhancedSiriWaitlist.Enabled = false
```

這是利用 macOS FeatureFlags 的 override 路徑，不直接修改 `/System/Library/FeatureFlags/Domain/GenerativeModels.plist`，因此比直接改 sealed system volume 更適合合入一鍵腳本。

另外，macOS 27 的部分新 Siri AI 路徑會檢查 AppleInternal variant。主腳本現在默認會在 sealed System volume 裡建立：

```text
/System/Library/CoreServices/AppleInternalVariant.plist
AppleInternal = true
```

這一步和普通 Data volume plist 不同，必須先在 Recovery 裡執行：

```bash
csrutil disable
csrutil authenticated-root disable
```

腳本會自動掛載 System volume、寫入 `AppleInternalVariant.plist`，然後執行：

```bash
bless --mount /private/tmp/codex_system_rw --create-snapshot --setBoot
```

因此這一步需要重啟後才會在 live root 生效。如果你不想開 AppleInternal variant，可以跳過：

```bash
./enable_apple_intelligence_oneclick.sh --skip-apple-internal
```

如果你只想跑 26.x 的原流程，或想手動測試 macOS 27，可以跳過這一步：

```bash
./enable_apple_intelligence_oneclick.sh --skip-macos27-siri-ai
```

本項目目前完整驗證的主線仍是 macOS 26.5 / 26.5.1。macOS 27 會在正式版發布後再重新分析底層鏈路並做穩定適配。

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

定位是另一條鏈。Apple Intelligence 需要 root identity 顯示為 `LL/A + USA`，但 Apple Maps / Weather 定位會參考 `locationd` / GeoServices 的國家配置。新版一鍵腳本會根據「當前出口 IP 的地理國家」自動寫入：

```text
/var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist
DeviceCountryCodeSourced.cc = <current public IP country>
```

這不會把 IORegistry 改回中國 SKU，只是讓地圖定位使用與當前網絡出口更一致的 GeoServices 配置。

如果想不看出口 IP、固定把 GeoServices 定位國家寫成美國，可以加：

```bash
./enable_apple_intelligence_oneclick.sh --force-geoservices-us
```

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

`enable_apple_intelligence_oneclick.sh` 是唯一 `.sh` 入口。Location Services 裡 Siri 圖標的 runtime identity 修正也已合併在主腳本內，主腳本會在運行時生成必要的 LLDB patch，並安裝進既有的 `load-region-spoof.sh` 開機流程。舊的 LLDB、Image Playground、eligibility 分析腳本只是研究過程備份，不是教程主流程。

## 風險與前提

這是系統級修改，會涉及：

```text
SIP / authenticated-root
Reduced Security
第三方 kext
/private/var/db/eligibilityd/*.plist
sealed system snapshot（macOS 27+ 的 AppleInternalVariant，或 Siri.app 的 Info.plist 曾被舊方案改壞、需要恢復時）
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

## 可選：刷新 Siri Launchpad 圖標

如果 Apple Intelligence 已經可用，但 Launchpad 裡 Siri 圖標仍是舊圖標，可以執行：

```bash
./enable_apple_intelligence_oneclick.sh --all
```

或只做圖標修正：

```bash
./enable_apple_intelligence_oneclick.sh --fix-siri-icon
```

目前正確狀態有兩層：

```text
/System/Applications/Siri.app
  CFBundleIconName = AppIcon

/System/Library/CoreServices/Siri.app
  被 AOSUI / iCloud 的 com.apple.siri identity 使用

IconServices
  com.apple.siri -> com.apple.application-icon.siri-intelligence
```

Launchpad / Menu Bar 通常讀 `/System/Applications/Siri.app`。但 iCloud「See All」、AOSUI 列表和一些隱私列表仍會從 `com.apple.siri` 解析到 `/System/Library/CoreServices/Siri.app`。正確路徑不是自己生成或覆蓋圖標，而是讓 IconServices 把 Siri app icon alias 到 Apple 內置的 `com.apple.application-icon.siri-intelligence`。腳本只刷新 LaunchServices / IconServices 緩存並驗證這條 alias，不替換 `.icns`。

iCloud「See All」還有一個更隱蔽的點：`AppleIDSettings.appex` 是 sandboxed Extension，`NSHomeDirectory()` 指向：

```text
~/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data
```

所以它讀不到普通用戶域裡的：

```text
~/Library/Preferences/com.apple.assistant.backedup.plist
```

如果這個容器裡沒有同一份 `SiriAvailability`，AOSUI 進程內就不會把 `com.apple.siri` alias 到 Apple Intelligence 圖標。腳本會把 `SiriAvailability` 鏡像到：

```text
~/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data/Library/Preferences/com.apple.assistant.backedup.plist
```

這不是改 UI 圖片，而是讓 AppleIDSettings 讀到和系統其它進程一致的 AI availability 狀態。

Location Services 裡 Siri 圖標是另一條路徑：它的權限身份是 `AssistantServices.framework`，但顯示圖標應該取 `/System/Applications/Siri.app`。主腳本會把這個 locationd runtime 修正合入既有的 `load-region-spoof.sh` 開機流程。

Siri / Safari 的網頁搜索 provider 也是另一條鏈。主腳本會把全局 web search provider 明確設為 Google，並在備份 Safari plist 後移除 `RecentWebSearches` 裡殘留的 Baidu URL，避免舊搜索歷史被誤判成當前 provider。

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
7. 根據當前出口 IP 自動寫入 GeoServices 定位國家 cache；如果加 `--force-geoservices-us`，則固定寫 `US`。
8. 合併 `kanshurichard/enableAppleAI` 方法二的 `countryd` cache 修正，把 `/private/var/db/com.apple.countryd/countryCodeCache.plist` 內的兩位國家碼固定為 `US` 並鎖定。
9. 在 macOS 27+ 上，於 sealed System volume 裡建立 `/System/Library/CoreServices/AppleInternalVariant.plist`，設置 `AppleInternal = true`，並建立新的 boot snapshot。
10. 在 macOS 27+ 上寫入 `GenerativeModels.EnhancedSiriWaitlist.Enabled = false` 的 FeatureFlags override，用於繞過新 Siri AI waitlist gate。
11. 將 Location Services 裡 Siri 圖標的 runtime identity 修正合入 `load-region-spoof.sh`。
12. 將 Siri / Safari web search provider 正規化為 Google，並清理 Safari RecentWebSearches 裡的舊 Baidu 條目。
13. 重啟相關服務：

   ```text
   eligibilityd
   generativeexperiencesd
   modelcatalogd
   locationd
   geod
   System Settings
   SiriPreferenceExtension
   SiriNCService
   SystemUIServer
   Dock
   cfprefsd
   ```

13. 發送 availability / eligibility notification。
14. 恢復 Siri menu bar extra。
15. 如果使用 `--all`，刷新 Siri Launchpad 圖標註冊；只有在舊補丁破壞過 Siri.app Info.plist 時才需要修復 snapshot。

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

## 方法二合併內容

一鍵腳本已經合併 `kanshurichard/enableAppleAI` 方法二涉及的持久文件修改：

```text
/private/var/db/eligibilityd/eligibility.plist
/private/var/db/os_eligibility/eligibility.plist
/private/var/db/com.apple.countryd/countryCodeCache.plist
```

前兩個 eligibility plist 會被寫成 Apple Intelligence 相關 domain `answer_t = 4`。`countryCodeCache.plist` 會把兩位國家碼固定為 `US`，再設成只讀並加 `uchg`，避免 `countryd` 下一次刷新時把中國 SKU 的國家 cache 寫回來。

如果只想跳過 `countryd` cache 修正，可以執行：

```bash
./enable_apple_intelligence_oneclick.sh --skip-countryd
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

如果使用了 `--all`，Launchpad 裡 Siri 圖標需要重啟或重新登入後再判斷。

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

然後重啟或重新登入。這一步會刷新 LaunchServices / IconServices，鏡像 `SiriAvailability` 到 AppleIDSettings 容器，並檢查 `NSWorkspace` 是否把 Siri app icon 解析為 `com.apple.application-icon.siri-intelligence`。如果 iCloud 彈窗仍顯示舊圖標，先關閉 System Settings 再重新打開，因為 AppleIDSettings/AOSUI 會在進程內緩存 service row icon。

### 5. Maps 定位按鈕沒反應

如果 Apple Intelligence 已經可用，但 Maps 裡點定位沒有反應，先看：

```text
View -> Go to Current Location
```

如果這個項目是灰色，通常不是 Maps 壞了，而是 `locationd` / GeoServices 的定位國家配置和當前網絡出口不一致。一鍵腳本默認會按當前出口 IP 寫入：

```text
DeviceCountryCodeSourced.cc = <current public IP country>
```

寫入 GeoServices cache，然後重啟：

```text
locationd
geod
routined
Maps
Weather
```

如果你不想讓腳本改定位國家 cache，可以執行：

```bash
./enable_apple_intelligence_oneclick.sh --skip-location-ip
```

### 6. Software Update 提示 snapshot 不一致

如果升級 macOS 時看到類似提示：

```text
A snapshot is currently set to boot that is not the currently booted snapshot.
Reboot to boot to the new snapshot to allow installation to this volume.
```

先直接重啟一次：

```bash
sudo reboot
```

如果重啟後仍然出現同樣提示，再手動讓系統回到 Apple 的 last sealed snapshot：

```bash
sudo bless --mount / --last-sealed-snapshot --setBoot
sudo reboot
```

這條命令只用來修復 Software Update / SSV snapshot 狀態，不是啟用 Apple Intelligence 的必要步驟，所以不要把它當成日常流程反覆執行。

執行後可以檢查：

```bash
diskutil info / | grep -E 'APFS Snapshot Name|APFS Snapshot UUID|Sealed'
diskutil apfs listSnapshots /
```

理想狀態是：

```text
Sealed: Yes
沒有 Will root to (boot from) another snapshot
```

注意：`bless --last-sealed-snapshot` 只影響 System Volume 的啟動 snapshot。它不會清掉 Data Volume / NVRAM 裡的狀態，例如：

```text
/Library/Extensions/CodexRegionSpoof.kext
/Library/LaunchDaemons/local.codex.region-spoof-loader.plist
/private/var/db/eligibilityd/eligibility.plist
/private/var/db/os_eligibility/eligibility.plist
/private/var/db/com.apple.countryd/countryCodeCache.plist
NVRAM region-info
```

升級完成後再執行：

```bash
./enable_apple_intelligence_oneclick.sh --verify-only
```

如果 Apple Intelligence 狀態掉了，再重新執行一鍵腳本。

### 7. 成功後如何恢復比較高安全狀態

先完成一鍵腳本，確認 Apple Intelligence / Writing Tools / Image Playground / Photos Clean Up 已經可用，並確認底層值已經固定為：

```text
country-of-origin = USA
region-info = LL/A
```

確認成功後，建議把安全狀態收緊到下面這個狀態：

目標狀態：

```text
SIP: 保持腳本要求的狀態，不要執行 csrutil enable
Authenticated Root: enabled
FileVault: on
Startup Security: Reduced Security
3rd Party Kexts: Enabled
Signed System Volume: Enabled
```

這不是完整 Full Security。原因是本方案仍依賴 `CodexRegionSpoof.kext` 在開機時修正底層 IORegistry 身份；如果切回 Full Security，第三方 kext 很可能無法載入，下一次重啟後會回到中國 SKU 身份。

成功後不要急著執行 `csrutil enable`。目前建議只恢復兩件事：

```text
1. csrutil authenticated-root enable
2. 打開 FileVault
```

推薦流程：

1. 先確認 Apple Intelligence 已經可用，並確認底層值：

   ```bash
   ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei 'region-info|country-of-origin'
   ```

   理想結果：

   ```text
   "country-of-origin" = <"USA">
   "region-info" = <4c4c2f41...>   # LL/A
   ```

2. 進 Recovery，只打開 authenticated-root：

   ```bash
   csrutil authenticated-root enable
   ```

   不要在這一步執行：

   ```bash
   csrutil enable
   ```

   因為本方案仍然需要開機載入第三方 kext。`csrutil enable` 可能讓 kext / 底層 spoof 鏈路失效。

3. 仍然保留 Startup Security Utility 裡的：

   ```text
   Reduced Security
   Allow user management of kernel extensions from identified developers
   ```

4. 重啟回 macOS 後，打開 FileVault：

   ```text
   System Settings
     -> Privacy & Security
     -> FileVault
     -> Turn On
   ```

   FileVault 是磁碟加密，和 SSV / authenticated-root 不是同一個開關。打開 FileVault 不會破壞 Apple Intelligence 狀態，也不會阻止 `/Library/Extensions/CodexRegionSpoof.kext` 從 Data Volume 載入。

5. 檢查狀態：

   ```bash
   csrutil status
   csrutil authenticated-root status
   fdesetup status
   sudo bputil -d | grep -E 'Security Mode|3rd Party Kexts|Signed System Volume'
   ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei 'region-info|country-of-origin'
   sudo kmutil showloaded | grep -Ei 'Codex|RegionSpoof'
   ```

   理想結果：

   ```text
   System Integrity Protection status: disabled.    # 或保持腳本要求的狀態
   Authenticated Root status: enabled
   FileVault is On.
   Security Mode: Permissive / Reduced Security
   3rd Party Kexts Status: Enabled
   Signed System Volume Status: Enabled
   country-of-origin = <"USA">
   region-info = <4c4c2f41...>
   local.codex.RegionSpoof loaded
   ```

6. 再重啟一次，再查同樣的值。第二次重啟後仍然保持 `USA + LL/A`，才算穩定。

如果重啟後變回：

```text
country-of-origin = CHN
region-info = CH/A
```

說明 kext 沒有在新的安全策略下成功載入。此時需要回 Recovery 重新設成 Reduced Security 並允許 kext，然後回 macOS 重新執行一鍵腳本。

不要做：

```text
不要切回 Full Security
不要執行 csrutil enable
不要移除 CodexRegionSpoof.kext
不要移除 /Library/LaunchDaemons/local.codex.region-spoof-loader.plist
不要再跑舊的 LLDB / UI patch 腳本
```

如果未來 Apple 官方放開，或你不再需要這套修正，可以先移除 LaunchDaemon 和 kext，再考慮恢復 Full Security。

### 8. 補充注意事項

下面是目前在不同 macOS 26 / 27 測試機上觀察到的現象，遇到時按這個思路處理。

#### Reduced Security / csrutil 狀態可能會互相牽動

部分 macOS 版本裡，Startup Security Utility 的安全策略和 `csrutil` / `authenticated-root` 不是完全獨立的開關。可能會看到：

```text
Security Policy -> Reduced Security
csrutil status -> enabled
csrutil authenticated-root status -> enabled
```

也可能出現：手動把 `authenticated-root` 改回 `disable` 後，Security Policy 立即滑到 `Permissive`。

這屬於 Apple 啟動安全策略的聯動行為，不一定是腳本失敗。成功後不要追求某一組固定的 `csrutil status` 字樣，重點看：

```bash
sudo bputil -d | grep -E 'Security Mode|3rd Party Kexts|Signed System Volume'
ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei 'region-info|country-of-origin'
sudo kmutil showloaded | grep -Ei 'Codex|RegionSpoof'
```

只要下面幾點成立，通常就可以繼續測試：

```text
3rd Party Kexts: Enabled
CodexRegionSpoof 已載入
country-of-origin = USA
region-info = LL/A
```

#### 第一次載入 kext 後可能需要手動允許

如果你在 Recovery 裡關過 SIP / 改過安全策略，第一次回到 macOS 後，可能還需要到：

```text
System Settings
  -> Privacy & Security
  -> 滑到最下方
  -> 允許被阻止的系統軟體 / 內核擴展
```

允許後通常還要再重啟一次。沒有完成這一步時，可能會出現「Apple Intelligence UI 已經出現，但 Siri AI / 相關模型功能仍然不可用」。

#### 部分功能初始化後會走本地模型 / 本地資產

Photos Clean Up、Writing Tools、Image Playground 等功能在資產下載完成後，很多路徑會走本地模型或本地快取。某些工具初始化成功一次後，即使之後調整 `csrutil` 狀態，短期內也可能仍然可用。

但這不代表底層 spoof 已經不需要了。新進程、新系統服務、重啟後的 availability 判斷，仍然可能重新讀：

```text
IORegistry
MobileGestalt
eligibilityd
generativeexperiencesd / modelcatalogd
```

所以最終仍以 `ioreg`、`kmutil showloaded` 和實際功能測試為準。

#### Siri 圖標短時間不對，先重啟

Siri / Apple Intelligence 圖標來自 LaunchServices / IconServices / AOSUI 等多層快取。腳本會刷新相關 cache，但有些列表不會即時更新。

如果只有 Siri 圖標不對，而 Apple Intelligence 功能已經可用，先完整重啟一次再看。不要反覆手動替換圖標文件。

#### 出現 macOS 26 風格 Siri 界面時

如果已經打開 Apple Intelligence，但仍看到 macOS 26 風格的 Siri 界面，先不要急著重跑腳本。可以打開網絡監控工具，看是否有 `generativeexperiencesd`、`modelcatalogd`、`assetd`、`mobileassetd` 等進程在下載 AI 資源。

如果有下載流量，等資源下載完成後重啟，再重新打開：

```text
System Settings -> Apple Intelligence & Siri
Image Playground
Writing Tools
Photos Clean Up
```

很多情況下，這是模型資產還沒完全 ready，而不是 eligibility 沒通。

## 還原

目前發布包只保留一個 `.sh`，還原也從同一個入口執行：

```bash
./enable_apple_intelligence_oneclick.sh --uninstall
```

如果只想看它會做什麼，不實際修改：

```bash
./enable_apple_intelligence_oneclick.sh --dry-run
```

它會先備份目前狀態，再移除 kext / LaunchDaemon，解鎖並清除 eligibility cache，刪除用戶層 Apple Intelligence 強制 defaults，最後提示重啟。
同時會解鎖 `countryCodeCache.plist`，但不直接刪除這個系統 cache，讓 `countryd` 後續自行刷新。

手動還原步驟如下。

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
