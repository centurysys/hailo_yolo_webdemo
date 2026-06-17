# Package

version       = "0.1.0"
author        = "Takeyoshi Kikuchi"
description   = "HAILO YOLOv11s web demo appliance"
license       = "MIT"
srcDir        = "src"
binDir        = "bin"
bin           = @[
#    "hailo_live_rtsp_publish_probe",
    "hailo_yolo_webdemo"
]


# Dependencies

requires "nim >= 2.2.10"
requires "argparse >= 4.0.2"
requires "mummy >= 0.4.8"
requires "pixie >= 6.1.0"
requires "sunny >= 0.1.10"

requires "threadtools >= 0.1.0"
requires "hailort_nim >= 0.2.0"
requires "libav_nim >= 0.1.0"
requires "libyuv_nim >= 0.1.0"
requires "libturbojpeg_nim >= 0.1.0"
requires "hyper_jpeg >= 0.1.0"
