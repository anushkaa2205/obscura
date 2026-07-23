# =============================================================================
#  Obscura - status / reconciliation  (READ ONLY, deletes nothing)
#  Lists every live AWS resource this project may have created, by name/tag.
#  Run this to see what a partial/failed deploy left behind before cleaning up.
# =============================================================================
$PSNativeCommandUseErrorActionPreference = $false
$env:AWS_REGION         = "ap-south-1"
$env:AWS_DEFAULT_REGION = "ap-south-1"
$PROJECT = "obscura"

function Ok($v) { return ($v -ne $null) -and ("$v".Trim() -ne "") -and ("$v".Trim() -ne "None") }
function Words($v) { if (-not (Ok $v)) { return @() } return ($v -split '\s+' | Where-Object { Ok $_ }) }
function Line($label, $value) {
    if (Ok $value) { Write-Host ("  {0,-16} {1}" -f $label, ($value -replace '\s+', ', ')) -ForegroundColor Green }
    else           { Write-Host ("  {0,-16} -" -f $label) -ForegroundColor DarkGray }
}

Write-Host "== Obscura live-resource report ($($env:AWS_REGION)) ==" -ForegroundColor Cyan
& aws sts get-caller-identity --query 'Arn' --output text 2>$null | ForEach-Object { Write-Host "Account: $_`n" }

$vpcList = & aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT-vpc" --query 'Vpcs[].VpcId' --output text 2>$null
$vpcIds = Words $vpcList
Line "VPC" $vpcList
if ($vpcIds.Count -gt 1) { Write-Host "  ^ WARNING: $($vpcIds.Count) VPCs found - an earlier deploy attempt was likely re-run without cleaning up first." -ForegroundColor Red }

# Query each VPC separately (a multi-value filter silently returns nothing) and merge.
$allSubnets = @(); $allRts = @(); $allSgs = @()
foreach ($v in $vpcIds) {
    $allSubnets += Words (& aws ec2 describe-subnets --filters "Name=vpc-id,Values=$v" --query 'Subnets[].SubnetId' --output text 2>$null)
    $allRts     += Words (& aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$v" --query 'RouteTables[].RouteTableId' --output text 2>$null)
    $allSgs     += Words (& aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$v" "Name=group-name,Values=$PROJECT-*" --query 'SecurityGroups[].GroupId' --output text 2>$null)
}
Line "Subnets"   ($allSubnets -join ' ')
Line "RouteTbls" ($allRts -join ' ')
Line "SecGroups" ($allSgs -join ' ')
Line "IGW" (& aws ec2 describe-internet-gateways --filters "Name=tag:Name,Values=$PROJECT-igw" --query 'InternetGateways[].InternetGatewayId' --output text 2>$null)

Line "Instances" (& aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=$PROJECT-app-a,$PROJECT-app-b" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text 2>$null)

Line "ALB" (& aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[].LoadBalancerArn' --output text 2>$null)
Line "TargetGroup" (& aws elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[].TargetGroupArn' --output text 2>$null)

# Target health (only if TG exists)
$TG = & aws elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>$null
if (Ok $TG) {
    Line "TargetHealth" (& aws elbv2 describe-target-health --target-group-arn $TG --query 'TargetHealthDescriptions[].TargetHealth.State' --output text 2>$null)
}

Line "CloudFront" (& aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='Obscura CDN'].[Id,Status,DomainName]" --output text 2>$null)
Line "S3 buckets" (& aws s3api list-buckets --query "Buckets[?starts_with(Name, '$PROJECT-clean-')].Name" --output text 2>$null)
Line "IAM role" (& aws iam get-role --role-name "$PROJECT-ec2-role" --query 'Role.RoleName' --output text 2>$null)
Line "InstProfile" (& aws iam get-instance-profile --instance-profile-name "$PROJECT-ec2-profile" --query 'InstanceProfile.InstanceProfileName' --output text 2>$null)
Line "Key pair" (& aws ec2 describe-key-pairs --key-names "$PROJECT-key" --query 'KeyPairs[].KeyName' --output text 2>$null)

Write-Host "`nGreen = live (may be costing credit).  Grey = not present." -ForegroundColor Cyan
Write-Host "To remove everything above: ./cleanup.ps1" -ForegroundColor Cyan
