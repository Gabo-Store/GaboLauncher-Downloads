$ErrorActionPreference='Stop'
if(-not $env:GITHUB_ACTIONS -or -not $env:RUNNER_TEMP){throw 'Este test solo se ejecuta en una VM desechable de GitHub Actions.'}
$testRoot=Join-Path $env:RUNNER_TEMP ('gabo-setup-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$install=Join-Path $testRoot 'installed'
$results=[ordered]@{version='0.9.5';os=[System.Environment]::OSVersion.VersionString;cleanInstall=$false;integrity=$false;loginWindow=$false;uninstall=$false;upgradeFrom='0.9.4';upgrade=$false;licensePreserved=$false;catalogPreserved=$false;gameFilePreserved=$false}
function Download-Setup([string]$version,[string]$hash){
 $file=Join-Path $testRoot ('setup-'+$version+'.exe')
 Invoke-WebRequest ('https://gabo-licencias.gabostorecodex.workers.dev/releases/GaboLauncher-Setup-'+$version+'-x64.exe') -OutFile $file
 if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash){throw "SHA256 incorrecto: $version"}
 return $file
}
function Install-Setup([string]$file,[string]$phase){
 $log=Join-Path $testRoot ($phase+'.log')
 $process=Start-Process -FilePath $file -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/TASKS=',('/DIR="'+$install+'"'),('/LOG="'+$log+'"')) -Wait -PassThru
 if($process.ExitCode -ne 0){Get-Content -LiteralPath $log -Tail 40;throw "Setup $phase terminó con $($process.ExitCode)"}
 if(-not(Test-Path -LiteralPath (Join-Path $install 'GaboLauncher.exe'))){throw 'El setup no instaló el host.'}
}
function Check-Integrity {
 $lib=Join-Path $install 'GaboLauncher.Seguridad.dll'
 $probe=Join-Path $testRoot 'IntegrityProbe.exe'
 $source=Join-Path $testRoot 'IntegrityProbe.cs'
 [IO.File]::WriteAllText($source,'using System; class Probe { static int Main(string[] args) { var error=GaboProtection.Integrity.Check(args[0]); Console.WriteLine(error ?? "INSTALLED_INTEGRITY_OK"); return error==null?0:3; } }')
 $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 & $compiler /nologo /target:exe "/out:$probe" "/r:$lib" $source
 if($LASTEXITCODE -ne 0){throw 'No se pudo compilar el comprobador .NET Framework.'}
 Copy-Item -LiteralPath $lib -Destination (Join-Path $testRoot 'GaboLauncher.Seguridad.dll') -Force
 & $probe $install
 if($LASTEXITCODE -ne 0){throw 'Integridad instalada incorrecta.'}
}
function Check-LoginWindow {
 $app=Start-Process -FilePath (Join-Path $install 'GaboLauncher.exe') -WorkingDirectory $install -PassThru
 try{
  $deadline=[DateTime]::UtcNow.AddSeconds(40)
  do{
   Start-Sleep -Milliseconds 500
   $app.Refresh()
   if($app.HasExited){throw "El launcher se cerró antes del login: $($app.ExitCode)"}
   if([DateTime]::UtcNow -gt $deadline){throw 'No apareció una ventana de licencia en la VM.'}
  }until($app.MainWindowHandle -ne 0)
  if($app.MainWindowTitle -notlike '*GaboLauncher*licencia*'){throw ('Ventana inesperada: '+$app.MainWindowTitle)}
  Write-Output ('LOGIN_WINDOW_OK: '+$app.MainWindowTitle)
 }finally{
  if(-not $app.HasExited){$null=$app.CloseMainWindow();if(-not $app.WaitForExit(10000)){$app.Kill();$app.WaitForExit()}}
 }
}
function Uninstall-Setup {
 $uninstaller=Join-Path $install 'unins000.exe'
 $p=Start-Process -FilePath $uninstaller -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -Wait -PassThru
 if($p.ExitCode -ne 0){throw "Desinstalador: $($p.ExitCode)"}
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while((Test-Path -LiteralPath (Join-Path $install 'GaboLauncher.exe')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 300}
 if(Test-Path -LiteralPath (Join-Path $install 'GaboLauncher.exe')){throw 'La desinstalación no retiró el host.'}
}
try{
 $new=Download-Setup '0.9.5' 'e9cc7fe9a60bfe0bf444079bd9d9861cccf38dbf48ccc48fe425a9075b2948ec'
 Install-Setup $new 'clean'
 $results.cleanInstall=$true
 Check-Integrity
 $results.integrity=$true
 Check-LoginWindow
 $results.loginWindow=$true
 Uninstall-Setup
 $results.uninstall=$true
 $old=Download-Setup '0.9.4' 'b1555e3a06233592fd341132a5d6e80ac2aa7bf63633bb90012617891afe7329'
 Install-Setup $old 'old'
 $licenseDir=Join-Path $env:LOCALAPPDATA 'GaboLauncherLicencias'
 New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
 $license=Join-Path $licenseDir 'licencia-propia.dat'
 $encrypted=[Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('CI-PRESERVE-ONLY-NOT-A-LICENSE'),$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
 [IO.File]::WriteAllBytes($license,$encrypted)
 $licenseHash=(Get-FileHash -LiteralPath $license).Hash
 $catalog=Join-Path $env:APPDATA 'com.uploadhaven.launcher\catalog_sync.json'
 $catalogHash=(Get-FileHash -LiteralPath $catalog).Hash
 $gameDir=Join-Path $testRoot 'game-files'
 New-Item -ItemType Directory -Path $gameDir | Out-Null
 $sentinel=Join-Path $gameDir 'preserve-test.txt'
 [IO.File]::WriteAllText($sentinel,'This is a harmless test file, not a game.')
 $gameHash=(Get-FileHash -LiteralPath $sentinel).Hash
 Install-Setup $new 'upgrade'
 Check-Integrity
 Check-LoginWindow
 $results.upgrade=$true
 $results.licensePreserved=(Get-FileHash -LiteralPath $license).Hash -eq $licenseHash
 $results.catalogPreserved=(Get-FileHash -LiteralPath $catalog).Hash -eq $catalogHash
 $results.gameFilePreserved=(Get-FileHash -LiteralPath $sentinel).Hash -eq $gameHash
 if(-not($results.licensePreserved -and $results.catalogPreserved -and $results.gameFilePreserved)){throw 'La actualización alteró un archivo de la prueba de conservación.'}
 Uninstall-Setup
 Write-Output 'WINDOWS_SETUP_VERIFIED'
}finally{
 $json=$results | ConvertTo-Json
 Write-Output $json
 if($env:GITHUB_STEP_SUMMARY){@('# Verificación de GaboLauncher Windows','', 'VM desechable Windows Server 2025 de GitHub. No equivale a probar todos los equipos o juegos.','', '```json',$json,'```','', 'El test no usa licencias reales ni credenciales del administrador. La conservación de juegos se comprueba con un archivo inocuo, no ejecutando un juego.') | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append}
}
