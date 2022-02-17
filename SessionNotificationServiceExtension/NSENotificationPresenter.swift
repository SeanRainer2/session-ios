// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import SignalUtilitiesKit
import UserNotifications

public class NSENotificationPresenter: NSObject, NotificationsProtocol {
    
    public func notifyUser(for incomingMessage: TSIncomingMessage, in thread: TSThread, transaction: YapDatabaseReadTransaction) {
        guard !thread.isMuted else {
            // Ignore PNs if the thread is muted
            return
        }
        
        let senderPublicKey = incomingMessage.authorId
        let userPublicKey = SNGeneralUtilities.getUserPublicKey()
        guard senderPublicKey != userPublicKey else {
            // Ignore PNs for messages sent by the current user
            // after handling the message. Otherwise the closed
            // group self-send messages won't show.
            return
        }
        
        let context = Contact.context(for: thread)
        let senderName = Storage.shared.getContact(with: senderPublicKey)?.displayName(for: context) ?? senderPublicKey
        
        var notificationTitle = senderName
        if let group = thread as? TSGroupThread {
            if group.isOnlyNotifyingForMentions && !incomingMessage.isUserMentioned {
                // Ignore PNs if the group is set to only notify for mentions
                return
            }
            
            var groupName = thread.name(with: transaction)
            if groupName.count < 1 {
                groupName = MessageStrings.newGroupDefaultTitle
            }
            notificationTitle = String(format: NotificationStrings.incomingGroupMessageTitleFormat, senderName, groupName)
        }
        
        let threadID = thread.uniqueId!
        let snippet = incomingMessage.previewText(with: transaction).filterForDisplay?.replacingMentions(for: threadID, using: transaction)
        ?? "APN_Message".localized()
        
        var userInfo: [String:Any] = [ NotificationServiceExtension.isFromRemoteKey : true ]
        userInfo[NotificationServiceExtension.threadIdKey] = threadID
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = userInfo
        notificationContent.sound = OWSSounds.notificationSound(for: thread).notificationSound(isQuiet: false)
        if let sharedUserDefaults = UserDefaults(suiteName: "group.com.loki-project.loki-messenger") {
            let newBadgeNumber = sharedUserDefaults.integer(forKey: "currentBadgeNumber") + 1
            notificationContent.badge = NSNumber(value: newBadgeNumber)
            sharedUserDefaults.set(newBadgeNumber, forKey: "currentBadgeNumber")
        }
        
        let notificationsPreference = Environment.shared.preferences!.notificationPreviewType()
        switch notificationsPreference {
        case .namePreview:
            notificationContent.title = notificationTitle
            notificationContent.body = snippet
        case .nameNoPreview:
            notificationContent.title = notificationTitle
            notificationContent.body = NotificationStrings.incomingMessageBody
        case .noNameNoPreview:
            notificationContent.title = "Session"
            notificationContent.body = NotificationStrings.incomingMessageBody
        default: break
        }
        
        let identifier = incomingMessage.notificationIdentifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: notificationContent, trigger: nil)
        SNLog("Add remote notification request")
        UNUserNotificationCenter.current().add(request)
    }
    
    public func cancelNotification(_ identifier: String) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [ identifier ])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [ identifier ])
    }
    
    public func clearAllNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
}

private extension String {
    
    func replacingMentions(for threadID: String, using transaction: YapDatabaseReadTransaction) -> String {
        var result = self
        let regex = try! NSRegularExpression(pattern: "@[0-9a-fA-F]{66}", options: [])
        var mentions: [(range: NSRange, publicKey: String)] = []
        var m0 = regex.firstMatch(in: result, options: .withoutAnchoringBounds, range: NSRange(location: 0, length: result.utf16.count))
        while let m1 = m0 {
            let publicKey = String((result as NSString).substring(with: m1.range).dropFirst()) // Drop the @
            var matchEnd = m1.range.location + m1.range.length
            let displayName = Storage.shared.getContact(with: publicKey, using: transaction)?.displayName(for: .regular)
            if let displayName = displayName {
                result = (result as NSString).replacingCharacters(in: m1.range, with: "@\(displayName)")
                mentions.append((range: NSRange(location: m1.range.location, length: displayName.utf16.count + 1), publicKey: publicKey)) // + 1 to include the @
                matchEnd = m1.range.location + displayName.utf16.count
            }
            m0 = regex.firstMatch(in: result, options: .withoutAnchoringBounds, range: NSRange(location: matchEnd, length: result.utf16.count - matchEnd))
        }
        return result
    }
}

