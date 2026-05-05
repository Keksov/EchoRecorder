unit echo_recorder_core_sinks;

{$mode objfpc}{$H+}

interface

uses
  echo_recorder_core_api;

type
  TStdOutResultSink = class(TRecorderResultSink)
  public
    procedure   writeResult(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aResult: TRecorderResult
    ); override;
  end;

  TJsonFileResultSink = class(TRecorderResultSink)
  public
    procedure   writeResult(
      const aSettings: TRecorderSettings;
      const aItem: TRecorderInputItem;
      const aResult: TRecorderResult
    ); override;
  end;

function    formatResultAsJson(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult
): string;

implementation

uses
  Classes,
  SysUtils,
  fpjson;

procedure saveUtf8Text(const aPath: string; const aText: string);
var
  len: Integer;
  data: UTF8String;
  fileData: TFileStream;
begin
  data := UTF8Encode(UnicodeString(aText));
  fileData := TFileStream.Create(aPath, fmCreate);
  try
    len := Length(data);
    if len > 0 then
      fileData.WriteBuffer(data[1], len);
  finally
    fileData.Free;
  end;
end;

function formatResultAsJson(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult
): string;
var
  fileName: string;
  inputPath: string;
  displayName: string;
  raw: TJSONObject;
  norm: TJSONObject;
  root: TJSONObject;
begin
  inputPath := aResult.InputPath;
  if inputPath = '' then
    inputPath := aItem.FilePath;

  fileName := aItem.FileName;
  if (fileName = '') and (inputPath <> '') then
    fileName := ExtractFileName(inputPath);

  displayName := aItem.DisplayName;
  if (displayName = '') and (fileName <> '') then
    displayName := ChangeFileExt(fileName, '');

  raw := TJSONObject.Create;
  norm := TJSONObject.Create;
  root := TJSONObject.Create;
  try
    raw.Add('text', aResult.RawText);
    norm.Add('text', aResult.NormalizedText);

    root.Add('ok', aResult.Ok);
    root.Add('backend', aResult.BackendName);
    root.Add('mode', aResult.ModeName);
    root.Add('language', aResult.Language);
    root.Add('status_code', aResult.StatusCode);
    root.Add('error_text', aResult.ErrorText);
    root.Add('job_id', aResult.JobId);
    root.Add('text', aResult.Text);
    root.Add('input_path', inputPath);
    root.Add('file_name', fileName);
    root.Add('display_name', displayName);
    root.Add('size_bytes', aItem.SizeBytes);
    root.Add('target_model', aResult.TargetModel);
    root.Add('command_status', aResult.CommandStatus);
    root.Add('response_body', aResult.ResponseBody);
    root.Add('base_url', aSettings.BaseUrl);
    root.Add('output_path', aSettings.OutputPath);
    root.Add('raw', raw);
    root.Add('normalized', norm);
    raw := nil;
    norm := nil;

    Result := root.AsJSON;
  finally
    root.Free;
    norm.Free;
    raw.Free;
  end;
end;

procedure TStdOutResultSink.writeResult(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult
);
begin
  WriteLn(formatResultAsJson(aSettings, aItem, aResult));
end;

procedure TJsonFileResultSink.writeResult(
  const aSettings: TRecorderSettings;
  const aItem: TRecorderInputItem;
  const aResult: TRecorderResult
);
var
  dir: string;
  text: string;
begin
  if Trim(aSettings.OutputPath) = '' then
    raise Exception.Create('Output path is empty for file result sink');

  dir := ExtractFileDir(ExpandFileName(aSettings.OutputPath));
  if (dir <> '') and (not DirectoryExists(dir)) then
    ForceDirectories(dir);

  text := formatResultAsJson(aSettings, aItem, aResult);
  saveUtf8Text(aSettings.OutputPath, text + LineEnding);
end;

end.