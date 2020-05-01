import PromiseKit

// A few notes about making changes in this file:
//
// • Don't use a database transaction if you can avoid it.
// • If you do need to use a database transaction, use a read transaction if possible.
// • Consider making it the caller's responsibility to manage the database transaction (this helps avoid nested or unnecessary transactions).
// • Think carefully about adding a function; there might already be one for what you need.
// • Document the expected cases for everything.
// • Express those cases in tests.

@objc(LKMultiDeviceProtocol)
public final class MultiDeviceProtocol : NSObject {

    private static var _lastDeviceLinkUpdate: [String:Date] = [:]
    /// A mapping from hex encoded public key to date updated.
    public static var lastDeviceLinkUpdate: [String:Date] {
        get { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate } }
        set { LokiAPI.stateQueue.sync { _lastDeviceLinkUpdate = newValue } }
    }

    // TODO: I don't think stateQueue actually helps avoid race conditions

    internal static var storage: OWSPrimaryStorage { OWSPrimaryStorage.shared() }

    // MARK: - Settings
    public static let deviceLinkUpdateInterval: TimeInterval = 20
    
    // MARK: - Multi Device Destination
    public struct MultiDeviceDestination : Hashable {
        public let hexEncodedPublicKey: String
        public let isMaster: Bool
    }

    // MARK: - Initialization
    private override init() { }

    // MARK: - Sending (Part 1)
    @objc(isMultiDeviceRequiredForMessage:)
    public static func isMultiDeviceRequired(for message: TSOutgoingMessage) -> Bool {
        return !(message is DeviceLinkMessage) && !message.thread.isGroupThread()
    }

    private static func copy(_ messageSend: OWSMessageSend, for destination: MultiDeviceDestination, with seal: Resolver<Void>) -> OWSMessageSend {
        var recipient: SignalRecipient!
        storage.dbReadConnection.read { transaction in
            recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: destination.hexEncodedPublicKey, transaction: transaction)
        }
        // TODO: Why is it okay that the thread, sender certificate, etc. don't get changed?
        return OWSMessageSend(message: messageSend.message, thread: messageSend.thread, recipient: recipient,
            senderCertificate: messageSend.senderCertificate, udAccess: messageSend.udAccess, localNumber: messageSend.localNumber, success: {
            seal.fulfill(())
        }, failure: { error in
            seal.reject(error)
        })
    }

    private static func sendMessage(_ messageSend: OWSMessageSend, to destination: MultiDeviceDestination, in transaction: YapDatabaseReadTransaction) -> Promise<Void> {
        let (threadPromise, threadPromiseSeal) = Promise<TSContactThread>.pending()
        if let thread = TSContactThread.getWithContactId(destination.hexEncodedPublicKey, transaction: transaction) {
            threadPromiseSeal.fulfill(thread)
        } else {
            // Dispatch async on the main queue to avoid nested write transactions
            DispatchQueue.main.async {
                storage.dbReadWriteConnection.readWrite { transaction in
                    let thread = TSContactThread.getOrCreateThread(withContactId: destination.hexEncodedPublicKey, transaction: transaction)
                    threadPromiseSeal.fulfill(thread)
                }
            }
        }
        return threadPromise.then(on: OWSDispatch.sendingQueue()) { thread -> Promise<Void> in
            let message = messageSend.message
            let messageSender = SSKEnvironment.shared.messageSender
            let (promise, seal) = Promise<Void>.pending()
            let shouldSendAutoGeneratedFR = !thread.isContactFriend && !(message is FriendRequestMessage)
                && message.shouldBeSaved() // shouldBeSaved indicates it isn't a transient message
            if !shouldSendAutoGeneratedFR {
                let messageSendCopy = copy(messageSend, for: destination, with: seal)
                messageSender.sendMessage(messageSendCopy)
            } else {
                // Dispatch async on the main queue to avoid nested write transactions
                DispatchQueue.main.async {
                    storage.dbReadWriteConnection.readWrite { transaction in
                        getAutoGeneratedMultiDeviceFRMessageSend(for: destination.hexEncodedPublicKey, in: transaction, seal: seal)
                        .done(on: OWSDispatch.sendingQueue()) { autoGeneratedFRMessageSend in
                            messageSender.sendMessage(autoGeneratedFRMessageSend)
                        }
                    }
                }
            }
            return promise
        }
    }

    /// See [Multi Device Message Sending](https://github.com/loki-project/session-protocol-docs/wiki/Multi-Device-Message-Sending) for more information.
    @objc(sendMessageToDestinationAndLinkedDevices:in:)
    public static func sendMessageToDestinationAndLinkedDevices(_ messageSend: OWSMessageSend, in transaction: YapDatabaseReadTransaction) {
        let message = messageSend.message
        let messageSender = SSKEnvironment.shared.messageSender
        if !isMultiDeviceRequired(for: message) {
            print("[Loki] sendMessageToDestinationAndLinkedDevices(_:in:) invoked for a message that doesn't require multi device routing.")
            OWSDispatch.sendingQueue().async {
                messageSender.sendMessage(messageSend)
            }
            return
        }
        print("[Loki] Sending \(type(of: message)) message using multi device routing.")
        let recipientID = messageSend.recipient.recipientId()
        getMultiDeviceDestinations(for: recipientID, in: transaction).done(on: OWSDispatch.sendingQueue()) { destinations in
            var promises: [Promise<Void>] = []
            let masterDestination = destinations.first { $0.isMaster }
            if let masterDestination = masterDestination {
                storage.dbReadConnection.read { transaction in
                    promises.append(sendMessage(messageSend, to: masterDestination, in: transaction))
                }
            }
            let slaveDestinations = destinations.filter { !$0.isMaster }
            slaveDestinations.forEach { slaveDestination in
                storage.dbReadConnection.read { transaction in
                    promises.append(sendMessage(messageSend, to: slaveDestination, in: transaction))
                }
            }
            when(resolved: promises).done(on: OWSDispatch.sendingQueue()) { results in
                let errors = results.compactMap { result -> Error? in
                    if case Result.rejected(let error) = result {
                        return error
                    } else {
                        return nil
                    }
                }
                if errors.isEmpty {
                    messageSend.success()
                } else {
                    messageSend.failure(errors.first!)
                }
            }
        }.catch(on: OWSDispatch.sendingQueue()) { error in
            // Proceed even if updating the recipient's device links failed, so that message sending
            // is independent of whether the file server is online
            messageSender.sendMessage(messageSend)
        }
    }

    @objc(updateDeviceLinksIfNeededForHexEncodedPublicKey:in:)
    public static func updateDeviceLinksIfNeeded(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadTransaction) -> AnyPromise {
        let promise = getMultiDeviceDestinations(for: hexEncodedPublicKey, in: transaction)
        return AnyPromise.from(promise)
    }

    /// See [Auto-Generated Friend Requests](https://github.com/loki-project/session-protocol-docs/wiki/Auto-Generated-Friend-Requests) for more information.
    @objc(getAutoGeneratedMultiDeviceFRMessageForHexEncodedPublicKey:in:)
    public static func getAutoGeneratedMultiDeviceFRMessage(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> FriendRequestMessage {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction)
        let isSlaveDeviceThread = masterHexEncodedPublicKey != hexEncodedPublicKey
        thread.isForceHidden = isSlaveDeviceThread // TODO: Could we make this computed?
        thread.save(with: transaction)
        let result = FriendRequestMessage(outgoingMessageWithTimestamp: NSDate.ows_millisecondTimeStamp(), in: thread,
            messageBody: "Please accept to enable messages to be synced across devices",
            attachmentIds: [], expiresInSeconds: 0, expireStartedAt: 0, isVoiceMessage: false,
            groupMetaMessage: .unspecified, quotedMessage: nil, contactShare: nil, linkPreview: nil)
        result.skipSave = true // TODO: Why is this necessary again?
        return result
    }

    /// See [Auto-Generated Friend Requests](https://github.com/loki-project/session-protocol-docs/wiki/Auto-Generated-Friend-Requests) for more information.
    @objc(getAutoGeneratedMultiDeviceFRMessageSendForHexEncodedPublicKey:in:)
    public static func objc_getAutoGeneratedMultiDeviceFRMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction) -> AnyPromise {
        return AnyPromise.from(getAutoGeneratedMultiDeviceFRMessageSend(for: hexEncodedPublicKey, in: transaction))
    }

    /// See [Auto-Generated Friend Requests](https://github.com/loki-project/session-protocol-docs/wiki/Auto-Generated-Friend-Requests) for more information.
    public static func getAutoGeneratedMultiDeviceFRMessageSend(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadWriteTransaction, seal externalSeal: Resolver<Void>? = nil) -> Promise<OWSMessageSend> {
        let thread = TSContactThread.getOrCreateThread(withContactId: hexEncodedPublicKey, transaction: transaction)
        let message = getAutoGeneratedMultiDeviceFRMessage(for: hexEncodedPublicKey, in: transaction)
        thread.friendRequestStatus = .requestSending
        thread.save(with: transaction)
        let recipient = SignalRecipient.getOrBuildUnsavedRecipient(forRecipientId: hexEncodedPublicKey, transaction: transaction)
        let udManager = SSKEnvironment.shared.udManager
        let senderCertificate = udManager.getSenderCertificate()
        let (promise, seal) = Promise<OWSMessageSend>.pending()
        // Dispatch async on the main queue to avoid nested write transactions
        DispatchQueue.main.async {
            var recipientUDAccess: OWSUDAccess?
            if let senderCertificate = senderCertificate {
                recipientUDAccess = udManager.udAccess(forRecipientId: hexEncodedPublicKey, requireSyncAccess: true) // Starts a new write transaction internally
            }
            let messageSend = OWSMessageSend(message: message, thread: thread, recipient: recipient, senderCertificate: senderCertificate,
                udAccess: recipientUDAccess, localNumber: getUserHexEncodedPublicKey(), success: {
                    externalSeal?.fulfill(())
                    // Dispatch async on the main queue to avoid nested write transactions
                    DispatchQueue.main.async {
                        thread.friendRequestStatus = .requestSent
                        thread.save()
                    }
            }, failure: { error in
                externalSeal?.reject(error)
                // Dispatch async on the main queue to avoid nested write transactions
                DispatchQueue.main.async {
                    thread.friendRequestStatus = .none
                    thread.save()
                }
            })
            seal.fulfill(messageSend)
        }
        return promise
    }

    // MARK: - Receiving
    @objc(handleDeviceLinkMessageIfNeeded:wrappedIn:using:)
    public static func handleDeviceLinkMessageIfNeeded(_ protoContent: SSKProtoContent, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        guard let deviceLinkMessage = protoContent.lokiDeviceLinkMessage, let master = deviceLinkMessage.masterHexEncodedPublicKey,
            let slave = deviceLinkMessage.slaveHexEncodedPublicKey, let slaveSignature = deviceLinkMessage.slaveSignature else {
            print("[Loki] Received an invalid device link message.")
            return
        }
        let deviceLinkingSession = DeviceLinkingSession.current
        if let masterSignature = deviceLinkMessage.masterSignature { // Authorization
            print("[Loki] Received a device link authorization from: \(hexEncodedPublicKey).") // Intentionally not `master`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingAuthorization(from: master, for: slave, masterSignature: masterSignature, slaveSignature: slaveSignature)
            } else {
                print("[Loki] Received a device link authorization without a session; ignoring.")
            }
            // Set any profile info (the device link authorization also includes the master device's profile info)
            if let dataMessage = protoContent.dataMessage {
                SessionMetaProtocol.updateDisplayNameIfNeeded(for: master, using: dataMessage, appendingShortID: false, in: transaction)
                SessionMetaProtocol.updateProfileKeyIfNeeded(for: master, using: dataMessage)
            }
        } else { // Request
            print("[Loki] Received a device link request from: \(hexEncodedPublicKey).") // Intentionally not `slave`
            if let deviceLinkingSession = deviceLinkingSession {
                deviceLinkingSession.processLinkingRequest(from: slave, to: master, with: slaveSignature)
            } else {
                NotificationCenter.default.post(name: .unexpectedDeviceLinkRequestReceived, object: nil)
            }
        }
    }

    @objc(isUnlinkDeviceMessage:)
    public static func isUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage) -> Bool {
        let unlinkDeviceFlag = SSKProtoDataMessage.SSKProtoDataMessageFlags.unlinkDevice
        return dataMessage.flags & UInt32(unlinkDeviceFlag.rawValue) != 0
    }

    @objc(handleUnlinkDeviceMessage:wrappedIn:using:)
    public static func handleUnlinkDeviceMessage(_ dataMessage: SSKProtoDataMessage, wrappedIn envelope: SSKProtoEnvelope, using transaction: YapDatabaseReadWriteTransaction) {
        // The envelope source is set during UD decryption
        let hexEncodedPublicKey = envelope.source!
        // Check that the request was sent by our master device
        guard let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: getUserHexEncodedPublicKey(), in: transaction) else { return }
        let wasSentByMasterDevice = (masterHexEncodedPublicKey == hexEncodedPublicKey)
        guard wasSentByMasterDevice else { return }
        // Ignore the request if we don't know about the device link in question
        let masterDeviceLinks = storage.getDeviceLinks(for: masterHexEncodedPublicKey, in: transaction)
        if !masterDeviceLinks.contains(where: {
            $0.master.hexEncodedPublicKey == masterHexEncodedPublicKey && $0.slave.hexEncodedPublicKey == getUserHexEncodedPublicKey()
        }) {
            return
        }
        LokiFileServerAPI.getDeviceLinks(associatedWith: getUserHexEncodedPublicKey()).done(on: DispatchQueue.main) { slaveDeviceLinks in
            // Check that the device link IS present on the file server.
            // Note that the device link as seen from the master device's perspective has been deleted at this point, but the
            // device link as seen from the slave perspective hasn't.
            if slaveDeviceLinks.contains(where: {
                $0.master.hexEncodedPublicKey == masterHexEncodedPublicKey && $0.slave.hexEncodedPublicKey == getUserHexEncodedPublicKey()
            }) {
                for deviceLink in slaveDeviceLinks { // In theory there should only be one
                    LokiFileServerAPI.removeDeviceLink(deviceLink) // Attempt to clean up on the file server
                }
                UserDefaults.standard[.wasUnlinked] = true
                NotificationCenter.default.post(name: .dataNukeRequested, object: nil)
            }
        }
    }
}

