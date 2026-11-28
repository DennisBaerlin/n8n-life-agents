#Requires -Version 5.1
# native_process.ps1 -- ein nativer Aufruf mit stdin aus einer Datei, byte-genau unter Windows und Linux. Dot-Sourcing: . "$PSScriptRoot\lib\native_process.ps1"
#
# Warum nicht ueberall Start-Process -RedirectStandardInput: Unter Windows reicht es die Datei als Handle durch (byte-genau, bewaehrt),
# unter Linux/macOS liest PowerShell 7 sie als Text (UTF-8) und schreibt sie mit einem Zeilenende in stdin. Ein Tar (Bau-Kontext fuer
# `docker build -`) kommt dort kaputt an: "archive/tar: invalid tar". Darum zwei Wege mit derselben Schnittstelle:
#   Windows:       Start-Process -RedirectStandardInput.
#   Linux/macOS:   System.Diagnostics.Process; die Datei wird als Bytes in den Eingabestrom kopiert, stdout und stderr (wenn Dateien
#                  genannt sind) nebenlaeufig als Bytes in ihre Dateien, damit ein Prozess mit viel Ausgabe nicht an vollem Puffer haengt.
#                  Der Weg gilt nicht fuer Windows: dort stellt .NET Framework dem Eingabestrom bei UTF-8-Konsole ein BOM voran.
# Ohne -StdoutFile/-StderrFile erbt der Aufruf die Konsole. Test: scripts/dev/native_process_test.ps1.
#   Invoke-NativeStdinFile -FilePath docker -ArgumentList @('build', '-') -StdinFile ctx.tar [-StdoutFile a.out] [-StderrFile a.err]
# Rueckgabe: Exit-Code des Prozesses.
#
# Ein Geheimnis (Passwort, Token) geht nie per Pipe an ein Programm (Wächter: scripts/secret_stdin_lint.ps1): die Pipe haengt ein
# Zeilenende an, und Windows PowerShell 5.1 stellt bei UTF-8-Konsole ein BOM davor. Stattdessen:
#   Invoke-NativeStdinBytes -FilePath docker -ArgumentList @('exec', '-i', $c, ...) -InputText $token [-CaptureOutput]
#   gibt genau die UTF-8-Bytes ohne BOM und ohne Zeilenende an stdin ('' = 0 Bytes, stdin sofort zu), nie ueber eine Datei.
#   Rueckgabe: Exit-Code; mit -CaptureOutput @{ Code; Output } (stdout- und stderr-Zeilen), sonst erbt der Aufruf die Konsole.
#   Invoke-GpgPassphrase -Gpg <exe> -Passphrase <text> -Arguments <gpg-Argumente> [-CaptureOutput]: gpg mit Passwort ueber stdin.
# Test: scripts/dev/secret_stdin_test.ps1.

# Eine Befehlszeile nach den Regeln der Windows-C-Laufzeit: Start-Process und ProcessStartInfo.Arguments (PS 5.1 hat keine
# ArgumentList) haengen Argumente sonst roh zusammen. Backslashes vor einem Anfuehrungszeichen zaehlen doppelt.
function ConvertTo-NativeArgLine([string[]]$ArgumentList) {
    return (@($ArgumentList | ForEach-Object {
                if ($_ -ne '' -and $_ -notmatch '[\s"]') { $_ }
                else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
            }) -join ' ')
}

