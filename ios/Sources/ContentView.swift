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

                Toggle("靠近時在背景／鎖屏全自動解鎖", isOn: $bleManager.autoBackgroundUnlock)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button("立即連線測試") {
                        bleManager.manualConnectAndUnlock()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("預覽卡片") {
                        bleManager.isUnlocked = false
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
        }
        .sheet(isPresented: $bleManager.showUnlockSheet) {
            AirPodsUnlockSheet()
                .presentationDetents([.height(350)])
                .presentationCornerRadius(36)
                .presentationBackground(.ultraThinMaterial)
                .presentationDragIndicator(.hidden)
        }
    }
}

struct AirPodsUnlockSheet: View {
    @EnvironmentObject var bleManager: BLEManager
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Spacer()
                Text("Sean 的 Windows 筆電")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    bleManager.showUnlockSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 22)

            Text(bleManager.isUnlocked ? "已通過安全驗證並解鎖" : "偵測到裝置靠近，點擊下方按鈕解鎖")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            ZStack {
                Circle()
                    .fill(bleManager.isUnlocked ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                    .frame(width: 115, height: 115)
                    .scaleEffect(isPulsing ? 1.06 : 0.96)

                Image(systemName: bleManager.isUnlocked ? "lock.open.laptopcomputer" : "laptopcomputer")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(bleManager.isUnlocked ? .green : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }

            Spacer()

            Button {
                bleManager.sendUnlockCommand()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: bleManager.isUnlocked ? "checkmark.circle.fill" : "faceid")
                    Text(bleManager.isUnlocked ? "已解鎖" : "解鎖電腦")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(bleManager.isUnlocked ? Color.green : Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(bleManager.isUnlocked)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
    }
}
