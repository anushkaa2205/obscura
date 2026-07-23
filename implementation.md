# Obscura — Implementation Guide

> **Strip the story your photos tell.**
> A privacy tool that removes hidden EXIF/GPS metadata from photos, deployed on AWS.

This document is a **nano-step build guide**. Every command, every file, every value to type is here. Follow it top to bottom and you will end with a live, HTTPS web app on your own AWS account and a GitHub repo you can submit.

---

## 0. What you are building

**The product.** A user opens Obscura, drops in a photo. Obscura reads the hidden metadata the camera baked in — GPS coordinates (where the photo was taken), the exact device model, the timestamp, editing software — and *shows the user what was secretly there*. Then it strips all of it and hands back a clean copy. The original geotagged file is **never written to disk** anywhere; only the scrubbed copy is stored, and that auto-deletes within a day.

**The architecture (this is what your course grades).**

```
                 HTTPS
   Browser  ─────────────►  CloudFront  (*.cloudfront.net, free TLS)
                                 │  HTTP (locked to CloudFront IPs)
                                 ▼
                          Application Load Balancer   ── public subnet A ┐
                                 │                                        │  2 Availability Zones
                          ┌──────┴───────┐            ── public subnet B ┘
                          ▼              ▼
                      EC2  (AZ-a)     EC2  (AZ-b)      Docker container (Flask app)
                          │              │
                          └──────┬───────┘
                                 ▼
                          S3 bucket (clean output only, 1-day expiry)
                     auth via IAM instance role — no access keys on the box
```

Everything lives inside a **custom VPC** you build yourself, in region **ap-south-1 (Mumbai)**.

**Syllabus modules this hits:** Linux (EC2/SSH/bash), EC2, S3, IAM, VPC + security groups, Elastic Load Balancing (ALB), Docker containerisation — **7 of 8**. Cloud concepts + multi-cloud go in your written report as theory.

**Cost:** run it for a week and tear it down and you'll spend roughly **$3–5** of your $80 credit. Teardown steps are in Section 14 — do them when you're done.

**Time budget:** ~4 h app + Docker, ~5 h infra, ~2 h CloudFront + debugging, ~3 h README/diagram/screenshots, ~2 h buffer.

> **Automated path (recommended).** The repo ships three PowerShell scripts that do everything in Sections 6–14 for you, safely:
> - `deploy.ps1` — builds the whole stack. **Idempotent and resumable**: it writes `state.env` after every resource, so if a run fails partway you just run it again and it picks up where it left off.
> - `status.ps1` — **read-only**. Lists every live Obscura resource by name/tag. Run this first if a previous attempt half-finished, to see what's already out there.
> - `cleanup.ps1` — **complete teardown**. Deletes everything (CloudFront disable+delete, both instances, ALB, target group, SGs, subnets, route table, IGW, VPC, S3, IAM role/profile/policy, key pair), discovering resources by name/tag even if `state.env` is incomplete.
>
> Set `$GITHUB_USER` at the top of `deploy.ps1` first, push your repo public, then run `./deploy.ps1`. The manual CLI steps below remain the reference for understanding what each script does — and for your report.

---

## 1. Table of contents

1. What you're building
2. Prerequisites & sanity checks
3. The app — full source code
4. Test the container locally
5. Push to GitHub
6. AWS: networking (VPC, subnets, IGW, routes)
7. AWS: security groups
8. AWS: IAM role + S3 bucket
9. AWS: EC2 instances (×2)
10. AWS: Target group + ALB
11. AWS: CloudFront + lock down the ALB
12. End-to-end verification
13. Screenshots & report checklist
14. Teardown (do this to stop spend)
15. Troubleshooting
16. Appendix: syllabus mapping

---

## 2. Prerequisites & sanity checks

You said your AWS account and CLI are already set up. Confirm it and set the working region.

```bash
# Confirm the CLI can talk to AWS and see WHO you are
aws sts get-caller-identity
# → should print your Account, UserId, Arn. If it errors, run `aws configure` first.

# Pin the region for this whole session
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION=ap-south-1

# A short project prefix used to name everything, so it's easy to find & delete later
export PROJECT=obscura

# Confirm the region took
aws configure get region || echo "using env AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
```

You also need, installed locally:

- **Docker** — `docker --version` (to build/test the image before it ever hits AWS)
- **git** + a **GitHub account** (the EC2 boxes clone your repo to build the app)
- **jq** (optional but handy) — `jq --version`

> **Important about shell variables:** every `export FOO=$(...)` below stores an ID you'll reuse later. **Keep the same terminal window open** for the whole build. If you close it, the variables vanish. Section 15 shows how to recover any ID from the console if that happens.

---

## 3. The app — full source code

Create a project folder and these five files.

