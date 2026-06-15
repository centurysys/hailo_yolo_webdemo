## Small job id generator.
##
## A random-looking, URL-safe id is enough here.  The job store is in-memory and
## /var/tmp-backed, so this does not need to be a stable database key.

import std/[random, strformat, strutils, times]

var seeded = false

proc ensureSeeded() =
  if not seeded:
    randomize()
    seeded = true

proc newJobId*(): string =
  ensureSeeded()
  let nowMs = int64(epochTime() * 1000)
  let rnd = rand(0x7fffffff)
  result = &"j{nowMs.toHex}-{rnd.toHex}"
