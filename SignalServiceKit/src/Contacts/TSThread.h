//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "TSYapDatabaseObject.h"

NS_ASSUME_NONNULL_BEGIN

BOOL IsNoteToSelfEnabled(void);

@class OWSDisappearingMessagesConfiguration;
@class TSInteraction;
@class TSInvalidIdentityKeyReceivingErrorMessage;

typedef NSString *ConversationColorName NS_STRING_ENUM;

extern ConversationColorName const ConversationColorNameCrimson;
extern ConversationColorName const ConversationColorNameVermilion;
extern ConversationColorName const ConversationColorNameBurlap;
extern ConversationColorName const ConversationColorNameForest;
extern ConversationColorName const ConversationColorNameWintergreen;
extern ConversationColorName const ConversationColorNameTeal;
extern ConversationColorName const ConversationColorNameBlue;
extern ConversationColorName const ConversationColorNameIndigo;
extern ConversationColorName const ConversationColorNameViolet;
extern ConversationColorName const ConversationColorNamePlum;
extern ConversationColorName const ConversationColorNameTaupe;
extern ConversationColorName const ConversationColorNameSteel;

extern ConversationColorName const kConversationColorName_Default;

// Loki: Friend request state
typedef NS_ENUM(NSInteger, TSThreadFriendRequestState) {
    // New conversation, no messages sent or received
    TSThreadFriendRequestStateNone,
    // This state is used to lock the input early while sending
    TSThreadFriendRequestStatePendingSend,
    // Friend request send, awaiting response
    TSThreadFriendRequestStateRequestSent,
    // Friend request received, awaiting user input
    TSThreadFriendRequestStateRequestReceived,
    // We are friends with the user of this thread
    TSThreadFriendRequestStateFriends,
    // Friend request sent but it timed out (user didn't accept within x time)
    TSThreadFriendRequestStateRequestExpired,
};

/**
 *  TSThread is the superclass of TSContactThread and TSGroupThread
 */
@interface TSThread : TSYapDatabaseObject

@property (nonatomic) BOOL shouldThreadBeVisible;
@property (nonatomic, readonly) NSDate *creationDate;
@property (nonatomic, readonly) BOOL isArchivedByLegacyTimestampForSorting;

// Loki: The current friend request state with this thread
@property (atomic, readonly) TSThreadFriendRequestState friendRequestState;

/**
 *  Whether the object is a group thread or not.
 *
 *  @return YES if is a group thread, NO otherwise.
 */
- (BOOL)isGroupThread;

/**
 *  Returns the name of the thread.
 *
 *  @return The name of the thread.
 */
- (NSString *)name;

@property (nonatomic, readonly) ConversationColorName conversationColorName;

- (void)updateConversationColorName:(ConversationColorName)colorName
                        transaction:(YapDatabaseReadWriteTransaction *)transaction;
+ (ConversationColorName)stableColorNameForNewConversationWithString:(NSString *)colorSeed;
@property (class, nonatomic, readonly) NSArray<ConversationColorName> *conversationColorNames;

/**
 * @returns
 *   Signal Id (e164) of the contact if it's a contact thread.
 */
- (nullable NSString *)contactIdentifier;

/**
 * @returns recipientId for each recipient in the thread
 */
@property (nonatomic, readonly) NSArray<NSString *> *recipientIdentifiers;

- (BOOL)isNoteToSelf;

#pragma mark Interactions

/**
 *  @return The number of interactions in this thread.
 */
- (NSUInteger)numberOfInteractions;

/**
 * Get all messages in the thread we weren't able to decrypt
 */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (NSArray<TSInvalidIdentityKeyReceivingErrorMessage *> *)receivedMessagesForInvalidKey:(NSData *)key;
#pragma clang diagnostic pop

- (NSUInteger)unreadMessageCountWithTransaction:(YapDatabaseReadTransaction *)transaction
    NS_SWIFT_NAME(unreadMessageCount(transaction:));

- (BOOL)hasSafetyNumbers;

- (void)markAllAsReadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;

/**
 *  Returns the string that will be displayed typically in a conversations view as a preview of the last message
 *received in this thread.
 *
 *  @return Thread preview string.
 */
- (NSString *)lastMessageTextWithTransaction:(YapDatabaseReadTransaction *)transaction
    NS_SWIFT_NAME(lastMessageText(transaction:));

- (nullable TSInteraction *)lastInteractionForInboxWithTransaction:(YapDatabaseReadTransaction *)transaction
    NS_SWIFT_NAME(lastInteractionForInbox(transaction:));

/**
 *  Updates the thread's caches of the latest interaction.
 *
 *  @param lastMessage Latest Interaction to take into consideration.
 *  @param transaction Database transaction.
 */
- (void)updateWithLastMessage:(TSInteraction *)lastMessage transaction:(YapDatabaseReadWriteTransaction *)transaction;

#pragma mark Archival

/**
 * @return YES if no new messages have been sent or received since the thread was last archived.
 */
- (BOOL)isArchivedWithTransaction:(YapDatabaseReadTransaction *)transaction;

/**
 *  Archives a thread
 *
 *  @param transaction Database transaction.
 */
- (void)archiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;

/**
 *  Unarchives a thread
 *
 *  @param transaction Database transaction.
 */
- (void)unarchiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;

- (void)removeAllThreadInteractionsWithTransaction:(YapDatabaseReadWriteTransaction *)transaction;


#pragma mark Disappearing Messages

- (OWSDisappearingMessagesConfiguration *)disappearingMessagesConfigurationWithTransaction:
    (YapDatabaseReadTransaction *)transaction;
- (uint32_t)disappearingMessagesDurationWithTransaction:(YapDatabaseReadTransaction *)transaction;

#pragma mark Drafts

/**
 *  Returns the last known draft for that thread. Always returns a string. Empty string if nil.
 *
 *  @param transaction Database transaction.
 *
 *  @return Last known draft for that thread.
 */
- (NSString *)currentDraftWithTransaction:(YapDatabaseReadTransaction *)transaction;

/**
 *  Sets the draft of a thread. Typically called when leaving a conversation view.
 *
 *  @param draftString Draft string to be saved.
 *  @param transaction Database transaction.
 */
- (void)setDraft:(NSString *)draftString transaction:(YapDatabaseReadWriteTransaction *)transaction;

@property (atomic, readonly) BOOL isMuted;
@property (atomic, readonly, nullable) NSDate *mutedUntilDate;

#pragma mark - Update With... Methods

- (void)updateWithMutedUntilDate:(NSDate *)mutedUntilDate transaction:(YapDatabaseReadWriteTransaction *)transaction;

#pragma mark - Loki Friend Request

/// Check if this thread is a friend
- (BOOL)isFriend;

/// Check if a friend request is pending
- (BOOL)isPendingFriendRequest;

/// Check if a friend request has been sent to this thread
- (BOOL)hasSentFriendRequest;

/// Check if a friend request has been received from this thread
- (BOOL)hasReceivedFriendRequest;

@end


NS_ASSUME_NONNULL_END