```bash
mkdir -p ~/obscura && cd ~/obscura
```

### 3.1 `app.py`

The whole backend. It: serves the UI, accepts one uploaded photo, reads its metadata **in memory**, strips everything by re-encoding the raw pixels into a fresh image (no metadata survives), uploads only the clean copy to S3 under a random key, and returns a short-lived presigned download link plus the list of what it found.

```python
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
s3 = boto3.client("s3", region_name=REGION)


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
    Bulletproof strip: decode to raw pixels, re-encode into a brand-new image.
    No EXIF, no GPS, no thumbnails, no maker notes can survive this.
    Returns (clean_bytes, out_format).
    """
    img = Image.open(io.BytesIO(raw))
    fmt = (img.format or "JPEG").upper()
    if fmt == "JPEG":
        img = img.convert("RGB")

    clean = Image.new(img.mode, img.size)
    clean.putdata(list(img.getdata()))
    if img.mode == "P":  # palette images: carry the colour table, not just indices
        clean.putpalette(img.getpalette())

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
        ExpiresIn=300,  # link dies in 5 minutes
    )

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
```

### 3.2 `requirements.txt`

```
Flask==3.0.3
Pillow==10.4.0
piexif==1.1.3
boto3==1.34.140
gunicorn==22.0.0
```

### 3.3 `Dockerfile`

```dockerfile
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

EXPOSE 8080
# 2 workers is plenty for a t3.micro
CMD ["gunicorn", "-b", "0.0.0.0:8080", "-w", "2", "--timeout", "60", "app:app"]
```

### 3.4 `templates/index.html`

