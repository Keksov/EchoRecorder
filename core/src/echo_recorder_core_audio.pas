unit echo_recorder_core_audio;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TSampleOffsets = array of Integer;

  TMonoPcmAudio = record
    SampleRate: Integer;
    Samples: array of SmallInt;
  end;

  TAudioFragment = record
    Index: Integer;
    StartSample: Integer;
    EndSample: Integer;
    WavBytes: TBytes;
  end;

  TAudioFragments = array of TAudioFragment;

function    decodeEncodedAudioBytes(const aEncodedBytes: TBytes; const aFormatHint: string): TMonoPcmAudio;
function    createFragmentsFromSampleEnds(
  const aAudio: TMonoPcmAudio;
  const aSampleEnds: TSampleOffsets
): TAudioFragments;
function    slicePcmAsWavBytes(
  const aAudio: TMonoPcmAudio;
  aStartSample: Integer;
  aEndSample: Integer
): TBytes;

implementation

uses
  Classes,
  Windows,
  ctypes,
  uos_libsndfile,
  echo_recorder_core_paths;

const
  FRAME_CHUNK = 4096;

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

function resolveLibSndFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(getRepoRootDir) + 'vendors' + PathDelim + 'uos' + PathDelim + 'bin' + PathDelim + 'sndfile.dll';
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

function formatHintFromInputFormat(const aFormatHint: string): Integer;
var
  formatHint: string;
begin
  formatHint := LowerCase(Trim(aFormatHint));
  if formatHint = 'ogg' then
    Exit(SF_FORMAT_OGG or SF_FORMAT_VORBIS);

  if formatHint = 'flac' then
    Exit(SF_FORMAT_FLAC or SF_FORMAT_PCM_16);

  Result := 0;
end;

procedure writeAsciiText(aStream: TMemoryStream; const aText: AnsiString);
begin
  if Length(aText) > 0 then
    aStream.WriteBuffer(aText[1], Length(aText));
end;

procedure writeUInt16LE(aStream: TMemoryStream; aValue: Word);
begin
  aStream.WriteBuffer(aValue, SizeOf(aValue));
end;

procedure writeUInt32LE(aStream: TMemoryStream; aValue: LongWord);
begin
  aStream.WriteBuffer(aValue, SizeOf(aValue));
end;

function sampleCountOf(const aAudio: TMonoPcmAudio): Integer;
begin
  Result := Length(aAudio.Samples);
end;

function clampSampleIndex(aValue: Integer; aMinValue: Integer; aMaxValue: Integer): Integer;
begin
  Result := aValue;
  if Result < aMinValue then
    Result := aMinValue;
  if Result > aMaxValue then
    Result := aMaxValue;
end;

function slicePcmAsWavBytes(
  const aAudio: TMonoPcmAudio;
  aStartSample: Integer;
  aEndSample: Integer
): TBytes;
var
  dataSize: LongWord;
  sampleLen: Integer;
  stream: TMemoryStream;
begin
  Result := nil;
  if aAudio.SampleRate <= 0 then
    raise Exception.Create('Decoded audio sample rate is not set');

  sampleLen := sampleCountOf(aAudio);
  aStartSample := clampSampleIndex(aStartSample, 0, sampleLen);
  aEndSample := clampSampleIndex(aEndSample, aStartSample, sampleLen);
  dataSize := LongWord((aEndSample - aStartSample) * SizeOf(SmallInt));

  stream := TMemoryStream.Create;
  try
    writeAsciiText(stream, 'RIFF');
    writeUInt32LE(stream, 36 + dataSize);
    writeAsciiText(stream, 'WAVE');
    writeAsciiText(stream, 'fmt ');
    writeUInt32LE(stream, 16);
    writeUInt16LE(stream, 1);
    writeUInt16LE(stream, 1);
    writeUInt32LE(stream, LongWord(aAudio.SampleRate));
    writeUInt32LE(stream, LongWord(aAudio.SampleRate * SizeOf(SmallInt)));
    writeUInt16LE(stream, SizeOf(SmallInt));
    writeUInt16LE(stream, 16);
    writeAsciiText(stream, 'data');
    writeUInt32LE(stream, dataSize);

    if dataSize > 0 then
      stream.WriteBuffer(aAudio.Samples[aStartSample], dataSize);

    SetLength(Result, stream.Size);
    if stream.Size > 0 then
    begin
      stream.Position := 0;
      stream.ReadBuffer(Result[0], stream.Size);
    end;
  finally
    stream.Free;
  end;
end;

function decodeEncodedAudioBytes(const aEncodedBytes: TBytes; const aFormatHint: string): TMonoPcmAudio;
type
  TSmallIntDynArray = array of SmallInt;
