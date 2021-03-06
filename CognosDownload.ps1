Param(
[parameter(Position=0,Mandatory=$true,HelpMessage="Give the name of the report you want to download.")][string]$report,
[parameter(Position=1,Mandatory=$false,HelpMessage="Give a specific folder to download the report into.")]
[string]$savepath="C:\ImportFiles\", #--- VARIABLE --- change to a path you want to save files
[parameter(Position=2,Mandatory=$false,HelpMessage="Extension to save onto the report name.")][ValidateSet("csv","xlsx")]
[string]$extension="csv", #--- VARIABLE --- file extension to save data in csv or xlsx
[parameter(Mandatory=$false,HelpMessage="eSchool SSO username to use.")]
[string]$username="0000name", #--- VARIABLE --- SSO username
[parameter(Mandatory=$false,HelpMessage="eSchool DSN location.")]
[string]$espdsn="schoolsms", #--- VARIABLE --- eSchool DSN for your district
[parameter(Mandatory=$false,HelpMessage="eFinance username to use.")]
[string]$efpuser="yourefinanceusername", #--- VARIABLE --- eFinance username
[parameter(Mandatory=$false,HelpMessage="eFinance DSN location.")]
[string]$efpdsn="schoolfms", #--- VARIABLE --- eFinance DSN for your district
[parameter(Mandatory=$false,HelpMessage="Use switch for Report Studio created report. Otherwise it will be a Query Studio report")][switch]$ReportStudio,
[parameter(Mandatory=$false,HelpMessage="Get the report from eFinance.")][switch]$eFinance,
[parameter(Mandatory=$false,HelpMessage="Run a live version instead of just getting a saved version.")][switch]$RunReport
[parameter(Mandatory=$false,HelpMessage="The email address to send the notification to.")]$Email
)
#Email Settings for password reminder
$From = 'Your.Email@Here'
$To = $Email
$Subject = 'APSCN Password needs to be updated'
$Body = 'Your APSCN password has changed since the last time this script has run. Please update the password on file so we can download $report successfully. 

Thanks'
$SMTPServer = 'aspmx.l.google.com'
$SMTPPort = '25'
# The above parameters can be called directly from powershell switches
# In Cognos, do the following:
# 1. Setup a report with specific name (best without spaces like MyReportName) to run scheduled to save with which format you want then schedule this script to download it.
# 2. You will need to determine the DSN (database name) for your district
#    To obtain this you need to log in to the eSchool Cognos site using and view the source code of the overall frameset.
#    The dsn is displayed in the second <frame> tag like so where the ****** is: src="https://adecognos.arkansas.gov/ibmcognos/cgi-bin/cognos.cgi?dsn=******
# On computer to download data:
# 1. After adjusting relevant variables for your district and user account
# 2. Create folder to store password data for script (default of C:\scripts)
# 3. Run from command line or batch script: powershell.exe -executionpolicy bypass -file C:\ImportFiles\Scripts\CognosDownload.ps1 MyReportName
#    Scripts can also use command switches from powershell: CognosDownload.ps1 -report MyReportName -savepath C:\Scripts -extension csv -username 0000username -espdsn schoolsms
# In case report was not built with Query Studio, use -ReportStudio
# For eFinance:
# Use "-username 0000name -efpuser yourefinanceusername -efpdsn schoolfms -eFinance" to run report from eFinance (SSO username is required along with eFinance username)

# Location to export the secured password file. When the password expires, just delete the specific file and run the script to re-create
$passwordfile = "C:\scripts\apscnpw.txt"
$userdomain = "APSCN"
#******************* end of variables to change ********************
#exit codes list
#1 = Specified path does not exist from parameter
#2 = Invalid uiAction option specified
#3 = sURL not found. The script tried to click the report link, but did not get the expected result of already saved report
#4 = Got HTTP reponse of something other than 200 (OK), likely received a 401 (Unauthorized)
#9 = General unspecified trap for error
#10 = CAM_PASSPORT_ERROR detected, check your password
#11 = AAA-AUT-0011 detected, namespace problem in report
#12 = Failed to verify CSV format, reverted file if available
#13 = CSV file didn't download to expected path
#20 = Unable to query for data source, check the DSN
#29 = Error during login found in returned data, probably with DSN or path requested

