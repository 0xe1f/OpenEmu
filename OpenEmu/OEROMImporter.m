/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEROMImporter.h"
#import "OEImportItem.h"

#import "OELibraryDatabase.h"
#import "OEDBRom.h"
#import "OEDBGame.h"
#import "OEDBCollection.h"
#import "OEDBSystem.h"
#import "OESystemPlugin.h"

#import "NSURL+OELibraryAdditions.h"
#import "NSFileManager+OEHashingAdditions.h"
#import "NSArray+OEAdditions.h"

#import <CommonCrypto/CommonDigest.h>
#import <OpenEmuSystem/OpenEmuSystem.h>
#import <XADMaster/XADArchive.h>
#import <objc/runtime.h>

#pragma mark User Default Keys -
NSString *const OEOrganizeLibraryKey       = @"organizeLibrary";
NSString *const OECopyToLibraryKey         = @"copyToLibrary";
NSString *const OEAutomaticallyGetInfoKey  = @"automaticallyGetInfo";

#pragma mark Error Codes -
NSString *const OEImportErrorDomainFatal      = @"OEImportFatalDomain";
NSString *const OEImportErrorDomainResolvable = @"OEImportResolvableDomain";
NSString *const OEImportErrorDomainSuccess    = @"OEImportSuccessDomain";

#pragma mark Import Info Keys -
NSString *const OEImportInfoMD5         = @"md5";
NSString *const OEImportInfoCRC         = @"crc";
NSString *const OEImportInfoROMObjectID = @"RomObjectID";
NSString *const OEImportInfoSystemID    = @"systemID";
NSString *const OEImportInfoCollectionID= @"collectionID";
NSString *const OEImportInfoArchivedFileURL   = @"archivedFileURL";
NSString *const OEImportInfoArchivedFileIndex = @"archivedFileIndex";

@interface OEROMImporter ()
{
    dispatch_queue_t dispatchQueue;
    NSLock *lock;
}

@property(readwrite)            NSInteger          status;
@property(readwrite)            NSInteger          numberOfProcessedItems;
@property(readwrite, nonatomic) NSInteger          totalNumberOfItems;
@property(readwrite)            NSMutableArray    *queue;
@property(readwrite, strong)    NSMutableArray    *spotlightSearchResults;
@property(weak)                 OELibraryDatabase *database;

@property(readwrite, retain) NSMutableSet *unsavedMD5Hashes;
@property(readwrite, retain) NSMutableSet *unsavedCRCHashes;

#pragma mark - Import Steps
- (void)performImportStepCheckDirectory:(OEImportItem *)item;
- (void)performImportStepCheckArchiveFile:(OEImportItem *)item;
- (void)performImportStepHash:(OEImportItem *)item;
- (void)performImportStepCheckHash:(OEImportItem *)item;
- (void)performImportStepDetermineSystem:(OEImportItem *)item;
- (void)performImportStepOrganize:(OEImportItem *)item;
- (void)performImportStepOrganizeAdditionalFiles:(OEImportItem *)item;

- (void)performImportStepCreateCoreDataObjects:(OEImportItem *)item;

- (void)scheduleItemForNextStep:(OEImportItem *)item;
- (void)stopImportForItem:(OEImportItem *)item withError:(NSError *)error;
- (void)cleanupImportForItem:(OEImportItem *)item;

- (void)OE_performSelectorOnDelegate:(SEL)selector withObject:(id)object;
@end

@implementation OEROMImporter
@synthesize database, delegate;
@synthesize spotlightSearchResults;

