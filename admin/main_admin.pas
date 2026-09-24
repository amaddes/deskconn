unit main_admin;

{ Главная форма rdp_admin.exe: подключение к rdp_client, отображение удалённого
  экрана (offscreen-битмап из frame_receiver, без мерцания), статистика сессии,
  переключение масштаба, полноэкранного режима и инъекция ввода мыши/клавиатуры
  (через input_sender, с учётом масштаба и режима "только просмотр"). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Menus, Spin, ComCtrls, IniFiles, LCLType, LCLIntf, Types,
  rdp_protocol, frame_receiver, input_sender;

type
  TAdminScaleMode = (smFit, sm100, smFree);

  { TfrmAdmin }

  TfrmAdmin = class(TForm)
    btnConnect: TButton;
    cbRemember: TCheckBox;
    cbViewOnly: TCheckBox;
    edIP: TEdit;
    edPassword: TEdit;
    lblIP: TLabel;
    lblPassword: TLabel;
    lblPort: TLabel;
    lblStatus: TLabel;
    MainMenu1: TMainMenu;
    MenuCtrlAltDel: TMenuItem;
    MenuFullscreen: TMenuItem;
    MenuScale: TMenuItem;
    MenuScaleFit: TMenuItem;
    MenuScaleFree: TMenuItem;
    MenuScale100: TMenuItem;
    MenuActions: TMenuItem;
    MenuView: TMenuItem;
    PaintBox1: TPaintBox;
    PanelTop: TPanel;
    sePort: TSpinEdit;
    StatusBar1: TStatusBar;
    procedure btnConnectClick(Sender: TObject);
    procedure cbViewOnlyClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MenuCtrlAltDelClick(Sender: TObject);
    procedure MenuFullscreenClick(Sender: TObject);
    procedure MenuScaleFitClick(Sender: TObject);
    procedure MenuScaleFreeClick(Sender: TObject);
    procedure MenuScale100Click(Sender: TObject);
    procedure PaintBox1Paint(Sender: TObject);
    procedure PaintBox1MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure PaintBox1MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PaintBox1MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure PaintBox1MouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
  private
    FReceiver: TFrameReceiverThread;
    FInputSender: TInputSender;
    FScaleMode: TAdminScaleMode;
    FIsFullscreen: Boolean;
    FPrevBorderStyle: TFormBorderStyle;
    FPrevWindowState: TWindowState;
    FPrevBoundsRect: TRect;
    FLastFPS, FLastBitrateKBs: Double;
    FLastLatencyMs: Integer;
    // Возвращает прямоугольник внутри PaintBox1, в который вписывается изображение
    // при текущем режиме масштаба - используется и для отрисовки, и для обратного
    // пересчёта координат мыши в систему offscreen-битмапа.
    function GetDisplayRect(ASrcW, ASrcH: Integer): TRect;
    // Переводит координаты мыши (в пикселях PaintBox1) в координаты offscreen-битмапа
    // с учётом текущего масштаба; False, если координата вне изображения (только для Fit).
    function MousePosToBitmap(AX, AY: Integer; out ABitmapX, ABitmapY: Integer): Boolean;
    procedure HandleLog(const AMsg: string);
    procedure HandleState(AState: TConnState; const AMsg: string);
    procedure HandleFrame;
    procedure HandleStats(AFPS, ABitrateKBs: Double; AWidth, AHeight, ALatencyMs: Integer);
    procedure Connect;
    procedure Disconnect;
    procedure LoadLastConnection;
    procedure SaveLastConnection;
    procedure SetScaleMode(AMode: TAdminScaleMode);
    procedure UpdateScaleMenuChecks;
    function GetIniPath: string;
  end;

var
  frmAdmin: TfrmAdmin;

implementation

{$R *.lfm}

procedure TfrmAdmin.FormCreate(Sender: TObject);
begin
  FScaleMode := smFit;
  KeyPreview := True;
  LoadLastConnection;
  UpdateScaleMenuChecks;
  lblStatus.Caption := 'Не подключено';
end;

procedure TfrmAdmin.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  Disconnect;
end;

function TfrmAdmin.GetIniPath: string;
var
  Dir: string;
begin
  Dir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) + 'RDPAdmin';
  if not DirectoryExists(Dir) then
    ForceDirectories(Dir);
  Result := IncludeTrailingPathDelimiter(Dir) + 'last.ini';
