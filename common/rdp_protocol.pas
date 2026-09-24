unit rdp_protocol;

{ Единый протокол обмена данными между rdp_client и rdp_admin.
  Формат пакета: [Size:uint32 LE][Type:byte][Payload:bytes].
  Size - размер Payload (без учёта байта Type). Все целые числа - little-endian. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  // Магическая последовательность рукопожатия и версия протокола.
  RDP_MAGIC: array[0..3] of Byte = (Ord('R'), Ord('D'), Ord('P'), Ord('1'));
  RDP_PROTOCOL_VERSION = 1;

  // Ограничение на размер полезной нагрузки одного пакета (защита от некорректного/вредоносного заголовка).
  RDP_MAX_PAYLOAD_SIZE = 64 * 1024 * 1024;

  // Размер соли рукопожатия и хэша пароля.
  RDP_SALT_SIZE = 8;
  RDP_HASH_SIZE = 32;

  // Типы пакетов.
  PT_HELLO       = $01;
  PT_AUTH_RESP   = $02;
  PT_AUTH_OK     = $03;
  PT_AUTH_FAIL   = $04;
  PT_FRAME_UPDATE= $05;
  // Соль рукопожатия (сервер -> админ). Явно не перечислена в базовом списке типов ТЗ,
  // но необходима, чтобы полностью описанный в разделе 1 handshake (magic/соль/хэш)
  // укладывался в единый формат кадра [Size][Type][Payload] без специальных "сырых" веток.
  PT_SALT        = $06;
  PT_MOUSE_MOVE  = $10;
  PT_MOUSE_BTN   = $11;
  PT_MOUSE_WHEEL = $12;
  PT_KEY_DOWN    = $13;
  PT_KEY_UP      = $14;
  PT_KEY_CHAR    = $15;
  // Запрос на секретную комбинацию внимания (Ctrl+Alt+Del) - не входит в список ТЗ явно,
  // но необходима, т.к. реальный Ctrl+Alt+Del нельзя синтезировать через SendInput/VK-события
  // (перехватывается на уровне ОС) - клиент обязан вызывать отдельно SendSAS (rdp_winapi).
  PT_SAS         = $16;
  PT_PING        = $20;
  PT_PONG        = $21;
  PT_BUSY        = $30;
  PT_DISCONNECT  = $FF;

  // Коды кнопок мыши.
  MBTN_LEFT   = 1;
  MBTN_RIGHT  = 2;
  MBTN_MIDDLE = 3;

  // Коды кодеков кадра.
  CODEC_RAW  = 0;
  CODEC_RLE  = 1;
  CODEC_ZLIB = 2;

type
  { Заголовок обновления кадра экрана. }
  TFrameHeader = record
    X, Y, W, H: Int32;
    CompressedSize: UInt32;
    Codec: Byte;
  end;

  TMouseMoveMsg = record
    X, Y: Int32;
  end;

  TMouseBtnMsg = record
    Btn: Byte;
    Down: Byte;
  end;

  TMouseWheelMsg = record
    Delta: Int16;
  end;

  TKeyMsg = record
    VK: UInt16;
  end;

  { Исключение при получении некорректного/битого пакета. }
  ERdpProtocolError = class(Exception);

// ---- Примитивы little-endian ----
procedure PutUInt16LE(AStream: TStream; AValue: UInt16);
procedure PutInt16LE(AStream: TStream; AValue: Int16);
procedure PutUInt32LE(AStream: TStream; AValue: UInt32);
procedure PutInt32LE(AStream: TStream; AValue: Int32);
function GetUInt16LE(AStream: TStream): UInt16;
function GetInt16LE(AStream: TStream): Int16;
function GetUInt32LE(AStream: TStream): UInt32;
function GetInt32LE(AStream: TStream): Int32;

// Чтение ровно ACount байт из потока; исключение при преждевременном закрытии.
procedure ReadExact(AStream: TStream; var ABuf; ACount: Integer);

// ---- Пакеты ----
// Записывает пакет целиком (заголовок + payload) в поток.
procedure WritePacket(AStream: TStream; APacketType: Byte; const APayload: TBytes);
// Записывает пакет без полезной нагрузки (например PING, AUTH_OK).
procedure WriteEmptyPacket(AStream: TStream; APacketType: Byte);
// Читает пакет из потока. Возвращает False, если поток закрыт корректно (0 байт прочитано на старте).
function ReadPacket(AStream: TStream; out APacketType: Byte; out APayload: TBytes): Boolean;

// ---- Кодирование полезных нагрузок конкретных команд ----
function EncodeFrameHeader(const AHeader: TFrameHeader): TBytes;
function DecodeFrameHeader(const AData: TBytes): TFrameHeader;

function EncodeMouseMove(AX, AY: Int32): TBytes;
function DecodeMouseMove(const AData: TBytes): TMouseMoveMsg;

function EncodeMouseBtn(ABtn: Byte; ADown: Boolean): TBytes;
function DecodeMouseBtn(const AData: TBytes): TMouseBtnMsg;

function EncodeMouseWheel(ADelta: Int16): TBytes;
function DecodeMouseWheel(const AData: TBytes): TMouseWheelMsg;

function EncodeKey(AVK: UInt16): TBytes;
function DecodeKey(const AData: TBytes): TKeyMsg;

function EncodeKeyChar(const AUtf8: UTF8String): TBytes;
function DecodeKeyChar(const AData: TBytes): UTF8String;

// Склеивает два байтовых массива (например заголовок кадра + сырые/сжатые пиксели)
// в единый payload для WritePacket.
function ConcatBytes(const A, B: TBytes): TBytes;

implementation

procedure PutUInt16LE(AStream: TStream; AValue: UInt16);
var
  Buf: array[0..1] of Byte;
begin
  Buf[0] := Byte(AValue and $FF);
  Buf[1] := Byte((AValue shr 8) and $FF);
  AStream.WriteBuffer(Buf, SizeOf(Buf));
end;

procedure PutInt16LE(AStream: TStream; AValue: Int16);
begin
  PutUInt16LE(AStream, UInt16(AValue));
end;

procedure PutUInt32LE(AStream: TStream; AValue: UInt32);
var
  Buf: array[0..3] of Byte;
begin
  Buf[0] := Byte(AValue and $FF);
  Buf[1] := Byte((AValue shr 8) and $FF);
  Buf[2] := Byte((AValue shr 16) and $FF);
  Buf[3] := Byte((AValue shr 24) and $FF);
  AStream.WriteBuffer(Buf, SizeOf(Buf));
end;

procedure PutInt32LE(AStream: TStream; AValue: Int32);
begin
  PutUInt32LE(AStream, UInt32(AValue));
end;

function GetUInt16LE(AStream: TStream): UInt16;
var
  Buf: array[0..1] of Byte;
begin
  ReadExact(AStream, Buf, SizeOf(Buf));
  Result := UInt16(Buf[0]) or (UInt16(Buf[1]) shl 8);
end;

function GetInt16LE(AStream: TStream): Int16;
begin
  Result := Int16(GetUInt16LE(AStream));
end;

function GetUInt32LE(AStream: TStream): UInt32;
var
  Buf: array[0..3] of Byte;
begin
  ReadExact(AStream, Buf, SizeOf(Buf));
  Result := UInt32(Buf[0]) or (UInt32(Buf[1]) shl 8) or
            (UInt32(Buf[2]) shl 16) or (UInt32(Buf[3]) shl 24);
end;

function GetInt32LE(AStream: TStream): Int32;
begin
  Result := Int32(GetUInt32LE(AStream));
end;

procedure ReadExact(AStream: TStream; var ABuf; ACount: Integer);
var
  Got, Total: Integer;
  P: PByte;
begin
  if ACount = 0 then Exit;
  // Один вызов Read (особенно у сокетов) может вернуть меньше байт, чем запрошено,
  // даже если соединение живо и остаток данных придёт следующим TCP-сегментом -
  // поэтому докручиваем чтение в цикле, а не считаем частичный Read обрывом связи.
  Total := 0;
  P := PByte(@ABuf);
  while Total < ACount do
  begin
    Got := AStream.Read(P[Total], ACount - Total);
    if Got <= 0 then
      raise ERdpProtocolError.CreateFmt('Разрыв соединения при чтении данных (ожидалось %d, получено %d)', [ACount, Total]);
    Inc(Total, Got);
  end;
end;

// Аналог ReadExact для записи: один вызов Write у сокета тоже не обязан принять
// весь буфер за раз (особенно для больших сжатых/RAW-кадров), поэтому докручиваем в цикле.
procedure WriteExact(AStream: TStream; const ABuf; ACount: Integer);
var
  Got, Total: Integer;
  P: PByte;
begin
  if ACount = 0 then Exit;
  Total := 0;
  P := PByte(@ABuf);
  while Total < ACount do
  begin
    Got := AStream.Write(P[Total], ACount - Total);
    if Got <= 0 then
      raise ERdpProtocolError.CreateFmt('Разрыв соединения при записи данных (записано %d из %d)', [Total, ACount]);
    Inc(Total, Got);
  end;
end;

procedure WritePacket(AStream: TStream; APacketType: Byte; const APayload: TBytes);
begin
  PutUInt32LE(AStream, UInt32(Length(APayload)));
  WriteExact(AStream, APacketType, 1);
  if Length(APayload) > 0 then
    WriteExact(AStream, APayload[0], Length(APayload));
end;

procedure WriteEmptyPacket(AStream: TStream; APacketType: Byte);
var
  Empty: TBytes;
begin
  SetLength(Empty, 0);
  WritePacket(AStream, APacketType, Empty);
end;

function ReadPacket(AStream: TStream; out APacketType: Byte; out APayload: TBytes): Boolean;
var
  Size: UInt32;
  FirstByte: array[0..3] of Byte;
  Got: Integer;
begin
  APacketType := 0;
  SetLength(APayload, 0);
  Result := False;

  // Пытаемся прочитать первый байт размера - если соединение закрыто штатно, Read вернёт 0.
  Got := AStream.Read(FirstByte[0], 1);
  if Got = 0 then
    Exit(False);
  if Got <> 1 then
    raise ERdpProtocolError.Create('Разрыв соединения при чтении заголовка пакета');

  ReadExact(AStream, FirstByte[1], 3);
  Size := UInt32(FirstByte[0]) or (UInt32(FirstByte[1]) shl 8) or
          (UInt32(FirstByte[2]) shl 16) or (UInt32(FirstByte[3]) shl 24);

  if Size > RDP_MAX_PAYLOAD_SIZE then
    raise ERdpProtocolError.CreateFmt('Слишком большой пакет: %d байт', [Size]);

  ReadExact(AStream, APacketType, 1);

  SetLength(APayload, Size);
  if Size > 0 then
    ReadExact(AStream, APayload[0], Size);

  Result := True;
end;

function EncodeFrameHeader(const AHeader: TFrameHeader): TBytes;
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    PutInt32LE(MS, AHeader.X);
    PutInt32LE(MS, AHeader.Y);
    PutInt32LE(MS, AHeader.W);
    PutInt32LE(MS, AHeader.H);
    PutUInt32LE(MS, AHeader.CompressedSize);
    MS.WriteBuffer(AHeader.Codec, 1);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
    begin
      MS.Position := 0;
      MS.ReadBuffer(Result[0], MS.Size);
    end;
  finally
    MS.Free;
  end;
end;

function DecodeFrameHeader(const AData: TBytes): TFrameHeader;
var
  MS: TMemoryStream;
begin
  if Length(AData) < 21 then
    raise ERdpProtocolError.Create('Некорректный заголовок кадра');
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AData[0], Length(AData));
    MS.Position := 0;
    Result.X := GetInt32LE(MS);
    Result.Y := GetInt32LE(MS);
    Result.W := GetInt32LE(MS);
    Result.H := GetInt32LE(MS);
    Result.CompressedSize := GetUInt32LE(MS);
    ReadExact(MS, Result.Codec, 1);
  finally
    MS.Free;
  end;
