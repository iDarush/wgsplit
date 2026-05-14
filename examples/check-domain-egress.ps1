param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Domain,

  [string]$DnsServer = "10.40.0.1",
  [string]$SshTarget = "user@234.234.234.234",
  [string]$RemoteScript = "/opt/splitvpn/scripts/check-domain-egress.sh"
)

$cleanDomain = $Domain -replace '^https?://', ''
$cleanDomain = ($cleanDomain -split '/')[0].TrimEnd('.')

Write-Host "Domain: $cleanDomain"
Write-Host "DNS server: $DnsServer"
Write-Host ""

Write-Host "Client DNS lookup:"
try {
  Resolve-DnsName -Name $cleanDomain -Server $DnsServer -Type A -ErrorAction Stop |
    Where-Object { $_.IPAddress } |
    Select-Object -ExpandProperty IPAddress |
    Sort-Object -Unique |
    ForEach-Object { Write-Host "  $_" }
} catch {
  Write-Host "  lookup failed: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Server routing decision:"
ssh $SshTarget "sudo $RemoteScript '$cleanDomain'"