end;

procedure TfrmAdmin.LoadLastConnection;
var
  Ini: TIniFile;
begin
  if not FileExists(GetIniPath) then Exit;
  Ini := TIniFile.Create(GetIniPath);
  try
    edIP.Text := Ini.ReadString('Connection', 'IP', '127.0.0.1');
    sePort.Value := Ini.ReadInteger('Connection', 'Port', 5555);
    cbRemember.Checked := Ini.ReadBool('Connection', 'Remember', False);
    if cbRemember.Checked then
      edPassword.Text := Ini.ReadString('Connection', 'Password', '');
  finally
    Ini.Free;
  end;
end;

procedure TfrmAdmin.SaveLastConnection;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(GetIniPath);
  try
    Ini.WriteString('Connection', 'IP', edIP.Text);
    Ini.WriteInteger('Connection', 'Port', sePort.Value);
    Ini.WriteBool('Connection', 'Remember', cbRemember.Checked);
    if cbRemember.Checked then
      Ini.WriteString('Connection', 'Password', edPassword.Text)
    else
      Ini.DeleteKey('Connection', 'Password');
  finally
    Ini.Free;
  end;
end;

procedure TfrmAdmin.btnConnectClick(Sender: TObject);
begin
  if FReceiver = nil then
    Connect
  else
    Disconnect;
end;

procedure TfrmAdmin.Connect;
begin
  SaveLastConnection;
  btnConnect.Enabled := False;
  FReceiver := TFrameReceiverThread.Create(edIP.Text, Word(sePort.Value), edPassword.Text,
    @HandleLog, @HandleState, @HandleFrame, @HandleStats);
  FInputSender := TInputSender.Create(FReceiver);
  FInputSender.ViewOnly := cbViewOnly.Checked;
  FReceiver.Start;
end;

procedure TfrmAdmin.Disconnect;
begin
  FreeAndNil(FInputSender);
  if FReceiver <> nil then
  begin
    FReceiver.ForceDisconnect;
    FReceiver.WaitFor;
    FreeAndNil(FReceiver);
  end;
  btnConnect.Caption := 'Подключиться';
  btnConnect.Enabled := True;
  lblStatus.Caption := 'Не подключено';
  StatusBar1.Panels[0].Text := 'FPS: -';
  StatusBar1.Panels[1].Text := 'Битрейт: -';
  StatusBar1.Panels[2].Text := 'Разрешение: -';
  StatusBar1.Panels[3].Text := 'Задержка: -';
  PaintBox1.Invalidate;
end;

procedure TfrmAdmin.HandleLog(const AMsg: string);
begin
  lblStatus.Caption := AMsg;
end;

procedure TfrmAdmin.HandleState(AState: TConnState; const AMsg: string);
begin
  lblStatus.Caption := AMsg;
  case AState of
    csConnecting:
      ; // кнопка уже отключена в Connect
    csConnected:
      begin
        btnConnect.Caption := 'Отключиться';
        btnConnect.Enabled := True;
      end;
    csAuthFailed, csBusy, csError, csDisconnected:
      begin
        // поток сам скоро завершится (или уже завершается) - откладываем реальный
        // разрыв на Disconnect, вызываемый пользователем или FormClose, но кнопку
        // возвращаем в исходное состояние сразу, чтобы не блокировать UI.
        btnConnect.Caption := 'Подключиться';
        btnConnect.Enabled := True;
      end;
  end;
end;

procedure TfrmAdmin.HandleFrame;
begin
  PaintBox1.Invalidate;
end;

procedure TfrmAdmin.HandleStats(AFPS, ABitrateKBs: Double; AWidth, AHeight, ALatencyMs: Integer);
begin
  FLastFPS := AFPS;
  FLastBitrateKBs := ABitrateKBs;
  FLastLatencyMs := ALatencyMs;
  StatusBar1.Panels[0].Text := Format('FPS: %.0f', [AFPS]);
  StatusBar1.Panels[1].Text := Format('Битрейт: %.0f КБ/с', [ABitrateKBs]);
  StatusBar1.Panels[2].Text := Format('Разрешение: %dx%d', [AWidth, AHeight]);
  StatusBar1.Panels[3].Text := Format('Задержка: %d мс', [ALatencyMs]);
