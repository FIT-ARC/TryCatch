<#
.SYNOPSIS
  Generates a self-signed code-signing certificate for TryCatch MSIX releases.
.DESCRIPTION
  Run ONCE on your Windows machine. Creates trycatch-signing.pfx (keep SECRET,
  upload base64 to GitHub secret MSIX_PFX_BASE64) and trycatch-signing.cer
  (PUBLIC - commit or attach to releases so users can install it).
  Subject MUST stay CN=ARC@FIT to match pubspec msix_config publisher.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool/packaging/New-SelfSignedMsixCert.ps1
  # then: [Convert]::ToBase64String([IO.File]::ReadAllBytes("trycatch-signing.pfx")) | Set-Content b64.txt
  # Add b64.txt content as secret MSIX_PFX_BASE64, password as MSIX_PASSWORD.
#>
$ErrorActionPreference = 'Stop'
$Subject = 'CN=ARC@FIT'
$Cert = New-SelfSignedCertificate -Type Custom `
  -Subject $Subject `
  -KeyUsage DigitalSignature `
  -FriendlyName 'TryCatch MSIX self-signed' `
  -CertStoreLocation 'Cert:\CurrentUser\My' `
  -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$Password = Read-Host -Prompt 'Enter a password for the .pfx (will be MSIX_PASSWORD secret)' -AsSecureString
$PfxPath = Join-Path (Get-Location) 'trycatch-signing.pfx'
$CerPath = Join-Path (Get-Location) 'trycatch-signing.cer'
Export-PfxCertificate -Cert $Cert -FilePath $PfxPath -Password $Password | Out-Null
Export-Certificate -Cert $Cert -FilePath $CerPath | Out-Null
Write-Output "Thumbprint: $($Cert.Thumbprint)"
Write-Output "Wrote: $PfxPath (SECRET - do not commit)"
Write-Output "Wrote: $CerPath (PUBLIC - share with users)"
Write-Output 'Next: base64 the .pfx into GitHub secrets MSIX_PFX_BASE64 / MSIX_PASSWORD.'
