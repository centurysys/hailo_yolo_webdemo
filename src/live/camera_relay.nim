## ffmpeg based RTSP camera input normalizer.
##
## The relay does not decode or re-encode video.  It lets ffmpeg pull a camera
## RTSP stream and publish it back to MediaMTX with `-c:v copy`, which normalizes
## RTSP/RTP/timestamp details that can otherwise upset some hardware decoders.

import std/[locks, osproc, sequtils, strformat, strutils, tables, times]

const
  defaultRelayLogLevel* = "warning"

type
  CameraRelayState* = enum
    crStopped,
    crRunning,
    crFailed

  CameraRelayStatus* = object
    slotId*: string
    state*: CameraRelayState
    pid*: int
    sourceMasked*: string
    outputRtsp*: string
    startedAtUnix*: int64
    message*: string

  CameraRelayProcess = ref object
    slotId: string
    sourceUrl: string
    sourceMasked: string
    outputRtsp: string
    process: Process
    startedAtUnix: int64
    message: string

  CameraRelayManager* = ref object
    lock: Lock
    ffmpegPath: string
    relays: Table[string, CameraRelayProcess]

proc maskRtspUrl*(url: string): string =
  ## Hide credentials in an RTSP URL before placing it in logs or UI state.
  ## The original URL is still passed to ffmpeg as a normal process argument.
  let marker = "://"
  let schemePos = url.find(marker)
  if schemePos < 0:
    return url

  let authStart = schemePos + marker.len
  let slashRel = url[authStart .. ^1].find('/')
  let authEnd = if slashRel < 0: url.len else: authStart + slashRel
  let authority = url[authStart ..< authEnd]
  let atPos = authority.rfind('@')
  if atPos < 0:
    return url

  let hostPart = authority[atPos + 1 .. ^1]
  let suffix = if authEnd < url.len: url[authEnd .. ^1] else: ""
  result = &"{url[0 ..< authStart]}****@{hostPart}{suffix}"

proc relayStateName*(state: CameraRelayState): string =
  case state
  of crStopped: "stopped"
  of crRunning: "running"
  of crFailed: "failed"

proc buildRelayArgs*(
    sourceUrl, outputRtsp: string;
    logLevel = defaultRelayLogLevel
  ): seq[string] =
  ## Return the ffmpeg argument vector used for camera input normalization.
  ## Keep this shell-free: camera URLs commonly contain ?, &, @ and other
  ## characters that are easy to break when routed through a shell command line.
  @[
    "-nostdin",
    "-hide_banner",
    "-loglevel", logLevel,
    "-rtsp_transport", "tcp",
    "-fflags", "+genpts",
    "-i", sourceUrl,
    "-map", "0:v:0",
    "-an",
    "-c:v", "copy",
    "-f", "rtsp",
    "-rtsp_transport", "tcp",
    outputRtsp
  ]

proc newCameraRelayManager*(ffmpegPath: string): CameraRelayManager =
  new(result)
  initLock(result.lock)
  result.ffmpegPath = ffmpegPath.strip()
  result.relays = initTable[string, CameraRelayProcess]()

proc processPid(process: Process): int =
  if process == nil:
    return 0
  try:
    result = process.processID()
  except CatchableError:
    result = 0

proc processRunning(process: Process): bool =
  if process == nil:
    return false
  try:
    result = process.running()
  except CatchableError:
    result = false

proc statusOf(relay: CameraRelayProcess): CameraRelayStatus =
  result.slotId = relay.slotId
  result.pid = relay.process.processPid()
  result.sourceMasked = relay.sourceMasked
  result.outputRtsp = relay.outputRtsp
  result.startedAtUnix = relay.startedAtUnix
  result.message = relay.message
  if relay.process.processRunning():
    result.state = crRunning
  else:
    result.state = crFailed
    if result.message.len == 0:
      result.message = "relay process is not running"

