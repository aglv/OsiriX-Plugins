//
//  DiscPublishingPatientDisc.mm
//  DiscPublishing
//
//  Created by Alessandro Volz on 3/2/10.
//  Copyright 2010 OsiriX Team. All rights reserved.
//

#import "DiscPublishingPatientDisc.h"
#import "DiscPublishingOptions.h"
#import "NSUserDefaultsController+DiscPublishing.h"
#import "DiscPublisher.h"
#import "DiscPublisher+Constants.h"
#import <OsiriXAPI/ThreadsManager.h>
#import <OsiriXAPI/NSFileManager+N2.h>
#import <OsiriXAPI/DicomCompressor.h>
#import <OsiriXAPI/QTExportHTMLSummary.h>
#import <OsiriXAPI/NSUserDefaultsController+N2.h>
#import <OsiriXAPI/DicomSeries.h>
#import <OsiriXAPI/DicomStudy.h>
#import <OsiriXAPI/DicomDatabase.h>
#import <OsiriXAPI/DicomDir.h>
#import <OsiriXAPI/AppController.h>
#import <OsiriX/DCMObject.h>
#import <OsiriXAPI/DicomImage.h>
#import <OsiriXAPI/NSString+N2.h>
//#import <OsiriXAPI/DicomDatabase.h>
#import <OsiriXAPI/BrowserController.h>
#import <OsiriXAPI/NSFileManager+N2.h>
#import <JobManager/PTJobManager.h>
#import <QTKit/QTKit.h>
#import "DiscPublishing.h"
#import "DiscPublishingTasksManager.h"
#import <OsiriXAPI/NSThread+N2.h>
#import <OsiriXAPI/N2Debug.h>
#import <OsiriX/DCMObject.h>
#import <OsiriX/DCMAttribute.h>
#import <OsiriX/DCMAttributeTag.h>
#import <OsiriXAPI/DicomStudy+Report.h>


static NSString* PreventNullString(NSString* s) {
	return s? s : @"";
}

@interface DPPhantomDicomDatabase : DicomDatabase
@end
@implementation DPPhantomDicomDatabase : DicomDatabase

