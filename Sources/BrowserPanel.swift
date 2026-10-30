import AppKit
import ImageIO

/// Folder navigation and SDR thumbnails; the full-size renderer stays independent.
final class BrowserPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry {
        let url: URL
        let isDirectory: Bool
    }
    private let table = NSTableView()
    private let path = NSPathControl()
    private let countLabel = NSTextField(labelWithString: "Выберите папку")
    private let thumbnails = NSCache<NSURL, NSImage>()
    private let thumbnailQueue = OperationQueue()
    private let directoryQueue = DispatchQueue(label: "HDRPhotoViewer.folders", qos: .userInitiated)
    private var entries: [Entry] = []
    private var generation = UUID()
    private var suppressSelection = false
    private var history: [URL] = []
    private var historyIndex = -1
    private let backButton = NSButton(title: "‹", target: nil, action: nil)
    private let forwardButton = NSButton(title: "›", target: nil, action: nil)
    private let upButton = NSButton(title: "↑", target: nil, action: nil)
    private(set) var folder: URL?
    var onSelect: ((URL) -> Void)?
    var onActivatePhoto: (() -> Void)?
    var onFolderPhotos: (([URL]) -> Void)?
    var onError: ((String) -> Void)?
    var onScanState: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnailQueue.maxConcurrentOperationCount = 2
        thumbnailQueue.qualityOfService = .utility
        thumbnails.countLimit = 250
        thumbnails.totalCostLimit = 32 * 1024 * 1024
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        upButton.target = self; upButton.action = #selector(goUp)
        backButton.toolTip = "Назад по папкам"
        forwardButton.toolTip = "Вперёд по папкам"
        upButton.toolTip = "Родительская папка"
        let choose = NSButton(title: "Папка…", target: self, action: #selector(chooseFolder))
        let refresh = NSButton(title: "↻", target: self, action: #selector(refreshFolder))
        refresh.toolTip = "Обновить содержимое папки"
        let navigation = NSStackView(views: [backButton, forwardButton, upButton, choose, refresh])
        navigation.spacing = 4
        let places = NSSegmentedControl(labels: ["Домой", "Фото", "Диски"],
            trackingMode: .momentary, target: self, action: #selector(openPlace(_:)))
        path.pathStyle = .standard
        path.target = self
        path.doubleAction = #selector(openPathComponent)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Папки и фотографии"
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activateRow)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [navigation, places, path, scroll, countLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            places.widthAnchor.constraint(equalTo: stack.widthAnchor),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            countLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { thumbnailQueue.cancelAllOperations() }

    static func isPhoto(_ url: URL) -> Bool {
        // Restrict navigation to raster formats; actual decoding is validated separately.
        ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "avif", "jxl", "gif", "webp", "bmp"]
            .contains(url.pathExtension.lowercased())
    }
    func open(_ url: URL) {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            navigate(to: url)
        } else {
            navigate(to: url.deletingLastPathComponent(), selecting: url)
        }
    }
    func navigate(to requestedFolder: URL, selecting requestedPhoto: URL? = nil,
                  recordHistory: Bool = true, targetHistoryIndex: Int? = nil) {
        let url = requestedFolder.standardizedFileURL
        let token = UUID()
        generation = token
        thumbnailQueue.cancelAllOperations()
        countLabel.stringValue = "Чтение папки…"
        onScanState?(true)
        directoryQueue.async { [weak self] in
            let result = Result { () throws -> [Entry] in
                let urls = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey],
                    options: [.skipsHiddenFiles])
                return urls.compactMap { child -> Entry? in
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]) else { return nil }
                    if values.isDirectory == true && values.isPackage != true {
                        return Entry(url: child.standardizedFileURL, isDirectory: true)
                    }
                    if values.isRegularFile == true && Self.isPhoto(child) {
                        return Entry(url: child.standardizedFileURL, isDirectory: false)
                    }
                    return nil
                }.sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    let order = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
                    if order == .orderedSame { return a.url.path < b.url.path }
                    return order == .orderedAscending
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.onScanState?(false)
                switch result {
                case .failure(let error):
                    self.countLabel.stringValue = "Не удалось открыть папку"
                    self.onError?(error.localizedDescription)
                case .success(let items):
                    self.folder = url
                    self.path.url = url
                    self.path.toolTip = url.path
                    if recordHistory {
                        self.history = Array(self.history.prefix(self.historyIndex + 1))
                        if self.history.last != url { self.history.append(url) }
                        self.historyIndex = self.history.count - 1
                    } else if let targetHistoryIndex {
                        self.historyIndex = targetHistoryIndex
                    }
                    self.entries = items
                    self.thumbnails.removeAllObjects()
                    self.suppressSelection = true
                    self.table.reloadData()
                    self.table.deselectAll(nil)
                    self.suppressSelection = false
                    let photos = items.filter { !$0.isDirectory }.map(\.url)
                    self.countLabel.stringValue = "\(photos.count) фото · \(items.count - photos.count) папок"
                    self.onFolderPhotos?(photos)
                    self.updateButtons()
                    let wanted = requestedPhoto?.standardizedFileURL
                    if let wanted, !photos.contains(wanted) {
                        self.onError?("Этот файл не входит в список поддерживаемых фотографий")
                    } else if let chosen = wanted ?? photos.first {
                        self.selectPhoto(chosen, notify: true)
                    } else {
                        self.onError?("В папке нет поддерживаемых фотографий")
                    }
                }
            }
        }
    }
    func selectPhoto(_ url: URL, notify: Bool = false) {
        guard let row = entries.firstIndex(where: { !$0.isDirectory && $0.url == url.standardizedFileURL }) else { return }
        suppressSelection = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        suppressSelection = false
        if notify { onSelect?(entries[row].url) }
    }
    @objc func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Открыть папку"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.navigate(to: url) }
        }
    }
    @objc private func goBack() {
        guard historyIndex > 0 else { return }
        let index = historyIndex - 1
        navigate(to: history[index], recordHistory: false, targetHistoryIndex: index)
    }
    @objc private func goForward() {
        guard historyIndex + 1 < history.count else { return }
        let index = historyIndex + 1
        navigate(to: history[index], recordHistory: false, targetHistoryIndex: index)
    }
    @objc private func goUp() {
        guard let folder else { return }
        navigate(to: folder.deletingLastPathComponent())
    }
    @objc private func refreshFolder() {
        guard let folder else { return }
        let selected = table.selectedRow
        let photo = entries.indices.contains(selected) && !entries[selected].isDirectory ? entries[selected].url : nil
        navigate(to: folder, selecting: photo, recordHistory: false)
    }
    @objc private func openPlace(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: navigate(to: FileManager.default.homeDirectoryForCurrentUser)
        case 1:
            if let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first { navigate(to: url) }
        default: navigate(to: URL(fileURLWithPath: "/Volumes", isDirectory: true))
        }
    }
    @objc private func openPathComponent() {
        if let url = path.clickedPathItem?.url { navigate(to: url) }
    }
    @objc private func activateRow() {
        let row = table.clickedRow
        guard entries.indices.contains(row) else { return }
        let entry = entries[row]
        if entry.isDirectory { navigate(to: entry.url) }
        else { onActivatePhoto?() }
    }
    private func updateButtons() {
        backButton.isEnabled = historyIndex > 0
        forwardButton.isEnabled = historyIndex + 1 < history.count
        upButton.isEnabled = folder != nil && folder?.path != "/"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, entries.indices.contains(table.selectedRow) else { return }
        let entry = entries[table.selectedRow]
        if !entry.isDirectory { onSelect?(entry.url) }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("PhotoRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserCell) ?? BrowserCell(frame: .zero)
        cell.identifier = identifier
        let entry = entries[row]
        cell.representedURL = entry.url
        cell.textField?.stringValue = entry.url.lastPathComponent
        cell.toolTip = entry.url.path
        cell.imageView?.image = NSImage(systemSymbolName: entry.isDirectory ? "folder.fill" : "photo", accessibilityDescription: nil)
        if !entry.isDirectory {
            if let cached = thumbnails.object(forKey: entry.url as NSURL) {
                cell.imageView?.image = cached
            } else {
                let token = generation
                let url = entry.url
                thumbnailQueue.addOperation { [weak self, weak cell] in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 128,
                            kCGImageSourceShouldCacheImmediately: true
                          ] as CFDictionary) else { return }
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        let thumbnail = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
                        self.thumbnails.setObject(thumbnail, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                        if cell?.representedURL == url { cell?.imageView?.image = thumbnail }
                    }
                }
            }
        }
        return cell
    }
}

private final class BrowserCell: NSTableCellView {
    var representedURL: URL?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image); addSubview(label)
        imageView = image; textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 68),
            image.heightAnchor.constraint(equalToConstant: 56),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
}