# Revisions:
# 2014-07-23: Brian Johnson: Updated URL string to include dsn parameters necessary for eSchool and re-enabled CredentialCache setting to login
# 2016-04-06: Added new username parameter efpuser for eFinance to work
# 2017-01-16: Brian Johnson: Updated URL from cognosisapi.dll to cognos.cgi. Also included previous changes that were not uploaded from before.
# 2017-02-07: Added CSV verify and revert
# 2017-02-27: Added variable for reporttype
# 2017-07-12: VBSDbjohnson: Merged past changes with CWeber42 version
# 2017-07-13: VBSDbjohnson: Changed to use Powershell parameters instead of args. Script should also be able to run without modifying file


# Cognos ui action to perform 'run' or 'view'
# run not fully implemented
If ($RunReport) {$uiAction = "run"} Else {$uiAction = "view"}

# server location for Cognos
$baseURL = "https://adecognos.arkansas.gov"
$cWebDir = "ibmcognos"

If ($eFinance) {
    $camName = "efp"    #efp for eFinance
    $dsnname = $efpdsn
}
Else {
    $camName = "esp"    #esp for eSchool
    $dsnname = $espdsn
}
If ($ReportStudio) {$reporttype = "report"} Else {$reporttype = "query"}    #report for Report Studio, query for Query Studio

#Script to create a password file for Cognos download Directory
#This script MUST BE RAN LOCALLY to work properly! Run it on the same machine doing the cognos downloads, this does not work remotely!

If ((Test-Path ($passwordfile))) {
    $password = Get-Content $passwordfile | ConvertTo-SecureString
}
Else {
    write-host("Password file does not exist! [$passwordfile]. Please enter a password to be saved on this computer for scripts") -ForeGroundColor Yellow
    Read-Host "Enter Password" -AsSecureString |  ConvertFrom-SecureString | Out-File $passwordfile
    $password = Get-Content $passwordfile | ConvertTo-SecureString
}

$fullfilepath = "$savepath\$report.$extension"

If (!(Test-Path ($savepath))) {
    write-host("Specified save folder does not exist! [$fullfilepath]") -ForeGroundColor Yellow
    exit 1 #specified save folder does not exist
}

#get current datetime for if-modified-since header for file
$filetimestamp = Get-Date

[System.Net.CredentialCache]$MyCredentialCache
[System.Net.HttpWebRequest]$request
[System.Net.HttpWebResponse]$response
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

if ($uiAction -match "run") #run the report live for the data
{
    $url = "$baseURL/$cWebDir/cgi-bin/cognos.cgi?dsn=$dsnname&CAM_action=logonAs&CAMNamespace=$camName&CAMUsername=$username&CAMPassword=$password&b_action=cognosViewer&ui.action=$uiAction&ui.object=CAMID(%22$camName%3aa%3a$username%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2f$reporttype%5b%40name%3d%27$report%27%5d&ui.name=$report&run.outputFormat=CSV&run.prompt=false"
    #old 2017-01-16 $url = "$baseURL/$cWebDir/cgi-bin/cognosisapi.dll?CAM_action=logonAs&CAMNamespace=$camName&CAMUsername=$username&CAMPassword=$password&b_action=cognosViewer&ui.action=$uiAction&ui.object=CAMID(%22$camName%3au%3a$userid%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2fquery%5b%40name%3d%27$report%27%5d&ui.name=$report&ui.format=CSV"
    #       -----------------/cgi-bin/cognosisapi.dll?CAM_action=logonAs&CAMNamespace=********&CAMUsername=*********&CAMPassword=*********&b_action=cognosViewer&ui.action=*********&ui.object=CAMID(%22********%3au%3a*******%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2fquery%5b%40name%3d%27*******%27%5d&ui.name=*******&ui.format=CSV
}
elseif ($uiAction -match "view") #view a saved version of the report data
{
    $url = "$baseURL/$cWebDir/cgi-bin/cognos.cgi?dsn=$dsnname&CAM_action=logonAs&CAMNamespace=$camName&CAMUsername=$username&CAMPassword=$password&b_action=cognosViewer&ui.action=$uiAction&ui.object=defaultOutput(CAMID(%22$camName%3aa%3a$username%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2f$reporttype%5b%40name%3d%27$report%27%5d)&ui.name=$report&ui.format=CSV"
    #old 2017-01-16 $url = "$baseURL/$cWebDir/cgi-bin/cognosisapi.dll?dsn=$dsnname&CAM_action=logonAs&CAMNamespace=$camName&CAMUsername=$username&CAMPassword=$password&b_action=cognosViewer&ui.action=$uiAction&ui.object=defaultOutput(CAMID(%22$camName%3aa%3a$username%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2fquery%5b%40name%3d%27$report%27%5d)&ui.name=$report&ui.format=CSV"

    #eFinance version when enabled
    If ($eFinance) {
        $url = "$baseURL/$cWebDir/cgi-bin/cognos.cgi?spi_db_name=$dsnname&CAM_action=logonAs&CAMNamespace=$camName&CAMUsername=$username&CAMPassword=$password&b_action=cognosViewer&ui.action=$uiAction&ui.object=defaultOutput(CAMID(%22$camName%3aa%3a$efpuser%22)%2ffolder%5b%40name%3d%27My%20Folders%27%5d%2fquery%5b%40name%3d%27$report%27%5d)&ui.name=$report"
    }
}
else
{
    throw "Invalid uiAction option: use only 'view' or 'run'"
    exit 2 #option not implemented
}

