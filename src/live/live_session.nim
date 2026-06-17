## Live inference session control skeleton.
##
## This module wires the selected camera target to a session status API.  It does
## not start the actual decode/infer/overlay/encode pipeline yet.  Instead, it
## validates the selected camera and prepares the input/output MediaMTX URLs that
## the real pipeline will consume in the next step.

import std/[json, locks, strformat, strutils, times]

import ./cameras
import ./live_target

const
  defaultRtspBaseUrl* = "rtsp://127.0.0.1:8554"

type
  LiveSessionState* = object
    status*: string
    running*: bool
    selectedCameraId*: string
    selectedCameraName*: string
    inputMediamtxPath*: string
    inputRtspUrl*: string
    outputMediamtxPath*: string
    outputRtspUrl*: string
    aiWebrtcPath*: string
    message*: string
    startedAt*: string
    stoppedAt*: string

  LiveSessionController* = ref object
    lock: Lock
    rtspBaseUrl: string
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

proc defaultState(rtspBaseUrl: string): LiveSessionState =
  let aiPath = defaultAiMediamtxPath
  LiveSessionState(
    status: "stopped",
    running: false,
    selectedCameraId: "",
    selectedCameraName: "",
    inputMediamtxPath: "",
    inputRtspUrl: "",
    outputMediamtxPath: aiPath,
    outputRtspUrl: mediaPathUrl(rtspBaseUrl, aiPath),
    aiWebrtcPath: &"/{aiPath}",
    message: "live inference pipeline is stopped",
    startedAt: "",
    stoppedAt: ""
  )

proc sessionToJson(state: LiveSessionState): JsonNode =
  result = newJObject()
  result["status"] = %state.status
  result["running"] = %state.running
  result["selectedCameraId"] = %state.selectedCameraId
  result["selectedCameraName"] = %state.selectedCameraName
  result["inputMediamtxPath"] = %state.inputMediamtxPath
  result["inputRtspUrl"] = %state.inputRtspUrl
  result["outputMediamtxPath"] = %state.outputMediamtxPath
  result["outputRtspUrl"] = %state.outputRtspUrl
  result["aiWebrtcPath"] = %state.aiWebrtcPath
  result["message"] = %state.message
  result["startedAt"] = %state.startedAt
  result["stoppedAt"] = %state.stoppedAt

proc newLiveSessionController*(rtspBaseUrl = defaultRtspBaseUrl): LiveSessionController =
  new(result)
  initLock(result.lock)
  result.rtspBaseUrl = normalizeBaseUrl(rtspBaseUrl)
  result.state = defaultState(result.rtspBaseUrl)

proc close*(controller: LiveSessionController) =
  if controller != nil:
    deinitLock(controller.lock)

proc sessionJson*(controller: LiveSessionController): string {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      result = pretty(sessionToJson(controller.state)) & "\n"

proc currentState*(controller: LiveSessionController): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock controller.lock:
      result = controller.state

proc prepareSession*(
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
    let msg = &"prepared live pipeline route: {slot.mediamtxPath} -> {outputPath}"

    withLock controller.lock:
      controller.state.status = "prepared"
      controller.state.running = false
      controller.state.selectedCameraId = slot.id
      controller.state.selectedCameraName = slot.name
      controller.state.inputMediamtxPath = slot.mediamtxPath
      controller.state.inputRtspUrl = inputRtsp
      controller.state.outputMediamtxPath = outputPath
      controller.state.outputRtspUrl = outputRtsp
      controller.state.aiWebrtcPath = &"/{outputPath}"
      controller.state.message = msg & "; inference worker is not connected yet"
      controller.state.startedAt = utcStamp()
      controller.state.stoppedAt = ""
      result = controller.state

    targetStore.setPipelineState("prepared", false, controller.state.message)

proc stopSession*(controller: LiveSessionController; targetStore: LiveTargetStore = nil): LiveSessionState {.gcsafe.} =
  {.cast(gcsafe).}:
    if controller == nil:
      raise newException(ValueError, "live session controller is not initialized")

    withLock controller.lock:
      let outputPath = if controller.state.outputMediamtxPath.len > 0: controller.state.outputMediamtxPath else: defaultAiMediamtxPath
      controller.state.status = "stopped"
      controller.state.running = false
      controller.state.message = "live inference pipeline is stopped"
      controller.state.inputMediamtxPath = ""
      controller.state.inputRtspUrl = ""
      controller.state.outputMediamtxPath = outputPath
      controller.state.outputRtspUrl = mediaPathUrl(controller.rtspBaseUrl, outputPath)
      controller.state.aiWebrtcPath = &"/{outputPath}"
      controller.state.stoppedAt = utcStamp()
      result = controller.state

    if targetStore != nil:
      targetStore.setPipelineState("stopped", false, "live inference pipeline is stopped")

proc prepareSessionJson*(
    controller: LiveSessionController;
    cameras: LiveCameraStore;
    targetStore: LiveTargetStore
  ): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.prepareSession(cameras, targetStore))) & "\n"

proc stopSessionJson*(controller: LiveSessionController; targetStore: LiveTargetStore = nil): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(sessionToJson(controller.stopSession(targetStore))) & "\n"
