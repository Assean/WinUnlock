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
    private var tokenCharacteristic: CBCharacteristic?

    private var isConnecting = false
    private var lastUnlockTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 15.0
    private let rssiThreshold: Int = -62

    @Published var isScanning: Bool = false
    @Published var showUnlockSheet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var autoBackgroundUnlock: Bool = true
    @Published var statusText: String = "正在初始化背景藍牙偵測..."

    override init() {
        super.init()
        setupNotifications()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // iOS 在背景或鎖屏偵測到筆電並喚醒 App 時呼叫
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
            startBackgroundScan()
        } else {
            isScanning = false
            statusText = "請開啟 iPhone 藍牙以啟用背景自動解鎖"
        }
    }

    func startBackgroundScan() {
        guard centralManager.state == .poweredOn else { return }
        // allowDuplicates: false 讓 iOS 硬體晶片在背景每次筆電進入範圍時主動喚醒 App
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.async {
            self.isScanning = true
            self.statusText = "背景偵測中（離開 App 或鎖屏仍會自動連線）"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal != 127, rssiVal >= rssiThreshold else { return }
        guard !isConnecting, Date().timeIntervalSince(lastUnlockTime) > cooldownSeconds else { return }

        isConnecting = true
        targetPeripheral = peripheral
        peripheral.delegate = self
        centralManager.stopScan()

        DispatchQueue.main.async {
            self.statusText = "偵測到筆電靠近 (\(rssiVal) dBm)，自動連線中..."
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
        lastUnlockTime = Date()
        DispatchQueue.main.async {
            let notifyGen = UINotificationFeedbackGenerator()
            notifyGen.notificationOccurred(.success)
            self.isUnlocked = true
            self.statusText = "已自動感應並解鎖 Windows 筆電"
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
        targetPeripheral = nil
        tokenCharacteristic = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.startBackgroundScan()
        }
    }
}