This is the creative part. The theme is a **photographic darkroom**: near-black background, a red "safelight" glow, film-grain texture, monospace metadata readout like a light-table. The UX is built around a reveal: when you drop a photo it "develops," then dramatically exposes the hidden data it found (with a live map pin if there's GPS), then **redacts** each line with a strike-through animation before handing you the clean file. The point of the design is to make the invisible privacy leak *visible* — then watch it get erased.

```bash
mkdir -p ~/obscura/templates
```

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Obscura — strip the story your photos tell</title>
<style>
  :root{
    --bg:#0b0b0d; --panel:#141418; --ink:#e9e6df; --muted:#7d7a73;
    --safelight:#ff3b30; --amber:#ffb020; --line:#26262c; --ok:#4ade80;
    --mono:"SF Mono",ui-monospace,"Cascadia Code",Menlo,Consolas,monospace;
  }
  *{box-sizing:border-box}
  html,body{margin:0;height:100%}
  body{
    background:radial-gradient(1200px 600px at 50% -10%, #1a0708 0%, var(--bg) 45%) fixed,
               var(--bg);
    color:var(--ink);
    font-family:"Helvetica Neue",Arial,sans-serif;
    display:flex;flex-direction:column;align-items:center;
    min-height:100%;padding:48px 20px;
  }
  /* film grain overlay */
  body::after{
    content:"";position:fixed;inset:0;pointer-events:none;opacity:.05;z-index:99;
    background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='120'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2'/></filter><rect width='100%25' height='100%25' filter='url(%23n)'/></svg>");
  }
  .brand{display:flex;align-items:center;gap:14px;margin-bottom:6px}
  .lens{
    width:34px;height:34px;border-radius:50%;
    background:radial-gradient(circle at 35% 30%, #444 0 20%, #111 60%);
    box-shadow:0 0 0 2px #000,0 0 0 4px #2a2a2f,0 0 22px 2px rgba(255,59,48,.35);
  }
  h1{font-size:30px;letter-spacing:.32em;margin:0;text-transform:uppercase;font-weight:600}
  .tag{color:var(--muted);font-family:var(--mono);font-size:12.5px;letter-spacing:.14em;margin:0 0 34px}
  .tag b{color:var(--safelight)}

  .stage{width:min(680px,100%);display:flex;flex-direction:column;gap:18px}

  /* drop zone framed like a photographic negative */
  .drop{
    position:relative;border:1.5px dashed #3a3a42;border-radius:14px;
    background:linear-gradient(180deg,#101014,#0c0c0f);
    padding:54px 24px;text-align:center;cursor:pointer;transition:.18s;
  }
  .drop:hover,.drop.hot{border-color:var(--safelight);box-shadow:0 0 0 1px rgba(255,59,48,.25) inset,0 0 34px rgba(255,59,48,.12)}
  .drop .frame{position:absolute;inset:10px;border:1px solid #1d1d22;border-radius:9px;pointer-events:none}
  .drop .frame::before,.drop .frame::after{content:"";position:absolute;width:14px;height:14px;border:2px solid var(--amber);opacity:.5}
  .drop .frame::before{top:-2px;left:-2px;border-right:0;border-bottom:0}
  .drop .frame::after{bottom:-2px;right:-2px;border-left:0;border-top:0}
  .drop .big{font-size:17px;margin:0 0 6px}
  .drop .small{color:var(--muted);font-family:var(--mono);font-size:12px;margin:0}
  input[type=file]{display:none}

  .card{background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden}
  .card h3{
    margin:0;padding:14px 18px;font-family:var(--mono);font-size:12px;letter-spacing:.18em;
    text-transform:uppercase;color:var(--muted);border-bottom:1px solid var(--line);
    display:flex;align-items:center;gap:9px;
  }
  .dot{width:8px;height:8px;border-radius:50%;background:var(--safelight);box-shadow:0 0 10px var(--safelight)}
  .rows{padding:6px 0}
  .row{
    display:flex;justify-content:space-between;gap:16px;padding:11px 18px;
    font-family:var(--mono);font-size:13px;border-bottom:1px dashed #1e1e24;
    animation:fade .35s both;
  }
  .row:last-child{border-bottom:0}
  .row .k{color:var(--muted)}
  .row .v{color:var(--ink);text-align:right;word-break:break-word}
  .row.redacted .v{position:relative;color:#5a5a60}
  .row.redacted .v::after{
    content:"";position:absolute;left:0;top:50%;height:2px;width:100%;
    background:var(--safelight);animation:strike .4s ease forwards;
  }
  @keyframes strike{from{width:0}to{width:100%}}
  @keyframes fade{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}

  .maplink{display:inline-block;margin-top:2px;color:var(--amber);text-decoration:none;border-bottom:1px dotted}
  .verdict{padding:16px 18px;font-family:var(--mono);font-size:13px;color:var(--ok);display:flex;gap:9px;align-items:center}

  .btn{
    appearance:none;border:0;cursor:pointer;font-family:var(--mono);font-size:13px;letter-spacing:.1em;
    padding:14px 20px;border-radius:11px;width:100%;text-transform:uppercase;
    background:var(--safelight);color:#160303;font-weight:700;transition:.15s;
  }
  .btn:hover{filter:brightness(1.08)}
  .btn.ghost{background:transparent;color:var(--muted);border:1px solid var(--line)}

  .status{font-family:var(--mono);font-size:12.5px;color:var(--amber);text-align:center;letter-spacing:.12em}
  .spin{display:inline-block;width:12px;height:12px;border:2px solid #3a2a10;border-top-color:var(--amber);border-radius:50%;animation:sp .7s linear infinite;vertical-align:-1px;margin-right:8px}
  @keyframes sp{to{transform:rotate(360deg)}}
  .hidden{display:none}
  footer{margin-top:34px;color:#4c4c53;font-family:var(--mono);font-size:11px;text-align:center;line-height:1.7}
</style>
</head>
<body>
  <div class="brand"><div class="lens"></div><h1>Obscura</h1></div>
  <p class="tag">strip the <b>story</b> your photos tell</p>

  <div class="stage">
    <label class="drop" id="drop">
      <div class="frame"></div>
      <p class="big">Drop a photo here</p>
      <p class="small">JPEG / PNG · your original is never stored · click to browse</p>
      <input type="file" id="file" accept="image/*" />
    </label>

    <p class="status hidden" id="status"></p>

    <div class="card hidden" id="exposed">
      <h3><span class="dot"></span> Hidden data found in your photo</h3>
      <div class="rows" id="rows"></div>
      <div class="verdict" id="verdict"></div>
    </div>

    <a class="btn hidden" id="download">↓ Download the clean photo</a>
    <button class="btn ghost hidden" id="again">Strip another</button>
  </div>

  <footer>
    Processed in memory · cleaned copy auto-deletes within 24h · we never log your metadata<br/>
    Obscura · AWS cloud project · VPC · EC2 · S3 · IAM · ALB · CloudFront
  </footer>

<script>
  const $=id=>document.getElementById(id);
  const drop=$("drop"),file=$("file"),status=$("status"),
        exposed=$("exposed"),rows=$("rows"),verdict=$("verdict"),
        download=$("download"),again=$("again");

  ["dragenter","dragover"].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add("hot")}));
  ["dragleave","drop"].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove("hot")}));
  drop.addEventListener("drop",ev=>{ if(ev.dataTransfer.files[0]) handle(ev.dataTransfer.files[0]); });
  file.addEventListener("change",()=>{ if(file.files[0]) handle(file.files[0]); });

  function show(el){el.classList.remove("hidden")}
  function hide(el){el.classList.add("hidden")}

  async function handle(f){
    reset();
    show(status);
    status.innerHTML='<span class="spin"></span>Developing… reading what your camera hid';
    const fd=new FormData(); fd.append("photo",f);
    let data;
    try{
      const r=await fetch("/strip",{method:"POST",body:fd});
      data=await r.json();
      if(!r.ok) throw new Error(data.error||"failed");
    }catch(err){
      status.textContent="✕ "+err.message; status.style.color="var(--safelight)"; return;
    }
    hide(status);
    renderFindings(data);
  }

  function renderFindings(data){
    const entries=Object.entries(data.found).filter(([k])=>!k.startsWith("_"));
    show(exposed); rows.innerHTML="";

    if(entries.length===0){
      const d=document.createElement("div"); d.className="row";
      d.innerHTML='<span class="k">result</span><span class="v">No metadata found — already clean</span>';
      rows.appendChild(d);
    }
    entries.forEach(([k,v],i)=>{
      const d=document.createElement("div"); d.className="row"; d.style.animationDelay=(i*0.09)+"s";
      let val=v;
      if(k==="GPS location" && data.found._gps){
        const g=data.found._gps;
        val=`${v} <a class="maplink" target="_blank" rel="noopener"
             href="https://www.openstreetmap.org/?mlat=${g.lat}&mlon=${g.lon}#map=15/${g.lat}/${g.lon}">view where →</a>`;
      }
      d.innerHTML=`<span class="k">${k}</span><span class="v">${val}</span>`;
      rows.appendChild(d);
    });

    // dramatic redaction pass, then reveal the clean download
    const total=data.stripped_count||entries.length;
    setTimeout(()=>{
      document.querySelectorAll("#rows .row").forEach((r,i)=>
        setTimeout(()=>r.classList.add("redacted"), i*180));
      const after=entries.length*180+500;
      setTimeout(()=>{
        verdict.innerHTML=`✔ Redacted ${total} hidden tag${total===1?"":"s"}. Your clean copy carries nothing.`;
        download.href=data.download_url; show(download); show(again);
      }, after);
    }, entries.length*90+400);
  }

  again.addEventListener("click",reset);
  function reset(){
    [exposed,download,again].forEach(hide);
    rows.innerHTML=""; verdict.textContent=""; status.style.color="var(--amber)";
    file.value="";
  }
</script>
</body>
</html>
```

### 3.5 `.gitignore`

```
__pycache__/
*.pyc
*.pem
.env
```

You now have:

```
obscura/
├── app.py
├── requirements.txt
├── Dockerfile
├── .gitignore
└── templates/
    └── index.html
```

---

## 4. Test the container locally

Never deploy something you haven't run. Build and run it on your own machine first. It won't reach S3 locally (no bucket yet), but the UI and metadata reveal will work — and that's enough to confirm the app is sound.

```bash
cd ~/obscura
docker build -t obscura .
# run without S3 — the /strip call will fail at the upload step, which is expected for now
docker run --rm -p 8080:8080 obscura
```

Open <http://localhost:8080>. You should see the dark Obscura UI. Drop in a photo **taken on a phone with location on** (those have GPS). You'll see the reveal populate. The download will only work once S3 exists (Section 12) — for now you're just confirming the UI renders and the app boots. `Ctrl+C` to stop.

> Want the full local loop including download? Add real AWS keys and a bucket as env vars: `docker run --rm -p 8080:8080 -e BUCKET_NAME=yourbucket -e AWS_ACCESS_KEY_ID=… -e AWS_SECRET_ACCESS_KEY=… -e AWS_REGION=ap-south-1 obscura`. Optional — the EC2 deployment uses an IAM role instead of keys, which is the correct pattern.

---

## 5. Push to GitHub

The EC2 instances build the app by cloning this repo, so it must be **public** (or you'd have to put credentials on the box — don't).

1. On GitHub, create a new **public** repo named `obscura`. Don't add a README (you'll push one).
2. Locally:

```bash
cd ~/obscura
git init
git add .
git commit -m "Obscura: EXIF-stripping privacy app for AWS"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/obscura.git
git push -u origin main
```

Set a shell variable with your username — the user-data script below uses it:

```bash
export GITHUB_USER=YOUR_GITHUB_USERNAME
```

> A polished README is in Section 13. You can push it now or at the end.

---

## 6. AWS: networking (VPC, subnets, IGW, routes)

From here everything is AWS CLI in the **same terminal** (your `PROJECT`, `AWS_REGION`, `GITHUB_USER` vars must still be set).

### 6.1 The VPC

```bash
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc}]" \
  --query 'Vpc.VpcId' --output text)
