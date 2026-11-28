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
function Invoke-NativeStdinFile {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$StdinFile, [string]$StdoutFile, [string]$StderrFile)

    if ($env:OS -eq 'Windows_NT') {
        # Start-Process haengt die Argumente roh zusammen (PS 5.1 quotet nicht) -> selbst quoten.
        $argLine = ($ArgumentList | ForEach-Object { if ($_ -eq '' -or $_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
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
