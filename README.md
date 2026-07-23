# Obscura — strip the story your photos tell

A privacy tool that removes hidden EXIF/GPS metadata from photos, deployed on AWS.

**Live:** https://YOUR_ID.cloudfront.net  ·  **Region:** ap-south-1 (Mumbai)

## Why

Every phone photo carries hidden metadata: the GPS coordinates of where it was
taken, your device model, timestamps, editing software. Share it online and you
may be broadcasting your home address. Obscura shows you exactly what's hidden,
then strips it and hands back a clean copy.

## Architecture

```
Browser ──HTTPS──▶ CloudFront ──HTTP (locked to CloudFront IPs)──▶ ALB
                                                                    │
                                              ┌─────────────────────┴───────┐
                                              ▼                             ▼
                                        EC2 (AZ-a)                    EC2 (AZ-b)
                                       Docker/Flask                  Docker/Flask
                                              └─────────────┬───────────────┘
                                                            ▼
                                              S3 (clean output, 1-day expiry)
                                          auth via IAM instance role — no keys
```

- Custom **VPC**, 2 public subnets across 2 Availability Zones
- EC2 authenticates to **S3** via an **IAM instance role** — no access keys on the host
- Uploaded originals are processed **in memory** and never written to disk
- Cleaned copies use random keys and **auto-expire after 24 h** (S3 lifecycle)
- ALB is **locked to CloudFront's IP range**; instances only accept traffic from the ALB
- Uploads capped at 25 MB; metadata values are never logged

## Stack

Python · Flask · Pillow · piexif · Docker · AWS (VPC, EC2, S3, IAM, ALB, CloudFront)

## Deploy / tear down

PowerShell + AWS CLI (from the repo root):

```powershell
# set $GITHUB_USER at the top of deploy.ps1 first, and push this repo PUBLIC
./deploy.ps1     # build the whole stack (idempotent + resumable)
./status.ps1     # read-only: list every live resource
./cleanup.ps1    # delete everything when you're done
```

## Privacy design & honest limitation

The correct architecture for a pure privacy tool is client-side stripping
(nothing ever uploaded). Server-side processing was chosen here to satisfy the
cloud-architecture requirement of the course. A production version would strip in
the browser and use the server only for optional storage. This tradeoff is
deliberate and documented.
