import Foundation
import XCTest
import os.log

public class QamlClient {
    let apiKey: String
    var app: XCUIApplication
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    public var systemPrompt = ""
    public var shouldUseAccessibilityElements: Bool
    public var autoDelay: TimeInterval = 0.0
    public var apiBaseURL = "https://api.camelqa.com/v1"
    public var alertHandler: String? = "select the most permissive option. DO NOT select options related to precision"

    var logger = OSLog(subsystem: "com.qaml", category: "QamlClient")

    let apiBaseURL = "https://api.camelqa.com/v1"

    public init(apiKey: String, app: XCUIApplication, useAccessibilityElements: Bool = true) {
        self.apiKey = apiKey
        self.app = app
        self.shouldUseAccessibilityElements = useAccessibilityElements
    }

    // MARK: Public API

    public enum Direction: String {
        case left
        case down
        case up
        case right
    }

    public func scroll(direction: Direction, until condition: String) {
        XCTContext.runActivity(named: "Scrolling \(direction) until \(condition)") { activity in
            while true {
                do {
                    try _assertCondition(condition, activity: activity)
                    break
                } catch {
                    scroll(direction: direction.rawValue)
                }
            }
        }
    }

    public func type(_ inputString: String) {
        typeText(text: inputString)
    }
    
    func handleAllSpringboardAlerts() {
        guard let alertHandler = alertHandler else {
            return
        }
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        while (self.springboard.alerts.count > 0) {
            do {
                guard let alert = self.springboard.alerts.allElementsBoundByAccessibilityElement.first else { continue }
                let alertSnapshot = try alert.snapshot()
                var elements = [alertSnapshot]
                var buttonElements: [Element] = []
                var staticTextLabels: [String] = []

                while !elements.isEmpty {
                    let element = elements.removeLast()
                    let elementDict = element.dictionaryRepresentation
                    // Check if the element's absolute frame intersects with the main app snapshot frame and if it is enabled.
                    if element.elementType == .staticText {
                        staticTextLabels.append(element.label)
                    } else if element.elementType == .button {
                        buttonElements.append(element.toElement)
                    }
                    elements.append(contentsOf: element.children)
                }

                if buttonElements.count == 1 {
                    alert.buttons.firstMatch.tap()
                    continue
                }

                let buttonElement = try self.selectElement(instructions: alertHandler, context: staticTextLabels.joined(separator: "\n"), elements: buttonElements)
                let button = alert.buttons[buttonElement.label]
                if button.exists {
                    button.tap()
                }
            } catch {
                print(error)
                // noop
            }
        }
    }

    internal func customAlertHandler() -> ((XCUIElement) -> Bool) {
        return { element in
            guard element.elementType == .alert else {
                return false
            }
            self.handleAllSpringboardAlerts()
            return true
        }
    }

