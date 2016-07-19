/*
 
 Document.swift
 
 CotEditor
 https://coteditor.com
 
 Created by nakamuxu on 2004-12-08.
 
 ------------------------------------------------------------------------------
 
 © 2004-2007 nakamuxu
 © 2014-2016 1024jp
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 */

import Cocoa

// constants

private let UniqueFileIDLength = 8

/// Maximal length to scan encoding declaration
private let MaxEncodingScanLength = 2000

private enum SerializationKey {
    static let readingEncoding = "readingEncoding"
    static let syntaxStyle = "syntaxStyle"
    static let autosaveIdentifier = "autosaveIdentifier"
}

// file extended attributes
private let NSFileExtendedAttributes = FileAttributeKey("NSFileExtendedAttributes")
private enum FileExtendedAttributeName {
    static let Encoding = "com.apple.TextEncoding"
    static let VerticalText = "com.coteditor.VerticalText"
}

// error key
private enum ErrorKey {
    static let StringEncodingUTF8BOM = "CEStringEncodingUTF8BOMErrorKey"
}



class Document: NSDocument, EncodingHolder {
    
    @objc var encodingObjC: UInt { return self.encoding.rawValue }
    
    static let EncodingDidChangeNotification = Notification.Name("DocumentEncodingDidChangeNotification")
    static let LineEndingDidChangeNotification = Notification.Name("DocumentLineEndingDidChangeNotification")
    static let SyntaxStyleDidChangeNotification = Notification.Name("DocumentSyntaxStyleDidChangeNotification")
    
    
    // MARK: Public Properties
    
    let textStorage = NSTextStorage()
    private(set) var encoding: String.Encoding
    private(set) var hasUTF8BOM = false
    private(set) var lineEnding: CENewLineType
    private(set) var fileAttributes: [FileAttributeKey: AnyObject]?
    private(set) var syntaxStyle: SyntaxStyle
    
    private(set) lazy var selection: TextSelection = TextSelection(document: self)
    private(set) lazy var analyzer: CEDocumentAnalyzer = CEDocumentAnalyzer(document: self)
    private(set) lazy var incompatibleCharacterScanner: IncompatibleCharacterScanner = IncompatibleCharacterScanner(document: self)
    
    
    // MARK: Public Properties
    
    private var windowController: DocumentWindowController!
    private lazy var printPanelAccessoryController = CEPrintPanelAccessoryController()
    @IBOutlet private var savePanelAccessoryView: NSView?
    
    private var readingEncoding: String.Encoding  // encoding to read document file
    private var needsShowUpdateAlertWithBecomeKey = false
    private var isExternalUpdateAlertShown = false
    private var fileHash: Data?  // MD5
    private var isVerticalText = false
    private var odbEventSender: ODBEventSender?
    private var shouldSaveXattr = true
    private var autosaveIdentifier: String
    private var suppressesIANACharsetConflictAlert = false
    private dynamic var isExecutable = false  // bind in save panel accessory view
    
    
    
    // MARK:
    // MARK: Lifecycle
    
