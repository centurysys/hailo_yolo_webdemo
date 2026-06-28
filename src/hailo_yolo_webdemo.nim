## hailo-yolo-webdemo entry point.
##
## Current target:
##   - Mummy web server
##   - nginx X-FILE compatible upload endpoint
##   - /var/tmp/hailo-demo job directory layout
##   - in-memory job store
##   - background job runner using threadtools.ThreadQueue
##   - HAILO detector preloaded in the job worker thread
##   - JPEG YOLOv11s inference via HAILO-8L
##   - Pixie bbox/label overlay and hyper_jpeg output

import std/[os, random]

import config
import jobs/[runner, store]
import live/[cameras, live_infer_owner, live_session, live_target, settings]
import util/paths
import web/server

when isMainModule:
  randomize()

  ensureWorkDirs(workRoot, uploadDir, jobsDir)
  createDir(stateRoot)
  let removedOldJobDirs = cleanupJobDirs(jobsDir)
  if removedOldJobDirs > 0:
    echo "removed old job directories at startup: ", removedOldJobDirs

  let jobStore = newJobStore()
  let pathctlPath = getMediamtxPathctlPath()
  let cameraStore = newLiveCameraStore(
    liveCameraConfigPath,
    pathctlPath,
    getLiveFfmpegPath(),
    liveRtspBaseUrl
  )
  let targetStore = newLiveTargetStore(liveTargetConfigPath)
  let settingsStore = newLiveSettingsStore(liveSettingsConfigPath)
  let liveOwner = startLiveInferOwner()
  let sessionController = newLiveSessionController(
    liveRtspBaseUrl,
    pathctlPath,
    getLiveFfmpegPath(),
    getLiveExternalWorkerPath(),
    getLiveExternalWorkerArgs(),
    getLiveSessionMode(),
    liveOwner
  )
  let syncResults = cameraStore.syncEnabledCameras()
  for item in syncResults:
    if item.mediamtx.ok:
      echo "synced live camera path: ", item.slot.id
    else:
      echo "warning: failed to sync live camera path ", item.slot.id, ": ", item.mediamtx.message

  let jobRunner = startJobRunner(jobStore)

  echo appName, " starting"
  echo "workRoot: ", workRoot
  echo "jobsDir : ", jobsDir
  echo "hefPath : ", hefPath
  echo "cameraConfigPath: ", liveCameraConfigPath
  echo "liveTargetConfigPath: ", liveTargetConfigPath
  echo "liveSettingsConfigPath: ", liveSettingsConfigPath
  echo "liveRtspBaseUrl: ", liveRtspBaseUrl
  echo "liveSessionMode: ", getLiveSessionMode()
  echo "liveFfmpeg: ", getLiveFfmpegPath()
  echo "liveExternalWorker: ", getLiveExternalWorkerPath()
  echo "liveExternalWorkerArgs: ", getLiveExternalWorkerArgs()
  echo "liveInferOwner: started"
  echo "mediamtxPathctl: ", pathctlPath

  try:
    startServer(jobStore, cameraStore, targetStore, settingsStore, sessionController)
  finally:
    jobRunner.close()
    sessionController.close()
    liveOwner.close()
    settingsStore.close()
    targetStore.close()
    cameraStore.close()
    jobStore.close()
