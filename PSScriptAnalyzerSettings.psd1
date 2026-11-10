@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # An interactive console tool: coloured Write-Host output is the user interface.
        'PSAvoidUsingWriteHost',
        # Changes are made only on the inspector's request inside a guided test (speaker volume is restored).
        'PSUseShouldProcessForStateChangingFunctions',
        # Names such as Get-RealPrinters and Get-GuidedTests return collections on purpose.
        'PSUseSingularNouns',
        # Empty catch blocks are limited to cosmetic calls (window title, icon, key buffer) and are commented.
        'PSAvoidUsingEmptyCatchBlock',
        # WinForms event handlers and test actions must accept ($sender, $e) / ($attempt) even when unused.
        'PSReviewUnusedParameter'
    )
}
