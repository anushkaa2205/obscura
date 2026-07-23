# =============================================================================
#  Obscura - full AWS deployment  (idempotent + resumable)
#  Builds: VPC -> subnets/IGW/routes -> security groups -> S3 + IAM ->
#          2x EC2 (Docker) -> target group + ALB -> CloudFront -> lockdown.
#
#  Safe to re-run: every step is guarded. If a previous run failed halfway,
#  just run this again - it reads state.env and resumes where it stopped.
#  Requires: AWS CLI configured, and your repo pushed PUBLIC to GitHub.
# =============================================================================
$ErrorActionPreference = "Stop"
# Don't let a failing aws probe (used for existence checks) abort the script.
$PSNativeCommandUseErrorActionPreference = $false

$env:AWS_REGION         = "ap-south-1"
$env:AWS_DEFAULT_REGION = "ap-south-1"
$PROJECT     = "obscura"
$GITHUB_USER = "anushkaa2205"         
$INSTANCE_TYPE = "t3.micro"
$STATE_FILE  = Join-Path $PSScriptRoot "state.env"
$PEM         = Join-Path $PSScriptRoot "obscura-key.pem"

# ---------------------------------------------------------------- helpers ----
function Ok($v) { return ($v -ne $null) -and ("$v".Trim() -ne "") -and ("$v".Trim() -ne "None") }

# Ordered state; loaded from state.env if present so we can resume.
$S = [ordered]@{
    VPC_ID=""; IGW_ID=""; SUBNET_A=""; SUBNET_B=""; RT_ID=""
    ALB_SG=""; EC2_SG=""; BUCKET=""; AMI_ID=""
    INST_A=""; INST_B=""; TG_ARN=""; ALB_ARN=""; ALB_DNS=""
    CF_DOMAIN=""; CF_ID=""
}
if (Test-Path $STATE_FILE) {
    foreach ($line in Get-Content $STATE_FILE) {
        if ($line -match '^\s*([^=#]+)=(.*)$') {
            $k = $matches[1].Trim(); $v = $matches[2].Trim()
            if ($S.Contains($k)) { $S[$k] = $v }
        }
    }
    Write-Host "Loaded existing state.env - resuming." -ForegroundColor DarkCyan
}
function Save-State {
    ($S.Keys | ForEach-Object { "$_=$($S[$_])" }) -join "`n" |
        Out-File $STATE_FILE -Encoding ascii
}
function Has($k) { return (Ok $S[$k]) }

Write-Host "== Obscura deploy in $($env:AWS_REGION) ==" -ForegroundColor Cyan
& aws sts get-caller-identity --query 'Arn' --output text | ForEach-Object { Write-Host "Identity: $_" }

# ------------------------------------------------------------------- VPC ----
if (-not (Has 'VPC_ID')) {
    $S.VPC_ID = & aws ec2 create-vpc --cidr-block 10.0.0.0/16 `
        --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc}]" `
        --query 'Vpc.VpcId' --output text
    & aws ec2 modify-vpc-attribute --vpc-id $S.VPC_ID --enable-dns-hostnames | Out-Null
    Save-State
}
Write-Host "VPC_ID     = $($S.VPC_ID)"

# ------------------------------------------------------------------- IGW ----
if (-not (Has 'IGW_ID')) {
    $S.IGW_ID = & aws ec2 create-internet-gateway `
        --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$PROJECT-igw}]" `
        --query 'InternetGateway.InternetGatewayId' --output text
    & aws ec2 attach-internet-gateway --vpc-id $S.VPC_ID --internet-gateway-id $S.IGW_ID | Out-Null
    Save-State
}
Write-Host "IGW_ID     = $($S.IGW_ID)"

# --------------------------------------------------------------- subnets ----
if (-not (Has 'SUBNET_A')) {
    $S.SUBNET_A = & aws ec2 create-subnet --vpc-id $S.VPC_ID --cidr-block 10.0.1.0/24 `
        --availability-zone "$($env:AWS_REGION)a" `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-public-a}]" `
        --query 'Subnet.SubnetId' --output text
    & aws ec2 modify-subnet-attribute --subnet-id $S.SUBNET_A --map-public-ip-on-launch | Out-Null
    Save-State
}
if (-not (Has 'SUBNET_B')) {
    $S.SUBNET_B = & aws ec2 create-subnet --vpc-id $S.VPC_ID --cidr-block 10.0.2.0/24 `
        --availability-zone "$($env:AWS_REGION)b" `
        --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$PROJECT-public-b}]" `
        --query 'Subnet.SubnetId' --output text
    & aws ec2 modify-subnet-attribute --subnet-id $S.SUBNET_B --map-public-ip-on-launch | Out-Null
    Save-State
}
Write-Host "SUBNET_A/B = $($S.SUBNET_A) / $($S.SUBNET_B)"

