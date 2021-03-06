#include <mutex>
#import <CoreFoundation/CoreFoundation.h>
//#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#include <VideoToolbox/VideoToolbox.h>

#include "h264_encoder.h"

static CMTimeValue s_forcedKeyframePTS = 0;

static std::mutex m_encodeMutex;

static size_t skipDisposable(const uint8_t *data, size_t size) {
  size_t pos = 0;
  while (pos < size) {
    size_t len = 0;
    for (int j = 4; j--; pos++) {
      len |= (data[pos] << (j * 8));
    }
    uint8_t flag = data[pos];
    bool disposable = ((flag >> 5) & 0x03) == 0;
    //uint8_t type = (flag & 0x1F);
    //printf("\ttype=%d, size=%lu, disposable=%d\n", type, len, disposable);
    if (disposable) {
      pos += len;
    } else {
      pos -= 4;
      break;
    }
  }
  return pos;
}

void vtCallback(void *outputCallbackRefCon,
                void *sourceFrameRefCon,
                OSStatus status,
                VTEncodeInfoFlags infoFlags,
                CMSampleBufferRef sampleBuffer )
{
  bool isKeyframe = false;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);

  if (attachments != NULL) {
    CFDictionaryRef attachment;
    CFBooleanRef dependsOnOthers;
    attachment = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    dependsOnOthers = (CFBooleanRef)CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers);
    isKeyframe = (dependsOnOthers == kCFBooleanFalse);
  }

  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  uint8_t *bufferData;
  size_t size;
  CMBlockBufferGetDataPointer(block, 0, NULL, &size, (char**) &bufferData);

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  //CMTime dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer);

  if (isKeyframe) {
    // Send the SPS and PPS.
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    size_t spsSize, ppsSize;
    size_t parmCount;
    const uint8_t* sps, *pps;

    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, &sps, &spsSize, &parmCount, nullptr );
    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 1, &pps, &ppsSize, &parmCount, nullptr );

    uint8_t *sps_buf = (uint8_t *)malloc(sizeof(uint8_t) * spsSize);
    uint8_t *pps_buf = (uint8_t *)malloc(sizeof(uint8_t) * ppsSize);

    memcpy(sps_buf, sps, spsSize);
    memcpy(pps_buf, pps, ppsSize);

    ((H264Encoder*)outputCallbackRefCon)->compressionSessionOutput(ENALUnitSPS, sps_buf, spsSize, pts.value, pts.timescale);
    ((H264Encoder*)outputCallbackRefCon)->compressionSessionOutput(ENALUnitPPS, pps_buf, ppsSize, pts.value, pts.timescale);

    size_t skipLen = skipDisposable(bufferData, size);
    size -= skipLen;
    bufferData += skipLen;
  }
        
  uint8_t *buf = (uint8_t *)malloc(sizeof(uint8_t) * size);
  memcpy(buf, bufferData, size);

  ((H264Encoder*)outputCallbackRefCon)->compressionSessionOutput(ENALUnitSlice, buf, size, pts.value, pts.timescale);
}

H264Encoder::H264Encoder(void *client, int inputFrameW, int inputFrameH, int outputFrameW, int outputFrameH, int fps, int bitrate, bool useBaseline)
 : m_client(client), m_inputFrameW(inputFrameW), m_inputFrameH(inputFrameH),
  m_outputFrameW(outputFrameW), m_outputFrameH(outputFrameH),
  m_fps(fps), m_bitrate(bitrate), m_flush(false),
  spsData(nullptr), spsDataLen(0), ppsData(nullptr), ppsDataLen(0),
  samples((const uint8_t **)malloc(sizeof(uint8_t*) * DEFAULT_SAMPLE_COUNT)),
  sampleByteLength(0),
  sampleSizeList((size_t *)malloc(sizeof(size_t) * DEFAULT_SAMPLE_COUNT)),
  sampleTimeList((int32_t *)malloc(sizeof(int32_t) * DEFAULT_SAMPLE_COUNT)),
  sampleCount(0), maxSampleCount(DEFAULT_SAMPLE_COUNT), m_timescale(1000), m_baseTimeOffset(0), m_firstBaseTimeOffset(0)
{
  setupCompressionSession(useBaseline);
}

H264Encoder::~H264Encoder()
{
  teardownCompressionSession();
}

CVPixelBufferPoolRef H264Encoder::pixelBufferPool() {
  if (m_compressionSession) {
    return VTCompressionSessionGetPixelBufferPool((VTCompressionSessionRef)m_compressionSession);
  }
  return nullptr;
}

