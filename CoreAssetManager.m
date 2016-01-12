//
//  CoreAssetManager.m
//  FinTech
//
//  Created by Bálint Róbert on 04/05/15.
//  Copyright (c) 2015 Incepteam All rights reserved.
//

#import "CoreAssetManager.h"
#import "CoreAssetWorker.h"
#import "CoreAssetWorkerDescriptor.h"
#import "CoreAssetItemImage.h"
#import "OKOMutableWeakArray.h"
#import "Helper.h"
#import "MCK_Image+Motis_CustomAccessors.h"
#import "MCK_Image+CoreDataProperties.h"

#define USE_CACHE 2

@interface CoreAssetManager() <CoreAssetWorkerDelegate>

@property (nonatomic, strong) NSMutableArray        *classList;
@property (nonatomic, strong) NSMutableDictionary   *threadDescriptors;
@property (nonatomic, assign) BOOL                  authenticationInProgress;
@property (nonatomic, strong) NSOperationQueue      *cachedOperationQueue;
@property (nonatomic, strong) OKOMutableWeakArray   *delegates;
@property (nonatomic, strong) dispatch_semaphore_t  backgroundFetchLock;
@property (nonatomic, assign) BOOL                  terminateDownloads;
#ifdef USE_CACHE
@property (nonatomic, strong) NSCache               *dataCache;
#endif

@end

@implementation CoreAssetManager

/*static CoreAssetManager *instance;

+ (instancetype)sharedInstance {
    if (!instance) {
        instance = [CoreAssetManager new];
    }
    
    return instance;
}*/

- (instancetype)init {
    self = [super init];
    
    if (self) {
        _classList = [NSMutableArray new];
        _threadDescriptors = [NSMutableDictionary new];
        _authenticationInProgress = NO;
        _cachedOperationQueue = [NSOperationQueue new];
        _cachedOperationQueue.name = @"cachedOperationQueue";
        _delegates = [OKOMutableWeakArray new];
        _terminateDownloads = NO;
#ifdef USE_CACHE
        _dataCache = [NSCache new];
#endif
        
        [self registerThreadForClass:[CoreAssetItemImage class]];
        
        [self enumerateImageAssets];
    }
    
    return self;
}

+ (NSArray *)listFilesInCacheDirectoryWithExtension:(NSString *)extension withSubpath:(NSString *)subpath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *assetPath = [CoreAssetItemNormal assetStorageDirectory];
    
    if (subpath) {
        [assetPath stringByAppendingPathComponent:[subpath stringByAppendingString:@"/"]];
    }
    
    NSMutableArray *list = [NSMutableArray new];
    for (NSString *path in [fileManager enumeratorAtPath:assetPath]) {
        if ([[path pathExtension] isEqualToString:extension])
            [list addObject:path];
    }
    
    return [NSArray arrayWithArray:list];
}

+ (void)removeAllAssetFromCache {
    NSString *assetPath = [CoreAssetItemNormal assetStorageDirectory];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *fileArray = [fileManager contentsOfDirectoryAtPath:assetPath error:nil];
    
    for (NSString *filename in fileArray)  {
        TestLog(@"%@",filename);
        
        if ([filename rangeOfString:@".pdf"].location != NSNotFound || [filename rangeOfString:@".png"].location != NSNotFound || [filename rangeOfString:@".jpg"].location != NSNotFound) {
            [fileManager removeItemAtPath:[assetPath stringByAppendingPathComponent:filename] error:NULL];
        }
    }
}

#pragma mark public interfaces

- (void)stopAllDownloads {
    _terminateDownloads = YES;
    
    for (Class clss in _classList) {
        CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
        
        if ([worker isBusy]) {
            TestLog(@"stopAllDownloads: killing busy worker... class: '%@'", NSStringFromClass(clss));
        }
        
        [worker stop];
    }
    
    _authenticationInProgress = NO;
}