# ------------------------------------------------------------ route table ----
if (-not (Has 'RT_ID')) {
    $S.RT_ID = & aws ec2 create-route-table --vpc-id $S.VPC_ID `
        --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$PROJECT-public-rt}]" `
        --query 'RouteTable.RouteTableId' --output text
    & aws ec2 create-route --route-table-id $S.RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $S.IGW_ID | Out-Null
    & aws ec2 associate-route-table --route-table-id $S.RT_ID --subnet-id $S.SUBNET_A | Out-Null
    & aws ec2 associate-route-table --route-table-id $S.RT_ID --subnet-id $S.SUBNET_B | Out-Null
    Save-State
}
Write-Host "RT_ID      = $($S.RT_ID)"

# ------------------------------------------------------- security groups ----
if (-not (Has 'ALB_SG')) {
    $S.ALB_SG = & aws ec2 create-security-group --group-name "$PROJECT-alb-sg" `
        --description "Obscura ALB" --vpc-id $S.VPC_ID --query 'GroupId' --output text
    # Temporary world access on 80 so we can smoke-test the ALB; locked to CloudFront below.
    & aws ec2 authorize-security-group-ingress --group-id $S.ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 2>$null | Out-Null
    Save-State
}
if (-not (Has 'EC2_SG')) {
    $S.EC2_SG = & aws ec2 create-security-group --group-name "$PROJECT-ec2-sg" `
        --description "Obscura app instances" --vpc-id $S.VPC_ID --query 'GroupId' --output text
    & aws ec2 authorize-security-group-ingress --group-id $S.EC2_SG --protocol tcp --port 8080 --source-group $S.ALB_SG 2>$null | Out-Null
    $MY_IP = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com").Trim()
    & aws ec2 authorize-security-group-ingress --group-id $S.EC2_SG --protocol tcp --port 22 --cidr "$MY_IP/32" 2>$null | Out-Null
    Write-Host "SSH allowed from $MY_IP/32"
    Save-State
}
Write-Host "ALB_SG/EC2_SG = $($S.ALB_SG) / $($S.EC2_SG)"

