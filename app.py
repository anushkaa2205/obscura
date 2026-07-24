import io
import os
import uuid

import boto3
import piexif
from flask import Flask, request, jsonify, render_template
from PIL import Image

app = Flask(__name__)

# Cap uploads so a huge file can't exhaust a t3.micro's memory (1 GB RAM).
app.config["MAX_CONTENT_LENGTH"] = 25 * 1024 * 1024  # 25 MB

REGION = os.environ.get("AWS_REGION", "ap-south-1")
BUCKET = os.environ.get("BUCKET_NAME")  # set on the EC2 instance via docker -e

# boto3 automatically uses the EC2 instance's IAM role — no keys stored anywhere.
# endpoint_url is pinned to the regional S3 endpoint: without it, this botocore
# version signs presigned URLs against the global s3.amazonaws.com host, which
# 307-redirects non-us-east-1 buckets to the regional host and breaks the
# signature (Host is a signed header) - the download link 403s for every user.
s3 = boto3.client(
    "s3", region_name=REGION, endpoint_url=f"https://s3.{REGION}.amazonaws.com"
)


def _ratio(x):
    """piexif stores rationals as (numerator, denominator)."""
    return x[0] / x[1] if x[1] else 0.0


def parse_gps(exif_dict):
    """Turn raw GPS EXIF into human lat/lon, or None if absent."""
    gps = exif_dict.get("GPS") or {}
    try:
        lat = gps[piexif.GPSIFD.GPSLatitude]
        lon = gps[piexif.GPSIFD.GPSLongitude]
        lat_ref = gps[piexif.GPSIFD.GPSLatitudeRef]
        lon_ref = gps[piexif.GPSIFD.GPSLongitudeRef]
    except KeyError:
        return None

    def to_deg(dms, ref):
        deg = _ratio(dms[0]) + _ratio(dms[1]) / 60 + _ratio(dms[2]) / 3600
        if ref in (b"S", b"W"):
            deg = -deg
        return round(deg, 6)

    return {"lat": to_deg(lat, lat_ref), "lon": to_deg(lon, lon_ref)}


def read_metadata(raw):
    """Extract the interesting hidden fields for the 'reveal' UI. Read only."""
    found = {}
    total = 0
    try:
        exif_dict = piexif.load(raw)
    except Exception:
        return found, 0

    # Count every tag present across all IFDs = "how much was hidden"
    for ifd in ("0th", "Exif", "GPS", "1st"):
        total += len(exif_dict.get(ifd) or {})

    zeroth = exif_dict.get("0th") or {}
    exif_ifd = exif_dict.get("Exif") or {}

    def dec(v):
        return v.decode(errors="ignore").strip() if isinstance(v, bytes) else v

    make = dec(zeroth.get(piexif.ImageIFD.Make))
    model = dec(zeroth.get(piexif.ImageIFD.Model))
    if make or model:
        found["Camera / device"] = f"{make or ''} {model or ''}".strip()

    sw = dec(zeroth.get(piexif.ImageIFD.Software))
    if sw:
        found["Software"] = sw

    dt = dec(zeroth.get(piexif.ImageIFD.DateTime)) or dec(
        exif_ifd.get(piexif.ExifIFD.DateTimeOriginal)
    )
    if dt:
        found["Taken at"] = dt

    gps = parse_gps(exif_dict)
    if gps:
        found["GPS location"] = f"{gps['lat']}, {gps['lon']}"
        found["_gps"] = gps  # used by the frontend map link

    return found, total


def strip_metadata(raw):
    """
    Bulletproof strip: copy the image (PIL's fast internal pixel copy) and
    wipe .info, which is where PIL sources EXIF/ICC profile/comments/thumbnails
    for every format on save. Equivalent guarantee to rebuilding pixel-by-pixel,
    but avoids materializing a Python list of every pixel as a tuple - which
    was slow/heavy enough on real 12-50MP phone photos to time out or exhaust
    memory on a t3.micro (the ALB then returns its own HTML error page instead
    of JSON, which is what "Unexpected token '<'" in the UI means).
    Returns (clean_bytes, out_format).
    """
    img = Image.open(io.BytesIO(raw))
    fmt = (img.format or "JPEG").upper()

    clean = img.copy()
    clean.info = {}  # drops exif, icc_profile, comment, dpi, thumbnails, etc.

    if fmt in ("JPEG", "JPG", "MPO") and clean.mode not in ("RGB", "L"):
        clean = clean.convert("RGB")  # JPEG can't save RGBA/P/CMYK-with-alpha etc.

    out = io.BytesIO()
    save_fmt = "JPEG" if fmt in ("JPG", "JPEG", "MPO") else fmt
    if save_fmt == "JPEG":
        clean.save(out, format="JPEG", quality=95)
    else:
        clean.save(out, format=save_fmt)
    out.seek(0)
    return out.read(), save_fmt


@app.errorhandler(413)
def too_large(_e):
    return jsonify({"error": "File too large (25 MB max)"}), 413


@app.route("/health")
def health():
    # The ALB target group pings this. Must return 200.
    return "ok", 200


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/strip", methods=["POST"])
def strip():
    if "photo" not in request.files:
        return jsonify({"error": "No file uploaded"}), 400

    f = request.files["photo"]
    raw = f.read()  # in memory only — the original never touches disk
    if not raw:
        return jsonify({"error": "Empty file"}), 400

    try:
        found, total = read_metadata(raw)
        clean_bytes, fmt = strip_metadata(raw)
    except Exception as e:
        return jsonify({"error": f"Could not process image: {e}"}), 400

    ext = "jpg" if fmt == "JPEG" else fmt.lower()
    key = f"clean/{uuid.uuid4().hex}.{ext}"  # random, unguessable
    orig_name = os.path.splitext(os.path.basename(f.filename or "photo"))[0]

    try:
        s3.put_object(
            Bucket=BUCKET,
            Key=key,
            Body=clean_bytes,
            ContentType=f"image/{ext}",
        )
        download_url = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET,
                "Key": key,
                "ResponseContentDisposition": f'attachment; filename="obscura_{orig_name}.{ext}"',
            },
            ExpiresIn=900,  # 15 min — was 5, too easy to let the link go stale mid-demo
        )
    except Exception as e:
        # Surface a clean JSON error instead of letting the browser hit a raw
        # AWS XML page if S3 is unreachable or the presigned URL fails to build.
        return jsonify({"error": f"Upload to storage failed: {e}"}), 502

    # NOTE: we deliberately never log `found` — that would leak GPS into CloudWatch.
    return jsonify(
        {
            "found": found,
            "stripped_count": total,
            "download_url": download_url,
        }
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
