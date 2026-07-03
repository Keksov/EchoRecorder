# EchoScript / EchoRecorder — обзор архитектуры и статус

> Сводка по архитектуре системы. Составлено по коду, git-истории и логам.
> Дата: 2026-07-01. Обновлено: добавлен ws-daemon файловый интерфейс (§6), уточнён оркестратор и `jobs/queue`.

---

## 0. Карта проекта

```
c:\projects\EchoScript\                  ← родительский git-репозиторий (origin: EchoScript.git)
├── EchoRecorder\                         ← ВЛОЖЕННЫЙ отдельный git-репозиторий (клиент записи/распознавания)
├── services\                             ← сервисы распознавания (2 категории: batch + daemon)
├── shared\echoscript_shared\             ← общий Python-пакет (механизм очереди jobs/)
├── jobs\                                 ← файловая очередь заданий (офлайн-тракт)
├── orchestrator\                         ← file-daemon: HTTP API + диспетчер очереди jobs/ (Bun/Hono, :3000)
├── tools\ffmpeg\                          ← ffmpeg для конвертации аудио (используется оркестратором; gitignored)
├── build\, scripts\, tests\, config.json
```

Важно: **EchoRecorder — это вложенный git-репозиторий** внутри EchoScript. У обоих свой `.git` и разные remote. EchoRecorder — лишь один компонент (клиент); сервисы, очередь и демоны — уровень родительского проекта.

Ни в одном репозитории на момент исследования **не было README/docs** — документация отсутствовала.

---

## 1. EchoRecorder — структура и статус

Проект на **Free Pascal / Lazarus**. Три смысловые части:

| Папка | Роль |
|------|------|
| `core/src/` | Ядро — общая библиотека (10 модулей, ~3200 строк). Вся логика здесь. |
| `cli/src/EchoRecorderCore.pas` | Консольное приложение `EchoRecorderCore.exe` — обёртка над ядром (парсинг аргументов). |
| `app/src/` | GUI на Lazarus + Pixie (HTML-рендер). Сейчас — симулятор микрофона. |
| `vendors/` | Зависимости: `uos` (аудио), `vosk` (спайк STT), `pixie` (UI), `SharedPasCore` (JSON-логи). |
| `VendorsCore/` | Тулчейн FPC (ставится setup-скриптом, в git не входит). |

### Модули ядра (`core/src/`)

| Модуль | Назначение |
|--------|-----------|
| `echo_recorder_core_api.pas` | Типы/контракты: настройки, результат, бэкенды, виды демонов, режимы. |
| `echo_recorder_core_runtime.pas` | Главный конвейер `runRecorderCli` — выбор бэкенда и оркестрация. |
| `echo_recorder_core_audio.pas` | Декод аудио (ogg/wav/mp3/flac/pcm16le через uos), нарезка фрагментов, упаковка WAV. |
| `echo_recorder_core_transport.pas` | `THttpSpeechTransport` — HTTP в EchoScript `/api/v2/speech/recognize`. |
| `echo_recorder_core_vosk.pas` | Локальное распознавание vosk in-process (`runLocalRecognition`, `runLocalPcmStreamRecognition`). |
| `echo_recorder_core_voskdaemon.pas` | **WebSocket-клиент к демонам** (vosk/whisper/diarization). Имя вводит в заблуждение. |
| `echo_recorder_core_protocol.pas` | Структурированный лог событий (JSONL / plain): partial, word, segment, final, error. |
| `echo_recorder_core_sources.pas` | Источники входа: файл-фикстуры, stdin. |
| `echo_recorder_core_sinks.pas` | Вывод результата (stdout/JSON-файл). |
| `echo_recorder_core_paths.pas` | Пути/каталоги. |

### Бэкенды распознавания (CLI `--backend`)

- `transport` — отправка аудио по HTTP в EchoScript.
- `local` / `local-dictation` — локальный vosk in-process (работает ТОЛЬКО для потокового `-f pcm16le -i -`).
- `daemon` — стриминг PCM по WebSocket в демоны (vosk/whisper/diarization), `voskdaemon.pas`.

### Статус готовности

| Слой | Готовность | Комментарий |
|------|-----------|-------------|
| Ядро + CLI | ~80% | Распознавание transport/daemon/локальный vosk работает; протокол и логирование зрелые. |
| GUI (`app/`) | ~20% | Только симулятор: берёт `.ogg` из `tests/` как «фиктивный микрофон». Реального захвата нет. |
| Документация | ~0% | README/docs отсутствуют. |

