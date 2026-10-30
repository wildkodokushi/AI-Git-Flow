Write-Host "🤖 Запуск AI-ассистента для Git..." -ForegroundColor Cyan

$branchName = Read-Host "Введите тип и название ветки (например, feat/home-swiper)"
if ([string]::IsNullOrWhiteSpace($branchName)) {
    Write-Host "Ветка не указана. Выход." -ForegroundColor Red
    exit
}

Write-Host "🌿 Создаем ветку $branchName..." -ForegroundColor Yellow
git switch -c $branchName

$files = git status --porcelain | ForEach-Object { $_.Substring(3) }

if ($files.Count -eq 0) {
    Write-Host "Нет изменений для коммита." -ForegroundColor Green
    exit
}

Write-Host "📄 Найдено файлов: $($files.Count)" -ForegroundColor Yellow

$fileList = $files -join "`n"

$prompt = @"
Разбей следующие файлы на логические группы для коммитов (максимум 4 группы).
Для каждой группы придумай сообщение коммита в формате Conventional Commits (например, feat: add button, chore: update deps).
Верни ТОЛЬКО валидный JSON массив в таком формате, без лишнего текста:
[
  {"files": ["file1.js", "file2.js"], "message": "feat: add new component"},
  {"files": ["style.css"], "message": "style: update layout"}
]

Список файлов:
$fileList
"@

Write-Host "🧠 Отправляем запрос локальной нейросети (Ollama)..." -ForegroundColor Cyan

$body = @{
    model = "qwen2.5-coder:1.5b"
    messages = @(@{role = "user"; content = $prompt})
    stream = $false
    options = @{
        num_ctx = 8192  


} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Uri "http://localhost:11434/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body
$aiAnswer = $response.choices[0].message.content

$aiAnswer = $aiAnswer -replace '```json', '' -replace '```', ''
$aiAnswer = $aiAnswer.Trim()

Write-Host "✅ План получен:" -ForegroundColor Green
Write-Host $aiAnswer -ForegroundColor Gray

try {
    $plan = $aiAnswer | ConvertFrom-Json
    
    
    foreach ($group in $plan) {
        Write-Host "📦 Коммит: $($group.message)" -ForegroundColor Magenta
        $filesToAdd = $group.files | ForEach-Object { "`"$_`"" }
        $filesString = $filesToAdd -join " "
        
        

Invoke-Expression "git add $filesString"
        
        

git commit -m "$($group.message)"
    }
    
    
    Write-Host "🚀 Отправляем ветку на сервер..." -ForegroundColor Cyan
    git push -u origin $branchName
    
    Write-Host "🎉 Все готово! Изменения разбиты на коммиты и отправлены в ветку $branchName" -ForegroundColor Green
} catch {
    Write-Host "❌ Ошибка: ИИ вернул некорректный формат. Попробуйте еще раз." -ForegroundColor Red
    Write-Host "Ответ ИИ: $aiAnswer" -ForegroundColor Yellow
}