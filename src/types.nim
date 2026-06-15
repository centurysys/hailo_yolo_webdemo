## Common types shared by the web layer, job store, media pipeline and worker.

import std/strformat

type
  JobKind* = enum
    jkJpeg
    jkMp4

  JobStatus* = enum
    jsQueued
    jsRunning
    jsDone
    jsFailed

  Detection* = object
    classId*: int
    label*: string
    score*: float32
    x*: float32
    y*: float32
    w*: float32
    h*: float32

  JobInfo* = object
    id*: string
    kind*: JobKind
    status*: JobStatus
    inputPath*: string
    outputPath*: string
    originalName*: string
    message*: string
    progress*: int
    createdAtUnix*: int64
    updatedAtUnix*: int64

proc toWire*(kind: JobKind): string =
  case kind
  of jkJpeg: "jpeg"
  of jkMp4: "mp4"

proc toWire*(status: JobStatus): string =
  case status
  of jsQueued: "queued"
  of jsRunning: "running"
  of jsDone: "done"
  of jsFailed: "failed"

proc extension*(kind: JobKind): string =
  case kind
  of jkJpeg: ".jpg"
  of jkMp4: ".mp4"

proc contentType*(kind: JobKind): string =
  case kind
  of jkJpeg: "image/jpeg"
  of jkMp4: "video/mp4"

proc `$`*(kind: JobKind): string = kind.toWire
proc `$`*(status: JobStatus): string = status.toWire

proc summary*(job: JobInfo): string =
  &"{job.id} {job.kind.toWire} {job.status.toWire} {job.progress}% {job.message}"
