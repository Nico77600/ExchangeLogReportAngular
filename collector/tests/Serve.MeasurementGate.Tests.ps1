#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    function Get-GateExpression([string]$Name) {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Name),[ref]$tokens,[ref]$errors)
        if($errors.Count){throw ($errors -join '; ')}
        if($Name -eq 'Serve.Measure.ps1'){
            return $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$evidence.gatePassed'
            },$true).Right.Extent.Text
        }
        $table=$ast.Find({
            param($node)
            $node -is [Management.Automation.Language.HashtableAst] -and
                @($node.KeyValuePairs|Where-Object {$_.Item1.Value -eq 'gatePassed'}).Count -eq 1
        },$true)
        return @($table.KeyValuePairs|Where-Object {$_.Item1.Value -eq 'gatePassed'})[0].Item2.Extent.Text
    }
}

Describe 'Serve measurement gate reporting' {
    It '<Name> includes hourly overview without discarding the existing list failures' -ForEach @(
        @{Name='Serve.Measure.ps1'},@{Name='Serve.ReadOnlyMeasure.ps1'}
    ) {
        $expression=Get-GateExpression $Name
        $before='same'; $after='same'
        $results=@([pscustomobject]@{name='messages';passed=$true},[pscustomobject]@{name='hourlyOverview';passed=$false})
        $lists=@($results|Where-Object name -NE 'hourlyOverview')
        $evidence=@{lists=$lists;overview=$results[1]}
        (Invoke-Expression $expression) | Should -BeFalse
        $results[1].passed=$true
        (Invoke-Expression $expression) | Should -BeTrue
        $results[0].passed=$false
        (Invoke-Expression $expression) | Should -BeFalse
        $results[0].passed=$true; $after='changed'
        if($Name -eq 'Serve.ReadOnlyMeasure.ps1'){
            (Invoke-Expression $expression) | Should -BeFalse
        }
    }

    It 'fails the read-only command when only the hourly case fails' {
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Serve.ReadOnlyMeasure.ps1'),[ref]$tokens,[ref]$errors)
        $last=$ast.EndBlock.Statements[-1].Extent.Text
        $before='same'; $after='same'
        $results=@([pscustomobject]@{name='messages';passed=$true},[pscustomobject]@{name='hourlyOverview';passed=$false})
        $lists=@($results|Where-Object name -NE 'hourlyOverview')
        {Invoke-Expression $last} | Should -Throw '*list/overview gate failed*'
    }
}
