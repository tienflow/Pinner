import SwiftUI
import AppKit

struct AddOTPView: View {
    @Binding var isPresented: Bool
    var onAdd: (OTPAccount) -> Void

    @State private var uriInput = ""
    @State private var errorMessage = ""
    @State private var mode: AddMode = .uri

    enum AddMode { case uri, scanner }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("添加 OTP 账户").font(.headline)
                Spacer()
                Picker("", selection: $mode) {
                    Text("粘贴 URI").tag(AddMode.uri)
                    Text("扫描二维码").tag(AddMode.scanner)
                }.pickerStyle(.segmented).frame(width: 180)
            }

            if mode == .uri {
                uriInputView
            } else {
                QRScannerView { uri in handleScannedURI(uri) }
            }

            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if mode == .uri {
                    Button("添加") { addAccount() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(uriInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 420, height: mode == .scanner ? 280 : 160)
    }

    private var uriInputView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("粘贴 otpauth:// URI").font(.caption).foregroundStyle(.secondary)
            NativeTextField(text: $uriInput, placeholder: "otpauth://totp/...")
                .frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func addAccount() {
        let trimmed = uriInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = OTPService.parseOTPAuthURI(trimmed) else {
            errorMessage = "无法解析 URI，请检查格式"
            return
        }
        onAdd(OTPAccount(name: parsed.name, secret: parsed.secret, issuer: parsed.issuer))
        isPresented = false
    }

    private func handleScannedURI(_ uri: String) {
        guard let parsed = OTPService.parseOTPAuthURI(uri) else {
            errorMessage = "图片中的二维码不是有效的 otpauth:// URI"
            mode = .uri
            return
        }
        onAdd(OTPAccount(name: parsed.name, secret: parsed.secret, issuer: parsed.issuer))
        isPresented = false
    }
}

// MARK: - Native NSTextField

struct NativeTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = false
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.delegate = context.coordinator
        tf.stringValue = text
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        init(_ parent: NativeTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { parent.text = tf.stringValue }
        }
    }
}