+ (void)initialize
{
    if(self != [OEROMImporter class]) return;

    NSDictionary *defaults = @{
                              OEOrganizeLibraryKey      : @(YES),
                              OECopyToLibraryKey        : @(YES),
                              OEAutomaticallyGetInfoKey : @(YES),
                              };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

- (id)initWithDatabase:(OELibraryDatabase *)aDatabase
{
    self = [super init];
    if (self != nil)
    {
        [self setDatabase:aDatabase];
        [self setQueue:[NSMutableArray array]];
        [self setSpotlightSearchResults:[NSMutableArray arrayWithCapacity:1]];
        [self setNumberOfProcessedItems:0];
        
        [self setUnsavedCRCHashes:[NSMutableSet set]];
        [self setUnsavedMD5Hashes:[NSMutableSet set]];

        lock = [[NSLock alloc] init];

        dispatchQueue = dispatch_queue_create("org.openemu.importqueue", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t priority = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
        dispatch_set_target_queue(dispatchQueue, priority);
        [self setStatus:OEImporterStatusStopped];
    }
    return self;
}

- (void)processNextItem
{
    DLog();
    if([self status] != OEImporterStatusRunning)
        return;

    if([lock tryLock] == NO)
        return;

    // Find next item that is idle
    OEImportItem *nextItem = [[self queue] firstObjectMatchingBlock:^BOOL (id evaluatedObject)
                              {
                                  return [evaluatedObject importState] == OEImportItemStatusIdle;
                              }];

    if(nextItem != nil)
    {
        [nextItem setImportState:OEImportItemStatusActive];
        dispatch_async(dispatchQueue, ^{
            importBlock(self, nextItem);
            [self OE_performSelectorOnDelegate:@selector(romImporter:startedProcessingItem:) withObject:nextItem];
        });
    }
    else
    {
        dispatch_async(dispatchQueue, ^{
            [self setQueue:[NSMutableArray array]];
            [self setNumberOfProcessedItems:0];
            [self setTotalNumberOfItems:0];

            [self OE_performSelectorOnDelegate:@selector(romImporterDidFinish:) withObject:nil];
            [self setStatus:OEImporterStatusStopped];
        });
    }
    [lock unlock];
}

- (void)dealloc
{
    dispatch_release(dispatchQueue);
}

#pragma mark - State
- (BOOL)saveQueue
{
    NSURL *url = [[self database] importQueueURL];
    
    IMPORTDLog(@"URL: %@", url);
    // remove last saved queue if any
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    
    IMPORTDLog(@"Saving %ld items", [[self queue] count]);
    
    // only save queue if it's not empty
    if([[self queue] count] != 0)
    {
        // write new queue data
        NSData *queueData = [NSKeyedArchiver archivedDataWithRootObject:[self queue]];
        return [queueData writeToURL:url atomically:YES];
    }
    return NO;
}

- (BOOL)loadQueue
{
    NSURL *url = [[self database] importQueueURL];
    IMPORTDLog(@"URL: %@", url);
    
    // read previously stored data
    NSData *queueData = [NSData dataWithContentsOfURL:url];
    if(queueData == nil) return NO;
    
    // remove file if reading was successfull
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    
    // Restore queue
    NSMutableArray *queue = [NSKeyedUnarchiver unarchiveObjectWithData:queueData];
    IMPORTDLog(@"Restored %ld items", [queue count]);
    if ([queue count])
    {
        [self setNumberOfProcessedItems:0];
        [self setTotalNumberOfItems:[queue count]];
        [self setQueue:queue];
        return YES;
    }
    return NO;
}

#pragma mark - Import Block
static void importBlock(OEROMImporter *importer, OEImportItem *item)
{
    @autoreleasepool {
        IMPORTDLog(@"Status: %ld | Step: %d | URL: %@", [importer status], [item importStep], [item sourceURL]);
        if([importer status] == OEImporterStatusPausing || [importer status] == OEImporterStatusPaused)
        {
            DLog(@"skipping item!");
            if([item importState] == OEImportItemStatusActive)
                [item setImportState:OEImportItemStatusIdle];
        }
        else if([importer status] == OEImporterStatusStopping || [importer status] == OEImporterStatusStopped)
        {
            [item setError:nil];
            [item setImportState:OEImportItemStatusCancelled];
            [importer cleanupImportForItem:item];
            DLog(@"deleting item!");
        }
        else
        {
            [importer OE_performSelectorOnDelegate:@selector(romImporter:changedProcessingPhaseOfItem:) withObject:item];
            switch([item importStep])
            {
                case OEImportStepCheckDirectory  : [importer performImportStepCheckDirectory:item];  break;
                case OEImportStepCheckArchiveFile : [importer performImportStepCheckArchiveFile:item]; break;
                case OEImportStepHash            : [importer performImportStepHash:item];            break;
                case OEImportStepCheckHash       : [importer performImportStepCheckHash:item];       break;
                case OEImportStepDetermineSystem : [importer performImportStepDetermineSystem:item]; break;
                case OEImportStepOrganize        : [importer performImportStepOrganize:item];        break;
                case OEImportStepOrganizeAdditionalFiles : [importer performImportStepOrganizeAdditionalFiles:item]; break;
                case OEImportStepCreateCoreDataObjects: [importer performImportStepCreateCoreDataObjects:item]; break;
                default : return;
            }
            
            if([item importState] == OEImportItemStatusActive)
                [importer scheduleItemForNextStep:item];
        }
    }
}

#pragma mark - Import Steps
// Checks if item.url points to a directory and adds its contents to the queue (by replacing item)
- (void)performImportStepCheckDirectory:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    NSURL *url = [item URL];
    if([url isDirectory])
    {
        NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsPackageKey, NSURLIsHiddenKey] options:NSDirectoryEnumerationSkipsSubdirectoryDescendants|NSDirectoryEnumerationSkipsPackageDescendants|NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url, NSError *error) {
            [self stopImportForItem:item withError:error];
            return NO;
        }];
        
        NSURL *subURL;
        while([self status]==OEImporterStatusRunning && (subURL = [directoryEnumerator nextObject]))
        {
            OEImportItem *subItem = [OEImportItem itemWithURL:subURL andCompletionHandler:[item completionHandler]];
            if(subItem)
            {
                if([[item importInfo] objectForKey:OEImportInfoCollectionID])
                    [[subItem importInfo] setObject:[[item importInfo] objectForKey:OEImportInfoCollectionID] forKey:OEImportInfoCollectionID];
                [[self queue] addObject:subItem];
                self.totalNumberOfItems++;
                [self OE_performSelectorOnDelegate:@selector(romImporterChangedItemCount:) withObject:self];
            }
        };
        
        if([self status]==OEImporterStatusRunning)
        {
            self.totalNumberOfItems--;
            [item setImportState:OEImportItemStatusFinished];
            [[self queue] removeObjectIdenticalTo:item];
            [self processNextItem];
        }
    }
}

