//
//  CoreAssetItemNormal.h
//  CoreAssetManager
//
//  Created by Bálint Róbert on 04/05/15.
//  Copyright (c) 2015 Incepteam All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CoreAssetManager.h"
@import util;

NS_ASSUME_NONNULL_BEGIN

@interface CoreAssetItemNormal : NSObject

@property (nonatomic, strong) OKOMutableWeakArray* assetCompletionHandlers;
@property (nonatomic, strong) OKOMutableWeakArray* assetFailureHandlers;
@property (nonatomic, assign) NSUInteger priorLevel;
@property (nonatomic, assign) NSUInteger retryCount;
@property (nonatomic, strong) NSString *assetName;
@property (nonatomic, readonly) BOOL shouldCache;

+ (NSUInteger)workerThreads;
+ (Class)parentCamClass;

+ (NSString *)assetStorageDirectory;
- (NSString *)fileSystemPath;
- (NSString *)cacheIdentifier;

- (NSData *)load;
- (void)store:(NSData *)assetData;
- (void)removeStoredFile;

- (NSURLRequest *)createURLRequest;

- (id)addCompletionHandler:(CoreAssetManagerCompletionBlock)completionHandler;
- (void)sendCompletionHandlerMessages:(id)data;

- (id)addFailureHandler:(CoreAssetManagerFailureBlock)completionHandler;
- (void)sendFailureHandlerMessages:(NSError *)reason;

- (id)postProcessData:(NSData *)assetData;

- (void)sendPostProcessedDataToHandlers:(id)postprocessedData;
- (void)sendFailureOnMainThreadToHandlers:(NSError *)reason;

+ (_Nullable id)fetchAssetWithName:(NSString *)assetName withCompletionHandler:(CoreAssetManagerCompletionBlock)completionHandler;
+ (_Nullable id)fetchAssetWithName:(NSString *)assetName withCompletionHandler:(CoreAssetManagerCompletionBlock)completionHandler withFailureHandler:(CoreAssetManagerFailureBlock)failureHandler;

@end

NS_ASSUME_NONNULL_END
