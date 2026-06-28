## Persistent live camera slot configuration and MediaMTX path sync.
##
## This module deliberately keeps the Web Demo camera model smaller than the
## full MediaMTX PathConf.  MediaMTX may return many default fields such as
## rpiCamera*, record* and runOn*; the demo only persists the fields that the
## live preview UI owns.

import std/[json, locks, os, osproc, streams, strformat, strutils, tables]

const
  defaultRtspTransport* = "udp"
  defaultInputMode* = "relay"
  defaultPathctlPath* = "/usr/local/sbin/mediamtx-pathctl"
  cameraSlotIds* = ["cam1", "cam2", "cam3", "cam4"]

type
  CameraSlot* = object
    id*: string
    name*: string
    source*: string
    rtspTransport*: string
    inputMode*: string
    enabled*: bool
    mediamtxPath*: string

  CameraUpdate* = object
    name*: string
    source*: string
    rtspTransport*: string
    inputMode*: string
    enabled*: bool

  CameraApplyResult* = object
    ok*: bool
    message*: string

  CameraOperationResult* = object
    slot*: CameraSlot
    mediamtx*: CameraApplyResult

  LiveCameraStore* = ref object
    lock: Lock
    configPath: string
    pathctlPath: string
    slots: Table[string, CameraSlot]

proc nowPidSuffix(): string =
  $getCurrentProcessId()

proc isValidSlotId*(id: string): bool =
  for slotId in cameraSlotIds:
    if id == slotId:
      return true
  false

proc validateSlotId(id: string) =
  if not id.isValidSlotId:
    raise newException(ValueError, &"invalid camera slot: {id}")

proc defaultSlotName(id: string): string =
  case id
  of "cam1": "Camera 1"
  of "cam2": "Camera 2"
  of "cam3": "Camera 3"
  of "cam4": "Camera 4"
  else: id

proc defaultSlot(id: string): CameraSlot =
  CameraSlot(
    id: id,
    name: defaultSlotName(id),
    source: "",
    rtspTransport: defaultRtspTransport,
    inputMode: defaultInputMode,
    enabled: false,
    mediamtxPath: id
  )

proc validateTransport*(value: string): string =
  let t = value.strip().toLowerAscii()
  if t.len == 0:
    return defaultRtspTransport
  case t
  of "udp", "automatic", "tcp", "multicast":
    result = t
  else:
    raise newException(ValueError, &"invalid RTSP transport: {value}")

proc validateInputMode*(value: string): string =
  let mode = value.strip().toLowerAscii()
  if mode.len == 0:
    return defaultInputMode
  case mode
  of "relay", "direct":
    result = mode
  else:
    raise newException(ValueError, &"invalid camera input mode: {value}")

proc initDefaultSlots(store: LiveCameraStore) =
  store.slots = initTable[string, CameraSlot]()
  for id in cameraSlotIds:
    store.slots[id] = defaultSlot(id)

proc slotToJson(slot: CameraSlot): JsonNode =
  result = newJObject()
  result["id"] = %slot.id
  result["name"] = %slot.name
  result["source"] = %slot.source
  result["rtspTransport"] = %slot.rtspTransport
  result["inputMode"] = %slot.inputMode
  result["enabled"] = %slot.enabled
  result["mediamtxPath"] = %slot.mediamtxPath
  result["webrtcPath"] = %(&"/{slot.mediamtxPath}")
  result["hlsPath"] = %(&"/{slot.mediamtxPath}")

proc slotsToJson(slots: Table[string, CameraSlot]): JsonNode =
  result = newJObject()
  var arr = newJArray()
  for id in cameraSlotIds:
    if id in slots:
      arr.add(slotToJson(slots[id]))
    else:
      arr.add(slotToJson(defaultSlot(id)))
  result["slots"] = arr

proc atomicWrite(path, content: string) =
  let dir = path.splitFile.dir
  if dir.len > 0:
    createDir(dir)
  let tmpPath = &"{path}.tmp.{nowPidSuffix()}"
  writeFile(tmpPath, content)
  moveFile(tmpPath, path)

proc saveLocked(store: LiveCameraStore) =
  let jsonText = pretty(slotsToJson(store.slots)) & "\n"
  atomicWrite(store.configPath, jsonText)

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

proc parseSlotNode(node: JsonNode; fallbackId: string): CameraSlot =
  let id = node.getStringField("id", fallbackId).strip()
  validateSlotId(id)
  let base = defaultSlot(id)
  result = CameraSlot(
    id: id,
    name: node.getStringField("name", base.name).strip(),
    source: node.getStringField("source", "").strip(),
    rtspTransport: validateTransport(node.getStringField("rtspTransport", defaultRtspTransport)),
    inputMode: validateInputMode(node.getStringField("inputMode", defaultInputMode)),
    enabled: node.getBoolField("enabled", false),
    mediamtxPath: node.getStringField("mediamtxPath", id).strip()
  )
  if result.name.len == 0:
    result.name = base.name
  if result.mediamtxPath.len == 0:
    result.mediamtxPath = id

proc loadFromDisk(store: LiveCameraStore) =
  store.initDefaultSlots()
  if not fileExists(store.configPath):
    return

  let root = parseJson(readFile(store.configPath))
  if root.kind != JObject or not root.hasKey("slots") or root["slots"].kind != JArray:
    raise newException(ValueError, &"invalid camera config: {store.configPath}")

  for item in root["slots"].items:
    let slot = parseSlotNode(item, "")
    store.slots[slot.id] = slot