- (void)performImportStepCheckArchiveFile:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    NSString *path = [[item URL] path];
    XADArchive *archive = [XADArchive archiveForFile:path];
    if (archive != nil)
    {
        NSMutableArray *newItems = [NSMutableArray arrayWithCapacity:[archive numberOfEntries]];

        NSString *formatName = [archive formatName];
        if ([formatName isEqualToString:@"MacBinary"])
            return;
        
        for(int i=0; i<[archive numberOfEntries]; i++)
        {
            if(![archive entryHasSize:i] || [archive entryIsEncrypted:i] || [archive entryIsDirectory:i] || [archive entryIsArchive:i])
            {
                DLog(@"Entry %d is either empty, or a directory or encrypted or iteself an archive", i);
                continue;
            }
            
            NSString *folder = temporaryDirectoryForDecompressionOfPath(path);
            NSString *name = [archive nameOfEntry:i];
            if ([[name pathExtension] length] == 0 && [[path pathExtension] length] > 0) {
                // this won't do. Re-add the archive's extension in case it's .smc or the like
                name = [name stringByAppendingPathExtension:[path pathExtension]];
            }
            NSString *tmpPath = [folder stringByAppendingPathComponent:name];
            
            BOOL isdir;
            NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:tmpPath isDirectory:&isdir]) {
                @try
                {
                    [archive _extractEntry:i as:tmpPath];
                }
                @catch (NSException *exception) {
                    [fm removeItemAtPath:folder error:nil];
                    tmpURL = nil;
                    DLog(@"unpack faield");
                }
            }
            
            if(tmpURL)
            {
                OEImportItem *subItem = [[OEImportItem alloc] init];
                [subItem setImportInfo:[[item importInfo] mutableCopy]];
                [subItem setImportState:OEImportItemStatusIdle];
                [subItem setImportStep:OEImportStepDetermineSystem];
                [subItem setArchive:item];
                [[subItem importInfo] setValue:tmpURL forKey:OEImportInfoArchivedFileURL];
                [[subItem importInfo] setValue:@(i)   forKey:OEImportInfoArchivedFileIndex];
                [newItems addObject:subItem];
                NSLog(@"%@ | %@", [subItem URL], [item URL]);
            }
        }

        NSUInteger currentIndex = [[self queue] indexOfObjectIdenticalTo:item];
        NSIndexSet *newItemIndexes = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(currentIndex+1, [newItems count])];
        [[self queue] insertObjects:newItems atIndexes:newItemIndexes];
        self.totalNumberOfItems += [newItems count];
        DLog(@"newItems: %@", newItems);

        self.totalNumberOfItems--;
        [self OE_performSelectorOnDelegate:@selector(romImporterChangedItemCount:) withObject:self];

        [item setImportState:OEImportItemStatusFinished];
        [[self queue] removeObjectAtIndex:currentIndex];
        [self processNextItem];
    }
}

// Calculates md5 and crc32 hash strings
- (void)performImportStepHash:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    NSURL         *url = [[item importInfo] valueForKey:OEImportInfoArchivedFileURL] ?: [item URL];
    NSString      *md5, *crc;
    NSError       *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    
    if(![fileManager hashFileAtURL:url md5:&md5 crc32:&crc error:&error])
    {
        DLog(@"unable to hash file, this is probably a fatal error");
        DLog(@"%@", error);
        
        [self stopImportForItem:item withError:error];
    }
    else
    {
        [[item importInfo] setValue:md5 forKey:OEImportInfoMD5];
        [[item importInfo] setValue:crc forKey:OEImportInfoCRC];
    }
}

// Checks if hash is already known, if so skips the file
- (void)performImportStepCheckHash:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    __block NSError  *error = nil;
    NSString *md5 = [[item importInfo] valueForKey:OEImportInfoMD5];
    NSString *crc = [[item importInfo] valueForKey:OEImportInfoCRC];

    __block OEDBRom *rom = nil;
    rom = [OEDBRom romWithMD5HashString:md5 inDatabase:[self database] error:&error];
    if(rom == nil) rom = [OEDBRom romWithCRC32HashString:crc inDatabase:[self database] error:&error];

    if(rom != nil)
    {
        NSURL *romURL = [rom URL];
        [[item importInfo] setValue:[[rom objectID] URIRepresentation] forKey:OEImportInfoROMObjectID];
        if(![romURL checkResourceIsReachableAndReturnError:&error])
        {
            DLog(@"rom file not available");
            DLog(@"%@", error);
            // TODO: depending on error finish here with 'already present' success
            // if the error says something like volume could not be found we might want to skip import because the file is probably on an external HD that is currently not connected
            // but if it just says the file was deleted we should replace the rom's url with the new one and continue importing
        }
        else
        {
            // TODO: set user info for error
            NSError *error = [NSError errorWithDomain:OEImportErrorDomainSuccess code:OEImportErrorCodeAlreadyInDatabase userInfo:nil];

            [self stopImportForItem:item withError:error];
        }
    }
    else
    {
        if([[self unsavedCRCHashes] containsObject:crc] || [[self unsavedMD5Hashes] containsObject:md5])
        {
            NSError *error = [NSError errorWithDomain:OEImportErrorDomainSuccess code:OEImportErrorCodeAlreadyInDatabase userInfo:nil];
            [self stopImportForItem:item withError:error];
        }
        
        [[self unsavedCRCHashes] addObject:crc];
        [[self unsavedMD5Hashes] addObject:md5];
    }
}