- (void)removeAllCaches {
#ifdef USE_CACHE
    [_dataCache removeAllObjects];
#endif
    
    for (Class clss in _classList) {
        CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
        
        @synchronized (worker) {
            [worker.cachedDict enumerateKeysAndObjectsUsingBlock:^(NSString *assetName, CoreAssetItemNormal *assetItem, BOOL *stop) {
                [assetItem removeStoredFile];
            }];
            
            TestLog(@"removeAllCaches: [1st] removed number of assets: %li in class: '%@'", (long)worker.cachedDict.count, NSStringFromClass(clss));
            
            [worker.normalDict removeAllObjects];
            [worker invalidateNormalList];
            [worker.priorDict removeAllObjects];
            [worker invalidatePriorList];
            [worker.cachedDict removeAllObjects];
        }
    }
    
    [self enumerateImageAssets];
    
    for (Class clss in _classList) {
        CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
        
        @synchronized (worker) {
            [worker.cachedDict enumerateKeysAndObjectsUsingBlock:^(NSString *assetName, CoreAssetItemNormal *assetItem, BOOL *stop) {
                [assetItem removeStoredFile];
            }];
            
            TestLog(@"removeAllCaches: [2nd] removed number of assets: %li in class: '%@'", (long)worker.cachedDict.count, NSStringFromClass(clss));
            
            [worker.normalDict removeAllObjects];
            [worker invalidateNormalList];
            [worker.priorDict removeAllObjects];
            [worker invalidatePriorList];
            [worker.cachedDict removeAllObjects];
        }
    }
    
#ifdef DEBUG
    // extra check
    [self enumerateImageAssets];
    
    NSUInteger faultyRemoveCount = 0;
    
    for (Class clss in _classList) {
        CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
        
        TestLog(@"removeAllCaches: faultyRemoveCount: %li in class: '%@'", (long)worker.cachedDict.count, NSStringFromClass(clss));
        
        @synchronized (worker) {
            faultyRemoveCount += worker.cachedDict.count;
        }
    }
    
    if (faultyRemoveCount) {
        [CoreAssetManager removeAllAssetFromCache];
    }
#endif
}

- (id)fetchAssetDataClass:(Class)clss forAssetName:(NSString *)assetName withCompletionHandler:(CoreAssetManagerCompletionBlock)completionHandler {
    
    //CFTimeInterval startTime = CACurrentMediaTime();
    
    if (!assetName.length) {
        return nil;
    }
    
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    if (!worker) {
        TestLog(@"fetchAssetDataClass: class not registered '%@'", NSStringFromClass(clss));
        return nil;
    }
    
    @synchronized (worker) {
        
        CoreAssetItemNormal *assetItem = [worker.cachedDict objectForKey:assetName];
        
        if (assetItem) {
#ifdef USE_CACHE
            id processedDataCached;
            
            if ((processedDataCached = [_dataCache objectForKey:assetName])) {
                if (completionHandler) {
                    completionHandler(processedDataCached);
                }
                
                return [NSNull null];
            }
#endif
            
            id blockCopy = [assetItem addCompletionHandler:completionHandler];
            
            /*if ([assetItem isKindOfClass:[CoreAssetItemImage class]] && PLATFORM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"4.0")) {
                NSData *cachedData = nil;
                
                @try {
                    cachedData = [assetItem load];
                }
                @catch (NSException *exception) {
                    [worker removeAssetFromCache:assetItem];
                }
                
                if (cachedData) {
                    id processedData = [assetItem postProcessData:cachedData];

#ifdef USE_CACHE
#if USE_CACHE > 1
                    if (assetItem.shouldCache) {
#endif
                        if (![processedData isKindOfClass:NSNull.class]) {
                            [_dataCache setObject:processedData forKey:assetItem.assetName];
                        }
#if USE_CACHE > 1
                    }
#endif
#endif
                    
                    [assetItem sendCompletionHandlerMessages:processedData];
                }
                
                return blockCopy;
            }*/
            
            [_cachedOperationQueue addOperationWithBlock:^{
                //CFTimeInterval lstartTime = CACurrentMediaTime();
                NSData *cachedData = nil;
                
                @try {
                    cachedData = [assetItem load];
                }
                @catch (NSException *exception) {
                    [worker removeAssetFromCache:assetItem];
                }
                
                if (cachedData) {
                    id processedData = [assetItem postProcessData:cachedData];

#ifdef USE_CACHE
#if USE_CACHE > 1
                    if (assetItem.shouldCache) {
#endif
                        if (![processedData isKindOfClass:NSNull.class]) {
                            [_dataCache setObject:processedData forKey:assetItem.assetName];
                        }
#if USE_CACHE > 1
                    }
#endif
#endif
                    
                    if (![processedData isKindOfClass:[NSNull class]]) {
                        [assetItem performSelectorOnMainThread:@selector(sendCompletionHandlerMessages:) withObject:processedData waitUntilDone:NO];
                    }
                }
                
                //CFTimeInterval lendTime = CACurrentMediaTime();
                
                //TestLog(@"Load:%.1fms '%@'", (lendTime-lstartTime)*1000.0, assetItem.assetName);
            }];
            
            //CFTimeInterval endTime = CACurrentMediaTime();
            
            //TestLog(@"Search:%.1fms", (endTime-startTime)*1000.0);
            
            return blockCopy;
        }
        
        assetItem = [worker.normalDict objectForKey:assetName];
        
        if (!assetItem) {
            assetItem = [worker.priorDict objectForKey:assetName];
        }
        else {
            [worker.normalDict removeObjectForKey:assetName];
            [worker.priorDict setObject:assetItem forKey:assetName];
            [worker invalidateNormalList];
        }
        
        if (!assetItem) {
            assetItem = [clss new];
            assetItem.assetName = assetName;
            [worker.priorDict setObject:assetItem forKey:assetName];
        }
        
        assetItem.retryCount = kCoreAssetManagerFetchWithBlockRetryCount;
        
        if (assetItem.priorLevel != kCoreAssetManagerFetchWithBlockPriorLevel) {
            assetItem.priorLevel = kCoreAssetManagerFetchWithBlockPriorLevel;
            [worker invalidatePriorList];
        }
        
        id blockCopy = [assetItem addCompletionHandler:completionHandler];
        
        [worker resume];
        [self performSelectorOnMainThread:@selector(resumeDownloadForClass:) withObject:clss waitUntilDone:NO];
        
        return blockCopy;
    }
    
    //CFTimeInterval endTime = CACurrentMediaTime();
    
    //TestLog(@"Search:%.1fms", (endTime-startTime)*1000.0);
    
    return nil;
}

