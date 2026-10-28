#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
Describe 'Serve bounded synthetic performance gate' {
    It 'keeps first and warm HTTP list requests below one second with an indexed order and a concurrent writer' {
        $path = & (Join-Path $PSScriptRoot 'Serve.Measure.ps1') -Messages 12000
        $evidence = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $evidence.scale24GBProven | Should -BeFalse
        $evidence.osCacheCold | Should -BeFalse
        $evidence.messageRows | Should -Be 12000
        $evidence.trackingEvents | Should -Be 24000
        $evidence.gatePassed | Should -BeTrue
        $evidence.rollupVerification.Verified | Should -BeTrue
        $evidence.rollupVerification.RowsVerified | Should -Be 12000
        $evidence.rollupVerification.SourceHashesVerified | Should -BeTrue
        $evidence.overview.maxMilliseconds | Should -BeLessThan 1000
        $evidence.unfilteredPlan -join "`n" | Should -Match 'ix_rollup_last'
        $evidence.unfilteredPlan -join "`n" | Should -Not -Match 'TEMP B-TREE'
        foreach ($case in $evidence.lists) {
            $case.firstRequestMilliseconds | Should -BeLessThan 1000
            $case.warmP95Milliseconds | Should -BeLessThan 1000
            $case.maxMilliseconds | Should -BeLessThan 1000
        }
        $evidence.writerCommittedDuringHttpStream | Should -BeTrue
        $evidence.writerCommitDuringHttpStreamMilliseconds | Should -BeLessThan 1000
    }
}
