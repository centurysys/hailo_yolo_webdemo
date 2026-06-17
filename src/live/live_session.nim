## Live inference session control.
##
## This step starts a temporary pass-through relay process for the selected
## camera.  The relay publishes the selected raw camera stream to /cam-ai so the
## AI preview panel can be verified end-to-end before the real
## decode/infer/overlay/encode pipeline is connected.
##
## The relay is intentionally isolated behind this controller.  Later, the
## ffmpeg-copy relay can be replaced by the in-process inference pipeline while
## keeping the HTTP API and UI state model stable.

import std/[json, locks, os, osproc, strformat, strutils, times]

import ./cameras
import ./live_target

const
  defaultRtspBaseUrl* = "rtsp://127.0.0.1:8554"
  defaultRelayBinary* = "ffmpeg"
  defaultRelayLogLevel* = "warning"

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
    message*: string
    startedAt*: string
    stoppedAt*: string

  LiveSessionController* = ref object
    lock: Lock
    rtspBaseUrl: string
    relayBinary: string
    relayLogLevel: string
    relayProcess: Process
    state: LiveSessionState

proc utcStamp(): string =
  ## Keep the timestamp plain and stable for logs/UI.  The container may not
  ## always have full timezone data, so UTC avoids local timezone surprises.
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

proc sanitizeRelayBinary(value: string): string =
  result = value.strip()
  if result.len == 0:
    result = defaultRelayBinary

proc sanitizeRelayLogLevel(value: string): string =
  let v = value.strip().toLowerAscii()
  case v
  of "quiet", "panic", "fatal", "error", "warning", "info", "verbose", "debug", "trace":
    result = v
  else:
    result = defaultRelayLogLevel

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
  result["message"] = %state.message
  result["startedAt"] = %state.startedAt
  result["stoppedAt"] = %state.stoppedAt

proc buildRelayArgs(inputRtspUrl, outputRtspUrl, logLevel: string): seq[string] =
  ## Pass-through relay used until the real inference pipeline is connected.
  ##
  ## The selected camera is already proxied by MediaMTX as /camN.  This command
  ## reads it over RTSP/TCP and republishes it to /cam-ai.  It does not decode,
  ## infer, overlay, or re-encode.
  result = @[
    "-nostdin",
    "-hide_banner",
    "-loglevel", logLevel,
    "-rtsp_transport", "tcp",
    "-fflags", "nobuffer",
    "-flags", "low_delay",
    "-i", inputRtspUrl,
    "-an",
    "-c:v", "copy",
    "-rtsp_transport", "tcp",
    "-f", "rtsp",
    outputRtspUrl
  ]

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
  controller.state.stoppedAt = utcStamp()

proc closeRelayProcess(controller: LiveSessionController) =
  if controller.relayProcess != nil:
    close(controller.relayProcess)
    controller.relayProcess = nil

proc refreshRelayStateLocked(controller: LiveSessionController) =
  ## Update state if the relay process exited since the last API call.
  if controller.relayProcess == nil:
    return
  if running(controller.relayProcess):
    return

  let exitCode = waitForExit(controller.relayProcess)
  closeRelayProcess(controller)
  controller.state.lastExitCode = exitCode
  controller.state.running = false
  controller.state.relayPid = 0
  if controller.state.status == "running":
    controller.state.status = if exitCode == 0: "stopped" else: "error"
    controller.state.message = &"live relay exited with code {exitCode}"
    controller.state.stoppedAt = utcStamp()

proc terminateRelayLocked(controller: LiveSessionController) =
  if controller.relayProcess == nil:
    return

  if running(controller.relayProcess):
    terminate(controller.relayProcess)
    let code = waitForExit(controller.relayProcess, 1500)
    if code == -1 and running(controller.relayProcess):
      kill(controller.relayProcess)
      discard waitForExit(controller.relayProcess)
  else:
    discard waitForExit(controller.relayProcess)
  closeRelayProcess(controller)