+ (id)fetchImageWithName:(NSString *)assetName withCompletionHandler:(void (^)(UIImage *image))completionHandler {
    CoreAssetManager *am = [CoreAssetManager manager];
    
    return [am fetchAssetDataClass:[CoreAssetItemImage class] forAssetName:assetName withCompletionHandler:completionHandler];
}

- (NSDictionary *)getCacheDictForDataClass:(Class)clss {
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    return worker.cachedDict;
}

- (void)prioratizeAssetWithName:(NSString *)assetName forClass:(Class)clss priorLevel:(NSUInteger)priorLevel retryCount:(NSUInteger)retryCount startDownload:(BOOL)startDownload {
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    @synchronized (worker) {
        CoreAssetItemNormal *temp = [worker.cachedDict objectForKey:assetName];
        CoreAssetItemNormal *temp2 = [worker.normalDict objectForKey:assetName];
        CoreAssetItemNormal *temp3 = [worker.priorDict objectForKey:assetName];
        
        if (temp3) {
            temp3.retryCount = retryCount;
            
            if (temp3.priorLevel != priorLevel) {
                temp3.priorLevel = priorLevel;
                [worker invalidatePriorList];
            }
        }
        else if (temp2) {
            [worker.priorDict setObject:temp2 forKey:assetName];
            [worker.normalDict removeObjectForKey:assetName];
            
            temp2.retryCount = retryCount;
            temp2.priorLevel = priorLevel;
            [worker invalidateNormalList];
            [worker invalidatePriorList];
        }
        else if (!temp) {
            temp = [clss new];
            temp.assetName = assetName;
            
            [worker.priorDict setObject:temp forKey:assetName];
            [worker.normalDict removeObjectForKey:assetName];
            
            temp.retryCount = retryCount;
            temp.priorLevel = priorLevel;
            [worker invalidateNormalList];
            [worker invalidatePriorList];
        }
    }
    
    if (startDownload) {
        worker.successfullDownloadsNum = @(0);
        _terminateDownloads = NO;
        worker.backgroundFetchMode = NO;
        [worker resume];
        [self performSelectorOnMainThread:@selector(resumeDownloadForClass:) withObject:clss waitUntilDone:NO];
    }
}

#pragma mark Image related

