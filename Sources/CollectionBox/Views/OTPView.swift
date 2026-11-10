import SwiftUI
import Combine

struct OTPView: View {
    @State var store: OTPStore
    var autoCopyOnAppear: Bool = false
    var onAddRequested: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onAddingStateChanged: ((Bool) -> Void)? = nil
    @State private var now = Date()
    @State private var copiedID: UUID?
    @State private var isAddingAccount = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if isAddingAccount {
                AddOTPView(
                    isPresented: $isAddingAccount,
                    onAdd: { account in
                        store.addAccount(account)
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isAddingAccount = false
                        }
                    },
                    embedded: true
                )
                .transition(.opacity)
            } else if store.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .frame(minWidth: 300, idealWidth: 330, minHeight: 380, idealHeight: 440)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .onReceive(timer) { now = $0 }
        .onChange(of: isAddingAccount) { _, newValue in
            onAddingStateChanged?(newValue)
        }
        .onAppear {
            if autoCopyOnAppear, let first = store.accounts.first,
               let code = store.code(for: first, at: Date()) {
                copyCode(code, id: first.id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if isAddingAccount {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddingAccount = false
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("返回验证码列表")
            }

            Image(systemName: "key.2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(isAddingAccount ? "添加 OTP 账户" : "OTP 验证码").font(.system(size: 14, weight: .bold))
            Spacer()

            if !isAddingAccount {
                Button(action: {
                    if let onAddRequested = onAddRequested {
                        onAddRequested()
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isAddingAccount = true
                        }
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("添加验证码")
            }

            PanelCloseButton(helpText: "关闭面板 (⎋)") {
                onClose?()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Account List

    private var accountList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func accountRow(_ account: OTPAccount) -> some View {
        let code = store.code(for: account, at: now) ?? "------"
        let remaining = OTPService.timeRemaining(at: now)
        let countdown = remaining
        let progress = Double(countdown) / 30.0
        let isCopied = copiedID == account.id
        let isUrgent = countdown <= 10

        return VStack(spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    if !account.issuer.isEmpty {
                        Text(account.issuer).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    Text(account.name).font(.system(size: Design.body, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: { copyCode(code, id: account.id) }) {
                    HStack(spacing: 5) {
                        Text(code)
                            .font(.system(size: 19, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isCopied ? .green : isUrgent ? .red : .primary)
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(isCopied ? 0.15 : 0.08), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text("\(countdown)s").font(.system(size: Design.micro, weight: .medium)).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12)).frame(height: 4)
                        RoundedRectangle(cornerRadius: 2).fill(isUrgent ? Color.red : Color.accentColor)
                            .frame(width: geo.size.width * progress, height: 4)
                            .animation(.linear(duration: 1), value: progress)
                    }
                }.frame(height: 4)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .liquidGlassCard(cornerRadius: Design.radiusM)
        .contextMenu {
            Button("复制验证码") { copyCode(code, id: account.id) }
            Divider()
            Button("删除", role: .destructive) {
                store.removeAccount(account.id)
                Haptics.levelChange()
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "key.2").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("暂无 OTP 账户").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("添加账户") {
                if let onAddRequested = onAddRequested {
                    onAddRequested()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddingAccount = true
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
    }

    // MARK: - Actions

    private func copyCode(_ code: String, id: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Haptics.success()
        withAnimation { copiedID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { withAnimation { copiedID = nil } }
        }
    }
}
