import Foundation
import CoreBluetooth
import CoreLocation
import CryptoKit
import UIKit
import UserNotifications

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    private let serviceUUID   = CBUUID(string: "FFF0")
    private let tokenCharUUID = CBUUID(string: "FFF1")
    private let beaconUUID    = UUID(uuidString: "A1B2C3D4-E5F6-4789-8012-3456789ABCDE")!
    private let secretKey     = "MySuperSecretUnlockKey_2026"
    private let restoreID     = "com.sean.WinUnlock.central.v7"

    private var centralManager: CBCentralManager!
    private let locationManager = CLLocationManager()
    private var targetPeripheral: CBPeripheral?
    private var lastDiscoveredPeripheral: CBPeripheral?
    private var tokenCharacteristic: CBCharacteristic?
    private var connectTimeoutWorkItem: DispatchWorkItem?

    private var isConnecting = false
    private var lastUnlockTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 12.0
    private let foregroundRssiThreshold: Int = -75
    private let backgroundRssiThreshold: Int = -90

    @Published var isScanning: Bool = false
    @Published var showUnlockSheet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var autoBackgroundUnlock: Bool = true
    @Published var statusText: String = "正在初始化 iBeacon 鎖屏感應..."
    @Published var detectedInfo: String = "尚未偵測到筆電信標"
    @Published var eventLogs: [String] = []

    override init() {
        super.init()
        setupNotifications()
        setupBeaconMonitoring()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    private func setupBeaconMonitoring() {
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()

        let region = CLBeaconRegion(uuid: beaconUUID, identifier: "WinUnlockBeacon")
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true
        locationManager.startMonitoring(for: region)
        locationManager.requestState(for: region)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            let region = CLBeaconRegion(uuid: beaconUUID, identifier: "WinUnlockBeacon")
            region.notifyEntryStateOnDisplay = true
            locationManager.startMonitoring(for: region)
            locationManager.requestState(for: region)
        }
    }

    // iPhone 在黑屏鎖定或螢幕亮起時，只要靠近筆電 iBeacon 就會被硬體瞬間喚醒
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        addLog("iBeacon 硬體喚醒：進入筆電感應範圍！")
        triggerActiveWakeScan()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside {
            addLog("iBeacon 狀態確認：位於筆電旁，啟動連線")
            triggerActiveWakeScan()
        }
    }

    private func triggerActiveWakeScan() {
        guard centralManager.state == .poweredOn else { return }
        guard !isConnecting, Date().timeIntervalSince(lastUnlockTime) > cooldownSeconds else { return }
        // 取得約 10 秒背景執行權限後，立即開啟主動掃描抓取 FFF0 並連線
        startScan(allowDuplicates: true)
    }

    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))] \(message)"
        DispatchQueue.main.async {
            self.eventLogs.insert(entry, at: 0)
            if self.eventLogs.count > 8 {
                self.eventLogs.removeLast()
            }
        }
    }

    @objc private func appDidEnterBackground() {
        addLog("進入鎖屏／背景，iBeacon 硬體監聽待機中")
        startScan(allowDuplicates: true)
    }

    @objc private func appWillEnterForeground() {
        addLog("回到前台模式")
        startScan(allowDuplicates: true)
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        addLog("CoreBluetooth 背景狀態還原")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = peripherals.first {
            self.targetPeripheral = first
            first.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            let isForeground = UIApplication.shared.applicationState == .active
            startScan(allowDuplicates: isForeground)
        } else {
            isScanning = false
            statusText = "請開啟 iPhone 藍牙以啟用鎖屏解鎖"
        }
    }

    func startScan(allowDuplicates: Bool) {
        guard centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        DispatchQueue.main.async {
            self.isScanning = true
            self.statusText = "iBeacon + BLE 雙引擎監聽中"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal != 127 else { return }
        self.lastDiscoveredPeripheral = peripheral

        let isBackground = UIApplication.shared.applicationState != .active
        let threshold = isBackground ? backgroundRssiThreshold : foregroundRssiThreshold

        if !isBackground {
            DispatchQueue.main.async {
                self.detectedInfo = "已偵測到筆電信標（訊號：\(rssiVal) dBm）"
            }
        }

        guard rssiVal >= threshold else { return }
        guard !isConnecting, Date().timeIntervalSince(lastUnlockTime) > cooldownSeconds else { return }

        addLog("\(isBackground ? "鎖屏喚醒" : "前台")連線筆電 (\(rssiVal) dBm)")
        connectToPeripheral(peripheral)
    }

    func manualConnectAndUnlock() {
        guard let p = lastDiscoveredPeripheral else {
            DispatchQueue.main.async {
                self.detectedInfo = "目前尚未掃描到筆電，請確認電腦端已啟動廣播"
            }
            return
        }
        addLog("手動觸發連線測試")
        connectToPeripheral(p)
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        isConnecting = true
        targetPeripheral = peripheral
        peripheral.delegate = self
        centralManager.stopScan()

        DispatchQueue.main.async {
            self.statusText = "正在連線至 Windows 筆電..."
        }

        connectTimeoutWorkItem?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isConnecting else { return }
            self.addLog("連線逾時，重置掃描")
            self.disconnectAndCooldown()
        }
        connectTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeoutItem)

        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        addLog("連線失敗: \(error?.localizedDescription ?? "未知原因")")
        resetAndRescan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        isConnecting = false
        targetPeripheral = nil
        tokenCharacteristic = nil
        let remaining = max(1.0, cooldownSeconds - Date().timeIntervalSince(lastUnlockTime))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.startScan(allowDuplicates: true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            disconnectAndCooldown()
            return
        }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([tokenCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            disconnectAndCooldown()
            return
        }
        for char in chars where char.uuid == tokenCharUUID {
            self.tokenCharacteristic = char
            DispatchQueue.main.async {
                if self.autoBackgroundUnlock || UIApplication.shared.applicationState != .active {
                    self.sendUnlockCommand()
                } else {
                    let gen = UIImpactFeedbackGenerator(style: .medium)
                    gen.impactOccurred()
                    self.isUnlocked = false
                    self.showUnlockSheet = true
                }
            }
        }
    }

    func sendUnlockCommand() {
        guard let peripheral = targetPeripheral, let tokenChar = tokenCharacteristic else { return }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(timestamp.utf8), using: key)
        let hexSig = signature.map { String(format: "%02x", $0) }.joined()

        let payload = "\(timestamp)|\(hexSig)"
        if let payloadData = payload.data(using: .utf8) {
            peripheral.writeValue(payloadData, for: tokenChar, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            addLog("寫入簽章失敗: \(error.localizedDescription)")
            disconnectAndCooldown()
            return
        }
        lastUnlockTime = Date()
        addLog("已成功寫入加密解鎖簽章！")
        DispatchQueue.main.async {
            let notifyGen = UINotificationFeedbackGenerator()
            notifyGen.notificationOccurred(.success)
            self.isUnlocked = true
            self.statusText = "已成功感應並解鎖 Windows 筆電"
            self.sendUnlockedNotification()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.showUnlockSheet = false
            }
        }
        disconnectAndCooldown()
    }

    private func sendUnlockedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Sean 的 Windows 筆電"
        content.body = "已在鎖屏／背景自動感應並完成安全解鎖"
        content.sound = .default
        let req = UNNotificationRequest(identifier: "WinUnlockSuccess", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func disconnectAndCooldown() {
        if let p = targetPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        resetAndRescan()
    }

    private func resetAndRescan() {
        isConnecting = false
        targetPeripheral = nil
        tokenCharacteristic = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let isForeground = UIApplication.shared.applicationState == .active
            self.startScan(allowDuplicates: isForeground)
        }
    }
}

