# enableAppleIntelligence

在中國 SKU Apple Silicon Mac 上啟用 Apple Intelligence 的一鍵腳本。

目前主線驗證：macOS 26.5 / 26.5.1。macOS 27 仍按 beta 處理，腳本已加入實驗性兼容；部分 build 可能仍無法打開新 Siri AI，正式版發布後會再適配。

## 原理

核心不是改 UI，而是從源頭改系統身份：

```text
IOPlatformExpertDevice.region-info / country-of-origin
  -> MobileGestalt RegionCode / RegionInfo
  -> eligibilityd
  -> generativeexperiencesd / modelcatalogd
  -> Siri / Settings / Writing Tools / Image Playground
```

中國 SKU 默認通常是：

```text
region-info = CH/A
country-of-origin = CHN
```

腳本安裝 `CodexRegionSpoof.kext`，在 runtime 把底層 IORegistry 改為：

```text
region-info = LL/A
country-of-origin = USA
```

這樣新進程會自然讀到非中國 SKU 身份，不需要逐個 App 注入。

## 文件

```text
enable_apple_intelligence_oneclick.sh
tools/CodexRegionSpoof.kext
```

只需要執行這一個 `.sh`。

## 前置條件

進 Recovery，Terminal 執行：

```bash
csrutil disable
csrutil authenticated-root disable
```

Startup Security Utility 裡保持 `csrutil disable` 後的 `Permissive Security` 狀態，不要改選 `Reduced Security`；只保留以下 kernel extension 選項啟用：

```text
Allow user management of kernel extensions from identified developers
```

注意：在 Startup Security Utility 改選 `Reduced Security` 會重新啟用 SIP / Signed System Volume，撤銷前面的 `csrutil disable` / `csrutil authenticated-root disable`，導致 issue #3 中的 `Bad code signature` 和 `Operation not permitted` 問題。

重啟回 macOS。

建議同時準備：

```text
非中國 Apple ID
系統 Region = United States
Siri 語言 = English (United States)
非中國網絡出口
```

## 一鍵啟用

```bash
chmod +x enable_apple_intelligence_oneclick.sh
./enable_apple_intelligence_oneclick.sh
```

第一次載入 kext 時，如果系統提示阻止擴展：

```text
System Settings -> Privacy & Security -> 滑到底部 -> Allow
```

允許後重啟，再執行一次腳本或等待開機 loader 自動載入。

## 腳本會做什麼

```text
安裝 / 載入 CodexRegionSpoof.kext
安裝開機自動載入 LaunchDaemon
修正 Apple Intelligence eligibility domains
修正 Siri SAE availability
按出口 IP 寫入 GeoServices 定位國家
把 countryd cache 固定為 US
macOS 27+ 寫入 AppleInternalVariant.plist
macOS 27+ 寫入 EnhancedSiriWaitlist FeatureFlags override
macOS 27+ 修正 Enhanced Siri waitlist / CloudSubscriptionFeatures / GMS availability 狀態
macOS 27+ 安裝常駐 Enhanced Siri repair LaunchDaemon，開機後與 cloud cache 被覆寫時自動補回
保留 Siri Launchpad 圖標刷新
保留 Location Services 裡 Siri 圖標 runtime patch
保留 Siri / Safari 搜索 provider 切到 Google 並清理舊 Baidu 搜索
重啟 AI / Siri / modelcatalog 相關守護進程
```

## 常用參數

```bash
./enable_apple_intelligence_oneclick.sh status
./enable_apple_intelligence_oneclick.sh --verify-only
./enable_apple_intelligence_oneclick.sh --all
./enable_apple_intelligence_oneclick.sh --fix-siri-icon
./enable_apple_intelligence_oneclick.sh --force-geoservices-us
./enable_apple_intelligence_oneclick.sh uninstall
./enable_apple_intelligence_oneclick.sh uninstall --dry-run
```

跳過某些步驟：

```bash
--skip-kext
--skip-launchdaemon
--skip-eligibility
--skip-sae
--skip-location-ip
--skip-countryd
--skip-apple-internal
--skip-macos27-siri-ai
--skip-siri-location-icon
--skip-web-search
```

`--skip-launchdaemon` 會同時跳過開機載入 kext 的 loader 與 macOS 27+ Enhanced Siri repair daemon。

## 驗證

```bash
./enable_apple_intelligence_oneclick.sh --verify-only
```

理想狀態：

```text
region-info = LL/A
country-of-origin = USA
CodexRegionSpoof loaded
GREYMATTER / FOUNDATION_MODELS / PERSONAL_QA = 4
SiriAvailability.desiredOrchestrationMode = 4
ai.enhanced-siri canUse = true
Enhanced Siri waitlist status = active
Enhanced Siri unifiedReasons = []
```

也可以看：

```bash
sudo tail -100 /var/log/codex-region-spoof-loader.log
sudo tail -100 /var/log/codex-enhanced-siri-repair.stdout.log
ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei 'region-info|country-of-origin'
sudo kmutil showloaded | grep -Ei 'Codex|RegionSpoof'
```

如果重啟或聯網後又看到 `Siri Update in Progress` / 舊 Siri UI，可先看：

```bash
sudo tail -200 /var/log/codex-enhanced-siri-repair.stdout.log
sudo tail -200 /var/log/codex-enhanced-siri-repair.stderr.log
```

## 成功後測試

重啟後檢查：

```text
System Settings -> Apple Intelligence & Siri
Writing Tools
Image Playground
Photos Clean Up / 照片擦除
Siri 新界面
```

如果進入舊 Siri UI，但網絡工具裡看到 `generativeexperiencesd` / `modelcatalogd` / `assetd` / `mobileassetd` 有下載流量，等資源下載完成後重啟再看。

## 安全狀態建議

功能確認成功後，可以恢復到較高安全狀態：

```text
Authenticated Root: enabled
FileVault: on
Startup Security: Reduced Security
3rd Party Kexts: Enabled
Signed System Volume: Enabled
```

只建議做：

```bash
csrutil authenticated-root enable
```

以及打開 FileVault。

不要執行：

```bash
csrutil enable
```

原因：本方案仍依賴 ad-hoc kext 開機載入。SIP 完全開啟後，kext 可能無法載入，系統會回到中國 SKU 身份。

## 升級 macOS

如果 Software Update 提示 snapshot 不一致，先重啟一次。

仍然不行再執行：

```bash
sudo bless --mount / --last-sealed-snapshot --setBoot
sudo reboot
```

升級完成後重新檢查：

```bash
./enable_apple_intelligence_oneclick.sh --verify-only
```

如果狀態掉了，重新跑一鍵腳本。

## 卸載

```bash
./enable_apple_intelligence_oneclick.sh uninstall
```

卸載後重啟。若想完全恢復原廠最高安全狀態，再進 Recovery 設置：

```bash
csrutil enable
csrutil authenticated-root enable
```

並切回 Full Security。

## 已知問題

```text
macOS 27 beta：新 Siri AI 仍可能受額外 gate 影響，未完全穩定。
首次載入 kext：可能需要 Privacy & Security 裡手動 Allow，然後重啟。
模型資源：Apple Intelligence UI 出現不代表模型資源已下載完成。
Siri 圖標：如果仍是舊圖標，先重啟；必要時執行 --all 或 --fix-siri-icon。
```

## Credits

本項目參考並合併了多個方向的思路：

```text
kanshurichard/enableAppleAI 的 eligibility / countryd 方法
本 repo 的 macOS 26.5 / 26.5.1 實測補充
```
