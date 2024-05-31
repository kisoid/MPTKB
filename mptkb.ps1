cls

Add-Type -AssemblyName System.Windows.Forms

function Calc-CheckSum($oid)
{
    $str = $script:note_content[$oid] -join ''
    $stringAsStream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.StreamWriter]::new($stringAsStream)
    $writer.write($str)
    $writer.Flush()
    $stringAsStream.Position = 0
    return (Get-FileHash -InputStream $stringAsStream -Algorithm SHA256).Hash.ToString()
}

$workfile = "$PSScriptRoot\KB.txt"

#профилирование
$startup_t1 = get-date

$curr_oid = 0
$last_oid = 0

$note_content = @{}
$note_hash = @{}
$note_title = @{}
$title2oid = @{}
$note_timestamp = @{}
$note_review = @{}

#отключалка события переписывания RTB в момент перехода между заметками
$ignore_RTB_changes = $false
$changed_notes = New-Object System.Collections.Generic.List[System.Object]

#начало загрузки файла и парсинга
$x = Get-Content -LiteralPath $workfile -Encoding UTF8

$note_body = $false

#Length или Count? как правильнее?
for($i = 0; $i -lt $x.Length; $i++)
{
    if($x[$i] -eq '----- begin note')
    {
        $note_body = $true
        $last_oid++
        $note_content[$last_oid] = New-Object System.Collections.Generic.List[System.Object]
        $note_content[$last_oid].Add('----- begin note')
        $note_title[$last_oid] = 'Untitled ' + (Get-Random) #надо будет добавить в проверку консистентности
        $note_timestamp[$last_oid] = (Get-Date -Year 1984 -Month 7 -Day 5) #надо будет добавить в проверку консистентности
        $note_review[$last_oid] = 1000
        continue
    }

    if($x[$i] -eq '----- end note')
    {
        $note_body = $false
        $note_content[$last_oid].Add('----- end note')
        continue
    }

    if($x[$i] -like 'checksum:*')
    {
        $note_hash[$last_oid] = $x[$i].Split(':')[1]
        $test_hash = (Calc-CheckSum $last_oid)
        if($test_hash -ne $note_hash[$last_oid])
        {
            [System.Windows.Forms.MessageBox]::Show(("не совпадает хеш: $last_oid `n" + $note_title[$last_oid]), 'checksum error')
        }
        continue
    }

    if(-not $note_body)
    {
        continue
    }

    $note_content[$last_oid].Add($x[$i])

    if($x[$i] -like 'title:*')
    {
        $note_title[$last_oid] = $x[$i].Split(':')[1]
        $title2oid[$note_title[$last_oid]] = $last_oid
        continue
    }

    if($x[$i] -like 'timestamp:*')
    {
        $note_timestamp[$last_oid] = [datetime]::parseexact(($x[$i].Split(':')[1]), 'yyyy-MM-dd', $null)
        continue
    }

    if($x[$i] -like '#review:*')
    {
        $note_review[$last_oid] = [int]($x[$i].Split(':')[1])
        continue
    }
}

$startup_t2 = get-date
"Время загрузки (сек): " + ($startup_t2 - $startup_t1).TotalSeconds

###

#debug
#$note_content[$last_oid] | Out-GridView
#Write-Host $note_title[$last_oid]
#Write-Host $title2oid[$note_title[$last_oid]]
#Write-Host $note_timestamp[$last_oid]
#Write-Host $note_review[$last_oid]

Get-Content -LiteralPath "$PSScriptRoot\config.txt" | Where-Object {$_ -like '$*'} | Invoke-Expression

#конец загрузки файла и парсинга

#оставить?
$antibonus = @{}
$review_ts = @{}


function Add-Node ($RootNode,$NodeName)
{
    $newNode = new-object System.Windows.Forms.TreeNode
    $newNode.Name = $NodeName
    $newNode.Text = $NodeName
    $newNode.Tag = $NodeName
    $Null = $RootNode.Nodes.Add($newNode)
    return $newNode
}