trap
{
    write-output $_
    exit 9 #general trap for errors
}

if(!(Split-Path -parent $savepath) -or !(Test-Path -pathType Container (Split-Path -parent $savepath))) {
  $savepath = Join-Path $pwd (Split-Path -leaf $savepath)
}

$FileExists = Test-Path $fullfilepath
If ($FileExists -eq $True) {
    #replace datetime for if-modified-since header from existing file
    $filetimestamp = (Get-Item $fullfilepath).LastWriteTime
}


$request = [System.Net.HttpWebRequest]::Create($url)

#Set the Credentials
write-host("Setting the Credentials now..") -ForeGroundColor Yellow
$request.UseDefaultCredentials = $true
$request.PreAuthenticate = $true
[System.Net.NetworkCredential]$NetworkCredential = New-Object System.Net.NetworkCredential($username, $password, $userdomain)
$MyCredentialCache = New-Object System.Net.CredentialCache
$MyCredentialCache.Add($url, "Basic", $NetworkCredential)
$request.Credentials = $NetworkCredential

$cookieJar = new-object "System.Net.CookieContainer"
$request.Method = "GET"
$request.CookieContainer = $cookieJar

$response = $request.GetResponse()
if ($response.StatusCode -ne 200)
{
    $result = "Error : " + $response.StatusCode + " : " + $response.StatusDescription
    $result
    exit 4 #was not a HTTP response of 200 (OK)
}
else
{
    $sr = New-Object System.IO.StreamReader($response.GetResponseStream())
    $HTMLDataString = $sr.ReadToEnd()

    write-host("Downloaded HTML to retrieve report url.") -ForeGroundColor Yellow

    $regex = [regex]"var sURL = '(.*?)'"
    if ($HTMLDataString -notmatch $regex)
    {
        if ($HTMLDataString -match [regex]"CAM_PASSPORT_ERROR") #this error is in the output of HTMLDataString
        {
            if ($Email){Send-MailMessage -From $From -to $To -Subject $Subject -Body $Body -SmtpServer $SMTPServer -port $SMTPPort}
            write-output "Found 'CAM_PASSPORT_ERROR': Please check the password used for script"
            exit 10 #login error
        }
        elseif ($HTMLDataString -match [regex]"AAA-AUT-0011") #this error is in the output of HTMLDataString for Invalid Namespace
        {
            write-host($HTMLDataString) -ForeGroundColor Gray
            write-output "Found 'AAA-AUT-0011': Invalid Namespace error"
            exit 11 #Invalid namespace error
        }
        elseif ($HTMLDataString -match [regex]"Unable to query for data source")
        {
            write-host($HTMLDataString) -ForeGroundColor Gray
            write-output "Found 'Unable to query for data source' in returned HTMLDataString: Check your DSN"
            exit 20 #Unable to query for data source
        }
        elseif ($HTMLDataString -match [regex]"Error during login")
        {
            write-host($HTMLDataString) -ForeGroundColor Gray
            write-output "Found 'Error during login' in returned HTMLDataString: Check your DSN paths"
            exit 29 #Error during login found in returned data
        }
        write-host($HTMLDataString) -ForeGroundColor Gray
        throw "'var sURL' not found"

        exit 3 #'var sURL' not found
    }
    $urlMatch = $regex.Matches($HTMLDataString)
    write-host("Found URL in data to download report.") -ForeGroundColor Yellow
    $fileURLString = $urlMatch[0].Value.Replace("var sURL = '", "").Replace("'", "")

    if ($uiAction -match "run") #run the report live for the data
    {
        # temp to show data from the HTMLDataString for the sURL
        write-host($HTMLDataString) -ForeGroundColor White
    }

    # Append beginning part of url
    $fileURLString = "$baseURL$fileURLString"

    [System.Net.HttpWebRequest] $fileRequest = [System.Net.HttpWebRequest] [System.Net.WebRequest]::Create($fileURLString)
    $fileRequest.CookieContainer = $request.CookieContainer
    $fileRequest.AllowWriteStreamBuffering = $false
    $fileRequest.Credentials = $NetworkCredential
    $fileRequest.IfModifiedSince = $filetimestamp
    $fileResponse = [System.Net.HttpWebResponse] $fileRequest.GetResponse()

    $PrevFileExists = Test-Path $fullfilepath
    If ($PrevFileExists -eq $True) {
        $PrevOldFileExists = Test-Path ($fullfilepath + ".old")
        If ($PrevOldFileExists -eq $True) {
            write-host("Deleting old $report...") -ForeGroundColor Yellow
            Remove-Item -Path ($fullfilepath + ".old")
        }
        write-host("Renaming old $report...") -ForeGroundColor Yellow
        Rename-Item -Path $fullfilepath -newname ($fullfilepath + ".old")
    }

    write-host("Downloading $report...") -ForeGroundColor Yellow
    [System.IO.Stream]$st = $fileResponse.GetResponseStream()
    # write to disk
    $mode = [System.IO.FileMode]::Create
    $fs = New-Object System.IO.FileStream $fullfilepath, $mode
    $read = New-Object byte[] 256
    [int] $count = $st.Read($read, 0, $read.Length)
    [int] $tcount = 0
    while ($count -gt 0)
    {
        $fs.Write($read, 0, $count)
        $count = $st.Read($read, 0, $read.Length)
        $tcount += $count
        Write-Host $tcount -NoNewline "`r"
    }
    $fs.Close()
    $st.Close()
    $fileResponse.Close()
    write-host("File [$fullfilepath] downloaded [$tcount] bytes") -ForeGroundColor Yellow
}
$response.Close()

