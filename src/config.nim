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
  liveExternalWorkerPath* = "/usr/local/bin/hailo-live-worker"
  liveExternalWorkerArgs* = "--input {input} --output {output}"
  liveSessionMode* = "in-process-ai"

  hefPath* = "/usr/local/share/hailo-demo/yolov11s.hef"
  fontPath* = "/usr/share/fonts/dejavu/DejaVuSans.ttf"

  maxJobsToKeep* = 20

proc getMediamtxPathctlPath*(): string =
  result = getEnv("HAILO_DEMO_MEDIAMTX_PATHCTL", mediamtxPathctlPath)

proc getLiveFfmpegPath*(): string =
  result = getEnv("HAILO_DEMO_LIVE_FFMPEG", liveFfmpegPath)

proc getLiveExternalWorkerPath*(): string =
  result = getEnv("HAILO_DEMO_LIVE_WORKER", liveExternalWorkerPath)

proc getLiveExternalWorkerArgs*(): string =
  result = getEnv("HAILO_DEMO_LIVE_WORKER_ARGS", liveExternalWorkerArgs)

proc getLiveSessionMode*(): string =
  ## The compact demo keeps the live worker inside the main web demo process by
  ## default, so the UI/API, file inference path, and live session controller can
  ## coordinate one HAILO device without an extra service process.
  ##
  ## Other modes are intentionally kept for comparison and bring-up:
  ##   mediamtx-proxy   MediaMTX path proxy only
  ##   ffmpeg-copy      external ffmpeg copy relay
  ##   external-worker  configurable worker command
  ##   in-process       internal ffmpeg-copy live worker thread
  ##   in-process-ai    internal RTSP -> HAILO -> overlay -> RTSP publisher
  result = getEnv("HAILO_DEMO_LIVE_SESSION_MODE", liveSessionMode)

proc getListenHost*(): string =
  ## Read at server startup time, not as a module-global let, so rebuild/run
  ## confusion is easier to diagnose and service environment changes are clear.
  result = getEnv("HAILO_DEMO_LISTEN_HOST", defaultListenHost)
