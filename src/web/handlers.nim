## HTTP handlers for Mummy.

import mummy
import std/[json, options, os, strformat, strutils, uri]

import ../config
import ../jobs/[runner, store]
import ../live/cameras
import ../types
import ../util/[ids, paths]
import ./pages
import ./api

var gStorePtr: pointer
var gCameraStorePtr: pointer

proc setJobStore*(store: JobStore) =
  ## Keep only an untraced pointer in global state so Mummy handler procs stay
  ## GC-safe.  The real JobStore ref is owned by main for the lifetime of
  ## server.serve(), and JobStore methods protect their Table with a Lock.
  gStorePtr = cast[pointer](store)

proc currentStore(): JobStore {.gcsafe.} =
  ## Mummy invokes handlers from worker threads and therefore requires
  ## GC-safe handlers.  Do not store a GC-managed JobStore ref directly in a
  ## global; keep a raw pointer and cast it back only at this boundary.
  {.cast(gcsafe).}:
    result = cast[JobStore](gStorePtr)

proc setLiveCameraStore*(store: LiveCameraStore) =
  ## Same pattern as JobStore: keep GC-managed refs out of globals that are
  ## accessed from GC-safe Mummy handlers.
  gCameraStorePtr = cast[pointer](store)

proc currentCameraStore(): LiveCameraStore {.gcsafe.} =
  {.cast(gcsafe).}:
    result = cast[LiveCameraStore](gCameraStorePtr)

