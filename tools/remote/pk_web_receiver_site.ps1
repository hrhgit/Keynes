# --------------------------------------------------------------- target ------
# Resolve every physical directory IIS serves for /<AppName>/.
#
# This follows the older deploy-web-debug.ps1 on purpose: that box has both an
# IP site and a domain site, and updating only one of them leaves "new package on
# the IP, old package on the domain" - the exact split its README warns about. So
# every virtual directory ending in /<AppName> is returned, not just the first.
function Resolve-TargetRoots {
    if ($TargetRoot) {
        $single = $TargetRoot.TrimEnd('\')
        return @([pscustomobject]@{
            Site      = '(explicit)'
            Target    = $single
            Url       = ''
            ProbeUrl  = ''
            ProbeHost = ''
            HasHttps  = $false
        })
    }
    $appcmd = $env:PK_IIS_APPCMD
    if (-not $appcmd) { $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe' }
    if (-not (Test-Path -LiteralPath $appcmd)) {
        throw "IIS appcmd.exe not found: $appcmd (is IIS installed?)"
    }
    $sites = New-Object System.Collections.ArrayList
    foreach ($line in (& $appcmd list site)) {
        if ($line -match '^SITE "([^"]+)" \(id:(\d+),bindings:(.*?),state:(\w+)\)') {
            $entry = [pscustomobject]@{
                Name     = $matches[1]
                Bindings = $matches[3]
                Root     = ''
                Hosts    = (New-Object System.Collections.ArrayList)
                HasHttps = $false
            }
            foreach ($binding in ($entry.Bindings -split ',')) {
                if (-not $binding) { continue }
                if ($binding -match '^(https?)/([^:]*):(\d+):(.*)$') {
                    $proto = $matches[1]
                    $port = $matches[3]
                    $hostName = $matches[4]
                    if ($proto -eq 'https') { $entry.HasHttps = $true }
                    if ($hostName -and $hostName -ne '*') { [void]$entry.Hosts.Add($hostName) }
                }
            }
            [void]$sites.Add($entry)
        }
    }

    $targets = New-Object System.Collections.ArrayList
    foreach ($line in (& $appcmd list vdir)) {
        if ($line -match '^VDIR "(.+?)/" \(physicalPath:(.+)\)$') {
            $vdir = $matches[1]
            $physical = $matches[2]
            $siteName = ($vdir -split '/')[0]
            foreach ($s in $sites) {
                if ($s.Name -eq $siteName -and -not $s.Root) { $s.Root = $physical }
            }
            if ($vdir -match ('/' + [regex]::Escape($AppName) + '$')) {
                $site = $sites | Where-Object { $_.Name -eq $siteName } | Select-Object -First 1
                $hosts = @()
                $hasHttps = $false
                if ($site) { $hosts = @($site.Hosts); $hasHttps = $site.HasHttps }
                $probeHost = ''
                if ($hosts.Count -gt 0) { $probeHost = [string]$hosts[0] }
                $url = ''
                if ($probeHost) {
                    $scheme = 'http'
                    if ($hasHttps) { $scheme = 'https' }
                    $url = ('{0}://{1}/{2}/' -f $scheme, $probeHost, $AppName)
                }
                [void]$targets.Add([pscustomobject]@{
                    Site      = $siteName
                    Target    = $physical.TrimEnd('\')
                    Url       = $url
                    ProbeUrl  = ('http://127.0.0.1/{0}/index.html' -f $AppName)
                    ProbeHost = $probeHost
                    HasHttps  = $hasHttps
                })
                Write-Log ("target from appcmd: vdir={0} physical={1} https={2}" -f $vdir, $physical, $hasHttps)
            }
        }
    }
    if ($targets.Count -gt 0) { return @($targets) }

    $site = $sites | Where-Object { $_.Bindings -match 'http/[^,:]*:80:' } | Select-Object -First 1
    if (-not $site) { $site = $sites | Select-Object -First 1 }
    if (-not $site -or -not $site.Root) { throw "cannot resolve a site root for /$AppName/" }
    $fallback = Join-Path $site.Root $AppName
    Write-Log ("target from site root: site={0} root={1} -> {2}" -f $site.Name, $site.Root, $fallback)
    $probeHost = ''
    if (@($site.Hosts).Count -gt 0) { $probeHost = [string]@($site.Hosts)[0] }
    $fallbackUrl = ''
    if ($probeHost) {
        $fallbackUrl = ('{0}://{1}/{2}/' -f $(if ($site.HasHttps) { 'https' } else { 'http' }), $probeHost, $AppName)
    }
    return @([pscustomobject]@{
        Site      = $site.Name
        Target    = $fallback.TrimEnd('\')
        Url       = $fallbackUrl
        ProbeUrl  = ('http://127.0.0.1/{0}/index.html' -f $AppName)
        ProbeHost = $probeHost
        HasHttps  = $site.HasHttps
    })
}

# First target only - used by /health and by callers that just want one path.
function Resolve-TargetRoot {
    $all = @(Resolve-TargetRoots)
    if ($all.Count -eq 0) { throw "no target resolved for /$AppName/" }
    return $all[0].Target
}

# ------------------------------------------------------------ site update ----
$WebConfigTemplate = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="Cross-Origin-Opener-Policy" value="same-origin" />
        <add name="Cross-Origin-Embedder-Policy" value="require-corp" />
        <add name="Cross-Origin-Resource-Policy" value="same-origin" />
      </customHeaders>
    </httpProtocol>
    <staticContent>
      <remove fileExtension=".wasm" />
      <mimeMap fileExtension=".wasm" mimeType="application/wasm" />
      <remove fileExtension=".pck" />
      <mimeMap fileExtension=".pck" mimeType="application/octet-stream" />
      <remove fileExtension=".worklet.js" />
      <mimeMap fileExtension=".worklet.js" mimeType="text/javascript" />
    </staticContent>
  </system.webServer>
</configuration>
'@

$IndexHtmlTemplate = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <title>Project.Keynes Web</title>
  <meta http-equiv="refresh" content="0; url=ProjectKeynes.html">
</head>
<body style="background:#111;color:#ddd;font-family:sans-serif">
  <p>Loading <a href="ProjectKeynes.html" style="color:#6cf">ProjectKeynes.html</a> ...</p>
</body>
</html>
'@

# Browser-side self check, deployed next to the game. Same purpose as the
# check.html that shipped with the older hand-made deploy package: the threads
# build needs a secure context plus cross-origin isolation, and over plain http
# on a bare IP neither is available - which looks like a broken game, not a
# header problem. ASCII only, so it renders the same whatever the codepage is.
$CheckHtmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>COI check</title>
<style>
  body{margin:0;padding:16px;background:#111;color:#ddd;font:14px/1.7 ui-monospace,Consolas,monospace}
  h1{font-size:16px;color:#6cf;margin:0 0 12px}
  table{border-collapse:collapse;width:100%}
  td{padding:4px 8px;border-bottom:1px solid #2a2a2a;vertical-align:top;word-break:break-all}
  td:first-child{color:#888;white-space:nowrap;width:42%}
  .ok{color:#4caf50;font-weight:700}
  .bad{color:#f44336;font-weight:700}
</style>
</head>
<body>
<h1>Cross-Origin Isolation check</h1>
<div id="verdict" style="margin-bottom:12px"></div>
<table id="rows"></table>
<p style="color:#666;margin-top:16px">
  Godot's threads build needs isSecureContext, crossOriginIsolated and SharedArrayBuffer.
  Plain http on a bare IP gives you none of them; use https (a domain with a certificate).
</p>
<script>
(function () {
  var sb = (typeof SharedArrayBuffer !== 'undefined');
  var coi = (window.crossOriginIsolated === true);
  var sec = (window.isSecureContext === true);
  var rows = [
    ['URL', location.href],
    ['isSecureContext', sec],
    ['crossOriginIsolated', coi],
    ['SharedArrayBuffer', sb ? 'function' : String(typeof SharedArrayBuffer)],
    ['WebAssembly', typeof WebAssembly],
    ['hardwareConcurrency', navigator.hardwareConcurrency],
    ['WebGL2', (function () {
        try {
          var c = document.createElement('canvas');
          return !!(c.getContext && c.getContext('webgl2'));
        } catch (e) { return 'error'; }
      })()]
  ];
  var t = document.getElementById('rows');
  for (var i = 0; i < rows.length; i++) {
    var tr = document.createElement('tr');
    var a = document.createElement('td');
    a.textContent = rows[i][0];
    var b = document.createElement('td');
    b.textContent = String(rows[i][1]);
    if (typeof rows[i][1] === 'boolean') { b.className = rows[i][1] ? 'ok' : 'bad'; }
    tr.appendChild(a); tr.appendChild(b); t.appendChild(tr);
  }
  var v = document.getElementById('verdict');
  if (sec && coi && sb) {
    v.className = 'ok';
    v.textContent = 'OK: this browser can run the threads build.';
  } else if (!sec) {
    v.className = 'bad';
    v.textContent = 'FAIL: not a secure context. Open the site over https, not http on an IP.';
  } else if (!coi) {
    v.className = 'bad';
    v.textContent = 'FAIL: not cross-origin isolated. Check that web.config is being served (COOP/COEP headers).';
  } else {
    v.className = 'bad';
    v.textContent = 'FAIL: isolated but this engine does not expose SharedArrayBuffer.';
  }
  document.title = (sec && coi && sb) ? 'COI OK' : 'COI FAIL';
})();
</script>
</body>
</html>
'@

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $utf8Bom)
}

# Local HEAD against the site IIS just started serving. Used for 500.19 recovery
# and to report a per-site status; a refused connection (no IIS on this machine)
# is reported as "unknown", never treated as a failed deploy.
function Invoke-SiteProbe {
    param([string]$Url, [string]$HostHeader)
    if (-not $Url) { return [pscustomobject]@{ Code = 0; Error = 'no url'; Detail = 'unknown' } }
    try {
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = 8000
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        if ($HostHeader) {
            try { $request.Host = $HostHeader } catch { }
        }
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        $response.Close()
        return [pscustomobject]@{ Code = $code; Error = ''; Detail = ('HTTP ' + $code) }
    } catch [Net.WebException] {
        $code = 0
        try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
        if ($code -eq 0) { return [pscustomobject]@{ Code = 0; Error = $_.Exception.Message; Detail = 'no response from 127.0.0.1 (IIS not reachable here?)' } }
        return [pscustomobject]@{ Code = $code; Error = $_.Exception.Message; Detail = ('HTTP ' + $code) }
    } catch {
        return [pscustomobject]@{ Code = 0; Error = $_.Exception.Message; Detail = 'probe error' }
    }
}

# 500.19 means the directory is not allowed to override the sections in
# web.config; registering it as an IIS application fixes that (same fallback the
# older deploy package used).
function Enable-IisApplication {
    param([string]$Site, [string]$App, [string]$PhysicalPath)
    if (-not $Site -or $Site -eq '(explicit)') { return $false }
    $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
    $result = Invoke-Native $appcmd @('add', 'app', ('/site.name:' + $Site), ('/path:/' + $App), ('/physicalPath:' + $PhysicalPath))
    Write-Log ("appcmd add app site={0} path=/{1} exit={2}" -f $Site, $App, $result.Code)
    return ($result.Code -eq 0)
}

# Swap one site directory for the staged copy. The previous directory is renamed
# to <target>.bak-<stamp> so a rollback is one rename away; if the second rename
# fails the original name is restored.
function Update-OneSite {
    param([pscustomobject]$TargetInfo, [string]$StagingDir, [string]$Stamp)

    $target = $TargetInfo.Target
    $parent = Split-Path -Parent $target
    $leaf = Split-Path -Leaf $target
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $newDir = Join-Path $parent ($leaf + '.new-' + $Stamp)
    $bakDir = Join-Path $parent ($leaf + '.bak-' + $Stamp)
    if (Test-Path -LiteralPath $newDir) { Remove-Item -LiteralPath $newDir -Recurse -Force }

    Write-Log ("copying staging -> {0}" -f $newDir)
    Copy-Item -LiteralPath $StagingDir -Destination $newDir -Recurse -Force

    $old = $null
    if (Test-Path -LiteralPath $target) {
        Write-Log ("previous version -> {0}" -f $bakDir)
        Rename-Item -LiteralPath $target -NewName (Split-Path -Leaf $bakDir)
        $old = $bakDir
    }
    try {
        Rename-Item -LiteralPath $newDir -NewName $leaf
    } catch {
        if ($old) { try { Rename-Item -LiteralPath $old -NewName $leaf } catch { } }
        throw
    }

    # IIS worker identities need read access to what SYSTEM just created.
    try { [void](Invoke-Native 'icacls.exe' @($target, '/grant', 'IIS_IUSRS:(OI)(CI)(RX)', '/T')) } catch { Write-Log 'icacls grant skipped' 'WARN' }

    # Keep the two newest backups; drop older ones.
    $backups = @(Get-ChildItem -LiteralPath $parent -Directory -Filter ($leaf + '.bak-*') | Sort-Object Name -Descending)
    for ($i = 2; $i -lt $backups.Count; $i++) {
        Write-Log ("pruning old backup {0}" -f $backups[$i].FullName)
        Remove-Item -LiteralPath $backups[$i].FullName -Recurse -Force
    }

    $probe = Invoke-SiteProbe -Url $TargetInfo.ProbeUrl -HostHeader $TargetInfo.ProbeHost
    if ($probe.Code -eq 500) {
        Write-Log 'probe returned 500 - trying to register the directory as an IIS application'
        if (Enable-IisApplication -Site $TargetInfo.Site -App $AppName -PhysicalPath $target) {
            Start-Sleep -Seconds 2
            $probe = Invoke-SiteProbe -Url $TargetInfo.ProbeUrl -HostHeader $TargetInfo.ProbeHost
        }
    }

    $files = @(Get-ChildItem -LiteralPath $target -Recurse -File)
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    Write-Log ("updated {0}: {1} files, {2} bytes, probe={3}" -f $target, $files.Count, $bytes, $probe.Detail)

    $url = $TargetInfo.Url
    return [pscustomobject]@{
        site       = $TargetInfo.Site
        target     = $target
        url        = $url
        https      = [bool]$TargetInfo.HasHttps
        backup     = [string]$bakDir
        probe      = $probe.Detail
        probe_code = [int]$probe.Code
        file_count = $files.Count
        bytes      = [int64]$bytes
    }
}

# Deploy to every resolved target. One staging directory is extracted once and
# copied per site, so the package is unzipped once no matter how many sites exist.
function Update-Sites {
    param([string]$ZipPath)

    Assert-ZipApi
    $targets = @(Resolve-TargetRoots)
    if ($targets.Count -eq 0) { throw "no target resolved for /$AppName/" }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $staging = Join-Path $StateDir ('staging-' + $stamp)

    try {
        Write-Log ("extracting {0} -> {1} ({2} target(s))" -f $ZipPath, $staging, $targets.Count)
        [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $staging)

        $html = @(Get-ChildItem -LiteralPath $staging -Filter '*.html' -File)
        $pck = @(Get-ChildItem -LiteralPath $staging -Filter '*.pck' -File)
        if ($html.Count -eq 0 -or $pck.Count -eq 0) {
            throw ("package rejected: it has {0} html and {1} pck file(s); a Godot web export has both" -f $html.Count, $pck.Count)
        }
        Write-TextFile -Path (Join-Path $staging 'web.config') -Text $WebConfigTemplate
        Write-TextFile -Path (Join-Path $staging 'index.html') -Text $IndexHtmlTemplate
        Write-TextFile -Path (Join-Path $staging 'check.html') -Text $CheckHtmlTemplate

        $buildId = ''
        $manifest = Join-Path $staging 'manifest.json'
        if (Test-Path -LiteralPath $manifest) {
            try { $buildId = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).build_id } catch { }
        }

        $results = @()
        $failed = $null
        foreach ($t in $targets) {
            try {
                $results += Update-OneSite -TargetInfo $t -StagingDir $staging -Stamp $stamp
            } catch {
                $failed = $_
                Write-Log ("update failed for {0}: {1}" -f $t.Target, $_.Exception.Message) 'ERROR'
                break
            }
        }
        if ($failed) { throw $failed }

        $totalFiles = 0
        $totalBytes = [int64]0
        foreach ($r in $results) { $totalFiles += $r.file_count; $totalBytes += $r.bytes }
        $first = $results[0]
        Write-Log ("updated {0} site(s), {1} files, {2} bytes, build_id={3}" -f $results.Count, $totalFiles, $totalBytes, $buildId)

        return [pscustomobject]@{
            ok           = $true
            build_id     = $buildId
            site_count   = $results.Count
            file_count   = $totalFiles
            bytes        = $totalBytes
            target       = $first.target
            backup       = $first.backup
            url          = $first.url
            sites        = $results
        }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }
        }
    }
}