// Tries to find out which system the file belongs to
- (void)performImportStepDetermineSystem:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    if([[item importInfo] valueForKey:OEImportInfoROMObjectID]) return;
    
    __block NSError  *error    = nil;
    __block NSArray  *validSystems;
    NSURL    *url              = [[item importInfo] valueForKey:OEImportInfoArchivedFileURL] ?: [item URL];

    validSystems = [OEDBSystem systemsForFileWithURL:url inDatabase:[self database] error:&error];
    NSArray *validSystemIdentifiers = nil;
    if(validSystems == nil)
    {
        DLog(@"Could not get valid systems");
        DLog(@"%@", error);
    }
    else if([validSystems count] == 0)
    {
        // Try again with the zip itself
        if([[item importInfo] valueForKey:OEImportInfoArchivedFileURL])
        {
            [[item importInfo] removeObjectForKey:OEImportInfoArchivedFileURL];
            [[item importInfo] removeObjectForKey:OEImportInfoArchivedFileIndex];
            [self performImportStepDetermineSystem:item];
        }
        else
        {
            DLog(@"No valid system found for item at url %@", url);
            error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeNoSystem userInfo:nil];
        }
    }
    else if([validSystems count] == 1)
    {
        validSystemIdentifiers = @[[[validSystems lastObject] systemIdentifier]];
    }
    else // Found multiple valid systems after checking extension and system specific canHandleFile:
    {
        error = [NSError errorWithDomain:OEImportErrorDomainResolvable code:OEImportErrorCodeMultipleSystems userInfo:nil];
        
        NSMutableArray *systemIDs = [NSMutableArray arrayWithCapacity:[validSystems count]];
        [validSystems enumerateObjectsUsingBlock:^(OEDBSystem *system, NSUInteger idx, BOOL *stop){
            NSString *systemIdentifier = [system systemIdentifier];
            [systemIDs addObject:systemIdentifier];
        }];
        
        validSystemIdentifiers = systemIDs;
        
        NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"Aaargh, too many systems. You need to choose one!" forKey:NSLocalizedDescriptionKey];
        error = [NSError errorWithDomain:OEImportErrorDomainResolvable code:OEImportErrorCodeMultipleSystems userInfo:userInfo];
    }
    
    if(validSystemIdentifiers != nil)
        [[item importInfo] setValue:validSystemIdentifiers forKey:OEImportInfoSystemID];
    
    if(error != nil)
        [self stopImportForItem:item withError:error];
}

- (void)performImportStepOrganize:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    BOOL copyToLibrary   = [standardUserDefaults boolForKey:OECopyToLibraryKey];
    BOOL organizeLibrary = [standardUserDefaults boolForKey:OEOrganizeLibraryKey];
    
    NSError *error       = nil;
    NSURL   *url         = [item URL];
    
    // Unlock rom file so we can rename the copy directly
    BOOL romFileLocked = NO;
    if([[[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:&error] objectForKey:NSFileImmutable] boolValue])
    {
        romFileLocked = YES;
        [[NSFileManager defaultManager] setAttributes:@{ NSFileImmutable: @(FALSE) } ofItemAtPath:[url path] error:nil];
    }
    
    // Copy to library folder if it's not already there
    NSLog(@"\t%@\n\t%@\n\t->> %d", url, [[self database] romsFolderURL], [url isSubpathOfURL:[[self database] romsFolderURL]]);
    if(copyToLibrary && ![url isSubpathOfURL:[[self database] romsFolderURL]])
    {
        NSString *fullName  = [url lastPathComponent];
        NSString *extension = [fullName pathExtension];
        NSString *baseName  = [fullName stringByDeletingPathExtension];
        
        NSURL *unsortedFolder = [[self database] unsortedRomsFolderURL];
        NSURL *romURL         = [unsortedFolder URLByAppendingPathComponent:fullName];

        romURL = [romURL uniqueURLUsingBlock:^NSURL *(NSInteger triesCount) {
            NSString *newName = [NSString stringWithFormat:@"%@ %ld.%@", baseName, triesCount, extension];
            return [unsortedFolder URLByAppendingPathComponent:newName];
        }];
        
        if([[NSFileManager defaultManager] copyItemAtURL:url toURL:romURL error:&error])
            // Lock original file again
            if(romFileLocked)
                [[NSFileManager defaultManager] setAttributes:@{ NSFileImmutable: @(YES) } ofItemAtPath:[url path] error:&error];
        
        if(error != nil)
        {
            [self stopImportForItem:item withError:error];
            return;
        }
        
        url = [romURL copy];
        [item setURL:url];
    }
    
    // Move items in library folder to system sub-folder
    NSMutableDictionary *importInfo = [item importInfo];
    if(organizeLibrary && [url isSubpathOfURL:[[self database] romsFolderURL]])
    {
        // unlock file so we can move and rename it
        if([[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:&error] objectForKey:NSFileImmutable])
            [[NSFileManager defaultManager] setAttributes:@{ NSFileImmutable: @(FALSE) } ofItemAtPath:[url path] error:nil];
        
        __block OEDBSystem *system = nil;
        if([importInfo valueForKey:OEImportInfoROMObjectID] != nil)
        {
            DLog(@"using rom object");
            NSURL *objectID = [importInfo valueForKey:OEImportInfoROMObjectID];
            __block OEDBRom *rom = nil;

            [OEDBRom romWithURIURL:objectID inDatabase:[self database]];
            system = [[rom game] system];
        }
        else
        {
            NSAssert([[importInfo valueForKey:OEImportInfoSystemID] count] == 1, @"System should have been detected at an earlier import stage");
            NSString *systemIdentifier = [[importInfo valueForKey:OEImportInfoSystemID] lastObject];
            system = [OEDBSystem systemForPluginIdentifier:systemIdentifier inDatabase:[self database]];
        }
        
        NSString *fullName  = [url lastPathComponent];
        NSString *extension = [fullName pathExtension];
        NSString *baseName  = [fullName stringByDeletingPathExtension];
        
        NSURL *systemFolder = [[self database] romsFolderURLForSystem:system];
        NSURL *romURL       = [systemFolder URLByAppendingPathComponent:fullName];
        if([romURL isEqualTo:url])
        {
            [item setURL:romURL];
            return;
        }
        
        romURL = [romURL uniqueURLUsingBlock:
                  ^ NSURL *(NSInteger triesCount)
                  {
                      NSString *newName = [NSString stringWithFormat:@"%@ %ld.%@", baseName, triesCount, extension];
                      return [systemFolder URLByAppendingPathComponent:newName];
                  }];
        
        NSError *error = nil;
        if(![[NSFileManager defaultManager] moveItemAtURL:url toURL:romURL error:&error])
            [self stopImportForItem:item withError:error];
        else
            [item setURL:romURL];
    }
}

