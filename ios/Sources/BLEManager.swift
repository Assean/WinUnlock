@objc private func appDidEnterBackground() {
    addLog("進入背景：啟動持續 iBeacon + BLE 掃描")
    startScan(allowDuplicates: true)
}

func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard error == nil, let chars = service.characteristics else {
        disconnectAndCooldown()
        return
    }
    for char in chars where char.uuid == tokenCharUUID {
        self.tokenCharacteristic = char
        let isBackground = UIApplication.shared.applicationState != .active
        if self.autoBackgroundUnlock || isBackground {
            self.sendUnlockCommand()
        } else {
            DispatchQueue.main.async {
                let gen = UIImpactFeedbackGenerator(style: .medium)
                gen.impactOccurred()
                self.isUnlocked = false
                self.showUnlockSheet = true
            }
        }
    }
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