## Live inference session control.
##
## This step keeps the existing MediaMTX proxy relay mode, ffmpeg copy-relay
## mode, external-worker mode, and in-process mode.  The in-process worker now
## exposes relay status and optional async live inference monitor status while
## /api/live/session is polled.

import std/[json, locks, os, osproc, streams, strformat, strutils, times]

import ./cameras
import ./live_target
import ./in_process_worker
import ./live_infer_owner
import ./settings
import ../types

const
  defaultRtspBaseUrl* = "rtsp://127.0.0.1:8554"
  defaultPathctlPath* = "/usr/local/sbin/mediamtx-pathctl"
  defaultFfmpegPath* = "/usr/bin/ffmpeg"
  defaultExternalWorkerPath* = "/usr/local/bin/hailo-live-worker"
  defaultExternalWorkerArgs* = "--input {input} --output {output}"
  defaultSessionMode* = "in-process"

type
  LiveSessionState* = object
    status*: string
    running*: bool
    mode*: string
    selectedCameraId*: string
    selectedCameraName*: string
    inputMediamtxPath*: string
    inputRtspUrl*: string
    outputMediamtxPath*: string
    outputRtspUrl*: string
    aiWebrtcPath*: string
    relayPid*: int
    relayCommand*: string
    relayArgs*: seq[string]
    lastExitCode*: int
    decodeProbeAttempted*: bool
    decodeProbeOk*: bool
    decodeProbeFrames*: int
    decodeProbeWidth*: int
    decodeProbeHeight*: int
    decodeProbeMs*: int
    decodeProbeMessage*: string
    liveInferAttempted*: bool
    liveInferOk*: bool
    liveInferFrames*: int
    liveInferWidth*: int
    liveInferHeight*: int
    liveInferDetections*: int
    liveInferMaxScorePercent*: int
    liveInferThroughputFps*: float64
    liveInferProcessingMs*: int
    liveInferReadMs*: int
    liveInferLetterboxMs*: int
    liveInferWaitMs*: int
    liveInferHailoWriteUs*: int64
    liveInferHailoReadUs*: int64
    liveInferMessage*: string
    message*: string
    startedAt*: string
    stoppedAt*: string

  PathctlResult = object
    ok: bool
    message: string
    exitCode: int

  LiveSessionController* = ref object
    lock: Lock
    rtspBaseUrl: string
    pathctlPath: string
    ffmpegPath: string
    externalWorkerPath: string
    externalWorkerArgsTemplate: string
    sessionMode: string
    relayProcess: Process
    inProcessWorker: InProcessLiveWorker
    retiredInProcessWorkers: seq[InProcessLiveWorker]
    liveInferOwner: LiveInferOwner
    state: LiveSessionState

proc utcStamp(): string =
  result = now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc normalizeBaseUrl(value: string): string =
  result = value.strip()
  if result.len == 0:
    result = defaultRtspBaseUrl
  while result.endsWith("/"):
    result.setLen(result.len - 1)

proc mediaPathUrl(baseUrl, path: string): string =
  let cleanBase = normalizeBaseUrl(baseUrl)
  let cleanPath = path.strip(chars = {'/'})
  &"{cleanBase}/{cleanPath}"

proc sanitizeExecutablePath(value, defaultValue: string): string =
  result = value.strip()
  if result.len == 0:
    result = defaultValue

proc sanitizeArgTemplate(value, defaultValue: string): string =
  result = value.strip()
  if result.len == 0:
    result = defaultValue

proc splitArgsTemplate(argsTemplate: string): seq[string] =
  ## Keep this intentionally simple.  Current RTSP URLs and paths do not contain
  ## whitespace, and avoiding shell parsing keeps the service behavior explicit.
  ## If a future worker needs complex quoting, add a small argv file or JSON
  ## config instead of routing through /bin/sh.
  for part in argsTemplate.splitWhitespace():
    if part.len > 0:
      result.add(part)

proc expandWorkerArg(
    value: string;
    inputRtsp, outputRtsp: string;
    slot: CameraSlot;
    outputPath: string
  ): string =
  result = value
  result = result.replace("{input}", inputRtsp)
  result = result.replace("{inputRtsp}", inputRtsp)
  result = result.replace("{output}", outputRtsp)
  result = result.replace("{outputRtsp}", outputRtsp)
  result = result.replace("{cameraId}", slot.id)
  result = result.replace("{cameraName}", slot.name)
  result = result.replace("{inputPath}", slot.mediamtxPath)
  result = result.replace("{outputPath}", outputPath)

