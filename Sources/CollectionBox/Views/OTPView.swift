import SwiftUI

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
            Divider()
            if store.accounts.isEmpty {
                emptyState
            } else {
                accountList
            }
        }
        .frame(minWidth: 260, idealWidth: 280, minHeight: 360, idealHeight: 400)
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
            Image(systemName: "key.2").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("OTP 验证码").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { onAddRequested?() }) {
                Image(systemName: "plus").font(.system(size: 12))
            }.buttonStyle(.plain)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Account List

    private var accountList: some View {
        List { ForEach(store.accounts) { account in
            accountRow(account)
        }}
        .listStyle(.plain)
    }

    private func accountRow(_ account: OTPAccount) -> some View {
        let code = store.code(for: account, at: now) ?? "------"
        let elapsed = OTPService.timeRemaining(at: now)
        let countdown = 30 - elapsed
        let progress = Double(countdown) / 30.0
        let isCopied = copiedID == account.id
        let isUrgent = countdown <= 10

        return VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if !account.issuer.isEmpty {
                        Text(account.issuer).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text(account.name).font(.system(size: Design.body, weight: .medium)).lineLimit(1)
                }
                Spacer()
                Button(action: { copyCode(code, id: account.id) }) {
                    HStack(spacing: 4) {
                        Text(code)
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(isCopied ? .green : isUrgent ? .red : .primary)
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(isCopied ? .green : .secondary)
                    }
                }.buttonStyle(.plain)
            }
            HStack {
                Text("\(countdown)s").font(.system(size: Design.micro)).foregroundStyle(.secondary)
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
        .padding(.vertical, 4).padding(.horizontal, 4)
        .contextMenu {
            Button("复制验证码") { copyCode(code, id: account.id) }
            Divider()
            Button("删除", role: .destructive) { store.removeAccount(account.id) }
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
        withAnimation { copiedID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == id { withAnimation { copiedID = nil } }
        }
    }
}