proc newLiveSessionController*(
    rtspBaseUrl = defaultRtspBaseUrl;
    relayBinary = defaultRelayBinary;
    relayLogLevel = defaultRelayLogLevel
  ): LiveSessionController =
  new(result)
  initLock(result.lock)
  result.rtspBaseUrl = normalizeBaseUrl(rtspBaseUrl)
  result.relayBinary = sanitizeRelayBinary(relayBinary)
  result.relayLogLevel = sanitizeRelayLogLevel(relayLogLevel)
  result.relayProcess = nil
  result.state = defaultState(result.rtspBaseUrl)

proc close*(controller: LiveSessionController) =
  if controller != nil:
    {.cast(gcsafe).}:
      withLock controller.lock:
        terminateRelayLocked(controller)
    deinitLock(controller.lock)

proc sessionJson*(controller: LiveSessionController): string {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      refreshRelayStateLocked(controller)
      result = pretty(sessionToJson(controller.state)) & "\n"

proc currentState*(controller: LiveSessionController): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      refreshRelayStateLocked(controller)
      result = controller.state

proc startSession*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore
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
    let args = buildRelayArgs(inputRtsp, outputRtsp, controller.relayLogLevel)

    withLock controller.lock:
      refreshRelayStateLocked(controller)
      terminateRelayLocked(controller)

      controller.state = LiveSessionState(
        status: "starting",
        running: false,
        mode: "ffmpeg-copy-relay",
        selectedCameraId: slot.id,
        selectedCameraName: slot.name,
        inputMediamtxPath: slot.mediamtxPath,
        inputRtspUrl: inputRtsp,
        outputMediamtxPath: outputPath,
        outputRtspUrl: outputRtsp,
        aiWebrtcPath: &"/{outputPath}",
        relayPid: 0,
        relayCommand: controller.relayBinary,
        relayArgs: args,
        lastExitCode: 0,
        message: &"starting live relay: {slot.mediamtxPath} -> {outputPath}",
        startedAt: utcStamp(),
        stoppedAt: ""
      )

      try:
        controller.relayProcess = startProcess(
          controller.relayBinary,
          args = args,
          options = {poUsePath, poParentStreams}
        )
      except CatchableError as e:
        controller.state.status = "error"
        controller.state.running = false
        controller.state.mode = "none"
        controller.state.message = &"failed to start live relay command '{controller.relayBinary}': {e.msg}"
        controller.state.stoppedAt = utcStamp()
        result = controller.state

      if controller.relayProcess != nil:
        controller.state.relayPid = processID(controller.relayProcess)
        sleep(250)

        if not running(controller.relayProcess):
          let exitCode = waitForExit(controller.relayProcess)
          closeRelayProcess(controller)
          controller.state.lastExitCode = exitCode
          controller.state.status = "error"
          controller.state.running = false
          controller.state.relayPid = 0
          controller.state.message = &"live relay failed immediately with code {exitCode}"
          controller.state.stoppedAt = utcStamp()
          result = controller.state
        else:
          controller.state.status = "running"
          controller.state.running = true
          controller.state.message = &"live relay is publishing /{slot.mediamtxPath} to /{outputPath}; inference worker is not connected yet"
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
      terminateRelayLocked(controller)
      markStoppedLocked(controller, "live relay is stopped")
      result = controller.state

    if targetStore != nil:
      targetStore.setPipelineState("stopped", false, "live relay is stopped")

proc prepareSession*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore
  ): LiveSessionState {.gcsafe.} =
  ## Backward-compatible name used by the existing HTTP handler.
  result = controller.startSession(cameras, targetStore)

proc prepareSessionJson*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore
  ): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.startSession(cameras, targetStore))) & "\n"

proc stopSessionJson*(controller: LiveSessionController; targetStore: LiveTargetStore = nil): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.stopSession(targetStore))) & "\n"