# check file for proper format if csv
if ($extension -eq "csv")
{
    $FileExists = Test-Path $fullfilepath
    If ($FileExists -eq $False) {
        Write-Host("Does not exist:" + $fullfilepath)
        exit 13 #CSV file didn't download to expected path
    }
    #line counts to keep track of lines
    $lcount = 0
    $badlcount = 0

    for(;;) {
        $reader = [System.IO.File]::OpenText($fullfilepath)
        $l = $reader.ReadLine()
        if ($l -eq $null) { break }
        if ($l -match '^\w,*')
        {
            $lcount++
        }
        else
        {
            $badlcount++
        }
        #exit based on whether number of lines passed
        if($lcount -eq 5)
        {
            write-host("Passed CSV $lcount lines...") -ForeGroundColor Yellow
            $reader.Close()
            break
        }
        if($badlcount -gt 0)
        {
            #bad file revert file
            $PrevOldFileExists = Test-Path ($fullfilepath + ".old")
            If ($PrevOldFileExists -eq $True) {
                write-host("Deleting old $report...") -ForeGroundColor Yellow
                Rename-Item -Path $fullfilepath -newname ($fullfilepath)
            }
            write-host("Failed CSV verify. Reversing old $report...") -ForeGroundColor Red
            $reader.Close()
            exit 12 #reverted file format
        }
        $reader.Close()
    }
}
