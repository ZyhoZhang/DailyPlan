import SwiftUI
import Combine

/// Brief, non-blocking status messages. Deliberately not an alert sheet —
/// nothing in this app should ever block the UI waiting for a click.
@MainActor
final class Toast: ObservableObject {
    static let shared = Toast()

    @Published var message: String?
    @Published var isError = false

    private var clearTask: Task<Void, Never>?

    static func show(_ message: String, isError: Bool = false) {
        Task { @MainActor in shared.present(message, isError: isError) }
    }

    private func present(_ message: String, isError: Bool) {
        self.message = message
        self.isError = isError
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 4 : 2))
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }
}

struct ToastView: View {
    @ObservedObject private var toast = Toast.shared

    var body: some View {
        if let message = toast.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(toast.isError ? Color(red: 0.5, green: 0.11, blue: 0.11)
                                          : Color(white: 0.1),
                            in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.18), value: toast.message)
        }
    }
}
