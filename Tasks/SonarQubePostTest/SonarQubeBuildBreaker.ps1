. ./SonarQubeHelper.ps1

$DefaultNumRetriesForAnalysisToComplete = 120; # there 1s delay between each retry plus the time it takes to make a web call

#
# Top-level orchestrating logic
# 
function BreakBuildOnQualityGateFailure
{
    
    $breakBuild = GetTaskContextVariable "MsBuild.SonarQube.BreakBuild"            
    $breakBuildEnabled = Convert-String $breakBuild Boolean    

    if ($breakBuildEnabled)
    {
        if (IsPrBuild)
        {
            Write-Warning "Ignoring the setting of breaking the build on quality gate failure because the build was triggered by a pull request."
            return;
        }
       
        $analysisId = WaitForAnalysisToFinish
        $qualityGateStatus = QueryQualityGateStatus $analysisId
        FailBuildOnQualityGateStatus $qualityGateStatus

    }
    else
    {
        Write-Host "The build was not set to fail if the associated quality gate fails."
    }
}

#
# Reads the task id from task-report.txt that is dropped by the sonar-scanner to give the task id
#
function FetchTaskIdFromReportFile
{
    param ([string]$reportTaskFile)

    $content = [System.IO.File]::ReadAllText($reportTaskFile);
    $matchResult = [System.Text.RegularExpressions.Regex]::Match($content, "ceTaskId=(.+)");    

    if (!$matchResult.Success -or !$matchResult.Groups -or $matchResult.Groups.Count -ne 2)
    {
        throw "Could not find the task Id in $reportTaskFile. If you are using SonarQube 5.3 or above, please raise a bug."
    }

    $taskId = $matchResult.Groups[1].Value
    Write-Verbose "The analysis is associated with the task id $taskId"

    return $taskId
}

#
# Queries the server to determine if the task has finished, i.e. if the quality gate has been evaluated
#
function QueryAnalysisFinished
{
    param ([string]$taskId)
    
    # response is in json and ps deserialize it automatically
    $response = InvokeGetRestMethod "/api/ce/task?id=$taskId" $true    
    $status = $response.task.status
    
    Write-Verbose "The task status is $status"

    if (!$status)
    {
        throw "Could not determine the task status - please raise a bug."
    }
    
    return $status -eq "success"   
}

#
# Query the server to determine the analysis id associated with the current analysis
#
function QueryAnalysisId
{
    param ([string]$taskId)
       
    $response = InvokeGetRestMethod "/api/ce/task?id=$taskId" $true    
    return $response.task.analysisId      
}

#
# Returns the path to the report-task.txt file containing task details
#
function GetTaskStatusFile
{    
    $sonarDir = GetSonarScannerDirectory 
    $reportTaskFile = [System.IO.Path]::Combine($sonarDir, "report-task.txt");
    
    if (![System.IO.File]::Exists($reportTaskFile))
    {
        Write-Verbose "Could not find the task details file at $reportTaskFile"
        throw "Cannot determine if the analysis has finished in order to break the build. Possible causes: your SonarQube server version is lower than 5.3 - for more details on how to break the build in this case see http://go.microsoft.com/fwlink/?LinkId=722407"
    }

    return $reportTaskFile
}

#
# Pools the server until current analysis is complete or a timeout is hit. Returns the analysis id.
#
function WaitForAnalysisToFinish
{    
    Write-Host "Waiting on the SonarQube server to finish processing in order to determine the quality gate status."
       
    $reportPath = GetTaskStatusFile    
    $taskId = FetchTaskIdFromReportFile $reportPath
        
    $command = { QueryAnalysisFinished $taskId }

    $numRetries = GetNumberOfPollingRetries
    $taskFinished = RetryUntilTrue $command -maxRetries $numRetries -retryDelay 1 

    if (!$taskFinished)
    {
        throw "The analysis did not complete after checking the task status $numRetries times."

    }

    $analysisId = QueryAnalysisId $taskId

    Write-Host "The SonarQube analysis has finished processing."
    Write-Verbose "The analysis id is $analysisId"

    return $analysisId
}

function GetNumberOfPollingRetries
{
    if ($env:SonarQubeAnalysisCompletionRetries)
    {
        $numRetries = $env:SonarQubeAnalysisCompletionRetries
        Write-Host "SonarQubeAnalysisCompletionRetries is set to $numRetries and will be used to poll for the SonarQube task completion."
        
    }
    else
    {
        $numRetries = $DefaultNumRetriesForAnalysisToComplete 
    }

    return $numRetries;
}

#
# Queries the server to get the result of the quality gate.
#
function QueryQualityGateStatus
{
    param ([string]$analysisId)

    $response = InvokeGetRestMethod "/api/qualitygates/project_status?analysisId=$analysisId" $true    
    return $response.projectStatus.status;
}

#
# Fails the build when the quality gate is set to Error. Possible quality gate results: OK, WARN, ERROR, NONE
#
function FailBuildOnQualityGateStatus
{
    param ([string]$qualityGateStatus)

    if ($qualityGateStatus -eq "error")
    {        
        $dashboardUrl = GetTaskContextVariable "MsBuild.SonarQube.ProjectUri"
        Write-Error "The SonarQube quality gate associated with this build has failed. For more details see $dashboardUrl"
        Write-host "##vso[task.complete result=Failed;]"
    }
    else
    {
        Write-Host "The SonarQube quality gate associated with this build has passed (status $qualityGateStatus)"
    }
}
