## JSON API response helpers.
##
## Keep JSON generation out of handlers/pages.  Sunny lets us serialize small
## response objects directly, avoiding hand-written JSON strings and formatter
## brace escaping.

import sunny

import ../types

type
  UploadResponse = object
    id: string
    kind: string
    status: string

  JobResponse = object
    id: string
    kind: string
    status: string
    progress: int
    message {.json: ",omitempty".}: string
    originalName {.json: "originalName,omitempty".}: string

proc encodeJson[T](value: T): string {.gcsafe.} =
  ## Sunny serialization is pure string generation.  Mummy requires handlers to
  ## be GC-safe, so keep the cast at this boundary instead of sprinkling it in
  ## each handler.
  {.cast(gcsafe).}:
    result = value.toJson()

proc uploadJson*(job: JobInfo): string {.gcsafe.} =
  UploadResponse(
    id: job.id,
    kind: job.kind.toWire,
    status: job.status.toWire
  ).encodeJson()

proc jobJson*(job: JobInfo): string {.gcsafe.} =
  JobResponse(
    id: job.id,
    kind: job.kind.toWire,
    status: job.status.toWire,
    progress: job.progress,
    message: job.message,
    originalName: job.originalName
  ).encodeJson()