    public func execute(_ command: String) {
        XCTContext.runActivity(named: "Execute command: \(command)") { activity in
            if autoDelay > 0 {
                sleep(duration: autoDelay)
            }
            guard var accessibilityElements = try? getAccessibilityElements() else {
                return
            }
            var isKeyboardShown = false
            accessibilityElements = accessibilityElements.filter { element in
                if element.type == "keyboard" || element.type == "key" {
                    isKeyboardShown = true
                    return false
                }
                return true
            }
            let windowSize = getWindowSize()
            let payload = [
                "action": command,
                "screen_size": ["width": Int(windowSize.width), "height": Int(windowSize.height)],
                "screenshot": getScreenshot(activity),
                "platform": "iOS", // Set this as a header so we never forget it?
                "extra_context": systemPrompt,
                "accessibility_elements": accessibilityElements.map(\.dictionaryRepresentation),
                "is_keyboard_shown": isKeyboardShown
            ]

            let url = URL(string: "\(apiBaseURL)/execute")!
            guard let request = try? constructAPIRequest(url: url, payload: payload) else {
                return
            }
            // MARK: sending the request
            let (data, httpResponse, error) = synchronousDataTaskWithRunLoop(urlRequest: request)
            if let error {
                XCTFail(error.localizedDescription)
                return
            }
            guard let response = try? JSONDecoder().decode([ActionResponse].self, from: data) else {
                do {
                    let failMessage = try JSONDecoder().decode(QamlErrorResponse.self, from: data)
                    XCTFail("API Error: \(failMessage.error)")
                    return
                } catch {
                    XCTFail("Failed to decode response: \(error)")
                    return
                }
            }
            // arguments is a json encoded string
            for action in response {
                // Decode the arguments
                let arguments: [String: Any]
                do {
                    arguments = try JSONSerialization.jsonObject(with: action.arguments.data(using: .utf8)!, options: []) as! [String: Any]
                } catch {
                    XCTFail("Failed to decode arguments: \(error)")
                    return
                }
                os_log("Command: %@ - Executing action: %@ with arguments: %@", log: logger, type: .info, command, action.name, arguments)
                
                // MARK: handling the action
                switch action.name {
                case "type_text":
                    let text = arguments["text"] as! String
                    typeText(text: text)
                case "tap":
                    let x = Int(arguments["x"] as! Double)
                    let y = Int(arguments["y"] as! Double)
                    tap(x: x, y: y)
                case "long_press":
                    let x = Int(arguments["x"] as! Double)
                    let y = Int(arguments["y"] as! Double)
                    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: x, dy: y)).press(forDuration: 2)
                case "swipe":
                    let direction = arguments["direction"] as! String
                    swipe(direction: direction)
                    // FIXME: Scroll on scrollable elements
                case "scroll":
                    let direction = arguments["direction"] as! String
                    scroll(direction: direction)
                case "drag":
                    let startX = arguments["startX"] as! Int
                    let startY = arguments["startY"] as! Int
                    let endX = arguments["endX"] as! Int
                    let endY = arguments["endY"] as! Int
                    drag(startX: startX, startY: startY, endX: endX, endY: endY)
                case "sleep":
                    let duration = arguments["duration"] as! TimeInterval
                    sleep(duration: duration)
                case "report_error":
                    let reason = arguments["reason"] as! String
                    reportError(reason: reason)
                case "assert":
                    XCTAssert(arguments["condition"] as! Bool, arguments["message"] as! String)
                default:
                    fatalError("Invalid action: \(action.name)")
                }
            }
        }
    }

    public func dumpAccessibilityElements() {
        let elements = try! getAccessibilityElements()
        os_log("Accessibility elements: %@", log: logger, type: .debug, elements)
    }

    public func switchToApp(bundleId: String) {
        let newApp = XCUIApplication(bundleIdentifier: bundleId)
        newApp.activate()
        app = newApp
        sleep(duration: 1)
    }

    public func launchApp(bundleId: String) {
        let newApp = XCUIApplication(bundleIdentifier: bundleId)
        newApp.launch()
        app = newApp
        sleep(duration: 1)
    }

// not support on Xcode lower than 14.3 or iOS 15.0
#if compiler(>=5.8)
    public func openURL(url: String) {
        XCUIDevice.shared.system.open(URL(string: url)!)
        sleep(duration: 1)
    }
