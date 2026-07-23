# =============================================================================
#  Obscura - complete teardown
#  Deletes EVERYTHING this project creates, in dependency order.
#  Discovers resources by name/tag AND from state.env, so it still works
#  even if state.env is incomplete (e.g. after a partial/failed deploy).
#  Safe to re-run. CloudFront deletion is slow (disable -> wait -> delete).
# =============================================================================
$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false

$env:AWS_REGION         = "ap-south-1"
$env:AWS_DEFAULT_REGION = "ap-south-1"
$PROJECT    = "obscura"
$STATE_FILE = Join-Path $PSScriptRoot "state.env"
$PEM        = Join-Path $PSScriptRoot "obscura-key.pem"

function Ok($v) { return ($v -ne $null) -and ("$v".Trim() -ne "") -and ("$v".Trim() -ne "None") }
function Words($v) { if (-not (Ok $v)) { return @() } return ($v -split '\s+' | Where-Object { Ok $_ }) }

# Retry a delete that may be blocked by async dependency release (ENIs etc.)
function Try-Delete($label, [scriptblock]$Action, $tries = 8, $delay = 15) {
    for ($i = 1; $i -le $tries; $i++) {
        & $Action 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  deleted $label"; return }
        if ($i -lt $tries) { Start-Sleep -Seconds $delay }
    }
    Write-Host "  WARN: could not delete $label after $tries tries (may already be gone, or retry later)" -ForegroundColor Yellow
}

# ---- load state (best effort) ----
$S = @{}
if (Test-Path $STATE_FILE) {
    foreach ($line in Get-Content $STATE_FILE) {
        if ($line -match '^\s*([^=#]+)=(.*)$') { $S[$matches[1].Trim()] = $matches[2].Trim() }
    }
}

Write-Host "== Tearing down Obscura in $($env:AWS_REGION) ==" -ForegroundColor Cyan

# Resolve ALL matching VPCs (state + Name tag). There can be more than one if
# an earlier deploy attempt was interrupted and re-run created a second stack -
# every one of them must be torn down, not just the first.
$vpcIds = @()
if (Ok $S["VPC_ID"]) { $vpcIds += $S["VPC_ID"] }
$discoveredVpcs = & aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT-vpc" --query 'Vpcs[].VpcId' --output text 2>$null
$vpcIds += (Words $discoveredVpcs)
$vpcIds = $vpcIds | Where-Object { Ok $_ } | Select-Object -Unique
if ($vpcIds.Count -gt 1) { Write-Host "  NOTE: found $($vpcIds.Count) VPCs tagged '$PROJECT-vpc' - cleaning up all of them." -ForegroundColor Yellow }

# --------------------------------------------------- [1/9] CloudFront ----
Write-Host "`n[1/9] CloudFront (disable + delete, slow)..." -ForegroundColor Yellow
$cfIds = & aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='Obscura CDN'].Id" --output text 2>$null
if (-not (Ok $cfIds) -and (Ok $S["CF_ID"])) { $cfIds = $S["CF_ID"] }
foreach ($id in (Words $cfIds)) {
    Write-Host "  distribution $id"
    $cfgRaw = & aws cloudfront get-distribution-config --id $id 2>$null
    if (-not (Ok $cfgRaw)) { Write-Host "    (already gone)"; continue }
    $cfg  = ($cfgRaw -join "") | ConvertFrom-Json
    $etag = $cfg.ETag
    if ($cfg.DistributionConfig.Enabled) {
        $cfg.DistributionConfig.Enabled = $false
        ($cfg.DistributionConfig | ConvertTo-Json -Depth 60) | Out-File (Join-Path $PSScriptRoot "cf-disable.json") -Encoding ascii
        & aws cloudfront update-distribution --id $id --distribution-config "file://$(Join-Path $PSScriptRoot 'cf-disable.json')" --if-match $etag 2>$null | Out-Null
        Write-Host "    disabling; waiting for Deployed (several minutes)..."
        do {
            Start-Sleep -Seconds 30
            $st = & aws cloudfront get-distribution --id $id --query 'Distribution.Status' --output text 2>$null
        } while ($st -ne "Deployed")
    }
    $etag2 = & aws cloudfront get-distribution-config --id $id --query 'ETag' --output text 2>$null
    & aws cloudfront delete-distribution --id $id --if-match $etag2 2>$null | Out-Null
    Write-Host "    deleted $id"
}

# --------------------------------------------------- [2/9] Load balancer ----
Write-Host "`n[2/9] Application Load Balancer..." -ForegroundColor Yellow
$ALB_ARN = $S["ALB_ARN"]
if (-not (Ok $ALB_ARN)) {
    $ALB_ARN = & aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>$null
}
if (Ok $ALB_ARN) {
    & aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN 2>$null | Out-Null
    Write-Host "  requested delete; waiting ~30s for it to drain..."
    Start-Sleep -Seconds 30
} else { Write-Host "  none" }

# --------------------------------------------------- [3/9] Target group ----
Write-Host "`n[3/9] Target group..." -ForegroundColor Yellow
$TG_ARN = $S["TG_ARN"]
if (-not (Ok $TG_ARN)) {
    $TG_ARN = & aws elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
}
if (Ok $TG_ARN) {
    Try-Delete "target group" { aws elbv2 delete-target-group --target-group-arn $TG_ARN }
} else { Write-Host "  none" }

