program vosk_spike;

{$mode objfpc}{$H+}

uses
  Math,
  SysUtils;

type
  PVoskModel = Pointer;
  PVoskRecognizer = Pointer;
  TSampleBuffer = array of SmallInt;

function vosk_model_new(const aModelPath: PChar): PVoskModel; cdecl; external 'libvosk.dll';
procedure vosk_model_free(aModel: PVoskModel); cdecl; external 'libvosk.dll';
function vosk_recognizer_new(aModel: PVoskModel; aSampleRate: Single): PVoskRecognizer; cdecl; external 'libvosk.dll';
procedure vosk_recognizer_free(aRecognizer: PVoskRecognizer); cdecl; external 'libvosk.dll';
function vosk_recognizer_accept_waveform(aRecognizer: PVoskRecognizer; const aData: Pointer; aLength: Integer): Integer; cdecl; external 'libvosk.dll';
function vosk_recognizer_partial_result(aRecognizer: PVoskRecognizer): PChar; cdecl; external 'libvosk.dll';
function vosk_recognizer_result(aRecognizer: PVoskRecognizer): PChar; cdecl; external 'libvosk.dll';
function vosk_recognizer_final_result(aRecognizer: PVoskRecognizer): PChar; cdecl; external 'libvosk.dll';
procedure vosk_set_log_level(aLevel: Integer); cdecl; external 'libvosk.dll';

function resolveModelPath: string;
begin
  if ParamCount >= 1 then
    Exit(ExpandFileName(ParamStr(1)));

  Result := '';
end;

function resolveSeconds: Integer;
var
  value: Integer;
begin
  Result := 2;
  if ParamCount < 2 then
    Exit;

  if not TryStrToInt(ParamStr(2), value) then
    Exit;

  if value > 0 then
    Result := value;
end;

function safeCString(const aValue: PChar): string;
begin
  if aValue = nil then
    Exit('');

  Result := string(aValue);
end;

procedure failAndRaise(const aMessage: string);
begin
  raise Exception.Create(aMessage);
end;

const
  SAMPLE_RATE = 16000;
  CHUNK_FRAMES = 4000;

var
  offset: Integer;
  seconds: Integer;
  accepted: Integer;
  sampleCount: Integer;
  chunkBytes: Integer;
  modelPath: string;
  totalBytes: Integer;
  remainingBytes: Integer;
  modelHandle: PVoskModel;
  recognizerHandle: PVoskRecognizer;
  pcmSamples: TSampleBuffer;
  partialJson: string;
  resultJson: string;
  finalJson: string;
  exitCode: Integer;
begin
  modelPath := resolveModelPath;
  seconds := resolveSeconds;
  modelHandle := nil;
  recognizerHandle := nil;
  partialJson := '';
  resultJson := '';
  finalJson := '';
  exitCode := 0;

  if modelPath = '' then
  begin
    WriteLn('Usage: vosk_spike.exe <model_path> [seconds]');
    Halt(2);
  end;

  if not DirectoryExists(modelPath) then
  begin
    WriteLn('SPIKE_ERROR: Model directory not found: ', modelPath);
    Halt(1);
  end;

  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);

  try
    vosk_set_log_level(-1);

    modelHandle := vosk_model_new(PChar(modelPath));
    if modelHandle = nil then
      failAndRaise('vosk_model_new failed');

    recognizerHandle := vosk_recognizer_new(modelHandle, SAMPLE_RATE);
    if recognizerHandle = nil then
      failAndRaise('vosk_recognizer_new failed');

    sampleCount := SAMPLE_RATE * seconds;
    if sampleCount <= 0 then
      failAndRaise('Invalid sample count');

    SetLength(pcmSamples, sampleCount);
    FillChar(pcmSamples[0], sampleCount * SizeOf(SmallInt), 0);

    totalBytes := sampleCount * SizeOf(SmallInt);
    offset := 0;

    while offset < totalBytes do
    begin
      remainingBytes := totalBytes - offset;
      chunkBytes := CHUNK_FRAMES * SizeOf(SmallInt);
      if chunkBytes > remainingBytes then
        chunkBytes := remainingBytes;

      accepted := vosk_recognizer_accept_waveform(
        recognizerHandle,
        Pointer(PByte(@pcmSamples[0]) + offset),
        chunkBytes
      );

      if accepted < 0 then
        failAndRaise('vosk_recognizer_accept_waveform returned negative status');

      if accepted = 0 then
        partialJson := safeCString(vosk_recognizer_partial_result(recognizerHandle))
      else
        resultJson := safeCString(vosk_recognizer_result(recognizerHandle));

      Inc(offset, chunkBytes);
    end;

    finalJson := safeCString(vosk_recognizer_final_result(recognizerHandle));

    WriteLn('SPIKE_RESULT:ok');
    WriteLn('model_path=', modelPath);
    WriteLn('sample_rate=', SAMPLE_RATE);
    WriteLn('seconds=', seconds);
    WriteLn('pcm_bytes=', totalBytes);
    WriteLn('partial_json=', partialJson);
    WriteLn('result_json=', resultJson);
    WriteLn('final_json=', finalJson);
  except
    on E: Exception do
    begin
      WriteLn('SPIKE_ERROR: ', E.Message);
      exitCode := 1;
    end;
  end;

  if recognizerHandle <> nil then
    vosk_recognizer_free(recognizerHandle);
  if modelHandle <> nil then
    vosk_model_free(modelHandle);

  Halt(exitCode);
end.