function Get-NeighborLinks ($node)
{
    if(-not ($script:title2oid.Keys -contains $node))
    {
        return @()
    }
    
    $tmp_oid = $script:title2oid[$node]
    $links = ($script:note_content[$tmp_oid] | Where-Object {$_ -like '*linkto:*'} | ForEach-Object {$_.Split(':')[1]})
    $links2 = @()
    
    $word2links = ($script:note_content[$tmp_oid] | Where-Object {$_ -like '*word2links:*'} | ForEach-Object {$_.Split(':')[1]})
    
    foreach($word2link in $word2links)
    {
        $links2 += (Search-Word $word2link).Node
    }
    
    $links = @() + $links + ($links2 | Sort-Object | Get-Unique)

    return $links
}


function GoToPage ($goto_oid)
{
    $script:curr_oid = $goto_oid
    $form1.Text = 'MPTKB - ' + $script:note_title[$script:curr_oid]

    #текст RTB меняется при переходе на другую заметку; игнорим это, т.к. все данные сохранены (и без сохранения нельзя перейти на другую заметку)
    $script:ignore_RTB_changes = $true
    $richTextBox1.Lines = $script:note_content[$script:curr_oid]
    #$label1.Text = "" #пусть событие RTB само решает, что сюда писать

    $treeView1.Nodes.Clear()
    Add-Node $treeView1 $script:note_title[$script:curr_oid] | Out-Null
}


function Search-Word ($request)
{
    $result = New-Object System.Collections.Generic.List[System.Object]

    for($node=1; $node -le $script:last_oid; $node++)
    {
        $matchstrings = ($script:note_content[$node] | Where-Object {$_ -like "*$($request)*"})

        foreach($mstr in $matchstrings)
        {
            $result.Add([pscustomobject]@{
            'Node' = $script:note_title[$node]
            'Line' = $mstr
            })
        }
    }

    return $result
}


function Review-Next
{
    $results = New-Object System.Collections.Generic.List[System.Object]

    $nodes = Get-ChildItem -LiteralPath $script:workdirectory -Recurse '*.dcmp2'

    $tmp_richTextBox = New-Object System.Windows.Forms.RichTextBox

    foreach($node in $nodes)
    {
        $tmp_richTextBox.LoadFile($node.FullName)
        $matchstrings = ($tmp_richTextBox.Lines | Where-Object {$_ -like '#review:*'})

        $cand_ts = $node.LastWriteTime

        foreach($mstr in $matchstrings)
        {
            $tmp_arr = $mstr.Split(':')
            $tmp_arr = ($tmp_arr[1]).Split(' ')
            $cand_rev = [int]($tmp_arr[0])

            if(-not $script:review_ts.ContainsKey($node.BaseName))
            {
                $script:review_ts[$node.BaseName] = $cand_ts
            }

            if(((Get-Date) - $cand_ts).TotalDays -lt $cand_rev)
            {
                continue
            }

            if(((Get-Date) - $script:review_ts[$node.BaseName]).TotalMinutes -lt $script:antibonus[$node.BaseName]*10*$cand_rev)
            {
                continue
            }
            
            $results.Add([pscustomobject]@{
                'NodeName' = $node.BaseName
                'Prio' = $cand_rev
                'Updated' = $cand_ts
                'rev_ts' = $script:review_ts[$node.BaseName]
            })
        }
    }

    if($results.Count -eq 0)
    {
        Write-Host "Нет больше заметок на ревью"
        return
    }

    Write-Host "Конкуренция: $($results.Count)"

    ### $selected_link = ($results.GetEnumerator() | Sort-Object -Property Updated | Out-GridView -OutputMode Single).NodeName
    $selected_link = ($results.GetEnumerator() | Sort-Object -Property Prio | Select-Object -First 20 | Get-Random).NodeName
    
    $script:antibonus[$selected_link]++
    $script:review_ts[$selected_link] = (Get-Date)

    $target = "$($script:workdirectory)\$($selected_link).dcmp2"
    Write-Host "Go for review $target"
    GoToPage $target

    ## debug
    # $results.GetEnumerator() | Out-GridView
}


