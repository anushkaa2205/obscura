# Obscura — strip the story your photos tell

### The photo that says more than you meant it to

You take a photo — nothing dangerous in frame, no faces, no address — and upload it to a listing or a profile. Hidden inside the file, though, is a string of numbers your camera wrote automatically: GPS coordinates accurate to a few meters, plus your exact device model and the second the shutter clicked. This isn't hypothetical — it's how people have been geolocated from a single innocent-looking photo. Apps like WhatsApp and Instagram already strip this quietly, which is exactly why most people never notice it exists elsewhere — the moment you use a channel that doesn't, that data rides along untouched.

**Obscura strips that hidden metadata out of your photos before anyone else sees it.** Drop in an image, it shows you exactly what was buried inside, then hands back a clean copy with none of it.

---

## Live demo

**http://obscura-alb-855727591.ap-south-1.elb.amazonaws.com/**

> This is served directly over HTTP for now. HTTPS via CloudFront is built and ready to switch on once AWS account verification clears.

## How to test it

The point of Obscura is only provable if your test photo actually *has* metadata to strip. A few platforms (WhatsApp, Instagram, Telegram) already strip EXIF data before you ever see the image, so testing with a photo that passed through one of those will show nothing — that's the app working correctly, not failing.

1. **Get a genuine test photo.** Take one with your phone's camera app, then transfer it to your computer *without* going through a messaging app — use a USB cable straight from `DCIM/Camera`, or download "original quality" from Google Photos.
2. **Check it has metadata first.** Right-click the file → Properties → Details tab. Look for populated GPS latitude/longitude, camera make/model, and date taken fields. If they're blank, the photo has nothing to strip — try a different one.
3. **Upload it to Obscura.** Drop it on the page. The "Hidden data found in your photo" panel lists which categories of metadata were present — Camera/device, GPS location, Taken at — without ever displaying the actual values on screen (see [Privacy-by-design UI](#privacy-by-design-ui) below for why).
4. **Download the cleaned copy** from the button that appears.
5. **Verify independently.** Right-click the *downloaded* file → Properties → Details tab. GPS and camera fields should now be empty. That's proof the strip worked, checked outside the app's own claims.

## Architecture

```
Browser ──HTTP──▶ Application Load Balancer ──┬──▶ EC2 (AZ-a, Docker/Flask)
                                                └──▶ EC2 (AZ-b, Docker/Flask)
                                                              │
                                                              ▼
                                          S3 bucket (clean output only, 1-day lifecycle)
                                          auth via IAM instance role — no access keys on host

Planned once CloudFront clears account verification:
Browser ──HTTPS──▶ CloudFront ──HTTP (locked to CloudFront's IP range)──▶ ALB → ...
```

- Custom **VPC**, two public subnets across two Availability Zones (ap-south-1a / ap-south-1b)
- **Application Load Balancer** health-checks both EC2 instances on `/health` and only routes to healthy targets
- Each EC2 instance runs the app in **Docker**, built from this repo's `Dockerfile` via a `git clone` + `docker build` in the instance's user-data boot script
- EC2 authenticates to **S3** via an **IAM instance role** scoped to `PutObject`/`GetObject`/`DeleteObject` on exactly one bucket — no static credentials anywhere
- Security groups: the EC2 instances only accept port 8080 from the ALB's security group (never the open internet); SSH is restricted to a single IP
- Uploaded originals are processed **entirely in memory** and never written to disk, on the instance or anywhere else
- Cleaned copies are stored under random UUID keys (unguessable) and auto-expire after 1 day via an S3 lifecycle rule
- Download links are short-lived presigned S3 URLs (15-minute expiry), not public objects

## Privacy-by-design UI

The "reveal" panel intentionally does **not** show the actual GPS coordinates, timestamp, or device model — only that each category was found and redacted. The server computes the real values to strip them, but the response sent to the browser never includes them (see `summarize_findings()` in `app.py`). Rendering real sensitive data on screen — even briefly, even with a strike-through animation — is itself an exposure risk: screen recording, shoulder-surfing, or a glance at the browser's Network tab would all still see it. This keeps the app's own "we never log your metadata" promise consistent end-to-end.

## Notable engineering decisions

A few things worth knowing if you're reading this as documentation rather than just running the app:

- **Fast metadata strip.** The strip function copies the image via Pillow's internal pixel copy and wipes `.info` (where EXIF/ICC profile/comments/thumbnails all live), rather than rebuilding the image pixel-by-pixel through a Python list. On a real 12MP+ phone photo this is roughly **18× faster** — the naive approach was slow enough on a memory-constrained t3.micro to occasionally time out the request entirely.
- **Regional S3 endpoint pinning.** `boto3.client("s3", ...)` is created with an explicit regional `endpoint_url`. Without it, this botocore version signs presigned URLs against the global `s3.amazonaws.com` host, which redirects non-`us-east-1` buckets to the regional host — breaking the signature, since `Host` is a signed header. This caused every download link to fail with `SignatureDoesNotMatch` until pinned explicitly.
- **Upload cap.** Requests are capped at 25 MB (`MAX_CONTENT_LENGTH`) so a single large upload can't exhaust a t3.micro's 1 GB of RAM.
- **Clean JSON errors.** S3 failures return a JSON error instead of letting the browser hit a raw AWS XML error page.

## Tech stack

Python · Flask · Pillow · piexif · Docker · gunicorn — deployed on AWS (VPC, EC2, S3, IAM, Application Load Balancer, CloudFront)

## Running locally

Requires Docker.

```bash
git clone https://github.com/anushkaa2205/obscura.git
cd obscura
docker build -t obscura .
docker run --rm -p 8080:8080 obscura
```

Open `http://localhost:8080`. The upload/reveal/strip flow works fully offline. The final S3 upload step needs real AWS credentials and an existing bucket to actually complete — for a full local test, pass them in:

```bash
docker run --rm -p 8080:8080 \
  -e AWS_REGION=ap-south-1 \
  -e BUCKET_NAME=your-bucket-name \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  obscura
```

(The deployed version uses an IAM instance role instead of static keys — that's the correct pattern and only available when actually running on EC2.)

## Deploying to AWS

Three PowerShell scripts automate the entire stack (region `ap-south-1`, cost roughly $1–1.50/day while running):

```powershell
# set $GITHUB_USER at the top of deploy.ps1 first, and push this repo PUBLIC
./deploy.ps1     # builds VPC → subnets → security groups → S3 + IAM → 2× EC2 → ALB → CloudFront
./status.ps1     # read-only: lists every live resource, useful after an interrupted run
./cleanup.ps1    # tears down everything, including partial/duplicate resources from a failed run
```

`deploy.ps1` is idempotent and resumable — if it fails partway (a common real-world case: AWS vCPU quota limits, transient API errors), re-running it picks up exactly where it left off rather than duplicating resources.

## Project structure

```
obscura/
├── app.py                 # Flask app: EXIF read/strip, S3 upload, presigned URLs
├── templates/index.html   # Single-page UI (drop zone, reveal panel, download)
├── Dockerfile
├── requirements.txt
├── deploy.ps1              # Full AWS stack deploy (idempotent/resumable)
├── status.ps1              # Read-only live-resource report
├── cleanup.ps1              # Full AWS stack teardown
├── userdata.sh              # EC2 boot script (generated by deploy.ps1)
├── trust.json / s3policy.json  # IAM role/policy documents (generated by deploy.ps1)
├── lifecycle.json           # S3 lifecycle rule (generated by deploy.ps1)
├── cf-config.json           # CloudFront distribution config (generated by deploy.ps1)
└── state.env                 # Deploy state (resource IDs), for resumability
```