proc expandWorkerArgs(
    argsTemplate: string;
    inputRtsp, outputRtsp: string;
    slot: CameraSlot;
    outputPath: string
  ): seq[string] =
  for part in splitArgsTemplate(argsTemplate):
    result.add(expandWorkerArg(part, inputRtsp, outputRtsp, slot, outputPath))

proc normalizeSessionMode(value: string): string =
  let mode = value.strip().toLowerAscii()
  case mode
  of "", "proxy", "mediamtx", "mediamtx-proxy":
    result = "mediamtx-proxy"
  of "ffmpeg", "ffmpeg-copy", "copy":
    result = "ffmpeg-copy"
  of "external", "external-worker", "worker", "live-worker":
    result = "external-worker"
  of "in-process-ai", "inprocess-ai", "internal-ai", "thread-ai", "threaded-ai", "ai", "ai-overlay", "live-ai":
    result = "in-process-ai"
  of "in-process", "inprocess", "internal", "thread", "threaded":
    result = "in-process"
  else:
    raise newException(ValueError, &"invalid live session mode: {value}")

proc defaultState(rtspBaseUrl: string): LiveSessionState =
  let aiPath = defaultAiMediamtxPath
  LiveSessionState(
    status: "stopped",
    running: false,
    mode: "none",
    selectedCameraId: "",
    selectedCameraName: "",
    inputMediamtxPath: "",
    inputRtspUrl: "",
    outputMediamtxPath: aiPath,
    outputRtspUrl: mediaPathUrl(rtspBaseUrl, aiPath),
    aiWebrtcPath: &"/{aiPath}",
    relayPid: 0,
    relayCommand: "",
    relayArgs: @[],
    lastExitCode: 0,
    message: "live inference pipeline is stopped",
    startedAt: "",
    stoppedAt: ""
  )

proc sessionToJson(state: LiveSessionState): JsonNode =
  result = newJObject()
  result["status"] = %state.status
  result["running"] = %state.running
  result["mode"] = %state.mode
  result["selectedCameraId"] = %state.selectedCameraId
  result["selectedCameraName"] = %state.selectedCameraName
  result["inputMediamtxPath"] = %state.inputMediamtxPath
  result["inputRtspUrl"] = %state.inputRtspUrl
  result["outputMediamtxPath"] = %state.outputMediamtxPath
  result["outputRtspUrl"] = %state.outputRtspUrl
  result["aiWebrtcPath"] = %state.aiWebrtcPath
  result["relayPid"] = %state.relayPid
  result["relayCommand"] = %state.relayCommand
  result["relayArgs"] = %state.relayArgs
  result["lastExitCode"] = %state.lastExitCode
  result["decodeProbeAttempted"] = %state.decodeProbeAttempted
  result["decodeProbeOk"] = %state.decodeProbeOk
  result["decodeProbeFrames"] = %state.decodeProbeFrames
  result["decodeProbeWidth"] = %state.decodeProbeWidth
  result["decodeProbeHeight"] = %state.decodeProbeHeight
  result["decodeProbeMs"] = %state.decodeProbeMs
  result["decodeProbeMessage"] = %state.decodeProbeMessage
  result["liveInferAttempted"] = %state.liveInferAttempted
  result["liveInferOk"] = %state.liveInferOk
  result["liveInferFrames"] = %state.liveInferFrames
  result["liveInferWidth"] = %state.liveInferWidth
  result["liveInferHeight"] = %state.liveInferHeight
  result["liveInferDetections"] = %state.liveInferDetections
  result["liveInferMaxScorePercent"] = %state.liveInferMaxScorePercent
  result["liveInferThroughputFps"] = %state.liveInferThroughputFps
  result["liveInferProcessingMs"] = %state.liveInferProcessingMs
  result["liveInferReadMs"] = %state.liveInferReadMs
  result["liveInferLetterboxMs"] = %state.liveInferLetterboxMs
  result["liveInferWaitMs"] = %state.liveInferWaitMs
  result["liveInferHailoWriteUs"] = %state.liveInferHailoWriteUs
  result["liveInferHailoReadUs"] = %state.liveInferHailoReadUs
  result["liveInferMessage"] = %state.liveInferMessage
  result["message"] = %state.message
  result["startedAt"] = %state.startedAt
  result["stoppedAt"] = %state.stoppedAt