# --------------------------------------------------- [4/9] EC2 instances ----
Write-Host "`n[4/9] EC2 instances..." -ForegroundColor Yellow
$ids = @()
foreach ($k in @("INST_A", "INST_B")) { if (Ok $S[$k]) { $ids += $S[$k] } }
$disc = & aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=$PROJECT-app-a,$PROJECT-app-b" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query 'Reservations[].Instances[].InstanceId' --output text 2>$null
$ids += (Words $disc)
$ids = $ids | Where-Object { Ok $_ } | Select-Object -Unique
if ($ids.Count -gt 0) {
    Write-Host ("  terminating: " + ($ids -join ", "))
    & aws ec2 terminate-instances --instance-ids $ids 2>$null | Out-Null
    & aws ec2 wait instance-terminated --instance-ids $ids 2>$null | Out-Null
    Write-Host "  terminated"
} else { Write-Host "  none" }

# --------------------------------------- [5/9] Security groups + [6/9] Networking ----
# Done together, per VPC, since SGs/subnets/route tables/IGW all belong to one VPC.
Write-Host "`n[5-6/9] Security groups, subnets, route tables, IGW, VPC..." -ForegroundColor Yellow
if ($vpcIds.Count -eq 0) {
    Write-Host "  no VPC found"
} else {
    foreach ($VPC_ID in $vpcIds) {
        Write-Host "  -- VPC $VPC_ID --" -ForegroundColor DarkCyan

        # Security groups (EC2 SG first - it references the ALB SG - then ALB SG).
        $ec2sg = & aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$PROJECT-ec2-sg" --query 'SecurityGroups[0].GroupId' --output text 2>$null
        $albsg = & aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=$PROJECT-alb-sg" --query 'SecurityGroups[0].GroupId' --output text 2>$null
        if (Ok $ec2sg) { Try-Delete "ec2 sg ($ec2sg)" { aws ec2 delete-security-group --group-id $ec2sg } }
        if (Ok $albsg) { Try-Delete "alb sg ($albsg)" { aws ec2 delete-security-group --group-id $albsg } }

        # Subnets (deleting them also clears their route-table associations).
        $subnets = & aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[].SubnetId' --output text 2>$null
        foreach ($sn in (Words $subnets)) { Try-Delete "subnet $sn" { aws ec2 delete-subnet --subnet-id $sn } }

        # Non-main route tables.
        $rts = & aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" `
            --query 'RouteTables[?length(Associations)==`0` || Associations[0].Main!=`true`].RouteTableId' --output text 2>$null
        foreach ($rt in (Words $rts)) { Try-Delete "route table $rt" { aws ec2 delete-route-table --route-table-id $rt } }

        # Internet gateway attached to THIS vpc.
        $igw = & aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[0].InternetGatewayId' --output text 2>$null
        if (Ok $igw) {
            & aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC_ID 2>$null | Out-Null
            Try-Delete "igw $igw" { aws ec2 delete-internet-gateway --internet-gateway-id $igw }
        }

        # The VPC itself (retry until dependencies clear).
        Try-Delete "vpc $VPC_ID" { aws ec2 delete-vpc --vpc-id $VPC_ID }
    }
}

# --------------------------------------------------- [7/9] S3 buckets ----
Write-Host "`n[7/9] S3 buckets..." -ForegroundColor Yellow
$buckets = @()
if (Ok $S["BUCKET"]) { $buckets += $S["BUCKET"] }
$allb = & aws s3api list-buckets --query "Buckets[?starts_with(Name, '$PROJECT-clean-')].Name" --output text 2>$null
$buckets += (Words $allb)
$buckets = $buckets | Where-Object { Ok $_ } | Select-Object -Unique
if ($buckets.Count -gt 0) {
    foreach ($b in $buckets) {
        & aws s3 rm "s3://$b" --recursive 2>$null | Out-Null
        & aws s3api delete-bucket --bucket $b 2>$null | Out-Null
        Write-Host "  deleted bucket $b"
    }
} else { Write-Host "  none" }

# --------------------------------------------------- [8/9] IAM ----
Write-Host "`n[8/9] IAM role / instance profile / policy..." -ForegroundColor Yellow
& aws iam remove-role-from-instance-profile --instance-profile-name "$PROJECT-ec2-profile" --role-name "$PROJECT-ec2-role" 2>$null | Out-Null
& aws iam delete-instance-profile --instance-profile-name "$PROJECT-ec2-profile" 2>$null | Out-Null
& aws iam delete-role-policy --role-name "$PROJECT-ec2-role" --policy-name s3-clean-access 2>$null | Out-Null
& aws iam delete-role --role-name "$PROJECT-ec2-role" 2>$null | Out-Null
Write-Host "  IAM cleaned"

# --------------------------------------------------- [9/9] Key pair ----
Write-Host "`n[9/9] Key pair..." -ForegroundColor Yellow
& aws ec2 delete-key-pair --key-name "$PROJECT-key" 2>$null | Out-Null
if (Test-Path $PEM) { Remove-Item $PEM -Force -ErrorAction SilentlyContinue }
Write-Host "  key pair removed"

# ---- reset state so a fresh deploy starts clean ----
@"
VPC_ID=
IGW_ID=
SUBNET_A=
SUBNET_B=
RT_ID=
ALB_SG=
EC2_SG=
BUCKET=
AMI_ID=
INST_A=
INST_B=
TG_ARN=
ALB_ARN=
ALB_DNS=
CF_DOMAIN=
CF_ID=
"@ | Out-File $STATE_FILE -Encoding ascii

Write-Host "`n== Teardown complete. state.env reset. ==" -ForegroundColor Green
Write-Host "Tip: run ./status.ps1 to confirm nothing Obscura-related is still live." -ForegroundColor Green
