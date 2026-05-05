unit echo_recorder_core_transport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  echo_recorder_core_api;

type
  THttpSpeechTransport = class(TRecorderTransport)
  public
    function    recognize(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem
    ): TRecorderResult; override;
    function    recognizeBytes(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aAudioBytes: TBytes
    ): TRecorderResult; override;
  end;

implementation

uses
  Classes,
  fpjson,
  jsonparser,
  fphttpclient,
  echo_recorder_core_sources;

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

function jsonObjectOf(const aObject: TJSONObject; const aName: string): TJSONObject;
var
  data: TJSONData;
begin
  Result := nil;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType = jtObject) then
    Result := TJSONObject(data);
end;

function normalizeBaseUrl(const aBaseUrl: string): string;
begin
  Result := Trim(aBaseUrl);
  if Result = '' then
    Result := 'http://127.0.0.1:3000';

  while (Length(Result) > 0) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

function utf8StringFromStream(const aStream: TMemoryStream): string;
var
  data: RawByteString;
  len: Integer;
begin
  Result := '';
  data := '';
  len := aStream.Size;
  if len = 0 then
    Exit;

  SetLength(data, len);
  aStream.Position := 0;
  aStream.ReadBuffer(data[1], len);
  SetCodePage(data, 65001, False);
  Result := data;
end;

procedure populateRecorderResult(const aBody: string; var aResult: TRecorderResult);
var
  data: TJSONData;
  norm: TJSONObject;
  root: TJSONObject;
  raw: TJSONObject;
begin
  if Trim(aBody) = '' then
    Exit;

  data := GetJSON(aBody);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    raw := jsonObjectOf(root, 'raw');
    norm := jsonObjectOf(root, 'normalized');

    aResult.JobId := jsonStringOf(root, 'job_id');
    aResult.ModeName := jsonStringOf(root, 'mode');
    aResult.Language := jsonStringOf(root, 'language');
    aResult.TargetModel := jsonStringOf(root, 'target_model');
    aResult.CommandStatus := jsonStringOf(root, 'command_status');
    aResult.Text := jsonStringOf(root, 'text');
    aResult.RawText := jsonStringOf(raw, 'text');
    aResult.NormalizedText := jsonStringOf(norm, 'text');
  finally
    data.Free;
  end;
end;

function THttpSpeechTransport.recognizeBytes(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aAudioBytes: TBytes
): TRecorderResult;
var
  url: string;
  data: TMemoryStream;
  text: TMemoryStream;
  client: TFPHTTPClient;
begin
  Result := emptyRecorderResult;
  Result.ModeName := speechModeToApiValue(aSettings.Mode);
  Result.Language := aSettings.Language;
  Result.InputPath := aItem.FilePath;
  Result.BackendName := recorderBackendLabel(rbTransport);

  url := Format(
    '%s/api/v2/speech/recognize?mode=%s&language=%s&speaker_embeddings=%s',
    [
      normalizeBaseUrl(aSettings.BaseUrl),
      Result.ModeName,
      aSettings.Language,
      BoolToStr(aSettings.SpeakerEmbeddings, 'true', 'false')
    ]
  );

  if Length(aAudioBytes) = 0 then
    raise Exception.CreateFmt('Audio fixture is empty: %s', [aItem.FilePath]);

  client := TFPHTTPClient.Create(nil);
  data := TMemoryStream.Create;
  text := TMemoryStream.Create;
  try
    data.WriteBuffer(aAudioBytes[0], Length(aAudioBytes));
    data.Position := 0;

    client.AllowRedirect := True;
    client.AddHeader('Accept', 'application/json');
    client.AddHeader('User-Agent', 'EchoRecorder/0.1');
    client.AddHeader('Content-Type', 'application/octet-stream');
    client.RequestBody := data;

    try
      client.Post(url, text);
    except
      on E: Exception do
        Result.ErrorText := E.Message;
    end;

    Result.StatusCode := client.ResponseStatusCode;
    Result.ResponseBody := utf8StringFromStream(text);
    Result.Ok := (Result.ErrorText = '') and (Result.StatusCode >= 200) and (Result.StatusCode < 300);

    if Result.ResponseBody <> '' then
    begin
      try
        populateRecorderResult(Result.ResponseBody, Result);
      except
        on E: Exception do
          if Result.ErrorText = '' then
            Result.ErrorText := 'Failed to parse JSON response: ' + E.Message;
      end;
    end;

    if (not Result.Ok) and (Result.ErrorText = '') then
    begin
      if Result.ResponseBody <> '' then
        Result.ErrorText := Result.ResponseBody
      else
        Result.ErrorText := Format('Speech request failed with HTTP %d', [Result.StatusCode]);
    end;

    if Result.ModeName = '' then
      Result.ModeName := speechModeLabel(aSettings.Mode);
    if Result.Language = '' then
      Result.Language := aSettings.Language;
    if Result.BackendName = '' then
      Result.BackendName := recorderBackendLabel(rbTransport);
    if Result.InputPath = '' then
      Result.InputPath := aItem.FilePath;
  finally
    text.Free;
    data.Free;
    client.Free;
  end;
end;

function THttpSpeechTransport.recognize(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem
): TRecorderResult;
var
  body: TBytes;
begin
  body := readInputItemBytes(aItem);
  Result := recognizeBytes(aSettings, aItem, body);
end;

end.