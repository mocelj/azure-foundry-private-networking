#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Unit tests for address-plan validation (no Azure required).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\scripts\preflight\NetworkValidation.psm1') -Force
    $script:default = @{
        privateEndpoints = '10.80.1.0/24'; management = '10.80.2.0/24'; bastion = '10.80.3.0/26'
        app = ''; integration = ''; agent = '10.80.6.0/24'
    }
}

Describe 'ConvertTo-CidrRange' {
    It 'parses a valid CIDR' {
        $r = ConvertTo-CidrRange '10.80.1.0/24'
        $r.Prefix | Should -Be 24
        ($r.End - $r.Start) | Should -Be 255
    }
    It 'rejects malformed input' { { ConvertTo-CidrRange '10.80.1.0' } | Should -Throw }
    It 'rejects octets > 255' { { ConvertTo-CidrRange '10.80.300.0/24' } | Should -Throw }
    It 'rejects unaligned network address' { { ConvertTo-CidrRange '10.80.1.5/24' } | Should -Throw '*not aligned*' }
}

Describe 'Get-CidrSubnet (mirrors Bicep cidrSubnet for the RAG app subnet default)' {
    It 'returns the 5th /24 of a /16' { Get-CidrSubnet '10.80.0.0/16' 24 4 | Should -Be '10.80.4.0/24' }
    It 'does not collide with the default plan' {
        $s = $script:default.Clone(); $s.app = Get-CidrSubnet '10.80.0.0/16' 24 4
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s).Count | Should -Be 0
    }
    It 'throws when the index does not fit' { { Get-CidrSubnet '10.80.0.0/22' 24 4 } | Should -Throw '*does not fit*' }
}

Describe 'Test-AddressPlan' {
    It 'accepts the default plan' {
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $script:default).Count | Should -Be 0
    }
    It 'detects overlapping subnets' {
        $s = $script:default.Clone(); $s.app = '10.80.1.128/25'
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s) -join ';' | Should -Match 'overlap'
    }
    It 'detects subnets outside the VNet' {
        $s = $script:default.Clone(); $s.app = '10.81.4.0/24'
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s) -join ';' | Should -Match 'outside VNet'
    }
    It 'rejects the Docker bridge range' {
        $s = @{ privateEndpoints = '172.17.1.0/24' }
        (Test-AddressPlan -VnetPrefix '172.17.0.0/16' -Subnets $s) -join ';' | Should -Match '172.17.0.0/16'
    }
    It 'rejects Agent Service reserved ranges' {
        $s = @{ privateEndpoints = '172.31.1.0/24' }
        (Test-AddressPlan -VnetPrefix '172.31.0.0/16' -Subnets $s) -join ';' | Should -Match 'reserved'
    }
    It 'rejects public address space' {
        $s = @{ privateEndpoints = '20.1.1.0/24' }
        (Test-AddressPlan -VnetPrefix '20.1.0.0/16' -Subnets $s) -join ';' | Should -Match 'RFC1918'
    }
    It 'rejects an agent subnet smaller than /27' {
        $s = $script:default.Clone(); $s.agent = '10.80.6.0/28'
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s) -join ';' | Should -Match 'Agent subnet must be /27'
    }
    It 'rejects a Bastion subnet smaller than /26' {
        $s = $script:default.Clone(); $s.bastion = '10.80.3.0/27'
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s) -join ';' | Should -Match 'AzureBastionSubnet'
    }
    It 'rejects PE subnet in 192.168.0.0/24 (hosted agent sandbox)' {
        $s = @{ privateEndpoints = '192.168.0.0/24'; agent = '192.168.1.0/24' }
        (Test-AddressPlan -VnetPrefix '192.168.0.0/16' -Subnets $s) -join ';' | Should -Match 'hosted agent sandbox'
    }
    It 'detects overlap with the hub / connected networks' {
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $script:default -OtherNetworks @('10.0.0.0/8')) -join ';' | Should -Match 'connected network'
    }
    It 'ignores empty (disabled) subnets' {
        $s = $script:default.Clone(); $s.bastion = ''; $s.management = ''
        (Test-AddressPlan -VnetPrefix '10.80.0.0/16' -Subnets $s).Count | Should -Be 0
    }
}