proc stoppedStatus(slotId: string; message = "relay is stopped"): CameraRelayStatus =
  CameraRelayStatus(
    slotId: slotId,
    state: crStopped,
    pid: 0,
    sourceMasked: "",
    outputRtsp: "",
    startedAtUnix: 0,
    message: message
  )

proc stopRelayProcess(relay: CameraRelayProcess) =
  if relay == nil or relay.process == nil:
    return

  try:
    if relay.process.running():
      relay.process.terminate()
      discard relay.process.waitForExit(1500)
  except CatchableError:
    try:
      if relay.process.running():
        relay.process.kill()
    except CatchableError:
      discard
  finally:
    try:
      relay.process.close()
    except CatchableError:
      discard
    relay.process = nil

proc stopRelay*(manager: CameraRelayManager; slotId: string): CameraRelayStatus =
  if manager == nil:
    return stoppedStatus(slotId, "relay manager is not initialized")

  withLock manager.lock:
    if slotId notin manager.relays:
      return stoppedStatus(slotId)

    let relay = manager.relays[slotId]
    relay.stopRelayProcess()
    manager.relays.del(slotId)
    result = stoppedStatus(slotId, &"stopped relay for {slotId}")

proc startRelay*(
    manager: CameraRelayManager;
    slotId, sourceUrl, outputRtsp: string
  ): CameraRelayStatus =
  if manager == nil:
    return stoppedStatus(slotId, "relay manager is not initialized")
  if manager.ffmpegPath.len == 0:
    return CameraRelayStatus(slotId: slotId, state: crFailed, message: "ffmpeg path is empty")
  if slotId.strip().len == 0:
    return CameraRelayStatus(slotId: slotId, state: crFailed, message: "relay slot id is empty")
  if sourceUrl.strip().len == 0:
    return CameraRelayStatus(slotId: slotId, state: crFailed, message: "relay source URL is empty")
  if outputRtsp.strip().len == 0:
    return CameraRelayStatus(slotId: slotId, state: crFailed, message: "relay output URL is empty")

  withLock manager.lock:
    if slotId in manager.relays:
      let current = manager.relays[slotId]
      if current.sourceUrl == sourceUrl and
          current.outputRtsp == outputRtsp and
          current.process.processRunning():
        return statusOf(current)
      current.stopRelayProcess()
      manager.relays.del(slotId)

    let args = buildRelayArgs(sourceUrl, outputRtsp)
    var process: Process
    try:
      process = startProcess(
        manager.ffmpegPath,
        args = args,
        options = {poUsePath, poParentStreams}
      )
    except CatchableError as e:
      return CameraRelayStatus(
        slotId: slotId,
        state: crFailed,
        pid: 0,
        sourceMasked: maskRtspUrl(sourceUrl),
        outputRtsp: outputRtsp,
        startedAtUnix: 0,
        message: &"failed to start ffmpeg relay: {e.msg}"
      )

    let relay = CameraRelayProcess(
      slotId: slotId,
      sourceUrl: sourceUrl,
      sourceMasked: maskRtspUrl(sourceUrl),
      outputRtsp: outputRtsp,
      process: process,
      startedAtUnix: now().toTime().toUnix(),
      message: &"relay started for {slotId}"
    )
    manager.relays[slotId] = relay
    result = statusOf(relay)

proc relayStatus*(manager: CameraRelayManager; slotId: string): CameraRelayStatus =
  if manager == nil:
    return stoppedStatus(slotId, "relay manager is not initialized")

  withLock manager.lock:
    if slotId notin manager.relays:
      return stoppedStatus(slotId)
    result = statusOf(manager.relays[slotId])

proc stopAllRelays*(manager: CameraRelayManager) =
  if manager == nil:
    return

  withLock manager.lock:
    for slotId in toSeq(manager.relays.keys):
      let relay = manager.relays[slotId]
      relay.stopRelayProcess()
      manager.relays.del(slotId)

proc close*(manager: CameraRelayManager) =
  if manager == nil:
    return
  manager.stopAllRelays()
  deinitLock(manager.lock)
