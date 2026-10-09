// 文字列を QR コードとしてターミナルに表示する（Xcode 付属の Swift だけで動く。追加インストール不要）。
// 使い方: swift scripts/qr_terminal.swift "<文字列>"
import CoreImage
import Foundation

guard CommandLine.arguments.count > 1, let data = CommandLine.arguments[1].data(using: .utf8) else {
    FileHandle.standardError.write(Data("usage: qr_terminal.swift <text>\n".utf8)); exit(2)
}
guard let filter = CIFilter(name: "CIQRCodeGenerator") else { exit(1) }
filter.setValue(data, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
guard let image = filter.outputImage else { exit(1) }

let rect = image.extent.integral
let width = Int(rect.width), height = Int(rect.height)
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let context = CIContext(options: [.useSoftwareRenderer: true])
context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

let quiet = 2   // white border (modules)
func dark(_ x: Int, _ y: Int) -> Bool {
    if x < 0 || y < 0 || x >= width || y >= height { return false }
    return pixels[(y * width + x) * 4] < 128      // CoreImage's row 0 is the top in this bitmap
}
// Two module rows per text line using "▀": foreground = upper module, background = lower module.
var out = ""
var y = -quiet
while y < height + quiet {
    for x in -quiet..<(width + quiet) {
        let top = dark(x, y), bottom = dark(x, y + 1)
        out += "\u{1B}[\(top ? 30 : 97);\(bottom ? 40 : 107)m▀"
    }
    out += "\u{1B}[0m\n"
    y += 2
}
print(out, terminator: "")
