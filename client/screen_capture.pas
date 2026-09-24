unit screen_capture;

{ TScreenCapturer - захват виртуального экрана с определением изменившейся области.
  Сравнение выполняется построчно через CRC32 (crc32 из стандартного пакета hash).
  Строка считается изменившейся, если её CRC32 отличается от CRC32 той же строки
  в последнем ОТПРАВЛЕННОМ кадре (а не просто предыдущем захвате) - это не даёт
  накопленным мелким изменениям "теряться" между кадрами. Кадр возвращается только
  если доля изменившихся пикселей (количество изменившихся строк * ширина) относительно
  общего числа пикселей не меньше CHANGE_THRESHOLD_PERCENT. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Types, crc, rdp_winapi;

const
  CHANGE_THRESHOLD_PERCENT = 0.5;

type
  TScreenCapturer = class
  private
    FPrevPixels: TBytes;
    FPrevRowCRC: array of Cardinal;
    FHasPrev: Boolean;
    FVSRect: TRect;
    FWidth, FHeight: Integer;
    function RowCRC(const AData: TBytes; ARowIndex: Integer): Cardinal;
  public
    constructor Create;
    // Захватывает экран и возвращает True, если есть что отправлять (см. правила выше).
    // AX/AY - координаты изменившейся области в системе виртуального экрана,
    // AW/AH - её размер, APixels - сырые BGRA-пиксели этой области (top-down).
    function CaptureIfChanged(out AX, AY, AW, AH: Integer; out APixels: TBytes): Boolean;
    // Сбрасывает "последний отправленный кадр" - следующий захват будет отправлен целиком.
    // Нужно вызывать при новом подключении, чтобы админ сразу получил полную картинку.
    procedure Reset;
    property VirtualScreenRect: TRect read FVSRect;
  end;

implementation

constructor TScreenCapturer.Create;
begin
  inherited Create;
  FHasPrev := False;
end;

procedure TScreenCapturer.Reset;
begin
  FHasPrev := False;
  SetLength(FPrevPixels, 0);
  SetLength(FPrevRowCRC, 0);
end;

function TScreenCapturer.RowCRC(const AData: TBytes; ARowIndex: Integer): Cardinal;
var
  RowBytes: Integer;
  Offset: Integer;
begin
  RowBytes := FWidth * 4;
  Offset := ARowIndex * RowBytes;
  Result := crc32(crc32(0, nil, 0), @AData[Offset], RowBytes);
end;

function TScreenCapturer.CaptureIfChanged(out AX, AY, AW, AH: Integer; out APixels: TBytes): Boolean;
var
  Cap: TCaptureResult;
  NewRowCRC: array of Cardinal;
  i, MinRow, MaxRow, ChangedRows: Integer;
  RowBytes: Integer;
  Percent: Double;
begin
  Result := False;
  AX := 0; AY := 0; AW := 0; AH := 0;
  SetLength(APixels, 0);

  FVSRect := GetVirtualScreenRect;
  Cap := CaptureScreenRegion(FVSRect);
  if (Cap.Width <= 0) or (Cap.Height <= 0) then
    Exit; // нечего захватывать (все мониторы выключены/недоступны - не должно происходить)

  // Смена разрешения (или первый захват) - считаем предыдущий кадр недействительным.
  if (not FHasPrev) or (Cap.Width <> FWidth) or (Cap.Height <> FHeight) then
  begin
    FWidth := Cap.Width;
    FHeight := Cap.Height;
    AX := FVSRect.Left;
    AY := FVSRect.Top;
    AW := FWidth;
    AH := FHeight;
    APixels := Cap.Data;

    SetLength(FPrevRowCRC, FHeight);
    for i := 0 to FHeight - 1 do
      FPrevRowCRC[i] := RowCRC(Cap.Data, i);
    FPrevPixels := Cap.Data;
    FHasPrev := True;
    Result := True;
    Exit;
  end;

  SetLength(NewRowCRC, FHeight);
  MinRow := -1;
  MaxRow := -1;
  ChangedRows := 0;
  for i := 0 to FHeight - 1 do
  begin
    NewRowCRC[i] := RowCRC(Cap.Data, i);
    if NewRowCRC[i] <> FPrevRowCRC[i] then
    begin
      Inc(ChangedRows);
      if MinRow = -1 then MinRow := i;
      MaxRow := i;
    end;
  end;

  if ChangedRows = 0 then
    Exit(False); // полностью идентичный кадр

  Percent := (ChangedRows * FWidth) * 100.0 / (FWidth * FHeight);
  if Percent < CHANGE_THRESHOLD_PERCENT then
    Exit(False); // изменения слишком незначительны - не тратим трафик

  RowBytes := FWidth * 4;
  AX := FVSRect.Left;
  AY := FVSRect.Top + MinRow;
  AW := FWidth;
  AH := MaxRow - MinRow + 1;

  SetLength(APixels, AH * RowBytes);
  Move(Cap.Data[MinRow * RowBytes], APixels[0], AH * RowBytes);

  FPrevPixels := Cap.Data;
  FPrevRowCRC := NewRowCRC;
  Result := True;
end;

end.
