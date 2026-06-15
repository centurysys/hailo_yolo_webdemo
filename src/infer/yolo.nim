## YOLO result helpers.
##
## HAILO inference is not connected yet.  The dummy boxes in this file are
## deliberately expressed in YOLO input coordinates, then restored through the
## same letterbox mapping that real YOLOv11s detections will use.

import ../media/convert
import ../types

proc classLabel*(classId: int): string =
  case classId
  of 0: "person"
  of 2: "car"
  of 16: "dog"
  else: "class" & $classId

proc demoYoloInputDetections*(): seq[Detection] =
  ## Fixed detections in 640x640 model-input coordinates.
  ##
  ## These are not meant to match the uploaded image.  They only validate that
  ## "input-space bbox -> original-image bbox" conversion is wired correctly.
  result = @[
    Detection(classId: 0, label: classLabel(0), score: 0.91.float32,
      x: 55.float32, y: 190.float32, w: 175.float32, h: 310.float32),
    Detection(classId: 16, label: classLabel(16), score: 0.87.float32,
      x: 325.float32, y: 325.float32, w: 150.float32, h: 135.float32),
    Detection(classId: 2, label: classLabel(2), score: 0.76.float32,
      x: 385.float32, y: 160.float32, w: 200.float32, h: 95.float32)
  ]

proc restoreDetections*(detections: openArray[Detection]; info: YoloLetterboxInfo): seq[Detection] =
  for d in detections:
    result.add(d.restoreDetectionFromInput(info))

proc demoDetectionsForLetterbox*(info: YoloLetterboxInfo): seq[Detection] =
  result = demoYoloInputDetections().restoreDetections(info)
