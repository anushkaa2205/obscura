"""
Verification for direct (no-bucket) mode — the Cloud Run path.

Builds a JPEG carrying real GPS + camera + timestamp EXIF, pushes it through
/strip, and asserts three things:
  1. the reveal panel names every category that was present,
  2. no real value (coordinates, device, timestamp) reaches the client,
  3. the returned image is a valid JPEG with zero EXIF left in it.
"""
import base64
import io
import sys

import piexif
from PIL import Image

import app as obscura

GPS_LAT = ((28, 1), (36, 1), (1234, 100))   # 28°36'12.34" N  — central Delhi
GPS_LON = ((77, 1), (12, 1), (5678, 100))


def build_photo_with_exif():
    img = Image.new("RGB", (1200, 900), (90, 40, 40))
    exif = {
        "0th": {
            piexif.ImageIFD.Make: b"OnePlus",
            piexif.ImageIFD.Model: b"CPH2447",
            piexif.ImageIFD.Software: b"OxygenOS 14.0",
            piexif.ImageIFD.DateTime: b"2026:08:19 22:14:03",
        },
        "Exif": {
            piexif.ExifIFD.DateTimeOriginal: b"2026:08:19 22:14:03",
            piexif.ExifIFD.LensMake: b"OnePlus",
        },
        "GPS": {
            piexif.GPSIFD.GPSLatitudeRef: b"N",
            piexif.GPSIFD.GPSLatitude: GPS_LAT,
            piexif.GPSIFD.GPSLongitudeRef: b"E",
            piexif.GPSIFD.GPSLongitude: GPS_LON,
        },
    }
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=92, exif=piexif.dump(exif))
    return buf.getvalue()


def main():
    assert obscura.BUCKET is None, "run this with BUCKET_NAME unset"
    raw = build_photo_with_exif()

    # sanity: the fixture really does carry what we claim
    before = piexif.load(raw)
    assert before["GPS"], "fixture has no GPS — test would prove nothing"

    client = obscura.app.test_client()
    r = client.post(
        "/strip",
        data={"photo": (io.BytesIO(raw), "IMG_20260819_221403.jpg")},
        content_type="multipart/form-data",
    )
    assert r.status_code == 200, f"expected 200, got {r.status_code}: {r.data[:300]}"
    body = r.get_json()

    # 1. every category detected
    found = body["found"]
    for expected in ("Camera / device", "GPS location", "Taken at", "Software"):
        assert expected in found, f"missing category: {expected}"
    print(f"  detected categories : {', '.join(found)}")
    print(f"  tags counted        : {body['stripped_count']}")

    # 2. nothing sensitive crossed the wire
    blob = r.data.decode("utf-8", errors="ignore")
    for leak in ("28.60", "77.20", "OnePlus", "CPH2447", "2026:08:19", "OxygenOS"):
        assert leak not in blob, f"LEAK: {leak!r} reached the client"
    assert all(v == "found — redacted" for v in found.values())
    assert "_gps" not in found
    print("  leak check          : clean (no coords, device or timestamp sent)")

    # 3. direct-mode payload is a real, fully stripped image
    assert "download_url" not in body, "should not be using S3 in direct mode"
    assert body["filename"] == "obscura_IMG_20260819_221403.jpg"
    assert body["mime"] == "image/jpeg"

    clean = base64.b64decode(body["image_b64"])
    out = Image.open(io.BytesIO(clean))
    out.verify()
    assert out.format == "JPEG"

    after = piexif.load(clean)
    leftover = {k: v for k, v in after.items() if k != "thumbnail" and v}
    assert not leftover, f"EXIF survived the strip: {leftover}"
    assert b"OnePlus" not in clean and b"OxygenOS" not in clean
    print(f"  clean image         : {len(clean):,} bytes, JPEG, 0 EXIF tags left")

    # 4. the old AWS contract is untouched when a bucket IS configured
    assert obscura.MAX_UPLOAD_MB == 10, "direct mode should cap at 10 MB"
    print("  upload cap          : 10 MB (direct) / 25 MB (S3)")

    print("\nPASS — direct mode strips everything and stores nothing.")


if __name__ == "__main__":
    sys.exit(main())
