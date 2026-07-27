param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern('^[a-p]{32}$')]
  [string]$ExtensionId,
  [string]$Version = '0.3.1'
)

$ErrorActionPreference = 'Stop'
$downloadRoot = 'https://waterdjiang.github.io/geo-action-privacy/downloads'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  throw '未找到 Node.js。请先安装 Node.js 18 或更高版本。'
}
$nodeMajor = [int](& $node.Source -p "Number(process.versions.node.split('.')[0])")
if ($nodeMajor -lt 18) {
  throw '当前 Node.js 版本过低，需要 Node.js 18 或更高版本。'
}

$installDirectory = Join-Path $env:LOCALAPPDATA 'GeoAction'
$binaryDirectory = Join-Path $installDirectory 'bin'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "geo-action-$([Guid]::NewGuid())"
New-Item -ItemType Directory -Force -Path $temporaryDirectory | Out-Null

try {
  if ($env:GEO_ACTION_PAYLOAD_DIR) {
    $payloadRoot = $env:GEO_ACTION_PAYLOAD_DIR
  } else {
    if ($Version -eq 'latest') {
      $releaseBase = "$downloadRoot/latest"
    } else {
      $releaseBase = "$downloadRoot/v$Version"
    }
    $archivePath = Join-Path $temporaryDirectory 'geo-action-cli.zip'
    $checksumsPath = Join-Path $temporaryDirectory 'checksums.txt'
    Invoke-WebRequest "$releaseBase/geo-action-cli.zip" -OutFile $archivePath
    Invoke-WebRequest "$releaseBase/checksums.txt" -OutFile $checksumsPath
    $expected = (Get-Content $checksumsPath |
      Where-Object { $_ -match ' geo-action-cli\.zip$' } |
      ForEach-Object { ($_ -split '\s+')[0] } |
      Select-Object -First 1)
    $actual = (Get-FileHash -Algorithm SHA256 $archivePath).Hash.ToLowerInvariant()
    if (-not $expected -or $actual -ne $expected.ToLowerInvariant()) {
      throw 'CLI 安装包 SHA-256 校验失败。'
    }
    Expand-Archive -Path $archivePath -DestinationPath $temporaryDirectory
    $payloadRoot = Join-Path $temporaryDirectory 'geo-action-cli'
  }

  $hostSource = Join-Path $payloadRoot 'native-host'
  $skillSource = Join-Path $payloadRoot 'skills\geo-action'
  if (-not (Test-Path (Join-Path $hostSource 'host.mjs')) -or
      -not (Test-Path (Join-Path $skillSource 'SKILL.md'))) {
    throw 'CLI 安装包结构不完整。'
  }

  New-Item -ItemType Directory -Force -Path $installDirectory, $binaryDirectory | Out-Null
  Copy-Item -Recurse -Force (Join-Path $hostSource '*') $installDirectory
  New-Item -ItemType Directory -Force -Path (Join-Path $installDirectory 'skills') | Out-Null
  $installedSkillPath = Join-Path $installDirectory 'skills\geo-action'
  if (Test-Path $installedSkillPath) {
    Remove-Item -Recurse -Force $installedSkillPath
  }
  Copy-Item -Recurse -Force $skillSource $installedSkillPath

  @{
    extensionId = $ExtensionId
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    version = '0.3.1'
  } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $installDirectory 'config.json')

  $tokenPath = Join-Path $installDirectory 'bridge-token'
  if (-not (Test-Path $tokenPath)) {
    & $node.Source -e "require('node:fs').writeFileSync(process.argv[1], require('node:crypto').randomBytes(32).toString('hex') + '\n')" $tokenPath
  }

  $hostScript = Join-Path $installDirectory 'host.mjs'
  $hostExecutable = Join-Path $installDirectory 'GeoActionNativeHost.exe'
  $escapedNode = $node.Source.Replace('\', '\\').Replace('"', '\"')
  $escapedHost = $hostScript.Replace('\', '\\').Replace('"', '\"')
  $source = @"
using System;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
public static class GeoActionNativeHost {
  static string Quote(string value) { return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; }
  public static int Main(string[] args) {
    var start = new ProcessStartInfo();
    start.FileName = "$escapedNode";
    start.Arguments = Quote("$escapedHost") + " " + String.Join(" ", args.Select(Quote));
    start.UseShellExecute = false;
    start.RedirectStandardInput = true;
    start.RedirectStandardOutput = true;
    start.RedirectStandardError = true;
    start.CreateNoWindow = true;
    var child = Process.Start(start);
    if (child == null) return 1;
    var input = Task.Run(async () => {
      await Console.OpenStandardInput().CopyToAsync(child.StandardInput.BaseStream);
      child.StandardInput.Close();
    });
    var stdout = child.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
    var stderr = child.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
    child.WaitForExit();
    Task.WaitAll(input, stdout, stderr);
    return child.ExitCode;
  }
}
"@
  if (Test-Path $hostExecutable) { Remove-Item -Force $hostExecutable }
  Add-Type -TypeDefinition $source -OutputAssembly $hostExecutable -OutputType ConsoleApplication

  $manifestPath = Join-Path $installDirectory 'cn.wattter.geo_action.json'
  @{
    name = 'cn.wattter.geo_action'
    description = 'GEO Action local AI and CLI bridge'
    path = $hostExecutable
    type = 'stdio'
    allowed_origins = @("chrome-extension://$ExtensionId/")
  } | ConvertTo-Json | Set-Content -Encoding UTF8 $manifestPath
  $registryPath = 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\cn.wattter.geo_action'
  New-Item -Force $registryPath | Out-Null
  Set-Item -Path $registryPath -Value $manifestPath

  $cliScript = Join-Path $installDirectory 'cli.mjs'
  $cliCommand = Join-Path $binaryDirectory 'geo-action.cmd'
  "@echo off`r`n`"$($node.Source)`" `"$cliScript`" %*`r`n" |
    Set-Content -Encoding ASCII $cliCommand

  $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $pathItems = @($currentPath -split ';' | Where-Object { $_ })
  if ($pathItems -notcontains $binaryDirectory) {
    [Environment]::SetEnvironmentVariable(
      'Path',
      (($pathItems + $binaryDirectory) -join ';'),
      'User'
    )
  }

  foreach ($skillRoot in @(
    (Join-Path $HOME '.codex\skills'),
    (Join-Path $HOME '.claude\skills')
  )) {
    New-Item -ItemType Directory -Force -Path $skillRoot | Out-Null
    $skillTarget = Join-Path $skillRoot 'geo-action'
    if (Test-Path $skillTarget) { Remove-Item -Recurse -Force $skillTarget }
    Copy-Item -Recurse -Force $skillSource $skillTarget
  }

  Write-Host 'GEO Action CLI 0.3.1 安装完成。'
  Write-Host '下一步：'
  Write-Host '1. 保持 Chrome 与 GEO Action 启用，在插件“CLI 与本地 AI”页点击“重新连接 CLI”。'
  Write-Host '2. 重新打开终端和 AI 工具会话；无需手动启动 daemon。'
  Write-Host '3. Codex 输入：$geo-action 请把 C:\绝对路径\article.md 准备为微信公众号和知乎草稿'
  Write-Host '4. Claude Code 输入：/geo-action 请把 C:\绝对路径\article.md 准备为微信公众号和知乎草稿'
  Write-Host '5. 直接使用 CLI 时先运行：geo-action doctor'
} finally {
  Remove-Item -Recurse -Force $temporaryDirectory -ErrorAction SilentlyContinue
}
