import AppKit
import CoreServices
import Foundation

/// Sends through Messages.app with an AppleScript compiled once and called in-process
/// (no `osascript` spawn, no string escaping: text travels as an Apple Event parameter).
@MainActor
final class MessageSender {
    private static let source = """
    on sendmessage(chatGuid, handleId, msg, asText)
        tell application "Messages"
            if asText is "1" then
                send msg to participant handleId of (1st account whose service type = SMS)
                return "sms"
            end if
            try
                send msg to chat id chatGuid
                return "chat"
            end try
            if handleId is "" then error "Messages couldn't find chat " & chatGuid
            try
                send msg to participant handleId of (1st account whose service type = iMessage)
                return "imessage"
            end try
            send msg to participant handleId of (1st account whose service type = SMS)
            return "sms"
        end tell
    end sendmessage

    on sendfile(chatGuid, handleId, filePath, asText)
        set theFile to POSIX file filePath
        tell application "Messages"
            if asText is "1" then
                send theFile to participant handleId of (1st account whose service type = SMS)
                return "sms"
            end if
            try
                send theFile to chat id chatGuid
                return "chat"
            end try
            if handleId is "" then error "Messages couldn't find chat " & chatGuid
            try
                send theFile to participant handleId of (1st account whose service type = iMessage)
                return "imessage"
            end try
            send theFile to participant handleId of (1st account whose service type = SMS)
            return "sms"
        end tell
    end sendfile
    """

    private var script: NSAppleScript?

    /// Sends a photo, video or file. Messages picks it up from the path, so it must stay put until it's sent.
    func sendFile(_ url: URL, chatGUID: String, handle: String?, asTextMessage: Bool = false) throws {
        try call("sendfile", chatGUID, handle ?? "", url.path, asTextMessage ? "1" : "0", asTextMessage: asTextMessage)
    }

    /// `asTextMessage` forces SMS (green bubble) through the iPhone's Text Message Forwarding.
    func send(_ text: String, chatGUID: String, handle: String?, asTextMessage: Bool = false) throws {
        if asTextMessage {
            guard let handle, !handle.isEmpty else { throw AppError("Group chats can't be resent as a text message from here.") }
            guard !handle.contains("@") else { throw AppError("Email addresses can't get text messages.") }
        }
        try call("sendmessage", chatGUID, handle ?? "", text, asTextMessage ? "1" : "0", asTextMessage: asTextMessage)
    }

    /// Messages has to be running to send. If it isn't, start it hidden and in the background, so a text going out
    /// never puts its window in front of you. (Already running with its window closed is fine as is.)
    func launchMessagesIfNeeded() async {
        let id = "com.apple.MobileSMS"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        options.hides = true
        options.addsToRecentItems = false
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: options) else { return }
        for _ in 0..<50 where !app.isFinishedLaunching { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(1))   // a moment for its accounts to sign in
    }

    private func call(_ handler: String, _ args: String..., asTextMessage: Bool = false) throws {
        let script = try compiled()
        let params = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() { params.insert(NSAppleEventDescriptor(string: arg), at: i + 1) }

        let event = NSAppleEventDescriptor(eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
                                           targetDescriptor: .currentProcess(),
                                           returnID: AEReturnID(-1), transactionID: AETransactionID(0))
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: fourCC("snam"))
        event.setParam(params, forKeyword: fourCC("----"))

        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 {
                throw AppError("macOS blocked iMessager from controlling Messages. Allow it in System Settings › Privacy & Security › Automation.")
            }
            if asTextMessage, number == -1728 || number == -1719 {
                throw AppError("This Mac can't send text messages. Turn on Text Message Forwarding on your iPhone (Settings › Apps › Messages).")
            }
            throw AppError(error[NSAppleScript.errorMessage] as? String ?? "Messages couldn't send (error \(number))")
        }
    }

    private func compiled() throws -> NSAppleScript {
        if let script { return script }
        guard let s = NSAppleScript(source: Self.source) else { throw AppError("Couldn't build the send script") }
        var error: NSDictionary?
        guard s.compileAndReturnError(&error) else {
            throw AppError(error?[NSAppleScript.errorMessage] as? String ?? "Couldn't compile the send script")
        }
        script = s
        return s
    }

    /// 0 = allowed, -1743 = denied, -1744 = not asked yet, -600 = Messages isn't running.
    nonisolated static func automationStatus(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, fourCC("****"), fourCC("****"), ask)
    }
}

private func fourCC(_ s: String) -> FourCharCode {
    s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
