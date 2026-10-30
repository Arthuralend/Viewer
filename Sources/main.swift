import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import Darwin

// macOS 15+: Apple Gain Map and Adaptive HDR decoding is delegated to Core Image.
struct Photo {
    let url: URL
    let hdr: CIImage
    let sdr: CIImage
    let details: String

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let uti = UTType(type as String), !uti.conforms(to: .rawImage),
              let hdr = CIImage(contentsOf: url, options: [
                .expandToHDR: true, .applyOrientationProperty: true]),
              let sdr = CIImage(contentsOf: url, options: [
                .expandToHDR: false, .toneMapHDRtoSDR: true,
                .applyOrientationProperty: true]),
              !hdr.extent.isEmpty, !hdr.extent.isInfinite,
              hdr.extent.width.isFinite, hdr.extent.height.isFinite else {
            throw NSError(domain: "HDRPhotoViewer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Не удалось прочитать фото. Используйте HEIC/JPEG/PNG/TIFF/AVIF; RAW пока не поддерживается."])
        }
        self.url = url
        self.hdr = hdr
        self.sdr = sdr
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let profile = properties?[kCGImagePropertyProfileName as String] as? String ?? "не указан"
        let appleMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        // A missing legacy auxiliary map does not rule out ISO/Adaptive HDR.
        let headroom = hdr.contentHeadroom
        let range = headroom > 1 ? String(format: "HDR %.2f×", headroom)
            : (headroom == 1 ? "Декодер сообщает SDR" : "Диапазон неизвестен")
        details = "\(Int(hdr.extent.width)) × \(Int(hdr.extent.height)) · \(range) · ICC: \(profile) · Apple gain map: \(appleMap ? "да" : "не обнаружена")"
    }
}