- (void)performImportStepOrganizeAdditionalFiles:(OEImportItem *)item
{
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    BOOL copyToLibrary   = [standardUserDefaults boolForKey:OECopyToLibraryKey];
    BOOL organizeLibrary = [standardUserDefaults boolForKey:OEOrganizeLibraryKey];
    if((copyToLibrary || organizeLibrary) && [[[[item URL] pathExtension] lastPathComponent] isEqualToString:@"cue"])
    {
        NSString *referencedFilesDirectory = [[[item sourceURL] path] stringByDeletingLastPathComponent];
        OECUESheet *cue = [[OECUESheet alloc] initWithPath:[[item URL] path] andReferencedFilesDirectory:referencedFilesDirectory];
        if(cue == nil)
        {
            // TODO: Create user info
            NSError *error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeInvalidFile userInfo:nil];
            [self stopImportForItem:item withError:error];
            return;
        }
        
        if(![cue allFilesAvailable])
        {
            // TODO: Create user info
            NSError *error = [NSError errorWithDomain:OEImportErrorDomainFatal code:OEImportErrorCodeAdditionalFiles userInfo:nil];
            [self stopImportForItem:item withError:error];
            return;
        }
        
        NSURL *sourceURL = [item sourceURL], *url = [item URL];
        NSString *targetDirectory = [[url path] stringByDeletingLastPathComponent];
        if(copyToLibrary && ![sourceURL isSubpathOfURL:[[self database] romsFolderURL]])
        {
            DLog(@"copy to '%@'", targetDirectory);
            NSError *error = nil;
            if(![cue copyReferencedFilesToPath:targetDirectory withError:&error])
            {
                DLog(@"%@", error);
                [self stopImportForItem:item withError:error];
                return;
            }
        }
        else if(organizeLibrary && [sourceURL isSubpathOfURL:[[self database] romsFolderURL]])
        {
            DLog(@"move to '%@'", targetDirectory);
            NSError *error = nil;
            if(![cue moveReferencedFilesToPath:targetDirectory withError:&error])
            {
                DLog(@"%@", error);
                [self stopImportForItem:item withError:error];
                return;
            }
        }
    }
}

- (void)performImportStepCreateCoreDataObjects:(OEImportItem*)item
{
    __block OEDBRom *rom = nil;
    __block NSError *error = nil;

    NSMutableDictionary *importInfo = [item importInfo];
    if([importInfo valueForKey:OEImportInfoROMObjectID] != nil)
    {
        rom = [OEDBRom romWithURIURL:[importInfo valueForKey:OEImportInfoROMObjectID] inDatabase:[self database]];
        [rom setURL:[item URL]];
        if([importInfo objectForKey:OEImportInfoArchivedFileIndex])
            [rom setArchiveFileIndex:[importInfo objectForKey:OEImportInfoArchivedFileIndex]];

        [self stopImportForItem:item withError:nil];
        return;
    }

    NSString *md5 = [importInfo valueForKey:OEImportInfoMD5];
    NSString *crc = [importInfo valueForKey:OEImportInfoCRC];
    rom = [OEDBRom createRomWithURL:[item URL] md5:md5 crc:crc inDatabase:[self database] error:&error];
    if([importInfo objectForKey:OEImportInfoArchivedFileIndex])
        [rom setArchiveFileIndex:[importInfo objectForKey:OEImportInfoArchivedFileIndex]];

    if(rom == nil)
    {
        [self stopImportForItem:item withError:error];
        return;
    }

    __block OEDBGame *game = nil;
    if(rom == nil || [rom game] != nil) return;
    if(game == nil)
    {
        NSAssert([[importInfo valueForKey:OEImportInfoSystemID] count] == 1, @"System should have been detected at an earlier import stage");

        NSString *systemIdentifier = [[importInfo valueForKey:OEImportInfoSystemID] lastObject];
        __block OEDBSystem *system = nil;
        system = [OEDBSystem systemForPluginIdentifier:systemIdentifier inDatabase:[self database]];

        if(system == nil)
        {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"No system! Someone must have deleted or disabled it!" forKey:NSLocalizedDescriptionKey];
            error = [NSError errorWithDomain:OEImportErrorDomainFatal code:51 userInfo:userInfo];
            [self stopImportForItem:item withError:error];
        }
        else
        {
            NSURL *url = [importInfo objectForKey:OEImportInfoArchivedFileURL] ?: [rom URL];
            NSString *gameTitleWithSuffix = [url lastPathComponent];
            NSString *gameTitleWithoutSuffix = [gameTitleWithSuffix stringByDeletingPathExtension];
            game = [OEDBGame createGameWithName:gameTitleWithoutSuffix andSystem:system inDatabase:[self database]];
        }
    }

    if(game != nil)
    {
        [rom setGame:game];
        [[self database] save:nil];
        NSURL *objectID = [[rom objectID] URIRepresentation];
        [importInfo setObject:objectID forKey:OEImportInfoROMObjectID];
        [self stopImportForItem:item withError:nil];
    } else
        [[self database] save:nil];
}

