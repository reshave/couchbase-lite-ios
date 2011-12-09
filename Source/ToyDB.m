/*
 *  ToyDB.m
 *  ToyCouch
 *
 *  Created by Jens Alfke on 6/19/10.
 *  Copyright 2010 Jens Alfke. All rights reserved.
 *
 */

#import "ToyDB.h"
#import "ToyDB_Internal.h"
#import "ToyRev.h"
#import "ToyView.h"

#import "FMDatabase.h"


NSString* const ToyDBChangeNotification = @"ToyDBChange";


@implementation ToyDB


+ (ToyDB*) createEmptyDBAtPath: (NSString*)path {
    [[NSFileManager defaultManager] removeItemAtPath: path error: nil];
    ToyDB *db = [[[self alloc] initWithPath: path] autorelease];
    if (![db open])
        return nil;
    return db;
}


- (id) initWithPath: (NSString*)path {
    if (self = [super init]) {
        _path = [path copy];
        _fmdb = [[FMDatabase alloc] initWithPath: _path];
        _fmdb.busyRetryTimeout = 10;
#if DEBUG
        _fmdb.logsErrors = YES;
        _fmdb.crashOnErrors = YES;
#else
        _fmdb.logsErrors = WillLogTo(ToyDB);
#endif
        _fmdb.traceExecution = WillLogTo(ToyDBVerbose);
    }
    return self;
}

- (NSString*) description {
    return $sprintf(@"%@[%@]", [self class], _fmdb.databasePath);
}

- (BOOL) exists {
    return [[NSFileManager defaultManager] fileExistsAtPath: _path];
}

- (BOOL) open {
    if (_open)
        return YES;
    if (![_fmdb open])
        return NO;
    
    // ***** THIS IS THE SQL DATABASE SCHEMA! *****
    NSString *sql = @"\
        PRAGMA foreign_keys = ON; \
        CREATE TABLE IF NOT EXISTS docs ( \
            sequence INTEGER PRIMARY KEY AUTOINCREMENT, \
            docid TEXT NOT NULL, \
            revid TEXT NOT NULL, \
            parent INTEGER REFERENCES docs(sequence) ON DELETE SET NULL, \
            current BOOLEAN, \
            deleted BOOLEAN DEFAULT 0, \
            json BLOB); \
        CREATE TABLE IF NOT EXISTS views ( \
            view_id INTEGER PRIMARY KEY, \
            name TEXT UNIQUE NOT NULL,\
            version TEXT, \
            lastsequence INTEGER DEFAULT 0); \
        CREATE TABLE IF NOT EXISTS maps ( \
            view_id INTEGER NOT NULL REFERENCES views(view_id) ON DELETE CASCADE, \
            sequence INTEGER NOT NULL REFERENCES docs(sequence) ON DELETE CASCADE, \
            key STRING NOT NULL, \
            value STRING);";
    // Declaring docs.sequence as AUTOINCREMENT means the values will always be
    // monotonically increasing, never reused. See <http://www.sqlite.org/autoinc.html>
    // TODO: 'docid' should be factored out into a separate table for efficiency.
    for (NSString* statement in [sql componentsSeparatedByString: @";"]) {
        if (statement.length && ![_fmdb executeUpdate: statement]) {
            [self close];
            return NO;
        }
    }

    _open = YES;
    return YES;
}

#if SQLITE_VERSION_NUMBER >= 3005000
- (BOOL) openWithFlags:(int)flags {
    return [_fmdb openWithFlags: flags];
}
#endif

- (BOOL) close {
    if (!_open || ![_fmdb close])
        return NO;
    _open = NO;
    return YES;
}

- (void) dealloc {
    [_fmdb release];
    [_path release];
    [_views release];
    [super dealloc];
}

@synthesize fmdb=_fmdb;

- (NSString*) path {
    return _fmdb.databasePath;
}

- (NSString*) name {
    return _fmdb.databasePath.lastPathComponent.stringByDeletingPathExtension;
}

- (int) error {
    return _fmdb.lastErrorCode;
}

- (NSString*) errorMessage {
    return _fmdb.lastErrorMessage;
}


- (void) beginTransaction {
    if (++_transactionLevel == 1) {
        LogTo(ToyDB, @"Begin transaction...");
        [_fmdb beginTransaction];
        _transactionFailed = NO;
    }
}

- (void) endTransaction {
    Assert(_transactionLevel > 0);
    if (--_transactionLevel == 0) {
        if (_transactionFailed) {
            LogTo(ToyDB, @"Rolling back failed transaction!");
            [_fmdb rollback];
        } else {
            LogTo(ToyDB, @"Committing transaction");
            [_fmdb commit];
        }
    }
    _transactionFailed = NO;
}

