//
//  CK2FileTransferSession.m
//  Connection
//
//  Created by Mike on 08/10/2012.
//
//

#import "CK2FileTransferSession.h"
#import "CK2FileTransferProtocol.h"


@interface CK2FileTransferClient : NSObject <CK2FileTransferProtocolClient>
{
  @private
    CK2FileTransferSession  *_session;
    void    (^_completionBlock)(NSError *);
    void    (^_enumerationBlock)(NSURL *);
}

- (id)initWithSession:(CK2FileTransferSession *)session completionBlock:(void (^)(NSError *))block;
- (id)initWithSession:(CK2FileTransferSession *)session enumerationBlock:(void (^)(NSURL *))enumBlock completionBlock:(void (^)(NSError *))block;

@end


#pragma mark -


NSString * const CK2URLSymbolicLinkDestinationKey = @"CK2URLSymbolicLinkDestination";


@implementation CK2FileTransferSession

#pragma mark Lifecycle

- (id)init;
{
    if (self = [super init])
    {
        // Record the queue to use for delegate messages
        NSOperationQueue *queue = [NSOperationQueue currentQueue];
        if (queue)
        {
            _deliverDelegateMessages = ^(void(^block)(void)) {
                [queue addOperationWithBlock:block];
            };
        }
        else
        {
            dispatch_queue_t queue = dispatch_get_current_queue();
            NSAssert(queue, @"dispatch_get_current_queue unexpectedly claims there is no current queue");
            
            _deliverDelegateMessages = ^(void(^block)(void)) {
                dispatch_async(queue, block);
            };
        }
        _deliverDelegateMessages = [_deliverDelegateMessages copy];
    }
    
    return self;
}

- (void)dealloc;
{
    [_deliverDelegateMessages release]; _deliverDelegateMessages = nil;
    [super dealloc];
}

#pragma mark NSURLAuthenticationChallengeSender

- (void)useCredential:(NSURLCredential *)credential forAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
}

- (void)continueWithoutCredentialForAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
}

- (void)cancelAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
}

#pragma mark Discovering Directory Contents

- (void)contentsOfDirectoryAtURL:(NSURL *)url
      includingPropertiesForKeys:(NSArray *)keys
                         options:(NSDirectoryEnumerationOptions)mask
               completionHandler:(void (^)(NSArray *, NSError *))block;
{
    NSMutableArray *contents = [[NSMutableArray alloc] init];
    __block BOOL resolved = NO;
    
    [self enumerateContentsOfURL:url includingPropertiesForKeys:keys options:(mask|NSDirectoryEnumerationSkipsSubdirectoryDescendants) usingBlock:^(NSURL *aURL) {
        
        if (resolved)
        {
            [contents addObject:aURL];
        }
        else
        {
            resolved = YES;
        }
        
    } completionHandler:^(NSError *error) {
        
        block(contents, error);
        [contents release];
    }];
}

- (void)enumerateContentsOfURL:(NSURL *)url includingPropertiesForKeys:(NSArray *)keys options:(NSDirectoryEnumerationOptions)mask usingBlock:(void (^)(NSURL *))block completionHandler:(void (^)(NSError *))completionBlock;
{
    NSParameterAssert(url);
    
    [CK2FileTransferProtocol classForURL:url completionHandler:^(Class protocolClass) {
        
        if (protocolClass)
        {
            CK2FileTransferClient *client = [[CK2FileTransferClient alloc] initWithSession:self
                                                                          enumerationBlock:block
                                                                           completionBlock:completionBlock];
            
            [protocolClass startEnumeratingContentsOfURL:url includingPropertiesForKeys:keys options:mask client:client];
            [client release];
        }
        else
        {
            completionBlock([self unsupportedURLErrorWithURL:url]);
        }
    }];
}

#pragma mark Creating and Deleting Items

