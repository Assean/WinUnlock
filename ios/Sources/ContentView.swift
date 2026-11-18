import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bleManager: BLEManager

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: bleManager.isScanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 48))
                    .foregroundStyle(bleManager.isScanning ? .blue : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: bleManager.isScanning)
                    .padding(.top, 12)

                VStack(spacing: 6) {
                    Text("WinUnlock 背景藍牙鑰匙")
                        .font(.title2.bold())
                    Text(bleManager.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(bleManager.detectedInfo)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                        .padding(.top, 2)
                }

                Toggle("偵測到筆電時強制生物辨識驗證", isOn: $bleManager.autoBackgroundUnlock)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button("立即連線測試") {
                        bleManager.manualConnectAndUnlock()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("預覽驗證視窗") {
                        bleManager.isUnlocked = false
                        bleManager.isPreviewMode = true
                        bleManager.showUnlockSheet = true
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("背景連線紀錄")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if bleManager.eventLogs.isEmpty {
                                Text("尚無紀錄，鎖屏後重啟電腦廣播即可觀察...")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(bleManager.eventLogs, id: \.self) { log in
                                    Text(log)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 24)
            }

            if bleManager.showUnlockSheet {
                GlassBiometricOverlay(
                    isPresented: $bleManager.showUnlockSheet,
                    deviceName: "Sean 的 Windows 筆電",
                    onAuthenticated: {
                        if bleManager.isPreviewMode {
                            bleManager.isPreviewMode = false
                            bleManager.isUnlocked = true
                            bleManager.statusText = "Face ID / 密碼預覽驗證成功"
                        } else {
                            bleManager.sendUnlockCommand()
                        }
                    },
                    onCancel: {
                        if bleManager.isPreviewMode {
                            bleManager.isPreviewMode = false
                        } else {
                            bleManager.cancelBiometricUnlock()
                        }
                    }
                )
                .zIndex(99)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: bleManager.showUnlockSheet)
    }
}
