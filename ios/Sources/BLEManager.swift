import Foundation
import CoreBluetooth
import CryptoKit
import UIKit
import UserNotifications

final class BLEManager: NSObject, ObservableObject, CBPeripheralManagerDelegate, UNUserNotificationCenterDelegate {
    private let serviceUUID     = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCDE")
    private let triggerCharUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCDF")
    private let tokenCharUUID   = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCE0")
    private let secretKey       = "MySuperSecretUnlockKey_2026"
    private let restoreID       = "com.sean.WinUnlock.peripheral"

    private var peripheralManager: CBPeripheralManager!
    private var tokenCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var pendingPayload: Data?

    @Published var isAdvertising: Bool = false
    @Published var showUnlockSheet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var statusText: String = "正在初始化藍牙信標..."

    override init() {
        super.init()
        setupNotifications()
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let unlockAction = UNNotificationAction(
            identifier: "UNLOCK_ACTION",
            title: "立即解鎖電腦",
            options: [.authenticationRequired]
        )
        let category = UNNotificationCategory(
            identifier: "WIN_UNLOCK_CATEGORY",
            actions: [unlockAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // 支援 iOS 背景狀態還原（系統喚醒 App 時必備）
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services {
                if let chars = service.characteristics as? [CBMutableCharacteristic] {
                    for char in chars where char.uuid == tokenCharUUID {
                        self.tokenCharacteristic = char
                    }
                }
            }
        }
        DispatchQueue.main.async {
            self.isAdvertising = peripheral.isAdvertising
            self.statusText = "背景藍牙信標運行中"
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            if !peripheral.isAdvertising {
                setupGattService()
            } else {
                isAdvertising = true
                statusText = "信標廣播中（支援背景感應）"
            }
        } else {
            isAdvertising = false
            statusText = "請開啟 iPhone 藍牙以啟用靠近解鎖"
        }
    }

    private func setupGattService() {
        let triggerChar = CBMutableCharacteristic(
            type: triggerCharUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )

        let tokenChar = CBMutableCharacteristic(
            type: tokenCharUUID,
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        self.tokenCharacteristic = tokenChar

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [triggerChar, tokenChar]

        peripheralManager.removeAllServices()
        peripheralManager.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else {
            statusText = "服務建立失敗: \(error!.localizedDescription)"
            return
        }
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "iPhone-UnlockKey"
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if error == nil {
            isAdvertising = true
            statusText = "信標廣播中（離開 App 仍可背景感應）"
        }
    }

    // 追蹤已連線並訂閱通知的 Windows 電腦
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        if let pending = pendingPayload, let tokenChar = tokenCharacteristic {
            if peripheral.updateValue(pending, for: tokenChar, onSubscribedCentrals: [central]) {
                pendingPayload = nil
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
    }

    // 收到 Windows 寫入 SHOW_POPUP 指令
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == triggerCharUUID,
               let data = request.value,
               let command = String(data: data, encoding: .utf8),
               command == "SHOW_POPUP" {
                DispatchQueue.main.async {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    self.isUnlocked = false

                    if UIApplication.shared.applicationState == .active {
                        self.showUnlockSheet = true
                    } else {
                        self.triggerBackgroundNotification()
                    }
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    private func triggerBackgroundNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Sean 的 Windows 筆電"
        content.body = "偵測到筆電靠近，點擊或長按此通知即可解鎖電腦"
        content.sound = .default
        content.categoryIdentifier = "WIN_UNLOCK_CATEGORY"

        let request = UNNotificationRequest(
            identifier: "WinUnlockPrompt",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // 使用者點擊背景通知或通知上的「立即解鎖電腦」按鈕
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "UNLOCK_ACTION" {
            sendUnlockCommand()
        } else {
            DispatchQueue.main.async {
                self.isUnlocked = false
                self.showUnlockSheet = true
            }
        }
        completionHandler()
    }

    func sendUnlockCommand() {
        guard let tokenChar = tokenCharacteristic else { return }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(timestamp.utf8), using: key)
        let hexSig = signature.map { String(format: "%02x", $0) }.joined()

        let payload = "\(timestamp)|\(hexSig)"
        guard let payloadData = payload.data(using: .utf8) else { return }

        let targets = subscribedCentrals.isEmpty ? nil : subscribedCentrals
        let sent = peripheralManager.updateValue(payloadData, for: tokenChar, onSubscribedCentrals: targets)
        if !sent {
            pendingPayload = payloadData
        }

        let notifyGen = UINotificationFeedbackGenerator()
        notifyGen.notificationOccurred(.success)
        isUnlocked = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showUnlockSheet = false
        }
    }

    // 若藍牙傳送佇列原本滿載，待可用時立刻補發
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let pending = pendingPayload, let tokenChar = tokenCharacteristic else { return }
        let targets = subscribedCentrals.isEmpty ? nil : subscribedCentrals
        if peripheral.updateValue(pending, for: tokenChar, onSubscribedCentrals: targets) {
            pendingPayload = nil
        }
    }
}
