# bazzite-mx: Windows-style Ctrl+C / Ctrl+V in PowerShell. pwsh is not in the image; this
# default applies to a pwsh the user installs (Homebrew, distrobox). Scoped to PSReadLine, so
# bash keeps its own bindings. PSReadLine's built-in clipboard functions need xclip on Linux;
# these handlers use wl-clipboard, which the base ships.
if ((Get-Module PSReadLine) -and (Get-Command wl-copy, wl-paste -ErrorAction SilentlyContinue)) {
    # Copy the PSReadLine selection (Shift+arrows) when there is one, else
    # cancel the current line: the CopyOrCancelLine semantics of Windows.
    Set-PSReadLineKeyHandler -Chord Ctrl+c -BriefDescription CopyOrCancelLine -ScriptBlock {
        $start = 0; $length = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetSelectionState([ref]$start, [ref]$length)
        if ($start -ge 0) {
            $line = ''; $cursor = 0
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
            # wl-copy forks a daemon that inherits a redirected stdout/stderr
            # and would hold the PowerShell pipeline open: redirect stdin only,
            # so the daemon detaches and the handler returns at once.
            $psi = [System.Diagnostics.ProcessStartInfo]::new('wl-copy')
            $psi.ArgumentList.Add('--trim-newline')
            $psi.RedirectStandardInput = $true
            $psi.UseShellExecute = $false
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write($line.Substring($start, $length))
            $p.StandardInput.Close()
            $p.WaitForExit()
        } else {
            [Microsoft.PowerShell.PSConsoleReadLine]::CancelLine()
        }
    }

    Set-PSReadLineKeyHandler -Chord Ctrl+v -BriefDescription Paste -ScriptBlock {
        $text = (wl-paste --no-newline 2>$null) -join "`n"
        if ($text) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($text)
        }
    }
}