### Что НЕ доделано (TODO)

1. **GUI — заглушка-симулятор.** `app/src/main_form.pas` не пишет с реального микрофона (код прямо признаёт «bypasses the real microphone for now»). PortAudio/uos в vendors есть, но в GUI не подключён.
2. **Файловый `local-dictation` не реализован.** `runtime.pas:72-84` — `TUnavailableLocalDictationEngine` возвращает `501 «not implemented in this slice»`. Локальный vosk работает только для потокового `pcm16le -i -`.
3. **VibeVoice — заглушка**: в `EchoRecorderCore.pas:65-66` `vibevoice` маппится на `whisper`.
4. **`initStdin` — пустой placeholder** (`EchoRecorderCore.pas:432-435`).
5. **Нет документации** (ни README, ни CLAUDE.md).
6. Зависимость `pixie` вынесена в отдельный вложенный репозиторий (ставится setup-скриптом). Последние 6 коммитов — только про setup/vendoring, не про функционал.

### О логах разработки (Copilot)

Рабочее хранилище VS Code найдено: `…\workspaceStorage\db28eb73…\` (привязано к папке EchoRecorder), но **история разработки не сохранилась** — единственный файл сессии пустой (создан позже, модель GPT-5.3-Codex, агентный режим, 0 запросов). Восстановить ход работы по чатам нельзя; ориентир — код и git.

---

## 2. Сервисы EchoScript — две категории

В `services/` живут сервисы **двух разных архитектур**:

### A. Батч-сервисы (Python) — используют очередь `jobs/`

`whisper_podlodka`, `vosk_ru`, `vosk_en`, `vosk_ru_cmd`, `vibevoice`, `borealis`, `gemma4`.

- Одинаковый тонкий `app/main.py` + свой `app/adapter.py`.
- Вся логика очереди — в общем пакете `shared/echoscript_shared/service_runner.py` (`run_service_from_cli` → `run_model_service`).
- Запуск через `launch.bat`:
  ```
  python -m app.main --jobs-root <PROJECT>/jobs --project-root <PROJECT> --model-name vosk_ru --poll-interval-ms 500
  ```

### B. Стриминговые демоны — НЕ используют `jobs/`

`voskdaemon`, `whisperdaemon`, `vibevoicedaemon`, `diarizationdaemon`.

- WebSocket/TCP-серверы на портах.
- Это онлайн-тракт реального времени; именно с ними работает EchoRecorder в режиме `--backend daemon`.

| Демон | Порт | Реализация |
|------|------|-----------|
| voskdaemon | 7701 / 7702 / 7703 | Free Pascal (`VoskDaemon.exe`) |
| whisperdaemon | 7801 | Free Pascal (`WhisperDaemon.exe`) |
| vibevoicedaemon | 7802 | Python |
| diarizationdaemon | 7900 | — |

Итого: `jobs/` — **офлайн/батч-тракт**, демоны — **онлайн-тракт**.

> **Обновление:** `whisperdaemon` теперь обслуживает и **офлайн-тракт** через файловый API
> (`transcribe_file`) — оркестратор использует его как «ws-daemon» бэкенд очереди вместо
> Python-воркера. Подробнее — §6.

---

## 3. Механизм очереди `jobs/` (file-based queue)

Структуру задаёт `ServicePaths` в `service_runner.py`:

| Путь | Назначение |
|------|-----------|
| `jobs/input/<model_name>/` | входная очередь модели (сюда кладут задания) |
| `jobs/data/<job_id>/` | рабочая папка задания (input, params, status, результаты) |
| `jobs/output/<job_id>.json` | маркер завершения `{created_at, status}` |
| `services/<model>.pid` / `.stop` | PID-файл и файл-сигнал остановки |

> Замечание: `jobs/queue` — это **очередь ожидания оркестратора** (`orchestrator/`): `JobManager.enqueueJob` кладёт `jobs/queue/<id>.json`, `peekQueue` его читает, а `dispatchJob` переносит в `jobs/input/<model>/` для Python-воркера. Python `service_runner` работает уже с `jobs/input/<model>/`. Для ws-daemon моделей оркестратор обрабатывает задание сам (§6), не создавая маркер в `input/`.

### Цикл воркера (`_model_input_loop`)

Наблюдает `jobs/input/<model>/`. Пробуждение — `watchdog.Observer` (событие создания файла), fallback — поллинг раз в 500 мс.

Задание попадает в обработку **двумя способами**:

1. **Маркер очереди** (`_claim_queue_file`): оркестратор заранее создаёт `jobs/data/<job_id>/` (с `input.json`/`params.json`/`status.json`) и кладёт пустышку `jobs/input/<model>/<job_id>.json`. Воркер атомарно захватывает её через `rename` → `<job_id>.json.lock`.

2. **Сырой медиа-файл** (`_claim_media_file`): аудио кладут прямо в `jobs/input/<model>/` (пример: `jobs/input/whisper_podlodka/CD4 - 8 - The Absolute.flac`). Воркер захватывает через `rename` → `*.processing`, генерирует `job_id` вида `<epoch_ms>_<uuid>_<model>_<имя-файла>` (кириллица транслитерируется), создаёт `jobs/data/<job_id>/`, перемещает аудио в `data/<job_id>/input`, генерирует `input.json`/`params.json`/`status.json`.

### Обработка (`_process_job`)

- читает `params.json` (language, timestamps, word_timestamps; для vosk — punctuation/speaker_embeddings);
- находит аудио (`data/<job_id>/input` или `source` из `input.json`);
- вызывает `adapter.transcribe(audio, language, params)`;
- пишет артефакты: `result.json` (raw + normalized сегменты со спикерами), `result_plain.txt`, `result_timestamp.txt`;
- дописывает событие в `status.json` (список: `dispatching → pending → processing → ready/failed`);
- в финале — маркер `jobs/output/<job_id>.json`.

### Гарантии

- Атомарный захват через `rename` (исключает двойную обработку).
- Один воркер на сервис (`ThreadPoolExecutor(max_workers=1)`).
- Атомарная запись через temp + `os.replace` с ретраями.
- Жизненный цикл: PID-файл, остановка через `.stop`-файл или SIGINT/SIGTERM.

---

## 4. Демоны и протокол (онлайн-тракт)

### `voskdaemon.pas` — это КЛИЕНТ, а не демон

Несмотря на имя, `core/src/echo_recorder_core_voskdaemon.pas` внутри EchoRecorder — **универсальный WebSocket-клиент**, который одинаково общается со всеми видами демонов. Вид определяется портом (`inferDaemonKindFromPort`) или явным `Kind` в эндпойнте:

| Вид (`TDaemonKind`) | Порт | Сервер |
|---|---|---|
| `dkVosk` | 7701 / 7702 / 7703 | `services/voskdaemon` (FPC, ws) |
| `dkWhisper` | 7801 | `services/whisperdaemon` (FPC, ws) |
| `dkWhisper` (vibevoice) | 7802 | `services/vibevoicedaemon` (Python, ws) |
| `dkDiarization` | 7900 | `services/diarizationdaemon` |

Эндпойнты задаются ключами CLI: `--daemon whisper:7801`, `--daemon-port`, `--daemon-ports`.

### Где живёт whisper-демон

`c:\projects\EchoScript\services\whisperdaemon\` — отдельная программа на **Free Pascal**:
- исходник `app/src/WhisperDaemon.pas` → `build/x64/WhisperDaemon.exe`;
- `TWebSocketServer`, слушает `ws://127.0.0.1:7801/` (`--port`, по умолчанию 7801);
- внутри обёртка над **whisper.cpp** (`services/whisperdaemon/whisper.cpp/`), модель `models/ggml-whisper_podlodka.bin`;
- запуск: `scripts/start_whisperdaemon_podlodka.bat` (`--model-name whisper_podlodka --host … --port 7801`, опц. `--gpu`).