- (void)scheduleItemForNextStep:(OEImportItem *)item
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    item.importStep++;
    if([self status] == OEImporterStatusRunning)
    {
        dispatch_async(dispatchQueue, ^{
            importBlock(self, item);
        });
    }
}

- (void)stopImportForItem:(OEImportItem *)item withError:(NSError *)error
{
    IMPORTDLog(@"URL: %@", [item sourceURL]);
    if([[error domain] isEqualTo:OEImportErrorDomainResolvable])
        [item setImportState:OEImportItemStatusResolvableError];
    else if(error == nil || [[error domain] isEqualTo:OEImportErrorDomainSuccess])
        [item setImportState:OEImportItemStatusFinished];
    else
        [item setImportState:OEImportItemStatusFatalError];
    
    [item setError:error];

    if(([item importState] == OEImportItemStatusFinished || [item importState] == OEImportItemStatusFatalError || [item importState] == OEImportItemStatusCancelled))
    {
        if([item completionHandler] != nil)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [item completionHandler]();
            });
        }
        
        if([item error] && [error domain] != OEImportErrorDomainSuccess) DLog(@"%@", [item error]);
        self.numberOfProcessedItems++;
        
        [self cleanupImportForItem:item];
    }
    
    [self processNextItem];
    
    [self OE_performSelectorOnDelegate:@selector(romImporter:stoppedProcessingItem:) withObject:item];
}

- (void)cleanupImportForItem:(OEImportItem *)item
{
    NSError *error = [item error];

    if(error && [[error domain] isEqualTo:OEImportErrorDomainResolvable])
        return;

    if([item importState] == OEImportItemStatusFinished)
    {
        OEDBRom *rom = nil;
        NSURL *romID = [[item importInfo] objectForKey:OEImportInfoROMObjectID];
        if(romID)
            rom = [[self database] objectWithURI:romID];

        if(rom && [[item importInfo] objectForKey:OEImportInfoCollectionID])
        {
            id collection = [[rom libraryDatabase] objectWithURI:[[item importInfo] objectForKey:OEImportInfoCollectionID]];
            if([collection isKindOfClass:[OEDBCollection class]])
            {
                [[collection mutableGames] addObject:[rom game]];
            }
        }
        
        [[self database] save:nil];

        if (!([error code]==OEImportErrorCodeAlreadyInDatabase && [[error domain] isEqualTo:OEImportErrorDomainSuccess]) && rom && [[NSUserDefaults standardUserDefaults] boolForKey:OEAutomaticallyGetInfoKey]) {
            [[rom game] requestInfoSync];
        }
    }
    
    
    NSString *md5 = [[item importInfo] valueForKey:OEImportInfoMD5];
    NSString *crc = [[item importInfo] valueForKey:OEImportInfoCRC];
    if([[self unsavedMD5Hashes] containsObject:md5])
        [[self unsavedMD5Hashes] removeObject:md5];
    if([[self unsavedCRCHashes] containsObject:crc])
        [[self unsavedCRCHashes] removeObject:crc];
    
    [[self queue] removeObjectIdenticalTo:item];
}

#pragma mark - Importing Items with completion handler
- (BOOL)importItemAtPath:(NSString *)path withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    return [self importItemAtPath:path intoCollectionWithID:nil withCompletionHandler:handler];
}

- (BOOL)importItemsAtPaths:(NSArray *)paths withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    return [self importItemsAtPaths:paths intoCollectionWithID:nil withCompletionHandler:handler];
}

- (BOOL)importItemAtURL:(NSURL *)url withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    return [self importItemAtURL:url intoCollectionWithID:nil withCompletionHandler:handler];
}

- (BOOL)importItemsAtURLs:(NSArray *)urls withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    return [self importItemsAtURLs:urls intoCollectionWithID:nil withCompletionHandler:handler];
}

#pragma mark - Importing Items without completion handler
- (BOOL)importItemAtPath:(NSString *)path
{
    return [self importItemAtPath:path withCompletionHandler:nil];
}

