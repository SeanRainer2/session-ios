//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import WebRTC
import SignalUtilitiesKit

@objc public class AppEnvironment: NSObject {

    private static var _shared: AppEnvironment = AppEnvironment()

    @objc
    public class var shared: AppEnvironment {
        get {
            return _shared
        }
        set {
            guard CurrentAppContext().isRunningTests else {
                owsFailDebug("Can only switch environments in tests.")
                return
            }

            _shared = newValue
        }
    }

    @objc
    public var callMessageHandlerRef: WebRTCCallMessageHandler

    @objc
    public var callServiceRef: CallService

    @objc
    public var outboundIndividualCallInitiatorRef: OutboundIndividualCallInitiator
    
    @objc
    public var accountManager: AccountManager

    @objc
    public var notificationPresenter: NotificationPresenter

    @objc
    public var pushRegistrationManager: PushRegistrationManager

    @objc
    public var backup: OWSBackup

    // Stored properties cannot be marked as `@available`, only classes and functions.
    // Instead, store a private `Any` and wrap it with a public `@available` getter
    private var _userNotificationActionHandler: Any?

    @objc
    public var userNotificationActionHandler: UserNotificationActionHandler {
        return _userNotificationActionHandler as! UserNotificationActionHandler
    }

    @objc
    public var backupLazyRestore: BackupLazyRestore

    private override init() {
        self.accountManager = AccountManager()
        self.notificationPresenter = NotificationPresenter()
        self.pushRegistrationManager = PushRegistrationManager()
        self.backup = OWSBackup()
        self.backupLazyRestore = BackupLazyRestore()
        self._userNotificationActionHandler = UserNotificationActionHandler()

        super.init()

        SwiftSingletons.register(self)
    }

    @objc
    public func setup() {
        // Hang certain singletons on SSKEnvironment too.
        SSKEnvironment.shared.notificationsManager = notificationPresenter
    }
}
