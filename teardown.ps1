param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroupName,
  [switch]$AutoApprove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AutoApprove) {
  az group delete --name $ResourceGroupName --yes --no-wait
} else {
  az group delete --name $ResourceGroupName
}