proc respondText(request: Request, status: int, text: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/plain; charset=utf-8"
  request.respond(status, headers, text)

proc respondHtml(request: Request, status: int, html: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(status, headers, html)

proc respondJson(request: Request, status: int, json: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json; charset=utf-8"
  request.respond(status, headers, json)

proc getHeader(request: Request, name: string): string {.gcsafe.} =
  result = request.headers[name]
  if result.len == 0:
    result = request.headers[name.toLowerAscii]

proc queryValue(uri, key: string): string =
  let qMark = uri.find('?')
  if qMark < 0:
    return ""
  for part in uri[qMark + 1 .. ^1].split('&'):
    let eq = part.find('=')
    if eq < 0:
      if decodeUrl(part) == key:
        return ""
    else:
      let k = decodeUrl(part[0 ..< eq])
      if k == key:
        return decodeUrl(part[eq + 1 .. ^1])


proc clampInt(value, lo, hi: int): int =
  result = value
  if result < lo:
    result = lo
  if result > hi:
    result = hi

proc clampFloat32(value, lo, hi: float32): float32 =
  result = value
  if result < lo:
    result = lo
  if result > hi:
    result = hi

proc parseQueryInt(uri, key: string; defaultValue, lo, hi: int): int =
  let raw = queryValue(uri, key).strip()
  if raw.len == 0:
    return defaultValue
  try:
    result = parseInt(raw).clampInt(lo, hi)
  except ValueError:
    result = defaultValue

proc parseQueryFloat32(uri, key: string; defaultValue, lo, hi: float32): float32 =
  let raw = queryValue(uri, key).strip()
  if raw.len == 0:
    return defaultValue
  try:
    result = parseFloat(raw).float32.clampFloat32(lo, hi)
  except ValueError:
    result = defaultValue

proc parseMp4QualityPreset(rawValue: string): Mp4QualityPreset =
  case rawValue.strip().toLowerAscii()
  of "small", "small-file", "compact": mpqSmall
  of "balanced", "balance": mpqBalanced
  of "high", "high-quality", "quality": mpqHigh
  of "manual", "custom": mpqManual
  else: mpqAuto

proc parseOverlayPreset(rawValue: string): OverlayPreset =
  case rawValue.strip().toLowerAscii()
  of "light", "sparse": opLight
  of "rich", "dense": opRich
  of "boxes-only", "box", "boxes": opBoxesOnly
  of "manual", "custom": opManual
  else: opBalanced

proc parseManualBitrate(uri: string): int =
  ## The UI sends Mbps because that is easier to reason about from a browser.
  ## Clamp to the demo-friendly range accepted by the MP4 path.
  let raw = queryValue(uri, "manualBitrateMbps").strip()
  if raw.len == 0:
    return 0
  try:
    let mbps = parseFloat(raw)
    result = int(mbps * 1_000_000.0 + 0.5).clampInt(250_000, 20_000_000)
  except ValueError:
    result = 0

proc parseJobOptions(uri: string): JobOptions =
  result = defaultJobOptions()
  result.mp4Quality = parseMp4QualityPreset(queryValue(uri, "mp4Quality"))
  result.manualBitrate = parseManualBitrate(uri)
  result.overlayPreset = parseOverlayPreset(queryValue(uri, "overlayPreset"))

  ## Manual overlay knobs are only used when overlayPreset=manual.  Still parse
  ## them here so the media layer can stay free of HTTP/query-string logic.
  result.maxBoxes = parseQueryInt(uri, "maxBoxes", result.maxBoxes, 0, 200)
  result.maxLabels = parseQueryInt(uri, "maxLabels", result.maxLabels, 0, 200)
  result.minBoxScore = parseQueryFloat32(uri, "minBoxScore", result.minBoxScore, 0.0.float32, 1.0.float32)
  result.minLabelScore = parseQueryFloat32(uri, "minLabelScore", result.minLabelScore, 0.0.float32, 1.0.float32)

proc trailingPathSegment(path, prefix: string): string =
  if path.startsWith(prefix):
    result = path[prefix.len .. ^1]
  else:
    result = ""
  result = result.strip(chars = {'/'})

proc outputContentType(job: JobInfo): string =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  case ext
  of ".jpg", ".jpeg": "image/jpeg"
  of ".mp4", ".m4v": "video/mp4"
  else: job.kind.contentType

proc outputFilename(job: JobInfo): string =
  let ext = job.outputPath.splitFile.ext.toLowerAscii()
  if job.kind == jkMp4 and ext in [".jpg", ".jpeg"]:
    "preview.jpg"
  else:
    "output" & job.kind.extension

proc handleIndex*(request: Request) {.gcsafe.} =
  request.respondHtml(200, renderIndexPage())

proc handleLive*(request: Request) {.gcsafe.} =
  request.respondHtml(200, renderLivePage())

proc respondAsset(request: Request; contentType, body: string) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = contentType
  headers["Cache-Control"] = "no-store"
  request.respond(200, headers, body)

proc handleDemoCss*(request: Request) {.gcsafe.} =
  request.respondAsset("text/css; charset=utf-8", demoCss())

proc handleIndexJs*(request: Request) {.gcsafe.} =
  request.respondAsset("application/javascript; charset=utf-8", indexJs())

proc handleLiveJs*(request: Request) {.gcsafe.} =
  request.respondAsset("application/javascript; charset=utf-8", liveJs())

proc handleWaitJs*(request: Request) {.gcsafe.} =
  request.respondAsset("application/javascript; charset=utf-8", waitJs())

proc handleResultViewerJs*(request: Request) {.gcsafe.} =
  request.respondAsset("application/javascript; charset=utf-8", resultViewerJs())

proc handleMissingPico*(request: Request) {.gcsafe.} =
  ## Keep standalone development harmless when Pico CSS has not been installed
  ## under nginx yet.  The app-specific fallback CSS still makes the page usable.
  var headers: HttpHeaders
  headers["Content-Type"] = "text/css; charset=utf-8"
  request.respond(200, headers, "/* pico.min.css is expected to be served by nginx in the final package. */\n")

proc handleUpload*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  try:
    let qFilename = queryValue(request.uri, "filename")
    let rawOriginalName =
      if qFilename.len > 0: qFilename
      else: getHeader(request, "X-Upload-Filename")
    let originalName = sanitizeFilename(rawOriginalName)
    let kind = detectJobKind(originalName)
    let jobId = newJobId()

    ensureJobDir(jobsDir, jobId)
    let input = inputPath(jobsDir, jobId, kind)
    let output = outputPath(jobsDir, jobId, kind)

    let nginxFile = getHeader(request, "X-FILE")
    if nginxFile.len > 0:
      if not fileExists(nginxFile):
        raise newException(IOError, &"X-FILE path does not exist: {nginxFile}")
      moveOrCopyFile(nginxFile, input)
    else:
      ## Development path when directly PUT-ing to Mummy without nginx.
      if request.body.len == 0:
        raise newException(ValueError, "missing X-FILE header and empty request body")
      writeFile(input, request.body)

    let options = parseJobOptions(request.uri)
    let job = store.createJob(jobId, kind, input, output, originalName, options)
    store.enqueueJob(job.id)

    request.respondJson(200, uploadJson(job))
  except CatchableError as e:
    request.respondHtml(400, renderErrorPage(e.msg))

proc handleWait*(request: Request) {.gcsafe.} =
  let jobId = trailingPathSegment(request.path, "/wait/")
  if jobId.len == 0:
    request.respondHtml(404, renderErrorPage("missing job id"))
    return
  request.respondHtml(200, renderWaitPage(jobId))

proc handleApiJob*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/api/jobs/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  request.respondJson(200, jobJson(maybeJob.get))

proc handleApiLiveCameras*(request: Request) {.gcsafe.} =
  let store = currentCameraStore()
  if store == nil:
    request.respondText(500, "live camera store is not initialized")
    return

  request.respondJson(200, store.camerasJson())

proc handleApiLiveCameraSet*(request: Request) {.gcsafe.} =
  let store = currentCameraStore()
  if store == nil:
    request.respondText(500, "live camera store is not initialized")
    return

  let cameraId = trailingPathSegment(request.path, "/api/live/cameras/")
  if cameraId.len == 0:
    request.respondText(404, "missing camera id")
    return

  try:
    request.respondJson(200, store.setCameraJson(cameraId, request.body))
  except ValueError as e:
    request.respondText(400, e.msg)
  except JsonParsingError as e:
    request.respondText(400, e.msg)
  except CatchableError as e:
    request.respondText(500, e.msg)

proc handleApiLiveCameraDelete*(request: Request) {.gcsafe.} =
  let store = currentCameraStore()
  if store == nil:
    request.respondText(500, "live camera store is not initialized")
    return

  let cameraId = trailingPathSegment(request.path, "/api/live/cameras/")
  if cameraId.len == 0:
    request.respondText(404, "missing camera id")
    return

  try:
    request.respondJson(200, store.deleteCameraJson(cameraId))
  except ValueError as e:
    request.respondText(400, e.msg)
  except CatchableError as e:
    request.respondText(500, e.msg)


proc handlePreview*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/preview/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  let path = previewPath(jobsDir, jobId)
  if not fileExists(path):
    request.respondText(404, "preview not available")
    return

  var headers: HttpHeaders
  headers["Content-Type"] = "image/jpeg"
  headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
  headers["Pragma"] = "no-cache"
  request.respond(200, headers, readFile(path))

proc handleResult*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondHtml(500, renderErrorPage("job store is not initialized"))
    return

  let jobId = trailingPathSegment(request.path, "/result/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondHtml(404, renderErrorPage("job not found"))
    return

  request.respondHtml(200, renderResultPage(maybeJob.get))

proc handleFile*(request: Request) {.gcsafe.} =
  let store = currentStore()
  if store == nil:
    request.respondText(500, "job store is not initialized")
    return

  let jobId = trailingPathSegment(request.path, "/files/")
  let maybeJob = store.getJob(jobId)
  if maybeJob.isNone:
    request.respondText(404, "job not found")
    return

  let job = maybeJob.get
  if job.status != jsDone:
    request.respondText(409, "job is not done")
    return
  if not fileExists(job.outputPath):
    request.respondText(404, "output file not found")
    return

  var headers: HttpHeaders
  headers["Content-Type"] = job.outputContentType
  headers["Content-Disposition"] = &"inline; filename=\"{job.outputFilename}\""
  request.respond(200, headers, readFile(job.outputPath))

proc handleNotFound*(request: Request) {.gcsafe.} =
  request.respondHtml(404, renderErrorPage("not found"))