- (BOOL)importItemsAtPaths:(NSArray *)paths
{
    return [self importItemsAtPaths:paths withCompletionHandler:nil];
}

- (BOOL)importItemAtURL:(NSURL *)url
{
    return [self importItemAtURL:url withCompletionHandler:nil];
}

- (BOOL)importItemsAtURLs:(NSArray *)urls
{
    return [self importItemsAtURLs:urls withCompletionHandler:nil];
}

#pragma mark - Importing items into collections
- (BOOL)importItemAtPath:(NSString *)path intoCollectionWithID:(NSURL*)collectionID
{
    return [self importItemAtPath:path intoCollectionWithID:collectionID withCompletionHandler:nil];
}
- (BOOL)importItemsAtPaths:(NSArray *)paths intoCollectionWithID:(NSURL*)collectionID
{
    return [self importItemsAtPaths:paths intoCollectionWithID:collectionID withCompletionHandler:nil];
}
- (BOOL)importItemAtURL:(NSURL *)url intoCollectionWithID:(NSURL*)collectionID
{
    return [self importItemAtURL:url intoCollectionWithID:collectionID withCompletionHandler:nil];
}
- (BOOL)importItemsAtURLs:(NSArray *)urls intoCollectionWithID:(NSURL*)collectionID
{
    return [self importItemsAtURLs:urls intoCollectionWithID:collectionID withCompletionHandler:nil];
}
#pragma mark - Importing items into collections with completion handlers
- (BOOL)importItemAtPath:(NSString *)path intoCollectionWithID:(NSURL*)collectionID withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    NSURL *url = [NSURL fileURLWithPath:path];
    return [self importItemAtURL:url intoCollectionWithID:collectionID withCompletionHandler:handler];
}
- (BOOL)importItemsAtPaths:(NSArray *)paths intoCollectionWithID:(NSURL*)collectionID  withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    __block BOOL success = NO;
    [paths enumerateObjectsUsingBlock:
     ^(id obj, NSUInteger idx, BOOL *stop)
     {
         success = [self importItemAtPath:obj intoCollectionWithID:collectionID withCompletionHandler:handler] || success;
     }];
    return success;
}

- (BOOL)importItemAtURL:(NSURL *)url intoCollectionWithID:(NSURL*)collectionID  withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    id item = [[self queue] firstObjectMatchingBlock:
               ^ BOOL (id item)
               {
                   return [[item URL] isEqualTo:url];
               }];
    
    if(item == nil)
    {
        OEImportItem *item = [OEImportItem itemWithURL:url andCompletionHandler:handler];
        if(item)
        {
            if(collectionID) [[item importInfo] setObject:collectionID forKey:OEImportInfoCollectionID];
            [[self queue] addObject:item];
            self.totalNumberOfItems++;
            [self start];
            return YES;
        }
    }
    return NO;
}

- (BOOL)importItemsAtURLs:(NSArray *)urls intoCollectionWithID:(NSURL*)collectionID  withCompletionHandler:(OEImportItemCompletionBlock)handler
{
    __block BOOL success = NO;
    [urls enumerateObjectsUsingBlock:
     ^(id obj, NSUInteger idx, BOOL *stop)
     {
         success = [self importItemAtURL:obj intoCollectionWithID:collectionID withCompletionHandler:handler] || success;
     }];
    return success;
}

#pragma mark - Spotlight importing -
- (void)discoverRoms:(NSArray *)volumes
{
    DLog();
    // TODO: limit searching or results to the volume URLs only.
    
    NSMutableArray *supportedFileExtensions = [[OESystemPlugin supportedTypeExtensions] mutableCopy];
    
    // We skip common types by default.
    NSArray *commonTypes = @[@"zip", @"elf"];
    
    [supportedFileExtensions removeObjectsInArray:commonTypes];
    
    //NSLog(@"Supported search Extensions are: %@", supportedFileExtensions);
    
    NSString *searchString = @"";
    for(NSString *extension in supportedFileExtensions)
    {
        searchString = [searchString stringByAppendingFormat:@"(kMDItemDisplayName == *.%@)", extension];
        searchString = [searchString stringByAppendingString:@" || "];
    }
    
    searchString = [searchString substringWithRange:NSMakeRange(0, [searchString length] - 4)];
    
    DLog(@"SearchString: %@", searchString);
    
    MDQueryRef searchQuery = MDQueryCreate(kCFAllocatorDefault, (__bridge CFStringRef)searchString, NULL, NULL);
    
    if(searchQuery != NULL)
    {
        // Limit Scope to selected volumes / URLs only
        MDQuerySetSearchScope(searchQuery, (__bridge CFArrayRef) volumes, 0);
        
        [[self spotlightSearchResults] removeAllObjects];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(finalizeSearchResults:)
                                                     name:(NSString *)kMDQueryDidFinishNotification
                                                   object:(__bridge id)searchQuery];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSearchResults:)
                                                     name:(NSString *)kMDQueryProgressNotification
                                                   object:(__bridge id)searchQuery];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateSearchResults:)
                                                     name:(NSString *)kMDQueryDidUpdateNotification
                                                   object:(__bridge id)searchQuery];
        
        if(MDQueryExecute(searchQuery, kMDQueryWantsUpdates))
            DLog(@"Searching for importable roms");
        else
        {
            CFRelease(searchQuery);
            searchQuery = nil;
            // leave this log message in...
            DLog(@"MDQuery failed to start.");
        }
        
    }
    else
        DLog(@"Invalid Search Query");
}

