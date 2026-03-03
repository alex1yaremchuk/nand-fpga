function Get-JackCorpusCases {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    return @(
        @{
            Name = "loop_sum"
            JackInput = Join-Path $RepoRoot "tools/programs/JackCorpus/LoopSum"
            Cycles = 500
            ExpectAddr = 16
            ExpectValue = 15
        },
        @{
            Name = "branch_max"
            JackInput = Join-Path $RepoRoot "tools/programs/JackCorpus/BranchMax"
            Cycles = 500
            ExpectAddr = 16
            ExpectValue = 11
        },
        @{
            Name = "nested_calls"
            JackInput = Join-Path $RepoRoot "tools/programs/JackCorpus/NestedCalls"
            Cycles = 700
            ExpectAddr = 16
            ExpectValue = 3
        },
        @{
            Name = "unary_compare"
            JackInput = Join-Path $RepoRoot "tools/programs/JackCorpus/UnaryCompare"
            Cycles = 700
            ExpectAddr = 16
            ExpectValue = 124
        },
        @{
            Name = "static_counter"
            JackInput = Join-Path $RepoRoot "tools/programs/JackCorpus/StaticCounter"
            Cycles = 700
            ExpectAddr = 17
            ExpectValue = 2
        }
    )
}