proc markStoppedLocked(controller: LiveSessionController; message: string; status = "stopped") =
  let outputPath = if controller.state.outputMediamtxPath.len > 0: controller.state.outputMediamtxPath else: defaultAiMediamtxPath
  controller.state.status = status
  controller.state.running = false
  controller.state.mode = "none"
  controller.state.message = message
  controller.state.inputMediamtxPath = ""
  controller.state.inputRtspUrl = ""
  controller.state.outputMediamtxPath = outputPath
  controller.state.outputRtspUrl = mediaPathUrl(controller.rtspBaseUrl, outputPath)
  controller.state.aiWebrtcPath = &"/{outputPath}"
  controller.state.relayPid = 0
  controller.state.relayCommand = ""
  controller.state.relayArgs = @[]
  controller.state.decodeProbeAttempted = false
  controller.state.decodeProbeOk = false
  controller.state.decodeProbeFrames = 0
  controller.state.decodeProbeWidth = 0
  controller.state.decodeProbeHeight = 0
  controller.state.decodeProbeMs = 0
  controller.state.decodeProbeMessage = ""
  controller.state.liveInferAttempted = false
  controller.state.liveInferOk = false
  controller.state.liveInferFrames = 0
  controller.state.liveInferWidth = 0
  controller.state.liveInferHeight = 0
  controller.state.liveInferDetections = 0
  controller.state.liveInferMaxScorePercent = 0
  controller.state.liveInferThroughputFps = 0.0
  controller.state.liveInferProcessingMs = 0
  controller.state.liveInferReadMs = 0
  controller.state.liveInferLetterboxMs = 0
  controller.state.liveInferWaitMs = 0
  controller.state.liveInferHailoWriteUs = 0
  controller.state.liveInferHailoReadUs = 0
  controller.state.liveInferMessage = ""
  controller.state.stoppedAt = utcStamp()

proc refreshProcessStateLocked(controller: LiveSessionController) =
  if controller.relayProcess.isNil:
    return
  if not (controller.state.mode in ["ffmpeg-copy", "external-worker"]):
    return
  if controller.state.running and not controller.relayProcess.running():
    let code = controller.relayProcess.waitForExit()
    controller.relayProcess.close()
    controller.relayProcess = nil
    controller.state.lastExitCode = code
    controller.state.status = "error"
    controller.state.running = false
    controller.state.message = &"{controller.state.mode} process exited with code {code}"
    controller.state.stoppedAt = utcStamp()

proc refreshInProcessStateLocked(controller: LiveSessionController) =
  if controller.inProcessWorker.isNil:
    return
  if not (controller.state.mode in ["in-process", "in-process-ai"]):
    return

  let snap = controller.inProcessWorker.snapshot()
  controller.state.relayPid = snap.relayPid
  controller.state.lastExitCode = snap.exitCode
  controller.state.decodeProbeAttempted = snap.decodeProbeAttempted
  controller.state.decodeProbeOk = snap.decodeProbeOk
  controller.state.decodeProbeFrames = snap.decodeProbeFrames
  controller.state.decodeProbeWidth = snap.decodeProbeWidth
  controller.state.decodeProbeHeight = snap.decodeProbeHeight
  controller.state.decodeProbeMs = snap.decodeProbeMs
  controller.state.decodeProbeMessage = snap.decodeProbeMessage
  controller.state.liveInferAttempted = snap.liveInferAttempted
  controller.state.liveInferOk = snap.liveInferOk
  controller.state.liveInferFrames = snap.liveInferFrames
  controller.state.liveInferWidth = snap.liveInferWidth
  controller.state.liveInferHeight = snap.liveInferHeight
  controller.state.liveInferDetections = snap.liveInferDetections
  controller.state.liveInferMaxScorePercent = snap.liveInferMaxScorePercent
  controller.state.liveInferThroughputFps = snap.liveInferThroughputFps
  controller.state.liveInferProcessingMs = snap.liveInferProcessingMs
  controller.state.liveInferReadMs = snap.liveInferReadMs
  controller.state.liveInferLetterboxMs = snap.liveInferLetterboxMs
  controller.state.liveInferWaitMs = snap.liveInferWaitMs
  controller.state.liveInferHailoWriteUs = snap.liveInferHailoWriteUs
  controller.state.liveInferHailoReadUs = snap.liveInferHailoReadUs
  controller.state.liveInferMessage = snap.liveInferMessage
  if snap.message.len > 0:
    controller.state.message = snap.message

  if controller.state.running and snap.finished:
    controller.state.running = false
    controller.state.status = if snap.exitCode == 0: "stopped" else: "error"
    controller.state.stoppedAt = utcStamp()