    override init() {
        
        let defaults = UserDefaults.standard
        
        let uuid = UUID().uuidString
        self.autosaveIdentifier = uuid.substring(to: uuid.index(uuid.startIndex, offsetBy: UniqueFileIDLength))
        
        self.encoding = String.Encoding(rawValue: UInt(defaults.integer(forKey: DefaultKey.encodingInNew.rawValue)))
        if self.encoding == .utf8 {
            self.hasUTF8BOM = defaults.bool(forKey: DefaultKey.saveUTF8BOM.rawValue)
        }
        self.lineEnding = CENewLineType(rawValue: defaults.integer(forKey: DefaultKey.lineEndCharCode.rawValue)) ?? .LF
        self.syntaxStyle = CESyntaxManager.shared().style(withName: defaults.string(forKey: DefaultKey.syntaxStyle.rawValue)) ?? SyntaxStyle()
        
        // set encoding to read file
        // -> The value is either user setting or selection of open panel.
        // -> This must be set before `readFromData:ofType:error:` is called.
        self.readingEncoding = String.Encoding(rawValue: (CEDocumentController.shared() as! CEDocumentController).accessorySelectedEncoding)
        
        super.init()
        
        self.hasUndoManager = true
        
        // observe sytnax style update
        NotificationCenter.default.addObserver(self, selector: #selector(syntaxDidUpdate), name: .CESyntaxDidUpdate, object: nil)
    }
    
    
    /// initialize instance with existing file
    
    // FIXME: override convenience initializer
//     convenience init(contentsOf url: URL, ofType typeName: String) throws {
//        
//        super.init(contentsOf: url, ofType: typeName)
//        
//        // [caution] This method may be called from a background thread due to concurrent-opening.
//        // This method won't be invoked on Resume. (2015-01-26)
//        
//        // set sender of external editor protocol (ODB Editor Suite)
//        self.odbEventSender = ODBEventSender()
//        
//        // check file meta data for text orientation
//        if UserDefaults.standard.bool(forKey: DefaultKey.savesTextOrientation.rawValue) {
//            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path!)  // FILE_READ
//            self.isVerticalText = (attributes?[NSFileExtendedAttributes]?[FileExtendedAttributeName.VerticalText] != nil)
//        }
//    }
    
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    
    /// store internal document state
    override func encodeRestorableState(with coder: NSCoder) {
        
        coder.encode(Int(self.encoding.rawValue), forKey: SerializationKey.readingEncoding)
        coder.encode(self.autosaveIdentifier, forKey: SerializationKey.autosaveIdentifier)
        coder.encode(self.syntaxStyle.styleName, forKey: SerializationKey.syntaxStyle)
        
        super.encodeRestorableState(with: coder)
    }
    
    
    /// resume UI state
    override func restoreState(with coder: NSCoder) {
        
        super.restoreState(with: coder)
        
        if coder.containsValue(forKey: SerializationKey.readingEncoding) {
            self.readingEncoding = String.Encoding(rawValue: UInt(coder.decodeInteger(forKey: SerializationKey.readingEncoding)))
        }
        if let identifier = coder.decodeObject(forKey: SerializationKey.autosaveIdentifier) as? String {
            self.autosaveIdentifier = identifier
        }
        if let styleName = coder.decodeObject(forKey: SerializationKey.syntaxStyle) as? String {
            self.setSyntaxStyle(name: styleName)
        }
    }
    
    
    
    // MARK: Document Methods
    
    /// enable Autosave in Place
    override class func autosavesInPlace() -> Bool {
        
        return self._autosavesInPlace
    }
    // avoid changing the value while the application is running
    private static let _autosavesInPlace = UserDefaults.standard.bool(forKey: DefaultKey.enablesAutosaveInPlace.rawValue)
    
    
    /// can read document on a background thread?
    override class func canConcurrentlyReadDocuments(ofType: String) -> Bool {
        
        return true
    }
    
    
    /// make custom windowControllers
    override func makeWindowControllers() {
        
        let storyboard = NSStoryboard(name: "DocumentWindow", bundle: nil)
        self.windowController = storyboard.instantiateInitialController() as! DocumentWindowController
        self.addWindowController(self.windowController)
    }
    
    
    /// load document from file and return whether it succeeded
    override func read(from url: URL, ofType typeName: String) throws {
        
        // [caution] This method may be called from a background thread due to concurrent-opening.
        
        let data = try Data(contentsOf: url)  // FILE_READ
        
        // store file hash (MD5) in order to check the file content identity in `presentedItemDidChange`
        self.fileHash = (data as NSData).md5()
        
        // read file attributes only if `fileURL` exists
        // -> The passed-in `url` in this method can point to a file that isn't the real document file,
        //    for example on resuming of an unsaved document.
        if let filePath = self.fileURL?.path {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath) {  // FILE_READ
                self.fileAttributes = attributes
                let posixPermissions = (attributes[.posixPermissions] as? UInt16) ?? 0
                self.isExecutable = (posixPermissions & S_IXUSR) != 0
            }
        }
        
        // try reading the `com.apple.TextEncoding` extended attribute
        var xattrEncoding: String.Encoding?
        if let extendedAttributes = (try? FileManager.default.attributesOfItem(atPath: url.path!)[NSFileExtendedAttributes]) as? [String: AnyObject],
            let xattrEncodingValue = extendedAttributes[FileExtendedAttributeName.Encoding] as? Data {
            let xattrEncodingRaw = decodeXattrEncoding(xattrEncodingValue)
            if xattrEncodingRaw != UInt(NSNotFound) {
                xattrEncoding = String.Encoding(rawValue: xattrEncodingRaw)
            }
        }
        self.shouldSaveXattr = (xattrEncoding != nil)
        
        var content: String
        var usedEncoding: String.Encoding
        
        if self.readingEncoding == String.Encoding.autoDetection {
            (content, usedEncoding) = try self.string(data: data, xattrEncoding: xattrEncoding)
            
        } else {
            usedEncoding = self.readingEncoding
            if data.count > 0 {
                content = try NSString(contentsOf: url, encoding: self.readingEncoding.rawValue) as String  // FILE_READ
                // -> Use NSString initializer to let it throw NSError if failed
            } else {
                content = ""
            }
        }
        
        // set read values
        self.encoding = usedEncoding
        self.hasUTF8BOM = (usedEncoding == .utf8) && ((data as NSData).hasUTF8BOM())
        
        let lineEnding = (content as NSString).detectNewLineType()
        if lineEnding != .none {  // keep default if no line endings are found
            self.lineEnding = lineEnding
        }
        
        // notify
        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: Document.EncodingDidChangeNotification, object: self)
            NotificationCenter.default.post(name: Document.LineEndingDidChangeNotification, object: self)
        }
        
        // standardize line endings to LF (File Open)
        // (Line endings replacemement by other text modifications are processed in the following methods.)
        //
        // # Methods Standardizing Line Endings on Text Editing
        //   - File Open:
        //       - Document > read(from:ofType:)
        //   - Key Typing, Script, Paste, Drop or Replace via Find Panel:
        //       - TextViewController > textView:shouldChangeTextInRange:replacementString:
        let string = (content as NSString).replacingNewLineCharacers(with: .LF)
        
        self.textStorage.replaceCharacters(in: self.textStorage.string.nsRange, with: string)
        
        // determine syntax style
        var styleName = CESyntaxManager.shared().styleName(fromDocumentFileName: url.lastPathComponent!)
        if styleName == nil {
            styleName = CESyntaxManager.shared().styleName(fromDocumentContent: string)
        }
        styleName = styleName ?? UserDefaults.standard.string(forKey: DefaultKey.syntaxStyle.rawValue)
        self.setSyntaxStyle(name: styleName)
    }
    
    
    /// revert to saved file contents
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        
        // once force-close all sheets
        //   -> Presented errors will be displayed again after the revert automatically (since OS X 10.10).
        self.windowForSheet?.sheets.forEach { $0.close() }
        
        try super.revert(toContentsOf: url, ofType: typeName)
        
        // apply to UI
        self.applyContentToWindow()
    }
    
    
    /// return preferred file extension corresponding the current syntax style
    override func fileNameExtension(forType typeName: String, saveOperation: NSSaveOperationType) -> String? {
        
        if let pathExtension = self.fileURL?.pathExtension {
            return pathExtension
        }
        
        let styleName = self.syntaxStyle.styleName
        let extensions = CESyntaxManager.shared().extensions(forStyleName: styleName)
        
        return extensions.first
    }
    
    
    /// create Data object to save
    override func data(ofType typeName: String) throws -> Data {
        
        let encoding = self.encoding
        let needsUTF8BOM = (encoding == .utf8) && self.hasUTF8BOM
        
        // convert Yen sign in consideration of the current encoding
        let string = (self.string as NSString).convertingYenSign(forEncoding: encoding.rawValue)
        
        // unblock the user interface, since fetching current document state has been done here
        self.unblockUserInteraction()
        
        // get data from string to save
        guard var data = string.data(using: encoding, allowLossyConversion: true) else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileWriteInapplicableStringEncodingError,
                          userInfo: [NSStringEncodingErrorKey: encoding.rawValue])
        }
        
        // add UTF-8 BOM if needed
        if needsUTF8BOM {
            data = (data as NSData).addingUTF8BOM()
        }
        
        return data
    }
    
    
    /// enable asynchronous saving
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSSaveOperationType) -> Bool {
        
        return saveOperation == .autosaveElsewhereOperation || saveOperation == .autosaveInPlaceOperation
    }
    
    
    /// save or autosave the document contents to a file
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSSaveOperationType, completionHandler: (NSError?) -> Void) {
        
        // trim trailing whitespace if needed
        if UserDefaults.standard.bool(forKey: DefaultKey.trimsTrailingWhitespaceOnSave.rawValue) {
            let keepsEditingPoint = (saveOperation == .autosaveInPlaceOperation || saveOperation == .autosaveElsewhereOperation)
            
            for layoutManager in self.textStorage.layoutManagers {
                guard
                    let textView = layoutManager.textViewForBeginningOfSelection,
                    let window = textView.window else { continue }
                
                if !keepsEditingPoint || layoutManager.layoutManagerOwnsFirstResponder(in: window) {
                    textView.trimTrailingWhitespaceKeepingEditingPoint(keepsEditingPoint)
                    break  // trimming once is enough
                }
            }
        }
        
        // break undo grouping
        for layoutManager in self.textStorage.layoutManagers {
            layoutManager.textViewForBeginningOfSelection?.breakUndoCoalescing()
        }
        
        // modify place to create backup file
        //   -> save backup file always in `~/Library/Autosaved Information/` directory
        //      (The default backup URL is the same directory as the fileURL.)
        var newUrl: URL = {
            guard let fileURL = self.fileURL, saveOperation == .autosaveElsewhereOperation else { return url }
            
            let autosaveDirectoryURL = (CEDocumentController.shared() as! CEDocumentController).autosaveDirectoryURL
            var baseFileName = ((try? fileURL.deletingPathExtension()) ?? fileURL).lastPathComponent!
            if baseFileName.hasPrefix(".") {  // avoid file to be hidden
                baseFileName.remove(at: baseFileName.startIndex)
            }
            // append a unique string to avoid overwriting another backup file with the same file name.
            let fileName = baseFileName + " (\(self.autosaveIdentifier))"
            
            guard var newURL = try? autosaveDirectoryURL.appendingPathComponent(fileName) else { return url }
            
            if let pathExtension = fileURL.pathExtension {
                return (try? newURL.appendingPathExtension(pathExtension)) ?? newURL
            }
            return newURL
        }()
        
        super.save(to: newUrl, ofType: typeName, for: saveOperation) { [unowned self] (error: NSError?) in
            // [note] This completionHandler block will always be invoked on the main thread.
         
            defer {
                completionHandler(error)
            }
            
            guard error == nil else { return }
            
            // apply syntax style that is inferred from the file name
            if saveOperation == .saveAsOperation {
                if let fileName = url.lastPathComponent,
                   let styleName = CESyntaxManager.shared().styleName(fromDocumentFileName: fileName)
                {
                    self.setSyntaxStyle(name: styleName)
                }
            }
            
            if saveOperation != .autosaveElsewhereOperation {
                // get the latest file attributes
                if let path = url.path {
                    self.fileAttributes = try? FileManager.default.attributesOfItem(atPath: path) ?? [:]
                }
                
                // update file information
                self.analyzer.invalidateFileInfo()
                
                // send file update notification for the external editor protocol (ODB Editor Suite)
                self.odbEventSender?.sendModifiedEvent(fileURL: url, operation: saveOperation)
            }
        }
    }
    
    
    /// write new data to file (invoked in file saving proccess)
    override func write(to url: URL, ofType typeName: String, for saveOperation: NSSaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        
        // [caution] This method may be called from a background thread due to async-saving.
        
        
        // store current state here, since the main thread will already be unblocked after `data(ofType:)`
        let encoding = self.encoding
        self.isVerticalText = self.editor?.verticalLayoutOrientation ?? false
        
        try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        
        if saveOperation != .autosaveElsewhereOperation {
            // store file hash (MD5) in order to check the file content identity in `presentedItemDidChange`
            if let data = try? Data(contentsOf: url) {  // FILE_READ
                self.fileHash = (data as NSData).md5()
            }
            
            // store file encoding for revert
            self.readingEncoding = encoding
        }
    }
    
    
    /// customize document's file attributes
    override func fileAttributesToWrite(to url: URL, ofType typeName: String, for saveOperation: NSSaveOperationType, originalContentsURL absoluteOriginalContentsURL: URL?) throws -> [String : AnyObject] {
        
        var attributes = try super.fileAttributesToWrite(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        
        // set extended file attributes
        var extendedAttributes: [String: AnyObject] = (attributes[NSFileExtendedAttributes.rawValue] as? [String: AnyObject]) ?? [:]
        // save encoding to the extended file attributes (com.apple.TextEncoding)
        if saveOperation == .autosaveElsewhereOperation || self.shouldSaveXattr {
            extendedAttributes[FileExtendedAttributeName.Encoding] = encodeXattrEncoding(self.encoding.rawValue)
        }
        // save text orientation state to the extended file attributes (com.coteditor.VerticalText)
        if UserDefaults.standard.bool(forKey: DefaultKey.savesTextOrientation.rawValue) {
            extendedAttributes[FileExtendedAttributeName.VerticalText] = self.isVerticalText ? Data(bytes: [1]) : nil
        }
        if attributes[NSFileExtendedAttributes.rawValue] != nil || !extendedAttributes.isEmpty {
            attributes[NSFileExtendedAttributes.rawValue] = extendedAttributes
        }
        
        // give the execute permission if user requested
        if self.isExecutable && saveOperation != .autosaveElsewhereOperation {
            var permissions = (attributes[FileAttributeKey.posixPermissions.rawValue] as? UInt16) ?? 0
            if let originalPath = absoluteOriginalContentsURL?.path, permissions == 0 {
                permissions = ((try? FileManager.default.attributesOfItem(atPath: originalPath))?[.posixPermissions] as? UInt16) ?? 0  // FILE_READ
            }
            if permissions == 0 {
                permissions = 0644  // ???: Is the default permission really always 644?
            }
            permissions |= S_IXUSR
            attributes[FileAttributeKey.posixPermissions.rawValue] = NSNumber(value: permissions)
        }
        
        return attributes
    }
    
    
    /// avoid let system add the standard save panel accessory (pop-up menu for document type change)
    override var shouldRunSavePanelWithAccessoryView: Bool {
        
        return false
    }
    
    
    /// prepare save panel
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        
        // reset file types, otherwise:
        //   - alert dialog will be displayed if user inputs another extension.
        //   - cannot save without extension.
        savePanel.allowedFileTypes = nil
        
        // disable hide extension checkbox
        // -> Because it doesn't work.
        savePanel.isExtensionHidden = false
        savePanel.canSelectHiddenExtension = false
        
        // set accessory view
        if self.savePanelAccessoryView == nil {
            Bundle.main.loadNibNamed("SaveDocumentAccessory", owner: self, topLevelObjects: nil)
        }
        savePanel.accessoryView = self.savePanelAccessoryView
        
        // append file extension as a part of the file name
        // -> NSSaveAsOperation will remove the current file extension from file name in the nameField
        //    as we set nil to `setAllowedFileTypes:` just above.
        //    So, we need to set it again manually.
        if let pathExtension = self.fileNameExtension(forType: self.fileType!, saveOperation: .saveOperation) {
            savePanel.nameFieldStringValue = savePanel.nameFieldStringValue + "." + pathExtension
        }
        
        return super.prepareSavePanel(savePanel)
    }
    
    
    /// display dialogs about save before closing document
    override func canClose(withDelegate delegate: AnyObject, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutablePointer<Void>?) {
        
        // disable save dialog if content is empty and not saved
        if self.fileURL == nil && self.textStorage.string.isEmpty {
            self.updateChangeCount(.changeCleared)
        }
        
        super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
    }
    
    
    /// close document
    override func close() {
        
        self.syntaxStyle.cancelAllParses()
        
        // send file close notification for the external editor protocol (ODB Editor Suite)
        if let fileURL = self.fileURL {
            self.odbEventSender?.sendCloseEvent(fileURL: fileURL)
        }
        
        super.close()
    }
    
    
    /// setup print setting including print panel
    override func printOperation(withSettings printSettings: [String : AnyObject]) throws -> NSPrintOperation {
        
        let editor = self.editor!
        
        // create printView
        let printView = CEPrintView()
        printView.setLayoutOrientation(editor.focusedTextView?.layoutOrientation ?? .horizontal)
        printView.theme = editor.theme
        printView.documentName = self.displayName
        printView.filePath = self.fileURL?.path
        printView.syntaxName = self.syntaxStyle.styleName
        printView.documentShowsInvisibles = editor.showsInvisibles
        printView.documentShowsLineNumber = editor.showsLineNumber
        
        // set font for printing
        printView.font = {
            if UserDefaults.standard.integer(forKey: DefaultKey.setPrintFont.rawValue) == 1 {  // == use printing font
                return NSFont(name: UserDefaults.standard.string(forKey: DefaultKey.printFontName.rawValue)!,
                              size: UserDefaults.standard.cgFloat(forKey: DefaultKey.printFontSize.rawValue))
            }
            return self.editor?.font
        }()
        
        // [caution] need to set string after setting other properties
        printView.string = self.textStorage.string
        
        // create print operation
        let printOperation = NSPrintOperation(view: printView, printInfo: self.printInfo)
        printOperation.printInfo.dictionary().addEntries(from: printSettings)
        printOperation.showsProgressPanel = true
        printOperation.canSpawnSeparateThread = true  // display print progress panel as a sheet
        
        // setup print panel
        printOperation.printPanel.addAccessoryController(self.printPanelAccessoryController)
        printOperation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling])
        
        return printOperation
    }
    
    
    /// printing information associated with the document
    override var printInfo: NSPrintInfo {
        get {
            let printInfo = super.printInfo
            
            printInfo.horizontalPagination = .fitPagination
            printInfo.isHorizontallyCentered = false
            printInfo.isVerticallyCentered = false
            printInfo.leftMargin = kHorizontalPrintMargin
            printInfo.rightMargin = kHorizontalPrintMargin
            printInfo.topMargin = kVerticalPrintMargin
            printInfo.bottomMargin = kVerticalPrintMargin
            printInfo.dictionary()[NSPrintHeaderAndFooter] = true
            
            return printInfo
        }
        
        set (printInfo) {
            super.printInfo = printInfo
        }
    }
    
    
    /// setup duplicated document
    override func duplicate() throws -> NSDocument {
        
        let document = try super.duplicate() as! Document
        
        document.setSyntaxStyle(name: self.syntaxStyle.styleName)
        document.lineEnding = self.lineEnding
        document.encoding = self.encoding
        document.hasUTF8BOM = self.hasUTF8BOM
        
        // apply text orientation
        document.editor?.verticalLayoutOrientation = self.editor?.verticalLayoutOrientation ?? self.isVerticalText
        
        return document
    }
    
    
    /// recover presented error
    override func attemptRecovery(fromError error: NSError, optionIndex recoveryOptionIndex: Int, delegate: AnyObject?, didRecoverSelector: Selector?, contextInfo: UnsafeMutablePointer<Void>?) {
        
        var didRecover = false
        
        if let errorCode = CotEditorError(rawValue: error.code), error.domain == CotEditorError.domain {
            switch errorCode {
            case .unconvertibleCharacters:
                switch recoveryOptionIndex {
                case 0:  // == Show Incompatible Chars
                    self.windowController.showIncompatibleCharList()
                case 1:  // == Save
                    didRecover = true
                case 2:  // == Cancel
                    break
                default: break
                }
                
            case .lossyEncodingConversion:
                switch recoveryOptionIndex {
                case 0:  // == Cancel
                    // reset to force reverting toolbar selection
                    NotificationCenter.default.post(name: Document.EncodingDidChangeNotification, object: self)
                case 1:  // == Change Encoding
                    let _ = self.changeEncoding(to: String.Encoding(rawValue: error.userInfo[NSStringEncodingErrorKey] as! UInt!),
                                                withUTF8BOM: error.userInfo[ErrorKey.StringEncodingUTF8BOM] as! Bool,
                                                askLossy: false, lossy: true)
                    self.undoManager?.prepare(withInvocationTarget: self.windowController).showIncompatibleCharList()
                    self.windowController.showIncompatibleCharList()
                    didRecover = true
                default: break
                }
                
            default: break
            }
        }
        
        let context = UnsafeMutablePointer<AnyObject>(contextInfo)
        let _ = delegate?.perform(didRecoverSelector, with: didRecover, with: context?.pointee)
    }
    
    
    
    // MARK: Protocols
    
    /// file location has changed
    override func presentedItemDidMove(to newURL: URL) {
        
        // [caution] This method can be called from any thread.
        
        super.presentedItemDidMove(to: newURL)
        
        DispatchQueue.main.async { [weak self] in
            // -> `fileURL` property will be updated automatically after this `presentedItemDidMoveToURL:`.
            //    However, we don't know when exactly, therefore update it manually before update documentAnalyzer. (2016-05-19 / OS X 10.11.5)
            self?.fileURL = newURL
            
            self?.analyzer.invalidateFileInfo()
        }
    }
    
    
    /// file has been modified by an external process
    override func presentedItemDidChange() {
        
        // [caution] This method can be called from any thread.
        
        guard let fileURL = self.fileURL else { return }
        
        let option = DocumentConflictOption(rawValue: UserDefaults.standard.integer(forKey: DefaultKey.documentConflictOption.rawValue)) ?? .notify
        
        // do nothing
        if option == .ignore { return }
        
        // don't check twice if document is already marked as modified
        guard !self.needsShowUpdateAlertWithBecomeKey else { return }
        
        // ignore if file's modificationDate is the same as document's modificationDate
        var fileModificationDate: Date?
        let coordinator = NSFileCoordinator(filePresenter: self)
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: nil) { (newURL) in
            fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: newURL.path!))?[.modificationDate] as? Date  // FILE_READ
        }
        guard fileModificationDate != self.fileModificationDate else { return }
        
        // ignore if file's MD5 hash is the same as the stored MD5 and deal as if it was not modified
        var fileHash: Data?
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges, error: nil) { (newURL) in
            fileHash = (try? Data(contentsOf: newURL) as NSData)?.md5()  // FILE_READ
        }
        guard fileHash != self.fileHash else {
            // update the document's fileModificationDate for a workaround (2014-03 by 1024jp)
            // If not, an alert shows up when user saves the file.
            if let currentFileModificationDate = self.fileModificationDate,
                fileModificationDate?.compare(currentFileModificationDate) == .orderedDescending
            {
                self.fileModificationDate = fileModificationDate
            }
            return
        }
        
        // notify about external file update
        DispatchQueue.main.async { [weak self] in
            switch option {
            case .ignore:
                break
            case .notify:
                // notify and show dialog later
                self?.notifyExternalFileUpdate()
            case .revert:
                if let fileURL = self?.fileURL, let fileType = self?.fileType {
                    let _ = try? self?.revert(toContentsOf: fileURL, ofType: fileType)
                }
            }
        }
    }
    
    
    /// apply current state to menu items
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        
        guard let action = menuItem.action else { return false }
        
        switch action {
        case #selector(changeEncoding(_:)):
            let encodingTag = self.hasUTF8BOM ? -Int(self.encoding.rawValue) : Int(self.encoding.rawValue)
            menuItem.state = (menuItem.tag == encodingTag) ? NSOnState : NSOffState
            
        case #selector(changeLineEnding(_:)),
             #selector(changeLineEndingToLF(_:)),
             #selector(changeLineEndingToCR(_:)),
             #selector(changeLineEndingToCRLF(_:)):
            menuItem.state = (menuItem.tag == self.lineEnding.rawValue) ? NSOnState : NSOffState
            
        case #selector(changeSyntaxStyle(_:)):
            let name = self.syntaxStyle.styleName
            menuItem.state = (menuItem.title == name) ? NSOnState : NSOffState
            
        default: break
        }
        
        return super.validateMenuItem(menuItem)
    }
    
    
    
    // MARK: Notifications
    
    /// set a flag of syntax highlight update if corresponded style has been updated
    func syntaxDidUpdate(_ notification: Notification) {
        
        guard
            let oldName = notification.userInfo?[CEOldNameKey] as? String,
            let newName = notification.userInfo?[CENewNameKey] as? String else { return }
        
        if oldName == self.syntaxStyle.styleName {
            self.setSyntaxStyle(name: newName)
        }
    }
    
    
    
    // MARK: Public Methods
    
    /// Return whole string in the current text storage which document's line endings are already applied to.  (Note: The internal text storage has always LF for its line ending.)
    var string: String {
        
        let editorString = self.textStorage.string // line ending is always LF
        
        if self.lineEnding == .LF {
            return NSString(string: editorString) as String  // make sure being immutable
        }
        
        return (editorString as NSString).replacingNewLineCharacers(with: self.lineEnding)
    }
    
    
    /// return document window's editor wrapper
    var editor: CEEditorWrapper? {
        
        return self.windowController.editor
    }
    
    
    /// transfer file information to UI
    func applyContentToWindow() {
        
        guard let editor = self.editor else { return }
        
        editor.invalidateStyleInTextStorage()
        
        // update status bar and document inspector
        self.analyzer.invalidateFileInfo()
        self.analyzer.invalidateModeInfo()
        self.analyzer.invalidateEditorInfo()
        
        // update incompatible characters if pane is visible
        self.incompatibleCharacterScanner.invalidate()
        
        // apply text orientation
        editor.verticalLayoutOrientation = self.isVerticalText
    }
    
    
    
    // string encoding
    
    /// reinterpret file with the desired encoding and show error dialog if failed
    func reinterpretAndShowError(encoding: String.Encoding) {
        
        do {
            try self.reinterpret(encoding: encoding)
            
        } catch let error as NSError {
            NSBeep()
            if let window = self.windowForSheet {
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                self.presentError(error)
            }
        }
    }
    
    /// reinterpret file with the desired encoding
    func reinterpret(encoding: String.Encoding) throws {
        
        guard let fileURL = self.fileURL else {
            // TODO: add userInfo (The outError under this condition will actually not be used, but better not to pass an empty errer pointer.)
            throw NSError(domain: CotEditorError.domain, code: CotEditorError.reinterpretationFailed.rawValue, userInfo: nil)
        }
        
        // do nothing if given encoding is the same as current one
        if encoding == self.encoding { return }
        
        // reinterpret
        self.readingEncoding = encoding
        do {
            try self.revert(toContentsOf: fileURL, ofType: self.fileType!)
            
        } catch let error as NSError {
            self.readingEncoding = self.encoding
            throw NSError(domain: CotEditorError.domain,
                          code: CotEditorError.reinterpretationFailed.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Can not reinterpret.", comment: ""),
                                     NSLocalizedRecoverySuggestionErrorKey: String(format: NSLocalizedString("The file “%@” could not be reinterpreted using the new encoding “%@”.", comment: ""), fileURL.lastPathComponent!, String.localizedName(of: encoding)),
                                     NSStringEncodingErrorKey: encoding.rawValue,
                                     NSUnderlyingErrorKey: error,
                                     NSURLErrorKey: fileURL])
        }
    }
    
    
    /// change string encoding registering process to the undo manager
    func changeEncoding(to encoding: String.Encoding, withUTF8BOM: Bool, askLossy: Bool, lossy: Bool) -> Bool {  // TODO: throw?
        
        guard encoding != self.encoding || withUTF8BOM != self.hasUTF8BOM else { return true }
        
        let encodingName = NSString.localizedName(ofStringEncoding: encoding.rawValue, withUTF8BOM: withUTF8BOM)
        
        // ask lossy
        guard !askLossy || self.string.canBeConverted(to: encoding) else {
            let error = NSError(domain: CotEditorError.domain,
                                code: CotEditorError.lossyEncodingConversion.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Some characters would have to be changed or deleted in saving as “%@”.", comment: ""), encodingName),
                                           NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Do you want to change encoding and show incompatible characters?", comment: "'"),
                                           NSLocalizedRecoveryOptionsErrorKey: [NSLocalizedString("Cancel", comment: ""),
                                                                                NSLocalizedString("Change Encoding", comment: "")],
                                           NSRecoveryAttempterErrorKey: self,
                                           NSStringEncodingErrorKey: NSNumber(value: encoding.rawValue),
                                           ErrorKey.StringEncodingUTF8BOM: withUTF8BOM
                ])
            
            if let window = self.windowForSheet {
                window.attachedSheet?.orderOut(self)  // close previous sheet
                self.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
            return false
        }
        
        // register undo
        self.undoManager?.prepare(withInvocationTarget: self).objcChangeEncoding(to: self.encoding.rawValue, withUTF8BOM: self.hasUTF8BOM, askLossy: false, lossy: lossy)
        self.undoManager?.setActionName(String(format: NSLocalizedString("Encoding to “%@”", comment: ""), encodingName))
        
        // update encoding
        self.encoding = encoding
        self.hasUTF8BOM = withUTF8BOM
        
        // notify
        NotificationCenter.default.post(name: Document.EncodingDidChangeNotification, object: self)
        
        // update UI
        self.incompatibleCharacterScanner.scan()
        self.analyzer.invalidateModeInfo()
        
        return true
    }
    
    
    /// dummy method for undoManager that can recognize only ObjC-compatible methods...
    func objcChangeEncoding(to encoding: UInt, withUTF8BOM: Bool, askLossy: Bool, lossy: Bool) {
        
        let _ = self.changeEncoding(to: String.Encoding(rawValue: encoding), withUTF8BOM: withUTF8BOM, askLossy: askLossy, lossy: lossy)
    }
    
    
    /// change line endings registering process to the undo manager
    func changeLineEnding(to lineEnding: CENewLineType) {
        
        guard lineEnding != self.lineEnding else { return }
        
        // register undo
        self.undoManager?.prepare(withInvocationTarget: self).changeLineEnding(to: self.lineEnding)
        self.undoManager?.setActionName(String(format: NSLocalizedString("Line Endings to “%@”", comment: ""),
                                               NSString.newLineName(with: lineEnding)))
        
        // update line ending
        self.lineEnding = lineEnding
        
        // notify
        NotificationCenter.default.post(name: Document.LineEndingDidChangeNotification, object: self)
        
        // update UI
        self.analyzer.invalidateModeInfo()
        self.analyzer.invalidateEditorInfo()
    }
    
    
    /// change syntax style with style name
    func setSyntaxStyle(name: String?) {
        
        guard let name = name, !name.isEmpty else { return }
        
        guard let syntaxStyle = CESyntaxManager.shared().style(withName: name), syntaxStyle != self.syntaxStyle else { return }
        
        self.syntaxStyle.cancelAllParses()
        
        // update
        syntaxStyle.textStorage = self.textStorage
        self.syntaxStyle = syntaxStyle
        
        NotificationCenter.default.post(name: Document.SyntaxStyleDidChangeNotification, object: self)
    }
    
    
    
    // MARK: Action Messages
    
    /// save document
    @IBAction override func save(_ sender: AnyObject?) {
        
        self.askSavingSafety { (continuesSaving: Bool) in
            if continuesSaving {
                super.save(sender)
            }
        }
    }
    
    
    /// save document with new name
    override func saveAs(_ sender: AnyObject?) {
        
        self.askSavingSafety { (continuesSaving: Bool) in
            if continuesSaving {
                super.saveAs(sender)
            }
        }
    }
    
    
    /// show Share Service menu
    @IBAction func share(_ sender: AnyObject?) {
        
        guard let view = sender as? NSView else { return }
        
        let items: [URL] = {
            if let url = self.fileURL {
                return [url]
            }
            return []
        }()
        
        let sharingServicePicker = NSSharingServicePicker(items: items)
        sharingServicePicker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        
    }
    
    
    /// share document
    @IBAction func shareFromService(_ sender: AnyObject?) {
        
        guard
            let service = sender?.representedObject as? NSSharingService,
            let fileURL = self.fileURL else { return }
        
        service.perform(withItems: [fileURL])
    }
    
    
    /// change line ending to LF
    @IBAction func changeLineEndingToLF(_ sender: AnyObject?) {
        
        self.changeLineEnding(to: .LF)
    }
    
    
    /// change line ending to CR
    @IBAction func changeLineEndingToCR(_ sender: AnyObject?) {
        
        self.changeLineEnding(to: .CR)
    }
    
    
    /// change line ending to CR/LF
    @IBAction func changeLineEndingToCRLF(_ sender: AnyObject?) {
        
        self.changeLineEnding(to: .CRLF)
    }
    
    
    /// change line ending with sender's tag
    @IBAction func changeLineEnding(_ sender: AnyObject?) {
        
        guard
            let tag = sender?.tag,
            let lineEnding = CENewLineType(rawValue: tag) else { return }
        
        self.changeLineEnding(to: lineEnding)
    }
    
    
    /// change document file encoding
    @IBAction func changeEncoding(_ sender: AnyObject?) {
        
        guard let tag = sender?.tag, let encodingName = sender?.title else { return }
        
        let encoding = String.Encoding(rawValue: UInt(abs(tag)))
        let withUTF8BOM = (tag == -Int(String.Encoding.utf8.rawValue))
        
        guard encoding != self.encoding || withUTF8BOM != self.hasUTF8BOM else { return }
        
        // change encoding immediately if there is nothing to worry about
        if self.textStorage.string.isEmpty ||
            self.fileURL == nil ||
            encoding == .utf8 && encoding == self.encoding {
            let _ = self.changeEncoding(to: encoding, withUTF8BOM: withUTF8BOM, askLossy: true, lossy: false)
            return
        }
        
        // ask whether just change the encoding or reinterpret docuemnt file
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("File encoding", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Do you want to convert or reinterpret this document using “%@”?", comment: ""), encodingName)
        alert.addButton(withTitle: NSLocalizedString("Convert", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Reinterpret", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        
        alert.beginSheetModal(for: self.windowForSheet!) { [unowned self] (returnCode: NSModalResponse) in
            switch returnCode {
            case NSAlertFirstButtonReturn:  // = Convert
                let _ = self.changeEncoding(to: encoding, withUTF8BOM: withUTF8BOM, askLossy: true, lossy: false)
                
            case NSAlertSecondButtonReturn:  // = Reinterpret
                if self.isDocumentEdited {
                    let alert = NSAlert()
                    alert.messageText = String(format: NSLocalizedString("The file “%@” has unsaved changes.", comment: ""), self.fileURL!.lastPathComponent!)
                    alert.informativeText = NSLocalizedString("Do you want to discard the changes and reset the file encoding?", comment: "")
                    alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                    alert.addButton(withTitle: NSLocalizedString("Discard Changes", comment: ""))
                    
                    self.windowForSheet!.attachedSheet?.orderOut(self)  // close previous sheet
                    alert.beginSheetModal(for: self.windowForSheet!, completionHandler: { (returnCode: NSModalResponse) in
                        switch returnCode {
                        case NSAlertFirstButtonReturn:  // = Cancel
                            // reset toolbar selection for in case if the operation was invoked from the toolbar popup
                            NotificationCenter.default.post(name: Document.EncodingDidChangeNotification, object: self)
                            
                        case NSAlertSecondButtonReturn:  // = Discard Changes
                            let _ = try? self.reinterpret(encoding: encoding)
                            
                        default: break
                        }
                    })
                    
                } else {
                    let _ = try? self.reinterpret(encoding: encoding)
                    
                }
                
            case NSAlertThirdButtonReturn:  // = Cancel
                // reset toolbar selection for in case if the operation was invoked from the toolbar popup
                NotificationCenter.default.post(name: Document.EncodingDidChangeNotification, object: self)
                
            default: break
            }
        }
    }
    
    
    /// change syntax style
    @IBAction func changeSyntaxStyle(_ sender: AnyObject?) {
        
        guard let name = sender?.title, name != self.syntaxStyle.styleName else { return }
        
        self.setSyntaxStyle(name: name)
    }
    
    
    /// insert IANA CharSet name to editor's insertion point
    @IBAction func insertIANACharSetName(_ sender: AnyObject?) {
        
        guard let string = NSString.ianaCharSetName(ofStringEncoding: self.encoding.rawValue) else { return }
        
        self.editor?.insert(string: string)
    }
    
    
    
    // MARK: Private Methods
    
    /// read String from Dada detecting file encoding automatically
    private func string(data: Data, xattrEncoding: String.Encoding?) throws -> (String, String.Encoding) {
        
        // try interpreting with xattr encoding
        if let xattrEncoding = xattrEncoding {
            // just trust xattr encoding if content is empty
            if let string = data.isEmpty ? "" : String(data: data, encoding: xattrEncoding) {
                return (string, xattrEncoding)
            }
        }
        
        // detect encoding from data
        var usedEncodingInt: UInt = 0
        let string = try NSString(data: data, suggestedCFEncodings: UserDefaults.standard.array(forKey: DefaultKey.encodingList.rawValue) as! [NSNumber], usedEncoding: &usedEncodingInt) as String
        let usedEncoding = String.Encoding(rawValue: usedEncodingInt)
        
        // try reading encoding declaration and take priority of it if it seems well
        if let scannedEncoding = self.scanEncodingFromDeclaration(content: string), scannedEncoding != usedEncoding {
            if let string = String(data: data, encoding: scannedEncoding) {
                return (string, scannedEncoding)
            }
        }
        
        return (string, usedEncoding)
    }
    
    
    /// detect file encoding from encoding declaration like "charset=" or "encoding=" in file content
    private func scanEncodingFromDeclaration(content: String) -> String.Encoding? {
        
        guard UserDefaults.standard.bool(forKey: DefaultKey.referToEncodingTag.rawValue) else { return nil }
        
        let suggestedCFEncodings = (UserDefaults.standard.array(forKey: DefaultKey.encodingList.rawValue) as? [NSNumber]) ?? []
        let encoding = (content as NSString).scanEncodingDeclaration(forTags: ["charset=", "encoding=", "@charset", "encoding:", "coding:"],
                                                                    upTo: MaxEncodingScanLength,
                                                                    suggestedCFEncodings: suggestedCFEncodings)
        
        return (encoding == UInt(NSNotFound)) ? nil : String.Encoding(rawValue: encoding)
    }
    
    
    /// check if can save safety with the current encoding and ask if not
    private func askSavingSafety(completionHandler:((Bool) -> Void)) {
        
        let content = self.string
        let encoding = self.encoding
        
        // check encoding declaration in the document and alert if incompatible with saving encoding
        if !self.suppressesIANACharsetConflictAlert {
            do {
                try self.checkSavingSafetyForConverting(content: content, encoding: encoding)
                
            } catch let error as NSError {
                // --> ask directly with a non-sheet NSAlert for the suppression button
                let alert = NSAlert(error: error)
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = NSLocalizedString("Do not show this warning for this document again", comment: "")
                
                let result = alert.runModal()
                // do not show the alert in this document again
                if alert.suppressionButton?.state == NSOnState {
                    self.suppressesIANACharsetConflictAlert = true
                }
                
                switch result {
                case NSAlertFirstButtonReturn:  // == Cancel
                    completionHandler(false)
                    return
                default: break  // == Continue Saving
                }
            }
        }
        
        // check file encoding for conversion and ask user how to solve
        do {
            try self.checkSavingSafetyForConverting(content: content, encoding: encoding)
            
        } catch let error as NSError {
            self.recoverBlock = completionHandler
            self.presentError(error,
                              modalFor: self.windowForSheet!,
                              delegate: self,
                              didPresent: #selector(didPresentErrorWithRecovery(didRecover:block:)),
                              contextInfo: nil)
        }
        
        completionHandler(true)
    }
    
    
    /// check compatibility of saving encoding with the encoding decralation in document
    private func checkSavingSafetyWithIANACharSetName(content: String, encoding: String.Encoding) throws {
        
        guard let IANACharSetEncoding = self.scanEncodingFromDeclaration(content: content) else { return }
        
        guard CEIsCompatibleIANACharSetEncoding(IANACharSetEncoding.rawValue, encoding.rawValue) else {
            let encodingName = String.localizedName(of: encoding)
            let IANAName = String.localizedName(of: IANACharSetEncoding)
            
            throw NSError(domain: CotEditorError.domain,
                          code: CotEditorError.unconvertibleCharacters.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("The encoding is “%@”, but the IANA charset name in text is “%@”.", comment: ""), encodingName, IANAName),
                                     NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Do you want to continue processing?", comment: ""),
                                     NSLocalizedRecoveryOptionsErrorKey: [NSLocalizedString("Cancel", comment: ""),
                                                                          NSLocalizedString("Continue Saving", comment: "")],
                                     NSRecoveryAttempterErrorKey: self,
                                     NSStringEncodingErrorKey: NSNumber(value: encoding.rawValue)])
        }
    }
    
    
    /// check if the content can be saved with the file encoding
    private func checkSavingSafetyForConverting(content: String, encoding: String.Encoding) throws {
        
        // convert yen if needed
        let newString = (content as NSString).convertingYenSign(forEncoding: encoding.rawValue)
        
        guard newString.canBeConverted(to: encoding) else {
            let encodingName = String.localizedName(of: encoding)
            
            throw NSError(domain: CotEditorError.domain,
                          code: CotEditorError.unconvertibleCharacters.rawValue,
                          userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Some characters would have to be changed or deleted in saving as “%@”.", comment: ""), encodingName),
                                     NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Do you want to continue processing?", comment: ""),
                                     NSLocalizedRecoveryOptionsErrorKey: [NSLocalizedString("Show Incompatible Chars", comment: ""),
                                                                          NSLocalizedString("Save Available Strings", comment: ""),
                                                                          NSLocalizedString("Cancel", comment: "")],
                                     NSRecoveryAttempterErrorKey: self,
                                     NSStringEncodingErrorKey: NSNumber(value: encoding.rawValue)])
        }
    }
    
    
    /// notify about external file update
    private func notifyExternalFileUpdate() {
        
        // rise a flag
        self.needsShowUpdateAlertWithBecomeKey = true
        
        if NSApp.isActive {
            // display dialog immediately
            self.showUpdatedByExternalProcessAlert()
            
        } else {
            // alert first when application becomes active
            NotificationCenter.default.addObserver(self, selector: #selector(showUpdatedByExternalProcessAlert), name: .NSApplicationDidBecomeActive, object: nil)
            
            // let application icon in Dock jump
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
    
    
    /// display alert about file modification by an external process
    func showUpdatedByExternalProcessAlert() {
    
        NotificationCenter.default.removeObserver(self, name: .NSApplicationDidBecomeActive, object: nil)
        
        guard let fileURL = self.fileURL,
            self.needsShowUpdateAlertWithBecomeKey &&
                !self.isExternalUpdateAlertShown  // do nothing if alert is already shown
            else { return }
        
        let messageText: String = {
            if self.isDocumentEdited {
                return "The file has been modified by another application. There are also unsaved changes in CotEditor."
            } else {
                return "The file has been modified by another application."
            }
        }()
        
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(messageText, comment: "")
        alert.informativeText = NSLocalizedString("Do you want to keep CotEditor’s edition or update to the modified edition?", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Keep CotEditor’s Edition", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Update", comment: ""))
        
        // mark the alert as critical in order to interpret other sheets already attached
        if self.windowForSheet?.attachedSheet != nil {
            alert.alertStyle = .critical
        }
        
        self.isExternalUpdateAlertShown = true
        self.windowForSheet?.orderFront(self)
        
        // display alert
        alert.beginSheetModal(for: self.windowForSheet!) { [unowned self] (returnCode: NSModalResponse) in
            
            if returnCode == NSAlertSecondButtonReturn { // == Revert
                let _ = try? self.revert(toContentsOf: fileURL, ofType: self.fileType!)
            }
            
            self.isExternalUpdateAlertShown = false
            self.needsShowUpdateAlertWithBecomeKey = false
        }
    }
    
    
    /// perform didRecoverBlock after recovering presented error
    private var recoverBlock: ((Bool) -> Void)? = nil
    func didPresentErrorWithRecovery(didRecover: Bool, block: UnsafeMutablePointer<Void>) {
        self.recoverBlock?(didRecover)
        self.recoverBlock = nil
    }
    
}
