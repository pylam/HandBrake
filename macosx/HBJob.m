/*  HBJob.m $

 This file is part of the HandBrake source code.
 Homepage: <http://handbrake.fr/>.
 It may be used under the terms of the GNU General Public License. */

#import "HBJob.h"
#import "HBJob+Private.h"
#import "HBTitle+Private.h"

#import "HBAudioDefaults.h"
#import "HBSubtitlesDefaults.h"

#import "HBCodingUtilities.h"
#import "HBMutablePreset.h"

#include "hb.h"

NSString *HBContainerChangedNotification = @"HBContainerChangedNotification";
NSString *HBChaptersChangedNotification  = @"HBChaptersChangedNotification";

@interface HBJob ()

@property (nonatomic, readonly) NSString *name;

/**
 Store the security scoped bookmarks, so we don't
 regenerate it each time
 */
@property (nonatomic, readonly) NSData *fileURLBookmark;
@property (nonatomic, readwrite) NSData *outputURLFolderBookmark;

/**
 Keep track of startAccessingSecurityScopedResource return value
 to avoid calling stopAccessingSecurityScopedResource when unnecessary
 and stopping another instance from accessing the url.
 */
@property (nonatomic, readwrite) BOOL accessingSecurityScopedFileURL;
@property (nonatomic, readwrite) BOOL accessingSecurityScopedOutputURL;

@end

@implementation HBJob

@synthesize uuid = _uuid;

- (instancetype)initWithTitle:(HBTitle *)title andPreset:(HBPreset *)preset
{
    self = [super init];
    if (self) {
        NSParameterAssert(title);
        NSParameterAssert(preset);

        _title = title;
        _titleIdx = title.index;

        _name = [title.name copy];
        _fileURL = title.url;

        _container = HB_MUX_MP4;
        _angle = 1;

        _range = [[HBRange alloc] initWithTitle:title];
        _video = [[HBVideo alloc] initWithJob:self];
        _picture = [[HBPicture alloc] initWithTitle:title];
        _filters = [[HBFilters alloc] init];

        _audio = [[HBAudio alloc] initWithJob:self];
        _subtitles = [[HBSubtitles alloc] initWithJob:self];

        _chapterTitles = [title.chapters copy];

        _uuid = [[NSUUID UUID] UUIDString];

        [self applyPreset:preset];
    }

    return self;
}

#pragma mark - HBPresetCoding

- (void)applyPreset:(HBPreset *)preset
{
    NSAssert(self.title, @"HBJob: calling applyPreset: without a valid title loaded");

    self.presetName = preset.name;
    NSDictionary *jobSettings = [self.title jobSettingsWithPreset:preset];

    self.container = hb_container_get_from_name([preset[@"FileFormat"] UTF8String]);

    // MP4 specifics options.
    self.mp4HttpOptimize = [preset[@"Mp4HttpOptimize"] boolValue];
    self.mp4iPodCompatible = [preset[@"Mp4iPodCompatible"] boolValue];

    // Chapter Markers
    self.chaptersEnabled = [preset[@"ChapterMarkers"] boolValue];

    [self.picture applyPreset:preset jobSettings:jobSettings];
    [self.filters applyPreset:preset jobSettings:jobSettings];
    [self.audio applyPreset:preset jobSettings:jobSettings];
    [self.subtitles applyPreset:preset jobSettings:jobSettings];
    [self.video applyPreset:preset jobSettings:jobSettings];
}

- (void)writeToPreset:(HBMutablePreset *)preset
{
    preset.name = self.presetName;

    preset[@"FileFormat"] = @(hb_container_get_short_name(self.container));
    preset[@"ChapterMarkers"] = @(self.chaptersEnabled);
    // MP4 specifics options.
    preset[@"Mp4HttpOptimize"] = @(self.mp4HttpOptimize);
    preset[@"Mp4iPodCompatible"] = @(self.mp4iPodCompatible);

    [@[self.video, self.filters, self.picture, self.audio, self.subtitles] makeObjectsPerformSelector:@selector(writeToPreset:)
                                                                                                           withObject:preset];
}

- (void)setUndo:(NSUndoManager *)undo
{
    _undo = undo;
    [@[self.video, self.range, self.filters, self.picture, self.audio, self.subtitles] makeObjectsPerformSelector:@selector(setUndo:)
                                                                                                       withObject:_undo];
    [self.chapterTitles makeObjectsPerformSelector:@selector(setUndo:) withObject:_undo];
}

- (void)setPresetName:(NSString *)presetName
{
    if (![presetName isEqualToString:_presetName])
    {
        [[self.undo prepareWithInvocationTarget:self] setPresetName:_presetName];
    }
    _presetName = [presetName copy];
}

