import SwiftUI
import AppKit

struct AddOTPView: View {
    @Binding var isPresented: Bool
    var onAdd: (OTPAccount) -> Void
    var embedded: Bool = false

    @State private var uriInput = ""
    @State private var errorMessage = ""
    @State private var mode: AddMode = .uri

    enum AddMode { case uri, scanner }

    var body: some View {
        Group {
            if embedded {
                content
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                content
                    .padding(20)
                    .liquidGlassBackground()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: some View {
        VStack(spacing: 14) {
            if !embedded {
                standaloneHeader
            }

            Picker("", selection: $mode) {
                Text("粘贴 URI").tag(AddMode.uri)
                Text("扫描二维码").tag(AddMode.scanner)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)

            if mode == .uri {
                uriInputView
            } else {
                QRScannerView { uri in handleScannedURI(uri) }
            }

            Spacer(minLength: 0)

            footer
        }
    }

    private var standaloneHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
            Text("添加 OTP 账户").font(.system(size: 14, weight: .bold))
            Spacer()
            PanelCloseButton(helpText: "关闭窗口 (⎋)") { isPresented = false }
        }
    }

    private var footer: some View {
        HStack {
            Button("取消") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if mode == .uri {
                Button("添加") { addAccount() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(uriInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var uriInputView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("粘贴 otpauth:// URI").font(.system(size: Design.caption)).foregroundStyle(.secondary)
            NativeTextField(text: $uriInput, placeholder: "otpauth://totp/...", autoFocus: true, onSubmit: { addAccount() })
                .frame(height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.system(size: Design.caption)).foregroundStyle(.red)
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
    var autoFocus: Bool = false
    var onSubmit: (() -> Void)?

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
        if autoFocus {
            DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        }
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

        /// Return key inside the field fires the submit callback instead of
        /// inserting a newline.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == Selector(("insertNewline:")), let onSubmit = parent.onSubmit {
                onSubmit()
                return true
            }
            return false
        }
    }
}
