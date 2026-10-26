<#
.SYNOPSIS
    Bulk-onboards new employees into Active Directory from a CSV file.

.DESCRIPTION
    For each row in the CSV, the script:
      1. Builds a username in the format firstname.lastname
      2. Creates the user in the matching department OU (OU=<Dept>,OU=Employees,OU=ABLab)
      3. Sets job title and department attributes
      4. Assigns a temporary password and forces a change at first logon
      5. Adds the user to the department security group (SG-<Dept>)
    Users that already exist are skipped, so the script is safe to re-run.

.PARAMETER CsvPath
    Path to the CSV. Required columns: FirstName, LastName, Department, Title

.EXAMPLE
    .\Onboard-NewHires.ps1 -CsvPath C:\LabScripts\new_hires.csv

.NOTES
    Lab: Active Directory Employee Onboarding and Help Desk Lab (Azure)
    Domain: ablab.internal
    Run on DC01 in an elevated PowerShell session.
#>
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$DomainDN  = 'DC=ablab,DC=internal',
    [string]$UpnSuffix = 'ablab.internal'
)

Import-Module ActiveDirectory

$base = "OU=ABLab,$DomainDN"

# Prompt for the temporary password so it is never stored in the script
$tempPassword = Read-Host -Prompt 'Temporary password for new users' -AsSecureString

$results = foreach ($hire in Import-Csv -Path $CsvPath) {
    $first = $hire.FirstName.Trim()
    $last  = $hire.LastName.Trim()
    $dept  = $hire.Department.Trim()
    $sam   = "$first.$last".ToLower()
    $ou    = "OU=$dept,OU=Employees,$base"

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        [pscustomobject]@{ User = $sam; Department = $dept; Status = 'Skipped - already exists' }
        continue
    }

    $created = $false
    try {
        # Create the account disabled first, then set the password.
        # If the password is rejected by domain policy, New-ADUser would otherwise
        # leave a half-built, disabled account behind - so we roll it back below.
        New-ADUser -Name "$first $last" `
                   -GivenName $first -Surname $last `
                   -DisplayName "$first $last" `
                   -SamAccountName $sam `
                   -UserPrincipalName "$sam@$UpnSuffix" `
                   -Title $hire.Title -Department $dept `
                   -Path $ou `
                   -Enabled $false `
                   -ErrorAction Stop
        $created = $true

        Set-ADAccountPassword -Identity $sam -Reset -NewPassword $tempPassword -ErrorAction Stop
        Set-ADUser -Identity $sam -ChangePasswordAtLogon $true
        Enable-ADAccount -Identity $sam
        Add-ADGroupMember -Identity "SG-$dept" -Members $sam

        [pscustomobject]@{ User = $sam; Department = $dept; Status = 'Created' }
    }
    catch {
        if ($created) { Remove-ADUser -Identity $sam -Confirm:$false }   # roll back the partial account
        [pscustomobject]@{ User = $sam; Department = $dept; Status = "Failed - $($_.Exception.Message)" }
    }
}

$results | Format-Table -AutoSize
$results | Export-Csv -Path (Join-Path (Split-Path $CsvPath) 'onboarding_log.csv') -NoTypeInformation
