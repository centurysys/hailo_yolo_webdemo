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

import std/random

import config
import jobs/[runner, store]
import util/paths
import web/server

when isMainModule:
  randomize()

  ensureWorkDirs(workRoot, uploadDir, jobsDir)
  let jobStore = newJobStore()
  let jobRunner = startJobRunner(jobStore)

  echo appName, " starting"
  echo "workRoot: ", workRoot
  echo "jobsDir : ", jobsDir
  echo "hefPath : ", hefPath

  try:
    startServer(jobStore)
  finally:
    jobRunner.close()
    jobStore.close()
