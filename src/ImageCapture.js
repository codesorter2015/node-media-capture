import EventTarget from './EventTarget';
//import SourceManager from './SourceManager';

let privateData = new WeakMap();

export default class ImageCapture extends EventTarget {
  constructor (track) {
    super();
    privateData.set(this, {
      videoStreamTrack: track,
      photoCapabilities: null,
      previewStream: null
    });
  }

  get videoStreamTrack() {
    return privateData.get(this).videoStreamTrack;
  }

  get photoCapabilities() {
    return privateData.get(this).photoCapabilities;
  }

  get previewStream() {
    return privateData.get(this).previewStream;
  }

  setOptions(photoSettings) {
    void photoSettings;
  }

  takePhoto() {
    let source = privateData.get(this).videoStreamTrack.source;
    return source.hal.takeSnapshot(source.deviceId);
  }

  grabFrame() {
  }
}