- (void)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates completionHandler:(void (^)(NSError *error))handler;
{
    NSParameterAssert(url);
    
    [CK2FileTransferProtocol classForURL:url completionHandler:^(Class protocol) {
        
        if (protocol)
        {
            CK2FileTransferClient *client = [self makeClientWithCompletionHandler:handler];
            [protocol startCreatingDirectoryAtURL:url withIntermediateDirectories:createIntermediates client:client];
        }
        else
        {            
            handler([self unsupportedURLErrorWithURL:url]);
        }
    }];
}

- (void)createFileAtURL:(NSURL *)url contents:(NSData *)data withIntermediateDirectories:(BOOL)createIntermediates progressBlock:(void (^)(NSUInteger bytesWritten, NSError *error))progressBlock;
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url];
    [request setHTTPBody:data];
    
    [self createFileWithRequest:request withIntermediateDirectories:createIntermediates progressBlock:progressBlock];
    [request release];
}

- (void)createFileAtURL:(NSURL *)destinationURL withContentsOfURL:(NSURL *)sourceURL withIntermediateDirectories:(BOOL)createIntermediates progressBlock:(void (^)(NSUInteger bytesWritten, NSError *error))progressBlock;
{
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:destinationURL];
    
    // Read the data using an input stream if possible
    NSInputStream *stream = [[NSInputStream alloc] initWithURL:sourceURL];
    if (stream)
    {
        [request setHTTPBodyStream:stream];
        [stream release];
    }
    else
    {
        NSError *error;
        NSData *data = [[NSData alloc] initWithContentsOfURL:sourceURL options:0 error:&error];
        
        if (data)
        {
            [request setHTTPBody:data];
            [data release];
        }
        else
        {
            [request release];
            if (!error) error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
            progressBlock(0, error);
            return;
        }
    }
    
    [self createFileWithRequest:request withIntermediateDirectories:createIntermediates progressBlock:progressBlock];
    [request release];
}

- (void)createFileWithRequest:(NSURLRequest *)request withIntermediateDirectories:(BOOL)createIntermediates progressBlock:(void (^)(NSUInteger bytesWritten, NSError *error))progressBlock;
{
    NSParameterAssert(request);
    
    [CK2FileTransferProtocol classForURL:[request URL] completionHandler:^(Class protocol) {
        
        if (protocol)
        {
            CK2FileTransferClient *client = [self makeClientWithCompletionHandler:^(NSError *error) {
                progressBlock(0, error);
            }];
            
            [protocol startCreatingFileWithRequest:request withIntermediateDirectories:createIntermediates client:client progressBlock:^(NSUInteger bytesWritten){
                progressBlock(bytesWritten, nil);
            }];
        }
        else
        {
            progressBlock(0, [self unsupportedURLErrorWithURL:[request URL]]);
        }
    }];
}

- (void)removeFileAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;
{
    NSParameterAssert(url);
    
    [CK2FileTransferProtocol classForURL:url completionHandler:^(Class protocol) {
        
        if (protocol)
        {
            CK2FileTransferClient *client = [self makeClientWithCompletionHandler:handler];
            [protocol startRemovingFileAtURL:url client:client];
        }
        else
        {
            handler([self unsupportedURLErrorWithURL:url]);
        }
    }];
}

#pragma mark Getting and Setting Attributes

- (void)setResourceValues:(NSDictionary *)keyedValues ofItemAtURL:(NSURL *)url completionHandler:(void (^)(NSError *error))handler;
{
    NSParameterAssert(keyedValues);
    NSParameterAssert(url);
    
    [CK2FileTransferProtocol classForURL:url completionHandler:^(Class protocol) {
        
        if (protocol)
        {
            CK2FileTransferClient *client = [self makeClientWithCompletionHandler:handler];
            [protocol startRemovingFileAtURL:url client:client];
        }
        else
        {
            handler([self unsupportedURLErrorWithURL:url]);
        }
    }];
}

#pragma mark Delegate

@synthesize delegate = _delegate;

- (void)deliverBlockToDelegate:(void (^)(void))block;
{
    _deliverDelegateMessages(block);
}

#pragma mark URLs

