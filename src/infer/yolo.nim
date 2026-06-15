## YOLO result helpers.
##
## This module contains:
## - COCO class label mapping
## - dummy detections for non-HAILO bring-up
## - conversion from HailoRT normalized detections to app-space detections

import hailort_nim

import ../media/convert
import ../types as appTypes

const cocoLabels*: array[80, string] = [
  "person", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
  "truck", "boat", "traffic light", "fire hydrant", "stop sign",
  "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep",
  "cow", "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella",
  "handbag", "tie", "suitcase", "frisbee", "skis", "snowboard",
  "sports ball", "kite", "baseball bat", "baseball glove", "skateboard",
  "surfboard", "tennis racket", "bottle", "wine glass", "cup", "fork",
  "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
  "broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair",
  "couch", "potted plant", "bed", "dining table", "toilet", "tv",
  "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave",
  "oven", "toaster", "sink", "refrigerator", "book", "clock", "vase",
  "scissors", "teddy bear", "hair drier", "toothbrush"
]

proc classLabel*(classId: int): string =
  if classId >= 0 and classId < cocoLabels.len:
    result = cocoLabels[classId]
  else:
    result = "class" & $classId

proc demoYoloInputDetections*(): seq[appTypes.Detection] =
  ## Fixed detections in 640x640 model-input coordinates.
  ##
  ## These are not meant to match the uploaded image.  They only validate that
  ## "input-space bbox -> original-image bbox" conversion is wired correctly.
  result = @[
    appTypes.Detection(classId: 0, label: classLabel(0), score: 0.91.float32,
      x: 55.float32, y: 190.float32, w: 175.float32, h: 310.float32),
    appTypes.Detection(classId: 16, label: classLabel(16), score: 0.87.float32,
      x: 325.float32, y: 325.float32, w: 150.float32, h: 135.float32),
    appTypes.Detection(classId: 2, label: classLabel(2), score: 0.76.float32,
      x: 385.float32, y: 160.float32, w: 200.float32, h: 95.float32)
  ]

proc restoreDetections*(
    detections: openArray[appTypes.Detection];
    info: YoloLetterboxInfo
  ): seq[appTypes.Detection] =
  for d in detections:
    result.add(d.restoreDetectionFromInput(info))

proc demoDetectionsForLetterbox*(info: YoloLetterboxInfo): seq[appTypes.Detection] =
  result = demoYoloInputDetections().restoreDetections(info)

proc toAppInputDetection*(
    d: hailort_nim.Detection;
    info: YoloLetterboxInfo
  ): appTypes.Detection =
  ## HailoRT NMS-by-class parser returns normalized x/y min/max in model input
  ## space.  Convert that to pixel-space bbox in the 640x640 input coordinate
  ## system.  The caller can then restore it through the shared letterbox info.
  let
    x1 = d.xMin * info.inputW.float32
    y1 = d.yMin * info.inputH.float32
    x2 = d.xMax * info.inputW.float32
    y2 = d.yMax * info.inputH.float32

  result = appTypes.Detection(
    classId: d.classId,
    label: classLabel(d.classId),
    score: d.score,
    x: x1,
    y: y1,
    w: x2 - x1,
    h: y2 - y1
  )

proc hailoDetectionsToApp*(
    detections: openArray[hailort_nim.Detection];
    info: YoloLetterboxInfo
  ): seq[appTypes.Detection] =
  for d in detections:
    result.add(d.toAppInputDetection(info).restoreDetectionFromInput(info))
