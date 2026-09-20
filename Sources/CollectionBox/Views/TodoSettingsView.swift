import SwiftUI
import AppKit

/// LLM configuration form for the todo quick-capture feature.
struct TodoSettingsView: View {
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var model: String = ""
    @State private var testResult: TestResult?
    @State private var isTesting = false

    private enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    private let store = TodoSettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("待办原文将发送至所配置端点。用于把一句话解析成「标题 + 到期 + 优先级 + 列表」。")
                .font(.system(size: Design.caption))
                .foregroundStyle(.secondary)

            field(label: "Base URL") {
                TextField("https://api.example.com/v1", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Design.body))
            }

            field(label: "API Key") {
                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Design.body))
            }

            field(label: "模型名") {
                TextField("gpt-4o-mini", text: $model)
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

            Text("提示：海外端点需在 macOS 系统设置中开启系统代理；Base URL 通常以 /v1 结尾。")
                .font(.system(size: Design.micro))
                .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 440, height: 265)
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
        let config = store.config
        baseURL = config.baseURL
        apiKey = config.apiKey
        model = config.model
    }

    private func save() {
        store.config = TodoLLMConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        testResult = .success("已保存")
    }

    /// Sends a fixed prompt to verify 200 + parseable response.
    private func testConnection() {
        let config = TodoLLMConfig(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !config.baseURL.isEmpty, !config.apiKey.isEmpty, !config.model.isEmpty else {
            testResult = .failure("请先填齐三项配置")
            return
        }
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            let client = TodoLLMClient(timeout: 30)
            let context = TodoPromptContext(input: "明早九点提醒我开会", now: Date(), lists: ["提醒事项", "工作", "购物"], lastList: nil)
            do {
                let result = try await client.parse(context: context, config: config)
                if let result, !result.title.isEmpty {
                    testResult = .success("连接成功，模型响应正常")
                } else {
                    testResult = .failure("响应无法解析为待办格式")
                }
            } catch {
                let nsError = error as NSError
                if nsError.code == NSURLErrorTimedOut || error.localizedDescription.contains("timed out") || error.localizedDescription.contains("超时") {
                    testResult = .failure("请求超时（30s）。若为海外端点请检查系统代理，或核对端点连通性")
                } else {
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }
}