proc newLiveCameraStore*(configPath: string; pathctlPath = defaultPathctlPath): LiveCameraStore =
  new(result)
  initLock(result.lock)
  result.configPath = configPath
  result.pathctlPath = pathctlPath
  result.loadFromDisk()
  ## Make sure the file exists with a complete four-slot skeleton.  This also
  ## creates the parent directory on a fresh package.
  withLock result.lock:
    result.saveLocked()

proc close*(store: LiveCameraStore) =
  if store != nil:
    deinitLock(store.lock)

proc parseCameraUpdate*(body: string): CameraUpdate =
  let node = parseJson(body)
  if node.kind != JObject:
    raise newException(ValueError, "camera update body must be a JSON object")

  result.name = node.getStringField("name", "").strip()
  result.source = node.getStringField("source", "").strip()
  result.rtspTransport = validateTransport(node.getStringField("rtspTransport", defaultRtspTransport))
  if node.hasKey("inputMode"):
    result.inputMode = validateInputMode(node.getStringField("inputMode", defaultInputMode))
  else:
    result.inputMode = ""
  result.enabled = node.getBoolField("enabled", result.source.len > 0)

proc runPathctl(store: LiveCameraStore; args: seq[string]): CameraApplyResult =
  if not fileExists(store.pathctlPath):
    return CameraApplyResult(
      ok: false,
      message: &"mediamtx-pathctl not found: {store.pathctlPath}"
    )

  var process: Process
  try:
    process = startProcess(
      store.pathctlPath,
      args = args,
      options = {poUsePath, poStdErrToStdOut}
    )
    let output = process.outputStream.readAll().strip()
    let code = process.waitForExit()
    process.close()
    process = nil

    if code == 0:
      result = CameraApplyResult(ok: true, message: output)
    else:
      result = CameraApplyResult(ok: false, message: &"mediamtx-pathctl exited with {code}: {output}")
  except CatchableError as e:
    if process != nil:
      process.close()
    result = CameraApplyResult(ok: false, message: e.msg)

proc applySlot(store: LiveCameraStore; slot: CameraSlot): CameraApplyResult =
  if slot.enabled and slot.source.len > 0:
    result = store.runPathctl(@[
      "set",
      slot.mediamtxPath,
      &"--source:{slot.source}",
      &"--transport:{slot.rtspTransport}"
    ])
  else:
    ## Deleting an absent path is not a fatal condition for the demo-side config.
    result = store.runPathctl(@["delete", slot.mediamtxPath])
    if not result.ok and ("404" in result.message or "not found" in result.message.toLowerAscii()):
      result.ok = true
      result.message = "path was already absent"

proc camerasJson*(store: LiveCameraStore): string {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock store.lock:
      result = pretty(slotsToJson(store.slots)) & "\n"

proc getCameraSlot*(store: LiveCameraStore; id: string): CameraSlot {.gcsafe.} =
  {.cast(gcsafe).}:
    validateSlotId(id)
    withLock store.lock:
      result = store.slots.getOrDefault(id, defaultSlot(id))

proc isCameraSelectable*(store: LiveCameraStore; id: string): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    let slot = store.getCameraSlot(id)
    result = slot.enabled and slot.source.len > 0

proc operationJson(op: CameraOperationResult): string =
  var root = newJObject()
  root["slot"] = slotToJson(op.slot)
  root["mediamtx"] = newJObject()
  root["mediamtx"]["ok"] = %op.mediamtx.ok
  root["mediamtx"]["message"] = %op.mediamtx.message
  pretty(root) & "\n"

proc setCamera*(store: LiveCameraStore; id: string; update: CameraUpdate): CameraOperationResult {.gcsafe.} =
  {.cast(gcsafe).}:
    validateSlotId(id)
    var slot: CameraSlot
    withLock store.lock:
      slot = store.slots.getOrDefault(id, defaultSlot(id))
      if update.name.len > 0:
        slot.name = update.name
      elif slot.name.len == 0:
        slot.name = defaultSlotName(id)
      slot.source = update.source
      slot.rtspTransport = update.rtspTransport
      if update.inputMode.len > 0:
        slot.inputMode = update.inputMode
      elif slot.inputMode.len == 0:
        slot.inputMode = defaultInputMode
      slot.enabled = update.enabled and update.source.len > 0
      slot.mediamtxPath = id
      store.slots[id] = slot
      store.saveLocked()

    result.slot = slot
    result.mediamtx = store.applySlot(slot)

proc setCameraJson*(store: LiveCameraStore; id, body: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    let update = parseCameraUpdate(body)
    result = store.setCamera(id, update).operationJson()

proc deleteCamera*(store: LiveCameraStore; id: string): CameraOperationResult {.gcsafe.} =
  {.cast(gcsafe).}:
    validateSlotId(id)
    let cleared = defaultSlot(id)
    withLock store.lock:
      store.slots[id] = cleared
      store.saveLocked()

    result.slot = cleared
    result.mediamtx = store.applySlot(cleared)

proc deleteCameraJson*(store: LiveCameraStore; id: string): string {.gcsafe.} =
  {.cast(gcsafe).}:
    result = store.deleteCamera(id).operationJson()

proc syncEnabledCameras*(store: LiveCameraStore): seq[CameraOperationResult] {.gcsafe.} =
  ## Best-effort startup sync.  This is intentionally non-fatal: during boot,
  ## MediaMTX may not be ready yet depending on service ordering.  The Web UI can
  ## still set a camera later and retry through the same pathctl layer.
  {.cast(gcsafe).}:
    var slots: seq[CameraSlot]
    withLock store.lock:
      for id in cameraSlotIds:
        let slot = store.slots.getOrDefault(id, defaultSlot(id))
        if slot.enabled and slot.source.len > 0:
          slots.add(slot)

    for slot in slots:
      result.add(CameraOperationResult(slot: slot, mediamtx: store.applySlot(slot)))