- (void)updateSearchResults:(NSNotification *)notification
{
    DLog();
    
    MDQueryRef searchQuery = (__bridge MDQueryRef)[notification object];
    
    
    // If you're going to have the same array for every iteration,
    // don't allocate it inside the loop !
    NSArray *excludedPaths = @[
                               @"System",
                               @"Library",
                               @"Developer",
                               @"Volumes",
                               @"Applications",
                               @"cores",
                               @"dev",
                               @"etc",
                               @"home",
                               @"net",
                               @"sbin",
                               @"private",
                               @"tmp",
                               @"usr",
                               @"var",
                               @"ReadMe", // markdown
                               @"readme", // markdown
                               @"README", // markdown
                               @"Readme", // markdown
                               ];
    
    // assume the latest result is the last index?
    for(CFIndex index = 0, limit = MDQueryGetResultCount(searchQuery); index < limit; index++)
    {
        MDItemRef resultItem = (MDItemRef)MDQueryGetResultAtIndex(searchQuery, index);
        NSString *resultPath = (__bridge_transfer NSString *)MDItemCopyAttribute(resultItem, kMDItemPath);
        
        // Nothing in common
        if([[resultPath pathComponents] firstObjectCommonWithArray:excludedPaths] == nil)
        {
            NSDictionary *resultDict = [[NSDictionary alloc] initWithObjectsAndKeys:
                                        resultPath, @"Path",
                                        [[resultPath lastPathComponent] stringByDeletingPathExtension], @"Name",
                                        nil];
            
            if(![[self spotlightSearchResults] containsObject:resultDict])
            {
                [[self spotlightSearchResults] addObject:resultDict];
                
                //                NSLog(@"Result Path: %@", resultPath);
            }
        }
    }
}

- (void)finalizeSearchResults:(NSNotification *)notification
{
    MDQueryRef searchQuery = (__bridge_retained MDQueryRef)[notification object];
    DLog(@"Finished searching, found: %lu items", MDQueryGetResultCount(searchQuery));
    
    if(MDQueryGetResultCount(searchQuery))
    {
        [self importSpotlightResultsInBackground];
        
        MDQueryStop(searchQuery);
    }
    
    CFRelease(searchQuery);
}

- (void)importSpotlightResultsInBackground;
{
    DLog();
    [self importItemsAtPaths:[[self spotlightSearchResults] valueForKey:@"Path"]];
}

#pragma mark - Controlling Import -
- (void)start
{
    IMPORTDLog();
    if([self status] == OEImporterStatusPaused || [self status] == OEImporterStatusStopped)
    {
        [self setStatus:OEImporterStatusRunning];
        [self processNextItem];
        [self OE_performSelectorOnDelegate:@selector(romImporterDidStart:) withObject:self];
    }
}

- (void)pause
{
    IMPORTDLog();
    if([self status] == OEImporterStatusRunning)
    {
        [self setStatus:OEImporterStatusPausing];
        dispatch_async(dispatchQueue, ^{
            [self setStatus:OEImporterStatusPaused];
            [self OE_performSelectorOnDelegate:@selector(romImporterDidPause:) withObject:self];
        });
    }
}

- (void)togglePause
{
    IMPORTDLog();
    if([self status] == OEImporterStatusPaused)
        [self start];
    else if([self status] == OEImporterStatusRunning)
        [self pause];
}

- (void)cancel
{
    IMPORTDLog();
    [self setStatus:OEImporterStatusStopped];
    
    [self setQueue:[NSMutableArray array]];
    [self setNumberOfProcessedItems:0];
    [self setTotalNumberOfItems:0];
    
    [self OE_performSelectorOnDelegate:@selector(romImporterDidCancel:) withObject:self];
}

- (void)removeFinished
{
    IMPORTDLog();
    DLog(@"removeFinished");
    dispatch_async(dispatchQueue, ^{
        [[self queue] filterUsingPredicate:
         [NSPredicate predicateWithBlock:
          ^ BOOL (OEImportItem *evaluatedObject, NSDictionary *bindings)
          {
              return [evaluatedObject importState] != OEImportItemStatusFinished && [evaluatedObject importState] != OEImportItemStatusFatalError && [evaluatedObject importState] != OEImportItemStatusCancelled;
          }]];
    });
}

#pragma mark - Private Methods -
- (void)setTotalNumberOfItems:(NSInteger)totalNumberOfItems
{
    _totalNumberOfItems = totalNumberOfItems;
    [self OE_performSelectorOnDelegate:@selector(romImporterChangedItemCount:) withObject:nil];
}

- (void)OE_performSelectorOnDelegate:(SEL)selector withObject:(id)object
{
    if(![[self delegate] respondsToSelector:selector] ||
       ![[self delegate] respondsToSelector:@selector(performSelectorOnMainThread:withObject:waitUntilDone:)])
        return;
    
    NSAssert(protocol_getMethodDescription(@protocol(OEROMImporterDelegate), selector, NO, YES).name == selector,
             @"Unknown delegate method %@", NSStringFromSelector(selector));
    
    [(NSObject *)[self delegate] performSelectorOnMainThread:selector withObject:object waitUntilDone:NO];
}

@end
