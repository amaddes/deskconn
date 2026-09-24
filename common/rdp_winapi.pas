unit rdp_winapi;

{ Обёртки над WinAPI:
  - захват экрана (виртуального, с учётом нескольких мониторов) в сырой буфер BGRA;
  - инъекция мыши и клавиатуры через SendInput;
  - эмуляция Ctrl+Alt+Del через SendSAS (sas.dll, Windows 8+, требует прав и/или политики SoftwareSASGeneration). }

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils, Types;

const
  // Отсутствует в заголовках FPC; значение стандартно для WinAPI (wingdi.h).
  CAPTUREBLT = $40000000;

type
  { Результат захвата экрана: сырые пиксели BGRA, порядок строк - сверху вниз (top-down). }
  TCaptureResult = record
    Width, Height: Integer;
    Data: TBytes;
  end;

// Возвращает прямоугольник всего виртуального экрана (все мониторы) в экранных координатах.
function GetVirtualScreenRect: TRect;

// Захватывает указанную область экрана в сырой буфер 32bpp BGRA (top-down).
// По умолчанию (ARect с нулевой площадью не передан) следует передавать GetVirtualScreenRect.
function CaptureScreenRegion(const ARect: TRect): TCaptureResult;

// Отрисовывает сырой буфер BGRA (top-down, AW*AH*4 байт) в указанный HDC по координатам
// (ALeft, ATop) - используется админом для композиции полученных кадров в offscreen-битмап.
procedure BlitRawBGRA(ADestDC: HDC; ALeft, ATop, AW, AH: Integer; const AData: TBytes);

// ---- Инъекция ввода (SendInput, не устаревший mouse_event/keybd_event) ----

// AX, AY - абсолютные экранные координаты в пространстве виртуального экрана этой машины.
procedure InputSendMouseMove(AX, AY: Integer);
// ABtn: 1=левая, 2=правая, 3=средняя (см. rdp_protocol.MBTN_*).
procedure InputSendMouseButton(ABtn: Byte; ADown: Boolean);
procedure InputSendMouseWheel(ADelta: Integer);
// Виртуальная клавиша Windows (VK_*).
procedure InputSendKey(AVK: Word; ADown: Boolean);
// Непосредственный ввод unicode-символа (используется для KEY_CHAR, не требует знания VK).
procedure InputSendUnicodeChar(ACh: WideChar);

// Попытка эмулировать secure attention sequence через sas.dll. Возвращает True при успешном вызове
// (это не гарантирует, что система показала экран Ctrl+Alt+Del - зависит от политики SoftwareSASGeneration).
function TrySendCtrlAltDel: Boolean;

implementation

function GetVirtualScreenRect: TRect;
var
  L, T, CX, CY: Integer;
begin
  L := GetSystemMetrics(SM_XVIRTUALSCREEN);
  T := GetSystemMetrics(SM_YVIRTUALSCREEN);
  CX := GetSystemMetrics(SM_CXVIRTUALSCREEN);
  CY := GetSystemMetrics(SM_CYVIRTUALSCREEN);
  Result := Types.Rect(L, T, L + CX, T + CY);
end;

function CaptureScreenRegion(const ARect: TRect): TCaptureResult;
var
  ScreenDC, MemDC: HDC;
  BmpHandle: HBITMAP;
  OldBmp: HGDIOBJ;
  BMI: BITMAPINFO;
  W, H: Integer;