echo "VPC_ID=$VPC_ID"

# Give instances DNS names
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
```

### 6.2 Internet gateway (the VPC's door to the internet)

```bash
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
echo "IGW_ID=$IGW_ID"
```

### 6.3 Two public subnets in two Availability Zones

The ALB requires at least two AZs. That's the whole point of high availability.

```bash
SUBNET_A=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 --availability-zone ${AWS_REGION}a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-public-a}]" \
  --query 'Subnet.SubnetId' --output text)

SUBNET_B=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 --availability-zone ${AWS_REGION}b \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-public-b}]" \
  --query 'Subnet.SubnetId' --output text)
echo "SUBNET_A=$SUBNET_A  SUBNET_B=$SUBNET_B"

# Auto-assign a public IP to anything launched here
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_A --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_B --map-public-ip-on-launch
```

### 6.4 Route table → send internet traffic through the IGW

```bash
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-public-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id $RT_ID \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_A
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_B
echo "RT_ID=$RT_ID"
```

---

## 7. AWS: security groups

Two firewalls. The ALB one is public (for now); the EC2 one only trusts the ALB.

```bash
# --- ALB security group ---
ALB_SG=$(aws ec2 create-security-group \
  --group-name $PROJECT-alb-sg --description "Obscura ALB" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

# Temporarily allow the world on port 80 so we can test the ALB directly.
# We LOCK THIS DOWN to CloudFront-only in Section 11.
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# --- EC2 security group ---
EC2_SG=$(aws ec2 create-security-group \
  --group-name $PROJECT-ec2-sg --description "Obscura app instances" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

# App port 8080: reachable ONLY from the ALB SG, never the public internet
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
  --protocol tcp --port 8080 --source-group $ALB_SG

# SSH port 22: only from YOUR current IP
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id $EC2_SG \
  --protocol tcp --port 22 --cidr ${MY_IP}/32

echo "ALB_SG=$ALB_SG  EC2_SG=$EC2_SG  MY_IP=$MY_IP"
```

> If your IP changes later (home internet, VPN), re-run the last block with the new IP, or you'll lose SSH access.

---

## 8. AWS: IAM role + S3 bucket

### 8.1 The S3 bucket (clean output only)

```bash
# Bucket names are globally unique — append a timestamp
BUCKET=$PROJECT-clean-$(date +%s)
echo "BUCKET=$BUCKET"

aws s3api create-bucket --bucket $BUCKET --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

# Block ALL public access — clean files are served via short-lived presigned URLs, never public
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Auto-delete cleaned files after 1 day (privacy + a nice S3 feature to point at)
cat > lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "expire-clean",
      "Filter": { "Prefix": "clean/" },
      "Status": "Enabled",
      "Expiration": { "Days": 1 }
    }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket $BUCKET --lifecycle-configuration file://lifecycle.json
```

### 8.2 IAM role for the EC2 instances

The instances get an identity that can touch **only this one bucket** — and no access keys ever live on the box.

```bash
# Trust policy: "EC2 is allowed to assume this role"
cat > trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole" }
  ]
}
EOF
aws iam create-role --role-name $PROJECT-ec2-role \
  --assume-role-policy-document file://trust.json