#endif

     public func assertCondition(_ assertion: String) {
        XCTContext.runActivity(named: "Assert Condition: \(assertion)") { activity in
            do {
                try _assertCondition(assertion, activity: activity)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    public func waitUntil(_ condition: String, timeout: TimeInterval = 10) {
        let start = Date()
        XCTContext.runActivity(named: "Wait Until \(condition)") { activity in
            do {
                while true {
                    if Date().timeIntervalSince(start) > timeout {
                        try _assertCondition(condition, activity: activity)
                        return
                    }
                    do {
                        os_log("Waiting for condition: %@", log: logger, type: .info, condition)
                        try _assertCondition(condition, activity: activity)
                        return
                    } catch {
                        os_log("Condition %@ not met yet. Retrying...", log: logger, type: .info, condition)
                    }
                }
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    struct QAMLException: Error {
        let reason: String
    }

    @MainActor
    func task(task: String, maxSteps: Int = 10) async throws {
        try XCTContext.runActivity(named: "Task: \(task)") { activity in
            var progress: [String] = []
            var iterations = 0
            while true {
                if iterations >= maxSteps {
                    XCTFail("Task execution took too many steps. Max steps: \(maxSteps)")
                }
                iterations += 1
                sleep(duration: 0.5)
                let accessibilityElements = try getAccessibilityElements()
                let payload = ["task": task, "progress": progress, "screenshot": getScreenshot(activity), "accessibility_elements": accessibilityElements] as [String : Any]
            }
        }
    }

   func sleep(duration: TimeInterval) {
        // Use run loop to sleep
        let start = Date()
        while Date().timeIntervalSince(start) < duration {
            // TODO: Make sure that this doesn't hot loop
            RunLoop.current.run(mode: .common, before: .distantFuture)
        }
    }

    func reportError(reason: String) {
        dumpAccessibilityElements()
        XCTFail(reason)
    }

    func elementTypeString(_ type: XCUIElement.ElementType) -> String {
        let typeString: String
        switch type {
        case .any:
            typeString = "any"
        case .other:
            typeString = "other"
        case .application:
            typeString = "application"
        case .group:
            typeString = "group"
        case .window:
            typeString = "window"
        case .sheet:
            typeString = "sheet"
        case .drawer:
            typeString = "drawer"
        case .alert:
            typeString = "alert"
        case .dialog:
            typeString = "dialog"
        case .button:
            typeString = "button"
        case .radioButton:
            typeString = "radioButton"
        case .radioGroup:
            typeString = "radioGroup"
        case .checkBox:
            typeString = "checkBox"
        case .disclosureTriangle:
            typeString = "disclosureTriangle"
        case .popUpButton:
            typeString = "popUpButton"
        case .comboBox:
            typeString = "comboBox"
        case .menuButton:
            typeString = "menuButton"
        case .toolbarButton:
            typeString = "toolbarButton"
        case .popover:
            typeString = "popover"
        case .keyboard:
            typeString = "keyboard"
        case .key:
            typeString = "key"
        case .navigationBar:
            typeString = "navigationBar"
        case .tabBar:
            typeString = "tabBar"
        case .tabGroup:
            typeString = "tabGroup"
        case .toolbar:
            typeString = "toolbar"
        case .statusBar:
            typeString = "statusBar"
        case .table:
            typeString = "table"
        case .tableRow:
            typeString = "tableRow"
        case .tableColumn:
            typeString = "tableColumn"
        case .outline:
            typeString = "outline"
        case .outlineRow:
            typeString = "outlineRow"
        case .browser:
            typeString = "browser"
        case .collectionView:
            typeString = "collectionView"
        case .slider:
            typeString = "slider"
        case .pageIndicator:
            typeString = "pageIndicator"
        case .progressIndicator:
            typeString = "progressIndicator"
        case .activityIndicator:
            typeString = "activityIndicator"
        case .segmentedControl:
            typeString = "segmentedControl"
        case .picker:
            typeString = "picker"
        case .pickerWheel:
            typeString = "pickerWheel"
        case .switch:
            typeString = "switch"
        case .toggle:
            typeString = "toggle"
        case .link:
            typeString = "link"
        case .image:
            typeString = "image"
        case .icon:
            typeString = "icon"
        case .searchField:
            typeString = "searchField"
        case .scrollView:
            typeString = "scrollView"
        case .scrollBar:
            typeString = "scrollBar"
        case .staticText:
            typeString = "staticText"
        case .textField:
            typeString = "textField"
        case .secureTextField:
            typeString = "secureTextField"
        case .datePicker:
            typeString = "datePicker"
        case .textView:
            typeString = "textView"
        case .menu:
            typeString = "menu"
        case .menuItem:
            typeString = "menuItem"
        case .menuBar:
            typeString = "menuBar"
        case .menuBarItem:
            typeString = "menuBarItem"
        case .map:
            typeString = "map"
        case .webView:
            typeString = "webView"
        case .incrementArrow:
            typeString = "incrementArrow"
        case .decrementArrow:
            typeString = "decrementArrow"
        case .timeline:
            typeString = "timeline"
        case .ratingIndicator:
            typeString = "ratingIndicator"
        case .valueIndicator:
            typeString = "valueIndicator"
        case .splitGroup:
            typeString = "splitGroup"
        case .splitter:
            typeString = "splitter"
        case .relevanceIndicator:
            typeString = "relevanceIndicator"
        case .colorWell:
            typeString = "colorWell"
        case .helpTag:
            typeString = "helpTag"
        case .matte:
            typeString = "matte"
        case .dockItem:
            typeString = "dockItem"
        case .ruler:
            typeString = "ruler"
        case .rulerMarker:
            typeString = "rulerMarker"
        case .grid:
            typeString = "grid"
        case .levelIndicator:
            typeString = "levelIndicator"
        case .cell:
            typeString = "cell"
        case .layoutArea:
            typeString = "layoutArea"
        case .layoutItem:
            typeString = "layoutItem"
        case .handle:
            typeString = "handle"
        case .stepper:
            typeString = "stepper"
        case .tab:
            typeString = "tab"
        case .touchBar:
            typeString = "touchBar"
        case .statusItem:
            typeString = "statusItem"
        }
        return typeString
    }

    struct Element: Encodable {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        let type: String
        let label: String
        let value: String?
        let placeholder: String?
    }

    public func dumpAccessibilityElements() {
        let elements = try! getAccessibilityElements()
        os_log("Accessibility elements: %@", log: logger, type: .debug, elements)
    }

    func getAccessibilityElements() throws -> [Element] {
        // First check springboard for alerts
        let springboardNavigationbars = springboard.navigationBars
        let springboardAlerts = springboard.alerts
        let snapshot: XCUIElementSnapshot
        if alertHandler != nil {
            while springboard.alerts.count > 0 {
                handleAllSpringboardAlerts()
            }
        }
        if springboardAlerts.count > 0 || springboardNavigationbars.count > 0 {
            snapshot = try springboard.snapshot()
        } else {
            snapshot = try app.snapshot()
        }
        var elements = [snapshot]
        var enabledElements: [XCUIElementSnapshot] = []
        let windowScale = getWindowSize().width/app.frame.width

        while !elements.isEmpty {
            let element = elements.removeLast()

            let elementDict = element.dictionaryRepresentation
            let windowContextID = XCUIElement.AttributeName(rawValue: "windowContextID")
            // If elementDict[windowContextID] is 0, skip it.
            if let windowContextIDValue = elementDict[windowContextID] as? Int, windowContextIDValue == 0 {
                continue
            }

            // Check if the element's absolute frame intersects with the main app snapshot frame and if it is enabled.
            if (!element.label.isEmpty || !element.identifier.isEmpty || element.value != nil || element.elementType == .textField || element.elementType == .secureTextField || element.elementType == .textView) && element.isEnabled && snapshot.frame.intersects(element.frame) && element.elementType != .key {
                enabledElements.append(element)
            }

            // Skip child images of labeled buttons. TODO: Reconsider this
            if element.elementType == .button && !element.label.isEmpty {
                continue
            }

            elements.append(contentsOf: element.children)
        }
        // Sort enabled elements by their y position.
        enabledElements.sort { $0.frame.minY < $1.frame.minY }
        var accessibilityElements: [Element] = []
        for element in enabledElements {
            let accessibilityElement = Element(
                left: Int(element.frame.minX * windowScale),
                top: Int(element.frame.minY * windowScale),
                width: Int(element.frame.width * windowScale),
                height: Int(element.frame.height * windowScale),
                type: elementTypeString(element.elementType),
                label: element.label,
                value: element.value != nil ? String(describing: element.value!) : nil,
                placeholder: element.placeholderValue
            )
            accessibilityElements.append(accessibilityElement)
        }
        return accessibilityElements
    }

    public func type(_ inputString: String) {
        typeText(text: inputString)
    }

    func constructTypedAPIRequest(url: URL, payload: Encodable) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            XCTFail("Failed to encode payload: \(error)")
            throw QAMLException(reason: "Error encoding data")
        }
        return request
    }

    private func getScreenshot(_ activity: XCTActivity) -> String {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        activity.add(attachment)
        return screenshot.pngRepresentation.base64EncodedString()
    }

    private func getWindowSize() -> CGRect {
        return app.windows.firstMatch.frame
    }

    public func assertCondition(_ assertion: String) {
        XCTContext.runActivity(named: "Assert Condition: \(assertion)") { activity in
            do {
                try _assertCondition(assertion, activity: activity)
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    public func _assertCondition(_ assertion: String, activity: XCTActivity) throws {
        sleep(duration: autoDelay + 0.5)
        struct AssertionRequest: Encodable {
            struct Size: Encodable {
                let width: Double
                let height: Double
            }
            let assertion: String
            let screen_size: Size
            let screenshot: String
            let platform: String
            let extra_context: String
            let accessibility_elements: String
        }
        let screenshotData = getScreenshot(activity)
        let screenSize = getWindowSize()
        let payload = AssertionRequest(
            assertion: assertion,
            screen_size: AssertionRequest.Size(width: screenSize.width, height: screenSize.height),
            screenshot: screenshotData,
            platform: "iOS",
            extra_context: systemPrompt,
            accessibility_elements: ""
        )

        let url = URL(string: "\(apiBaseURL)/assert")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            XCTFail("Failed to encode payload: \(error)")
            return
        }

        let (data, httpResponse, error) = synchronousDataTaskWithRunLoop(urlRequest: request)
        if let error {
            XCTFail(error.localizedDescription)
            return
        }

        guard let data = data else {
            XCTFail("No data received from QAML API")
            return
        }

        struct AssertionResponse: Decodable {
            let name: String
            let arguments: String
        }

        let assertionResponses: [AssertionResponse]
        let arguments: [String: Any]
        do {
            assertionResponses = try JSONDecoder().decode([AssertionResponse].self, from: data)
            arguments = try JSONSerialization.jsonObject(with: assertionResponses[0].arguments.data(using: .utf8)!, options: []) as! [String: Any]
        } catch {
            do {
                let failMessage = try JSONDecoder().decode(QamlErrorResponse.self, from: data)
                XCTFail("API Error: \(failMessage.error)")
            } catch {
                XCTFail("Failed to decode response: \(error)")
            }
            return
        }
        guard let result = arguments["result"] as? Bool else {
            throw QAMLException(reason: "Invalid response from QAML API")
        }
        if (!result) {
            throw QAMLException(reason: "Assertion failed: \(assertion). Reason: \(arguments["reason"])")
        }
    }

    struct Tool: Encodable {
        let name: String
        let description: String
        let arguments: [String: [String: String]]
        let required: [String]
    }

    struct CallPayload: Encodable {
        let systemPrompt: String
        let elements: [Element]
        let tools: [Tool]
        let base64Image: String? = nil
        let shouldUseVisionElements: Bool = false
    }

    func selectElement(instructions: String, context: String, elements: [Element]) throws -> Element {
        let selectElementTool = Tool(
            name: "selectElement",
            description: "select the specified element",
            arguments: [
                "elementID": [
                    "type": "integer",
                    "description": "the ID of the element to select"
                ]
            ],
            required: ["elementID"]
        )

        let systemPrompt = "INSTRUCTIONS: \(instructions). Use the instructions to select the best element out of the provided element list. Window content: \(context). INSTRUCTIONS: \(instructions)"

        let payload = CallPayload(
            systemPrompt: systemPrompt,
            elements: elements,
            tools: [selectElementTool])

        let url = URL(string: "\(apiBaseURL)/call")!
        let request = try constructTypedAPIRequest(url: url, payload: payload)

        let (data, httpResponse, error) = synchronousDataTaskWithRunLoop(urlRequest: request)
        if let error {
            XCTFail(error.localizedDescription)
            throw error
        }

        struct CallEndpointResponse: Decodable {
            let toolCalls: [ActionResponse]
            let elements: [Element]
        }

        print(String(data: data, encoding: .utf8))
        let actionResponse = try JSONDecoder().decode(CallEndpointResponse.self, from: data)
        let arguments = try JSONSerialization.jsonObject(with: actionResponse.toolCalls[0].arguments.data(using: .utf8)!) as! [String: Any]
        guard let elementIndex = arguments["elementID"] as? Int else {
            throw QAMLException(reason: "Invalid response from QAML API")
        }
        return actionResponse.elements[elementIndex]
    }

    struct QAMLException: Error {
        let reason: String
    }

    @MainActor
    func task(task: String, maxSteps: Int = 10) async throws {
        try XCTContext.runActivity(named: "Task: \(task)") { activity in
            var progress: [String] = []
            var iterations = 0
            while true {
                if iterations >= maxSteps {
                    XCTFail("Task execution took too many steps. Max steps: \(maxSteps)")
                }
                iterations += 1
                sleep(duration: 0.5)
                let accessibilityElements = try getAccessibilityElements()
                let payload = ["task": task, "progress": progress, "screenshot": getScreenshot(activity), "accessibility_elements": accessibilityElements] as [String : Any]
            }
        }
    }

    func tap(x: Int, y: Int) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    func drag(startX: Int, startY: Int, endX: Int, endY: Int) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: startX, dy: startY)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: endX, dy: endY)))
    }

    func swipe(direction: String) {
        switch direction {
        case "up":
            app.windows.firstMatch.swipeUp()
        case "down":
            app.windows.firstMatch.swipeDown()
        case "left":
            app.windows.firstMatch.swipeLeft()
        case "right":
            app.windows.firstMatch.swipeRight()
        default:
            fatalError("Invalid swipe direction: \(direction)")
        }
    }

    func scroll(direction: String) {
        switch direction {
        case "up":
            swipe(direction: "down")
        case "down":
            swipe(direction: "up")
        case "left":
            swipe(direction: "right")
        case "right":
            swipe(direction: "left")
        default:
            fatalError("Invalid scroll direction: \(direction)")
        }
    }

    func typeText(text: String) {
        // Clear key HID events to delete the current text
        performIOHIDEvent(page: 0x07, usage: 0x9C, duration: 0.1, device: XCUIDevice.shared)
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).element(boundBy: 0)
        if let value = element.value as? String {
            // Use ASCII control characters to delete the current text using delete and forward delete
            let deleteString = String(repeating: "\u{8}", count: value.count)
            let forwardDeleteString = String(repeating: "\u{7F}", count: value.count)
            element.typeText(deleteString + forwardDeleteString)
        }
        element.typeText(text)
    }
    
    func synchronousDataTaskWithRunLoop(urlRequest: URLRequest) -> (Data?, URLResponse?, Error?) {
        var data: Data?
        var response: URLResponse?
        var error: Error?
        var done = false
        let task = URLSession.shared.dataTask(with: urlRequest) { (taskData, taskResponse, taskError) in
            print(taskResponse)
            print(taskError)
            print(taskData)
            data = taskData
            response = taskResponse
            error = taskError
            done = true
        }
        task.resume()
        let runLoop = CFRunLoopGetCurrent()
        let allModes = CFRunLoopCopyAllModes(runLoop) as! [CFString]
        while !done {
            for mode in allModes {
                if mode == ("kCFRunLoopDefaultMode" as CFString) {
                    continue
                }
                CFRunLoopRunInMode(CFRunLoopMode(mode), 0.1, true)
                if done {
                    break
                }
            }
        }
        return (data, response, error)
    }
    
    public enum Direction: String {
        case left
        case down
        case up
        case right
    }
    public func scroll(direction: Direction, until condition: String) {
        XCTContext.runActivity(named: "Scrolling \(direction) until \(condition)") { activity in
            while true {
                do {
                    try _assertCondition(condition, activity: activity)
                    break
                } catch {
                    scroll(direction: direction.rawValue)
                }
            }
        }
    }

    func createXCDeviceEvent(page: UInt32, usage: UInt32, duration: TimeInterval) -> AnyObject? {
        guard let xcDeviceEventClass: AnyObject.Type = NSClassFromString("XCDeviceEvent") else {
            return nil
        }

        let selector = NSSelectorFromString("deviceEventWithPage:usage:duration:")
        guard let method = class_getClassMethod(xcDeviceEventClass, selector) else {
            return nil
        }

        let imp = method_getImplementation(method)
        typealias DeviceEventFunction = @convention(c) (AnyObject, Selector, UInt32, UInt32, TimeInterval) -> AnyObject
        let function = unsafeBitCast(imp, to: DeviceEventFunction.self)

        return function(xcDeviceEventClass, selector, page, usage, duration)
    }

    func performIOHIDEvent(page: UInt32, usage: UInt32, duration: TimeInterval, device: XCUIDevice) {
        guard let event = createXCDeviceEvent(page: page, usage: usage, duration: duration) else {
            return
        }

        let selector = NSSelectorFromString("performDeviceEvent:error:")
        guard let method = class_getInstanceMethod(XCUIDevice.self, selector) else {
            return
        }

        let imp = method_getImplementation(method)
        typealias PerformDeviceEventFunction = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> Bool
        let function = unsafeBitCast(imp, to: PerformDeviceEventFunction.self)

        var error: NSError?
        let result = function(device, selector, event, &error)

        if let error = error {
            os_log("Error performing device event: %@", log: logger, type: .error, error)
        } else if !result {
            os_log("Failed to perform device event.", log: logger, type: .error)
        }
    }

}

