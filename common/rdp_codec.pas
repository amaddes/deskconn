unit rdp_codec;

{ Кодеки для передачи кадра экрана:
  - RLE по 4-байтовым пикселям (BGRA);
  - zlib-сжатие через чистый Pascal-порт paszlib (без внешних DLL).
  Сервер (rdp_client) сам решает, какой кодек выгоднее, и передаёт его код в заголовке кадра. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, zbase, zcompres, zuncompr;

// ---- RLE по 4-байтовым пикселям ----
// APixelData должен содержать APixelCount*4 байт (BGRA). Возвращает сжатые данные
// в виде последовательности записей [RunLen:UInt16 LE][Pixel:4 байта].
function RLEEncode(const APixelData: TBytes; APixelCount: Integer): TBytes;
// Разворачивает RLE-данные обратно в APixelCount*4 байт. Бросает исключение при некорректных данных.
function RLEDecode(const AData: TBytes; APixelCount: Integer): TBytes;

// ---- zlib (paszlib, чистый Pascal) ----
function ZlibCompressBytes(const AData: TBytes; ALevel: Integer = Z_DEFAULT_COMPRESSION): TBytes;
function ZlibDecompressBytes(const AData: TBytes; AOutputSize: Integer): TBytes;

implementation

function RLEEncode(const APixelData: TBytes; APixelCount: Integer): TBytes;
var
  Capacity, OutLen: Integer;
  i, RunStart: Integer;
  RunLen: Integer;
  procedure EnsureCapacity(AAdditional: Integer);
  begin
    if OutLen + AAdditional > Capacity then
    begin
      while OutLen + AAdditional > Capacity do
        Capacity := Capacity * 2;
      SetLength(Result, Capacity);
    end;
  end;
  procedure EmitRun(APixelIndex: Integer; ALen: Integer);
  var
    Chunk: Integer;
  begin
    while ALen > 0 do
    begin
      if ALen > 65535 then
        Chunk := 65535
      else
        Chunk := ALen;
      EnsureCapacity(6);
      Result[OutLen]   := Byte(Chunk and $FF);
      Result[OutLen+1] := Byte((Chunk shr 8) and $FF);
      Move(APixelData[APixelIndex*4], Result[OutLen+2], 4);
      Inc(OutLen, 6);
      Dec(ALen, Chunk);
    end;
  end;
begin
  Capacity := 4096;
  SetLength(Result, Capacity);
  OutLen := 0;
  if APixelCount = 0 then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  RunStart := 0;
  RunLen := 1;
  for i := 1 to APixelCount - 1 do
  begin
    if CompareByte(APixelData[i*4], APixelData[RunStart*4], 4) = 0 then
      Inc(RunLen)
    else
    begin
      EmitRun(RunStart, RunLen);
      RunStart := i;
      RunLen := 1;
    end;
  end;
  EmitRun(RunStart, RunLen);
  SetLength(Result, OutLen);
end;

function RLEDecode(const AData: TBytes; APixelCount: Integer): TBytes;
var
  Pos, OutPos: Integer;
  RunLen, k: Integer;
begin
  SetLength(Result, APixelCount * 4);
  Pos := 0;
  OutPos := 0;
  while Pos < Length(AData) do
  begin
    if Pos + 6 > Length(AData) then
      raise Exception.Create('RLE: повреждённые данные (неполная запись)');
    RunLen := AData[Pos] or (AData[Pos+1] shl 8);
    if OutPos + RunLen * 4 > Length(Result) then
      raise Exception.Create('RLE: выход за границы буфера декодирования');
    for k := 0 to RunLen - 1 do
    begin
      Move(AData[Pos+2], Result[OutPos], 4);
      Inc(OutPos, 4);
    end;
    Inc(Pos, 6);
  end;
  if OutPos <> Length(Result) then
    raise Exception.Create('RLE: итоговый размер не совпадает с ожидаемым');
end;

function ZlibCompressBytes(const AData: TBytes; ALevel: Integer): TBytes;
var
  DestLen: Cardinal;
  Err: Integer;
  SrcLen: Cardinal;
begin
  if Length(AData) = 0 then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  SrcLen := Cardinal(Length(AData));
  DestLen := SrcLen + (SrcLen div 1000) + 128;
  SetLength(Result, DestLen);
  Err := zcompres.compress2(@Result[0], DestLen, AData, SrcLen, ALevel);
  if Err <> Z_OK then
    raise Exception.CreateFmt('Ошибка сжатия zlib, код %d', [Err]);
  SetLength(Result, DestLen);
end;

function ZlibDecompressBytes(const AData: TBytes; AOutputSize: Integer): TBytes;
var
  DestLen: Cardinal;
  Err: Integer;
begin
  if AOutputSize = 0 then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  DestLen := Cardinal(AOutputSize);
  SetLength(Result, DestLen);
  Err := zuncompr.uncompress(@Result[0], DestLen, AData, Cardinal(Length(AData)));
  if Err <> Z_OK then
    raise Exception.CreateFmt('Ошибка распаковки zlib, код %d', [Err]);
  SetLength(Result, DestLen);
end;

end.
