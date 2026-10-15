/*
 Copyright (c) 2001-2021, Kurt Revis.  All rights reserved.

 This source code is licensed under the BSD-style license found in the
 LICENSE file in the root directory of this source tree.
 */

import Cocoa
import SnoizeMIDI

class MonitorWindowController: NSWindowController {

    init() {
        super.init(window: nil)
        shouldCascadeWindows = true
        shouldCloseDocument = true

        NotificationCenter.default.addObserver(self, selector: #selector(self.displayPreferencesDidChange(_:)), name: .displayPreferenceChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var windowNibName: NSNib.Name? {
        return "MIDIMonitor"
    }

    // MARK: Internal

    // Sources controls
    @IBOutlet private var sourcesDisclosureButton: DisclosureButton!
    @IBOutlet private var sourcesDisclosableView: DisclosableView!
    @IBOutlet private var sourcesOutlineView: SourcesOutlineView!

    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private let sourceSearchField = NSSearchField()
    private let sourceSummary = NSTextField(labelWithString: "")
    private var visibleSourceGroups: [CombinationInputStreamSourceGroup] = []
    private var visibleSourceBoxes: [ObjectIdentifier: [Box<InputStreamSource>]] = [:]
    private var hasLoadedSources = false
    private var expandedSourceGroups = Set<ObjectIdentifier>()
    private var previousSourceQuery = ""
    private var filterIsShown = false
    private var filterHeightConstraint: NSLayoutConstraint?
    private var sidebarWidth: CGFloat = 340

    // Filter controls
    @IBOutlet private var filterDisclosureButton: DisclosureButton!
    @IBOutlet private var filterDisclosableView: DisclosableView!
    @IBOutlet private var voiceMessagesCheckBox: NSButton!
    @IBOutlet private var voiceMessagesMatrix: NSMatrix!
    @IBOutlet private var systemCommonCheckBox: NSButton!
    @IBOutlet private var systemCommonMatrix: NSMatrix!
    @IBOutlet private var realTimeCheckBox: NSButton!
    @IBOutlet private var realTimeMatrix: NSMatrix!
    @IBOutlet private var systemExclusiveCheckBox: NSButton!
    @IBOutlet private var invalidCheckBox: NSButton!
    @IBOutlet private var channelRadioButtons: NSMatrix!
    @IBOutlet private var oneChannelField: NSTextField!
    private var filterCheckboxes: [NSButton] {
        return [voiceMessagesCheckBox, systemCommonCheckBox, realTimeCheckBox, systemExclusiveCheckBox, invalidCheckBox]
    }
    private var filterMatrixCells: [NSCell] {
        return voiceMessagesMatrix.cells + systemCommonMatrix.cells + realTimeMatrix.cells
    }

    // Event controls
    @IBOutlet private var messagesTableView: NSTableView!
    @IBOutlet private var clearButton: NSButton!
    @IBOutlet private var maxMessageCountField: NSTextField!
    @IBOutlet private var sysExProgressIndicator: NSProgressIndicator!
    @IBOutlet private var sysExProgressField: NSTextField!

    // Transient data
    private var oneChannel: Int = 1
    private var inputSourceGroups: [CombinationInputStreamSourceGroup] = []
    private var displayedMessages: [Message] = []
    private var messagesNeedScrollToBottom: Bool = false
    private var nextMessagesRefreshDate: NSDate?
    private var nextMessagesRefreshTimer: Timer?
    private var isRestoringWindowSettings = false
    private var doneSettingDocument = false

    // Constants
    private let minimumMessagesRefreshDelay: TimeInterval = 0.10

}

extension MonitorWindowController {

    // MARK: Window and document

    override func windowDidLoad() {
        super.windowDidLoad()

        sourcesOutlineView.outlineTableColumn = sourcesOutlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "name"))
        sourcesOutlineView.autoresizesOutlineColumn = false

