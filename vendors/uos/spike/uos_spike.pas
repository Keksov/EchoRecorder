program uos_spike;

{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  Windows,
  ctypes,
  uos_libsndfile;

type
  TByteChunk = array of Byte;
  TShortChunk = array of SmallInt;

function clampReadCount(const aValue: Tuos_count_t): LongInt;
begin
  if aValue <= 0 then
    Exit(0);

  if aValue > High(LongInt) then
    Exit(High(LongInt));

  Result := LongInt(aValue);
end;

function memGetFileLen(aStream: PMemoryStream): Tuos_count_t; cdecl;
begin
  if aStream = nil then
    Exit(-1);

  Result := aStream^.Size;
end;

function memSeek(aOffset: Tuos_count_t; aWhence: cint; aStream: PMemoryStream): Tuos_count_t; cdecl;
var
  nextPos: Int64;
begin
  if aStream = nil then
    Exit(-1);

  case aWhence of
    SEEK_SET:
      nextPos := aOffset;
    SEEK_CUR:
      nextPos := aStream^.Position + aOffset;
    SEEK_END:
      nextPos := aStream^.Size + aOffset;
  else
    Exit(-1);
  end;

  if (nextPos < 0) or (nextPos > aStream^.Size) then
    Exit(-1);

  aStream^.Position := nextPos;
  Result := aStream^.Position;
end;

function memRead(const aBuffer: Pointer; aCount: Tuos_count_t; aStream: PMemoryStream): Tuos_count_t; cdecl;
var
  readLen: LongInt;
begin
  if (aStream = nil) or (aBuffer = nil) then
    Exit(0);

  readLen := clampReadCount(aCount);
  if readLen = 0 then
    Exit(0);

  Result := aStream^.Read(PByte(aBuffer)^, readLen);
end;

function memWrite(const aBuffer: Pointer; aCount: Tuos_count_t; aStream: PMemoryStream): Tuos_count_t; cdecl;
begin
  Result := 0;
end;

function memTell(aStream: PMemoryStream): Tuos_count_t; cdecl;
begin
  if aStream = nil then
    Exit(-1);

  Result := aStream^.Position;
end;

function resolveAudioPath: string;
begin
  if ParamCount >= 1 then
    Exit(ExpandFileName(ParamStr(1)));

  Result := '';
end;

{ For sf_open_virtual there is no filename to probe from, so the format must be
  set explicitly in SF_INFO.format. For sf_open with a real path the same hint
  bypasses format detection that can fail on some libsndfile builds. }
function formatHintFromExtension(const aPath: string): Integer;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(aPath));
  if ext = '.ogg' then
    Result := SF_FORMAT_OGG or SF_FORMAT_VORBIS
  else if ext = '.flac' then
    Result := SF_FORMAT_FLAC or SF_FORMAT_PCM_16
  else
    Result := 0;  { 0 = let libsndfile autodetect (works for WAV, etc.) }
end;

function resolveLibSndFilePath: string;
begin
  if ParamCount >= 2 then
    Exit(ExpandFileName(ParamStr(2)));

  Result := ExpandFileName(
    ExtractFileDir(ParamStr(0)) + PathDelim + '..' + PathDelim + '..' + PathDelim + 'bin' + PathDelim + 'sndfile.dll'
  );
end;

function safeLibSndFileError: string;
var
  errPtr: PChar;
begin
  Result := '';
  if not Assigned(sf_strerror) then
    Exit;

  errPtr := sf_strerror(nil);
  if errPtr <> nil then
    Result := string(errPtr);
end;

function decodeFromHandle(const aHandle: TSNDFILE_HANDLE; const aInfo: TSF_INFO; out aFrames: Int64; out aChunks: Integer): Boolean;
const
  FRAME_CHUNK = 4096;
var
  bufLen: Integer;
  frames: Tuos_count_t;
  sampleBuf: TShortChunk;
begin
  Result := False;
  aFrames := 0;
  aChunks := 0;

  if aHandle = nil then
    Exit;

  if aInfo.channels > 0 then
    bufLen := FRAME_CHUNK * aInfo.channels
  else
    bufLen := FRAME_CHUNK;

  if bufLen <= 0 then
    Exit;

  SetLength(sampleBuf, bufLen);
  repeat
    frames := sf_readf_short(aHandle, @sampleBuf[0], FRAME_CHUNK);
    if frames < 0 then
      Exit;

    if frames > 0 then
    begin
      Inc(aChunks);
      Inc(aFrames, Int64(frames));
    end;
  until frames = 0;

  Result := True;
end;

function loadStreamInChunks(const aFilePath: string; out aStream: TMemoryStream; out aChunkCount: Integer): Boolean;
const
  READ_CHUNK = 4096;
var
  bytesRead: LongInt;
  sourceFile: TFileStream;
  chunkData: TByteChunk;
