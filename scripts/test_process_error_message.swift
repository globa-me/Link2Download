import Foundation

@main
struct ProcessErrorMessageRegression {
    static func main() {
        let dns = "ERROR: \r[download] Got error: Failed to resolve googlevideo.com. Giving up after 5 retries\n"
        let message = ProcessErrorMessage.clean(stderr: dns, stdout: "__L2D_META__:hidden\n")
        precondition(message == "ERROR: [download] Got error: Failed to resolve googlevideo.com. Giving up after 5 retries")
        precondition(ProcessErrorMessage.clean(stderr: "ERROR:\r\n[download] Got error: DNS failed\n", stdout: "") == "[download] Got error: DNS failed")
        precondition(ProcessErrorMessage.clean(stderr: "ERROR: Download failed\n", stdout: "") == "ERROR: Download failed")
        precondition(ProcessErrorMessage.clean(stderr: "ERROR:\n", stdout: "") == "yt-dlp failed")
        print("PASS: yt-dlp carriage-return errors preserve the cause and hide internal markers")
    }
}