- (void)enumerateImageAssets {
    Class clss = [CoreAssetItemImage class];
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    NSArray *imageList = [CoreAssetManager listFilesInCacheDirectoryWithExtension:@"png" withSubpath:@"images"];
    NSArray *imageList2 = [CoreAssetManager listFilesInCacheDirectoryWithExtension:@"jpg" withSubpath:@"images"];
    imageList = [imageList arrayByAddingObjectsFromArray:imageList2];
    
    @synchronized (worker) {
        for (NSString *imageFilePath in imageList) {
            CoreAssetItemImage *temp = [CoreAssetItemImage new];
            
            temp.assetName = [imageFilePath lastPathComponent];
//          temp.assetName = [[imageFilePath lastPathComponent] stringByDeletingPathExtension];
//          temp.assetName = [temp.assetName stringByReplacingOccurrencesOfString:@"IMG_" withString:@""];
            [worker.cachedDict setObject:temp forKey:temp.assetName];
        }
    }
}

- (void)fetchImageAssetListFromImages:(NSArray *)images startDownload:(BOOL)startDownload {
    Class clss = [CoreAssetItemImage class];
    
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    @synchronized (worker) {
        for (MCK_Image* oneElement in images) {
            NSString *assetName = oneElement.imageUrl;
            CoreAssetItemImage *temp = [worker.cachedDict objectForKey:assetName];
            
            if (!temp) {
                // check if its already in normal download list
                temp = [worker.normalDict objectForKey:assetName];
                
                // if in normal list, do nothing
                if (temp) {
                    continue;
                }
                
                // check if its already in prior list
                temp = [worker.priorDict objectForKey:assetName];
                
                // if in prior list, do nothing
                if (temp) {
                    continue;
                }
                
                // if not, create new, add to the normal list
                temp = [CoreAssetItemImage new];
                temp.assetName = assetName;
                [worker.normalDict setObject:temp forKey:assetName];
            }
        }
        
        [worker invalidateNormalList];
    }
    
    if (startDownload) {
        _terminateDownloads = NO;
        worker.backgroundFetchMode = NO;
        [worker resume];
        [self performSelectorOnMainThread:@selector(resumeDownloadForClass:) withObject:clss waitUntilDone:NO];
    }
}

#pragma mark asset class handling

- (void)registerThreadForClass:(Class)clss {
    // allocate thread
    CoreAssetWorkerDescriptor *worker = [CoreAssetWorkerDescriptor descriptorWithClass:clss];
    worker.delegate = self;
    [_threadDescriptors setObject:worker forKey:NSStringFromClass(clss)];
    
    [_classList addObject:clss];
}

- (void)removeAssetFromDownloadDict:(CoreAssetItemNormal *)assetItem andDispatchCompletionHandlersWithData:(id)assetData loadAssetData:(BOOL)load {
    Class clss = [assetItem class];
    
    //
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    NSMutableArray *removeList = [[NSMutableArray alloc] initWithCapacity:2];
    
    CoreAssetItemNormal *normalItem = [worker.normalDict objectForKey:assetItem.assetName];
    CoreAssetItemNormal *priorItem = [worker.priorDict objectForKey:assetItem.assetName];
    
    if (normalItem) {
        [worker.normalDict removeObjectForKey:assetItem.assetName];
        [removeList addObject:normalItem];
    }
    
    if (priorItem) {
        [worker.priorDict removeObjectForKey:assetItem.assetName];
        [removeList addObject:priorItem];
    }
    
    
    if (!removeList.count)
        TestLog(@"removeAssetFromDownloadList: no instances found for asset '%@' class: '%@'", assetItem.assetName, NSStringFromClass(clss));
    else if (removeList.count > 1)
        TestLog(@"removeAssetFromDownloadList: multiple instances found for asset '%@' count: %li class: '%@'", assetItem.assetName, (long)removeList.count, NSStringFromClass(clss));
    
    [removeList addObject:assetItem];
    
    for (CoreAssetItemNormal *removeItem in removeList) {
        
        if (removeItem.assetCompletionHandlers.count) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                id processedData = assetData;
                
                if(!processedData && load) {
                    NSData *cachedData = [removeItem load];
                    processedData = [removeItem postProcessData:cachedData];

#ifdef USE_CACHE
#if USE_CACHE > 1
                    if (removeItem.shouldCache) {
#endif
                        if (![processedData isKindOfClass:NSNull.class]) {
                            [_dataCache setObject:processedData forKey:removeItem.assetName];
                        }
#if USE_CACHE > 1
                    }
#endif
#endif
                }
                
                [removeItem performSelectorOnMainThread:@selector(sendCompletionHandlerMessages:) withObject:processedData waitUntilDone:NO];
            });
        }
    }
}