#Generated Form Function
function GenerateForm {
########################################################################
# Code Generated By: SAPIEN Technologies PrimalForms (Community Edition) v1.0.10.0
# Generated On: 24.11.2021 19:13
# Generated By: vlad
########################################################################

#region Import the Assemblies
[reflection.assembly]::loadwithpartialname("System.Drawing") | Out-Null
[reflection.assembly]::loadwithpartialname("System.Windows.Forms") | Out-Null
#endregion

#region Generated Form Objects
$form1 = New-Object System.Windows.Forms.Form
$treeView1 = New-Object System.Windows.Forms.TreeView
$ReviewButton = New-Object System.Windows.Forms.Button
$RecentButton = New-Object System.Windows.Forms.Button
$ConsistencyCheckerButton = New-Object System.Windows.Forms.Button
$GitPushButton = New-Object System.Windows.Forms.Button
$GitPullButton = New-Object System.Windows.Forms.Button
$GitStatusButton = New-Object System.Windows.Forms.Button

$SaveButton = New-Object System.Windows.Forms.Button
$AddLinkToExistPageButton = New-Object System.Windows.Forms.Button
$SearchButton = New-Object System.Windows.Forms.Button
$JumpPageButton = New-Object System.Windows.Forms.Button
$GoToPageButton = New-Object System.Windows.Forms.Button
$label1 = New-Object System.Windows.Forms.Label
$richTextBox1 = New-Object System.Windows.Forms.RichTextBox

$InitialFormWindowState = New-Object System.Windows.Forms.FormWindowState
#endregion Generated Form Objects

#----------------------------------------------
#Generated Event Script Blocks
#----------------------------------------------
#Provide Custom Code for events specified in PrimalForms.
$handler_treeView1_AfterSelect= 
{
    $links = (Get-NeighborLinks $_.Node.Name)

    $_.Node.Nodes.Clear()

    foreach($link in $links)
    {
        Add-Node $_.Node $link
    }
}

$handler_treeView1_AfterExpand= 
{
    #Write-Host "EXPAND!" $_.Node.Name
}

$ReviewButton_OnClick= 
{
    Write-Host '----- Review ------------------------------------------------------'
    Review-Next
    Write-Host '-------------------------------------------------------------------'
}

$RecentButton_OnClick= 
{
    $rcnt_ts = (get-date).AddHours(-48)
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
    $request = [Microsoft.VisualBasic.Interaction]::InputBox("Введите временную отметку", "Недавние", $rcnt_ts.ToString("yyyy-MM-dd"))
    $rcnt_ts = [datetime]::parseexact($request, "yyyy-MM-dd", $null)
    #Write-Host $rcnt_ts

    $rcnt_nodes = ($script:note_title.GetEnumerator() | Where-Object {$script:note_timestamp[$_.Name] -ge $rcnt_ts} | Sort-Object -Property @{Expression={$script:note_timestamp[$_.Name]}} -Descending).Value

    if($rcnt_nodes.Count -gt 0)
    {
        $treeView1.Nodes.Clear()

        foreach($rcnt_node in $rcnt_nodes)
        {
            Add-Node $treeView1 $rcnt_node | Out-Null
        }
    }
    else
    {
        Write-Host 'Нет недавних заметок за этот период'
    }
}

$ConsistencyCheckerButton_OnClick= 
{
    Write-Host '----- Consistency Check -------------------------------------------'
    
    $problem = @{}

    #$problem[1498] = 'у гугла нет проблем'

    $name2id = @{} #не путать с title2oid
    #нужно, потому что в title2oid два или более разных имени могут ссылаться на один oid после переименования

    for($node=1; $node -le $script:last_oid; $node++)
    {
        $name2id[$script:note_title[$node]] = $node
    }

    $neibs = @{} #ids
    $links = @{} #names

    $warn_count = 0

    for($node=1; $node -le $script:last_oid; $node++)
    {
        $links[$node] = ($script:note_content[$node] | Where-Object {$_ -like '*linkto:*'} | ForEach-Object {$_.Split(':')[1]})

        $tmplist = New-Object System.Collections.Generic.List[System.Object]

        foreach($link in $links[$node])
        {
            if(-not $name2id[$link])
            {
                $warn_count++
                $problem[$node] = ('' + $problem[$node] + "ПРЕДУПРЕЖДЕНИЕ: ссылка на несуществующую страницу: $link ; ")
                continue
            }

            $tmplist.Add($name2id[$link])
        }

        $neibs[$node] = $tmplist
    }

    #$neibs.GetEnumerator() | Out-GridView
    write-host "Количество узлов: " $neibs.Count #можно, конечно, проще...

    $err_count = 0

    foreach($Aid in $neibs.Keys)
    {
        #Write-Host $Aid
        foreach($Bid in $neibs[$Aid])
        {
            if(-not ($neibs[$Bid] -contains $Aid))
            {
                $Aname = $script:note_title[$Aid]
                $Bname = $script:note_title[$Bid]
                $problem[$Bid] = ('' + $problem[$Bid] + "ОШИБКА: отсутствует обратная ссылка: $Bname -> $Aname ; ")
                $err_count++
            }
        }
    }

    for($node=1; $node -le $script:last_oid; $node++)
    {
        if($neibs[$node].Count -lt 1)
        {
            $warn_count++
            $problem[$node] = ('' + $problem[$node] + "ПРЕДУПРЕЖДЕНИЕ: заметка без ссылок: $($script:note_title[$node]) ; ")
        }
    }

    for($node=1; $node -le $script:last_oid; $node++)
    {
        if($script:note_title[$node] -like 'Untitled*')
        {
            $err_count++
            $problem[$node] = ('' + $problem[$node] + "ОШИБКА: заметка без имени: $($script:note_title[$node]) ; ")
        }
    }

    foreach($key in $script:note_hash.Keys)
    {
        $test_hash = (Calc-CheckSum $key)
        if($test_hash -ne $script:note_hash[$key])
        {
            $err_count++
            $problem[$key] = ('' + $problem[$key] + "ОШИБКА: не совпадает хеш: $($script:note_title[$key]) ; ")
        }
    }

    Write-Host "Ошибки:         $err_count"
    Write-Host "Предупреждения: $warn_count"
    
    #добавить потом ещё столбцов
    $stats = New-Object System.Collections.Generic.List[System.Object]

    for($i = 1; $i -le $script:last_oid; $i++)
    {
        $stats.Add([pscustomobject]@{
                'oid' = $i
                'Name' = $script:note_title[$i]
                'Links' = $neibs[$i].Count
                'Timestamp' = $script:note_timestamp[$i]
                'Review timestamp' = $script:review_ts[$i]
                'Priority' = $script:note_review[$i]
                'Problem' = $problem[$i]
                })
    }

    $stats | Sort-Object -Property Problem,oid -Descending | Out-GridView

    Write-Host '-------------------------------------------------------------------'
}

$GitStatusButton_OnClick= 
{
    Write-Host '----- Git status --------------------------------------------------'
    #Start-Process -FilePath $script:path2git -ArgumentList 'status' -Wait -WorkingDirectory $script:workfile.Directory.Parent.FullName -NoNewWindow

    #https://stackoverflow.com/questions/8761888/capturing-standard-out-and-error-with-start-process/33652732#33652732

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $script:path2git
    $pinfo.WorkingDirectory = $PSScriptRoot
    $pinfo.RedirectStandardError = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.UseShellExecute = $false
    $pinfo.Arguments = 'status'
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    $p.WaitForExit()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    #Write-Host "stdout: $stdout"
    #Write-Host "stderr: $stderr"
    #Write-Host "exit code: " + $p.ExitCode

    if(($stdout.Substring(0,14) -eq 'On branch main') -and
       ($stdout.Substring(15,30) -eq 'Your branch is up to date with') -and
       ($stdout.Substring(62,37) -eq 'nothing to commit, working tree clean'))
    {
        Write-Host 'OK!'
    }
    else
    {
        Write-Host "stdout: $stdout"
    }

    Write-Host '-------------------------------------------------------------------'
}

$GitPullButton_OnClick= 
{
    Write-Host '----- Git PULL ----------------------------------------------------'
    Start-Process -FilePath $script:path2git -ArgumentList 'pull' -Wait -WorkingDirectory $PSScriptRoot -NoNewWindow
    Write-Host '-------------------------------------------------------------------'
}

$GitPushButton_OnClick= 
{
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
    $commit_message = [Microsoft.VisualBasic.Interaction]::InputBox("Введите комментарий к коммиту", "Коммит", (Get-Date).ToString("UPD yyyy-MM-dd HH-mm"))

    Write-Host '----- Add, commit & push ------------------------------------------'
    Write-Host ">> git add -A`n`n"

    Start-Process -FilePath $script:path2git -ArgumentList 'add -A' -Wait -WorkingDirectory $PSScriptRoot -NoNewWindow
    Start-Sleep -Seconds 3

    Write-Host ">> git commit -m `"$commit_message`"`n`n"

    Start-Process -FilePath $script:path2git -ArgumentList "commit -m `"$commit_message`"" -Wait -WorkingDirectory $PSScriptRoot -NoNewWindow
    Start-Sleep -Seconds 3

    Write-Host ">> git push`n`n"

    Start-Process -FilePath $script:path2git -ArgumentList 'push' -Wait -WorkingDirectory $PSScriptRoot -NoNewWindow
    Start-Sleep -Seconds 3

    Write-Host '-------------------------------------------------------------------'
}

$SaveButton_OnClick= 
{
    #save changes

    $saving_t1 = get-date

    #синхронизируются изменения только в текущей заметке, поэтому уход с неё запрещён, пока не нажата кнопка сохранения...

    $script:note_content[$script:curr_oid] = New-Object System.Collections.Generic.List[System.Object]
    $script:note_content[$script:curr_oid].AddRange($richTextBox1.Lines)

    $script:note_hash[$script:curr_oid] = (Calc-CheckSum $script:curr_oid)

    #обновление метаданных текущей заметки в памяти

    for($i = 0; $i -lt ($script:note_content[$script:curr_oid]).Count; $i++)
    {
        if(($script:note_content[$script:curr_oid])[$i] -like 'title:*')
        {
            #интересно, какой будет эффект от изменения имени заметки...
            $script:note_title[$script:curr_oid] = ($script:note_content[$script:curr_oid])[$i].Split(':')[1]
            #2 тайтла будут ссылаться на один oid
            $script:title2oid[$script:note_title[$script:curr_oid]] = $script:curr_oid
            continue
        }

        if(($script:note_content[$script:curr_oid])[$i] -like 'timestamp:*')
        {
            #поменять на get-date? нет! я могу текстом в заметку дату написать и именно она должна быть сюда внесена (не мешать с review, у него своя метка времени)
            $script:note_timestamp[$script:curr_oid] = [datetime]::parseexact((($script:note_content[$script:curr_oid])[$i].Split(':')[1]), 'yyyy-MM-dd', $null)
            continue
        }

        if(($script:note_content[$script:curr_oid])[$i] -like '#review:*')
        {
            $script:note_review[$script:curr_oid] = [int](($script:note_content[$script:curr_oid])[$i].Split(':')[1])
            continue
        }
    }
    
    $out_buf = New-Object System.Collections.Generic.List[System.Object]
    $padding = @('')*5

    for($node=1; $node -le $script:last_oid; $node++)
    {
        $out_buf.AddRange($script:note_content[$node])
        $out_buf.AddRange($padding)

        if(-not $script:note_hash[$node])
        {
            $script:note_hash[$node] = (Calc-CheckSum $node)
        }

        $out_buf.Add('checksum:' + $script:note_hash[$node])
        $out_buf.AddRange($padding)
    }

    $out_buf | Out-File -LiteralPath $script:workfile -Encoding utf8 -Force

    $label1.Text = "СОХРАНЕНО!"

    #обнуляем "счётчик" изменений
    $script:changed_notes = New-Object System.Collections.Generic.List[System.Object]

    $GoToPageButton.Enabled = $true
    $JumpPageButton.Enabled = $true
    $ReviewButton.Enabled = $true
    $AddLinkToExistPageButton.Enabled = $true

    $saving_t2 = get-date
    Write-Host "Сохранение (сек): " + ($saving_t2 - $saving_t1).TotalSeconds
}

$SearchButton_OnClick= 
{
    #поиск текста
    
    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
    $request = [Microsoft.VisualBasic.Interaction]::InputBox("Введите искомое слово/фрагмент", "Поиск")

    $searchresults = (Search-Word $request)

    $searchresults | Out-GridView
}

$RTFChanged= 
{
    if($script:ignore_RTB_changes)
    {
        $script:ignore_RTB_changes = $false
    }
    else
    {
        $script:changed_notes.Add($script:curr_oid)
    }

    if($script:changed_notes.Count -gt 0)
    {
        $label1.Text = 'Заметка была изменена [' + $script:changed_notes.Count + ']' #количество изменений в попугаях
        $GoToPageButton.Enabled = $false
        $JumpPageButton.Enabled = $false
        $ReviewButton.Enabled = $false
        $AddLinkToExistPageButton.Enabled = $false
    }
}

$AddLinkToExistPageButton_OnClick= 
{
    #Add link
    $selected_link = ($script:note_title | Out-GridView -OutputMode Single)

    $sl_oid = $selected_link.Name
    $sl_text = $selected_link.Value

    $script:note_content[$sl_oid].Insert(( $script:note_content[$sl_oid].Count-2 ), ('На эту страницу ссылается - linkto:' + $script:note_title[$script:curr_oid]))
    $script:changed_notes.Add($sl_oid)
    $script:note_hash[$sl_oid] = (Calc-CheckSum $sl_oid)

    $script:note_content[$script:curr_oid].Insert(( $script:note_content[$script:curr_oid].Count-2 ), ('linkto:' + $sl_text))
    $richTextBox1.Lines = $script:note_content[$script:curr_oid]
    $script:note_hash[$script:curr_oid] = (Calc-CheckSum $script:curr_oid)
}

$GoToPageButton_OnClick= 
{
    #GoTo
    
    $selected_link = $treeView1.SelectedNode.Name

    if(-not $selected_link)
    {
        Write-Host "No link selected"
        return
    }

    $prev = $script:note_title[$script:curr_oid]
    $target = $selected_link

    if($script:title2oid.Keys -contains $target)
    {
        Write-Host "Go to existing $target"
        GoToPage $script:title2oid[$target]
    }
    else
    {
        Write-Host "Create $target"
        
        $script:last_oid++
        $script:note_content[$script:last_oid] = New-Object System.Collections.Generic.List[System.Object]
        $script:note_title[$script:last_oid] = $target
        $script:title2oid[$target] = $script:last_oid
        $script:note_timestamp[$script:last_oid] = (Get-Date)
        $script:note_review[$script:last_oid] = 1

        $script:note_content[$script:last_oid].Add('----- begin note')
        $script:note_content[$script:last_oid].Add('')
        $script:note_content[$script:last_oid].Add('title:' + $target)
        $script:note_content[$script:last_oid].Add('#review:1')
        $script:note_content[$script:last_oid].Add('')
        $script:note_content[$script:last_oid].Add('timestamp:' + (get-date).ToString('yyyy-MM-dd'))
        $script:note_content[$script:last_oid].Add('')
        $script:note_content[$script:last_oid].Add('Основной текст')
        $script:note_content[$script:last_oid].Add('')
        $script:note_content[$script:last_oid].Add("Назад - linkto:$prev")
        $script:note_content[$script:last_oid].Add('')
        $script:note_content[$script:last_oid].Add('----- end note')
        $script:changed_notes.Add($script:last_oid)
        GoToPage $script:last_oid
    }
}

$JumpPageButton_OnClick= 
{
    #Jump
    $selected_link = ($script:note_title | Out-GridView -OutputMode Single)
    Write-Host "Jump to existing" $selected_link.Value
    GoToPage $selected_link.Name
}

$OnLoadForm_StateCorrection=
{#Correct the initial state of the form to prevent the .Net maximized form issue
	$form1.WindowState = $InitialFormWindowState
}

#----------------------------------------------
#region Generated Form Code
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 762
$System_Drawing_Size.Width = 1192
$form1.ClientSize = $System_Drawing_Size
$form1.DataBindings.DefaultDataSourceUpdateMode = 0
$form1.Name = "form1"
$form1.Text = "Primal Form"


$treeView1.DataBindings.DefaultDataSourceUpdateMode = 0
$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 13
$System_Drawing_Point.Y = 43
$treeView1.Location = $System_Drawing_Point
$treeView1.Name = "treeView1"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 680
$System_Drawing_Size.Width = 424
$treeView1.Size = $System_Drawing_Size
$treeView1.TabIndex = 21
$treeView1.add_AfterSelect($handler_treeView1_AfterSelect)
$treeView1.add_AfterExpand($handler_treeView1_AfterExpand)

$form1.Controls.Add($treeView1)


$ReviewButton.DataBindings.DefaultDataSourceUpdateMode = 0
$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 462
$ReviewButton.Location = $System_Drawing_Point
$ReviewButton.Name = "ReviewButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$ReviewButton.Size = $System_Drawing_Size
$ReviewButton.TabIndex = 20
$ReviewButton.Text = "Review"
$ReviewButton.UseVisualStyleBackColor = $True
$ReviewButton.add_Click($ReviewButton_OnClick)

$form1.Controls.Add($ReviewButton)


$RecentButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 432
$RecentButton.Location = $System_Drawing_Point
$RecentButton.Name = "RecentButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$RecentButton.Size = $System_Drawing_Size
$RecentButton.TabIndex = 19
$RecentButton.Text = "Recent"
$RecentButton.UseVisualStyleBackColor = $True
$RecentButton.add_Click($RecentButton_OnClick)

$form1.Controls.Add($RecentButton)


$ConsistencyCheckerButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 402
$ConsistencyCheckerButton.Location = $System_Drawing_Point
$ConsistencyCheckerButton.Name = "ConsistencyCheckerButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$ConsistencyCheckerButton.Size = $System_Drawing_Size
$ConsistencyCheckerButton.TabIndex = 18
$ConsistencyCheckerButton.Text = "Consistency check"
$ConsistencyCheckerButton.UseVisualStyleBackColor = $True
$ConsistencyCheckerButton.add_Click($ConsistencyCheckerButton_OnClick)

$form1.Controls.Add($ConsistencyCheckerButton)


$GitPushButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 341
$GitPushButton.Location = $System_Drawing_Point
$GitPushButton.Name = "GitPushButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$GitPushButton.Size = $System_Drawing_Size
$GitPushButton.TabIndex = 17
$GitPushButton.Text = "Git push"
$GitPushButton.UseVisualStyleBackColor = $True
$GitPushButton.add_Click($GitPushButton_OnClick)

$form1.Controls.Add($GitPushButton)


$GitPullButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 311
$GitPullButton.Location = $System_Drawing_Point
$GitPullButton.Name = "GitPullButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$GitPullButton.Size = $System_Drawing_Size
$GitPullButton.TabIndex = 16
$GitPullButton.Text = "Git pull"
$GitPullButton.UseVisualStyleBackColor = $True
$GitPullButton.add_Click($GitPullButton_OnClick)

$form1.Controls.Add($GitPullButton)


$GitStatusButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 281
$GitStatusButton.Location = $System_Drawing_Point
$GitStatusButton.Name = "GitStatusButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$GitStatusButton.Size = $System_Drawing_Size
$GitStatusButton.TabIndex = 15
$GitStatusButton.Text = "Git status"
$GitStatusButton.UseVisualStyleBackColor = $True
$GitStatusButton.add_Click($GitStatusButton_OnClick)

$form1.Controls.Add($GitStatusButton)


$SaveButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 223
$SaveButton.Location = $System_Drawing_Point
$SaveButton.Name = "SaveButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$SaveButton.Size = $System_Drawing_Size
$SaveButton.TabIndex = 10
$SaveButton.Text = "Save changes"
$SaveButton.UseVisualStyleBackColor = $True
$SaveButton.add_Click($SaveButton_OnClick)

$form1.Controls.Add($SaveButton)


$AddLinkToExistPageButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 163
$AddLinkToExistPageButton.Location = $System_Drawing_Point
$AddLinkToExistPageButton.Name = "AddLinkToExistPageButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$AddLinkToExistPageButton.Size = $System_Drawing_Size
$AddLinkToExistPageButton.TabIndex = 9
$AddLinkToExistPageButton.Text = "Add link"
$AddLinkToExistPageButton.UseVisualStyleBackColor = $True
$AddLinkToExistPageButton.add_Click($AddLinkToExistPageButton_OnClick)

$form1.Controls.Add($AddLinkToExistPageButton)


$SearchButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 133
$SearchButton.Location = $System_Drawing_Point
$SearchButton.Name = "SearchButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$SearchButton.Size = $System_Drawing_Size
$SearchButton.TabIndex = 8
$SearchButton.Text = "Search"
$SearchButton.UseVisualStyleBackColor = $True
$SearchButton.add_Click($SearchButton_OnClick)

$form1.Controls.Add($SearchButton)


$JumpPageButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 73
$JumpPageButton.Location = $System_Drawing_Point
$JumpPageButton.Name = "JumpPageButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$JumpPageButton.Size = $System_Drawing_Size
$JumpPageButton.TabIndex = 7
$JumpPageButton.Text = "Jump"
$JumpPageButton.UseVisualStyleBackColor = $True
$JumpPageButton.add_Click($JumpPageButton_OnClick)

$form1.Controls.Add($JumpPageButton)


$GoToPageButton.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 1071
$System_Drawing_Point.Y = 43
$GoToPageButton.Location = $System_Drawing_Point
$GoToPageButton.Name = "GoToPageButton"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 109
$GoToPageButton.Size = $System_Drawing_Size
$GoToPageButton.TabIndex = 6
$GoToPageButton.Text = "GoTo"
$GoToPageButton.UseVisualStyleBackColor = $True
$GoToPageButton.add_Click($GoToPageButton_OnClick)

$form1.Controls.Add($GoToPageButton)

$label1.DataBindings.DefaultDataSourceUpdateMode = 0

$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 443
$System_Drawing_Point.Y = 730
$label1.Location = $System_Drawing_Point
$label1.Name = "label1"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 23
$System_Drawing_Size.Width = 621
$label1.Size = $System_Drawing_Size
$label1.TabIndex = 5
$label1.Text = ""

$form1.Controls.Add($label1)

$richTextBox1.DataBindings.DefaultDataSourceUpdateMode = 0
$System_Drawing_Point = New-Object System.Drawing.Point
$System_Drawing_Point.X = 443
$System_Drawing_Point.Y = 43
$richTextBox1.Location = $System_Drawing_Point
$richTextBox1.Name = "richTextBox1"
$System_Drawing_Size = New-Object System.Drawing.Size
$System_Drawing_Size.Height = 680
$System_Drawing_Size.Width = 621
$richTextBox1.Size = $System_Drawing_Size
$richTextBox1.TabIndex = 4
$richTextBox1.Text = ""
$richTextBox1.add_TextChanged($RTFChanged)

$richTextBox1.Font = New-Object System.Drawing.Font("Tahoma",10,[System.Drawing.FontStyle]::Regular)

$form1.Controls.Add($richTextBox1)


#endregion Generated Form Code

#Save the initial state of the form
$InitialFormWindowState = $form1.WindowState
#Init the OnLoad event to correct the initial state of the form
$form1.add_Load($OnLoadForm_StateCorrection)
#Show the Form

GoToPage $script:last_oid

$form1.ShowDialog()| Out-Null

} #End Function

#Call the Function
GenerateForm
