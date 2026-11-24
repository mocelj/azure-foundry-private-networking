# CIDR / address-plan validation helpers used by preflight and unit tests.
Set-StrictMode -Version Latest

function ConvertTo-CidrRange {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cidr)
    if ($Cidr -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        throw "Invalid IPv4 CIDR '$Cidr'."
    }
    $octets = 1..4 | ForEach-Object { [int]$Matches[$_] }
    $prefix = [int]$Matches[5]
    if (($octets | Where-Object { $_ -gt 255 }) -or $prefix -gt 32) { throw "Invalid IPv4 CIDR '$Cidr'." }
    [uint64]$ip = ([uint64]$octets[0] -shl 24) + ([uint64]$octets[1] -shl 16) + ([uint64]$octets[2] -shl 8) + [uint64]$octets[3]
    [uint64]$size = [math]::Pow(2, 32 - $prefix)
    [uint64]$start = $ip - ($ip % $size)
    if ($start -ne $ip) { throw "CIDR '$Cidr' is not aligned to its prefix length (network address should be $(ConvertFrom-UInt32 $start)/$prefix)." }
    [pscustomobject]@{ Cidr = $Cidr; Start = $start; End = $start + $size - 1; Prefix = $prefix }
}

function ConvertFrom-UInt32([uint64]$v) {
    '{0}.{1}.{2}.{3}' -f (($v -shr 24) -band 255), (($v -shr 16) -band 255), (($v -shr 8) -band 255), ($v -band 255)
}

# Same semantics as Bicep cidrSubnet(): the Nth subnet of size /NewPrefix inside Cidr.
function Get-CidrSubnet([string]$Cidr, [int]$NewPrefix, [int]$Index) {
    $r = ConvertTo-CidrRange $Cidr
    if ($NewPrefix -lt $r.Prefix) { throw "Prefix /$NewPrefix is larger than '$Cidr'." }
    [uint64]$size = [math]::Pow(2, 32 - $NewPrefix)
    [uint64]$start = $r.Start + ($size * $Index)
    if ($start + $size - 1 -gt $r.End) { throw "Subnet index $Index of /$NewPrefix does not fit in '$Cidr'." }
    "$(ConvertFrom-UInt32 $start)/$NewPrefix"
}

function Test-CidrOverlap([string]$A, [string]$B) {
    $ra = ConvertTo-CidrRange $A; $rb = ConvertTo-CidrRange $B
    return ($ra.Start -le $rb.End) -and ($rb.Start -le $ra.End)
}

function Test-CidrContains([string]$Outer, [string]$Inner) {
    $ro = ConvertTo-CidrRange $Outer; $ri = ConvertTo-CidrRange $Inner
    return ($ri.Start -ge $ro.Start) -and ($ri.End -le $ro.End)
}

# Ranges that must not be used (Docker bridge + Agent Service reserved ranges).
$script:ReservedRanges = @(
    '172.17.0.0/16', '169.254.0.0/16', '172.30.0.0/16', '172.31.0.0/16', '192.0.2.0/24',
    '0.0.0.0/8', '127.0.0.0/8', '100.100.0.0/17', '100.100.192.0/19', '100.100.224.0/19'
)
$script:AllowedPrivate = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10')

function Test-AddressPlan {
    <#
      .SYNOPSIS Validates the VNet/subnet plan. Returns a list of error strings (empty = valid).
      .PARAMETER Subnets Hashtable name -> CIDR. Empty values are ignored.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VnetPrefix,
        [Parameter(Mandatory)][hashtable]$Subnets,
        [string[]]$OtherNetworks = @(),
        [string]$AgentSubnetName = 'agent',
        [string]$PeSubnetName = 'privateEndpoints',
        [string]$BastionSubnetName = 'bastion'
    )
    $errors = [System.Collections.Generic.List[string]]::new()
    try { $null = ConvertTo-CidrRange $VnetPrefix } catch { $errors.Add("VNet: $($_.Exception.Message)"); return , $errors }

    if (-not ($script:AllowedPrivate | Where-Object { Test-CidrContains $_ $VnetPrefix })) {
        $errors.Add("VNet $VnetPrefix must be inside RFC1918 (10/8, 172.16/12, 192.168/16) or RFC6598 (100.64/10).")
    }
    foreach ($r in $script:ReservedRanges) {
        if (Test-CidrOverlap $VnetPrefix $r) { $errors.Add("VNet $VnetPrefix overlaps reserved range $r.") }
    }

    $active = @{}
    foreach ($k in $Subnets.Keys) { if (-not [string]::IsNullOrWhiteSpace($Subnets[$k])) { $active[$k] = $Subnets[$k] } }

    foreach ($k in $active.Keys) {
        try { $r = ConvertTo-CidrRange $active[$k] } catch { $errors.Add("Subnet ${k}: $($_.Exception.Message)"); continue }
        if (-not (Test-CidrContains $VnetPrefix $active[$k])) { $errors.Add("Subnet $k ($($active[$k])) is outside VNet $VnetPrefix.") }
        if ($k -eq $AgentSubnetName -and $r.Prefix -gt 27) { $errors.Add("Agent subnet must be /27 or larger (got /$($r.Prefix)); /24 recommended.") }
        if ($k -eq $BastionSubnetName -and $r.Prefix -gt 26) { $errors.Add("AzureBastionSubnet must be /26 or larger (got /$($r.Prefix)).") }
        if ($k -eq $PeSubnetName -and (Test-CidrOverlap $active[$k] '192.168.0.0/24')) {
            $errors.Add("Private endpoint subnet must not overlap 192.168.0.0/24 (hosted agent sandbox network).")
        }
    }

    $keys = @($active.Keys | Sort-Object)
    for ($i = 0; $i -lt $keys.Count; $i++) {
        for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            try {
                if (Test-CidrOverlap $active[$keys[$i]] $active[$keys[$j]]) {
                    $errors.Add("Subnets $($keys[$i]) ($($active[$keys[$i]])) and $($keys[$j]) ($($active[$keys[$j]])) overlap.")
                }
            } catch { }
        }
    }

    foreach ($n in $OtherNetworks) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        if (Test-CidrOverlap $VnetPrefix $n) { $errors.Add("VNet $VnetPrefix overlaps connected network $n (hub/peer/on-premises).") }
    }
    return , $errors
}

Export-ModuleMember -Function ConvertTo-CidrRange, Test-CidrOverlap, Test-CidrContains, Test-AddressPlan, Get-CidrSubnet
