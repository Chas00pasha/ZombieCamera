import Foundation

enum CameraHandshake {
    static func buildCommand(config: CameraConfig) -> String {
        let credentials = "\(config.username):\(config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()

        var content = "Cseq: 1\r\n"
        content += "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n"

        var request = "GET http://\(config.host):\(config.port)/livestream.cgi?stream=\(config.stream)&action=play&media=\(config.media) HTTP/1.1\r\n"
        request += "Connection: Keep-Alive\r\n"
        request += "Cache-Control: no-cache\r\n"
        request += "Authorization: Basic \(encoded)\r\n"
        request += "Content-Length: \(content.utf8.count)\r\n"
        request += "\r\n"
        request += content
        return request
    }
}
