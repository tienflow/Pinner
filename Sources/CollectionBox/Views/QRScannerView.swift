import SwiftUI
import AppKit
import CoreImage

/// File picker that reads a QR code image and extracts the URI.
struct QRScannerView: View {
    var onCodeFound: (String) -> Void
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("选择包含二维码的图片").font(.system(size: 13)).foregroundStyle(.secondary)
            Button("选择图片…") { pickImage() }
                .buttonStyle(.bordered)
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择包含 OTP 二维码的图片"
        panel.prompt = "选择"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let image = NSImage(contentsOf: url),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let ciImage = CIImage(bitmapImageRep: bitmap) else {
            errorMessage = "无法读取图片"
            return
        }

        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ciImage) as? [CIQRCodeFeature]

        guard let first = features?.first, let uri = first.messageString else {
            errorMessage = "图片中未识别到二维码"
            return
        }

        onCodeFound(uri)
    }
}