# ------------------------------------------------------------------- S3 ----
if (-not (Has 'BUCKET')) {
    $S.BUCKET = "$PROJECT-clean-$([int][double](Get-Date -UFormat %s))"
    & aws s3api create-bucket --bucket $S.BUCKET --region $env:AWS_REGION `
        --create-bucket-configuration LocationConstraint=$env:AWS_REGION | Out-Null
    & aws s3api put-public-access-block --bucket $S.BUCKET `
        --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true | Out-Null
    @'
{
  "Rules": [
    { "ID": "expire-clean", "Filter": { "Prefix": "clean/" },
      "Status": "Enabled", "Expiration": { "Days": 1 } }
  ]
}
'@ | Out-File (Join-Path $PSScriptRoot "lifecycle.json") -Encoding ascii
    & aws s3api put-bucket-lifecycle-configuration --bucket $S.BUCKET `
        --lifecycle-configuration "file://$(Join-Path $PSScriptRoot 'lifecycle.json')" | Out-Null
    Save-State
}
Write-Host "BUCKET     = $($S.BUCKET)"

# ------------------------------------------------------------------ IAM ----
$roleName    = "$PROJECT-ec2-role"
$profileName = "$PROJECT-ec2-profile"
$iamFresh = $false
$roleExists = & aws iam get-role --role-name $roleName --query 'Role.RoleName' --output text 2>$null
if (-not (Ok $roleExists)) {
    @'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" }
  ]
}
'@ | Out-File (Join-Path $PSScriptRoot "trust.json") -Encoding ascii
    & aws iam create-role --role-name $roleName --assume-role-policy-document "file://$(Join-Path $PSScriptRoot 'trust.json')" | Out-Null
    $iamFresh = $true
}
# put-role-policy is idempotent (overwrites) - always apply so scope stays correct.
@"
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$($S.BUCKET)/*" }
  ]
}
"@ | Out-File (Join-Path $PSScriptRoot "s3policy.json") -Encoding ascii
& aws iam put-role-policy --role-name $roleName --policy-name s3-clean-access `
    --policy-document "file://$(Join-Path $PSScriptRoot 's3policy.json')" | Out-Null

$profExists = & aws iam get-instance-profile --instance-profile-name $profileName --query 'InstanceProfile.InstanceProfileName' --output text 2>$null
if (-not (Ok $profExists)) {
    & aws iam create-instance-profile --instance-profile-name $profileName | Out-Null
    $iamFresh = $true
}
# Attach role to profile; ignore error if already attached.
& aws iam add-role-to-instance-profile --instance-profile-name $profileName --role-name $roleName 2>$null | Out-Null
if ($iamFresh) { Write-Host "Waiting 15s for IAM consistency..."; Start-Sleep -Seconds 15 }
Write-Host "IAM        = $roleName / $profileName"

# ------------------------------------------------------------- key pair ----
$keyExists = & aws ec2 describe-key-pairs --key-names "$PROJECT-key" --query 'KeyPairs[0].KeyName' --output text 2>$null
if ((Ok $keyExists) -and -not (Test-Path $PEM)) {
    # Key exists in AWS but we lost the private material - recreate it.
    Write-Host "Key exists without local .pem - recreating key pair." -ForegroundColor Yellow
    & aws ec2 delete-key-pair --key-name "$PROJECT-key" 2>$null | Out-Null
    $keyExists = $null
}
if (-not (Ok $keyExists)) {
    & aws ec2 create-key-pair --key-name "$PROJECT-key" --query 'KeyMaterial' --output text | Out-File $PEM -Encoding ascii
    Write-Host "Key pair created -> $PEM"
}

# --------------------------------------------------------------- AMI id ----
if (-not (Has 'AMI_ID')) {
    $S.AMI_ID = & aws ssm get-parameters `
        --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 `
        --query 'Parameters[0].Value' --output text
    Save-State
}
Write-Host "AMI_ID     = $($S.AMI_ID)"

# ------------------------------------------------------ user-data script ----
$USERDATA = Join-Path $PSScriptRoot "userdata.sh"
@"
#!/bin/bash
dnf update -y
dnf install -y docker git
systemctl enable --now docker

cd /home/ec2-user
git clone https://github.com/$GITHUB_USER/obscura.git app
cd app
docker build -t obscura .
docker run -d --restart always -p 8080:8080 \
  -e AWS_REGION=$($env:AWS_REGION) \
  -e BUCKET_NAME=$($S.BUCKET) \
  obscura
"@ | Out-File $USERDATA -Encoding ascii

function Alive($id) {
    if (-not (Ok $id)) { return $false }
    $st = & aws ec2 describe-instances --instance-ids $id --query 'Reservations[0].Instances[0].State.Name' --output text 2>$null
    return ($st -eq 'pending' -or $st -eq 'running')
}
function Launch($subnet, $name) {
    return & aws ec2 run-instances --image-id $S.AMI_ID --instance-type $INSTANCE_TYPE `
        --key-name "$PROJECT-key" --iam-instance-profile Name=$profileName `
        --security-group-ids $S.EC2_SG --subnet-id $subnet `
        --user-data "file://$USERDATA" `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" `
        --query 'Instances[0].InstanceId' --output text
}

# ------------------------------------------------------------ instances ----
if (-not (Alive $S.INST_A)) { $S.INST_A = Launch $S.SUBNET_A "$PROJECT-app-a"; Save-State }
if (-not (Alive $S.INST_B)) { $S.INST_B = Launch $S.SUBNET_B "$PROJECT-app-b"; Save-State }
Write-Host "INST_A/B   = $($S.INST_A) / $($S.INST_B)"
Write-Host "  (boot + docker build takes ~3-5 min before health checks pass)"

# --------------------------------------------------------- target group ----
if (-not (Has 'TG_ARN')) {
    $existingTg = & aws elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
    if (Ok $existingTg) { $S.TG_ARN = $existingTg }
}
if (-not (Has 'TG_ARN')) {
    $S.TG_ARN = & aws elbv2 create-target-group --name "$PROJECT-tg" --protocol HTTP --port 8080 `
        --vpc-id $S.VPC_ID --target-type instance --health-check-path /health `
        --health-check-interval-seconds 15 --healthy-threshold-count 2 `
        --query 'TargetGroups[0].TargetGroupArn' --output text
    Save-State
}
# register-targets is idempotent
& aws elbv2 register-targets --target-group-arn $S.TG_ARN --targets Id=$($S.INST_A) Id=$($S.INST_B) 2>$null | Out-Null
Write-Host "TG_ARN     = $($S.TG_ARN)"

# ------------------------------------------------------------------ ALB ----
if (-not (Has 'ALB_ARN')) {
    $existingAlb = & aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>$null
    if (Ok $existingAlb) { $S.ALB_ARN = $existingAlb }
}
if (-not (Has 'ALB_ARN')) {
    $S.ALB_ARN = & aws elbv2 create-load-balancer --name "$PROJECT-alb" --type application `
        --scheme internet-facing --subnets $S.SUBNET_A $S.SUBNET_B --security-groups $S.ALB_SG `
        --query 'LoadBalancers[0].LoadBalancerArn' --output text
    Save-State
}
$S.ALB_DNS = & aws elbv2 describe-load-balancers --load-balancer-arns $S.ALB_ARN --query 'LoadBalancers[0].DNSName' --output text
Save-State
# Ensure a listener exists (idempotent).
$listener = & aws elbv2 describe-listeners --load-balancer-arn $S.ALB_ARN --query 'Listeners[0].ListenerArn' --output text 2>$null
if (-not (Ok $listener)) {
    & aws elbv2 create-listener --load-balancer-arn $S.ALB_ARN --protocol HTTP --port 80 `
        --default-actions Type=forward,TargetGroupArn=$($S.TG_ARN) | Out-Null
}
Write-Host "ALB_DNS    = $($S.ALB_DNS)"

# ----------------------------------------------------------- CloudFront ----
if (-not (Has 'CF_ID')) {
    $existingCf = & aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='Obscura CDN'].Id | [0]" --output text 2>$null
    if (Ok $existingCf) {
        $S.CF_ID = $existingCf
        $S.CF_DOMAIN = & aws cloudfront get-distribution --id $S.CF_ID --query 'Distribution.DomainName' --output text
    }
}
if (-not (Has 'CF_ID')) {
    @"
{
  "CallerReference": "$PROJECT-$([int][double](Get-Date -UFormat %s))",
  "Comment": "Obscura CDN",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "obscura-alb",
        "DomainName": "$($S.ALB_DNS)",
        "CustomOriginConfig": {
          "HTTPPort": 80, "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] },
          "OriginReadTimeout": 30, "OriginKeepaliveTimeout": 5
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
"@ | Out-File (Join-Path $PSScriptRoot "cf-config.json") -Encoding ascii

    $cfRaw = & aws cloudfront create-distribution --distribution-config "file://$(Join-Path $PSScriptRoot 'cf-config.json')"
    $cf = ($cfRaw -join "") | ConvertFrom-Json
    $S.CF_ID     = $cf.Distribution.Id
    $S.CF_DOMAIN = $cf.Distribution.DomainName
    Save-State
}
Write-Host "CF_ID      = $($S.CF_ID)"
Write-Host "CF_DOMAIN  = $($S.CF_DOMAIN)"

# ------------------------------------------------- lock ALB to CloudFront ----
# Note: CachePolicyId 4135ea2d... = managed CachingDisabled (dynamic app).
#       OriginRequestPolicyId 216adef6... = managed AllViewer.
$PL_ID = & aws ec2 describe-managed-prefix-lists `
    --filters "Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing" `
    --query 'PrefixLists[0].PrefixListId' --output text
if (Ok $PL_ID) {
    & aws ec2 authorize-security-group-ingress --group-id $S.ALB_SG `
        --ip-permissions IpProtocol=tcp,FromPort=80,ToPort=80,PrefixListIds="[{PrefixListId=$PL_ID}]" 2>$null | Out-Null
    & aws ec2 revoke-security-group-ingress --group-id $S.ALB_SG --protocol tcp --port 80 --cidr 0.0.0.0/0 2>$null | Out-Null
    Write-Host "ALB locked to CloudFront prefix list $PL_ID"
}

Save-State
Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host " Deploy complete. State saved to state.env" -ForegroundColor Green
Write-Host " Live app (after CloudFront finishes ~5-10 min): https://$($S.CF_DOMAIN)" -ForegroundColor Green
Write-Host " Check target health:" -ForegroundColor Green
Write-Host "   aws elbv2 describe-target-health --target-group-arn $($S.TG_ARN) --query 'TargetHealthDescriptions[].TargetHealth.State'" -ForegroundColor Green
Write-Host " When finished, run:   ./cleanup.ps1" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