- (BOOL) transactionFailed { return _transactionFailed; }

- (void) setTransactionFailed: (BOOL)failed {
    Assert(_transactionLevel > 0);
    Assert(failed, @"Can't clear the transactionFailed property!");
    LogTo(ToyDB, @"Current transaction failed, will abort!");
    _transactionFailed = failed;
}


#pragma mark - GETTING DOCUMENTS:


- (ToyRev*) getDocumentWithID: (NSString*)docID {
    return [self getDocumentWithID: docID revisionID: nil];
}

- (ToyRev*) getDocumentWithID: (NSString*)docID revisionID: (NSString*)revID {
    ToyRev* result = nil;
    NSString* sql;
    if (revID)
        sql = @"SELECT revid, deleted, json FROM docs WHERE docid=? and revid=? LIMIT 1";
    else
        sql = @"SELECT revid, deleted, json FROM docs WHERE docid=? and current=1 and deleted=0 "
               "ORDER BY revid DESC LIMIT 1";
    FMResultSet *r = [_fmdb executeQuery: sql, docID, revID];
    if ([r next]) {
        if (!revID)
            revID = [r stringForColumnIndex: 0];
        BOOL deleted = [r boolForColumnIndex: 1];
        NSData* json = [r dataForColumnIndex: 2];
        result = [[[ToyRev alloc] initWithDocID: docID revID: revID deleted: deleted] autorelease];
        if (json)
            result.asJSON = json;
    }
    [r close];
    return result;
}


- (ToyDBStatus) loadRevisionBody: (ToyRev*)rev {
    if (rev.body)
        return 200;
    Assert(rev.docID && rev.revID);
    FMResultSet *r = [_fmdb executeQuery: @"SELECT json FROM docs "
                                           "WHERE docid=? AND revid=? LIMIT 1",
                                          rev.docID, rev.revID];
    if (!r)
        return 500;
    ToyDBStatus status = 404;
    if ([r next]) {
        // Found the rev. But the JSON still might be null if the database has been compacted.
        status = 200;
        NSData* json = [r dataForColumnIndex: 0];
        if (json)
            rev.asJSON = json;
    }
    [r close];
    return status;
}


- (ToyDBStatus) compact {
    // Can't delete any rows because that would lose revision tree history.
    // But we can remove the JSON of non-current revisions, which is most of the space.
    return [_fmdb executeUpdate: @"UPDATE docs SET json=null WHERE current=0"] ? 200 : 500;
}


#pragma mark - PUTTING DOCUMENTS:


+ (BOOL) isValidDocumentID: (NSString*)str {
    // http://wiki.apache.org/couchdb/HTTP_Document_API#Documents
    return (str.length > 0);
}


- (NSUInteger) documentCount {
    NSUInteger result = NSNotFound;
    FMResultSet* r = [_fmdb executeQuery: @"SELECT COUNT(DISTINCT docid) FROM docs "
                                           "WHERE current=1 AND deleted=0"];
    if ([r next]) {
        result = [r intForColumnIndex: 0];
    }
    [r close];
    return result;    
}


- (SequenceNumber) lastSequence {
    FMResultSet* r = [_fmdb executeQuery: @"SELECT sequence FROM docs ORDER BY sequence DESC LIMIT 1"];
    if (!r)
        return NSNotFound;
    SequenceNumber result = 0;
    if ([r next])
        result = [r longLongIntForColumnIndex: 0];
    [r close];
    return result;    
}


