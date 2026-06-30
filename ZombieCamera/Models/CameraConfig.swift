import Foundation

struct CameraConfig: Equatable {
    var host: String = "192.168.1.88"
    var port: Int = 80
    var stream: Int = 12
    var username: String = "admin"
    var password: String = "admin"
    var media: String = "video_audio_data"
}