- (void)setOutputURL:(NSURL *)outputURL
{
    if (![outputURL isEqualTo:_outputURL])
    {
        [[self.undo prepareWithInvocationTarget:self] setOutputURL:_outputURL];
    }
    _outputURL = [outputURL copy];

#ifdef __SANDBOX_ENABLED__
    // Clear we bookmark to regenerate it
    self.outputURLFolderBookmark = nil;
#endif
}

- (void)setOutputFileName:(NSString *)outputFileName
{
    if (![outputFileName isEqualTo:_outputFileName])
    {
        [[self.undo prepareWithInvocationTarget:self] setOutputFileName:_outputFileName];
    }
    _outputFileName = [outputFileName copy];
}

- (NSURL *)completeOutputURL
{
    return [self.outputURL URLByAppendingPathComponent:self.outputFileName];
}

- (void)setContainer:(int)container
{
    if (container != _container)
    {
        [[self.undo prepareWithInvocationTarget:self] setContainer:_container];
    }

    _container = container;

    [self.audio setContainer:container];
    [self.subtitles setContainer:container];
    [self.video containerChanged];

    // post a notification for any interested observers to indicate that our video container has changed
    [[NSNotificationCenter defaultCenter] postNotificationName:HBContainerChangedNotification object:self];
}

- (void)setAngle:(int)angle
{
    if (angle != _angle)
    {
        [[self.undo prepareWithInvocationTarget:self] setAngle:_angle];
    }
    _angle = angle;
}

- (void)setTitle:(HBTitle *)title
{
    _title = title;
    self.range.title = title;
}

- (void)setMp4HttpOptimize:(BOOL)mp4HttpOptimize
{
    if (mp4HttpOptimize != _mp4HttpOptimize)
    {
        [[self.undo prepareWithInvocationTarget:self] setMp4HttpOptimize:_mp4HttpOptimize];
    }
    _mp4HttpOptimize = mp4HttpOptimize;
}

- (void)setMp4iPodCompatible:(BOOL)mp4iPodCompatible
{
    if (mp4iPodCompatible != _mp4iPodCompatible)
    {
        [[self.undo prepareWithInvocationTarget:self] setMp4iPodCompatible:_mp4iPodCompatible];
    }
    _mp4iPodCompatible = mp4iPodCompatible;
}

- (void)setChaptersEnabled:(BOOL)chaptersEnabled
{
    if (chaptersEnabled != _chaptersEnabled)
    {
        [[self.undo prepareWithInvocationTarget:self] setChaptersEnabled:_chaptersEnabled];
    }
    _chaptersEnabled = chaptersEnabled;
    [[NSNotificationCenter defaultCenter] postNotificationName:HBChaptersChangedNotification object:self];
}

- (NSString *)description
{
    return self.name;
}

- (BOOL)startAccessingSecurityScopedResource
{
#ifdef __SANDBOX_ENABLED__
    if (!self.accessingSecurityScopedFileURL)
    {
        self.accessingSecurityScopedFileURL = [self.fileURL startAccessingSecurityScopedResource];
    }
    if (!self.accessingSecurityScopedOutputURL)
    {
        self.accessingSecurityScopedOutputURL = [self.outputURL startAccessingSecurityScopedResource];
    }

    return self.accessingSecurityScopedFileURL || self.accessingSecurityScopedOutputURL;
#else
    return NO;
#endif
}

- (void)stopAccessingSecurityScopedResource
{
#ifdef __SANDBOX_ENABLED__
    if (self.accessingSecurityScopedFileURL)
    {
        [self.fileURL stopAccessingSecurityScopedResource];
    }
    if (self.accessingSecurityScopedOutputURL)
    {
        [self.outputURL stopAccessingSecurityScopedResource];
    }
#endif
}

#pragma mark - NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
    HBJob *copy = [[[self class] alloc] init];

    if (copy)
    {
        copy->_state = HBJobStateReady;
        copy->_name = [_name copy];
        copy->_presetName = [_presetName copy];
        copy->_titleIdx = _titleIdx;
        copy->_uuid = [[NSUUID UUID] UUIDString];

        copy->_fileURLBookmark = [_fileURLBookmark copy];
        copy->_outputURLFolderBookmark = [_outputURLFolderBookmark copy];

        copy->_fileURL = [_fileURL copy];
        copy->_outputURL = [_outputURL copy];
        copy->_outputFileName = [_outputFileName copy];

        copy->_container = _container;
        copy->_angle = _angle;
        copy->_mp4HttpOptimize = _mp4HttpOptimize;
        copy->_mp4iPodCompatible = _mp4iPodCompatible;

        copy->_range = [_range copy];
        copy->_video = [_video copy];
        copy->_picture = [_picture copy];
        copy->_filters = [_filters copy];

        copy->_video.job = copy;

        copy->_audio = [_audio copy];
        copy->_audio.job = copy;
        copy->_subtitles = [_subtitles copy];
        copy->_subtitles.job = copy;

        copy->_chaptersEnabled = _chaptersEnabled;
        copy->_chapterTitles = [[NSArray alloc] initWithArray:_chapterTitles copyItems:YES];
    }

    return copy;
}