begin
  Result := False;
  aChunkCount := 0;
  aStream := TMemoryStream.Create;

  try
    sourceFile := TFileStream.Create(aFilePath, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(chunkData, READ_CHUNK);
      repeat
        bytesRead := sourceFile.Read(chunkData[0], READ_CHUNK);
        if bytesRead > 0 then
        begin
          aStream.WriteBuffer(chunkData[0], bytesRead);
          Inc(aChunkCount);
        end;
      until bytesRead = 0;
    finally
      sourceFile.Free;
    end;

    aStream.Position := 0;
    Result := True;
  except
    FreeAndNil(aStream);
  end;
end;

function copyToTempAudioPath(const aSourcePath: string): string;
var
  sourceFile: TFileStream;
  targetFile: TFileStream;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'uos_spike_input.ogg';
  sourceFile := TFileStream.Create(aSourcePath, fmOpenRead or fmShareDenyWrite);
  try
    targetFile := TFileStream.Create(Result, fmCreate);
    try
      targetFile.CopyFrom(sourceFile, 0);
    finally
      targetFile.Free;
    end;
  finally
    sourceFile.Free;
  end;
end;

procedure failAndExit(const aMessage: string);
begin
  WriteLn('SPIKE_ERROR: ', aMessage);
  Halt(1);
end;

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

var
  audioPath: string;
  sndPath: string;
  fileInfo: TSF_INFO;
  virtualInfo: TSF_INFO;
  streamData: TMemoryStream;
  virtualIO: TSF_VIRTUAL;
  fileHandle: TSNDFILE_HANDLE;
  virtualHandle: TSNDFILE_HANDLE;
  fileFrames: Int64;
  tempAudioPath: string;
  fileChunks: Integer;
  loadChunks: Integer;
  virtualFrames: Int64;
  virtualChunks: Integer;
begin
  audioPath := resolveAudioPath;
  sndPath := resolveLibSndFilePath;
  streamData := nil;
  fileHandle := nil;
  virtualHandle := nil;
  tempAudioPath := '';

  if audioPath = '' then
  begin
    WriteLn('Usage: uos_spike.exe <audio_path> [sndfile_dll_path]');
    Halt(2);
  end;

  if not FileExists(audioPath) then
    failAndExit('Audio file not found: ' + audioPath);

  tempAudioPath := copyToTempAudioPath(audioPath);

  prependDirectoryToPath(ExtractFileDir(sndPath));

  if not sf_Load(sndPath) then
    failAndExit('Failed to load libsndfile from: ' + sndPath);

  if not Assigned(sf_open_virtual) then
    failAndExit('sf_open_virtual is not available in loaded libsndfile');

  FillChar(fileInfo, SizeOf(fileInfo), 0);
  fileInfo.format := formatHintFromExtension(audioPath);
  fileHandle := sf_open(tempAudioPath, SFM_READ, fileInfo);
  if fileHandle = nil then
    failAndExit('sf_open failed: ' + safeLibSndFileError);

  try
    if not decodeFromHandle(fileHandle, fileInfo, fileFrames, fileChunks) then
      failAndExit('Failed to decode file-open path');
  finally
    sf_close(fileHandle);
    fileHandle := nil;
  end;

  if fileChunks <= 0 then
    failAndExit('Decoded zero non-empty PCM chunks in file-open path');

  if not loadStreamInChunks(audioPath, streamData, loadChunks) then
    failAndExit('Failed to load encoded stream chunks');

  FillChar(virtualIO, SizeOf(virtualIO), 0);
  virtualIO.sf_vio_get_filelen := @memGetFileLen;
  virtualIO.seek := @memSeek;
  virtualIO.read := @memRead;
  virtualIO.write := @memWrite;
  virtualIO.tell := @memTell;

  FillChar(virtualInfo, SizeOf(virtualInfo), 0);
  virtualInfo.format := formatHintFromExtension(audioPath);
  virtualHandle := sf_open_virtual(@virtualIO, SFM_READ, @virtualInfo, @streamData);
  if virtualHandle = nil then
    failAndExit('sf_open_virtual failed: ' + safeLibSndFileError);

  try
    if not decodeFromHandle(virtualHandle, virtualInfo, virtualFrames, virtualChunks) then
      failAndExit('Failed to decode virtual-open path');
  finally
    sf_close(virtualHandle);
    virtualHandle := nil;
  end;

  if virtualChunks <= 0 then
    failAndExit('Decoded zero non-empty PCM chunks in virtual-open path');

  WriteLn('SPIKE_RESULT:ok');
  WriteLn('audio_path=', audioPath);
  WriteLn('temp_audio_path=', tempAudioPath);
  WriteLn('sndfile_path=', sndPath);
  WriteLn('sample_rate=', fileInfo.samplerate);
  WriteLn('channels=', fileInfo.channels);
  WriteLn('decoded_frames_file=', fileFrames);
  WriteLn('decoded_chunks_file=', fileChunks);
  WriteLn('loaded_encoded_chunks=', loadChunks);
  WriteLn('decoded_frames_virtual=', virtualFrames);
  WriteLn('decoded_chunks_virtual=', virtualChunks);

  FreeAndNil(streamData);
  if (tempAudioPath <> '') and FileExists(tempAudioPath) then
    SysUtils.DeleteFile(tempAudioPath);
  sf_Unload;
end.