void H264Encoder::pushBuffer(const uint8_t *const data, size_t size, const int64_t timestamp, const int32_t timescale, bool forceKeyFrame)
{
  if (m_compressionSession) {
    m_encodeMutex.lock();
    VTCompressionSessionRef session = (VTCompressionSessionRef)m_compressionSession;

    //printf("\tdelta: %d\n", timestamp);

    CMTime pts = CMTimeMake(timestamp, timescale);
    CMTime dur = CMTimeMake(1, m_fps);
    VTEncodeInfoFlags flags;

    CFMutableDictionaryRef frameProps = NULL;

    if (forceKeyFrame) {
      s_forcedKeyframePTS = pts.value;
      frameProps = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFDictionaryAddValue(frameProps, kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);
    }
    VTCompressionSessionEncodeFrame(session, (CVPixelBufferRef)data, pts, dur, frameProps, NULL, &flags);

    if (forceKeyFrame) {
      CFRelease(frameProps);
    }

    m_encodeMutex.unlock();
  }
}

void H264Encoder::setBitrate(int bitrate)
{
  if (bitrate == m_bitrate) {
    return;
  }
  m_bitrate = bitrate;

  if (m_compressionSession) {
    m_encodeMutex.lock();

    int v = m_bitrate;
    CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);

    //VTCompressionSessionCompleteFrames((VTCompressionSessionRef)m_compressionSession, kCMTimeInvalid);

    OSStatus ret = VTSessionSetProperty((VTCompressionSessionRef)m_compressionSession, kVTCompressionPropertyKey_AverageBitRate, ref);

    if (ret != noErr) {
      printf("H264Encoder::setBitrate Error setting bitrate! %d\n", (int) ret);
    }
    CFRelease(ref);
    ret = VTSessionCopyProperty((VTCompressionSessionRef)m_compressionSession, kVTCompressionPropertyKey_AverageBitRate, kCFAllocatorDefault, &ref);

    if (ret == noErr && ref) {
      SInt32 br = 0;

      CFNumberGetValue(ref, kCFNumberSInt32Type, &br);

      m_bitrate = br;
      CFRelease(ref);
    } else {
      m_bitrate = v;
    }
    v = bitrate / 8;
    CFNumberRef bytes = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
    v = 1;
    CFNumberRef duration = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);

    CFMutableArrayRef limit = CFArrayCreateMutable(kCFAllocatorDefault, 2, &kCFTypeArrayCallBacks);

    CFArrayAppendValue(limit, bytes);
    CFArrayAppendValue(limit, duration);

    VTSessionSetProperty((VTCompressionSessionRef)m_compressionSession, kVTCompressionPropertyKey_DataRateLimits, limit);
    CFRelease(bytes);
    CFRelease(duration);
    CFRelease(limit);

    m_encodeMutex.unlock();
  }
}

#if 0
static void printNAL(const uint8_t *data, const size_t size) {
  size_t len = 0;
  for (int i = 0, j = 4; j--; i++) {
    len |= (data[i] << (j * 8));
  }
  uint8_t type = (data[4] & 0x1F);
  printf("type=%d, firstBytes=%lu, statedSize=%lu\n", type, len, size);
}
#endif

void H264Encoder::compressionSessionOutput(ENALUnitType type, const uint8_t *data, size_t size, uint64_t pts, uint32_t timescale)
{
  m_encodeMutex.lock();

  switch (type) {
  case ENALUnitSPS:
    if (m_flush) {
      flushCompressedData();
      m_flush = false;
    }
    //printf("SPS: type=%d\n", (data[0] & 0x1F));
    spsData = data;
    spsDataLen = size;
    m_timescale = timescale;
    break;
  case ENALUnitPPS:
    //printf("PPS: type=%d\n", (data[0] & 0x1F));
    ppsData = data;
    ppsDataLen = size;
    break;
  case ENALUnitSlice:
    addEntry(data, size, pts);
    break;
  }

  m_encodeMutex.unlock();
}

void H264Encoder::addEntry(const uint8_t *data, size_t size, int64_t timeDelta)
{
  samples[sampleCount] = data;
  //printf("sample[%lu]: ", sampleCount);
  //printNAL(data, size);
  sampleSizeList[sampleCount] = size;
  sampleByteLength += size;
  if (sampleCount == 0) {
    m_baseTimeOffset = timeDelta;
    if (m_firstBaseTimeOffset == 0) {
      m_firstBaseTimeOffset = m_baseTimeOffset;
    }
  }
  sampleTimeList[sampleCount] = ((timeDelta - m_baseTimeOffset) & 0xFFFFFFFF);
  if (++sampleCount >= maxSampleCount) {
    maxSampleCount += DEFAULT_SAMPLE_COUNT;
    samples = (const uint8_t **)realloc((void *)samples, sizeof(uint8_t*) * maxSampleCount);
    sampleSizeList = (size_t *)realloc((void *)sampleSizeList, sizeof(size_t) * maxSampleCount);
    sampleTimeList = (int32_t *)realloc((void *)sampleTimeList, sizeof(int32_t) * maxSampleCount);
  }
}

void H264Encoder::flush()
{
  m_flush = true;
}

