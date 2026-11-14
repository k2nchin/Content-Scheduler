import SwiftUI
import AVFoundation

/// Clipping en vivo: graba con la cámara en partes de 3 minutos y, al cerrar cada parte,
/// saca los clips marcados (botón «Clip» o picos de energía) y los manda a la cola mientras sigues grabando.
@Observable
@MainActor
final class LiveRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var audioConnection: AVCaptureConnection? { output.connection(with: .audio) }

    var isRecording = false
    var elapsed = 0.0
    var level: Float = -160      // dB actual del micrófono
    var made = 0                 // clips ya creados
    var processing = 0           // partes procesándose
    var marks: [Double] = []     // momentos marcados en la parte actual (segundos desde que empezó)
    var lastMessage = ""

    var clipLength = 30.0
    var autoMarks = true
    var subtitles = true
    let segmentLength = 180.0

    private var segmentStart = Date()
    private var sessionStart = Date()
    private var timer: Timer?
    private var avgLevel: Float = -50
    private var lastAutoMark = -100.0
    private var stopping = false
    var onSegment: ((URL, [Double]) -> Void)?

    func configure() async -> Bool {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard cam, mic else { lastMessage = "Activa cámara y micrófono para Scheduler en Ajustes del iPhone."; return false }
        guard session.inputs.isEmpty else { return true }
        session.beginConfiguration()
        session.sessionPreset = .high
        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) { session.addInput(input) }
        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 } // vertical
        session.commitConfiguration()
        let s = session
        Task.detached { s.startRunning() }
        return true
    }

    func flipCamera() {
        guard !isRecording, let current = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first(where: { $0.device.hasMediaType(.video) }) else { return }
        let pos: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
              let input = try? AVCaptureDeviceInput(device: cam) else { return }
        session.beginConfiguration()
        session.removeInput(current)
        if session.canAddInput(input) { session.addInput(input) } else { session.addInput(current) }
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        session.commitConfiguration()
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        stopping = false
        sessionStart = .now
        UIApplication.shared.isIdleTimerDisabled = true
        startSegment()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        guard isRecording else { return }
        stopping = true
        isRecording = false
        timer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
        output.stopRecording()
    }

    /// Marca el momento actual (el clip toma los segundos anteriores).
    func mark() {
        let t = Date.now.timeIntervalSince(segmentStart)
        if marks.contains(where: { abs($0 - t) < 5 }) { return }
        marks.append(t)
    }

    private func startSegment() {
        marks = []
        segmentStart = .now
        let url = AppStore.videosDir.appendingPathComponent("live-\(UUID().uuidString).mov")
        output.startRecording(to: url, recordingDelegate: self)
    }

    private func tick() {
        elapsed = Date.now.timeIntervalSince(sessionStart)
        if let ch = audioConnection?.audioChannels.first {
            level = ch.averagePowerLevel
            // Pico de energía: bastante más fuerte que el promedio reciente
            if autoMarks {
                let t = Date.now.timeIntervalSince(segmentStart)
                if level > avgLevel + 12, level > -30, t - lastAutoMark > 20, t > 5 { lastAutoMark = t; mark() }
            }
            avgLevel = avgLevel * 0.985 + max(level, -60) * 0.015
        }
        if Date.now.timeIntervalSince(segmentStart) >= segmentLength { output.stopRecording() } // cerrar parte y seguir
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        MainActor.assumeIsolated {
            let segMarks = marks
            lastAutoMark = -100
            if isRecording && !stopping { startSegment() }   // sigue grabando sin parar
            onSegment?(url, segMarks)
        }
    }
}