Связь EchoRecorder ↔ whisper — **процессно-разделённая по WebSocket**: два независимых exe, общий контракт — JSON поверх ws.

### Протокол (подтверждён с обеих сторон)

```
EchoRecorder (voskdaemon.pas, клиент)          WhisperDaemon.exe (сервер, :7801)
  Connect ws://127.0.0.1:7801/  ───────────────▶
  {event:session_start, audio_format:pcm16le,
   sample_rate_hz:16000, channels:1, language,
   mode, speaker_embeddings, emit_partials,
   emit_words}                  ───────────────▶
                                ◀───────────────  {event:session_ack}
  бинарные PCM-кадры по 3840 байт (SendData) ──▶  (накопление аудио)
  {event:flush}                 ───────────────▶
                                ◀───────────────  {event:word_committed ...}
                                ◀───────────────  {event:segment_final ...}
                                ◀───────────────  {event:session_final, text,
                                                    language, detected_language}
```

- Клиент: `buildSessionStartMessage` (`:172`), `connectDaemonClients` (`:610`), разбор входящих в `handleMessage` (`:435`).
- Сервер: `session_ack`/`segment_final`/`word_committed`/`session_final` в `WhisperDaemon.pas:1633-1761`.
- `partial_update` шлёт только vosk (`emit_partials = (kind = dkVosk)`).