function Invoke-NativeStdinBytes {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$InputText = '', [switch]$CaptureOutput)

    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($InputText)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = @(Get-Command $FilePath -CommandType Application -ErrorAction Stop)[0].Source
    $psi.Arguments = ConvertTo-NativeArgLine $ArgumentList
    $psi.UseShellExecute = $false
    # Sonst erbt das Programm den Ordner des Prozesses, den Set-Location nicht aendert.
    $psi.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    $psi.RedirectStandardInput = $true
    if ($CaptureOutput) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    # .NET Framework baut den stdin-Schreiber des Kindes aus [Console]::InputEncoding und schreibt dessen BOM beim Start.
    $prevIn = [Console]::InputEncoding
    try {
        try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }   # ohne Konsole nicht setzbar; die Pruefung darunter entscheidet
        if ([Console]::InputEncoding.GetPreamble().Length -gt 0) { throw 'Konsolen-Kodierung laesst sich nicht ohne BOM setzen: das Geheimnis wird nicht uebergeben.' }
        $p = [System.Diagnostics.Process]::Start($psi)
    } finally {
        try { [Console]::InputEncoding = $prevIn } catch { }
    }
    try {
        if ($CaptureOutput) { $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync() }
        # Schreiben darf scheitern: der Prozess hat aufgehoert zu lesen, sein Exit-Code sagt warum.
        try { $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $p.StandardInput.BaseStream.Flush() } catch { }
        try { $p.StandardInput.Close() } catch { }
        $p.WaitForExit()
        if (-not $CaptureOutput) { return $p.ExitCode }
        $lines = @(@($out.Result, $err.Result) | ForEach-Object { $_ -split "`r?`n" } | Where-Object { $_ -ne '' })
        return [pscustomobject]@{ Code = $p.ExitCode; Output = $lines }
    } finally {
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
    }
}

# gpg liest bei --passphrase-fd 0 bis zum ersten LF oder Ende: jedes Byte davor gehoert zum Passwort.
function Invoke-GpgPassphrase {
    param([Parameter(Mandatory)][string]$Gpg, [string]$Passphrase = '', [Parameter(Mandatory)][string[]]$Arguments, [switch]$CaptureOutput)
    $all = @('--batch', '--pinentry-mode', 'loopback', '--passphrase-fd', '0') + $Arguments
    return Invoke-NativeStdinBytes -FilePath $Gpg -ArgumentList $all -InputText $Passphrase -CaptureOutput:$CaptureOutput
}

function Invoke-NativeStdinFile {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$StdinFile, [string]$StdoutFile, [string]$StderrFile)

    if ($env:OS -eq 'Windows_NT') {
        $argLine = ConvertTo-NativeArgLine $ArgumentList
        $sp = @{ FilePath = $FilePath; NoNewWindow = $true; Wait = $true; PassThru = $true }
        if ($argLine) { $sp.ArgumentList = $argLine }
        if ($StdinFile) { $sp.RedirectStandardInput = $StdinFile }
        if ($StdoutFile) { $sp.RedirectStandardOutput = $StdoutFile }
        if ($StderrFile) { $sp.RedirectStandardError = $StderrFile }
        return (Start-Process @sp).ExitCode
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = [bool]$StdinFile
    $psi.RedirectStandardOutput = [bool]$StdoutFile
    $psi.RedirectStandardError = [bool]$StderrFile
    $p = [System.Diagnostics.Process]::Start($psi)
    $copies = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    $sinks = New-Object System.Collections.Generic.List[System.IO.FileStream]
    try {
        if ($StdoutFile) { $fs = [System.IO.File]::Create($StdoutFile); $sinks.Add($fs); $copies.Add($p.StandardOutput.BaseStream.CopyToAsync($fs)) }
        if ($StderrFile) { $fs = [System.IO.File]::Create($StderrFile); $sinks.Add($fs); $copies.Add($p.StandardError.BaseStream.CopyToAsync($fs)) }
        if ($StdinFile) {
            $in = [System.IO.File]::OpenRead($StdinFile)
            try {
                $stdin = $p.StandardInput.BaseStream
                $buf = New-Object byte[] 81920
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    # Nur das Schreiben darf scheitern: der Prozess hat aufgehoert zu lesen (fruehes Ende), sein Exit-Code und seine
                    # Fehlerausgabe sagen warum. Ein Lesefehler der Datei steigt auf.
                    try { $stdin.Write($buf, 0, $n) } catch { break }
                }
            } finally { $in.Dispose(); try { $p.StandardInput.Close() } catch { } }
        }
        $p.WaitForExit()
        if ($copies.Count -gt 0) { [System.Threading.Tasks.Task]::WaitAll($copies.ToArray()) }
    } finally {
        if (-not $p.HasExited) { try { $p.Kill() } catch { } }
        foreach ($s in $sinks) { $s.Dispose() }
    }
    return $p.ExitCode
}