begin
  W := ARect.Right - ARect.Left;
  H := ARect.Bottom - ARect.Top;
  Result.Width := W;
  Result.Height := H;
  SetLength(Result.Data, 0);
  if (W <= 0) or (H <= 0) then
    Exit;

  ScreenDC := GetDC(0);
  if ScreenDC = 0 then
    raise Exception.Create('GetDC(0) вернул 0 - не удалось получить контекст экрана');
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    if MemDC = 0 then
      raise Exception.Create('CreateCompatibleDC завершился ошибкой');
    try
      BmpHandle := CreateCompatibleBitmap(ScreenDC, W, H);
      if BmpHandle = 0 then
        raise Exception.Create('CreateCompatibleBitmap завершился ошибкой');
      try
        OldBmp := SelectObject(MemDC, BmpHandle);
        try
          if not BitBlt(MemDC, 0, 0, W, H, ScreenDC, ARect.Left, ARect.Top, SRCCOPY or CAPTUREBLT) then
            raise Exception.Create('BitBlt завершился ошибкой при захвате экрана');

          FillChar(BMI, SizeOf(BMI), 0);
          BMI.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
          BMI.bmiHeader.biWidth := W;
          BMI.bmiHeader.biHeight := -H; // отрицательная высота = top-down DIB
          BMI.bmiHeader.biPlanes := 1;
          BMI.bmiHeader.biBitCount := 32;
          BMI.bmiHeader.biCompression := BI_RGB;

          SetLength(Result.Data, W * H * 4);
          if GetDIBits(MemDC, BmpHandle, 0, H, @Result.Data[0], BMI, DIB_RGB_COLORS) = 0 then
            raise Exception.Create('GetDIBits завершился ошибкой при извлечении пикселей');
        finally
          SelectObject(MemDC, OldBmp);
        end;
      finally
        DeleteObject(BmpHandle);
      end;
    finally
      DeleteDC(MemDC);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

procedure BlitRawBGRA(ADestDC: HDC; ALeft, ATop, AW, AH: Integer; const AData: TBytes);
var
  TempDC: HDC;
  TempBmp: HBITMAP;
  OldBmp: HGDIOBJ;
  BMI: BITMAPINFO;
begin
  if (AW <= 0) or (AH <= 0) or (Length(AData) < AW * AH * 4) then
    Exit;

  TempDC := CreateCompatibleDC(ADestDC);
  if TempDC = 0 then
    raise Exception.Create('CreateCompatibleDC завершился ошибкой (BlitRawBGRA)');
  try
    TempBmp := CreateCompatibleBitmap(ADestDC, AW, AH);
    if TempBmp = 0 then
      raise Exception.Create('CreateCompatibleBitmap завершился ошибкой (BlitRawBGRA)');
    try
      OldBmp := SelectObject(TempDC, TempBmp);
      try
        FillChar(BMI, SizeOf(BMI), 0);
        BMI.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
        BMI.bmiHeader.biWidth := AW;
        BMI.bmiHeader.biHeight := -AH; // top-down, соответствует формату из CaptureScreenRegion
        BMI.bmiHeader.biPlanes := 1;
        BMI.bmiHeader.biBitCount := 32;
        BMI.bmiHeader.biCompression := BI_RGB;

        if SetDIBits(TempDC, TempBmp, 0, AH, @AData[0], BMI, DIB_RGB_COLORS) = 0 then
          raise Exception.Create('SetDIBits завершился ошибкой (BlitRawBGRA)');

        if not BitBlt(ADestDC, ALeft, ATop, AW, AH, TempDC, 0, 0, SRCCOPY) then
          raise Exception.Create('BitBlt завершился ошибкой (BlitRawBGRA)');
      finally
        SelectObject(TempDC, OldBmp);
      end;
    finally
      DeleteObject(TempBmp);
    end;
  finally
    DeleteDC(TempDC);
  end;
end;

// Преобразует абсолютную экранную координату в нормализованную 0..65535 для MOUSEEVENTF_ABSOLUTE.
function NormalizeCoord(AValue, AOrigin, AExtent: Integer): Integer;
begin
  if AExtent <= 1 then
    Result := 0
  else
    Result := Round(((AValue - AOrigin) * 65535.0) / (AExtent - 1));
  if Result < 0 then Result := 0;
  if Result > 65535 then Result := 65535;
end;

procedure SendOneInput(const AInput: TInput);
var
  Arr: array[0..0] of TInput;
begin
  Arr[0] := AInput;
  if SendInput(1, @Arr[0], SizeOf(TInput)) <> 1 then
    raise Exception.CreateFmt('SendInput завершился ошибкой, код %d', [GetLastError]);
end;

procedure InputSendMouseMove(AX, AY: Integer);
var
  Inp: TInput;
  VS: TRect;