### Мульти-демон в одном прогоне

`runDaemonPcmStreamRecognition` (`:955`) держит несколько соединений одновременно (например whisper-ASR + diarization) и оркестрирует в два этапа:
1. стримит PCM во все ASR-демоны → `flush` → ждёт `session_final`, собирает сегменты;
2. если есть diarization-демон — отдаёт ему сегменты как подсказки (`diar_set_segments`), `diar_flush`, ждёт `diar_final`, накладывает спикеров.

Diarization использует свои события: `diar_session_start`/`diar_session_ack`/`diar_set_segments`/`diar_flush`/`diar_final`.

Итог агрегируется в `buildDaemonAggregateText` (при нескольких ASR — с префиксами `[whisper@host:port]`).

### Две реализации «whisper» — не путать

- `services/whisperdaemon/` — стриминговый FPC ws-сервер на 7801 (онлайн; с ним работает `voskdaemon.pas`).
- `services/whisper_podlodka/` — батч-сервис на Python через очередь `jobs/` (офлайн).

Одна модель (podlodka), два разных транспорта. `vibevoicedaemon` (7802) — Python-демон, но клиент трактует его как `dkWhisper`.

---

## 5. Открытые вопросы / что ещё стоит изучить

**Разрешено** (см. §6): оркестратор наполняет `jobs/` через HTTP (`/add_file`, `/add_body`) + `enqueue`; `jobs/queue` — его очередь ожидания; внутренности `WhisperDaemon.pas` разобраны.

**Остаётся:**
- Устройство `diarizationdaemon` (7900).
- HTTP-контракт `/api/v2/speech/recognize` на стороне EchoScript-бэкенда (режим `--backend transport`).
- Восстановление ws-daemon задания после краша оркестратора (задание зависает в `processing` без output-маркера).

---

## 6. Оркестратор (file-daemon) и ws-daemon файловый интерфейс

`orchestrator/` — TypeScript/Bun (Hono, :3000). Это **единственный владелец** тракта `jobs/`:
watch, конвертация аудио, жизненный цикл, `status.json`, артефакты и HTTP-статусы.

### HTTP API (`orchestrator/src/index.ts`)
`/add_file`, `/add_body`, `/run_job`, `/get_job_status`, `/get_job_result?type=plain|timestamp|…`,
`/list_jobs`, `/delete_job`, `/api/v2/speech/recognize`.

### Два способа обслуживания модели
Модель маршрутизируется по `config.json`:

| | python-worker (`service_runner`) | ws-daemon (FPC-демон) |
|---|---|---|
| процесс | оркестратор спавнит `python -m app.main` | внешний прогретый `*.exe` (напр. `WhisperDaemon`) |
| очередь | воркер читает `jobs/input/<model>/` | оркестратор сам конвертит и зовёт `transcribe_file` |
| декод | внутри воркера (librosa/HF) | оркестратор через **ffmpeg** → pcm16le 16k mono |
| артефакты | пишет воркер | пишет **оркестратор** (`ws-daemon-runner.ts`) |

Маршрутизация: модель — ws-daemon, если есть в `config.json → ws_daemons` (сопоставление по `model_name`);
тогда `Scheduler` направляет её в `dispatchWsDaemonJob` вместо Python-воркера. Иначе — Python-путь.
Контракт артефактов `jobs/` — один и тот же для обоих путей.

```json
"ws_daemons": {
  "whisperdaemon": { "host": "127.0.0.1", "port": 7801, "model_name": "whisper_podlodka" }
}
```

### Файловый API демона (тонкий, поверх WebSocket)
Демон (`services/whisperdaemon`) держит модель прогретой и отвечает на:
- `{event:describe}` → `describe_ack` (дескриптор из `services/whisperdaemon/daemon.json` с фактическим transport);
- `{event:health}` → `health_ack {state: loading|ready|failed, model_name, error?}`;
- `{event:transcribe_file, request_id, path, language, params}` → поток `word_committed`/`segment_final`
  → терминальный `session_final {text, duration_ms, segment_count, language, detected_language?, request_id}`.

