## Persistent live AI preview settings.
##
## These settings are intentionally small and scalar-only.  They are read when a
## live AI session starts, then copied into the worker options.  Changing them
## while the live AI pipeline is running is rejected by the HTTP layer so the
## worker never has to observe mutable configuration.

import std/[json, locks, os, strformat, strutils]

const
  defaultDebugOverlay* = true

type
  LiveSettingsState* = object
    debugOverlay*: bool

  LiveSettingsStore* = ref object
    lock: Lock
    configPath: string
    state: LiveSettingsState

proc nowPidSuffix(): string =
  $getCurrentProcessId()

proc defaultLiveSettings*(): LiveSettingsState =
  LiveSettingsState(debugOverlay: defaultDebugOverlay)

proc atomicWrite(path, content: string) =
  let dir = path.splitFile.dir
  if dir.len > 0:
    createDir(dir)
  let tmpPath = &"{path}.tmp.{nowPidSuffix()}"
  writeFile(tmpPath, content)
  moveFile(tmpPath, path)

proc getBoolField(node: JsonNode, key: string; defaultValue: bool): bool =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JBool:
    result = node[key].bval
  else:
    result = defaultValue

proc parseSettingsNode(node: JsonNode): LiveSettingsState =
  result = defaultLiveSettings()
  if node.kind != JObject:
    return
  result.debugOverlay = node.getBoolField("debugOverlay", result.debugOverlay)

proc settingsToJsonNode(state: LiveSettingsState; canEdit: bool): JsonNode =
  result = newJObject()
  result["debugOverlay"] = %state.debugOverlay
  result["canEdit"] = %canEdit

proc saveLocked(store: LiveSettingsStore) =
  atomicWrite(store.configPath, pretty(settingsToJsonNode(store.state, true)) & "\n")

proc loadFromDisk(store: LiveSettingsStore) =
  store.state = defaultLiveSettings()
  if not fileExists(store.configPath):
    return
  let root = parseJson(readFile(store.configPath))
  store.state = parseSettingsNode(root)

proc newLiveSettingsStore*(configPath: string): LiveSettingsStore =
  new(result)
  initLock(result.lock)
  result.configPath = configPath
  result.loadFromDisk()
  withLock result.lock:
    result.saveLocked()

proc close*(store: LiveSettingsStore) =
  if store != nil:
    deinitLock(store.lock)

proc getSettings*(store: LiveSettingsStore): LiveSettingsState {.gcsafe.} =
  if store == nil:
    return defaultLiveSettings()
  {.cast(gcsafe).}:
    withLock store.lock:
      result = store.state

proc settingsJson*(store: LiveSettingsStore; canEdit: bool): string {.gcsafe.} =
  {.cast(gcsafe).}:
    let state = if store == nil: defaultLiveSettings() else: store.getSettings()
    result = pretty(settingsToJsonNode(state, canEdit)) & "\n"

proc updateSettings*(store: LiveSettingsStore; body: string): LiveSettingsState {.gcsafe.} =
  if store == nil:
    raise newException(ValueError, "live settings store is not initialized")

  {.cast(gcsafe).}:
    let root = parseJson(body)
    if root.kind != JObject:
      raise newException(ValueError, "live settings request must be a JSON object")

    var next: LiveSettingsState
    withLock store.lock:
      next = store.state
      if root.hasKey("debugOverlay"):
        if root["debugOverlay"].kind != JBool:
          raise newException(ValueError, "debugOverlay must be a boolean")
        next.debugOverlay = root["debugOverlay"].bval

      store.state = next
      store.saveLocked()
      result = store.state

proc updateSettingsJson*(store: LiveSettingsStore; body: string; canEdit: bool): string {.gcsafe.} =
  let state = store.updateSettings(body)
  {.cast(gcsafe).}:
    result = pretty(settingsToJsonNode(state, canEdit)) & "\n"