+ (NSURL *)URLWithPath:(NSString *)path relativeToURL:(NSURL *)baseURL;
{
    Class protocolClass = [CK2FileTransferProtocol classForURL:baseURL];
    if (!protocolClass)
    {
        protocolClass = [CK2FileTransferProtocol class];
        if ([path isAbsolutePath])
        {
            // On 10.6, file URLs sometimes behave strangely when combined with an absolute path. Force it to be resolved
            if ([baseURL isFileURL]) [baseURL absoluteString];
        }
    }
    return [protocolClass URLWithPath:path relativeToURL:baseURL];
}

+ (NSString *)pathOfURLRelativeToHomeDirectory:(NSURL *)URL;
{
    Class protocolClass = [CK2FileTransferProtocol classForURL:URL];
    if (!protocolClass) protocolClass = [CK2FileTransferProtocol class];
    return [protocolClass pathOfURLRelativeToHomeDirectory:URL];
}

+ (BOOL)canHandleURL:(NSURL *)url;
{
    return ([CK2FileTransferProtocol classForURL:url] != nil);
}

#pragma mark Transfers

- (CK2FileTransferClient *)makeClientWithCompletionHandler:(void (^)(NSError *error))block;
{
    CK2FileTransferClient *client = [[CK2FileTransferClient alloc] initWithSession:self completionBlock:block];
    return [client autorelease];
}

- (NSError *)unsupportedURLErrorWithURL:(NSURL *)url;
{
    NSDictionary *info = @{NSURLErrorKey : url, NSURLErrorFailingURLErrorKey : url, NSURLErrorFailingURLStringErrorKey : [url absoluteString]};
    return [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:info];
}

@end


#pragma mark -


@implementation CK2FileTransferClient

- (id)initWithSession:(CK2FileTransferSession *)session completionBlock:(void (^)(NSError *))block;
{
    NSParameterAssert(block);
    NSParameterAssert(session);
    
    if (self = [self init])
    {
        _session = [session retain];
        _completionBlock = [block copy];
        
        [self retain];  // until protocol finishes or fails
    }
    
    return self;
}

- (id)initWithSession:(CK2FileTransferSession *)session enumerationBlock:(void (^)(NSURL *))enumBlock completionBlock:(void (^)(NSError *))block;
{
    if (self = [self initWithSession:session completionBlock:block])
    {
        _enumerationBlock = [enumBlock copy];
    }
    return self;
}

- (void)finishWithError:(NSError *)error;
{
    _completionBlock(error);
    
    [_completionBlock release]; _completionBlock = nil;
    [_enumerationBlock release]; _enumerationBlock = nil;
    [_session release]; _session = nil;
    
    [self release]; // balances call in -init
}

- (void)fileTransferProtocol:(CK2FileTransferProtocol *)protocol didFailWithError:(NSError *)error;
{
    if (!error) error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:nil];
    [self finishWithError:error];
}

- (void)fileTransferProtocolDidFinish:(CK2FileTransferProtocol *)protocol;
{
    [self finishWithError:nil];
}

- (void)fileTransferProtocol:(CK2FileTransferProtocol *)protocol didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge;
{
    // TODO: Cache credentials per protection space
    [_session deliverBlockToDelegate:^{
        [[_session delegate] fileTransferSession:_session didReceiveAuthenticationChallenge:challenge];
    }];
}

- (void)fileTransferProtocol:(CK2FileTransferProtocol *)protocol appendString:(NSString *)info toTranscript:(CKTranscriptType)transcript;
{
    [_session deliverBlockToDelegate:^{
        [[_session delegate] fileTransferSession:_session appendString:info toTranscript:transcript];
    }];
}

- (void)fileTransferProtocol:(CK2FileTransferProtocol *)protocol didDiscoverItemAtURL:(NSURL *)url;
{
    if (_enumerationBlock)
    {
        _enumerationBlock(url);
    }
}

@end


#pragma mark -


@implementation NSURL (ConnectionKit)

- (BOOL)ck2_isFTPURL;
{
    NSString *scheme = [self scheme];
    return ([@"ftp" caseInsensitiveCompare:scheme] == NSOrderedSame || [@"ftps" caseInsensitiveCompare:scheme] == NSOrderedSame);
}

@end