- (void)addAssetToCacheDict:(CoreAssetItemNormal *)assetItem {
    Class clss = [assetItem class];
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    [worker.cachedDict setObject:assetItem forKey:assetItem.assetName];
}

- (CoreAssetItemNormal *)getNextDownloadableAssetForClass:(Class)clss {
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    CoreAssetItemNormal *assetItem = nil;
    
    if (worker.priorDict.count)
        assetItem = [[worker.priorDict objectEnumerator] nextObject];
    
    if (!assetItem)
        assetItem = [[worker.normalDict objectEnumerator] nextObject];
    
    // terminates recursion
    if (!assetItem)
        return nil;
    
    CoreAssetItemNormal *cachedItem = [worker.cachedDict objectForKey:assetItem.assetName];
    
    // impossible case when a download finished with asset but still inside the dl list
    if (cachedItem) {
        [self removeAssetFromDownloadDict:assetItem andDispatchCompletionHandlersWithData:nil loadAssetData:YES];
        assetItem = [self getNextDownloadableAssetForClass:clss];
    }
    
    return assetItem;
}

- (void)checkDownloadState {
    NSUInteger busyWorkerCount = 0;
    
    for (Class clss in _classList) {
        CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
        busyWorkerCount += [worker isBusy];
    }
    
    //[[CoreNotificationManager sharedInstance] notifyUserAboutDownloading: busyWorkerCount > 0];
}

- (void)resumeDownloadForClass:(Class)clss {
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    if (_backgroundFetchLock && !worker.isBusy) {
        dispatch_semaphore_signal(_backgroundFetchLock);
    }
    
    if (_authenticationInProgress || _backgroundFetchLock) {
        return;
    }
    
    [worker resume];
    [worker continueDownload:worker.numWorkers];
    
    [self checkDownloadState];
}

- (void)resumeDownloadAllClass {
    for (Class clss in _classList) {
        [self resumeDownloadForClass:clss];
    }
}

#pragma mark CoreAssetWorkerDelegate methods

