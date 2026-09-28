import SwiftUI
import Combine

struct OTPView: View {
    @State var store: OTPStore
    var autoCopyOnAppear: Bool = false
    var onAddRequested: (() -> Void)?
    @State private var now = Date()
    @State private var copiedID: UUID?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            if store.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .frame(minWidth: 300, idealWidth: 330, minHeight: 380, idealHeight: 440)
        .liquidGlassBackground(cornerRadius: Design.radiusL)
        .ignoresSafeArea()
        .onReceive(timer) { now = $0 }
        .onAppear {
            if autoCopyOnAppear, let first = store.accounts.first,
               let code = store.code(for: first, at: Date()) {
                copyCode(code, id: first.id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Spacer().frame(width: 58)
            Image(systemName: "key.2").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("OTP 验证码").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { onAddRequested?() }) {
                Image(systemName: "plus").font(.system(size: 12))
            }.buttonStyle(.plain)
        }
        .frame(height: 32)
        .padding(.horizontal, 12)
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
        let elapsed = OTPService.timeRemaining(at: now)
        let countdown = 30 - elapsed
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
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "key.2").font(.system(size: 32)).foregroundStyle(.tertiary)
            Text("点击 + 添加 OTP 账户").font(.system(size: 13)).foregroundStyle(.secondary)
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
