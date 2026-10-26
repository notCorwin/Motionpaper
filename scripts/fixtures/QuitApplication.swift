import AppKit
import Carbon

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]), pid > 0 else {
    exit(EXIT_FAILURE)
}

let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
    targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
)
do {
    let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 5)
    let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
    guard error == 0 else {
        print("External quit failed with Apple event error \(error): \(reply)")
        exit(EXIT_FAILURE)
    }
} catch {
    print("External quit failed: \(error)")
    exit(EXIT_FAILURE)
}