begin
  VS := GetVirtualScreenRect;
  FillChar(Inp, SizeOf(Inp), 0);
  Inp._Type := INPUT_MOUSE;
  Inp.mi.dx := NormalizeCoord(AX, VS.Left, VS.Right - VS.Left);
  Inp.mi.dy := NormalizeCoord(AY, VS.Top, VS.Bottom - VS.Top);
  Inp.mi.dwFlags := MOUSEEVENTF_MOVE or MOUSEEVENTF_ABSOLUTE or MOUSEEVENTF_VIRTUALDESK;
  SendOneInput(Inp);
end;

procedure InputSendMouseButton(ABtn: Byte; ADown: Boolean);
var
  Inp: TInput;
begin
  FillChar(Inp, SizeOf(Inp), 0);
  Inp._Type := INPUT_MOUSE;
  case ABtn of
    1: if ADown then Inp.mi.dwFlags := MOUSEEVENTF_LEFTDOWN else Inp.mi.dwFlags := MOUSEEVENTF_LEFTUP;
    2: if ADown then Inp.mi.dwFlags := MOUSEEVENTF_RIGHTDOWN else Inp.mi.dwFlags := MOUSEEVENTF_RIGHTUP;
    3: if ADown then Inp.mi.dwFlags := MOUSEEVENTF_MIDDLEDOWN else Inp.mi.dwFlags := MOUSEEVENTF_MIDDLEUP;
  else
    Exit; // неизвестная кнопка - игнорируем
  end;
  SendOneInput(Inp);
end;

procedure InputSendMouseWheel(ADelta: Integer);
var
  Inp: TInput;
begin
  FillChar(Inp, SizeOf(Inp), 0);
  Inp._Type := INPUT_MOUSE;
  Inp.mi.dwFlags := MOUSEEVENTF_WHEEL;
  Inp.mi.MouseData := DWORD(ADelta);
  SendOneInput(Inp);
end;

procedure InputSendKey(AVK: Word; ADown: Boolean);
var
  Inp: TInput;
begin
  FillChar(Inp, SizeOf(Inp), 0);
  Inp._Type := INPUT_KEYBOARD;
  Inp.ki.wVk := AVK;
  Inp.ki.wScan := Word(MapVirtualKey(AVK, 0));
  if not ADown then
    Inp.ki.dwFlags := KEYEVENTF_KEYUP;
  SendOneInput(Inp);
end;

procedure InputSendUnicodeChar(ACh: WideChar);
var
  DownInp, UpInp: TInput;
  Arr: array[0..1] of TInput;
begin
  FillChar(DownInp, SizeOf(DownInp), 0);
  DownInp._Type := INPUT_KEYBOARD;
  DownInp.ki.wVk := 0;
  DownInp.ki.wScan := Word(Ord(ACh));
  DownInp.ki.dwFlags := KEYEVENTF_UNICODE;

  FillChar(UpInp, SizeOf(UpInp), 0);
  UpInp._Type := INPUT_KEYBOARD;
  UpInp.ki.wVk := 0;
  UpInp.ki.wScan := Word(Ord(ACh));
  UpInp.ki.dwFlags := KEYEVENTF_UNICODE or KEYEVENTF_KEYUP;

  Arr[0] := DownInp;
  Arr[1] := UpInp;
  if SendInput(2, @Arr[0], SizeOf(TInput)) <> 2 then
    raise Exception.CreateFmt('SendInput (unicode) завершился ошибкой, код %d', [GetLastError]);
end;

function TrySendCtrlAltDel: Boolean;
type
  TSendSASProc = procedure(AsUser: BOOL); stdcall;
var
  LibHandle: HMODULE;
  SendSASProc: TSendSASProc;
begin
  Result := False;
  LibHandle := LoadLibrary('sas.dll');
  if LibHandle = 0 then
    Exit(False);
  try
    Pointer(SendSASProc) := GetProcAddress(LibHandle, 'SendSAS');
    if not Assigned(SendSASProc) then
      Exit(False);
    SendSASProc(False);
    Result := True;
  finally
    FreeLibrary(LibHandle);
  end;
end;

end.