struct QamlErrorResponse: Codable {
    let error: String?
}

struct ActionResponse: Decodable {
    let name: String
    let arguments: String
}

struct Element: Codable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let type: String
    let label: String
    let value: String?
    let placeholder: String?

    var dictionaryRepresentation: [String: Any] {
        get {
            var dictionary: [String: Any] = [
                "left": left,
                "top": top,
                "width": width,
                "height": height,
                "type": type,
                "label": label
            ]
            if let value = value {
                dictionary["value"] = value
            }
            if let placeholder = placeholder {
                dictionary["placeholder"] = placeholder
            }
            return dictionary
        }
    }
}

func elementTypeString(_ type: XCUIElement.ElementType) -> String {
    switch type {
    case .any: return "any"
    case .other: return "other"
    case .application: return "application"
    case .group: return "group"
    case .window: return "window"
    case .sheet: return "sheet"
    case .drawer: return "drawer"
    case .alert: return "alert"
    case .dialog: return "dialog"
    case .button: return "button"
    case .radioButton: return "radioButton"
    case .radioGroup: return "radioGroup"
    case .checkBox: return "checkBox"
    case .disclosureTriangle: return "disclosureTriangle"
    case .popUpButton: return "popUpButton"
    case .comboBox: return "comboBox"
    case .menuButton: return "menuButton"
    case .toolbarButton: return "toolbarButton"
    case .popover: return "popover"
    case .keyboard: return "keyboard"
    case .key: return "key"
    case .navigationBar: return "navigationBar"
    case .tabBar: return "tabBar"
    case .tabGroup: return "tabGroup"
    case .toolbar: return "toolbar"
    case .statusBar: return "statusBar"
    case .table: return "table"
    case .tableRow: return "tableRow"
    case .tableColumn: return "tableColumn"
    case .outline: return "outline"
    case .outlineRow: return "outlineRow"
    case .browser: return "browser"
    case .collectionView: return "collectionView"
    case .slider: return "slider"
    case .pageIndicator: return "pageIndicator"
    case .progressIndicator: return "progressIndicator"
    case .activityIndicator: return "activityIndicator"
    case .segmentedControl: return "segmentedControl"
    case .picker: return "picker"
    case .pickerWheel: return "pickerWheel"
    case .switch: return "switch"
    case .toggle: return "toggle"
    case .link: return "link"
    case .image: return "image"
    case .icon: return "icon"
    case .searchField: return "searchField"
    case .scrollView: return "scrollView"
    case .scrollBar: return "scrollBar"
    case .staticText: return "staticText"
    case .textField: return "textField"
    case .secureTextField: return "secureTextField"
    case .datePicker: return "datePicker"
    case .textView: return "textView"
    case .menu: return "menu"
    case .menuItem: return "menuItem"
    case .menuBar: return "menuBar"
    case .menuBarItem: return "menuBarItem"
    case .map: return "map"
    case .webView: return "webView"
    case .incrementArrow: return "incrementArrow"
    case .decrementArrow: return "decrementArrow"
    case .timeline: return "timeline"
    case .ratingIndicator: return "ratingIndicator"
    case .valueIndicator: return "valueIndicator"
    case .splitGroup: return "splitGroup"
    case .splitter: return "splitter"
    case .relevanceIndicator: return "relevanceIndicator"
    case .colorWell: return "colorWell"
    case .helpTag: return "helpTag"
    case .matte: return "matte"
    case .dockItem: return "dockItem"
    case .ruler: return "ruler"
    case .rulerMarker: return "rulerMarker"
    case .grid: return "grid"
    case .levelIndicator: return "levelIndicator"
    case .cell: return "cell"
    case .layoutArea: return "layoutArea"
    case .layoutItem: return "layoutItem"
    case .handle: return "handle"
    case .stepper: return "stepper"
    case .tab: return "tab"
    case .touchBar: return "touchBar"
    case .statusItem: return "statusItem"
    }
}

extension XCUIElementSnapshot {
    var toElement: Element {
        get {
            return Element(
                left: Int(self.frame.minX),
                top: Int(self.frame.minY),
                width: Int(self.frame.width),
                height: Int(self.frame.height),
                type: elementTypeString(self.elementType),
                label: self.label.isEmpty ? self.identifier : self.label,
                value: self.value != nil ? String(describing: self.value!) : nil,
                placeholder: self.placeholderValue
            )
        }
    }
}