# Permission policy: only Put/Get/Delete on OUR bucket's objects
cat > s3policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$BUCKET/*" }
  ]
}
EOF
aws iam put-role-policy --role-name $PROJECT-ec2-role \
  --policy-name s3-clean-access --policy-document file://s3policy.json

# An instance profile is the wrapper that attaches a role to an EC2 instance
aws iam create-instance-profile --instance-profile-name $PROJECT-ec2-profile
aws iam add-role-to-instance-profile \
  --instance-profile-name $PROJECT-ec2-profile --role-name $PROJECT-ec2-role

# IAM is eventually-consistent; give it a few seconds before launching instances
sleep 12
```

---

## 9. AWS: EC2 instances (×2)

### 9.1 SSH key pair

```bash
aws ec2 create-key-pair --key-name $PROJECT-key \
  --query 'KeyMaterial' --output text > ~/obscura-key.pem
chmod 400 ~/obscura-key.pem
```

### 9.2 Latest Amazon Linux 2023 AMI (fetched, not hardcoded)

```bash
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
echo "AMI_ID=$AMI_ID"
```

### 9.3 The user-data boot script

This runs automatically on first boot: installs Docker + git, clones your repo, builds the image, runs it on port 8080 with the bucket name injected. Because `$GITHUB_USER`, `$AWS_REGION`, and `$BUCKET` are expanded **now**, the file is written with real values baked in.

```bash
cat > userdata.sh <<EOF
#!/bin/bash
dnf update -y
dnf install -y docker git
systemctl enable --now docker

cd /home/ec2-user
git clone https://github.com/$GITHUB_USER/obscura.git app
cd app
docker build -t obscura .
docker run -d --restart always -p 8080:8080 \\
  -e AWS_REGION=$AWS_REGION \\
  -e BUCKET_NAME=$BUCKET \\
  obscura
EOF

# sanity check — open it and confirm your username/bucket are filled in
cat userdata.sh
```

### 9.4 Launch one instance per subnet (one per AZ)

```bash
INST_A=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.micro \
  --key-name $PROJECT-key \
  --iam-instance-profile Name=$PROJECT-ec2-profile \
  --security-group-ids $EC2_SG --subnet-id $SUBNET_A \
  --user-data file://userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT-app-a}]" \
  --query 'Instances[0].InstanceId' --output text)

INST_B=$(aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.micro \
  --key-name $PROJECT-key \
  --iam-instance-profile Name=$PROJECT-ec2-profile \
  --security-group-ids $EC2_SG --subnet-id $SUBNET_B \
  --user-data file://userdata.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT-app-b}]" \
  --query 'Instances[0].InstanceId' --output text)

echo "INST_A=$INST_A  INST_B=$INST_B"
```

> The boot script needs **3–5 minutes** to install Docker and build the image. Be patient before expecting health checks to pass.

Optional — watch one build over SSH:

```bash
PUB_A=$(aws ec2 describe-instances --instance-ids $INST_A \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
ssh -i ~/obscura-key.pem ec2-user@$PUB_A
#   on the box:  sudo docker ps        (container running?)
#                sudo docker logs $(sudo docker ps -q)
#   exit
```

---

## 10. AWS: Target group + ALB

### 10.1 Target group (health-checks your app on `/health`)

```bash
TG_ARN=$(aws elbv2 create-target-group \
  --name $PROJECT-tg --protocol HTTP --port 8080 \
  --vpc-id $VPC_ID --target-type instance \
  --health-check-path /health \
  --health-check-interval-seconds 15 --healthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn $TG_ARN \
  --targets Id=$INST_A Id=$INST_B
echo "TG_ARN=$TG_ARN"
```

### 10.2 The load balancer + listener

```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name $PROJECT-alb --type application --scheme internet-facing \
  --subnets $SUBNET_A $SUBNET_B --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)

aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN

echo "ALB_DNS=$ALB_DNS"
```

### 10.3 Wait for targets to go healthy

```bash
# Repeat this until BOTH show "healthy" (takes a few minutes after boot)
aws elbv2 describe-target-health --target-group-arn $TG_ARN \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State}' \
  --output table
```

Once healthy, test the ALB directly:

```bash
curl -I http://$ALB_DNS/health      # expect: HTTP/1.1 200 OK
```

Open `http://$ALB_DNS` in a browser — the Obscura UI should load and a full strip+download should now work (S3 exists). This is **HTTP** for the moment; CloudFront adds HTTPS next.

---

## 11. AWS: CloudFront + lock down the ALB

CloudFront gives you a free `https://xxxx.cloudfront.net` address — the clean link for your README — and terminates TLS so photo uploads are encrypted in transit.

### 11.1 Create the distribution

```bash
cat > cf-config.json <<EOF
{
  "CallerReference": "$PROJECT-$(date +%s)",
  "Comment": "Obscura CDN",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "obscura-alb",
        "DomainName": "$ALB_DNS",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] },
          "OriginReadTimeout": 30,
          "OriginKeepaliveTimeout": 5
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "obscura-alb",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] }
    },
    "Compress": true,
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }
}
EOF

CF_JSON=$(aws cloudfront create-distribution --distribution-config file://cf-config.json)
CF_DOMAIN=$(echo "$CF_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['Distribution']['DomainName'])")
CF_ID=$(echo "$CF_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['Distribution']['Id'])")
echo "CF_DOMAIN=$CF_DOMAIN   CF_ID=$CF_ID"
```

- `CachePolicyId 4135ea2d-…` is the AWS-managed **CachingDisabled** policy (this is a dynamic app — you don't want responses cached).
- `OriginRequestPolicyId 216adef6-…` is the managed **AllViewer** policy (forwards all headers/cookies/query to your app).
- These two IDs are the same for every AWS account.

CloudFront takes **~5–10 minutes** to deploy globally. Check status:

```bash
aws cloudfront get-distribution --id $CF_ID \
  --query 'Distribution.Status' --output text     # wait for "Deployed"
```

### 11.2 Lock the ALB to CloudFront only

Right now anyone can hit your ALB over plain HTTP. Restrict inbound to AWS's CloudFront IP ranges (a managed prefix list), and remove the open rule.

```bash
PL_ID=$(aws ec2 describe-managed-prefix-lists \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[0].PrefixListId' --output text)
echo "PL_ID=$PL_ID"

# Allow port 80 only from CloudFront's edge servers
aws ec2 authorize-security-group-ingress --group-id $ALB_SG \
  --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds="[{PrefixListId=$PL_ID}]"

# Remove the temporary open-to-world rule
aws ec2 revoke-security-group-ingress --group-id $ALB_SG \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
```

Now `http://$ALB_DNS` should **time out** (good — direct access is blocked), while `https://$CF_DOMAIN` works.

---

## 12. End-to-end verification

```bash
echo "Your live app:  https://$CF_DOMAIN"
```

Open that URL and run the full story:

1. Page loads over **HTTPS** (padlock in the address bar).
2. Drop in a **phone photo with GPS**. The reveal panel lists Camera, Taken-at, and GPS with a working "view where →" map link.
3. Watch the redaction animation strike through each field.
4. Click **Download the clean photo**.
5. Verify the download is actually clean:

```bash
cd ~/Downloads    # wherever it saved
# Should print little/nothing and definitely NO GPS:
exiftool obscura_*.jpg 2>/dev/null | grep -i -E "gps|make|model|date" || echo "CLEAN — no metadata"
# no exiftool? use Python:
python3 -c "from PIL import Image;print(dict(Image.open('$(ls -t obscura_*.jpg|head -1)').getexif()) or 'CLEAN — no EXIF')"
```

If the last command prints `CLEAN`, the whole pipeline works: CloudFront → ALB → EC2/Docker → S3, with the original never persisted.

---

## 13. Screenshots & report checklist

Capture these while everything is live (you'll tear it down after). They're your proof of work and they map 1:1 to the syllabus.

- [ ] **VPC** resource map (console → VPC → your `obscura-vpc`) showing 2 subnets across 2 AZs
- [ ] **EC2** instances list — both `obscura-app-a/b` running in different AZs
- [ ] **Security groups** — the EC2 SG showing 8080 sourced from the ALB SG (not the world)
- [ ] **IAM** role `obscura-ec2-role` with the scoped S3 policy
- [ ] **S3** bucket showing Block-Public-Access ON and the lifecycle rule
- [ ] **Target group** — both targets **healthy**
- [ ] **Load balancer** — DNS name + listener
- [ ] **CloudFront** — distribution Deployed, with the `*.cloudfront.net` domain
- [ ] The **app itself**: the reveal panel + the "clean" verdict
- [ ] Terminal proof the downloaded file has **no EXIF**

Suggested `README.md` for the repo:

```markdown
# Obscura — strip the story your photos tell

A privacy tool that removes hidden EXIF/GPS metadata from photos, deployed on AWS.

**Live:** https://YOUR_ID.cloudfront.net

## Why
Every phone photo carries hidden metadata: the GPS coordinates of where it was
taken, your device model, timestamps. Share it online and you may be broadcasting
your home address. Obscura shows you exactly what's hidden, then strips it.

## Architecture
Browser → CloudFront (HTTPS) → Application Load Balancer → 2× EC2 (Docker) → S3
- Custom VPC, 2 public subnets across 2 Availability Zones (ap-south-1)
- EC2 authenticates to S3 via an IAM instance role — no access keys on the host
- Uploaded originals are processed in memory and never stored
- Cleaned copies use random keys and auto-expire after 24h (S3 lifecycle)
- ALB is locked to CloudFront's IP range; instances only accept traffic from the ALB

## Privacy design & honest limitation
The correct architecture for a pure privacy tool is client-side stripping
(nothing ever uploaded). Server-side processing was chosen here to satisfy the
cloud-architecture requirement of the course. A production version would strip in
the browser and use the server only for optional storage. This tradeoff is
deliberate and documented.

## Stack
Python · Flask · Pillow · piexif · Docker · AWS (VPC, EC2, S3, IAM, ALB, CloudFront)
```

That "honest limitation" paragraph is worth keeping — evaluators notice when you can articulate the limits of your own design.

---

## 14. Teardown (do this to stop spend)

Delete in **reverse order of creation** (dependencies block deletion otherwise). Run this once your report and screenshots are done.

```bash
# 1. CloudFront: must be DISABLED then deleted (this part is slow — needs the ETag)
aws cloudfront get-distribution-config --id $CF_ID > dist.json
ETAG=$(python3 -c "import json;print(json.load(open('dist.json'))['ETag'])")
python3 -c "import json;d=json.load(open('dist.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('disabled.json','w'))"
aws cloudfront update-distribution --id $CF_ID \
  --distribution-config file://disabled.json --if-match $ETAG
# wait until Status = Deployed again (several minutes)...
aws cloudfront get-distribution --id $CF_ID --query 'Distribution.Status' --output text
# then delete (fetch a fresh ETag first)
NEW_ETAG=$(aws cloudfront get-distribution-config --id $CF_ID --query 'ETag' --output text)
aws cloudfront delete-distribution --id $CF_ID --if-match $NEW_ETAG

# 2. Load balancer + listener + target group
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
sleep 30
aws elbv2 delete-target-group --target-group-arn $TG_ARN

# 3. EC2 instances
aws ec2 terminate-instances --instance-ids $INST_A $INST_B
aws ec2 wait instance-terminated --instance-ids $INST_A $INST_B

# 4. S3 (empty then delete)
aws s3 rm s3://$BUCKET --recursive
aws s3api delete-bucket --bucket $BUCKET

# 5. IAM
aws iam remove-role-from-instance-profile --instance-profile-name $PROJECT-ec2-profile --role-name $PROJECT-ec2-role
aws iam delete-instance-profile --instance-profile-name $PROJECT-ec2-profile
aws iam delete-role-policy --role-name $PROJECT-ec2-role --policy-name s3-clean-access
aws iam delete-role --role-name $PROJECT-ec2-role

# 6. Networking (SGs → subnets → route table → IGW → VPC)
aws ec2 delete-security-group --group-id $EC2_SG
aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 delete-subnet --subnet-id $SUBNET_A
aws ec2 delete-subnet --subnet-id $SUBNET_B
aws ec2 delete-route-table --route-table-id $RT_ID
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-vpc --vpc-id $VPC_ID

# 7. Key pair
aws ec2 delete-key-pair --key-name $PROJECT-key && rm -f ~/obscura-key.pem
```

> If a delete complains something is "in use," wait a minute and retry — AWS releases dependencies asynchronously. Security groups won't delete until the network interfaces from terminated instances/ALB are gone.

---

## 15. Troubleshooting

**Targets stuck "unhealthy."** The image is probably still building. SSH in (`ssh -i ~/obscura-key.pem ec2-user@<public-ip>`), then `sudo docker ps`. Empty? `sudo cat /var/log/cloud-init-output.log` shows the boot script's progress/errors. Common cause: a typo in `$GITHUB_USER` so the clone failed — fix the repo URL and re-run `docker build/run` manually, or terminate and relaunch.

**`curl http://$ALB_DNS/health` hangs.** Either targets aren't healthy yet, or you already locked the SG (Section 11.2) — after that, the ALB only answers CloudFront, so use `https://$CF_DOMAIN` instead.

**CloudFront returns 502 / "can't connect to origin."** The ALB SG no longer allows CloudFront, or targets are unhealthy. Confirm the prefix-list rule exists on `$ALB_SG` and both targets are `healthy`.

**Download button gives Access Denied.** The presigned URL expired (5 min) — just strip the photo again. If it *always* fails, the IAM role/policy didn't attach; confirm the instance shows the role: `aws ec2 describe-instances --instance-ids $INST_A --query 'Reservations[0].Instances[0].IamInstanceProfile'`.

**"Upload failed" in the UI.** Check the container can reach S3: SSH in, `sudo docker logs <id>`. A `NoCredentialsError` means the instance profile isn't attached; a `NoSuchBucket` means `BUCKET_NAME` was wrong in user-data.

**I closed my terminal and lost the variables.** Recover them by name:

```bash
export PROJECT=obscura AWS_DEFAULT_REGION=ap-south-1
VPC_ID=$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=$PROJECT-vpc --query 'Vpcs[0].VpcId' --output text)
ALB_ARN=$(aws elbv2 describe-load-balancers --names $PROJECT-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$PROJECT-alb-sg --query 'SecurityGroups[0].GroupId' --output text)
# ...same pattern (filter by the Name tag / resource name) for each ID you need
```

**Region mismatch errors.** Every command must run with `AWS_DEFAULT_REGION=ap-south-1`. If you see resources "not found" that you just made, you're probably in a different region.

---

## 16. Appendix: syllabus mapping

| Syllabus module | Where it shows up in this build |
|---|---|
| Introduction to Linux (SSH, bash, packages) | User-data bash script; SSH into EC2; `dnf`, `systemctl` |
| Getting Started with AWS — EC2 | Two t3.micro instances, AL2023, launched via CLI |
| EC2 security groups & key pairs | `obscura-ec2-sg`, `obscura-key` |
| AWS Storage — S3 | Output bucket, block-public-access, lifecycle expiry, presigned URLs |
| AWS Security — IAM | Instance role scoped to one bucket; no static keys |
| Networking — VPC | Custom VPC, 2 subnets/2 AZs, IGW, route table |
| Elastic Load Balancing (ELB/ALB) | Target group + health checks + Application Load Balancer |
| Containerisation — Docker | Dockerfile, image built & run on each instance |
| (Bonus) Edge/CDN + TLS | CloudFront distribution, HTTPS, origin lockdown |
| Cloud concepts (Week 1) | Written report — theory |
| Multi-cloud (Week 5) | Written report — theory |

That's 7 of 8 practical modules plus a CDN bonus. Cloud concepts and multi-cloud are theory you cover in the written report.

---

*Build the app locally first (Sections 3–4). Everything downstream assumes a working container.*
