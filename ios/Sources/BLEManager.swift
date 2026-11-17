import Foundation
import CoreBluetooth
import CryptoKit
import UIKit
import UserNotifications

final class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, UNUserNotificationCenterDelegate {
    private let serviceUUID   = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCDE")
    private let tokenCharUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCE0")
    private let secretKey     = "MySuperSecretUnlockKey_2026"
    private let restoreID     = "com.sean.WinUnlock.central"

    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var lastDiscoveredPeripheral: CBPeripheral?
    private var tokenCharacteristic: CBCharacteristic?

    private var isConnecting = false
    private var shouldCheckRssiAfterConnect = false
    private var rssiRetryCount = 0
    private let maxRssiRetries = 15

    private var lastUnlockTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 12.0
    private let rssiThreshold: Int = -75

    @Published var isScanning: Bool = false
    @Published var showUnlockSheet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var autoBackgroundUnlock: Bool = true
    @Published var statusText: String = "正在初始化背景藍牙偵測..."
    @Published var detectedInfo: String = "尚未偵測到筆電信標"

    override init() {
        super.init()
        setupNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    @objc private func appDidEnterBackground() {
        startScan(allowDuplicates: false)
    }

    @objc private func appWillEnterForeground() {
        startScan(allowDuplicates: true)
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = peripherals.first {
            self.targetPeripheral = first
            first.delegate = self
        }
        DispatchQueue.main.async {
            self.isScanning = true
            self.statusText = "背景自動感應運行中"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            let isForeground = UIApplication.shared.applicationState == .active
            startScan(allowDuplicates: isForeground)
        } else {
            isScanning = false
            statusText = "請開啟 iPhone 藍牙以啟用背景自動解鎖"
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
            self.statusText = "偵測中（觸發門檻: \(self.rssiThreshold) dBm）"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal != 127 else { return }
        self.lastDiscoveredPeripheral = peripheral

        let isBackground = UIApplication.shared.applicationState != .active
        if !isBackground {
            DispatchQueue.main.async {
                self.detectedInfo = "已偵測到筆電信標（訊號：\(rssiVal) dBm）"
            }
            // 前台連續掃描時，直接在發現階段過濾距離
            guard rssiVal >= rssiThreshold else { return }
        }

        // 背景／鎖屏狀態下因 iOS 只觸發一次 didDiscover，必須直接連線後再透過 readRSSI 測距
        guard !isConnecting, Date().timeIntervalSince(lastUnlockTime) > cooldownSeconds else { return }
        connectToPeripheral(peripheral, checkRssiAfterConnect: isBackground)
    }

    func manualConnectAndUnlock() {
        guard let p = lastDiscoveredPeripheral else {
            DispatchQueue.main.async {
                self.detectedInfo = "目前尚未掃描到筆電，請確認電腦端已啟動廣播"
            }
            return
        }
        connectToPeripheral(p, checkRssiAfterConnect: false)
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral, checkRssiAfterConnect: Bool) {
        isConnecting = true
        shouldCheckRssiAfterConnect = checkRssiAfterConnect
        targetPeripheral = peripheral
        peripheral.delegate = self
        centralManager.stopScan()

        DispatchQueue.main.async {
            self.statusText = "正在連線至 Windows 筆電..."
        }
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        resetAndRescan()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetAndRescan()
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
            if self.shouldCheckRssiAfterConnect {
                self.rssiRetryCount = 0
                peripheral.readRSSI()
            } else {
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
    }

    // 連線後在背景持續讀取即時訊號強度，達標即自動解鎖
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else {
            disconnectAndCooldown()
            return
        }
        let currentRssi = RSSI.intValue
        if currentRssi != 127 && currentRssi >= rssiThreshold {
            sendUnlockCommand()
        } else if rssiRetryCount < maxRssiRetries {
            rssiRetryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, self.targetPeripheral?.state == .connected else { return }
                peripheral.readRSSI()
            }
        } else {
            disconnectAndCooldown()
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
        lastUnlockTime = Date()
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
        content.body = "已在背景自動感應並完成安全解鎖"
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
        shouldCheckRssiAfterConnect = false
        targetPeripheral = nil
        tokenCharacteristic = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let isForeground = UIApplication.shared.applicationState == .active
            self.startScan(allowDuplicates: isForeground)
        }
    }
}