final class PhotoView: MTKView, MTKViewDelegate {
    private let context: CIContext
    private let queue: MTLCommandQueue
    private let outputSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    var photo: Photo? { didSet { redraw() } }
    var showHDR = true { didSet { redraw() } }
    var onDrop: ((URL) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var lastHeadroom: CGFloat = -1
    private var timer: Timer?

    init(device: MTLDevice, queue: MTLCommandQueue) {
        self.queue = queue
        context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        super.init(frame: .zero, device: device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.colorspace = outputSpace
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
        registerForDraggedTypes([.fileURL])
        // Poll only headroom, not image frames; catch brightness and screen changes.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let headroom = self.displayHeadroom
            if abs(headroom - self.lastHeadroom) > 0.001 {
                self.lastHeadroom = headroom
                self.redraw()
            }
        }
    }
    required init(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { timer?.invalidate() }
    private var displayHeadroom: CGFloat {
        let value = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        return value.isFinite ? max(1, value) : 1
    }
    func redraw() { needsDisplay = true }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); redraw() }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let command = queue.makeCommandBuffer() else { return }
        let bounds = CGRect(origin: .zero, size: drawableSize)
        guard bounds.width > 0, bounds.height > 0 else { return }
        var frame = CIImage(color: CIColor(red: 0.018, green: 0.018, blue: 0.018)).cropped(to: bounds)
        let target = Float(displayHeadroom)
        var rendering = "Откройте фото — ⌘O или перетащите файл"
        if let photo {
            var image = photo.sdr
            let source = photo.hdr.contentHeadroom
            if showHDR && target > 1 && source > 1 {
                let filter = CIFilter.toneMapHeadroom()
                filter.inputImage = photo.hdr
                filter.sourceHeadroom = source
                filter.targetHeadroom = min(source, target)
                guard let mapped = filter.outputImage else {
                    onError?("Не удалось выполнить HDR tone mapping.")
                    return
                }
                image = mapped
                rendering = "HDR → экран \(String(format: "%.2f", target))×"
            } else {
                rendering = showHDR ? "SDR fallback · экран \(String(format: "%.2f", target))×" : "SDR · базовое представление"
                if source == 0 { rendering += " · HDR headroom неизвестен" }
            }
            // Source profile is preserved on load. CI converts it into linear P3.
            // Fit in backing pixels, normalize EXIF-oriented extent, then center.
            let rect = image.extent
            let scale = min(bounds.width / rect.width, bounds.height / rect.height)
            image = image.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(
                    translationX: (bounds.width - rect.width * scale) / 2,
                    y: (bounds.height - rect.height * scale) / 2))
            frame = image.composited(over: frame).cropped(to: bounds)
        }
        let destination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: command)
        destination.colorSpace = outputSpace
        destination.isFlipped = true
        do {
            _ = try context.startTask(toRender: frame, to: destination)
            command.addCompletedHandler { [weak self] buffer in
                if let error = buffer.error {
                    DispatchQueue.main.async { self?.onError?(error.localizedDescription) }
                }
            }
            command.present(drawable)
            command.commit()
            onStatus?(rendering)
        } catch { onError?(error.localizedDescription) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first else { return false }
        onDrop?(url)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var viewer: PhotoView!
    let browser = BrowserPanel(frame: .zero)
    let info = NSTextField(labelWithString: "HEIC / JPEG HDR · исходные фотографии")
    let status = NSTextField(labelWithString: "Откройте фото или папку")
    let position = NSTextField(labelWithString: "")
    var controls: NSStackView!
    var requestID = UUID()
    var photos: [URL] = []
    var selectedIndex: Int?
    var isLoading = false
    var isScanning = false
    var loadFailed = false
    var keyMonitor: Any?
    var pendingDecode: DispatchWorkItem?
    var restoreBrowserAfterFullscreen = true
    let loader = DispatchQueue(label: "HDRPhotoViewer.decode", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            let alert = NSAlert(); alert.messageText = "Metal недоступен"; alert.runModal()
            NSApp.terminate(nil); return
        }
        viewer = PhotoView(device: device, queue: queue)
        viewer.onDrop = { [weak self] in self?.browser.open($0) }
        viewer.onStatus = { [weak self] text in
            guard let self, !self.isLoading, !self.isScanning, !self.loadFailed else { return }
            self.status.stringValue = text
        }
        viewer.onError = { [weak self] in self?.status.stringValue = "Ошибка рендеринга: \($0)" }
        browser.onFolderPhotos = { [weak self] urls in
            guard let self else { return }
            self.requestID = UUID()
            self.pendingDecode?.cancel()
            self.photos = urls
            self.selectedIndex = nil
            self.isLoading = false
            self.loadFailed = false
            self.viewer.photo = nil
            self.info.stringValue = ""
            self.position.stringValue = urls.isEmpty ? "Нет фотографий" : "\(urls.count) фото"
            self.window.title = "\(self.browser.folder?.lastPathComponent ?? "") — HDR Photo Viewer"
        }
        browser.onSelect = { [weak self] url in
            guard let self else { return }
            self.selectedIndex = self.photos.firstIndex(of: url)
            self.load(url)
        }
        browser.onActivatePhoto = { [weak self] in
            guard let self, !self.window.styleMask.contains(.fullScreen) else { return }
            self.window.toggleFullScreen(nil)
        }
        browser.onScanState = { [weak self] scanning in
            guard let self else { return }
            self.isScanning = scanning
            if scanning {
                self.requestID = UUID()
                self.pendingDecode?.cancel()
                self.isLoading = false
                self.status.stringValue = "Чтение папки…"
            }
        }
        browser.onError = { [weak self] text in
            self?.loadFailed = true
            self?.status.stringValue = text
        }
        let open = NSButton(title: "Фото…", target: self, action: #selector(openPhoto))
        let folder = NSButton(title: "Папка…", target: browser, action: #selector(BrowserPanel.chooseFolder))
        let previous = NSButton(title: "←", target: self, action: #selector(previousPhoto))
        let next = NSButton(title: "→", target: self, action: #selector(nextPhoto))
        previous.toolTip = "Предыдущее фото (←)"
        next.toolTip = "Следующее фото (→)"
        let mode = NSSegmentedControl(labels: ["HDR / Авто", "SDR"], trackingMode: .selectOne,
                                      target: self, action: #selector(changeMode(_:)))
        mode.selectedSegment = 0
        let sidebar = NSButton(title: "Проводник", target: self, action: #selector(toggleBrowser))
        let fullscreen = NSButton(title: "Полный экран", target: self, action: #selector(toggleFullscreen))
        controls = NSStackView(views: [open, folder, previous, next, mode, sidebar, fullscreen])
        controls.spacing = 8
        let picture = NSStackView(views: [controls, viewer, position, info, status])
        picture.orientation = .vertical
        picture.alignment = .leading
        picture.spacing = 8
        viewer.translatesAutoresizingMaskIntoConstraints = false
        viewer.widthAnchor.constraint(equalTo: picture.widthAnchor).isActive = true
        viewer.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        for label in [info, status, position] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.widthAnchor.constraint(lessThanOrEqualTo: picture.widthAnchor).isActive = true
        }
        browser.translatesAutoresizingMaskIntoConstraints = false
        browser.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let body = NSStackView(views: [browser, picture])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 12
        body.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        browser.heightAnchor.constraint(equalTo: body.heightAnchor, constant: -24).isActive = true
        picture.heightAnchor.constraint(equalTo: body.heightAnchor, constant: -24).isActive = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HDR Photo Viewer"
        window.minSize = NSSize(width: 1100, height: 500)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.contentView = body
        window.center()
        makeMenu()
        installKeyboardNavigation()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let path = CommandLine.arguments.dropFirst().first, !path.hasPrefix("-") {
            browser.open(URL(fileURLWithPath: path))
        } else {
            browser.navigate(to: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser)
        }
    }
    private func makeMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Завершить HDR Photo Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(); menu.addItem(file)
        file.submenu = NSMenu(title: "Файл")
        let open = file.submenu!.addItem(withTitle: "Открыть фото…", action: #selector(openPhoto), keyEquivalent: "o")
        open.target = self
        let folder = file.submenu!.addItem(withTitle: "Открыть папку…", action: #selector(BrowserPanel.chooseFolder), keyEquivalent: "o")
        folder.keyEquivalentModifierMask = [.command, .shift]
        folder.target = browser
        let view = NSMenuItem(); menu.addItem(view)
        view.submenu = NSMenu(title: "Вид")
        let sidebar = view.submenu!.addItem(withTitle: "Показать / скрыть проводник", action: #selector(toggleBrowser), keyEquivalent: "b")
        sidebar.target = self
        let fullscreen = view.submenu!.addItem(withTitle: "Полный экран", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.target = self
        NSApp.mainMenu = menu
    }
    private func installKeyboardNavigation() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window.isKeyWindow,
                  self.window.attachedSheet == nil, NSApp.modalWindow == nil,
                  !(self.window.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            // Local to this window. Does not capture arrows in file dialogs or other apps.
            switch event.keyCode {
            case 123: self.movePhoto(by: -1); return nil
            case 124: self.movePhoto(by: 1); return nil
            case 53 where self.window.styleMask.contains(.fullScreen):
                self.window.toggleFullScreen(nil); return nil
            case 3: self.window.toggleFullScreen(nil); return nil // F
            default: return event
            }
        }
    }
    @objc func openPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.directoryURL = browser.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.browser.open(url) }
        }
    }
    @objc func changeMode(_ sender: NSSegmentedControl) { viewer.showHDR = sender.selectedSegment == 0 }
    @objc func previousPhoto() { movePhoto(by: -1) }
    @objc func nextPhoto() { movePhoto(by: 1) }
    func movePhoto(by offset: Int) {
        guard !isScanning, !photos.isEmpty else { return }
        let candidate = (selectedIndex ?? (offset > 0 ? -1 : photos.count)) + offset
        guard photos.indices.contains(candidate) else { return }
        selectedIndex = candidate
        let url = photos[candidate]
        browser.selectPhoto(url)
        load(url)
    }
    @objc func toggleBrowser() { browser.isHidden.toggle() }
    @objc func toggleFullscreen() { window.toggleFullScreen(nil) }
    func windowWillEnterFullScreen(_ notification: Notification) {
        restoreBrowserAfterFullscreen = !browser.isHidden
        browser.isHidden = true
        controls.isHidden = true
        position.isHidden = true
        info.isHidden = true
        status.isHidden = true
        window.makeFirstResponder(viewer)
    }
    func windowDidExitFullScreen(_ notification: Notification) { restoreWindowControls() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { restoreWindowControls() }
    private func restoreWindowControls() {
        browser.isHidden = !restoreBrowserAfterFullscreen
        controls.isHidden = false
        position.isHidden = false
        info.isHidden = false
        status.isHidden = false
        viewer.redraw()
    }
    func load(_ url: URL) {
        let id = UUID(); requestID = id
        pendingDecode?.cancel()
        isLoading = true
        loadFailed = false
        status.stringValue = "Чтение \(url.lastPathComponent)…"
        if let index = selectedIndex { position.stringValue = "\(index + 1) / \(photos.count) · \(url.lastPathComponent)" }
        window.title = "\(url.lastPathComponent) — HDR Photo Viewer"
        let work = DispatchWorkItem { [weak self] in
            let result = autoreleasepool { Result { try Photo(url: url) } }
            DispatchQueue.main.async {
                guard let self, self.requestID == id else { return }
                self.isLoading = false
                switch result {
                case .success(let photo):
                    self.viewer.photo = photo
                    self.info.stringValue = photo.details
                    self.info.toolTip = photo.details
                    self.status.stringValue = "Фото загружено"
                case .failure(let error):
                    self.loadFailed = true
                    self.viewer.photo = nil
                    self.info.stringValue = ""
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
        pendingDecode = work
        loader.async(execute: work)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        pendingDecode?.cancel()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--self-test") {
    do {
        try runSelfTests()
        print("All headless checks passed")
        exit(0)
    } catch {
        fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
