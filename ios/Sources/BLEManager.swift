import Foundation
import CoreBluetooth
import CryptoKit
import UIKit

final class BLEManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    private let serviceUUID     = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCDE")
    private let triggerCharUUID = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCDF")
    private let tokenCharUUID   = CBUUID(string: "A1B2C3D4-E5F6-4789-8012-3456789ABCE0")
    private let secretKey       = "MySuperSecretUnlockKey_2026"

    private var peripheralManager: CBPeripheralManager!
    private var tokenCharacteristic: CBMutableCharacteristic?

    @Published var isAdvertising: Bool = false
    @Published var showUnlockSheet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var statusText: String = "正在初始化藍牙信標..."

    override init() {
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            setupGattService()
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
            statusText = "信標廣播中，靠近 Windows 筆電自動感應"
        }
    }

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
                    self.showUnlockSheet = true
                }
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func sendUnlockCommand() {
        guard let tokenChar = tokenCharacteristic else { return }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let key = SymmetricKey(data: Data(secretKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(timestamp.utf8), using: key)
        let hexSig = signature.map { String(format: "%02x", $0) }.joined()

        let payload = "\(timestamp)|\(hexSig)"
        if let payloadData = payload.data(using: .utf8) {
            peripheralManager.updateValue(payloadData, for: tokenChar, onSubscribedCentrals: nil)
        }

        let notifyGen = UINotificationFeedbackGenerator()
        notifyGen.notificationOccurred(.success)
        isUnlocked = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showUnlockSheet = false
        }
    }
}