struct LiveClipperView: View {
    @Environment(AppStore.self) private var store
    @Environment(YouTubeService.self) private var youtube
    @Environment(\.dismiss) private var dismiss
    @State private var rec = LiveRecorder()
    @State private var ready = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready { CameraPreview(session: rec.session).ignoresSafeArea() }
            VStack(spacing: 12) {
                HStack {
                    Button { rec.stop(); dismiss() } label: { Image(systemName: "xmark").font(.title3.bold()).padding(10).background(.black.opacity(0.5), in: Circle()) }
                    Spacer()
                    if rec.isRecording {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text(clock(rec.elapsed)).font(.system(size: 15, weight: .bold, design: .monospaced))
                        }.padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.55), in: Capsule())
                    }
                    Spacer()
                    Button { rec.flipCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title3).padding(10).background(.black.opacity(0.5), in: Circle()) }
                        .disabled(rec.isRecording)
                }
                .foregroundStyle(.white)
                Spacer()
                // Medidor de energía
                GeometryReader { g in
                    let v = CGFloat(max(0, min(1, (rec.level + 60) / 60)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(v > 0.75 ? Theme.accent : Theme.ok).frame(width: g.size.width * v)
                    }
                }.frame(height: 6)
                HStack {
                    Text("Clips: \(rec.made)" + (rec.processing > 0 ? " · creando…" : "")).font(.footnote.bold())
                    Spacer()
                    Text("Marcas: \(rec.marks.count)").font(.footnote)
                }.foregroundStyle(.white)
                if !rec.lastMessage.isEmpty { Text(rec.lastMessage).font(.caption).foregroundStyle(.white.opacity(0.85)) }
                HStack(spacing: 18) {
                    if rec.isRecording {
                        Button { rec.mark() } label: {
                            Label("Clip", systemImage: "scissors").font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 14).background(Theme.accent, in: Capsule())
                        }
                    }
                    Button { rec.isRecording ? rec.stop() : rec.start() } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
                            RoundedRectangle(cornerRadius: rec.isRecording ? 6 : 30).fill(.red)
                                .frame(width: rec.isRecording ? 30 : 58, height: rec.isRecording ? 30 : 58)
                        }
                    }.disabled(!ready)
                }
                if !rec.isRecording {
                    VStack(spacing: 8) {
                        Picker("Duración del clip", selection: $rec.clipLength) {
                            Text("15 s").tag(15.0); Text("30 s").tag(30.0); Text("60 s").tag(60.0)
                        }.pickerStyle(.segmented)
                        Toggle("Clips automáticos por energía", isOn: $rec.autoMarks).font(.footnote)
                        Toggle("Subtítulos automáticos", isOn: $rec.subtitles).font(.footnote)
                        Text("Graba en partes de 3 min. Al cerrar cada parte, los momentos marcados se vuelven clips y van a la cola mientras sigues grabando.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(12).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white).tint(Theme.accent)
                }
            }
            .padding(16)
        }
        .task {
            ready = await rec.configure()
            rec.onSegment = { url, marks in Task { await process(url, marks: marks) } }
        }
        .onDisappear { rec.stop() }
    }

    private func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

    /// Convierte las marcas de una parte en clips (los segundos anteriores a cada marca) y los manda a la cola.
    private func process(_ url: URL, marks: [Double]) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard !marks.isEmpty else { return }
        rec.processing += 1
        defer { rec.processing -= 1 }
        let dur = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        for m in marks {
            let end = min(dur, m + 3)                         // un poquito después de la marca
            let start = max(0, end - rec.clipLength)
            guard end - start >= 3 else { continue }
            do {
                let clip = try await StudioExport.run(source: url, start: start, end: end, subtitles: rec.subtitles) { _ in }
                let id = await store.addVideo(from: clip, youtubeConnected: youtube.isConnected)
                store.update(id) { $0.title = "Clip en vivo · \(Date.now.formatted(.dateTime.hour().minute()))" }
                let drive = DriveService.shared
                if drive.isConnected && drive.useDrive, let did = try? await drive.upload(clip, name: "En vivo \(Date.now.formatted(.dateTime.day().month().hour().minute())).mp4") {
                    store.update(id) { $0.driveID = did }
                    store.deleteVideoFile(of: id)
                }
                rec.made += 1
                rec.lastMessage = "Nuevo clip en la cola ✓"
            } catch {
                rec.lastMessage = "Un clip falló: \(error.localizedDescription)"
            }
        }
    }
}

/// Vista previa de la cámara.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.layer2.session = session
        v.layer2.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layer2: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