        let checkboxCell = NonHighlightingButtonCell(textCell: "")
        checkboxCell.setButtonType(.switch)
        checkboxCell.controlSize = .small
        checkboxCell.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        checkboxCell.allowsMixedState = true
        sourcesOutlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "enabled"))?.dataCell = checkboxCell

        let textFieldCell = NonHighlightingTextFieldCell(textCell: "")
        textFieldCell.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sourcesOutlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "name"))?.dataCell = textFieldCell

        voiceMessagesCheckBox.allowsMixedState = true
        systemCommonCheckBox.allowsMixedState = true
        realTimeCheckBox.allowsMixedState = true

        (maxMessageCountField.formatter as? NumberFormatter)?.allowsFloats = false
        (oneChannelField.formatter as? NumberFormatter)?.allowsFloats = false

        messagesTableView.autosaveName = "MessagesTableView2"
        messagesTableView.autosaveTableColumns = true
        messagesTableView.target = self
        messagesTableView.doubleAction = #selector(self.showDetailsOfSelectedMessages(_:))

        configureModernLayout()
        hideSysExProgressIndicator()
    }

    override var document: AnyObject? {
        didSet {
            guard let document else { return }
            guard let smmDocument = document as? Document else { fatalError() }

            _ = window // Make sure the window and all views are loaded first

            if !smmDocument.isDraft && smmDocument.fileURL != nil {
                windowFrameAutosaveName = ""
            }

            updateMessages(scrollingToBottom: false)
            updateSources()
            updateMaxMessageCount()
            updateFilterControls()

            restoreWindowSettings(smmDocument.windowSettings ?? [:])

            doneSettingDocument = true
        }
    }

    private var midiDocument: Document? {
        return document as? Document
    }

    private func trivialWindowSettingsDidChange() {
        // Mark the document as dirty, so the state of the window gets saved.
        // However, use NSChangeDiscardable, so it doesn't cause a locked document to get dirtied for a trivial change.
        // Also, don't do it for untitled, unsaved documents which have no fileURL yet, because that's annoying.
        // Similarly, don't do it if "Ask to keep changes when closing documents" is turned on.

        guard let midiDocument else { return }
        if midiDocument.fileURL != nil && !UserDefaults.standard.bool(forKey: "NSCloseAlwaysConfirmsChanges") {
            let change = NSDocument.ChangeType(rawValue: (NSDocument.ChangeType.changeDone.rawValue | NSDocument.ChangeType.changeDiscardable.rawValue))!
            midiDocument.updateChangeCount(change)
        }
    }

}

extension MonitorWindowController: NSUserInterfaceValidations {

    // MARK: General UI

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return window?.firstResponder == messagesTableView && messagesTableView.numberOfSelectedRows > 0
        case #selector(self.showDetailsOfSelectedMessages(_:)):
            return selectedMessages.count > 0
        case #selector(self.clearMessages(_:)):
            return messagesTableView.numberOfRows > 0
        default:
            return false
        }
    }

}