`path` — путь к **уже готовому** raw pcm16le 16k mono (согласованный формат из `daemon.json`).
Демон **не трогает** `jobs/`, не декодирует и не пишет артефакты.

### Поток ws-daemon задания
```
POST /add_file → /run_job → JobManager.enqueueJob (jobs/queue/<id>.json)
   → Scheduler.dispatchNext → findWsDaemonForModel → dispatchWsDaemonJob
      → claimExternalJob (снять queue-маркер, status=pending)
      → runWsDaemonJob:  ffmpeg (input → data/<id>/audio.pcm)
                       → daemon-stream-driver.transcribeFileStreaming (WS, окнами)
                       → whisperdaemon (session_start → бинарные окна → flush → session_final)
                       → progress.json (0→100) по мере коммитов
                       → запись result.json (секунды) / result_plain.txt / result_timestamp.txt
                       → status processing→ready|failed, jobs/output/<id>.json
```

### Файловый ввод через стриминг (мост)
Файлы (в т.ч. **многочасовые**) идут через тот же **живой** протокол демона, что и запись
EchoRecorder, а не одним `transcribe_file`. Это снимает 10-мин потолок таймаута, ограничивает
память демона окном и даёт инкрементальные `segment_final` + процент выполнения. Демон при этом
**не меняет** роль (тонкий), правка минимальна — см. ниже.

- **Драйвер** `orchestrator/src/daemon-stream-driver.ts` → `transcribeFileStreaming`: читает `audio.pcm`
  окнами, шлёт `session_start` (контракт `sample_rate_hz=16000, channels=1, audio_format=pcm16le`) →
  бинарные кадры → `flush` → ждёт `session_final`. Backpressure по `bufferedAmount`; **heartbeat**
  вместо глобального таймаута (сбрасывается на каждом событии демона).
- **Окно/rollover — из `config.json`:** `stream_window_ms` (дефолт 30000), `stream_rollover_ms`
  (дефолт 1200000). Rollover (страховка от 30-мин лимита буфера демона) = финализация и продолжение
  на **новом WS-соединении** со сдвигом таймстампов; на практике коммиты по границам предложений
  срабатывают задолго до порога.
- **Прогресс:** раннер пишет `data/<id>/progress.json`
  `{progress_pct, windows_done, windows_total, processed_ms, total_ms, updated_at}` (overwrite,
  троттлинг, финальные 100%). `status.json` остаётся append-лентой lifecycle. API — **аддитивно**:
  поле `progress` в `/list_jobs`, роут `/get_job_progress`, `active_progress` в `GET /`;
  `/get_job_status` без изменений (контракт-массив).
- **Правка демона (накопительная база времени):** в стриминге whisperdaemon эмитил время
  относительно каждого коммита (буфер чистится) → абсолютные таймстампы файла ломались. Демон теперь
  держит `FcommittedMs` и эмитит `segment_final`/`word_committed` со сдвигом (сброс на `session_start`);
  `transcribe_file` (one-shot) не затронут. Проверено E2E (`orchestrator/scripts/e2e_stream_manual.ts`).

### Файловый drop + саморегистрация демонов (readiness)
Возвращено поведение старого Python-watcher: **сырой медиафайл**, бро­шенный в
`jobs/input/<model>/`, снова становится заданием. Плюс закрыт timing: если файл появился, а
ws-daemon ещё не запущен, задание **ждёт в очереди**, а не падает.

- **Drop** (`input-drop.ts` + `file-drop.ts`): оркестратор на старте сканирует `input/<model>/`, а
  дальше слушает `fs.watch` + reconcile-sweep. Файл берётся только когда его mtime стабилен ≥
  `drop_stable_ms` (защита от недокопированного), атомарно клеймится в `.processing`, **перемещается**
  в `data/<id>/input` и создаётся обычным `JobManager`/`enqueue` (один контракт `jobs/`). Осиротевшие
  `.processing` (краш после клейма) восстанавливаются на старте.
