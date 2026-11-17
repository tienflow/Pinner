import SwiftUI
import AppKit

/// Configuration form for the decision model (Jev System One protocol) used by fleeting routing.
public struct JevSettingsView: View {
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专用于「闪念投递」的高精度决策模型。毫秒级判定备忘录分类与已有笔记，零幻觉精准匹配。")
                .font(.system(size: Design.caption))
                .foregroundStyle(.secondary)

            field(label: "Base URL") {
                TextField(TypeSafeJevClient.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Design.body))
            }

            field(label: "API Key") {
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Design.body))
            }

            field(label: "模型名") {
                TextField(TypeSafeJevClient.defaultModel, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Design.body))
            }

            HStack(spacing: 8) {
                Button("测试连接") { testConnection() }
                    .disabled(isTesting)
                if isTesting {
                    ProgressView().controlSize(.small)
                }
                if let testResult {
                    resultRow(testResult)
                }
                Spacer()
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)

            Text("提示：若留空，默认自动探测系统环境变量 TYPESAFE_API_KEY 或本地已有的 TypeSafe 配置。")
                .font(.system(size: Design.micro))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: Design.ui)).foregroundStyle(.secondary)
            content()
        }
    }

    private func resultRow(_ result: TestResult) -> some View {
        Group {
            switch result {
            case .success(let msg):
                Label(msg, systemImage: "checkmark.circle.fill")
                    .font(.system(size: Design.caption))
                    .foregroundStyle(.green)
            case .failure(let msg):
                Label(msg, systemImage: "exclamationmark.circle")
                    .font(.system(size: Design.caption))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private func load() {
        let defaults = UserDefaults.standard
        let udKey = defaults.string(forKey: "TypeSafe.apiKey")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let udURL = defaults.string(forKey: "TypeSafe.baseURL")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let udModel = defaults.string(forKey: "TypeSafe.model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !udKey.isEmpty {
            apiKey = udKey
            baseURL = udURL.isEmpty ? TypeSafeJevClient.defaultBaseURL : udURL
            model = udModel.isEmpty ? TypeSafeJevClient.defaultModel : udModel
        } else if let resolved = TypeSafeJevClient.resolveConfig() {
            apiKey = resolved.apiKey
            baseURL = resolved.baseURL
            model = resolved.model
        } else {
            baseURL = TypeSafeJevClient.defaultBaseURL
            model = TypeSafeJevClient.defaultModel
        }
    }

    private func save() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        UserDefaults.standard.set(trimmedKey, forKey: "TypeSafe.apiKey")
        UserDefaults.standard.set(trimmedURL.isEmpty ? TypeSafeJevClient.defaultBaseURL : trimmedURL, forKey: "TypeSafe.baseURL")
        UserDefaults.standard.set(trimmedModel.isEmpty ? TypeSafeJevClient.defaultModel : trimmedModel, forKey: "TypeSafe.model")
        testResult = .success("Jev 配置已保存")
    }

    private func testConnection() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            testResult = .failure("请先填写 API Key")
            return
        }

        isTesting = true
        testResult = nil

        Task {
            defer { isTesting = false }
            do {
                let msg = try await TypeSafeJevClient.testConnection(
                    baseURL: trimmedURL.isEmpty ? TypeSafeJevClient.defaultBaseURL : trimmedURL,
                    apiKey: trimmedKey,
                    model: trimmedModel.isEmpty ? TypeSafeJevClient.defaultModel : trimmedModel
                )
                testResult = .success(msg)
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}
