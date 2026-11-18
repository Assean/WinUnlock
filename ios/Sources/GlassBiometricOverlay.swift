import SwiftUI
import LocalAuthentication

struct GlassBiometricOverlay: View {
    @Binding var isPresented: Bool
    var deviceName: String = "Sean 的 Windows 筆電"
    var onAuthenticated: () -> Void
    var onCancel: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var authError: String?
    @State private var isAuthenticating = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 78, height: 78)
                        .scaleEffect(pulseScale)

                    Image(systemName: "faceid")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.top, 6)

                VStack(spacing: 6) {
                    Text("安全解鎖驗證")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("偵測到「\(deviceName)」處於鎖定狀態\n請透過 Face ID 或 iPhone 密碼確認解鎖")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let err = authError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 12) {
                    Button(action: dismiss) {
                        Text("取消")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: triggerBiometricAuth) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill")
                            Text(isAuthenticating ? "驗證中..." : "立即驗證")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isAuthenticating)
                }
            }
            .padding(24)
            .frame(maxWidth: 330)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.65), .white.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 24)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulseScale = 1.12
            }
            if scenePhase == .active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    triggerBiometricAuth()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && isPresented && !isAuthenticating {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    triggerBiometricAuth()
                }
            }
        }
    }

    private func triggerBiometricAuth() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authError = nil

        let context = LAContext()
        context.localizedFallbackTitle = "使用 iPhone 密碼"
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            let reason = "驗證身分以自動解鎖你的 Windows 電腦"
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evalError in
                DispatchQueue.main.async {
                    self.isAuthenticating = false
                    if success {
                        let gen = UINotificationFeedbackGenerator()
                        gen.notificationOccurred(.success)
                        self.isPresented = false
                        self.onAuthenticated()
                    } else {
                        self.authError = evalError?.localizedDescription ?? "驗證未通過，請重試"
                    }
                }
            }
        } else {
            isAuthenticating = false
            authError = error?.localizedDescription ?? "此裝置未設定 Face ID 或螢幕鎖定密碼"
        }
    }

    private func dismiss() {
        isPresented = false
        onCancel()
    }
}
