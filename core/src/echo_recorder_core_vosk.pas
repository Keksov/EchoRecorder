unit echo_recorder_core_vosk;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  echo_recorder_core_api,
  echo_recorder_core_audio,
  echo_recorder_core_protocol;

type
  TVoskPartialEvent = record
    Text: string;
    StartMs: Int64;
    EndMs: Int64;
  end;

  TVoskPartialEvents = array of TVoskPartialEvent;

  TVoskLocalRun = record
    FinalText: string;
    Partials: TVoskPartialEvents;
    FragmentEndSamples: TSampleOffsets;
  end;

function    runLocalRecognition(
  const aSettings: TRecorderSettings;
  const aAudio: TMonoPcmAudio;
  const aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TVoskLocalRun;
function    runLocalPcmStreamRecognition(
  const aSettings: TRecorderSettings;
  var aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TRecorderResult;

implementation

uses
  Math,
  Windows,
  Dynlibs,
  fpjson,
  jsonparser,
  echo_recorder_core_paths;

type
  PVoskModel = Pointer;
  PVoskRecognizer = Pointer;

var
  gVoskHandle: TLibHandle = 0;
  gVoskLoaded: Boolean = False;
  gCachedModel: PVoskModel = nil;
  gVoskDllPath: string = '';
  gCachedModelPath: string = '';
  gModelNew: function(const aModelPath: PChar): PVoskModel; cdecl;
  gModelFree: procedure(aModel: PVoskModel); cdecl;
  gRecognizerNew: function(aModel: PVoskModel; aSampleRate: Single): PVoskRecognizer; cdecl;
  gRecognizerFree: procedure(aRecognizer: PVoskRecognizer); cdecl;
  gRecognizerAcceptWaveform: function(aRecognizer: PVoskRecognizer; const aData: Pointer; aLength: Integer): Integer; cdecl;
  gRecognizerPartialResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerFinalResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerSetWords: procedure(aRecognizer: PVoskRecognizer; aEnabled: Integer); cdecl;
  gRecognizerSetPartialWords: procedure(aRecognizer: PVoskRecognizer; aEnabled: Integer); cdecl;
  gSetLogLevel: procedure(aLevel: Integer); cdecl;

const
  PCM_CHUNK_FRAMES = 4000;

procedure prependDirectoryToPath(const aDirPath: string);
var
  envPath: string;
begin
  envPath := SysUtils.GetEnvironmentVariable('PATH');
  if Pos(UpperCase(aDirPath), UpperCase(envPath)) > 0 then
    Exit;

  if envPath = '' then
    Windows.SetEnvironmentVariable(PChar('PATH'), PChar(aDirPath))
  else
    Windows.SetEnvironmentVariable(PChar('PATH'), PChar(aDirPath + PathSeparator + envPath));
end;

procedure freeCachedModel;
begin
  if (gCachedModel <> nil) and Assigned(gModelFree) then
    gModelFree(gCachedModel);

  gCachedModel := nil;
  gCachedModelPath := '';
end;

procedure unloadVoskLibrary;
begin
  freeCachedModel;

  if gVoskHandle <> 0 then
    UnloadLibrary(gVoskHandle);

  gVoskHandle := 0;
  gVoskDllPath := '';
  gVoskLoaded := False;
  Pointer(gModelNew) := nil;
  Pointer(gModelFree) := nil;
  Pointer(gRecognizerNew) := nil;
  Pointer(gRecognizerFree) := nil;
  Pointer(gRecognizerAcceptWaveform) := nil;
  Pointer(gRecognizerPartialResult) := nil;
  Pointer(gRecognizerResult) := nil;
  Pointer(gRecognizerFinalResult) := nil;
  Pointer(gRecognizerSetWords) := nil;
  Pointer(gRecognizerSetPartialWords) := nil;
  Pointer(gSetLogLevel) := nil;
end;

procedure requireAssigned(const aProc: Pointer; const aName: string);
begin
  if aProc = nil then
    raise Exception.CreateFmt('Missing libvosk export: %s', [aName]);
end;

procedure loadVoskLibrary(const aDllPath: string);
var
  dllPath: string;
begin
  dllPath := ExpandFileName(aDllPath);

  if gVoskLoaded then
  begin
    if SameText(gVoskDllPath, dllPath) then
      Exit;

    unloadVoskLibrary;
  end;

  if not FileExists(dllPath) then
    raise Exception.CreateFmt('libvosk.dll not found: %s', [dllPath]);

  prependDirectoryToPath(ExtractFileDir(dllPath));
  gVoskHandle := SafeLoadLibrary(dllPath);
  if gVoskHandle = 0 then
    raise Exception.CreateFmt('Failed to load libvosk.dll from: %s', [dllPath]);

  Pointer(gModelNew) := GetProcedureAddress(gVoskHandle, 'vosk_model_new');
  Pointer(gModelFree) := GetProcedureAddress(gVoskHandle, 'vosk_model_free');
  Pointer(gRecognizerNew) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_new');
  Pointer(gRecognizerFree) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_free');
  Pointer(gRecognizerAcceptWaveform) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_accept_waveform');
  Pointer(gRecognizerPartialResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_partial_result');
  Pointer(gRecognizerResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_result');
  Pointer(gRecognizerFinalResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_final_result');
  Pointer(gRecognizerSetWords) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_set_words');
  Pointer(gRecognizerSetPartialWords) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_set_partial_words');
  Pointer(gSetLogLevel) := GetProcedureAddress(gVoskHandle, 'vosk_set_log_level');

  requireAssigned(Pointer(gModelNew), 'vosk_model_new');
  requireAssigned(Pointer(gModelFree), 'vosk_model_free');
  requireAssigned(Pointer(gRecognizerNew), 'vosk_recognizer_new');
  requireAssigned(Pointer(gRecognizerFree), 'vosk_recognizer_free');
  requireAssigned(Pointer(gRecognizerAcceptWaveform), 'vosk_recognizer_accept_waveform');
  requireAssigned(Pointer(gRecognizerPartialResult), 'vosk_recognizer_partial_result');
  requireAssigned(Pointer(gRecognizerResult), 'vosk_recognizer_result');
  requireAssigned(Pointer(gRecognizerFinalResult), 'vosk_recognizer_final_result');
  requireAssigned(Pointer(gRecognizerSetWords), 'vosk_recognizer_set_words');
  requireAssigned(Pointer(gRecognizerSetPartialWords), 'vosk_recognizer_set_partial_words');
  requireAssigned(Pointer(gSetLogLevel), 'vosk_set_log_level');

  gVoskDllPath := dllPath;
  gVoskLoaded := True;
end;

function getOrCreateCachedModel(const aModelPath: string): PVoskModel;
var
  modelPath: string;
begin
  modelPath := ExpandFileName(aModelPath);

  if (gCachedModel <> nil) and SameText(gCachedModelPath, modelPath) then
    Exit(gCachedModel);

  freeCachedModel;
  gCachedModel := gModelNew(PChar(modelPath));
  if gCachedModel = nil then
    raise Exception.Create('vosk_model_new failed');

  gCachedModelPath := modelPath;
  Result := gCachedModel;
end;

function resolveVoskServiceName(const aSettings: TRecorderSettings): string;
begin
  if SameText(aSettings.Language, 'en') then
    Exit('vosk_en');

  if aSettings.Mode = smCommand then
    Exit('vosk_ru_cmd');

  Result := 'vosk_ru';
end;

function resolveVoskModelName(const aSettings: TRecorderSettings): string;
begin
  if SameText(aSettings.Language, 'en') then
    Exit('vosk-model-en-us-0.42-gigaspeech');

  if aSettings.Mode = smCommand then
    Exit('vosk-model-small-ru-0.22');

  Result := 'vosk-model-ru-0.42';
end;

function resolveVoskDllPath(const aSettings: TRecorderSettings): string;
begin
  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) + 'services' + PathDelim + resolveVoskServiceName(aSettings) + PathDelim + 'venv' + PathDelim + 'Lib' + PathDelim + 'site-packages' + PathDelim + 'vosk' + PathDelim + 'libvosk.dll';
end;

function resolveVoskModelsRoot: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('VOSK_MODELS_ROOT'));
  if Result = '' then
    Result := 'C:\var\vosk';
end;

function resolveVoskModelPath(const aSettings: TRecorderSettings): string;
begin
  Result := IncludeTrailingPathDelimiter(resolveVoskModelsRoot) + resolveVoskModelName(aSettings);
end;

function safeCString(const aValue: PChar): string;
var
  len: SizeInt;
  data: RawByteString;
begin
  Result := '';
  if aValue = nil then
    Exit('');

  len := StrLen(aValue);
  if len <= 0 then
    Exit;

  SetLength(data, len);
  Move(aValue^, data[1], len);
  SetCodePage(data, 65001, False);
  Result := data;
end;

function jsonStringOf(const aObject: TJSONObject; const aName: string): string;
var
  data: TJSONData;
begin
  Result := '';
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsString;
end;

function jsonFloatOf(const aObject: TJSONObject; const aName: string; out aValue: Double): Boolean;
var
  data: TJSONData;
begin
  Result := False;
  aValue := 0;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data = nil) or (data.JSONType = jtNull) then
    Exit;

  try
    aValue := data.AsFloat;
    Result := True;
  except
    Result := False;
  end;
end;

function sampleToMs(aSample: Integer; aSampleRate: Integer): Int64;
begin
  if aSampleRate <= 0 then
    Exit(0);

  Result := Round((aSample * 1000.0) / aSampleRate);
end;

procedure appendTextWithSpace(var aTarget: string; const aValue: string);
var
  value: string;
begin
  value := Trim(aValue);
  if value = '' then
    Exit;

  if aTarget = '' then
    aTarget := value
  else
    aTarget := aTarget + ' ' + value;
end;

procedure appendPartial(
  var aPartials: TVoskPartialEvents;
  const aText: string;
  aStartMs: Int64;
  aEndMs: Int64
);
var
  idx: Integer;
begin
  idx := Length(aPartials);
  SetLength(aPartials, idx + 1);
  aPartials[idx].Text := aText;
  aPartials[idx].StartMs := aStartMs;
  aPartials[idx].EndMs := aEndMs;
end;

procedure appendFragmentEnd(var aSampleEnds: TSampleOffsets; aEndSample: Integer);
var
  idx: Integer;
begin
  if aEndSample <= 0 then
    Exit;

  idx := Length(aSampleEnds);
  if (idx > 0) and (aSampleEnds[idx - 1] = aEndSample) then
    Exit;

  SetLength(aSampleEnds, idx + 1);
  aSampleEnds[idx] := aEndSample;
end;

function checkedSampleCount(aBytesRead: Int64): Integer;
var
  count: Int64;
begin
  count := aBytesRead div SizeOf(SmallInt);
  if count > High(Integer) then
    raise Exception.Create('PCM16LE stream is too large');

  Result := Integer(count);
end;

procedure parsePartialPayload(
  const aJson: string;
  aSampleRate: Integer;
  aFallbackStartSample: Integer;
  aFallbackEndSample: Integer;
  out aText: string;
  out aStartMs: Int64;
  out aEndMs: Int64
);
var
  data: TJSONData;
  root: TJSONObject;
  item: TJSONObject;
  startSec: Double;
  endSec: Double;
  words: TJSONArray;
begin
  aText := '';
  aStartMs := sampleToMs(aFallbackStartSample, aSampleRate);
  aEndMs := sampleToMs(aFallbackEndSample, aSampleRate);

  if Trim(aJson) = '' then
    Exit;

  data := GetJSON(aJson);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    aText := Trim(jsonStringOf(root, 'partial'));
    if aText = '' then
      Exit;

    if (root.Find('partial_result') = nil) or (root.Find('partial_result').JSONType <> jtArray) then
      Exit;

    words := TJSONArray(root.Find('partial_result'));
    if words.Count = 0 then
      Exit;

    if words.Objects[0] <> nil then
    begin
      item := words.Objects[0];
      if jsonFloatOf(item, 'start', startSec) then
        aStartMs := Round(startSec * 1000.0);
    end;

    if words.Objects[words.Count - 1] <> nil then
    begin
      item := words.Objects[words.Count - 1];
      if jsonFloatOf(item, 'end', endSec) then
        aEndMs := Round(endSec * 1000.0);
    end;
  finally
    data.Free;
  end;
end;

function parseTextPayload(const aJson: string; const aFieldName: string): string;
var
  data: TJSONData;
  root: TJSONObject;
begin
  Result := '';
  if Trim(aJson) = '' then
    Exit;

  data := GetJSON(aJson);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    Result := Trim(jsonStringOf(root, aFieldName));
  finally
    data.Free;
  end;
end;

function runLocalRecognition(
  const aSettings: TRecorderSettings;
  const aAudio: TMonoPcmAudio;
  const aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TVoskLocalRun;
var
  acc: Integer;
  len: Integer;
  pos: Integer;
  endMs: Int64;
  startMs: Int64;
  chunkLen: Integer;
  chunkBytes: Integer;
  modelPath: string;
  finalJson: string;
  finalText: string;
  partialJson: string;
  partialText: string;
  resultJson: string;
  resultText: string;
  lastPartial: string;
  processedSamples: Integer;
  lastBoundarySample: Integer;
  modelHandle: PVoskModel;
  recognizerHandle: PVoskRecognizer;
begin
  Result.FinalText := '';
  Result.Partials := nil;
  Result.FragmentEndSamples := nil;
  if (aAudio.SampleRate <= 0) or (Length(aAudio.Samples) = 0) then
    Exit;

  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);

  loadVoskLibrary(resolveVoskDllPath(aSettings));
  modelPath := resolveVoskModelPath(aSettings);
  if not DirectoryExists(modelPath) then
    raise Exception.CreateFmt('Vosk model directory not found: %s', [modelPath]);

  modelHandle := nil;
  recognizerHandle := nil;
  lastBoundarySample := 0;
  lastPartial := '';
  try
    gSetLogLevel(-1);
    modelHandle := getOrCreateCachedModel(modelPath);

    recognizerHandle := gRecognizerNew(modelHandle, aAudio.SampleRate);
    if recognizerHandle = nil then
      raise Exception.Create('vosk_recognizer_new failed');

    gRecognizerSetWords(recognizerHandle, 1);
    gRecognizerSetPartialWords(recognizerHandle, 1);

    len := Length(aAudio.Samples);
    pos := 0;
    while pos < len do
    begin
      chunkLen := PCM_CHUNK_FRAMES;
      if chunkLen > len - pos then
        chunkLen := len - pos;

      chunkBytes := chunkLen * SizeOf(SmallInt);
      acc := gRecognizerAcceptWaveform(recognizerHandle, @aAudio.Samples[pos], chunkBytes);
      if acc < 0 then
        raise Exception.Create('vosk_recognizer_accept_waveform returned a negative status');

      Inc(pos, chunkLen);
      processedSamples := pos;

      if acc = 0 then
      begin
        partialJson := safeCString(gRecognizerPartialResult(recognizerHandle));
        parsePartialPayload(
          partialJson,
          aAudio.SampleRate,
          lastBoundarySample,
          processedSamples,
          partialText,
          startMs,
          endMs
        );

        if (partialText <> '') and (partialText <> lastPartial) then
        begin
          if aProtocol <> nil then
            aProtocol.writeLocalPartial(aItem, partialText, startMs, endMs);
          appendPartial(Result.Partials, partialText, startMs, endMs);
          lastPartial := partialText;
        end;
      end
      else
      begin
        resultJson := safeCString(gRecognizerResult(recognizerHandle));
        resultText := parseTextPayload(resultJson, 'text');
        if resultText <> '' then
        begin
          appendTextWithSpace(Result.FinalText, resultText);
          appendFragmentEnd(Result.FragmentEndSamples, processedSamples);
          lastBoundarySample := processedSamples;
        end;

        lastPartial := '';
      end;
    end;

    finalJson := safeCString(gRecognizerFinalResult(recognizerHandle));
    finalText := parseTextPayload(finalJson, 'text');
    if finalText <> '' then
    begin
      appendTextWithSpace(Result.FinalText, finalText);
      appendFragmentEnd(Result.FragmentEndSamples, len);
    end;
  finally
    if recognizerHandle <> nil then
      gRecognizerFree(recognizerHandle);
  end;
end;

function runLocalPcmStreamRecognition(
  const aSettings: TRecorderSettings;
  var aItem: TRecorderInputItem;
  aProtocol: TRecorderProtocolWriter
): TRecorderResult;
const
  PCM_STREAM_CHUNK_BYTES = 3840;
var
  ok: BOOL;
  acc: Integer;
  err: DWORD;
  len: DWORD;
  endMs: Int64;
  read: DWORD;
  text: string;
  carry: Byte;
  finalJson: string;
  finalText: string;
  lastPartial: string;
  modelPath: string;
  partialJson: string;
  partialText: string;
  resultJson: string;
  resultText: string;
  startMs: Int64;
  carryLen: Integer;
  totalBytes: Int64;
  modelHandle: PVoskModel;
  stdinHandle: THandle;
  lastBoundarySample: Integer;
  processedSamples: Integer;
  recognizerHandle: PVoskRecognizer;
  chunkData: array[0..PCM_STREAM_CHUNK_BYTES] of Byte;
begin
  Result := emptyRecorderResult;
  Result.Ok := True;
  Result.StatusCode := 200;
  Result.ModeName := speechModeLabel(aSettings.Mode);
  Result.Language := aSettings.Language;
  Result.InputPath := aItem.FilePath;
  Result.BackendName := recorderBackendLabel(rbLocalDictation);

  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);

  loadVoskLibrary(resolveVoskDllPath(aSettings));
  modelPath := resolveVoskModelPath(aSettings);
  if not DirectoryExists(modelPath) then
    raise Exception.CreateFmt('Vosk model directory not found: %s', [modelPath]);

  stdinHandle := GetStdHandle(STD_INPUT_HANDLE);
  if stdinHandle = INVALID_HANDLE_VALUE then
    raise Exception.Create('Failed to get stdin handle');

  acc := 0;
  len := 0;
  read := 0;
  carry := 0;
  endMs := 0;
  startMs := 0;
  carryLen := 0;
  totalBytes := 0;
  modelHandle := nil;
  finalJson := '';
  finalText := '';
  lastPartial := '';
  modelPath := resolveVoskModelPath(aSettings);
  partialJson := '';
  partialText := '';
  resultJson := '';
  resultText := '';
  lastBoundarySample := 0;
  processedSamples := 0;
  recognizerHandle := nil;
  try
    gSetLogLevel(-1);
    modelHandle := getOrCreateCachedModel(modelPath);

    recognizerHandle := gRecognizerNew(modelHandle, 16000);
    if recognizerHandle = nil then
      raise Exception.Create('vosk_recognizer_new failed');

    gRecognizerSetWords(recognizerHandle, 1);
    gRecognizerSetPartialWords(recognizerHandle, 1);

    repeat
      if carryLen > 0 then
        chunkData[0] := carry;

      read := 0;
      ok := Windows.ReadFile(
        stdinHandle,
        chunkData[carryLen],
        PCM_STREAM_CHUNK_BYTES - carryLen,
        read,
        nil
      );
      len := read + DWORD(carryLen);

      if len > 0 then
      begin
        if (len mod SizeOf(SmallInt)) <> 0 then
        begin
          carry := chunkData[len - 1];
          carryLen := 1;
          Dec(len);
        end
        else
          carryLen := 0;

        if len > 0 then
        begin
          acc := gRecognizerAcceptWaveform(recognizerHandle, @chunkData[0], len);
          if acc < 0 then
            raise Exception.Create('vosk_recognizer_accept_waveform returned a negative status');

          Inc(totalBytes, len);
          processedSamples := checkedSampleCount(totalBytes);

          if acc = 0 then
          begin
            partialJson := safeCString(gRecognizerPartialResult(recognizerHandle));
            parsePartialPayload(
              partialJson,
              16000,
              lastBoundarySample,
              processedSamples,
              partialText,
              startMs,
              endMs
            );

            if (partialText <> '') and (partialText <> lastPartial) then
            begin
              if aProtocol <> nil then
                aProtocol.writeLocalPartial(aItem, partialText, startMs, endMs);
              lastPartial := partialText;
            end;
          end
          else
          begin
            resultJson := safeCString(gRecognizerResult(recognizerHandle));
            resultText := parseTextPayload(resultJson, 'text');
            if resultText <> '' then
            begin
              appendTextWithSpace(Result.Text, resultText);
              appendTextWithSpace(Result.RawText, resultText);
              appendTextWithSpace(Result.NormalizedText, resultText);
              lastBoundarySample := processedSamples;
            end;

            lastPartial := '';
          end;
        end;
      end;

      if ok and (read = 0) then
        Break;

      if not ok then
      begin
        err := GetLastError();
        if (err = ERROR_BROKEN_PIPE) or (err = ERROR_HANDLE_EOF) then
          Break;

        raise Exception.CreateFmt('Failed to read pcm16le stdin: %d', [err]);
      end;
    until False;

    if carryLen <> 0 then
      raise Exception.Create('PCM16LE stdin ended on an odd byte boundary');

    finalJson := safeCString(gRecognizerFinalResult(recognizerHandle));
    finalText := parseTextPayload(finalJson, 'text');
    if finalText <> '' then
    begin
      appendTextWithSpace(Result.Text, finalText);
      appendTextWithSpace(Result.RawText, finalText);
      appendTextWithSpace(Result.NormalizedText, finalText);
    end;

    aItem.SizeBytes := totalBytes;
  finally
    if recognizerHandle <> nil then
      gRecognizerFree(recognizerHandle);
  end;

  text := Trim(Result.Text);
  if text = '' then
    text := Trim(Result.NormalizedText);
  if text = '' then
    text := Trim(Result.RawText);
  Result.Text := text;
  Result.RawText := text;
  Result.NormalizedText := text;
end;

finalization
  unloadVoskLibrary;

end.