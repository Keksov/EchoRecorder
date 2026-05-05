unit echo_recorder_core_sources;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  echo_recorder_core_api;

type
  TFileInputSource = class(TRecorderInputSource)
  private
    Fdone                   : Boolean;
    Fitem                   : TRecorderInputItem;
  public
    constructor Create(const aSettings: TRecorderSettings);
    function    next(out aItem: TRecorderInputItem): Boolean; override;
  end;

function    formatInputItemSize(aSizeBytes: Int64): string;
function    loadAudioFixtures(const aTestsDir: string): TRecorderInputItems;
function    readInputItemBytes(const aItem: TRecorderInputItem): TBytes;
function    resolveSourceItem(const aSettings: TRecorderSettings): TRecorderInputItem;

implementation

uses
  Classes
  {$ifdef MSWINDOWS}
  , Windows
  {$endif};

function getInputItemSize(const aPath: string): Int64;
var
  data: TFileStream;
begin
  data := TFileStream.Create(aPath, fmOpenRead or fmShareDenyNone);
  try
    Result := data.Size;
  finally
    data.Free;
  end;
end;

function createInputItemFromFilePath(const aPath: string): TRecorderInputItem;
var
  path: string;
begin
  path := ExpandFileName(aPath);
  if not FileExists(path) then
    raise Exception.CreateFmt('Audio fixture not found: %s', [path]);

  Result.DisplayName := ChangeFileExt(ExtractFileName(path), '');
  Result.FileName := ExtractFileName(path);
  Result.FilePath := path;
  Result.SizeBytes := getInputItemSize(path);
end;

function formatInputItemSize(aSizeBytes: Int64): string;
begin
  if aSizeBytes >= 1024 * 1024 then
    Result := Format('%.1f MB', [aSizeBytes / (1024 * 1024)])
  else if aSizeBytes >= 1024 then
    Result := Format('%.1f KB', [aSizeBytes / 1024])
  else
    Result := Format('%d B', [aSizeBytes]);
end;

function loadAudioFixtures(const aTestsDir: string): TRecorderInputItems;
var
  idx: Integer;
  code: Integer;
  list: TStringList;
  path: string;
  scan: TSearchRec;
begin
  Result := nil;
  if not DirectoryExists(aTestsDir) then
    Exit;

  list := TStringList.Create;
  try
    code := SysUtils.FindFirst(IncludeTrailingPathDelimiter(aTestsDir) + '*.ogg',
      faAnyFile, scan);
    if code = 0 then
    begin
      try
        repeat
          if (scan.Attr and faDirectory) = 0 then
            list.Add(scan.Name);
          code := SysUtils.FindNext(scan);
        until code <> 0;
      finally
        SysUtils.FindClose(scan);
      end;
    end;

    list.Sort;
    SetLength(Result, list.Count);
    for idx := 0 to list.Count - 1 do
    begin
      path := IncludeTrailingPathDelimiter(aTestsDir) + list[idx];
      Result[idx] := createInputItemFromFilePath(path);
    end;
  finally
    list.Free;
  end;
end;

function readStdInBytes(out aTotalRead: Integer): TBytes;
const
  CHUNK_SIZE = 8192;
var
  ok: BOOL;
  err: DWORD;
  len: Int64;
  buf: array[0..CHUNK_SIZE - 1] of Byte;
  read: DWORD;
  stream: TMemoryStream;
  stdinHandle: THandle;
begin
  Result := nil;
  aTotalRead := 0;

  {$ifdef MSWINDOWS}
  stdinHandle := GetStdHandle(STD_INPUT_HANDLE);
  if stdinHandle = INVALID_HANDLE_VALUE then
    raise Exception.Create('Failed to get stdin handle.');

  stream := TMemoryStream.Create;
  try
    repeat
      read := 0;
      ok := Windows.ReadFile(stdinHandle, buf, SizeOf(buf), read, nil);
      if read > 0 then
        stream.WriteBuffer(buf, read);

      if ok and (read = 0) then
        Break;

      if not ok then
      begin
        err := GetLastError();
        if (err = ERROR_BROKEN_PIPE) or (err = ERROR_HANDLE_EOF) then
          Break;

        raise Exception.CreateFmt('Failed to read stdin: %d', [err]);
      end;
    until False;

    len := stream.Size;
    if len > High(Integer) then
      raise Exception.Create('Audio input from stdin is too large.');

    aTotalRead := Integer(len);
    if aTotalRead > 0 then
    begin
      SetLength(Result, aTotalRead);
      stream.Position := 0;
      stream.ReadBuffer(Result[0], aTotalRead);
    end;
  finally
    stream.Free;
  end;
  {$else}
  raise Exception.Create('stdin pipe input is currently supported only on Windows.');
  {$endif}
end;

function readInputItemBytes(const aItem: TRecorderInputItem): TBytes;
var
  len: Integer;
  size: Int64;
  data: TFileStream;
  totalRead: Integer;
begin
  Result := nil;

  { Special marker for stdin source }
  if aItem.FilePath = '<<STDIN>>' then
  begin
    Result := readStdInBytes(totalRead);
    Exit;
  end;

  if not FileExists(aItem.FilePath) then
    raise Exception.CreateFmt('Audio fixture not found: %s', [aItem.FilePath]);

  data := TFileStream.Create(aItem.FilePath, fmOpenRead or fmShareDenyNone);
  try
    size := data.Size;
    if size > High(Integer) then
      raise Exception.CreateFmt('Audio fixture is too large: %s', [aItem.FilePath]);

    len := size;
    SetLength(Result, len);
    if len > 0 then
      data.ReadBuffer(Result[0], len);
  finally
    data.Free;
  end;
end;

function resolveSourceItem(const aSettings: TRecorderSettings): TRecorderInputItem;
var
  list: TRecorderInputItems;
  path: string;
begin
  path := Trim(aSettings.InputFilePath);

  { stdin marker: -i - }
  if path = '-' then
  begin
    Result.DisplayName := '<stdin>';
    Result.FileName := '-';
    Result.FilePath := '<<STDIN>>';
    Result.SizeBytes := 0;  { unknown for stdin }
    Exit;
  end;

  if path <> '' then
    Exit(createInputItemFromFilePath(path));

  list := loadAudioFixtures(aSettings.TestsDir);
  if Length(list) = 0 then
    raise Exception.CreateFmt('No prerecorded .ogg fixtures found under %s', [aSettings.TestsDir]);

  Result := list[0];
end;

constructor TFileInputSource.Create(const aSettings: TRecorderSettings);
begin
  inherited Create;
  Fdone := False;
  Fitem := resolveSourceItem(aSettings);
end;

function TFileInputSource.next(out aItem: TRecorderInputItem): Boolean;
begin
  Result := not Fdone;
  if not Result then
    Exit;

  aItem := Fitem;
  Fdone := True;
end;

end.