- (void)finishedDownloadingAsset:(NSDictionary *)assetDict {
    NSData *connectionData = [assetDict objectForKey:kCoreAssetWorkerAssetData];
    CoreAssetItemNormal *assetItem = [assetDict objectForKey:kCoreAssetWorkerAssetItem];
    id postprocessedData = [assetDict objectForKey:kCoreAssetWorkerAssetPostprocessedData];
    const char* dataBytes = connectionData.bytes;
    const char htmlHeader[] = {'<', 'h', 't', 'm', 'l', '>'};
//    const char pngHeader[] = {0x89, 'P', 'N', 'G'};
//    const char gifHeader[] = {'G', 'I', 'F', '8'};
//    const char jpgHeader[] = {0xFF, 0xD8, 0xFF}; // e0-e1 as 4th byte
//    NSError *error;
    NSDictionary *jsonResponse;
    BOOL isImageAsset = NO;
    
    Class clss = [assetItem class];
    CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
    
    if (_terminateDownloads) {
        [assetItem removeStoredFile];
        return;
    }
    else if ([assetItem isKindOfClass:[CoreAssetItemImage class]] && postprocessedData && memcmp(dataBytes, htmlHeader, sizeof(htmlHeader))) {
        //TestLog(@"finishedDownloadingAsset: png asset: '%@' class: '%@'", assetItem.assetName, NSStringFromClass(clss));
        isImageAsset = YES;
        
        if ([postprocessedData isKindOfClass:[CoreAssetItemErrorImage class]]) {
            TestLog(@"finishedDownloadingAsset: no-pic error asset: '%@' class: '%@'", assetItem.assetName, NSStringFromClass(clss));
            [worker removeAssetFromCache:assetItem];
        } else {
            worker.successfullDownloadsNum = @(worker.successfullDownloadsNum.integerValue + 1);
        }
    }
    else if ([assetItem isKindOfClass:[CoreAssetItemImage class]] && postprocessedData && ![postprocessedData isKindOfClass:[NSNull class]] && memcmp(dataBytes, htmlHeader, sizeof(htmlHeader))) {
        NSDictionary* errorDict = [jsonResponse objectForKey:@"error"];
        NSString* errorCode = [errorDict objectForKey:@"code"];
        
        TestLog(@"finishedDownloadingAsset: json, error code: %@ asset: '%@' class: '%@'", errorCode, assetItem.assetName, NSStringFromClass(clss));
        
        if (errorCode) {
            /*ServerErrorCode code = (ServerErrorCode)[errorCode integerValue];
            
            if (code == ServerErrorCode_AuthNeeded || code == ServerErrorCode_SessionIsOver) {
                if (!authenticationInProgress) {
                    authenticationInProgress = YES;
                    [[AuthenticationManager sharedInstance] automaticLoginWithCompletionHandler:^(NSException *error) {
                        authenticationInProgress = NO;
                        [self resumeDownloadAllClass];
                    }];
                }
                return;
            }*/
            
            // any other error codes
            [self removeAssetFromDownloadDict:assetItem andDispatchCompletionHandlersWithData:nil loadAssetData:NO];
            [assetItem removeStoredFile];
            [self resumeDownloadForClass:clss];
            return;
        }
    }
    else if (!connectionData.length) {
        TestLog(@"finishedDownloadingAsset: unknown error asset: '%@' class: '%@' zero bytes", assetItem.assetName, NSStringFromClass(clss));
        //[worker removeAssetFromCache:assetItem];
        [self resumeDownloadForClass:clss];
        return;
    }
    else {
        TestLog(@"finishedDownloadingAsset: unknown error asset: '%@' class: '%@' bytes: '%.4s' (%.2x%.2x%.2x%.2x)", assetItem.assetName, NSStringFromClass(clss), dataBytes, (UInt8)dataBytes[0], (UInt8)dataBytes[1], (UInt8)dataBytes[2], (UInt8)dataBytes[3]);
        [worker removeAssetFromCache:assetItem];
        [self resumeDownloadForClass:clss];
        return;
    }
    
#ifdef USE_CACHE
#if USE_CACHE > 1
    if (assetItem.shouldCache) {
#endif
        if (![postprocessedData isKindOfClass:NSNull.class]) {
            [_dataCache setObject:postprocessedData forKey:assetItem.assetName];
        }
#if USE_CACHE > 1
    }
#endif
#endif
    
    [assetItem sendPostProcessedDataToHandlers:postprocessedData];
    [_delegates compact];
    
    if (isImageAsset) {
        
        for (NSObject<CoreAssetManagerDelegate> *delegate in _delegates) {
            
            if ([delegate respondsToSelector:@selector(cachedImageDictChanged:)]) {
                CoreAssetWorkerDescriptor *worker = [_threadDescriptors objectForKey:NSStringFromClass(clss)];
                [delegate performSelectorOnMainThread:@selector(cachedImageDictChanged:) withObject:worker.cachedDict waitUntilDone:NO];
            }
        }
    }
    
    [self resumeDownloadForClass:clss];
}

- (void)failedDownloadingAsset:(NSDictionary *)assetDict {
    CoreAssetItemNormal *assetItem = [assetDict objectForKey:kCoreAssetWorkerAssetItem];
    
    Class clss = [assetItem class];
    
    TestLog(@"failedDownloadingAsset: '%@' class: '%@'", assetItem.assetName, NSStringFromClass(clss));
    
    [self resumeDownloadForClass:clss];
}

- (void)addWeakDelegate:(NSObject<CoreAssetManagerDelegate> *)delegate {
    [_delegates addObject:delegate];
    [_delegates compact];
}

- (void)removeWeakDelegate:(NSObject<CoreAssetManagerDelegate> *)delegate {
    [_delegates addObject:delegate];
    [_delegates compact];
}

#pragma mark - helper methods

+ (void)disableBackupForFilePath:(NSString *)path {
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    
    if (![fileURL setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:&error]) {
        TestLog(@"disableBackupForFilePath: an error uccured: '%@'", error.description);
    }
}

@end