end;

function TfrmAdmin.GetDisplayRect(ASrcW, ASrcH: Integer): TRect;
var
  Scale, ScaleX, ScaleY: Double;
  DrawW, DrawH: Integer;
begin
  case FScaleMode of
    sm100:
      begin
        Result := Rect(0, 0, ASrcW, ASrcH);
        if Result.Right > PaintBox1.Width then Result.Right := PaintBox1.Width;
        if Result.Bottom > PaintBox1.Height then Result.Bottom := PaintBox1.Height;
      end;
    smFree:
      Result := PaintBox1.ClientRect;
  else // smFit
    begin
      ScaleX := PaintBox1.Width / ASrcW;
      ScaleY := PaintBox1.Height / ASrcH;
      if ScaleX < ScaleY then Scale := ScaleX else Scale := ScaleY;
      if Scale <= 0 then Scale := 1;
      DrawW := Round(ASrcW * Scale);
      DrawH := Round(ASrcH * Scale);
      Result := Rect(0, 0, DrawW, DrawH);
      OffsetRect(Result, (PaintBox1.Width - DrawW) div 2, (PaintBox1.Height - DrawH) div 2);
    end;
  end;
end;

function TfrmAdmin.MousePosToBitmap(AX, AY: Integer; out ABitmapX, ABitmapY: Integer): Boolean;
var
  SrcW, SrcH: Integer;
  DestRect: TRect;
begin
  Result := False;
  ABitmapX := 0;
  ABitmapY := 0;
  if FReceiver = nil then Exit;

  FReceiver.LockBitmap;
  try
    SrcW := FReceiver.Offscreen.Width;
    SrcH := FReceiver.Offscreen.Height;
  finally
    FReceiver.UnlockBitmap;
  end;
  if (SrcW <= 0) or (SrcH <= 0) then Exit;

  DestRect := GetDisplayRect(SrcW, SrcH);
  if (AX < DestRect.Left) or (AX >= DestRect.Right) or (AY < DestRect.Top) or (AY >= DestRect.Bottom) then
    Exit; // курсор вне отображаемого изображения (чёрные поля при масштабе "по размеру окна")

  if FScaleMode = sm100 then
  begin
    ABitmapX := AX - DestRect.Left;
    ABitmapY := AY - DestRect.Top;
  end
  else // smFit, smFree - равномерное растяжение всего DestRect на весь битмап
  begin
    ABitmapX := Round((AX - DestRect.Left) * SrcW / DestRect.Width);
    ABitmapY := Round((AY - DestRect.Top) * SrcH / DestRect.Height);
  end;

  if ABitmapX < 0 then ABitmapX := 0;
  if ABitmapX >= SrcW then ABitmapX := SrcW - 1;
  if ABitmapY < 0 then ABitmapY := 0;
  if ABitmapY >= SrcH then ABitmapY := SrcH - 1;
  Result := True;
end;

procedure TfrmAdmin.PaintBox1Paint(Sender: TObject);
var
  SrcW, SrcH: Integer;
  DestRect: TRect;
begin
  PaintBox1.Canvas.Brush.Color := clBlack;
  PaintBox1.Canvas.FillRect(PaintBox1.ClientRect);

  if FReceiver = nil then Exit;

  FReceiver.LockBitmap;
  try
    SrcW := FReceiver.Offscreen.Width;
    SrcH := FReceiver.Offscreen.Height;
    if (SrcW <= 0) or (SrcH <= 0) then Exit;

    DestRect := GetDisplayRect(SrcW, SrcH);
    if FScaleMode = sm100 then
      PaintBox1.Canvas.CopyRect(DestRect, FReceiver.Offscreen.Canvas, DestRect)
    else
      PaintBox1.Canvas.StretchDraw(DestRect, FReceiver.Offscreen);
  finally
    FReceiver.UnlockBitmap;
  end;
end;

