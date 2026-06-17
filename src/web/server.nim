## Mummy server setup.

import std/os
import std/net

import mummy, mummy/routers

import ../config
import ../jobs/store
import ../live/cameras
import ./handlers

proc startServer*(jobStore: JobStore; cameraStore: LiveCameraStore) =
  setJobStore(jobStore)
  setLiveCameraStore(cameraStore)

  var router: Router
  router.get("/", handleIndex)
  router.put("/upload", handleUpload)
  router.get("/wait/*", handleWait)
  router.get("/api/jobs/*", handleApiJob)
  router.get("/api/live/cameras", handleApiLiveCameras)
  router.put("/api/live/cameras/*", handleApiLiveCameraSet)
  router.delete("/api/live/cameras/*", handleApiLiveCameraDelete)
  router.get("/result/*", handleResult)
  router.get("/preview/*", handlePreview)
  router.get("/files/*", handleFile)
  router.get("/static/demo.css", handleDemoCss)
  router.get("/static/index.js", handleIndexJs)
  router.get("/static/wait.js", handleWaitJs)
  router.get("/static/result-viewer.js", handleResultViewerJs)
  router.get("/static/pico.min.css", handleMissingPico)
  router.get("/*", handleNotFound)

  let bindHost = getListenHost()

  echo "HAILO_DEMO_LISTEN_HOST=", getEnv("HAILO_DEMO_LISTEN_HOST", "<unset>")
  echo "Serving on http://", bindHost, ":", listenPort

  let server = newServer(router, workerThreads = workerThreads)
  server.serve(Port(listenPort), bindHost)