end;

function EncodeMouseMove(AX, AY: Int32): TBytes;
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    PutInt32LE(MS, AX);
    PutInt32LE(MS, AY);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

function DecodeMouseMove(const AData: TBytes): TMouseMoveMsg;
var
  MS: TMemoryStream;
begin
  if Length(AData) < 8 then
    raise ERdpProtocolError.Create('Некорректный пакет MOUSE_MOVE');
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AData[0], Length(AData));
    MS.Position := 0;
    Result.X := GetInt32LE(MS);
    Result.Y := GetInt32LE(MS);
  finally
    MS.Free;
  end;
end;

function EncodeMouseBtn(ABtn: Byte; ADown: Boolean): TBytes;
begin
  SetLength(Result, 2);
  Result[0] := ABtn;
  if ADown then
    Result[1] := 1
  else
    Result[1] := 0;
end;

function DecodeMouseBtn(const AData: TBytes): TMouseBtnMsg;
begin
  if Length(AData) < 2 then
    raise ERdpProtocolError.Create('Некорректный пакет MOUSE_BTN');
  Result.Btn := AData[0];
  Result.Down := AData[1];
end;

function EncodeMouseWheel(ADelta: Int16): TBytes;
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    PutInt16LE(MS, ADelta);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

function DecodeMouseWheel(const AData: TBytes): TMouseWheelMsg;
var
  MS: TMemoryStream;
begin
  if Length(AData) < 2 then
    raise ERdpProtocolError.Create('Некорректный пакет MOUSE_WHEEL');
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AData[0], Length(AData));
    MS.Position := 0;
    Result.Delta := GetInt16LE(MS);
  finally
    MS.Free;
  end;
end;

function EncodeKey(AVK: UInt16): TBytes;
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    PutUInt16LE(MS, AVK);
    SetLength(Result, MS.Size);
    MS.Position := 0;
    MS.ReadBuffer(Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

function DecodeKey(const AData: TBytes): TKeyMsg;
var
  MS: TMemoryStream;
begin
  if Length(AData) < 2 then
    raise ERdpProtocolError.Create('Некорректный пакет KEY');
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(AData[0], Length(AData));
    MS.Position := 0;
    Result.VK := GetUInt16LE(MS);
  finally
    MS.Free;
  end;
end;

function EncodeKeyChar(const AUtf8: UTF8String): TBytes;
begin
  SetLength(Result, Length(AUtf8));
  if Length(AUtf8) > 0 then
    Move(AUtf8[1], Result[0], Length(AUtf8));
end;

function DecodeKeyChar(const AData: TBytes): UTF8String;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

function ConcatBytes(const A, B: TBytes): TBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

end.