var
  sum: Int64;
  ch: Integer;
  len: Integer;
  cap: Integer;
  pos: Integer;
  info: TSF_INFO;
  mono: TSmallIntDynArray;
  frame: Integer;
  frames: Integer;
  streamData: TMemoryStream;
  sampleBuf: array of SmallInt;
  virtualIO: TSF_VIRTUAL;
  sndPath: string;
  handle: TSNDFILE_HANDLE;
  readFrames: Tuos_count_t;
begin
  Result.SampleRate := 0;
  Result.Samples := nil;

  if Length(aEncodedBytes) = 0 then
    raise Exception.Create('Audio input is empty');

  sndPath := resolveLibSndFilePath;
  if not FileExists(sndPath) then
    raise Exception.CreateFmt('sndfile.dll not found: %s', [sndPath]);

  prependDirectoryToPath(ExtractFileDir(sndPath));
  if not sf_Load(sndPath) then
    raise Exception.CreateFmt('Failed to load libsndfile from: %s', [sndPath]);

  streamData := TMemoryStream.Create;
  handle := nil;
  try
    if not Assigned(sf_open_virtual) then
      raise Exception.Create('sf_open_virtual is unavailable in loaded libsndfile');

    streamData.WriteBuffer(aEncodedBytes[0], Length(aEncodedBytes));
    streamData.Position := 0;

    FillChar(virtualIO, SizeOf(virtualIO), 0);
    virtualIO.sf_vio_get_filelen := @memGetFileLen;
    virtualIO.seek := @memSeek;
    virtualIO.read := @memRead;
    virtualIO.write := @memWrite;
    virtualIO.tell := @memTell;

    FillChar(info, SizeOf(info), 0);
    info.format := formatHintFromInputFormat(aFormatHint);
    handle := sf_open_virtual(@virtualIO, SFM_READ, @info, @streamData);
    if handle = nil then
      raise Exception.CreateFmt('sf_open_virtual failed: %s', [safeLibSndFileError]);

    if info.samplerate <= 0 then
      raise Exception.Create('Decoded audio sample rate is invalid');
    if info.channels <= 0 then
      raise Exception.Create('Decoded audio channel count is invalid');

    Result.SampleRate := info.samplerate;
    len := 0;
    cap := 0;
    if (info.frames > 0) and (info.frames <= High(Integer)) then
    begin
      cap := Integer(info.frames);
      SetLength(mono, cap);
    end;

    SetLength(sampleBuf, FRAME_CHUNK * info.channels);
    repeat
      readFrames := sf_readf_short(handle, @sampleBuf[0], FRAME_CHUNK);
      if readFrames < 0 then
        raise Exception.CreateFmt('Failed to decode PCM frames: %s', [safeLibSndFileError]);

      frames := Integer(readFrames);
      if frames = 0 then
        Break;

      if len + frames > cap then
      begin
        if cap = 0 then
          cap := 1024;
        while cap < len + frames do
          cap := cap * 2;
        SetLength(mono, cap);
      end;

      for frame := 0 to frames - 1 do
      begin
        sum := 0;
        pos := frame * info.channels;
        for ch := 0 to info.channels - 1 do
          Inc(sum, sampleBuf[pos + ch]);
        mono[len + frame] := SmallInt(sum div info.channels);
      end;

      Inc(len, frames);
    until False;

    SetLength(mono, len);
    Result.Samples := mono;
  finally
    if handle <> nil then
      sf_close(handle);
    streamData.Free;
    sf_Unload;
  end;
end;

procedure appendFragment(
  var aFragments: TAudioFragments;
  const aAudio: TMonoPcmAudio;
  aStartSample: Integer;
  aEndSample: Integer
);
var
  idx: Integer;
begin
  if aEndSample <= aStartSample then
    Exit;

  idx := Length(aFragments);
  SetLength(aFragments, idx + 1);
  aFragments[idx].Index := idx + 1;
  aFragments[idx].StartSample := aStartSample;
  aFragments[idx].EndSample := aEndSample;
  aFragments[idx].WavBytes := slicePcmAsWavBytes(aAudio, aStartSample, aEndSample);
end;

function createFragmentsFromSampleEnds(
  const aAudio: TMonoPcmAudio;
  const aSampleEnds: TSampleOffsets
): TAudioFragments;
var
  idx: Integer;
  last: Integer;
  next: Integer;
  total: Integer;
begin
  Result := nil;
  total := sampleCountOf(aAudio);
  if total <= 0 then
    Exit;

  last := 0;
  for idx := 0 to High(aSampleEnds) do
  begin
    next := clampSampleIndex(aSampleEnds[idx], last, total);
    appendFragment(Result, aAudio, last, next);
    last := next;
  end;

  if last < total then
    appendFragment(Result, aAudio, last, total);
end;

end.