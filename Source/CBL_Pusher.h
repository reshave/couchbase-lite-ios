//
//  CBL_Pusher.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/5/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//

#import "CBL_Puller.h"
#import "CBLDatabase.h"
#import "CBLStatus.h"


/** Replicator that pushes to a remote CouchDB. */
@interface CBL_Pusher : CBL_Replicator
{
    BOOL _createTarget;
    BOOL _creatingTarget;
    BOOL _observing;
    BOOL _uploading;
    NSMutableArray* _uploaderQueue;
    BOOL _dontSendMultipart;
    NSMutableIndexSet* _pendingSequences;
    SequenceNumber _maxPendingSequence;
}

@property BOOL createTarget;

@end


CBLStatus CBLStatusFromBulkDocsResponseItem(NSDictionary* item);