- **Саморегистрация демонов** (`daemon-registry.ts` + `-watcher.ts`): демон, став готовым, **атомарно**
  пишет `jobs/registry/<model>.json` `{name, host, port, model_name, state, pid, input:{codec,
  sample_rate_hz, channels}, updated_at}` и обновляет `updated_at` как heartbeat (whisperdaemon —
  каждые 5 c, `--registry-dir`/`ECHOSCRIPT_REGISTRY_DIR`, дефолт `<root>/jobs/registry`). Оркестратор
  watch'ит папку; запись «готова», только если `updated_at` не старше `daemon_registry_ttl_ms`
  (дефолт 15000; инвариант TTL ≥ ~3× heartbeat). `jobs/registry/` создаёт оркестратор.
- **Readiness-gate + requeue** (`scheduler.ts`): `dispatchNext` берёт первое **выполнимое** задание —
  python-модели всегда (оркестратор сам стартует воркер), ws-daemon-модели только при свежей
  `ready`-записи (диспетч на **announced** host/port), неготовые пропускаются (без head-of-line
  блокировки). Транспортный сбой (`DaemonUnreachableError`: connect/close/stall) → **requeue** (статус
  `waiting`), а не terminal `failed`; демон при этом инвалидируется до следующего свежего heartbeat
  (без шторма повторов). Задание для невыключенного демона просто **остаётся в очереди** (`queued`),
  пока демон не зарегистрируется.
- **Стойл vs живость + лимит повторов** (`max_requeue_attempts`, дефолт 5): при редкой речи / долгом
  инференсе демон между коммитами молчит дольше stream-heartbeat (120 c). Чтобы это **не** считалось
  «недоступностью» и не давало бесконечный requeue, whisperdaemon шлёт `{event:keepalive}` из whisper
  `progressCallback` (троттл ~3 c) — оркестратор сбрасывает heartbeat на нём, так что heartbeat =
  реальная живость. Плюс страховка: после `max_requeue_attempts` транспортных сбоев задание падает
  честным `failed`, а не крутится вечно.
- **Известное ограничение:** WS-сервер демона **однопоточный** — во время длинного инференса он держит
  `gInferenceLock` и не отменяет инференс при обрыве клиента (нет abort-on-disconnect). keepalive +
  лимит повторов гасят каскад, но не-блокирующий сервер/отмена — отдельная будущая работа.

### Компоненты
- `orchestrator/src/audio-convert.ts` — ffmpeg → pcm16le 16k mono (`config.ffmpegPath` / env `ECHOSCRIPT_FFMPEG_PATH`).
- `orchestrator/src/daemon-stream-driver.ts` — WS-клиент стриминга: `transcribeFileStreaming` (окна, прогресс, rollover).
- `orchestrator/src/daemon-driver.ts` — WS-клиент: `describeDaemon`, `transcribeFileViaDaemon` (one-shot; для тестов/совместимости).
- `orchestrator/src/ws-daemon-runner.ts` — convert→стрим-драйвер→`progress.json`→артефакты (владелец контракта `jobs/`).
- `orchestrator/src/scheduler.ts` — маршрутизация + readiness-gate (peek-dispatchable) + requeue; startup-scan/watch drop.
- `orchestrator/src/daemon-registry.ts` / `-watcher.ts` — реестр готовности демонов (TTL-свежесть, инвалидация).
- `orchestrator/src/file-drop.ts` / `input-drop.ts` — claim/job_id/bootstrap дропнутых файлов + сканер `input/<model>/`.
- `services/whisperdaemon/daemon.json` — дескриптор формата/возможностей.

### Запуск и тесты
- Стек: `pwsh -NoProfile -File scripts\start_ws_daemon_stack.ps1` (whisperdaemon + оркестратор).
- Юнит: `cd orchestrator && bun test` (audio-convert, daemon-driver, **daemon-stream-driver**, ws-daemon-runner, job-manager).
- E2E HTTP: `pwsh -NoProfile -File tests\whisperdaemon-file-api.ps1` (реальный файл через HTTP API → `ready` + артефакты).
- E2E стрим (ручной, нужен живой демон): `cd orchestrator && bun run scripts\e2e_stream_manual.ts [audio.wav] [port]`.
- E2E drop (ручной, поднимает оркестратор+демон, изолированный jobs-root): `bash orchestrator/scripts/e2e_drop_manual.sh [audio] [port]`.
- Планы инициатив: `orchestrator/spec/file-streaming-bridge-plan.md`, `orchestrator/spec/jobs-drop-daemon-registry-plan.md`.

> Подробности по демону — `services/whisperdaemon/README.md`.
> Паритет ws-daemon и Python — по **схеме/контракту** артефактов, не по дословному тексту
> (whisper.cpp ggml ≠ HF transformers).