static NSString* createUUID() {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    NSString* str = NSMakeCollectable(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    return [str autorelease];
}

- (NSString*) generateDocumentID {
    return createUUID();
}

- (NSString*) generateNextRevisionID: (NSString*)revID {
    // Revision IDs have a generation count, a hyphen, and a UUID.
    int generation = 0;
    if (revID) {
        NSScanner* scanner = [[NSScanner alloc] initWithString: revID];
        bool ok = [scanner scanInt: &generation] && generation > 0;
        [scanner release];
        if (!ok)
            return nil;
    }
    NSString* digest = createUUID();  //TODO: Generate canonical digest of body
    return [NSString stringWithFormat: @"%i-%@", ++generation, digest];
}


- (void) notifyChange: (ToyRev*)rev
{
    NSDictionary* userInfo = $dict({@"rev", rev}, {@"seq", $object(rev.sequence)});
    [[NSNotificationCenter defaultCenter] postNotificationName: ToyDBChangeNotification
                                                        object: self
                                                      userInfo: userInfo];
}


// Raw row insertion. Returns new sequence, or 0 on error
- (SequenceNumber) insertRevision: (ToyRev*)rev
                   parentSequence: (SequenceNumber)parentSequence
                          current: (BOOL)current
                             JSON: (NSData*)json
{
    if (![_fmdb executeUpdate: @"INSERT INTO docs (docid, revid, parent, current, deleted, json) "
                                "VALUES (?, ?, ?, ?, ?, ?)",
                               rev.docID,
                               rev.revID,
                               (parentSequence ? $object(parentSequence) : nil ),
                               $object(current),
                               $object(rev.deleted),
                               json])
        return 0;
    return _fmdb.lastInsertRowId;
}


- (ToyRev*) putRevision: (ToyRev*)rev
         prevRevisionID: (NSString*)prevRevID   // rev ID being replaced, or nil if an insert
                 status: (ToyDBStatus*)outStatus
{
    Assert(!rev.revID);
    Assert(outStatus);
    NSString* docID = rev.docID;
    BOOL deleted = rev.deleted;
    if (!rev || (prevRevID && !docID) || (deleted && !prevRevID)) {
        *outStatus = 400;
        return nil;
    }
    
    *outStatus = 500;
    [self beginTransaction];
    FMResultSet* r = nil;
    SequenceNumber parentSequence = 0;
    if (prevRevID) {
        // Replacing: make sure given prevRevID is current & find its sequence number:
        r = [_fmdb executeQuery: @"SELECT sequence FROM docs "
                                  "WHERE docid=? AND revid=? and current=1",
                                 docID, prevRevID];
        if (!r)
            goto exit;
        if (![r next]) {
            // Not found: either a 404 or a 409, depending on whether there is any current revision
            *outStatus = [self getDocumentWithID: docID] ? 409 : 404;
            goto exit;
        }
        parentSequence = [r longLongIntForColumnIndex: 0];
        [r close];
        r = nil;
        
        // Make replaced rev non-current:
        if (![_fmdb executeUpdate: @"UPDATE docs SET current=0 WHERE sequence=?",
                                   $object(parentSequence)])
            goto exit;
    } else {
        // Inserting: make sure docID doesn't exist, or exists but is currently deleted
        if (!docID)
            docID = [self generateDocumentID];
        r = [_fmdb executeQuery: @"SELECT sequence, deleted FROM docs "
                                  "WHERE docid=? and current=1 ORDER BY revid DESC LIMIT 1",
                                 docID];
        if (!r)
            goto exit;
        if ([r next]) {
            if ([r boolForColumnIndex: 1]) {
                // Make the deleted revision no longer current:
                if (![_fmdb executeUpdate: @"UPDATE docs SET current=0 WHERE sequence=?",
                                           $object([r longLongIntForColumnIndex: 0])])
                    goto exit;
            } else {
                *outStatus = 409;
                goto exit;
            }
        }
        [r close];
        r = nil;
    }
    
    // Bump the revID and update the JSON:
    NSString* newRevID = [self generateNextRevisionID: prevRevID];
    NSMutableDictionary* props = nil;
    NSData* json = nil;
    if (!rev.deleted) {
        props = [[rev.properties mutableCopy] autorelease];
        if (!props) {
            *outStatus = 400;  // bad or missing JSON
            goto exit;
        }
        [props setObject: docID forKey: @"_id"];
        [props setObject: newRevID forKey: @"_rev"];
        json = [NSJSONSerialization dataWithJSONObject: props options: 0 error: nil];
        NSAssert(json!=nil, @"Couldn't serialize document");
    }
    
    if (![_fmdb executeUpdate: @"INSERT INTO docs (docid, revid, parent, current, deleted, json) "
                                "VALUES (?, ?, ?, 1, ?, ?)",
                               docID,
                               newRevID,
                               (parentSequence ? $object(parentSequence) : nil),
                               $object(deleted),
                               json])
        goto exit;
    SequenceNumber sequence = _fmdb.lastInsertRowId;
    Assert(sequence > 0);
    
    // Success! Update the revision & its properties, with the new revID
    rev = [[rev copyWithDocID: docID revID: newRevID] autorelease];
    if (props)
        rev.properties = props;
    rev.sequence = sequence;
    *outStatus = deleted ? 200 : 201;
    
exit:
    [r close];
    if (*outStatus >= 300)
        self.transactionFailed = YES;
    [self endTransaction];
    if (*outStatus >= 300) 
        return nil;
    
    // Send a change notification:
    [self notifyChange: rev];
    return rev;
}


- (ToyDBStatus) forceInsert: (ToyRev*)rev revisionHistory: (NSArray*)history {
    // First look up all locally-known revisions of this document:
    NSString* docID = rev.docID;
    ToyRevList* localRevs = [self getAllRevisionsOfDocumentID: docID];
    if (!localRevs)
        return 500;
    
    // Walk through the remote history in chronological order, matching each revision ID to
    // a local revision. When the list diverges, start creating blank local revisions to fill
    // in the local history:
    SequenceNumber parentSequence = 0;
    for (NSInteger i = history.count - 1; i>=0; --i) {
        NSString* revID = [history objectAtIndex: i];
        ToyRev* localRev = [localRevs revWithDocID: docID revID: revID];
        if (localRev) {
            // This revision is known locally. Remember its sequence as the parent of the next one:
            parentSequence = localRev.sequence;
            Assert(parentSequence > 0);
        } else {
            // This revision isn't known, so add it:
            ToyRev* newRev;
            NSData* json = nil;
            BOOL current = NO;
            if (i==0) {
                // Hey, this is the leaf revision we're inserting:
                newRev = rev;
                if (!rev.deleted) {
                    json = rev.asJSON;
                    if (!json)
                        return 400;
                }
                current = YES;
            } else {
                // It's an intermediate parent, so insert a stub:
                newRev = [[[ToyRev alloc] initWithDocID: docID revID: revID deleted: NO]
                                autorelease];
            }

            // Insert it:
            parentSequence = [self insertRevision: newRev
                                   parentSequence: parentSequence
                                          current: current 
                                             JSON: json];
            if (parentSequence <= 0)
                return 500;
        }
    }
    
    // Record its sequence and send a change notification:
    rev.sequence = parentSequence;
    [self notifyChange: rev];
    
    return 201;
}


#pragma mark - CHANGES:


- (NSArray*) changesSinceSequence: (int)lastSequence
                          options: (const ToyDBQueryOptions*)options
{
    if (!options) options = &kDefaultToyDBQueryOptions;

    FMResultSet* r = [_fmdb executeQuery: @"SELECT sequence, docid, revid, deleted FROM docs "
                                           "WHERE sequence > ? AND current=1 "
                                           "ORDER BY sequence LIMIT ?",
                                          $object(lastSequence), $object(options->limit)];
    if (!r)
        return nil;
    NSMutableArray* changes = $marray();
    while ([r next]) {
        ToyRev* rev = [[ToyRev alloc] initWithDocID: [r stringForColumnIndex: 1]
                                              revID: [r stringForColumnIndex: 2]
                                            deleted: [r boolForColumnIndex: 3]];
        rev.sequence = [r longLongIntForColumnIndex: 0];
        [changes addObject: rev];
        [rev release];
    }
    [r close];
    return changes;
}


#pragma mark - QUERIES:


- (ToyView*) viewNamed: (NSString*)name {
    ToyView* view = [_views objectForKey: name];
    if (!view) {
        view = [[[ToyView alloc] initWithDatabase: self name: name] autorelease];
        if (!view)
            return nil;
        if (!_views)
            _views = [[NSMutableDictionary alloc] init];
        [_views setObject: view forKey: name];
    }
    return view;
}


- (NSArray*) allViews {
    FMResultSet* r = [_fmdb executeQuery: @"SELECT name FROM views"];
    if (!r)
        return nil;
    NSMutableArray* views = $marray();
    while ([r next])
        [views addObject: [self viewNamed: [r stringForColumnIndex: 0]]];
    return views;
}


- (ToyDBStatus) deleteViewNamed: (NSString*)name {
    if (![_fmdb executeUpdate: @"DELETE FROM views WHERE name=?", name])
        return 500;
    [_views removeObjectForKey: name];
    return _fmdb.changes ? 200 : 404;
}


// http://wiki.apache.org/couchdb/HTTP_view_API#Querying_Options


const ToyDBQueryOptions kDefaultToyDBQueryOptions = {
    nil, nil, 0, INT_MAX, NO, NO, NO
};


- (NSDictionary*) getAllDocs: (const ToyDBQueryOptions*)options {
    if (!options)
        options = &kDefaultToyDBQueryOptions;
    
    SequenceNumber update_seq = 0;
    if (options->updateSeq)
        update_seq = self.lastSequence;     // TODO: needs to be atomic with the following SELECT
    
    NSString* sql = $sprintf(@"SELECT docid, revid %@ FROM docs "
                              "WHERE current=1 AND deleted=0 "
                              "ORDER BY docid %@ LIMIT ? OFFSET ?",
                             (options->includeDocs ? @", json" : @""),
                             (options->descending ? @"DESC" : @"ASC"));
    FMResultSet* r = [_fmdb executeQuery: sql, $object(options->limit), $object(options->skip)];
    if (!r)
        return nil;
    
    NSMutableArray* rows = $marray();
    while ([r next]) {
        NSString* docID = [r stringForColumnIndex: 0];
        NSString* revID = [r stringForColumnIndex: 1];
        NSDictionary* docContents = nil;
        if (options->includeDocs) {
            docContents = [NSJSONSerialization JSONObjectWithData: [r dataForColumnIndex: 2]
                                                          options: 0 error: nil];
        }
        NSDictionary* change = $dict({@"id",  docID},
                                     {@"key", docID},
                                     {@"value", $dict({@"rev", revID})},
                                     {@"doc", docContents});
        [rows addObject: change];
    }
    [r close];
    NSUInteger totalRows = rows.count;      //??? Is this true, or does it ignore limit/offset?
    return $dict({@"rows", $object(rows)},
                 {@"total_rows", $object(totalRows)},
                 {@"offset", $object(options->skip)},
                 {@"update_seq", update_seq ? $object(update_seq) : nil});
}


#pragma mark - FOR REPLICATION


static NSString* quote(NSString* str) {
    return [str stringByReplacingOccurrencesOfString: @"'" withString: @"''"];
}

static NSString* joinQuoted(NSArray* strings) {
    if (strings.count == 0)
        return @"";
    NSMutableString* result = [NSMutableString stringWithString: @"'"];
    BOOL first = YES;
    for (NSString* str in strings) {
        if (first)
            first = NO;
        else
            [result appendString: @"','"];
        [result appendString: quote(str)];
    }
    [result appendString: @"'"];
    return result;
}


- (BOOL) findMissingRevisions: (ToyRevList*)toyRevs {
    if (toyRevs.count == 0)
        return YES;
    NSString* sql = $sprintf(@"SELECT docid, revid FROM docs "
                              "WHERE docid IN (%@) AND revid in (%@)",
                             joinQuoted(toyRevs.allDocIDs), joinQuoted(toyRevs.allRevIDs));
    FMResultSet* r = [_fmdb executeQuery: sql];
    if (!r)
        return NO;
    while ([r next]) {
        ToyRev* rev = [toyRevs revWithDocID: [r stringForColumnIndex: 0]
                                      revID: [r stringForColumnIndex: 1]];
        if (rev)
            [toyRevs removeRev: rev];
    }
    [r close];
    return YES;
}


- (ToyRevList*) getAllRevisionsOfDocumentID: (NSString*)docID {
    FMResultSet* r = [_fmdb executeQuery: @"SELECT sequence, revid, deleted FROM docs "
                                           "WHERE docid=? ORDER BY sequence DESC",
                                          docID];
    if (!r)
        return nil;
    ToyRevList* revs = [[[ToyRevList alloc] init] autorelease];
    while ([r next]) {
        ToyRev* rev = [[ToyRev alloc] initWithDocID: docID
                                              revID: [r stringForColumnIndex: 1]
                                            deleted: [r boolForColumnIndex: 2]];
        rev.sequence = [r longLongIntForColumnIndex: 0];
        [revs addRev: rev];
        [rev release];
    }
    [r close];
    return revs;
}


- (NSArray*) getRevisionHistory: (ToyRev*)rev {
    NSString* docID = rev.docID;
    NSString* revID = rev.revID;
    Assert(revID && docID);
    FMResultSet* r = [_fmdb executeQuery: @"SELECT sequence, parent, revid, deleted FROM docs "
                                           "WHERE docid=? ORDER BY sequence DESC",
                                          rev.docID];
    if (!r)
        return nil;
    SequenceNumber lastSequence = 0;
    NSMutableArray* history = $marray();
    while ([r next]) {
        SequenceNumber sequence = [r longLongIntForColumnIndex: 0];
        BOOL matches;
        if (lastSequence == 0)
            matches = ($equal(revID, [r stringForColumnIndex: 2]));
        else
            matches = (sequence == lastSequence);
        if (matches) {
            NSString* revID = [r stringForColumnIndex: 2];
            BOOL deleted = [r boolForColumnIndex: 3];
            ToyRev* rev = [[ToyRev alloc] initWithDocID: docID revID: revID deleted: deleted];
            rev.sequence = sequence;
            [history addObject: rev];
            [rev release];
            lastSequence = [r longLongIntForColumnIndex: 1];
            if (lastSequence == 0)
                break;
        }
    }
    [r close];
    return history;
}


@end