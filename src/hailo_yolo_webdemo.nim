## hailo-yolo-webdemo entry point.
##
## Step 1 target:
##   - Mummy web server
##   - nginx X-FILE compatible upload endpoint
##   - /var/tmp/hailo-demo job directory layout
##   - in-memory job store
##   - dummy runner that copies input to output
##
## HAILO, Pixie, JPEG decode/encode and MP4 pipeline will be introduced in
## later steps without changing the public web routes.

import std/random

import config
import jobs/store
import util/paths
import web/server

when isMainModule:
  randomize()

  ensureWorkDirs(workRoot, uploadDir, jobsDir)
  let jobStore = newJobStore()

  echo appName, " starting"
  echo "workRoot: ", workRoot
  echo "jobsDir : ", jobsDir

  startServer(jobStore)