proc refreshLiveStateLocked(controller: LiveSessionController) =
  controller.refreshProcessStateLocked()
  controller.refreshInProcessStateLocked()

proc runPathctl(controller: LiveSessionController; args: seq[string]): PathctlResult =
  if not fileExists(controller.pathctlPath):
    return PathctlResult(
      ok: false,
      message: &"mediamtx-pathctl not found: {controller.pathctlPath}",
      exitCode: 127
    )

  var process: Process
  try:
    process = startProcess(
      controller.pathctlPath,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    let output = process.outputStream.readAll().strip()
    let code = process.waitForExit()
    process.close()
    process = nil

    result.exitCode = code
    result.message = output
    result.ok = code == 0
  except CatchableError as e:
    if process != nil:
      process.close()
    result = PathctlResult(ok: false, message: e.msg, exitCode: -1)

proc deleteOutputPath(controller: LiveSessionController; outputPath: string): PathctlResult =
  result = controller.runPathctl(@["delete", outputPath])
  if not result.ok:
    let lower = result.message.toLowerAscii()
    if "404" in lower or "not found" in lower:
      result.ok = true
      result.message = "path was already absent"
      result.exitCode = 0

proc ffmpegCopyArgs(inputRtsp, outputRtsp: string): seq[string] =
  @[
    "-nostdin",
    "-hide_banner",
    "-loglevel", "warning",
    "-rtsp_transport", "tcp",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-i", inputRtsp,
    "-an",
    "-c:v", "copy",
    "-rtsp_transport", "tcp",
    "-f", "rtsp",
    outputRtsp
  ]

proc startFfmpegCopyRelayLocked(
    controller: LiveSessionController;
    slot: CameraSlot;
    inputRtsp, outputPath, outputRtsp: string
  ) =
  if controller.ffmpegPath.contains("/") and not fileExists(controller.ffmpegPath):
    raise newException(IOError, &"ffmpeg not found: {controller.ffmpegPath}")

  discard controller.deleteOutputPath(outputPath)

  let args = ffmpegCopyArgs(inputRtsp, outputRtsp)
  controller.state = LiveSessionState(
    status: "starting",
    running: false,
    mode: "ffmpeg-copy",
    selectedCameraId: slot.id,
    selectedCameraName: slot.name,
    inputMediamtxPath: slot.mediamtxPath,
    inputRtspUrl: inputRtsp,
    outputMediamtxPath: outputPath,
    outputRtspUrl: outputRtsp,
    aiWebrtcPath: &"/{outputPath}",
    relayPid: 0,
    relayCommand: controller.ffmpegPath,
    relayArgs: args,
    lastExitCode: 0,
    message: &"starting ffmpeg copy relay: /{slot.mediamtxPath} -> /{outputPath}",
    startedAt: utcStamp(),
    stoppedAt: ""
  )

  try:
    controller.relayProcess = startProcess(
      controller.ffmpegPath,
      args = args,
      options = {poUsePath, poParentStreams}
    )
    controller.state.relayPid = controller.relayProcess.processID()
    controller.state.status = "running"
    controller.state.running = true
    controller.state.message = &"ffmpeg copy relay is publishing /{slot.mediamtxPath} to /{outputPath}; inference worker is not connected yet"
  except CatchableError as e:
    if controller.relayProcess != nil:
      controller.relayProcess.close()
      controller.relayProcess = nil
    controller.state.status = "error"
    controller.state.running = false
    controller.state.lastExitCode = -1
    controller.state.message = &"failed to start ffmpeg copy relay: {e.msg}"
    controller.state.stoppedAt = utcStamp()


proc startInProcessWorkerLocked(
    controller: LiveSessionController;
    slot: CameraSlot;
    inputRtsp, outputPath, outputRtsp: string
  ) =
  discard controller.deleteOutputPath(outputPath)

  controller.state = LiveSessionState(
    status: "starting",
    running: false,
    mode: "in-process",
    selectedCameraId: slot.id,
    selectedCameraName: slot.name,
    inputMediamtxPath: slot.mediamtxPath,
    inputRtspUrl: inputRtsp,
    outputMediamtxPath: outputPath,
    outputRtspUrl: outputRtsp,
    aiWebrtcPath: &"/{outputPath}",
    relayPid: 0,
    relayCommand: "in-process-ffmpeg-copy",
    relayArgs: ffmpegCopyArgs(inputRtsp, outputRtsp),
    lastExitCode: 0,
    message: &"starting in-process live worker copy relay: /{slot.mediamtxPath} -> /{outputPath}",
    startedAt: utcStamp(),
    stoppedAt: ""
  )

  try:
    controller.inProcessWorker = startInProcessLiveWorker(
      inputRtsp,
      outputRtsp,
      slot.id,
      slot.name,
      controller.ffmpegPath,
      liveInferOwner = controller.liveInferOwner
    )
    let snap = controller.inProcessWorker.snapshot()
    controller.state.relayPid = snap.relayPid
    controller.state.lastExitCode = snap.exitCode
    controller.state.decodeProbeAttempted = snap.decodeProbeAttempted
    controller.state.decodeProbeOk = snap.decodeProbeOk
    controller.state.decodeProbeFrames = snap.decodeProbeFrames
    controller.state.decodeProbeWidth = snap.decodeProbeWidth
    controller.state.decodeProbeHeight = snap.decodeProbeHeight
    controller.state.decodeProbeMs = snap.decodeProbeMs
    controller.state.decodeProbeMessage = snap.decodeProbeMessage
    controller.state.liveInferAttempted = snap.liveInferAttempted
    controller.state.liveInferOk = snap.liveInferOk
    controller.state.liveInferFrames = snap.liveInferFrames
    controller.state.liveInferWidth = snap.liveInferWidth
    controller.state.liveInferHeight = snap.liveInferHeight
    controller.state.liveInferDetections = snap.liveInferDetections
    controller.state.liveInferMaxScorePercent = snap.liveInferMaxScorePercent
    controller.state.liveInferThroughputFps = snap.liveInferThroughputFps
    controller.state.liveInferProcessingMs = snap.liveInferProcessingMs
    controller.state.liveInferReadMs = snap.liveInferReadMs
    controller.state.liveInferLetterboxMs = snap.liveInferLetterboxMs
    controller.state.liveInferWaitMs = snap.liveInferWaitMs
    controller.state.liveInferHailoWriteUs = snap.liveInferHailoWriteUs
    controller.state.liveInferHailoReadUs = snap.liveInferHailoReadUs
    controller.state.liveInferMessage = snap.liveInferMessage
    controller.state.status = "running"
    controller.state.running = true
    controller.state.message = &"in-process live worker is starting /{slot.mediamtxPath} -> /{outputPath} with ffmpeg copy relay; inference stage is not connected yet"
  except CatchableError as e:
    if controller.inProcessWorker != nil:
      let oldWorker = controller.inProcessWorker
      try:
        oldWorker.close()
      except CatchableError:
        discard
      controller.retiredInProcessWorkers.add(oldWorker)
      controller.inProcessWorker = nil
    controller.state.status = "error"
    controller.state.running = false
    controller.state.lastExitCode = -1
    controller.state.message = &"failed to start in-process live worker: {e.msg}"
    controller.state.stoppedAt = utcStamp()


proc startInProcessAiWorkerLocked(
    controller: LiveSessionController;
    slot: CameraSlot;
    inputRtsp, outputPath, outputRtsp: string;
    liveSettings: LiveSettingsState
  ) =
  discard controller.deleteOutputPath(outputPath)

  let args = @[
    "--input", inputRtsp,
    "--output", outputRtsp,
    "--decoder", getEnv("HAILO_DEMO_LIVE_DECODER", "h264_v4l2m2m"),
    "--debug-overlay", $liveSettings.debugOverlay,
    "--overlay-preset", liveSettings.overlayPreset.toWire
  ]

  controller.state = LiveSessionState(
    status: "starting",
    running: false,
    mode: "in-process-ai",
    selectedCameraId: slot.id,
    selectedCameraName: slot.name,
    inputMediamtxPath: slot.mediamtxPath,
    inputRtspUrl: inputRtsp,
    outputMediamtxPath: outputPath,
    outputRtspUrl: outputRtsp,
    aiWebrtcPath: &"/{outputPath}",
    relayPid: 0,
    relayCommand: "in-process-ai-overlay",
    relayArgs: args,
    lastExitCode: 0,
    message: &"starting in-process AI overlay pipeline: /{slot.mediamtxPath} -> /{outputPath} debugOverlay={liveSettings.debugOverlay} overlayPreset={liveSettings.overlayPreset.toWire}",
    startedAt: utcStamp(),
    stoppedAt: ""
  )

  try:
    controller.inProcessWorker = startInProcessLiveWorker(
      inputRtsp,
      outputRtsp,
      slot.id,
      slot.name,
      controller.ffmpegPath,
      liveInferOwner = controller.liveInferOwner,
      aiOverlay = true,
      aiDebugOverlay = liveSettings.debugOverlay,
      aiOverlayPreset = liveSettings.overlayPreset
    )
    let snap = controller.inProcessWorker.snapshot()
    controller.state.relayPid = snap.relayPid
    controller.state.lastExitCode = snap.exitCode
    controller.state.liveInferAttempted = snap.liveInferAttempted
    controller.state.liveInferOk = snap.liveInferOk
    controller.state.liveInferFrames = snap.liveInferFrames
    controller.state.liveInferWidth = snap.liveInferWidth
    controller.state.liveInferHeight = snap.liveInferHeight
    controller.state.liveInferDetections = snap.liveInferDetections
    controller.state.liveInferMaxScorePercent = snap.liveInferMaxScorePercent
    controller.state.liveInferThroughputFps = snap.liveInferThroughputFps
    controller.state.liveInferProcessingMs = snap.liveInferProcessingMs
    controller.state.liveInferReadMs = snap.liveInferReadMs
    controller.state.liveInferLetterboxMs = snap.liveInferLetterboxMs
    controller.state.liveInferWaitMs = snap.liveInferWaitMs
    controller.state.liveInferHailoWriteUs = snap.liveInferHailoWriteUs
    controller.state.liveInferHailoReadUs = snap.liveInferHailoReadUs
    controller.state.liveInferMessage = snap.liveInferMessage
    controller.state.status = "running"
    controller.state.running = true
    controller.state.message = &"in-process AI overlay pipeline is publishing /{slot.mediamtxPath} to /{outputPath} debugOverlay={liveSettings.debugOverlay} overlayPreset={liveSettings.overlayPreset.toWire}"
  except CatchableError as e:
    if controller.inProcessWorker != nil:
      let oldWorker = controller.inProcessWorker
      try:
        oldWorker.close()
      except CatchableError:
        discard
      controller.retiredInProcessWorkers.add(oldWorker)
      controller.inProcessWorker = nil
    controller.state.status = "error"
    controller.state.running = false
    controller.state.lastExitCode = -1
    controller.state.message = &"failed to start in-process AI overlay pipeline: {e.msg}"
    controller.state.stoppedAt = utcStamp()


proc startExternalWorkerLocked(
    controller: LiveSessionController;
    slot: CameraSlot;
    inputRtsp, outputPath, outputRtsp: string
  ) =
  if controller.externalWorkerPath.len == 0:
    raise newException(IOError, "external live worker path is empty")
  if controller.externalWorkerPath.contains("/") and not fileExists(controller.externalWorkerPath):
    raise newException(IOError, &"external live worker not found: {controller.externalWorkerPath}")

  discard controller.deleteOutputPath(outputPath)

  let args = expandWorkerArgs(
    controller.externalWorkerArgsTemplate,
    inputRtsp,
    outputRtsp,
    slot,
    outputPath
  )
  controller.state = LiveSessionState(
    status: "starting",
    running: false,
    mode: "external-worker",
    selectedCameraId: slot.id,
    selectedCameraName: slot.name,
    inputMediamtxPath: slot.mediamtxPath,
    inputRtspUrl: inputRtsp,
    outputMediamtxPath: outputPath,
    outputRtspUrl: outputRtsp,
    aiWebrtcPath: &"/{outputPath}",
    relayPid: 0,
    relayCommand: controller.externalWorkerPath,
    relayArgs: args,
    lastExitCode: 0,
    message: &"starting external live worker: /{slot.mediamtxPath} -> /{outputPath}",
    startedAt: utcStamp(),
    stoppedAt: ""
  )

  try:
    controller.relayProcess = startProcess(
      controller.externalWorkerPath,
      args = args,
      options = {poUsePath, poParentStreams}
    )
    controller.state.relayPid = controller.relayProcess.processID()
    controller.state.status = "running"
    controller.state.running = true
    controller.state.message = &"external live worker is publishing /{slot.mediamtxPath} to /{outputPath}"
  except CatchableError as e:
    if controller.relayProcess != nil:
      controller.relayProcess.close()
      controller.relayProcess = nil
    controller.state.status = "error"
    controller.state.running = false
    controller.state.lastExitCode = -1
    controller.state.message = &"failed to start external live worker: {e.msg}"
    controller.state.stoppedAt = utcStamp()

proc startMediamtxProxyRelayLocked(
    controller: LiveSessionController;
    slot: CameraSlot;
    inputRtsp, outputPath, outputRtsp: string
  ) =
  let args = @[
    "set",
    outputPath,
    &"--source:{inputRtsp}",
    "--transport:tcp",
    "--on-demand"
  ]

  discard controller.deleteOutputPath(outputPath)

  controller.state = LiveSessionState(
    status: "starting",
    running: false,
    mode: "mediamtx-proxy",
    selectedCameraId: slot.id,
    selectedCameraName: slot.name,
    inputMediamtxPath: slot.mediamtxPath,
    inputRtspUrl: inputRtsp,
    outputMediamtxPath: outputPath,
    outputRtspUrl: outputRtsp,
    aiWebrtcPath: &"/{outputPath}",
    relayPid: 0,
    relayCommand: controller.pathctlPath,
    relayArgs: args,
    lastExitCode: 0,
    message: &"configuring MediaMTX proxy: /{slot.mediamtxPath} -> /{outputPath}",
    startedAt: utcStamp(),
    stoppedAt: ""
  )

  let res = controller.runPathctl(args)
  controller.state.lastExitCode = res.exitCode
  controller.state.message = res.message

  if res.ok:
    controller.state.status = "running"
    controller.state.running = true
    controller.state.message = &"MediaMTX is proxying /{slot.mediamtxPath} to /{outputPath}; inference worker is not connected yet"
  else:
    controller.state.status = "error"
    controller.state.running = false
    controller.state.mode = "none"
    controller.state.message = &"failed to configure /{outputPath}: {res.message}"
    controller.state.stoppedAt = utcStamp()

proc newLiveSessionController*(
    rtspBaseUrl = defaultRtspBaseUrl;
    pathctlPath = defaultPathctlPath;
    ffmpegPath = defaultFfmpegPath;
    externalWorkerPath = defaultExternalWorkerPath;
    externalWorkerArgsTemplate = defaultExternalWorkerArgs;
    sessionMode = defaultSessionMode;
    liveInferOwner: LiveInferOwner = nil
  ): LiveSessionController =
  new(result)
  initLock(result.lock)
  result.rtspBaseUrl = normalizeBaseUrl(rtspBaseUrl)
  result.pathctlPath = sanitizeExecutablePath(pathctlPath, defaultPathctlPath)
  result.ffmpegPath = sanitizeExecutablePath(ffmpegPath, defaultFfmpegPath)
  result.externalWorkerPath = sanitizeExecutablePath(externalWorkerPath, defaultExternalWorkerPath)
  result.externalWorkerArgsTemplate = sanitizeArgTemplate(externalWorkerArgsTemplate, defaultExternalWorkerArgs)
  result.sessionMode = normalizeSessionMode(sessionMode)
  result.relayProcess = nil
  result.inProcessWorker = nil
  result.retiredInProcessWorkers = newSeqOfCap[InProcessLiveWorker](4)
  result.liveInferOwner = liveInferOwner
  result.state = defaultState(result.rtspBaseUrl)

proc sessionJson*(controller: LiveSessionController): string {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      controller.refreshLiveStateLocked()
      result = pretty(sessionToJson(controller.state)) & "\n"

proc currentState*(controller: LiveSessionController): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      controller.refreshLiveStateLocked()
      result = controller.state

proc stopInProcessWorkerLocked(controller: LiveSessionController) =
  if controller.inProcessWorker.isNil:
    return

  # Keep the closed worker object alive instead of letting ORC reclaim it
  # during the stop request.  The in-process worker state contains strings,
  # locks and thread-owned objects that were touched from the worker thread.
  # In earlier live inference experiments, dropping the last ref here could
  # crash in ORC/shared allocator cleanup after the worker thread had stopped.
  #
  # This is a demo service and live sessions are expected to be started/stopped
  # only a small number of times.  Retiring the closed worker avoids the fragile
  # teardown path while still marking the session as stopped and allowing a new
  # worker to be started.
  let oldWorker = controller.inProcessWorker
  try:
    oldWorker.close()
  except CatchableError:
    discard
  controller.retiredInProcessWorkers.add(oldWorker)
  controller.inProcessWorker = nil


proc stopProcessLocked(controller: LiveSessionController) =
  if controller.relayProcess.isNil:
    return
  try:
    if controller.relayProcess.running():
      controller.relayProcess.terminate()
      discard controller.relayProcess.waitForExit()
    else:
      discard controller.relayProcess.waitForExit()
  except CatchableError:
    try:
      controller.relayProcess.kill()
      discard controller.relayProcess.waitForExit()
    except CatchableError:
      discard
  try:
    controller.relayProcess.close()
  except CatchableError:
    discard
  controller.relayProcess = nil

proc startSession*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore;
    liveSettings = defaultLiveSettings()
  ): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    if controller == nil:
      raise newException(ValueError, "live session controller is not initialized")
    if cameras == nil:
      raise newException(ValueError, "live camera store is not initialized")
    if targetStore == nil:
      raise newException(ValueError, "live target store is not initialized")

    let target = targetStore.getTargetState()
    if target.selectedCameraId.len == 0:
      raise newException(ValueError, "no live AI target is selected")

    let slot = cameras.getCameraSlot(target.selectedCameraId)
    if not slot.enabled or slot.source.len == 0:
      raise newException(ValueError, &"selected camera is not enabled: {target.selectedCameraId}")

    let inputRtsp = mediaPathUrl(controller.rtspBaseUrl, slot.mediamtxPath)
    let outputPath = target.aiMediamtxPath.strip(chars = {'/'})
    let outputRtsp = mediaPathUrl(controller.rtspBaseUrl, outputPath)

    withLock controller.lock:
      controller.refreshLiveStateLocked()
      controller.stopProcessLocked()
      controller.stopInProcessWorkerLocked()
      discard controller.deleteOutputPath(outputPath)

      case controller.sessionMode
      of "in-process-ai":
        controller.startInProcessAiWorkerLocked(slot, inputRtsp, outputPath, outputRtsp, liveSettings)
      of "in-process":
        controller.startInProcessWorkerLocked(slot, inputRtsp, outputPath, outputRtsp)
      of "ffmpeg-copy":
        controller.startFfmpegCopyRelayLocked(slot, inputRtsp, outputPath, outputRtsp)
      of "external-worker":
        controller.startExternalWorkerLocked(slot, inputRtsp, outputPath, outputRtsp)
      else:
        controller.startMediamtxProxyRelayLocked(slot, inputRtsp, outputPath, outputRtsp)

      result = controller.state

    if result.running:
      targetStore.setPipelineState("running", true, result.message)
    else:
      targetStore.setPipelineState(result.status, false, result.message)

proc stopSession*(controller: LiveSessionController; targetStore: LiveTargetStore = nil): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    if controller == nil:
      raise newException(ValueError, "live session controller is not initialized")

    withLock controller.lock:
      controller.stopProcessLocked()
      controller.stopInProcessWorkerLocked()
      let outputPath = if controller.state.outputMediamtxPath.len > 0: controller.state.outputMediamtxPath else: defaultAiMediamtxPath
      let res = controller.deleteOutputPath(outputPath)
      if res.ok:
        markStoppedLocked(controller, "live session is stopped")
      else:
        markStoppedLocked(controller, &"failed to delete /{outputPath}: {res.message}", "error")
      controller.state.lastExitCode = res.exitCode
      result = controller.state

    if targetStore != nil:
      targetStore.setPipelineState(result.status, result.running, result.message)

proc close*(controller: LiveSessionController) =
  if controller != nil:
    discard controller.stopSession()
    deinitLock(controller.lock)

proc prepareSession*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore;
    liveSettings = defaultLiveSettings()
  ): LiveSessionState {.gcsafe.} =
  result = controller.startSession(cameras, targetStore, liveSettings)

proc prepareSessionJson*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore;
    liveSettings = defaultLiveSettings()
  ): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.startSession(cameras, targetStore, liveSettings))) & "\n"

proc stopSessionJson*(controller: LiveSessionController; targetStore: LiveTargetStore = nil): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.stopSession(targetStore))) & "\n"