#pragma mark - NSCoding

+ (BOOL)supportsSecureCoding
{
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeInt:3 forKey:@"HBJobVersion"];

    encodeInt(_state);
    encodeObject(_name);
    encodeObject(_presetName);
    encodeInt(_titleIdx);
    encodeObject(_uuid);

#ifdef __SANDBOX_ENABLED__
    NSError *error = nil;

    if (!_fileURLBookmark)
    {
        _fileURLBookmark = [_fileURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope|NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
                                 includingResourceValuesForKeys:nil
                                                  relativeToURL:nil
                                                          error:&error];

        if (error)
        {
            NSLog(@"Error creating bookmark for URL (%@): %@", _fileURL, error);
        }
    }

    encodeObject(_fileURLBookmark);

    if (!_outputURLFolderBookmark)
    {
        BOOL accessed = [_outputURL startAccessingSecurityScopedResource];

        _outputURLFolderBookmark = [_outputURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                                                 includingResourceValuesForKeys:nil
                                                                  relativeToURL:nil
                                                                          error:&error];


        if (error)
        {
            NSLog(@"Error creating bookmark for URL (%@): %@", _outputURL, error);
        }
        if (accessed)
        {
            [_outputURL stopAccessingSecurityScopedResource];
        }
    }

    encodeObject(_outputURLFolderBookmark);

#endif

    encodeObject(_fileURL);
    encodeObject(_outputURL);
    encodeObject(_outputFileName);

    encodeInt(_container);
    encodeInt(_angle);
    encodeBool(_mp4HttpOptimize);
    encodeBool(_mp4iPodCompatible);

    encodeObject(_range);
    encodeObject(_video);
    encodeObject(_picture);
    encodeObject(_filters);

    encodeObject(_audio);
    encodeObject(_subtitles);

    encodeBool(_chaptersEnabled);
    encodeObject(_chapterTitles);
}

- (instancetype)initWithCoder:(NSCoder *)decoder
{
    int version = [decoder decodeIntForKey:@"HBJobVersion"];

    if (version == 3 && (self = [super init]))
    {
        decodeInt(_state);
        decodeObject(_name, NSString);
        decodeObject(_presetName, NSString);
        decodeInt(_titleIdx);
        decodeObject(_uuid, NSString);

#ifdef __SANDBOX_ENABLED__
        NSError *error;

        _fileURLBookmark = [HBCodingUtilities decodeObjectOfClass:[NSData class] forKey:@"_fileURLBookmark" decoder:decoder];

        if (_fileURLBookmark)
        {
            BOOL bookmarkDataIsStale;
            _fileURL = [NSURL URLByResolvingBookmarkData:_fileURLBookmark
                                                 options:NSURLBookmarkResolutionWithSecurityScope
                                           relativeToURL:nil
                                     bookmarkDataIsStale:&bookmarkDataIsStale
                                                   error:&error];
            if (error)
            {
                NSLog(@"Error creating URL from bookmark (%@): %@", _outputURL, error);
            }
        }
        else
        {
            decodeObject(_fileURL, NSURL);
        }

        _outputURLFolderBookmark = [HBCodingUtilities decodeObjectOfClass:[NSData class] forKey:@"_outputURLFolderBookmark" decoder:decoder];

        if (_outputURLFolderBookmark)
        {
            BOOL bookmarkDataIsStale;
            _outputURL = [NSURL URLByResolvingBookmarkData:_outputURLFolderBookmark
                                                             options:NSURLBookmarkResolutionWithSecurityScope
                                                       relativeToURL:nil
                                                 bookmarkDataIsStale:&bookmarkDataIsStale
                                                               error:&error];
            if (error)
            {
                NSLog(@"Error creating URL from bookmark (%@): %@", _outputURL, error);
            }
        }
        else
        {
            decodeObject(_outputURL, NSURL);
        }
#else
        decodeObject(_fileURL, NSURL);
        decodeObject(_outputURL, NSURL);
#endif

        decodeObject(_outputFileName, NSString);

        decodeInt(_container);
        decodeInt(_angle);
        decodeBool(_mp4HttpOptimize);
        decodeBool(_mp4iPodCompatible);

        decodeObject(_range, HBRange);
        decodeObject(_video, HBVideo);
        decodeObject(_picture, HBPicture);
        decodeObject(_filters, HBFilters);

        _video.job = self;

        decodeObject(_audio, HBAudio);
        decodeObject(_subtitles, HBSubtitles);

        _audio.job = self;
        _video.job = self;

        decodeBool(_chaptersEnabled);
        decodeCollectionOfObjects(_chapterTitles, NSArray, HBChapter);

        return self;
    }

    return nil;
}

@end
