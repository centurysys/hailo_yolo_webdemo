## Selected live camera target state.
##
## This module only stores which raw camera slot should be used by the future
## inference pipeline.  It does not start decode/infer/overlay/encode yet; that
## will be added by the LiveSession layer in a later step.

import std/[json, locks, os, strformat, strutils]

import ./cameras

const
  defaultAiMediamtxPath* = "cam-ai"

type
  LiveTargetState* = object
    selectedCameraId*: string
    aiMediamtxPath*: string
    pipelineStatus*: string
    running*: bool
    message*: string

  LiveTargetStore* = ref object
    lock: Lock
    configPath: string
    aiMediamtxPath: string
    state: LiveTargetState

proc nowPidSuffix(): string =
  $getCurrentProcessId()

proc defaultState(aiMediamtxPath: string): LiveTargetState =
  LiveTargetState(
    selectedCameraId: "",
    aiMediamtxPath: aiMediamtxPath,
    pipelineStatus: "not-started",
    running: false,
    message: "no camera selected"
  )

proc atomicWrite(path, content: string) =
  let dir = path.splitFile.dir
  if dir.len > 0:
    createDir(dir)
  let tmpPath = &"{path}.tmp.{nowPidSuffix()}"
  writeFile(tmpPath, content)
  moveFile(tmpPath, path)

proc targetToJson(state: LiveTargetState): JsonNode =
  result = newJObject()
  result["selectedCameraId"] = %state.selectedCameraId
  result["aiMediamtxPath"] = %state.aiMediamtxPath
  result["aiWebrtcPath"] = %(&"/{state.aiMediamtxPath}")
  result["aiHlsPath"] = %(&"/{state.aiMediamtxPath}")
  result["pipelineStatus"] = %state.pipelineStatus
  result["running"] = %state.running
  result["message"] = %state.message

proc saveLocked(store: LiveTargetStore) =
  atomicWrite(store.configPath, pretty(targetToJson(store.state)) & "\n")

proc getStringField(node: JsonNode, key, defaultValue: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    result = node[key].str
  else:
    result = defaultValue

proc getBoolField(node: JsonNode, key: string; defaultValue: bool): bool =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
    result = node[key].bval
  else:
    result = defaultValue

proc parseStateNode(node: JsonNode; aiMediamtxPath: string): LiveTargetState =
  result = defaultState(aiMediamtxPath)
  if node.kind != JObject:
    return

  let selected = node.getStringField("selectedCameraId", "").strip()
  if selected.len > 0 and selected.isValidSlotId:
    result.selectedCameraId = selected
    result.message = &"{selected} selected; inference pipeline is not started yet"

  let path = node.getStringField("aiMediamtxPath", aiMediamtxPath).strip()
  if path.len > 0:
    result.aiMediamtxPath = path

  ## These fields are kept for future LiveSession integration.  In this step
  ## the pipeline is never running, even if an old file says otherwise.
  discard node.getBoolField("running", false)
  result.running = false
  result.pipelineStatus = "not-started"

proc loadFromDisk(store: LiveTargetStore) =
  store.state = defaultState(store.aiMediamtxPath)
  if not fileExists(store.configPath):
    return
  let root = parseJson(readFile(store.configPath))
  store.state = parseStateNode(root, store.aiMediamtxPath)

proc newLiveTargetStore*(configPath: string; aiMediamtxPath = defaultAiMediamtxPath): LiveTargetStore =
  new(result)
  initLock(result.lock)
  result.configPath = configPath
  result.aiMediamtxPath = aiMediamtxPath
  result.loadFromDisk()
  withLock result.lock:
    result.saveLocked()

proc close*(store: LiveTargetStore) =
  if store != nil:
    deinitLock(store.lock)

proc targetJson*(store: LiveTargetStore): string {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock store.lock:
      result = pretty(targetToJson(store.state)) & "\n"

proc getTargetState*(store: LiveTargetStore): LiveTargetState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock store.lock:
      result = store.state

proc setPipelineState*(store: LiveTargetStore; status: string; running: bool; message: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock store.lock:
      store.state.pipelineStatus = status
      store.state.running = running
      store.state.message = message
      store.saveLocked()

proc selectTarget*(store: LiveTargetStore; cameras: LiveCameraStore; cameraId: string): LiveTargetState {.gcsafe.} =
  {.cast(gcsafe).}:
    if not cameraId.isValidSlotId:
      raise newException(ValueError, &"invalid camera slot: {cameraId}")
    if cameras == nil:
      raise newException(ValueError, "live camera store is not initialized")

    let slot = cameras.getCameraSlot(cameraId)
    if not slot.enabled or slot.source.len == 0:
      raise newException(ValueError, &"camera is not enabled: {cameraId}")

    withLock store.lock:
      store.state.selectedCameraId = cameraId
      store.state.running = false
      store.state.pipelineStatus = "not-started"
      store.state.message = &"{cameraId} selected; inference pipeline is not started yet"
      store.saveLocked()
      result = store.state

proc selectTargetJson*(store: LiveTargetStore; cameras: LiveCameraStore; cameraId: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(targetToJson(store.selectTarget(cameras, cameraId))) & "\n"

proc clearTarget*(store: LiveTargetStore): LiveTargetState {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock store.lock:
      store.state = defaultState(store.aiMediamtxPath)
      store.saveLocked()
      result = store.state

proc clearTargetJson*(store: LiveTargetStore): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = pretty(targetToJson(store.clearTarget())) & "\n"

proc clearIfSelected*(store: LiveTargetStore; cameraId: string) {.gcsafe.} =
  {.cast(gcsafe).}:
    if cameraId.len == 0:
      return
    withLock store.lock:
      if store.state.selectedCameraId == cameraId:
        store.state = defaultState(store.aiMediamtxPath)
        store.saveLocked()
