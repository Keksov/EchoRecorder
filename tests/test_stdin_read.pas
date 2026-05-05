program TestStdinRead;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

function readStdIn: TBytes;
const
  CHUNK_SIZE = 65536;
var
  chunk: TBytes;
  stream: TMemoryStream;
  numRead: LongInt;
begin
  stream := TMemoryStream.Create;
  try
    SetLength(chunk, CHUNK_SIZE);
    repeat
      { File descriptor 0 is stdin }
      numRead := FileRead(0, chunk[0], CHUNK_SIZE);
      WriteLn(StdErr, Format('FileRead(0) returned: %d', [numRead]));
      
      if numRead > 0 then
        stream.WriteBuffer(chunk[0], numRead)
      else
        Break;
    until stream.Size > 10000000;  { Safety }

    WriteLn(StdErr, Format('Total bytes read: %d', [stream.Size]));
    
    Result := nil;
    if stream.Size > 0 then
    begin
      SetLength(Result, stream.Size);
      stream.Position := 0;
      stream.ReadBuffer(Result[0], stream.Size);
    end;
  finally
    stream.Free;
  end;
end;

var
  data: TBytes;
begin
  WriteLn(StdErr, 'Starting stdin read...');
  data := readStdIn;
  WriteLn(StdErr, Format('Read %d bytes total', [Length(data)]));
  
  { Write first 100 bytes as hex to stderr for debugging }
  if Length(data) > 0 then
  begin
    WriteLn(StdErr, 'First bytes (hex):');
    for var i := 0 to Min(99, Length(data) - 1) do
      Write(StdErr, Format('%02x ', [data[i]]));
    WriteLn(StdErr, '');
  end;
end.
