## Runtime configuration for hailo-yolo-webdemo.
##
## During direct bring-up, binding to 0.0.0.0 is convenient.  Once nginx is
## placed in front of this app, set HAILO_DEMO_LISTEN_HOST=127.0.0.1 in the
## service environment.

import std/os

const
  appName* = "hailo-yolo-webdemo"

  defaultListenHost* = "0.0.0.0"
  listenPort* = 18080
  workerThreads* = 4

  workRoot* = "/var/tmp/hailo-demo"
  uploadDir* = workRoot & "/upload"
  jobsDir* = workRoot & "/jobs"

  stateRoot* = "/var/lib/hailo-demo"
  liveCameraConfigPath* = stateRoot & "/live-cameras.json"
  liveTargetConfigPath* = stateRoot & "/live-target.json"
  mediamtxPathctlPath* = "/usr/local/sbin/mediamtx-pathctl"
  liveRtspBaseUrl* = "rtsp://127.0.0.1:8554"
  liveFfmpegPath* = "/usr/bin/ffmpeg"
  liveSessionMode* = "mediamtx-proxy"

  hefPath* = "/usr/local/share/hailo-demo/yolov11s.hef"
  fontPath* = "/usr/share/fonts/dejavu/DejaVuSans.ttf"

  maxJobsToKeep* = 20

proc getMediamtxPathctlPath*(): string =
  result = getEnv("HAILO_DEMO_MEDIAMTX_PATHCTL", mediamtxPathctlPath)

proc getLiveFfmpegPath*(): string =
  result = getEnv("HAILO_DEMO_LIVE_FFMPEG", liveFfmpegPath)

proc getLiveSessionMode*(): string =
  ## mediamtx-proxy keeps the proven zero-process relay as the safe default.
  ## Set HAILO_DEMO_LIVE_SESSION_MODE=ffmpeg-copy to exercise a long-running
  ## RTSP read/publish relay process before wiring in the real inference worker.
  result = getEnv("HAILO_DEMO_LIVE_SESSION_MODE", liveSessionMode)

proc getListenHost*(): string =
  ## Read at server startup time, not as a module-global let, so rebuild/run
  ## confusion is easier to diagnose and service environment changes are clear.
  result = getEnv("HAILO_DEMO_LISTEN_HOST", defaultListenHost)