void H264Encoder::flushCompressedData()
{
  printf("H264Encoder::flushCompressedData()\n");

  uint8_t *buf, *p_buf;
  buf = (uint8_t*)malloc(sizeof (uint8_t) * sampleByteLength);
  p_buf = buf;
  for (unsigned i = 0; i < sampleCount; i++) {
    int len = sampleSizeList[i];
    //printf("sample[%u]: ", i);
    //printNAL(samples[i], len);
    memcpy((void *)p_buf, samples[i], len);
    p_buf += len;
    free((void *) samples[i]);
  }

  [(id)m_client  setFrameData:(const void *) buf
    length: sampleByteLength
    spsData: spsData
    spsDataLength: spsDataLen
    ppsData: ppsData
    ppsDataLength: ppsDataLen
    sampleSizeList: sampleSizeList
    sampleTimeList: sampleTimeList
    sampleListLength: sampleCount
    sampleTimeScale: m_timescale
    sampleBaseTimeOffset: m_baseTimeOffset - m_firstBaseTimeOffset
  ];

  spsData = nullptr;
  spsDataLen = 0;
  ppsData = nullptr;
  ppsDataLen = 0;

  sampleCount = 0;
  maxSampleCount = DEFAULT_SAMPLE_COUNT;

  sampleByteLength = 0;
  free((void *) samples);
  samples = (const uint8_t **)malloc(sizeof(uint8_t*) * maxSampleCount);
  sampleSizeList = (size_t *)malloc(sizeof(size_t) * maxSampleCount);
  sampleTimeList = (int32_t *)malloc(sizeof(int32_t) * maxSampleCount);
}

void H264Encoder::setupCompressionSession(bool useBaseline)
{
  m_baseline = useBaseline;

  // Parts of this code pulled from https://github.com/galad87/HandBrake-QuickSync-Mac/blob/2c1332958f7095c640cbcbcb45ffc955739d5945/libhb/platform/macosx/encvt_h264.c
  // More info from WWDC 2014 Session 513

  m_encodeMutex.lock();
  OSStatus err = noErr;
  CFMutableDictionaryRef encoderSpecifications = nullptr;

  /** iOS is always hardware-accelerated **/
  CFStringRef key = kVTVideoEncoderSpecification_EncoderID;
  CFStringRef value = CFSTR("com.apple.videotoolbox.videoencoder.h264.gva");

  CFStringRef bkey = CFSTR("EnableHardwareAcceleratedVideoEncoder");
  CFBooleanRef bvalue = kCFBooleanTrue;

  CFStringRef ckey = CFSTR("RequireHardwareAcceleratedVideoEncoder");
  CFBooleanRef cvalue = kCFBooleanTrue;

  encoderSpecifications = CFDictionaryCreateMutable(
          kCFAllocatorDefault,
          3,
          &kCFTypeDictionaryKeyCallBacks,
          &kCFTypeDictionaryValueCallBacks);

  CFDictionaryAddValue(encoderSpecifications, bkey, bvalue);
  CFDictionaryAddValue(encoderSpecifications, ckey, cvalue);
  CFDictionaryAddValue(encoderSpecifications, key, value);

  VTCompressionSessionRef session = nullptr;

  @autoreleasepool {

    NSDictionary* pixelBufferOptions = @{
      (NSString*) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
      (NSString*) kCVPixelBufferWidthKey: @(m_inputFrameW),
      (NSString*) kCVPixelBufferHeightKey: @(m_inputFrameH),
      (NSString*) kCVPixelBufferIOSurfacePropertiesKey : @{}
    };

    err = VTCompressionSessionCreate(
      kCFAllocatorDefault,
      m_outputFrameW,
      m_outputFrameH,
      kCMVideoCodecType_H264,
      encoderSpecifications,
      (__bridge CFDictionaryRef)pixelBufferOptions,
      NULL,
      &vtCallback,
      this,
      &session);
  }

  if (err == noErr) {
    m_compressionSession = session;

    const int32_t v = m_fps * 1; // 1-second kfi
    CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    err = VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, ref);
    CFRelease(ref);
  }

  if (err == noErr) {
    const int v = m_fps;
    CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ExpectedFrameRate, ref);
    CFRelease(ref);
  }

  if (err == noErr) {
    CFBooleanRef allowFrameReodering = useBaseline ? kCFBooleanFalse : kCFBooleanTrue;
    err = VTSessionSetProperty(session , kVTCompressionPropertyKey_AllowFrameReordering, allowFrameReodering);
  }

  if (err == noErr) {
    const int v = m_bitrate;
    CFNumberRef ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    err = VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, ref);
    CFRelease(ref);
  }

  if (err == noErr) {
    err = VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
  }

  if (err == noErr) {
    CFStringRef profileLevel = useBaseline ? kVTProfileLevel_H264_Baseline_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel;

    err = VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel, profileLevel);
  }

  if (!useBaseline) {
    VTSessionSetProperty(session, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC);
  }

  if (err == noErr) {
    VTCompressionSessionPrepareToEncodeFrames(session);
  }

  m_encodeMutex.unlock();
}

void H264Encoder::teardownCompressionSession()
{
  if (m_compressionSession) {
    VTCompressionSessionInvalidate((VTCompressionSessionRef)m_compressionSession);
    CFRelease((VTCompressionSessionRef)m_compressionSession);
  }
}
