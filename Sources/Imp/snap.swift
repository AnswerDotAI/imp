import AVFoundation

/// Camera capture lives here in Swift rather than in macmage: the grant flows to any child,
/// but AVCapturePhotoOutput's running-session-plus-delegate dance does not translate well.
final class SnapDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let done = Box(false)
    let data = Box<Data?>(nil)
    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto p: AVCapturePhoto, error: Error?) {
        data.v = p.fileDataRepresentation()
        done.v = true
    }
}

func snap(_ path: String) -> Int32 {
    guard let dev = AVCaptureDevice.default(for: .video) else { print("no camera"); return 1 }
    let sess = AVCaptureSession(), outp = AVCapturePhotoOutput(), del = SnapDelegate()
    do { sess.addInput(try AVCaptureDeviceInput(device: dev)) }
    catch { print("input failed: \(error)"); return 1 }
    sess.addOutput(outp)
    sess.startRunning()
    Thread.sleep(forTimeInterval: 1.0)  // the first frames are dark while exposure settles
    outp.capturePhoto(with: AVCapturePhotoSettings(), delegate: del)
    // The delegate may be served by the main queue, so run the loop rather than block on a semaphore
    let deadline = Date().addingTimeInterval(10)
    while !del.done.v && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
    sess.stopRunning()
    guard let d = del.data.v else { print("no photo data"); return 1 }
    if path == "-" { FileHandle.standardOutput.write(d) }
    else {
        do { try d.write(to: URL(fileURLWithPath: path)) }
        catch { print("write failed: \(error)"); return 1 }
    }
    return 0
}
