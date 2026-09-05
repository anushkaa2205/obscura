import base64
import io
import os
import uuid

import piexif
from flask import Flask, request, jsonify, render_template
from PIL import Image

app = Flask(__name__)

REGION = os.environ.get("AWS_REGION", "ap-south-1")
BUCKET = os.environ.get("BUCKET_NAME")  # set on EC2 via `docker -e`; unset elsewhere

# ---------------------------------------------------------------------------
# Two storage modes, one codebase.
#
#   BUCKET set   -> AWS deployment. The clean copy goes to S3 under a random key
#                   and comes back as a short-lived presigned URL. This is
#                   REQUIRED there: two EC2 instances sit behind the ALB, so the
#                   download request may well land on the instance that didn't
#                   process the upload. Shared storage is the only correct answer.
#
#   BUCKET unset -> single-service deployment (Cloud Run, plain docker, local).
#                   There is no second instance to hand off to, so the clean copy
#                   is returned inline in the response and never persisted at
#                   all - not to disk, not to a bucket, not to a cache. Strictly
#                   stronger privacy than the S3 path, which keeps the cleaned
#                   file for up to a day before the lifecycle rule expires it.
#
# boto3 is imported lazily so a container running without a bucket never touches
# AWS credential resolution - which otherwise stalls on the EC2 metadata endpoint.
# ---------------------------------------------------------------------------
if BUCKET:
    import boto3
    from botocore.config import Config

    # endpoint_url is pinned to the regional S3 endpoint: without it, this
    # botocore version signs presigned URLs against the global s3.amazonaws.com
    # host, which 307-redirects non-us-east-1 buckets to the regional host and
    # breaks the signature (Host is a signed header) - the download link 403s
    # for every user.
    #
    # The timeouts matter as much as the endpoint. On defaults, an unreachable
    # or misnamed bucket leaves boto3 retrying for minutes while the gunicorn
    # worker is held hostage and the browser sits on a spinner. Fail in seconds
    # and return a real error instead.
    s3 = boto3.client(
        "s3",
        region_name=REGION,
        endpoint_url=f"https://s3.{REGION}.amazonaws.com",
        config=Config(
            connect_timeout=5,
            read_timeout=15,
            retries={"max_attempts": 2},
        ),
    )
else:
    s3 = None

# Direct mode returns the image inline as base64 (~1.33x the byte size), so cap
# it lower to stay well inside Cloud Run's 32 MB response ceiling. S3 mode only
# ever returns a URL, so it can afford the original 25 MB.
_DEFAULT_CAP_MB = 25 if BUCKET else 10
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", _DEFAULT_CAP_MB))
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD_MB * 1024 * 1024


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
        found["_gps"] = gps  # never sent to the client; see summarize_findings

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
    return jsonify({"error": f"File too large ({MAX_UPLOAD_MB} MB max)"}), 413


def summarize_findings(found):
    """
    Never send the actual sensitive values to the browser - only which
    categories of metadata were present. Rendering the real GPS coordinates,
    exact timestamp, or device model on screen (even briefly, even struck
    through) is itself an exposure: screen recording, shoulder-surfing, or a
    glance at the browser's Network tab would all still see it. This keeps
    the "we never log your metadata" promise consistent end-to-end - the
    real values live only in server memory for the split second it takes to
    strip them, and never reach the client at all.
    """
    return {k: "found — redacted" for k in found if not k.startswith("_")}


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
    mime = "image/jpeg" if fmt == "JPEG" else f"image/{ext}"
    orig_name = os.path.splitext(os.path.basename(f.filename or "photo"))[0]

    # NOTE: we deliberately never log `found` — that would leak GPS into
    # CloudWatch / Cloud Logging. We also never send the real values to the
    # browser — see summarize_findings.
    payload = {"found": summarize_findings(found), "stripped_count": total}

    if not BUCKET:
        # Direct mode: the clean copy goes straight back down the wire. It exists
        # in this response and nowhere else — there is no object to expire, no
        # key to guess, and no bucket policy to get wrong.
        payload["image_b64"] = base64.b64encode(clean_bytes).decode("ascii")
        payload["filename"] = f"obscura_{orig_name}.{ext}"
        payload["mime"] = mime
        return jsonify(payload)

    key = f"clean/{uuid.uuid4().hex}.{ext}"  # random, unguessable
    try:
        s3.put_object(Bucket=BUCKET, Key=key, Body=clean_bytes, ContentType=mime)
        payload["download_url"] = s3.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": BUCKET,
                "Key": key,
                "ResponseContentDisposition": (
                    f'attachment; filename="obscura_{orig_name}.{ext}"'
                ),
            },
            ExpiresIn=900,  # 15 min — was 5, too easy to let the link go stale mid-demo
        )
    except Exception as e:
        # Surface a clean JSON error instead of letting the browser hit a raw
        # AWS XML page if S3 is unreachable or the presigned URL fails to build.
        return jsonify({"error": f"Upload to storage failed: {e}"}), 502

    return jsonify(payload)


if __name__ == "__main__":
    # Cloud Run injects PORT; everything else defaults to 8080.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