procedure TfrmAdmin.PaintBox1MouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  BX, BY: Integer;
begin
  if FInputSender = nil then Exit;
  if MousePosToBitmap(X, Y, BX, BY) then
    FInputSender.MouseMove(BX, BY);
end;

procedure TfrmAdmin.PaintBox1MouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Btn: Byte;
begin
  // TPaintBox - не оконный контрол (TGraphicControl) и не может получать фокус сам по себе,
  // но это и не нужно: KeyPreview=True у формы уже перехватывает клавиатуру независимо
  // от того, какой дочерний контрол "в фокусе".
  if FInputSender = nil then Exit;
  case Button of
    mbLeft: Btn := MBTN_LEFT;
    mbRight: Btn := MBTN_RIGHT;
    mbMiddle: Btn := MBTN_MIDDLE;
  else
    Exit;
  end;
  FInputSender.MouseButton(Btn, True);
end;

procedure TfrmAdmin.PaintBox1MouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  Btn: Byte;
begin
  if FInputSender = nil then Exit;
  case Button of
    mbLeft: Btn := MBTN_LEFT;
    mbRight: Btn := MBTN_RIGHT;
    mbMiddle: Btn := MBTN_MIDDLE;
  else
    Exit;
  end;
  FInputSender.MouseButton(Btn, False);
end;

procedure TfrmAdmin.PaintBox1MouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint; var Handled: Boolean);
begin
  if FInputSender <> nil then
  begin
    FInputSender.MouseWheel(WheelDelta);
    Handled := True;
  end;
end;

procedure TfrmAdmin.SetScaleMode(AMode: TAdminScaleMode);
begin
  FScaleMode := AMode;
  UpdateScaleMenuChecks;
  PaintBox1.Invalidate;
end;

procedure TfrmAdmin.UpdateScaleMenuChecks;
begin
  MenuScaleFit.Checked := FScaleMode = smFit;
  MenuScale100.Checked := FScaleMode = sm100;
  MenuScaleFree.Checked := FScaleMode = smFree;
end;

procedure TfrmAdmin.MenuScaleFitClick(Sender: TObject);
begin
  SetScaleMode(smFit);
end;

procedure TfrmAdmin.MenuScale100Click(Sender: TObject);
begin
  SetScaleMode(sm100);
end;

procedure TfrmAdmin.MenuScaleFreeClick(Sender: TObject);
begin
  SetScaleMode(smFree);
end;

procedure TfrmAdmin.MenuFullscreenClick(Sender: TObject);
begin
  if not FIsFullscreen then
  begin
    FPrevBorderStyle := BorderStyle;
    FPrevWindowState := WindowState;
    FPrevBoundsRect := BoundsRect;
    BorderStyle := bsNone;
    WindowState := wsMaximized;
    FIsFullscreen := True;
  end
  else
  begin
    BorderStyle := FPrevBorderStyle;
    WindowState := FPrevWindowState;
    if FPrevWindowState = wsNormal then
      BoundsRect := FPrevBoundsRect;
    FIsFullscreen := False;
  end;
end;

procedure TfrmAdmin.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F11 then
  begin
    MenuFullscreenClick(Sender);
    Key := 0;
    Exit;
  end;
  // LCL на Win32-виджетсете передаёт в Key нативный VK_*-код Windows напрямую,
  // поэтому таблица трансляции (MapVirtualKey) не нужна - в отличие от кроссплатформенных
  // сборок LCL, где потребовалось бы явное сопоставление.
  if FInputSender <> nil then
    FInputSender.KeyDown(Key);
end;

procedure TfrmAdmin.FormKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F11 then Exit;
  if FInputSender <> nil then
    FInputSender.KeyUp(Key);
end;

procedure TfrmAdmin.MenuCtrlAltDelClick(Sender: TObject);
begin
  if (FInputSender <> nil) and not cbViewOnly.Checked then
    FInputSender.SendCtrlAltDel
  else
    lblStatus.Caption := 'Ctrl+Alt+Del недоступен: нет подключения или включён режим "только просмотр"';
end;

procedure TfrmAdmin.cbViewOnlyClick(Sender: TObject);
begin
  if FInputSender <> nil then
    FInputSender.ViewOnly := cbViewOnly.Checked;
end;

end.