-(void)dealloc {
    if (self.isMainDatabase) {
        NSString* path = self.baseDirPath;
        if ([path.lastPathComponent isEqualToString:OsirixDataDirName])
            path = [path stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    }
    [super dealloc];
}

@end

@implementation DiscPublishingPatientDisc

@synthesize window = _window;

-(id)initWithImagesID:(NSArray*)images options:(DiscPublishingOptions*)options {
	self = [super init];
    
	_options = [options retain];
    
//    if( [[[images objectAtIndex:0] managedObjectContext] isKindOfClass: [N2ManagedObjectContext class]] && [N2ManagedObjectContext instancesRespondToSelector: @selector( initWithDatabase:)])
//    {
//        N2ManagedDatabase *database = [[[images objectAtIndex:0] managedObjectContext] database];
//        _icontext = [[N2ManagedObjectContext alloc] initWithDatabase: database];
//    }
//    else
//    {
//        _icontext = [[NSManagedObjectContext alloc] init];
//    }
    
//    _icontext.undoManager = nil;
//    _icontext.persistentStoreCoordinator = [[[images objectAtIndex:0] managedObjectContext] persistentStoreCoordinator];
    
	_imagesID = [[NSMutableArray alloc] init];
    [_imagesID addObjectsFromArray: images];

	_tmpPath = [[NSFileManager.defaultManager tmpFilePathInTmp] retain];
	[[NSFileManager defaultManager] confirmDirectoryAtPath:_tmpPath];
	
	return self;
}

-(void)dealloc {
	[[NSFileManager defaultManager] removeItemAtPath:_tmpPath error:NULL];
	[_tmpPath release];
	[_options release];
	[_imagesID release];
    self.window = nil;
	[super dealloc];
}

+(NSArray*)selectSeriesOfSizes:(NSDictionary*)seriesSizes forDiscWithCapacity:(CGFloat)mediaCapacity {
	// if all fits in a disk, return all
	NSUInteger sum = 0;
	for (NSValue* serieValue in seriesSizes)
		sum += [[seriesSizes objectForKey:serieValue] unsignedIntValue];
	if (sum <= mediaCapacity)
		return [seriesSizes allKeys];
	
	// else combine the blocks
	NSArray* series = [seriesSizes allKeys];
	NSMutableArray* selectedSeries = [NSMutableArray array];
	
	sum = 0;
	// TODO: use a better algorithm (bin packing, ideally)
	for (NSValue* serieValue in series) {
		NSUInteger size = [[seriesSizes objectForKey:serieValue] unsignedIntValue];
		if (sum+size <= mediaCapacity)  {
			sum += size;
			[selectedSeries addObject:serieValue];
		}
	}
	
	return selectedSeries;
}

+(NSString*)dirPathForSeries:(DicomSeries*)series inBaseDir:(NSString*)basePath {
	return [basePath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@", [series valueForKeyPath:@"seriesDICOMUID"]]];
}

+(NSString*)dicomDirName {
	NSDictionary* info = [[NSBundle bundleForClass:[self class]] infoDictionary];
	
	NSString* dicomDirName = [info objectForKey:@"DicomDirectoryName"];
	if ([dicomDirName isKindOfClass:[NSString class]] && dicomDirName.length)
		return dicomDirName;
	
	return @"DICOM";
}

+(void)copyOsirixLiteToPath:(NSString*)path {
	NSTask* unzipTask = [[NSTask alloc] init];
	[unzipTask setLaunchPath: @"/usr/bin/unzip"];
	[unzipTask setCurrentDirectoryPath:path];
	[unzipTask setArguments:[NSArray arrayWithObjects: @"-o", [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"OsiriX Launcher.zip"], NULL]];
	[unzipTask launch];
    //	[theTask waitUntilExit];	<- The problem with this: it calls the current running loop.... problems with GUI !
	while( [unzipTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
    [unzipTask interrupt];
	[unzipTask release];
}

+(void)copyContentsOfDirectory:(NSString*)auxDir toPath:(NSString*)path {
	for (NSString* subpath in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:auxDir error:NULL])
		[[NSFileManager defaultManager] copyItemAtPath:[auxDir stringByAppendingPathComponent:subpath] toPath:[path stringByAppendingPathComponent:subpath] error:NULL];
}

+(void)copyWeasisToPath:(NSString*)path {
	if ([[AppController sharedAppController] respondsToSelector:@selector(weasisBasePath)])
		[self copyContentsOfDirectory:[[AppController sharedAppController] weasisBasePath] toPath:path];
	else NSLog(@"Warning: attempt to copy weasis on OsiriX prior to version 3.9");
}

+(NSString*)discNameForSeries:(NSArray*)series {
	NSMutableArray* names = [NSMutableArray array];
	for (DicomSeries* serie in series)
		if (![names containsObject:serie.study.name])
			[names addObject:serie.study.name];
	
	if (names.count == 1)
		return [names objectAtIndex:0];
	
	return [NSString stringWithFormat:@"Archive %@", [[NSDate date] descriptionWithCalendarFormat:@"%Y%m%d-%H%M%S" timeZone:NULL locale:NULL]];
}

+(void)generateDICOMDIRAtDirectory:(NSString*)root withDICOMFilesInDirectory:(NSString*)dicomPath {
    // newer versions of osirix (since revision 9105) have a DicomDir class with a createDicomDirAtDir: class method
    if ([NSClassFromString(@"DicomDir") respondsToSelector:@selector(createDicomDirAtDir:)]) 
    {
        [DicomDir createDicomDirAtDir:root];
    }
    else // before that, we had to use the dcmmkdir binary bundled with OsiriX
    {
        NSTask* dcmmkdirTask = [[NSTask alloc] init];
        [dcmmkdirTask setEnvironment:[NSDictionary dictionaryWithObject:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"dicom.dic"] forKey:@"DCMDICTPATH"]];
        [dcmmkdirTask setLaunchPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"dcmmkdir"]];
        [dcmmkdirTask setCurrentDirectoryPath:root];
        [dcmmkdirTask setArguments:[NSArray arrayWithObjects:@"+r", @"-Pfl", @"-W", @"-Nxc", @"+I", @"+m", @"+id", dicomPath, NULL]];		
        [dcmmkdirTask launch];
        while( [dcmmkdirTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
        [dcmmkdirTask interrupt];
        [dcmmkdirTask release];
    }
}

-(void)main {
    @autoreleasepool {
        @try {
            self.supportsCancel = YES;
            
            NSDate* startingDate = [NSDate date];
            
            NSDateFormatter* dateFormatter = [[[NSDateFormatter alloc] init] autorelease];
            [dateFormatter setDateFormat:[[NSUserDefaultsController sharedUserDefaultsController] stringForKey:@"DBDateOfBirthFormat2"]];

            
            NSManagedObjectContext *icontext = [[DicomDatabase defaultDatabase] independentContext];
            NSMutableArray *images = [NSMutableArray array];
            
            for( NSManagedObjectID *imageID in _imagesID)
            {
                DicomImage *i = [icontext objectWithID: imageID];
                
                if( i)
                    [images addObject: [icontext objectWithID: imageID]];
            }
            
            DicomImage *image = [images objectAtIndex:0];
            self.name = [NSString stringWithFormat:@"Preparing disc data for %@", image.series.study.name];
            
            self.status = @"Detecting image series and studies...";
            NSMutableArray* series = [[[NSMutableArray alloc] init] autorelease];
            NSMutableArray* studies = [[[NSMutableArray alloc] init] autorelease];
            for (DicomImage* image in images)
            {
                if( image.series && ![series containsObject:image.series])
                    [series addObject:image.series];
                if( image.series.study && ![studies containsObject:image.series.study])
                    [studies addObject:image.series.study];
            }
            
            DicomDatabase* database = [DPPhantomDicomDatabase databaseAtPath:[NSFileManager.defaultManager tmpFilePathInTmp]];

        /*	NSManagedObjectModel* managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"/OsiriXDB_DataModel.mom"]]];
            NSPersistentStoreCoordinator* persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];
            [persistentStoreCoordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:NULL URL:NULL options:NULL error:NULL];
            NSManagedObjectContext* managedObjectContext = [[NSManagedObjectContext alloc] init];
            [managedObjectContext setPersistentStoreCoordinator:persistentStoreCoordinator];
            managedObjectContext.undoManager.levelsOfUndo = 1;	
            [managedObjectContext.undoManager disableUndoRegistration];*/
            
            
            
            
            NSMutableDictionary* matchedDataPerStudy = [NSMutableDictionary dictionary];
            NSString* matchesDirPath = [_tmpPath stringByAppendingPathComponent:@"Matches"];
            if (_options.fsMatchFlag) {
                self.status = NSLocalizedString(@"Mounting match share...", nil);
                
                [NSFileManager.defaultManager confirmDirectoryAtPath:matchesDirPath];
                
                NSString* shareMountPath = [NSFileManager.defaultManager tmpFilePathInTmp];
                [NSFileManager.defaultManager confirmDirectoryAtPath:shareMountPath];
                
                BOOL ok = YES;
                
                // mount!
                @try {
                    NSURL* url = [NSURL URLWithString:_options.fsMatchShareUrl];
                    if (!url)
                        [NSException raise:NSGenericException format:@"Can't match data: invalid URL: %@", _options.fsMatchShareUrl];
                    
                    FSVolumeRefNum volumeRefNum = -1;
                    OSErr err = FSMountServerVolumeSync((CFURLRef)url, (CFURLRef)[NSURL URLWithString:shareMountPath], (CFStringRef)url.user, (CFStringRef)url.password, &volumeRefNum, kFSMountServerMarkDoNotDisplay|kFSMountServerMountOnMountDir|kFSMountServerSuppressConnectionUI);
                    if (err != noErr)
                        [NSException raise:NSGenericException format:@"Can't match data: FSMountServerVolumeSync error %d, URL was %@", (int)err, url];
                    
                    NSString* inShareMountPath = shareMountPath;
                    NSArray* pathComponents = [url pathComponents];
                    pathComponents = [pathComponents subarrayWithRange:NSMakeRange(2, pathComponents.count-2)];
                    if (pathComponents.count)
                        inShareMountPath = [shareMountPath stringByAppendingPathComponent:[pathComponents componentsJoinedByString:@"/"]];
                    
                    // mounted, now look for the data
                    self.status = NSLocalizedString(@"Matching share data...", nil);
                    
                    for (DicomStudy* study in studies) {
                        NSString* studyMatchesDirPath = [NSFileManager.defaultManager tmpFilePathInDir:matchesDirPath];

                        DicomImage* image = [[study images] anyObject];
                        DCMObject* obj = [[[DCMObject alloc] initWithContentsOfFile:[image completePath] decodingPixelData:NO] autorelease];
                        
                        NSMutableArray* tokens = [[[_options fsMatchTokens] mutableCopy] autorelease];
                        for (NSInteger i = 0; i < (int)tokens.count; ++i) {
                            NSString* token = [tokens objectAtIndex:i];
                            DCMAttributeTag* tag = [DCMAttributeTag tagWithName:token];
                            if (!tag)
                                tag = [DCMAttributeTag tagWithTagString:token];
                            if (!tag)
                                [NSException raise:NSGenericException format:@"Invalid token %@", token];
                            
                            DCMAttribute* attr = [obj attributeForTag:tag];
                            if (!attr)
                                [NSException raise:NSGenericException format:@"No value for token %@", token];
                            
                            id value = [attr value];
                            if ([value respondsToSelector:@selector(stringValue)])
                                value = [value stringValue];
                            if (![value isKindOfClass:[NSString class]])
                                [NSException raise:NSGenericException format:@"Invalid token value class %@", [value className]];
                            
                            [tokens replaceObjectAtIndex:i withObject:value];
                        }
                        
                        NSString* match = [tokens componentsJoinedByString:@""];

                        BOOL studyOk = NO;
                        while (!studyOk && !self.isCancelled) {
                            NSArray* contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:inShareMountPath error:NULL];
                            
                            if (!contents)
                                [NSException raise:NSGenericException format:@"Share mount problem, maybe the share is already mounted?"];
                            
                            @try {
                                for (NSString* content in contents)
                                    if ([content hasPrefix:match]) { // a match! a match!
                                        studyOk = YES;
                                        // destination folder...
                                        [NSFileManager.defaultManager confirmDirectoryAtPath:studyMatchesDirPath];
                                        // copy
                                        [NSFileManager.defaultManager copyItemAtPath:[inShareMountPath stringByAppendingPathComponent:content] toPath:[studyMatchesDirPath stringByAppendingPathComponent:content] error:NULL];
                                        if (_options.fsMatchDelete)
                                            [NSFileManager.defaultManager removeItemAtPath:[inShareMountPath stringByAppendingPathComponent:content] error:NULL];
                                    }
                                
                                // if found at least a document/folder, done with this study
                            }
                            @catch (NSException* e) {
                                studyOk = NO;
                            }
                            
                            if (!studyOk && -[startingDate timeIntervalSinceNow] > _options.fsMatchDelay) { // not ok, delay passed...
                                if (!_options.fsMatchCondition)
                                    studyOk = YES; // optiopnal, skip to the next study
                                else // otherwise, a file is NEEDED, and not found... and time is up. stop publishing....
                                    studyOk = ok = NO;
                                break;
                            }
                            
                            if (!studyOk && !self.isCancelled)
                                [NSThread sleepForTimeInterval:1];
                        }
                        
                        if (!ok)
                            break;
                        
                        if ([NSFileManager.defaultManager fileExistsAtPath:studyMatchesDirPath])
                            [matchedDataPerStudy setObject:studyMatchesDirPath forKey:[NSValue valueWithPointer:study]];

                        if (_options.fsMatchToDicom) // make DICOM files from PDFs
                            for (NSString* filename in [NSFileManager.defaultManager contentsOfDirectoryAtPath:studyMatchesDirPath error:NULL]) {
                                NSString* path = [studyMatchesDirPath stringByAppendingPathComponent:filename];
                                if ([[path pathExtension] caseInsensitiveCompare:@"pdf"] == NSOrderedSame) {
                                    // make dicom...
                                    NSString* dcmpath = [[DicomDatabase defaultDatabase] uniquePathForNewDataFileWithExtension:nil];
                                    [study transformPdfAtPath:path toDicomAtPath:dcmpath];
                                    // add it to the db
                                    NSArray* reportImageIDs = [[DicomDatabase defaultDatabase] addFilesAtPaths:[NSArray arrayWithObject:dcmpath] postNotifications:NO];
                                    
                                    NSMutableArray* reportImages = [NSMutableArray array];
                                    for( NSManagedObjectID *reportID in reportImageIDs)
                                    {
                                        DicomImage *i = [icontext objectWithID: reportID];
                                        
                                        if( i)
                                            [reportImages addObject: [icontext objectWithID: reportID]];
                                    }
                                    
                                    // add the report DicomImage objects and theis DicomSeries to the arrays --- no need to touch the studies
                                    [images addObjectsFromArray:reportImages];
                                    for (DicomImage* image in reportImages)
                                        if( image.series && ![series containsObject:image.series])
                                            [series addObject:image.series];
                                }
                            }
                        
                        if (self.isCancelled)
                            break;
                    }
                    
                    // done, unmount
                    
                    self.status = NSLocalizedString(@"Unmounting match share...", nil);
                    
                    [NSThread performBlockInBackground:^{ // unmounting is sometimes slow (probably because of spotlight), so we do it in a background thread
                        pid_t dissenter;
                        FSUnmountVolumeSync(volumeRefNum, 0, &dissenter);
                        [NSFileManager.defaultManager removeItemAtPath:shareMountPath error:NULL];
                    }];
                }
                @catch (NSException* e) {
                    ok = NO;
                    N2LogExceptionWithStackTrace(e);
                }
                
                if (!ok) { // match failure!
                    self.status = NSLocalizedString(@"Error: no match found, aborting...", nil);
                    NSLog(@"Error: no match found, publishment aborted");
                    NSDate* date = [NSDate date];
                    while (!self.isCancelled && -[date timeIntervalSinceNow] < 60)
                        [NSThread sleepForTimeInterval:0.05];
                    return;
                }
            }  

            NSMutableDictionary* seriesSizes = [[NSMutableDictionary alloc] initWithCapacity:series.count];
            NSMutableDictionary* seriesPaths = [[NSMutableDictionary alloc] initWithCapacity:series.count];
            NSUInteger processedImagesCount = 0;

            for (DicomSeries* serie in series)
            {
                @try
                {
                    self.status = [NSString stringWithFormat:@"Preparing data for series %@...", serie.name];

                    NSArray* images = serie.images.allObjects;
                    [self enterOperationWithRange:1.*processedImagesCount/images.count:1.*images.count/images.count];
                    
        //            images = [DiscPublishingPatientDisc prepareSeriesDataForImages:images inDirectory:_tmpPath options:_options context:managedObjectContext seriesPaths:seriesPaths];
                    images = [DiscPublishingPatientDisc prepareSeriesDataForImages:images inDirectory:_tmpPath options:_options database:database seriesPaths:seriesPaths];
                    
                    if (self.isCancelled)
                        return;
                    
                    if (images.count) {
                        serie = [(DicomImage*)[images objectAtIndex:0] series];
                        NSString* tmpPath = [DiscPublishingPatientDisc dirPathForSeries:serie inBaseDir:_tmpPath];
                            
                        NSUInteger size;
                        if ([_options zip]) {
                            NSString* tmpZipPath = [[[NSFileManager defaultManager] tmpFilePathInTmp] stringByAppendingPathExtension:@"zip"];
                            
                            NSTask* task = [[NSTask alloc] init];
                            [task setLaunchPath:@"/usr/bin/zip"];
                            [task setArguments:[NSArray arrayWithObjects: @"-rq", tmpZipPath, tmpPath, NULL]];
                            [task launch];
                            while( [task isRunning]) [NSThread sleepForTimeInterval: 0.01];
                            [task interrupt];
                            [task release];
                            
                            size = [[[NSFileManager defaultManager] attributesOfItemAtPath:tmpZipPath error:NULL] fileSize];
                            
                            [[NSFileManager defaultManager] removeItemAtPath:tmpZipPath error:NULL];			
                        } else size = [[NSFileManager defaultManager] sizeAtPath:tmpPath];
                        [seriesSizes setObject:[NSNumber numberWithUnsignedInteger:size] forKey:[NSValue valueWithPointer:serie]];

                        processedImagesCount += images.count;
                    }
                }
                @catch (NSException* e) {
                    N2LogExceptionWithStackTrace(e);
                }
                @finally {
                    [self exitOperation];
                }
                
                if (self.isCancelled)
                    return;
            }
            
            NSString* reportsTmpPath = [_tmpPath stringByAppendingPathComponent:@"Reports"];
            if (_options.includeReports)
            {
                [[NSFileManager defaultManager] confirmDirectoryAtPath:reportsTmpPath];
                
                for (DicomStudy* study in studies)
                {
                    if (study.reportURL)
                    {
                        if( [study.reportURL hasPrefix: @"http://"] || [study.reportURL hasPrefix: @"https://"])
                        {
                            NSStringEncoding se = NULL;
                            NSString *urlContent = [NSString stringWithContentsOfURL:[NSURL URLWithString:study.reportURL] usedEncoding:&se error:NULL];
                            [urlContent writeToFile: [reportsTmpPath stringByAppendingPathComponent:[study.reportURL lastPathComponent]] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        }
                        else
                            [[NSFileManager defaultManager] copyItemAtPath:study.reportURL toPath:[reportsTmpPath stringByAppendingPathComponent:[study.reportURL lastPathComponent]] error:NULL];
                    }
                }
            }
            
        //	DLog(@"paths: %@", seriesPaths);

            NSUInteger discNumber = 1;
            while (seriesSizes.count && !self.isCancelled) {
                NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
                @try {
                    self.status = [NSString stringWithFormat:@"Preparing data for disc %d...", (int) discNumber];

                    NSMutableArray* privateFiles = [NSMutableArray array];

                    NSString* discBaseDirPath = [[NSFileManager defaultManager] tmpFilePathInTmp];
                    [[NSFileManager defaultManager] confirmDirectoryAtPath:discBaseDirPath];
            //		NSString* discBaseDirPath = [discTmpDirPath stringByAppendingPathComponent:@"DATA"];
            //		[[NSFileManager defaultManager] confirmDirectoryAtPath:discBaseDirPath];
            //		NSString* discFinalDirPath = [discTmpDirPath stringByAppendingPathComponent:@"FINAL"];
            //		[[NSFileManager defaultManager] confirmDirectoryAtPath:discFinalDirPath];
                    
                    NSDictionary* mediaCapacitiesBytes = [[NSUserDefaultsController sharedUserDefaultsController] discPublishingMediaCapacities];
                //	NSLog(@"----- mcb %@", mediaCapacitiesBytes);
                    
                    if ([_options respondsToSelector:@selector(includeWeasis)] && _options.includeWeasis)
                        [DiscPublishingPatientDisc copyWeasisToPath:discBaseDirPath];
                    
                    if (_options.includeOsirixLite)
                        [DiscPublishingPatientDisc copyOsirixLiteToPath:discBaseDirPath];
                    if (_options.includeAuxiliaryDir)
                        [DiscPublishingPatientDisc copyContentsOfDirectory:_options.auxiliaryDirPath toPath:discBaseDirPath];
                    if (_options.includeReports) {
                        NSString* reportsDiscBaseDirPath = [discBaseDirPath stringByAppendingPathComponent:@"Reports"];
                        [privateFiles addObject:@"Reports"];
                        [[NSFileManager defaultManager] copyItemAtPath:reportsTmpPath toPath:reportsDiscBaseDirPath error:NULL];
                    }
                    if (_options.fsMatchFlag) {
                        for (NSString* matchDir in [NSFileManager.defaultManager contentsOfDirectoryAtPath:matchesDirPath error:NULL]) {
                            NSString* matchDirPath = [matchesDirPath stringByAppendingPathComponent:matchDir];
                            for (NSString* matchItem in [NSFileManager.defaultManager contentsOfDirectoryAtPath:matchDirPath error:NULL]) {
                                [NSFileManager.defaultManager copyItemAtPath:[matchDirPath stringByAppendingPathComponent:matchItem] toPath:[discBaseDirPath stringByAppendingPathComponent:matchItem] error:NULL];
                                [privateFiles addObject:matchItem];
                            }
                        }
                    }
                    
                    NSUInteger tempSizeAtDiscBaseDir = [[NSFileManager defaultManager] sizeAtPath:discBaseDirPath];
                    NSMutableDictionary* mediaCapacitiesBytesTemp = [NSMutableDictionary dictionaryWithCapacity:mediaCapacitiesBytes.count];
                    for (id key in mediaCapacitiesBytes)
                        [mediaCapacitiesBytesTemp setObject:[NSNumber numberWithFloat:[[mediaCapacitiesBytes objectForKey:key] floatValue]-tempSizeAtDiscBaseDir] forKey:key];
                    mediaCapacitiesBytes = mediaCapacitiesBytesTemp;
                //	NSLog(@"----- mcb %@", mediaCapacitiesBytes);
                    
                    // mediaCapacitiesBytes contains one or more disc capacities and seriesSizes contains the series still needing to be burnt
                    // what disc type between these in mediaCapacitiesBytes will we use?
                    NSUInteger totalSeriesSizes = 0;
                    for (id serie in seriesSizes)
                        totalSeriesSizes += [[seriesSizes objectForKey:serie] unsignedIntValue];
                    id pickedMediaKey = nil;
                    // try pick the smallest that fits the data
                    //NSLog(@"----- Picking media... totalSeriesSizes is %d", totalSeriesSizes);
                    for (id key in mediaCapacitiesBytes) {
                    //	NSLog(@"Will it be %@ sized %f ?", key, [[mediaCapacitiesBytes objectForKey:key] floatValue]);
                        if ([[mediaCapacitiesBytes objectForKey:key] floatValue] > totalSeriesSizes) { // fits
                    //		NSLog(@"\tIt may be...");
                            if (!pickedMediaKey || [[mediaCapacitiesBytes objectForKey:key] floatValue] < [[mediaCapacitiesBytes objectForKey:pickedMediaKey] floatValue]) { // forst OR is smaller than the one we picked earlier
                    //			NSLog(@"\tIt really may be...");
                                pickedMediaKey = key;
                            }
                        }
                    }
                    //NSLog(@"Picked media key %@", pickedMediaKey);
                    if (!pickedMediaKey) // data won't fit a single disc, pick the biggest of discs available
                        for (id key in mediaCapacitiesBytes)
                            if (!pickedMediaKey || [[mediaCapacitiesBytes objectForKey:key] floatValue] > [[mediaCapacitiesBytes objectForKey:pickedMediaKey] floatValue]) // forst OR is bigger than the one we picked earlier
                                pickedMediaKey = key;
                    
                    DLog(@"media type will be: %@", pickedMediaKey);
                    
                    if (!pickedMediaKey) {
                        [self cancel];
                        [NSException raise:NSGenericException format:@"%@", NSLocalizedString(@"Something is wrong with the robot.", nil)];
                    }
                    
                    NSArray* discSeriesValues = [DiscPublishingPatientDisc selectSeriesOfSizes:seriesSizes forDiscWithCapacity:[[mediaCapacitiesBytes objectForKey:pickedMediaKey] floatValue]];
                    [seriesSizes removeObjectsForKeys:discSeriesValues];
                    NSMutableArray* discSeries = [NSMutableArray arrayWithCapacity:discSeriesValues.count];
                    for (NSValue* serieValue in discSeriesValues)
                        [discSeries addObject:(id)serieValue.pointerValue];
                    
                    NSString* discName = [DiscPublishingPatientDisc discNameForSeries:discSeries];
                    NSString* safeDiscName = [discName filenameString];
                    
                    // change label in Autorun.inf because ppl don't like "Weasis" to be the label in windows...
                    NSString* autorunInfPath = [discBaseDirPath stringByAppendingPathComponent:@"Autorun.inf"];
                    if ([NSFileManager.defaultManager fileExistsAtPath:autorunInfPath]) {
                        NSStringEncoding encoding;
                        NSString* autorunInf = [NSString stringWithContentsOfFile:autorunInfPath usedEncoding:&encoding error:nil];
                        if (autorunInf.length) {
                            autorunInf = [autorunInf stringByReplacingOccurrencesOfString:@"Label=Weasis" withString:[NSString stringWithFormat:@"Label=%@", safeDiscName]];
                            [NSFileManager.defaultManager removeItemAtPath:autorunInfPath error:nil];
                            [autorunInf writeToFile:autorunInfPath atomically:YES encoding:encoding error:nil];
                        }
                    }
                    
                    NSMutableArray* discModalities = [NSMutableArray array];
                    for (DicomSeries* serie in discSeries)
                        if( serie.modality && ![discModalities containsObject:serie.modality])
                            [discModalities addObject:serie.modality];
                    NSString* modalities = [discModalities componentsJoinedByString:@", "];
                    
                    NSMutableArray* discStudyNames = [NSMutableArray array];
                    for (DicomSeries* serie in discSeries)
                        if( serie.study.studyName && ![discStudyNames containsObject:serie.study.studyName])
                            [discStudyNames addObject:serie.study.studyName];
                    NSString* studyNames = [discStudyNames componentsJoinedByString:@", "];
                    
                    NSMutableArray* discStudyDates = [NSMutableArray array];
                    for (DicomSeries* serie in discSeries) {
                        NSString* date = [dateFormatter stringFromDate:serie.study.date];
                        if( date && ![discStudyDates containsObject:date])
                            [discStudyDates addObject:date];
                    }
                    NSString* studyDates = [discStudyDates componentsJoinedByString:@", "];			
                    
                    // prepare patients dictionary for html generation
                    
                    NSMutableDictionary* htmlExportDic = [NSMutableDictionary dictionary];
                    for (DicomSeries* serie in discSeries) {
                        NSMutableArray* patientSeries = [htmlExportDic objectForKey:serie.study.name];
                        if (!patientSeries) {
                            patientSeries = [NSMutableArray array];
                            [htmlExportDic setObject:patientSeries forKey:serie.study.name];
                        }
                        
                        for (DicomImage* image in [serie sortedImages])
                        {
                            if( image.series)
                                [patientSeries addObject:image.series];
                        }
                    }
                    
                    if (self.isCancelled)
                        return;
                    
                    // move DICOM files
                    
                    NSString* dicomDiscBaseDirPath = [discBaseDirPath stringByAppendingPathComponent:[DiscPublishingPatientDisc dicomDirName]];
                    [[NSFileManager defaultManager] confirmDirectoryAtPath:dicomDiscBaseDirPath];
                    [privateFiles addObject:[DiscPublishingPatientDisc dicomDirName]];
                    
                    NSUInteger fileNumber = 0;
                    for (DicomSeries* serie in discSeries)
                    {
                        for (DicomImage* image in [serie sortedImages])
                        {
                            NSString* newPath = [dicomDiscBaseDirPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%06d", (int) (fileNumber++)]];
                            NSError *error = nil;
                            if( ![[NSFileManager defaultManager] moveItemAtPath:image.pathString toPath:newPath error: &error])
                            {
                                NSLog( @"******* moveItemAtPath failed: %@", error);
                                
                                if( [[NSFileManager defaultManager] fileExistsAtPath: image.pathString] == NO)
                                    NSLog( @"image.pathString fileDoesntExist");
                                
                                if( [[NSFileManager defaultManager] fileExistsAtPath: dicomDiscBaseDirPath] == NO)
                                    NSLog( @"dicomDiscBaseDirPath fileDoesntExist");
                            }
                            image.pathString = newPath;
                        }
                    }
                    NSLog(@"disk %d series count is %d", (int)discNumber, (int)discSeries.count);
                    
                    if (self.isCancelled)
                        return;
                    
                    // generate DICOMDIR: move DICOM to a tmp dir, execute generateDICOMDIRAtDirectory:withDICOMFilesInDirectory: in the tmp dir, move DICOM and DICOMDIR back to the working directory (to avoid dcmmkdir errors/warnings in stdout)
                    NSString* temporaryDirPathForDicomdirGeneration = [NSFileManager.defaultManager tmpFilePathInTmp];
                    NSString* temporaryDicomDirPathForDicomdirGeneration = [temporaryDirPathForDicomdirGeneration stringByAppendingPathComponent:[DiscPublishingPatientDisc dicomDirName]];
                    [NSFileManager.defaultManager confirmDirectoryAtPath:temporaryDirPathForDicomdirGeneration];
                    [NSFileManager.defaultManager moveItemAtPath:dicomDiscBaseDirPath toPath:temporaryDicomDirPathForDicomdirGeneration error:NULL];
                    [DiscPublishingPatientDisc generateDICOMDIRAtDirectory:temporaryDirPathForDicomdirGeneration withDICOMFilesInDirectory:temporaryDirPathForDicomdirGeneration];
                    [NSFileManager.defaultManager moveItemAtPath:temporaryDicomDirPathForDicomdirGeneration toPath:dicomDiscBaseDirPath error:NULL];
                    [NSFileManager.defaultManager moveItemAtPath:[temporaryDirPathForDicomdirGeneration stringByAppendingPathComponent:@"DICOMDIR"] toPath:[discBaseDirPath stringByAppendingPathComponent:@"DICOMDIR"] error:NULL];
                    [NSFileManager.defaultManager removeItemAtPath:temporaryDirPathForDicomdirGeneration error:NULL];
                    [privateFiles addObject:@"DICOMDIR"];
                    
                    if (self.isCancelled)
                        return;
                    
                    // move QTHTML files
                    
                    if (_options.includeHTMLQT) {
                        NSString* htmlqtDiscBaseDirPath = [discBaseDirPath stringByAppendingPathComponent:@"HTML"];
                        [[NSFileManager defaultManager] confirmDirectoryAtPath:htmlqtDiscBaseDirPath];
                        [privateFiles addObject:@"HTML"];

                        for (DicomSeries* serie in discSeries) {
                            NSString* serieHtmlQtBase = [[DiscPublishingPatientDisc dirPathForSeries:serie inBaseDir:_tmpPath] stringByAppendingPathComponent:@"HTMLQT"];
                            // in in this series htmlqt folder, remove the html-extra folder: it will be generated later
                            [[NSFileManager defaultManager] removeItemAtPath:[serieHtmlQtBase stringByAppendingPathComponent:@"html-extra"] error:NULL];
                            // also remove all HTML files: they will be regenerated later, more complete
                            NSDirectoryEnumerator* e = [[NSFileManager defaultManager] enumeratorAtPath:serieHtmlQtBase];
                            NSMutableArray* files = [NSMutableArray array];
                            while (NSString* subpath = [e nextObject]) {
                                NSString* completePath = [serieHtmlQtBase stringByAppendingPathComponent:subpath];
                                BOOL isDir;
                                if ([[NSFileManager defaultManager] fileExistsAtPath:completePath isDirectory:&isDir] && !isDir && [completePath hasSuffix:@".html"])
                                    [[NSFileManager defaultManager] removeItemAtPath:completePath error:NULL];
                                else if (!isDir)
                                    [files addObject:subpath];
                            }
                            
                            // now that the folder has been cleaned, merge its contents
                                
                            for (NSString* subpath in files) {
                                NSString* completePath = [serieHtmlQtBase stringByAppendingPathComponent:subpath];
                                NSString* subDirPath = [subpath stringByDeletingLastPathComponent];
                                NSString* destinationDirPath = [htmlqtDiscBaseDirPath stringByAppendingPathComponent:subDirPath];
                                [[NSFileManager defaultManager] confirmDirectoryAtPath:destinationDirPath];
                                
                                NSString* destinationPath = [htmlqtDiscBaseDirPath stringByAppendingPathComponent:subpath];
                                // does such file already exist?
                                if ([[NSFileManager defaultManager] fileExistsAtPath:destinationPath]) { // yes, change the destination name
                                    NSString* destinationFilename = [destinationPath lastPathComponent];
                                    NSString* destinationDir = [destinationPath substringToIndex:destinationPath.length-destinationFilename.length];
                                    NSString* destinationFilenameExt = [destinationFilename pathExtension];
                                    NSString* destinationFilenamePre = [destinationFilename substringToIndex:destinationFilename.length-destinationFilenameExt.length-1];
                                    
                                    for (NSUInteger i = 0; ; ++i) {
                                        destinationFilename = [NSString stringWithFormat:@"%@_%i.%@", destinationFilenamePre, (int)i, destinationFilenameExt];
                                        destinationPath = [destinationDir stringByAppendingPathComponent:destinationFilename];
                                        if (![[NSFileManager defaultManager] fileExistsAtPath:destinationPath])
                                            break;
                                    }
                                    
                                    NSString* kind = [QTExportHTMLSummary kindOfPath:subpath forSeriesId:serie.id.intValue inSeriesPaths:seriesPaths];
                                    if (kind) {
                                        [BrowserController setPath:destinationPath relativeTo:htmlqtDiscBaseDirPath forSeriesId:serie.id.intValue kind:kind toSeriesPaths:seriesPaths];
                                        DLog(@"renaming %@ to %@", subpath, destinationFilename);
                                    }
                                }
                                
                                [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:NULL];
                                [[NSFileManager defaultManager] moveItemAtPath:completePath toPath:destinationPath error:NULL];
                            }
                            
                            [[NSFileManager defaultManager] removeItemAtPath:serieHtmlQtBase error:NULL];
                            
                            if (self.isCancelled)
                                return;
                        }
                        
                        // generate html
                        
        //				for (NSString* k in htmlExportDic)
        //					NSLog(@"%@ has %d images", k, [[htmlExportDic objectForKey:k] count]);
                        
                        QTExportHTMLSummary* htmlExport = [[QTExportHTMLSummary alloc] init];
                        [htmlExport setPatientsDictionary:htmlExportDic];
                        [htmlExport setPath:htmlqtDiscBaseDirPath];
                        [htmlExport setImagePathsDictionary:seriesPaths];
                        [htmlExport createHTMLfiles];
                        [htmlExport release];
                    }
                    
                    if (self.isCancelled)
                        return;
                    
                    if (_options.zip) {
                        NSMutableArray* args = [NSMutableArray arrayWithObject:@"-r"];
                        if (_options.zipEncrypt && [NSUserDefaultsController discPublishingIsValidPassword:_options.zipEncryptPassword]) {
                            [args addObject:@"-eP"];
                            [args addObject:_options.zipEncryptPassword];
                            [args addObject:@"encryptedDICOM.zip"];
                        } else 
                            [args addObject:@"DICOM.zip"];
                        
                        [args addObjectsFromArray:privateFiles];
                        
                        NSTask* zipTask = [[NSTask alloc] init];
                        [zipTask setLaunchPath: @"/usr/bin/zip"];
                        [zipTask setCurrentDirectoryPath:discBaseDirPath];
                        [zipTask setArguments:args];
                        [zipTask launch];
                        while( [zipTask isRunning]) [NSThread sleepForTimeInterval: 0.01];
                        [zipTask interrupt];
                        [zipTask release];
                        
                        for (NSString* path in [discBaseDirPath stringsByAppendingPaths:privateFiles])
                            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                    }
                    
                    // move data to ~/Library/Application Support/OsiriX/DiscPublishing/Discs/<safeDiscName>
                    
                    NSString* discsDir = [DiscPublishing discsDirPath];
                    [[NSFileManager defaultManager] confirmDirectoryAtPath:discsDir];
                    
                    NSString* discDir = [discsDir stringByAppendingPathComponent:safeDiscName];
                    NSUInteger i = 0;
                    while ([[NSFileManager defaultManager] fileExistsAtPath:discDir])
                        discDir = [discsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%d", safeDiscName, (int)(++i)]];
                    [[NSFileManager defaultManager] moveItemAtPath:discBaseDirPath toPath:discDir error:NULL];
                    
                    // save information dict
                    
                    if (self.isCancelled)
                        return;
                    
                    NSDictionary* info = [NSDictionary dictionaryWithObjectsAndKeys:
                                          safeDiscName, DPJobInfoDiscNameKey,
                                          [NSNumber numberWithBool:_options.deleteOnCompletition], DPJobInfoDeleteWhenCompletedKey,
                      //				  _options, DiscPublishingJobInfoOptionsKey,
                                          _options.discCoverTemplatePath, DPJobInfoTemplatePathKey,
                                          pickedMediaKey, DPJobInfoMediaTypeKey,
                                          [[NSUserDefaultsController sharedUserDefaultsController] valueForValuesKey:DPBurnSpeedDefaultsKey], DPJobInfoBurnSpeedKey,
                                          [NSArray arrayWithObjects:
                                            /* 1 */	PreventNullString(discName),
                                            /* 2 */ PreventNullString([dateFormatter stringFromDate:[[discSeries objectAtIndex:0] study].dateOfBirth]),
                                            /* 3 */	PreventNullString(studyNames),
                                            /* 4 */	PreventNullString(modalities),
                                            /* 5 */ PreventNullString(studyDates),
                                            /* 6 */	PreventNullString([dateFormatter stringFromDate:[NSDate date]]),
                                           NULL], DPJobInfoMergeValuesKey,
                                          [images valueForKeyPath:@"objectID.URIRepresentation.absoluteString"], DPJobInfoObjectIDsKey,
                                          NULL];
                    [[DiscPublishingTasksManager defaultManager] spawnDiscWrite:discDir info:info];
                } @catch (NSException* e) {
                    NSLog(@"[DiscPublishingPatientDisc main] error: %@", e);
                    if (self.window)
                        [self performSelectorOnMainThread:@selector(_reportError:) withObject:e.reason waitUntilDone:NO];
                    break;
                } @finally {
                    [NSThread sleepForTimeInterval:0.01];
                    [pool release];
                }
            }
        } @catch (NSException* e) {
            NSLog(@"[DiscPublishingPatientDisc main] exception: %@", e.reason);
        } @finally {
            //	NSLog(@"paths: %@", seriesPaths);
            
            [seriesPaths release];
            [seriesSizes release];
            [series release];
            [studies release];

           /*[managedObjectContext release];
            [persistentStoreCoordinator release];
            [managedObjectModel release];*/
        }
    }
}

-(void)_reportError:(NSString*)err {
    NSString* title = NSLocalizedString(@"Disc Publishing Error", nil);

    @try {
        [[[DiscPublishing instance] tool] growlWithTitle:title message:err];
    } @catch (...) {
        // an exception occurred while trying to growl an error... we're displaying it anyway, so nevermind
    }
    
    NSAlert* alert = [NSAlert alertWithMessageText:title defaultButton:nil alternateButton:nil otherButton:nil informativeTextWithFormat:@"%@", err];
    [alert.window center];
    [alert.window makeKeyAndOrderFront:self];
}

+(NSArray*)prepareSeriesDataForImages:(NSArray*)imagesIn inDirectory:(NSString*)basePath options:(DiscBurningOptions*)options database:(DicomDatabase*)database seriesPaths:(NSMutableDictionary*)seriesPaths
//+(NSArray*)prepareSeriesDataForImages:(NSArray*)imagesIn inDirectory:(NSString*)basePath options:(DiscBurningOptions*)options context:(NSManagedObjectContext*)managedObjectContext seriesPaths:(NSMutableDictionary*)seriesPaths
{
	NSThread* currentThread = [NSThread currentThread];
	NSString* baseStatus = currentThread.status;
//	CGFloat baseProgress = currentThread.progress;
	
	NSString* dirPath = [NSFileManager.defaultManager tmpFilePathInDir:basePath];
	[[NSFileManager defaultManager] confirmDirectoryAtPath:dirPath];
	
	DLog(@"dirPath is %@", dirPath);
	
	// copy files by considering anonymize
	NSString* dicomDirPath = [dirPath stringByAppendingPathComponent:[DiscPublishingPatientDisc dicomDirName]];
	[[NSFileManager defaultManager] confirmDirectoryAtPath:dicomDirPath];
	
	DLog(@"copying %lu files to %@", (unsigned long)imagesIn.count, dicomDirPath);
	
	currentThread.status = [baseStatus stringByAppendingFormat:@" %@", options.anonymize? NSLocalizedString(@"Anonymizing files...", NULL) : NSLocalizedString(@"Copying files...", NULL) ];
	NSMutableArray* fileNames = [NSMutableArray arrayWithCapacity:imagesIn.count];
	NSMutableArray* originalCopiedFiles = [NSMutableArray array]; // to avoid double copies (multiframe dicom)
	[currentThread enterOperationWithRange:0:0.5];
	@try {
        for (NSUInteger i = 0; i < imagesIn.count; ++i)
        {
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            
            currentThread.progress = CGFloat(i)/imagesIn.count;
            
            DicomImage* image = [imagesIn objectAtIndex:i];
            NSString* filePath = [image completePathResolved];
            
            if (![originalCopiedFiles containsObject:filePath])
            {
                [originalCopiedFiles addObject:filePath];
            
                if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
                {
                    NSLog(@"Warning: file unavailable at path %@", filePath);
                    goto continueFor;
                }
                
                NSString* filename = [NSString stringWithFormat:@"%08d", (int)i]; // IHE wants DICOM files to be named with 8 chars
                NSString* toFilePath = [dicomDirPath stringByAppendingPathComponent:filename];
                
                if (options.anonymize)
                {
                    @try
                    {
                        [DCMObject anonymizeContentsOfFile:filePath tags:options.anonymizationTags writingToFile:toFilePath];
                    }
                    @catch (NSException * e)
                    {
                        NSLog( @"***** exception in %s: %@", __PRETTY_FUNCTION__, e);
                    }
                }
                else
                {
                    NSError *error = nil;
                    
                    if( [[NSFileManager defaultManager] copyItemAtPath:filePath toPath:toFilePath error: &error] == NO)
                        N2LogError( @"[[NSFileManager defaultManager] copyItemAtPath:filePath toPath:toFilePath error: &error] == NO : %@", error);
                }
                
                [fileNames addObject:filename];
            }
            
        continueFor:
            [pool release];
            
            if (currentThread.isCancelled)
                return nil;
        }
    } @catch (...) {
        @throw;
    } @finally {
        currentThread.status = baseStatus;
        [currentThread exitOperation];
    }

	if (!fileNames.count)
		return fileNames;
	
	[currentThread enterOperationWithRange:0.5:0.5];
	currentThread.status = [baseStatus stringByAppendingFormat:@" %@", NSLocalizedString(@"Importing files...", NULL)];
	DLog(@"importing %lu images to context", (unsigned long)fileNames.count);
	
    NSMutableArray* images = nil;
    @try {
    //	NSString* dbPath = [dirPath stringByAppendingPathComponent:@"OsiriX Data"];
    //	[[NSFileManager defaultManager] confirmDirectoryAtPath:dbPath];
        
        NSArray* imageIDs = [[[database addFilesAtPaths:[dicomDirPath stringsByAppendingPaths:fileNames] postNotifications:NO dicomOnly:YES rereadExistingItems:NO] mutableCopy] autorelease];
        images = [[[database objectsWithIDs:imageIDs] mutableCopy] autorelease];
        //	NSMutableArray* imageIDs = [[[database addFilesAtPaths:[dicomDirPath stringsByAppendingPaths:fileNames] postNotifications:NO dicomOnly:YES rereadExistingItems:NO] mutableCopy] autorelease];
        for (NSInteger i = images.count-1; i >= 0; --i)
            if (![[images objectAtIndex:i] pathString] || ![[[images objectAtIndex:i] pathString] hasPrefix:dirPath])
                [images removeObjectAtIndex:i];
        
        DLog(@"    %lu files to %lu images", (unsigned long)fileNames.count, (unsigned long)images.count);
        
        if (!images.count)
            return images;
        
        NSString* oldDirPath = dirPath;
        dirPath = [self dirPathForSeries:[[images objectAtIndex:0] valueForKeyPath:@"series"] inBaseDir:basePath];
        DLog(@"moving %@ to %@", oldDirPath, dirPath);
        
        NSString *dDICOM = [dirPath stringByAppendingPathComponent: @"DICOM"];
        
        NSError *error = nil;
        if( [[NSFileManager defaultManager] createDirectoryAtPath: dDICOM withIntermediateDirectories: YES attributes: nil error: &error] == NO)
            N2LogError( @"[[NSFileManager defaultManager] createDirectoryAtPath: dDICOM withIntermediateDirectories: YES attributes: nil error: nil] : %@", error);
        
        int fileNumber = 0;
        for( DicomImage *im in images)
        {
            while( [[NSFileManager defaultManager] fileExistsAtPath: [dDICOM stringByAppendingPathComponent: [NSString stringWithFormat:@"%06d", fileNumber]]])
                fileNumber++;
            
            NSString *newPath = [dDICOM stringByAppendingPathComponent: [NSString stringWithFormat:@"%06d", fileNumber]];
            
            NSError *error = nil;
            if( [[NSFileManager defaultManager] moveItemAtPath: im.pathString toPath: newPath error: &error] == NO)
                N2LogError( @"[[NSFileManager defaultManager] moveItemAtPath: im.pathString toPath: newPath error: &error] : %@", error);
            [im setPathString: newPath];
        }
        
        dicomDirPath = [dicomDirPath stringByReplacingCharactersInRange:NSMakeRange(0, [oldDirPath length]) withString:dirPath];
        
        if (currentThread.isCancelled)
            return nil;

        DLog(@"decompressing");
        
        currentThread.progress = 0.3;
        if (options.compression == CompressionDecompress || (options.compression == CompressionCompress && options.compressJPEGNotJPEG2000))
        {
            currentThread.status = [baseStatus stringByAppendingFormat:@" %@", NSLocalizedString(@"Decompressing files...", NULL)];
            NSString* beforeDicomDirPath = [dirPath stringByAppendingPathComponent:@"DICOM_before_decompression"];
            
            NSError *error = nil;
            if( [[NSFileManager defaultManager] moveItemAtPath:dicomDirPath toPath:beforeDicomDirPath error: &error] == NO)
                N2LogError( @"[[NSFileManager defaultManager] moveItemAtPath:dicomDirPath toPath:beforeDicomDirPath error: &error] : %@", error);
            
            [[NSFileManager defaultManager] confirmDirectoryAtPath:dicomDirPath];
            
            [DicomCompressor decompressFiles:[beforeDicomDirPath stringsByAppendingPaths:fileNames] toDirectory:dicomDirPath withOptions:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"DecompressMoveIfFail"]];
            [[NSFileManager defaultManager] removeItemAtPath:beforeDicomDirPath error:NULL];
        }
        
        if (currentThread.isCancelled)
            return nil;

        DLog(@"compressing");

        currentThread.progress = 0.4;
        if (options.compression == CompressionCompress)
        {
            currentThread.status = [baseStatus stringByAppendingFormat:@" %@", NSLocalizedString(@"Compressing files...", NULL)];
            NSMutableDictionary* execOptions = [NSMutableDictionary dictionary];
            [execOptions setObject:[NSNumber numberWithBool:options.compressJPEGNotJPEG2000] forKey:@"JPEGinsteadJPEG2000"];
            [execOptions setObject:[NSNumber numberWithBool:YES] forKey:@"DecompressMoveIfFail"];
            if (options.compressJPEGNotJPEG2000) {
                [execOptions setObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys: NSLocalizedString(@"default", nil), @"modality", @"2", @"compression", @"1", @"quality", nil]] forKey: @"CompressionSettings"];
                [execOptions setObject:@"1" forKey:@"CompressionResolutionLimit"];
            }
            
            NSString* beforeDicomDirPath = [dirPath stringByAppendingPathComponent:@"DICOM_before_compression"];
            
            NSError *error = nil;
            if( [[NSFileManager defaultManager] moveItemAtPath:dicomDirPath toPath:beforeDicomDirPath error: &error] == NO)
                N2LogError( @"[[NSFileManager defaultManager] moveItemAtPath:dicomDirPath toPath:beforeDicomDirPath error: &error] : %@", error);
            
            [[NSFileManager defaultManager] confirmDirectoryAtPath:dicomDirPath];
            [DicomCompressor compressFiles:[beforeDicomDirPath stringsByAppendingPaths:fileNames] toDirectory:dicomDirPath withOptions:execOptions];
            [[NSFileManager defaultManager] removeItemAtPath:beforeDicomDirPath error:NULL];
        }
        
//        [DiscPublishingPatientDisc generateDICOMDIRAtDirectory:dirPath withDICOMFilesInDirectory:dicomDirPath];
        
        if (currentThread.isCancelled)
            return nil;

        DLog(@"generating QTHTML");

        currentThread.progress = 0.7;
        if (options.includeHTMLQT) {
            currentThread.status = [baseStatus stringByAppendingFormat:@" %@", NSLocalizedString(@"Generating HTML/Quicktime files...", NULL)];
            NSString* htmlqtTmpPath = [dirPath stringByAppendingPathComponent:@"HTMLQT"]; // IHE wants this folder to be named IHE_PDI... but that's really not an explicit name!
            [[NSFileManager defaultManager] confirmDirectoryAtPath:htmlqtTmpPath];
            NSArray* sortedImages = [images sortedArrayUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"instanceNumber" ascending:YES] autorelease]]];
            [BrowserController exportQuicktime :sortedImages :htmlqtTmpPath :YES :NULL :seriesPaths];
        }
        
        DLog(@"done");
    } @catch (...) {
        @throw;
    } @finally {
        [currentThread exitOperation];
        currentThread.status = baseStatus;
    }
	
	return images;
}

@end
