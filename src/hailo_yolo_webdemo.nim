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
import live/[cameras, live_target]
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
  let cameraStore = newLiveCameraStore(liveCameraConfigPath, mediamtxPathctlPath)
  let targetStore = newLiveTargetStore(liveTargetConfigPath)
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

  try:
    startServer(jobStore, cameraStore, targetStore)
  finally:
    jobRunner.close()
    targetStore.close()
    cameraStore.close()
    jobStore.close()