extension MonitorWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    // MARK: Input Sources Outline View

    // Note: On macOS 10.15 (and possibly before), we can provide items which are Swift structs.
    // However, in macOS 10.9-10.11 (and maybe later) this causes a crash in swift_unknownObjectRetain.
    // Work around it by boxing the structs (InputStreamSource) in Box.

    func updateSources() {
        guard let midiDocument else { return }

        inputSourceGroups = midiDocument.inputSourceGroups
        reloadVisibleSources()
    }

    func revealInputSources(_ sources: Set<InputStreamSource>) {
        // Show the sources first
        sidebarItem.isCollapsed = false
        sourceSearchField.stringValue = ""
        reloadVisibleSources()

        // Of all of the input sources, find the first one which is in the given set.
        // Then expand the outline view to show this source, and scroll it to be visible.
        // Subsequent sources will expand their groups (if necessary) but won't scroll.
        var foundFirstSource = false
        for group in inputSourceGroups where group.expandable {
            for source in group.boxedSources where sources.contains(source.unbox) {
                // Found one!
                sourcesOutlineView.expandItem(group)

                if !foundFirstSource {
                    sourcesOutlineView.scrollRowToVisible(sourcesOutlineView.row(forItem: source))
                    foundFirstSource = true
                }
            }
        }
    }

    @IBAction func toggleSourcesShown(_ sender: Any?) {
        if !sidebarItem.isCollapsed {
            sidebarWidth = sidebarItem.viewController.view.frame.width
        }
        sidebarItem.isCollapsed.toggle()
        if !sidebarItem.isCollapsed {
            window?.contentView?.layoutSubtreeIfNeeded()
            splitController.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
        trivialWindowSettingsDidChange()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return visibleSourceGroups.count
        }
        else if let group = item as? CombinationInputStreamSourceGroup {
            return boxes(for: group).count
        }
        else {
            return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return visibleSourceGroups[index]
        }
        else if let group = item as? CombinationInputStreamSourceGroup {
            return boxes(for: group)[index]
        }
        else {
            fatalError()
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let group = item as? CombinationInputStreamSourceGroup {
            return group.expandable
        }
        else {
            return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        guard let item else { fatalError() }

        let identifier = tableColumn?.identifier.rawValue
        switch identifier {
        case "name":
            if let group = item as? CombinationInputStreamSourceGroup {
                return group.name
            }
            else if let source = item as? Box<InputStreamSource> {
                return source.unbox.name ?? ""
            }
            else {
                return nil
            }

        case "enabled":
            if let group = item as? CombinationInputStreamSourceGroup {
                return buttonStateForInputSources(boxes(for: group).map { $0.unbox })
            }
            else if let source = item as? Box<InputStreamSource> {
                return buttonStateForInputSources([source.unbox])
            }
            else {
                return nil
            }

        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, byItem item: Any?) {
        guard let midiDocument else { return }
        guard let item,
              let number = object as? NSNumber else { fatalError() }

        var newState = NSControl.StateValue(rawValue: number.intValue)
        // It doesn't make sense to switch from off to mixed, so go directly to on
        if newState == .mixed {
            newState = .on
        }

        let sources: [InputStreamSource]
        if let group = item as? CombinationInputStreamSourceGroup {
            sources = boxes(for: group).map { $0.unbox }
        }
        else if let source = item as? Box<InputStreamSource> {
            sources = [source.unbox]
        }
        else {
            sources = []
        }

        var newSelectedSources = midiDocument.selectedInputSources
        for source in sources {
            if newState == .on {
                newSelectedSources.insert(source)
            }
            else {
                newSelectedSources.remove(source)
            }
        }

        midiDocument.selectedInputSources = newSelectedSources
    }

    func outlineView(_ outlineView: NSOutlineView, willDisplayOutlineCell cell: Any, for tableColumn: NSTableColumn?, item: Any) {
        // cause the button cell to always use a "dark" triangle
        if let cell = cell as? NSCell {
            cell.backgroundStyle = .normal
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldTrackCell cell: NSCell, for tableColumn: NSTableColumn?, item: Any) -> Bool {
        // Allow clicks in the checkbox column to apply to the checkbox, not to attempt to change selection
        return tableColumn?.identifier.rawValue == "enabled"
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        // Don't allow any selection
        return IndexSet()
    }

    private func buttonStateForInputSources(_ sources: [InputStreamSource]) -> NSControl.StateValue {
        guard let midiDocument else { return .off }
        let selectedSources = midiDocument.selectedInputSources

        var areAnySelected = false
        var areAnyNotSelected = false

        for source in sources {
            if selectedSources.contains(source) {
                areAnySelected = true
            }
            else {
                areAnyNotSelected = true
            }

            if areAnySelected && areAnyNotSelected {
                return .mixed
            }
        }

        return areAnySelected ? .on : .off
    }

}

extension MonitorWindowController {

    // MARK: Filter

    func updateFilterControls() {
        guard let midiDocument else { return }

        let currentMask = midiDocument.filterMask.rawValue

        // Each filter checkbox has a tag with the mask of filters that it is based on.
        // Top-level filter checkboxes are standalone NSButtons. They include the state of second-level checkboxes, so their tags may have multiple bits set, and they may be mixed state.
        // Second-level filter checkboxes are NSCells in an NSMatrix. Their tags have only a single bit set, and they are either on or off, never mixed state.
        for checkbox in filterCheckboxes {
            let buttonMask = checkbox.tag   // multiple bits
            checkbox.state = switch currentMask & buttonMask {
            case buttonMask: .on     // all on
            case 0:          .off    // all off
            default:         .mixed  // some but not all on
            }
        }

        for checkbox in filterMatrixCells {
            let buttonMask = checkbox.tag   // only a single bit
            checkbox.state = switch currentMask & buttonMask {
            case buttonMask: .on            // on
            case 0:          .off           // off
            default:         fatalError()   // shouldn't happen, something is wrong with the tag
            }
        }

        if midiDocument.isShowingAllChannels {
            channelRadioButtons.selectCell(withTag: 0)
            oneChannelField.isEnabled = false
        }
        else {
            channelRadioButtons.selectCell(withTag: 1)
            oneChannelField.isEnabled = true
            oneChannel = midiDocument.oneChannelToShow
        }
        oneChannelField.objectValue = NSNumber(value: oneChannel)
    }

    @IBAction func toggleFilterShown(_ sender: Any?) {
        setFilterShown(!filterIsShown)
        trivialWindowSettingsDidChange()
    }

    private func changeFilter(tag: Int, state: NSControl.StateValue) {
        guard let midiDocument else { return }

        let turnBitsOn = switch state {
        case .on, .mixed: true
        default: false
        }

        midiDocument.changeFilterMask(Message.TypeMask(rawValue: tag), turnBitsOn: turnBitsOn)
    }

    @IBAction func changeFilter(_ sender: Any?) {
        if let button = sender as? NSButton {
            changeFilter(tag: button.tag, state: button.state)
        }
    }

    @IBAction func changeFilterFromMatrix(_ sender: Any?) {
        if let matrix = sender as? NSMatrix,
           let buttonCell = matrix.selectedCell() as? NSButtonCell {
            changeFilter(tag: buttonCell.tag, state: buttonCell.state)
        }
    }

    @IBAction func setChannelRadioButton(_ sender: Any?) {
        guard let midiDocument else { return }

        if let matrix = sender as? NSMatrix {
            if matrix.selectedCell()?.tag == 0 {
                midiDocument.showAllChannels()
            }
            else {
                midiDocument.showOnlyOneChannel(oneChannel)
            }
        }
    }

    @IBAction func setChannel(_ sender: Any?) {
        guard let midiDocument else { return }

        if let control = sender as? NSControl {
            let channel = (control.objectValue as? NSNumber)?.intValue ?? 0
            midiDocument.showOnlyOneChannel(channel)
        }
    }

}

extension MonitorWindowController: NSTableViewDataSource {

    // MARK: Messages Table View

    func updateMaxMessageCount() {
        guard let midiDocument else { return }

        maxMessageCountField.objectValue = NSNumber(value: midiDocument.maxMessageCount)
    }

    func updateVisibleMessages() {
        // Traditionally this was just messagesTableView.reloadData(), but as of macOS 10.15 (and perhaps earlier)
        // that sometimes, the first time after the window is shown, has a side-effect of changing the scroll position
        // (inappropriately adjusting for the header height). It's better to do a more targeted update, anyway.
        let visibleRowRange = messagesTableView.rows(in: messagesTableView.visibleRect)
        let rowIndexes = IndexSet(integersIn: visibleRowRange.lowerBound ..< visibleRowRange.upperBound)
        messagesTableView.reloadData(forRowIndexes: rowIndexes, columnIndexes: IndexSet(integersIn: 0 ..< messagesTableView.numberOfColumns))
    }

    func updateMessages(scrollingToBottom: Bool) {
        // Reloading the NSTableView can be excruciatingly slow, and if messages are coming in quickly,
        // we will hog a lot of CPU. So we make sure that we don't do it too often.

        if scrollingToBottom {
            messagesNeedScrollToBottom = true
        }

        if nextMessagesRefreshTimer != nil {
            // We're going to refresh soon, so don't do anything now.
            return
        }

        let timeUntilNextRefresh = nextMessagesRefreshDate?.timeIntervalSinceNow ?? 0
        if timeUntilNextRefresh <= 0 {
            // Refresh right away, since we haven't recently.
            refreshMessagesTableView()
        }
        else {
            // We have refreshed recently.
            // Schedule an event to make us refresh when we are next allowed to do so.
            nextMessagesRefreshTimer = Timer.scheduledTimer(timeInterval: timeUntilNextRefresh, target: self, selector: #selector(self.refreshMessagesTableViewFromTimer(_:)), userInfo: nil, repeats: false)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedMessages.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let message = displayedMessages[row]

        switch tableColumn?.identifier.rawValue {
        case "timeStamp":
            return message.timeStampForDisplay
        case "source":
            return message.originatingEndpointForDisplay
        case "type":
            return message.typeForDisplay
        case "channel":
            return message.channelForDisplay
        case "data":
            if UserDefaults.standard.bool(forKey: MessageFormatter.expertModePreferenceKey) {
                return message.expertDataForDisplay
            }
            else {
                return message.dataForDisplay
            }
        default:
            return nil
        }
    }

    @IBAction func clearMessages(_ sender: Any?) {
        guard let midiDocument else { return }

        midiDocument.clearSavedMessages()
    }

    @IBAction func setMaximumMessageCount(_ sender: Any?) {
        guard let midiDocument else { return }
        guard let control = sender as? NSControl else { fatalError() }

        if let number = control.objectValue as? NSNumber {
            midiDocument.maxMessageCount = number.intValue
        }
        else {
            updateMaxMessageCount()
        }
    }

    @IBAction func copy(_ sender: Any?) {
        guard window?.firstResponder == messagesTableView else { return }

        let columns = messagesTableView.tableColumns
        let rowStrings = messagesTableView.selectedRowIndexes.map { (row) -> String in
            let columnStrings = columns.map { (column) -> String in
                tableView(messagesTableView, objectValueFor: column, row: row) as? String ?? ""
            }
            let rowString = columnStrings.joined(separator: "\t")
            return rowString
        }
        let totalString = rowStrings.joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(totalString, forType: .string)
    }

    @IBAction func showDetailsOfSelectedMessages(_ sender: Any?) {
        guard let midiDocument else { return }

        for message in selectedMessages {
            midiDocument.detailsWindowController(for: message).showWindow(nil)
        }
    }

    @objc private func displayPreferencesDidChange(_ notification: Notification) {
        updateVisibleMessages()
    }

    private var selectedMessages: [Message] {
        return messagesTableView.selectedRowIndexes.map { displayedMessages[$0] }
    }

    private func refreshMessagesTableView() {
        guard let midiDocument else { return }

        let oldMessages = displayedMessages
        let newMessages = midiDocument.savedMessages
        displayedMessages = newMessages

        // Keep the same messages selected, if possible
        let newRowIndexes = IndexSet(messagesTableView.selectedRowIndexes.compactMap { newMessages.firstIndex(of: oldMessages[$0]) })

        // If the table view was already scrolled to the bottom, remain scrolled to the bottom when new messages come in
        let wasAtBottom = messagesTableView.bounds.maxY - messagesTableView.visibleRect.maxY < messagesTableView.rowHeight

        // NSTableView won't detect a change in displayedMessages.count unless we tell it
        if oldMessages.count != newMessages.count {
            messagesTableView.noteNumberOfRowsChanged()
        }

        // Without doing a more complex diff of the message objects in the array, all we know is that the data for
        // any row and column may have changed, so reload them all.
        messagesTableView.reloadData(forRowIndexes: IndexSet(integersIn: 0 ..< displayedMessages.count), columnIndexes: IndexSet(integersIn: 0 ..< messagesTableView.numberOfColumns))

        if messagesNeedScrollToBottom && wasAtBottom {
            let messageCount = displayedMessages.count
            if messageCount > 0 {
                messagesTableView.scrollRowToVisible(messageCount - 1)
            }
        }
        messagesNeedScrollToBottom = false

        messagesTableView.selectRowIndexes(newRowIndexes, byExtendingSelection: false)

        // Figure out when we should next be allowed to refresh.
        nextMessagesRefreshDate = NSDate(timeIntervalSinceNow: minimumMessagesRefreshDelay)
    }

    @objc private func refreshMessagesTableViewFromTimer(_ timer: Timer) {
        nextMessagesRefreshTimer = nil
        refreshMessagesTableView()
    }

    func updateSysExReadIndicator() {
        showSysExProgressIndicator()
    }

    func stopSysExReadIndicator() {
        hideSysExProgressIndicator()
    }

    private func showSysExProgressIndicator() {
        sysExProgressField.isHidden = false
        sysExProgressIndicator.startAnimation(nil)
    }

    private func hideSysExProgressIndicator() {
        sysExProgressField.isHidden = true
        sysExProgressIndicator.stopAnimation(nil)
    }

}

extension MonitorWindowController {

    // MARK: Window settings

    private static let sourcesShownKey = "areSourcesShown"
    private static let filterShownKey = "isFilterShown"
    private static let windowFrameKey = "windowFrame"
    private static let messagesScrollPointX = "messagesScrollPointX"
    private static let messagesScrollPointY = "messagesScrollPointY"

    private static let untitledSourcesShownKey = "SMMUntitledAreSourcesShown"
    private static let untitledFilterShownKey = "SMMUntitledIsFilterShown"

    static var windowSettingsKeys: [String] {
        return [sourcesShownKey, filterShownKey, windowFrameKey, messagesScrollPointX, messagesScrollPointY, "sidebarWidth", "sidebarLayoutVersion"]
    }

    var windowSettings: [String: Any] {
        var windowSettings: [String: Any] = [:]

        // Remember whether our sections are shown or hidden
        windowSettings[Self.sourcesShownKey] = NSNumber(value: !sidebarItem.isCollapsed)
        if filterIsShown {
            windowSettings[Self.filterShownKey] = NSNumber(value: true)
        }

        // And remember the window frame, so we can restore it after restoring those
        if let windowFrameDescriptor = window?.frameDescriptor {
            windowSettings[Self.windowFrameKey] = windowFrameDescriptor as AnyObject
        }

        // And the scroll position of the messages
        if let clipView = messagesTableView.enclosingScrollView?.contentView {
            let clipBounds = clipView.bounds
            let scrollPoint = messagesTableView.convert(clipBounds.origin, from: clipView)
            windowSettings[Self.messagesScrollPointX] = NSNumber(value: Double(scrollPoint.x))
            windowSettings[Self.messagesScrollPointY] = NSNumber(value: Double(scrollPoint.y))
        }

        if !sidebarItem.isCollapsed {
            sidebarWidth = sidebarItem.viewController.view.frame.width
        }
        windowSettings["sidebarWidth"] = sidebarWidth
        windowSettings["sidebarLayoutVersion"] = 1
        return windowSettings
    }

    private func restoreWindowSettings(_ windowSettings: [String: Any]) {
        guard let window else { return }

        isRestoringWindowSettings = true
        defer { isRestoringWindowSettings = false }

        // Remember the original window frame in case we need it later. This is
        // - its size and position in the xib
        // - or the previously autosaved frame, if present
        // - plus any AppKit adjustments like cascading
        let originalFrameDescriptor = window.frameDescriptor

        // Old documents used a short, vertically collapsing source panel.
        // Start the new layout with its sidebar visible when migrating them.
        let isSidebarLayout = windowSettings["sidebarLayoutVersion"] as? Int == 1
        sidebarItem.isCollapsed = isSidebarLayout && !((windowSettings[Self.sourcesShownKey] as? NSNumber)?.boolValue ?? true)
        let filterShown = (windowSettings[Self.filterShownKey] as? NSNumber)?.boolValue ?? false
        setFilterShown(filterShown)

        // Then, since those may have resized the window, set the frame back to what we expect.
        // (If we don't have a frame in the document, use the original frame.)
        let windowFrame = windowSettings[Self.windowFrameKey] as? NSWindow.PersistableFrameDescriptor ?? originalFrameDescriptor
        window.setFrame(from: windowFrame)
        var frame = window.frame
        frame.size.width = max(frame.width, window.minSize.width)
        frame.size.height = max(frame.height, window.minSize.height)
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        sidebarWidth = CGFloat((windowSettings["sidebarWidth"] as? NSNumber)?.doubleValue ?? 340)
        if !sidebarItem.isCollapsed {
            splitController.splitView.setPosition(min(max(sidebarWidth, 240), max(240, splitController.splitView.bounds.width - 600)), ofDividerAt: 0)
        }

        if let scrollX = windowSettings[Self.messagesScrollPointX] as? NSNumber,
           let scrollY = windowSettings[Self.messagesScrollPointY] as? NSNumber {
            let scrollPoint = NSPoint(x: scrollX.doubleValue, y: scrollY.doubleValue)
            messagesTableView.scroll(scrollPoint)
        }
    }

}

extension MonitorWindowController: NSWindowDelegate {

    // Lifecycle

    func windowWillClose(_ notification: Notification) {
        // Clean up when the window is closed. This window controller will go away soon.
        NotificationCenter.default.removeObserver(self, name: .displayPreferenceChanged, object: nil)
        nextMessagesRefreshTimer?.invalidate()
        nextMessagesRefreshTimer = nil
    }

    // NSWindowRestoration-related:
    //
    // In some cases, the document's saved window settings will not match
    // the window size that was automatically encoded in restorable state.
    // (For instance, if we don't dirty the document when the window settings
    // were changed, and the user didn't save before quitting, and autosave
    // is turned off.)
    // Therefore, we must also put the window settings into the restorable
    // state, and restore that after the regular document settings are done.

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        state.encode(windowSettings, forKey: "windowSettings")
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        if let decodedWindowSettings = state.decodeObject(of: [NSDictionary.self, NSNumber.self, NSString.self], forKey: "windowSettings") as? [String: Any] {
            restoreWindowSettings(decodedWindowSettings)
        }
    }

}

extension MonitorWindowController: FastAnimatingWindowDelegate {

    func windowDidSaveFrame(window: FastAnimatingWindow, usingName name: NSWindow.FrameAutosaveName) {
        if !isRestoringWindowSettings && doneSettingDocument {
            // Also save whether each disclosable section is shown, since we want to
            // restore them all together in a new document in order to be coherent
            let defaults = UserDefaults.standard
            defaults.setValue(!sidebarItem.isCollapsed, forKey: Self.untitledSourcesShownKey)
            defaults.setValue(filterIsShown, forKey: Self.untitledFilterShownKey)
        }
    }

}

// MARK: Sidebar layout

extension MonitorWindowController: NSSearchFieldDelegate {

    private func configureModernLayout() {
        guard let window,
              let sourcesScroll = sourcesOutlineView.enclosingScrollView,
              let eventsScroll = messagesTableView.enclosingScrollView else { return }

        // Retain the original controls, their bindings and their MIDI data sources.
        // Only the layout is replaced; the MIDI pipeline remains unchanged.
        let progressContainer = sysExProgressIndicator.superview!
        let controls: [NSView] = [sourcesScroll, eventsScroll, filterDisclosableView,
                                  maxMessageCountField, clearButton, progressContainer]
        for view in controls {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        let sidebar = NSViewController()
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view = background
        let heading = NSTextField(labelWithString: "Sources")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        sourceSearchField.placeholderString = "Search MIDI ports"
        sourceSearchField.delegate = self
        sourceSearchField.sendsSearchStringImmediately = true
        sourceSearchField.setAccessibilityLabel("Search MIDI ports")
        sourceSummary.font = .systemFont(ofSize: 11)
        sourceSummary.textColor = .secondaryLabelColor
        sourceSummary.lineBreakMode = .byTruncatingTail

        sourcesScroll.borderType = .noBorder
        sourcesScroll.drawsBackground = false
        sourcesScroll.hasVerticalScroller = true
        sourcesScroll.autohidesScrollers = true
        sourcesOutlineView.backgroundColor = .clear
        sourcesOutlineView.rowHeight = 25
        sourcesOutlineView.intercellSpacing = NSSize(width: 4, height: 2)
        sourcesOutlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sourcesOutlineView.autoresizesOutlineColumn = true
        sourcesOutlineView.setAccessibilityLabel("MIDI sources")
        let nameColumn = sourcesOutlineView.tableColumn(withIdentifier: .init("name"))!
        nameColumn.minWidth = 160
        (nameColumn.dataCell as? NSTextFieldCell)?.font = .systemFont(ofSize: 12)
        (nameColumn.dataCell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail

        for view in [heading, sourceSearchField, sourcesScroll, sourceSummary] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            sourceSearchField.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            sourceSearchField.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            sourceSearchField.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            sourcesScroll.topAnchor.constraint(equalTo: sourceSearchField.bottomAnchor, constant: 12),
            sourcesScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            sourcesScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            sourcesScroll.bottomAnchor.constraint(equalTo: sourceSummary.topAnchor, constant: -10),
            sourceSummary.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            sourceSummary.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            sourceSummary.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)
        ])

        let detail = NSViewController()
        detail.view = NSView()
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        let sidebarButton = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle sources")!, target: self, action: #selector(toggleSourcesShown(_:)))
        sidebarButton.bezelStyle = .texturedRounded
        sidebarButton.toolTip = "Show or hide MIDI sources"
        let filterButton = NSButton(title: "Filters", target: self, action: #selector(toggleFilterShown(_:)))
        filterButton.bezelStyle = .rounded
        let title = NSTextField(labelWithString: "MIDI Events")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let limitLabel = NSTextField(labelWithString: "Event limit")
        limitLabel.font = .systemFont(ofSize: 11)
        limitLabel.textColor = .secondaryLabelColor
        let footer = NSView()
        let filterContainer = NSView()
        filterContainer.addSubview(filterDisclosableView)
        filterDisclosableView.autoresizesSubviews = false
        filterHeightConstraint = filterContainer.heightAnchor.constraint(equalToConstant: 0)
        filterHeightConstraint?.isActive = true
        filterContainer.isHidden = true
        filterDisclosableView.isHidden = true

        for view in [header, filterContainer, eventsScroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detail.view.addSubview(view)
        }
        for view in [sidebarButton, title, filterButton, clearButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        for view in [limitLabel, maxMessageCountField, progressContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.view.topAnchor),
            header.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 54),
            sidebarButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            sidebarButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sidebarButton.widthAnchor.constraint(equalToConstant: 34),
            title.leadingAnchor.constraint(equalTo: sidebarButton.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            filterButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            filterButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            filterContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterContainer.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            filterContainer.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            filterDisclosableView.topAnchor.constraint(equalTo: filterContainer.topAnchor),
            filterDisclosableView.leadingAnchor.constraint(equalTo: filterContainer.leadingAnchor, constant: 16),
            filterDisclosableView.widthAnchor.constraint(equalToConstant: 560),
            filterDisclosableView.heightAnchor.constraint(equalToConstant: 193),
            eventsScroll.topAnchor.constraint(equalTo: filterContainer.bottomAnchor),
            eventsScroll.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            eventsScroll.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            eventsScroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: detail.view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: detail.view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: detail.view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
            limitLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            limitLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            maxMessageCountField.leadingAnchor.constraint(equalTo: limitLabel.trailingAnchor, constant: 8),
            maxMessageCountField.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            maxMessageCountField.widthAnchor.constraint(equalToConstant: 80),
            progressContainer.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            progressContainer.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            progressContainer.widthAnchor.constraint(equalToConstant: 115),
            progressContainer.heightAnchor.constraint(equalToConstant: 18)
        ])

        eventsScroll.hasHorizontalScroller = true
        eventsScroll.autohidesScrollers = true
        messagesTableView.rowHeight = 23
        messagesTableView.usesAlternatingRowBackgroundColors = true
        for column in messagesTableView.tableColumns {
            (column.dataCell as? NSTextFieldCell)?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        messagesTableView.tableColumn(withIdentifier: .init("source"))?.width = 200
        messagesTableView.tableColumn(withIdentifier: .init("timeStamp"))?.width = 110

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 650
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.preferredThicknessFraction = 0.275
        sidebarItem.canCollapseFromWindowResize = false
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 600
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)
        splitController.splitView.dividerStyle = .thin
        window.contentViewController = splitController
        window.contentMinSize = NSSize(width: 860, height: 480)
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.titlebarAppearsTransparent = true
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = sourcesOutlineView
        window.contentView?.layoutSubtreeIfNeeded()
        splitController.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
    }

    private func setFilterShown(_ shown: Bool) {
        filterIsShown = shown
        filterDisclosableView.isHidden = !shown
        filterDisclosableView.superview?.isHidden = !shown
        filterHeightConstraint?.constant = shown ? 201 : 0
    }

    private func boxes(for group: CombinationInputStreamSourceGroup) -> [Box<InputStreamSource>] {
        visibleSourceBoxes[ObjectIdentifier(group)] ?? []
    }

    private func reloadVisibleSources() {
        if hasLoadedSources && previousSourceQuery.isEmpty {
            expandedSourceGroups = Set(inputSourceGroups.filter { sourcesOutlineView.isItemExpanded($0) }.map { ObjectIdentifier($0) })
        }
        let query = sourceSearchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleSourceBoxes.removeAll()
        visibleSourceGroups = inputSourceGroups.filter { group in
            let matches = group.boxedSources.filter {
                query.isEmpty || group.name.localizedStandardContains(query) || ($0.unbox.name ?? "").localizedStandardContains(query)
            }
            visibleSourceBoxes[ObjectIdentifier(group)] = matches
            return query.isEmpty || !matches.isEmpty
        }
        sourcesOutlineView.reloadData()
        for group in visibleSourceGroups where group.expandable {
            if !hasLoadedSources || !query.isEmpty || expandedSourceGroups.contains(ObjectIdentifier(group)) {
                sourcesOutlineView.expandItem(group)
            }
        }
        if !hasLoadedSources {
            expandedSourceGroups = Set(inputSourceGroups.map { ObjectIdentifier($0) })
        }
        previousSourceQuery = query
        if !inputSourceGroups.isEmpty { hasLoadedSources = true }
        let total = inputSourceGroups.reduce(0) { $0 + $1.sources.count }
        let selected = midiDocument?.selectedInputSources.count ?? 0
        let visible = visibleSourceGroups.reduce(0) { $0 + boxes(for: $1).count }
        sourceSummary.stringValue = query.isEmpty ? "\(selected) selected · \(total) ports" : "\(visible) matches · \(selected) selected"
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === sourceSearchField else { return }
        reloadVisibleSources()
    }

    func outlineView(_ outlineView: NSOutlineView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, item: Any, mouseLocation: NSPoint) -> String {
        if let group = item as? CombinationInputStreamSourceGroup { return group.name }
        return (item as? Box<InputStreamSource>)?.unbox.name ?? ""
    }
}