// MARK: - Sending (Part 2)
// Here (in a non-@objc extension) because it doesn't interoperate well with Obj-C
public extension MultiDeviceProtocol {

    fileprivate static func getMultiDeviceDestinations(for hexEncodedPublicKey: String, in transaction: YapDatabaseReadTransaction) -> Promise<Set<MultiDeviceDestination>> {
        let (promise, seal) = Promise<Set<MultiDeviceDestination>>.pending()
        func getDestinations(in transaction: YapDatabaseReadTransaction? = nil) {
            storage.dbReadConnection.read { transaction in
                var destinations: Set<MultiDeviceDestination> = []
                let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
                let masterDestination = MultiDeviceDestination(hexEncodedPublicKey: masterHexEncodedPublicKey, isMaster: true)
                destinations.insert(masterDestination)
                let deviceLinks = storage.getDeviceLinks(for: masterHexEncodedPublicKey, in: transaction)
                let slaveDestinations = deviceLinks.map { MultiDeviceDestination(hexEncodedPublicKey: $0.slave.hexEncodedPublicKey, isMaster: false) }
                destinations.formUnion(slaveDestinations)
                seal.fulfill(destinations)
            }
        }
        let timeSinceLastUpdate: TimeInterval
        if let lastDeviceLinkUpdate = lastDeviceLinkUpdate[hexEncodedPublicKey] {
            timeSinceLastUpdate = Date().timeIntervalSince(lastDeviceLinkUpdate)
        } else {
            timeSinceLastUpdate = .infinity
        }
        if timeSinceLastUpdate > deviceLinkUpdateInterval {
            let masterHexEncodedPublicKey = storage.getMasterHexEncodedPublicKey(for: hexEncodedPublicKey, in: transaction) ?? hexEncodedPublicKey
            LokiFileServerAPI.getDeviceLinks(associatedWith: masterHexEncodedPublicKey).done(on: LokiAPI.workQueue) { _ in
                getDestinations()
                lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
            }.catch(on: LokiAPI.workQueue) { error in
                if (error as? LokiDotNetAPI.LokiDotNetAPIError) == LokiDotNetAPI.LokiDotNetAPIError.parsingFailed {
                    // Don't immediately re-fetch in case of failure due to a parsing error
                    lastDeviceLinkUpdate[hexEncodedPublicKey] = Date()
                    getDestinations()
                } else {
                    print("[Loki] Failed to get device links due to error: \(error).")
                    seal.reject(error)
                }
            }
        } else {
            getDestinations()
        }
        return promise
    }
}
