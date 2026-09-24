unit main_client;

{ Главная форма rdp_client.exe: настройки порта/пароля, старт/стоп прослушивания,
  журнал подключений, автозапуск с Windows, сворачивание в трей. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Menus, Spin, Registry, LCLType,
  rdp_crypto, server_threads;

type

  { TfrmMain }

  TfrmMain = class(TForm)
    btnRegen: TButton;
    btnStartStop: TButton;
    cbAutostart: TCheckBox;
    cbTrayMinimize: TCheckBox;
    edPassword: TEdit;
    lblPassword: TLabel;
    lblPort: TLabel;
    lblStatus: TLabel;
    MemoLog: TMemo;
    MenuExit: TMenuItem;
    MenuShow: TMenuItem;
    PanelTop: TPanel;
    PopupMenu1: TPopupMenu;
    sePort: TSpinEdit;
    shpStatus: TShape;
    TrayIcon1: TTrayIcon;
    procedure btnRegenClick(Sender: TObject);
    procedure btnStartStopClick(Sender: TObject);
    procedure cbAutostartClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuShowClick(Sender: TObject);
    procedure TrayIcon1DblClick(Sender: TObject);
  private
    FListener: TRdpListenerThread;
    FReallyClose: Boolean;
    FLogFilePath: string;
    procedure HandleLog(const AMsg: string);
    procedure SetListeningUI(AListening: Boolean);
    procedure StopListening;
    procedure InitLogFile;
    procedure WriteLogFile(const ALine: string);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

const
  AUTOSTART_KEY = 'Software\Microsoft\Windows\CurrentVersion\Run';
  AUTOSTART_VALUE_NAME = 'RDPClient';

{ TfrmMain }

procedure TfrmMain.FormCreate(Sender: TObject);
var
  Reg: TRegistry;
begin
  FReallyClose := False;
  Randomize;
  edPassword.Text := GenerateClientPassword;
  InitLogFile;

  // Определяем текущее состояние автозапуска из реестра, а не полагаемся на сохранённое значение.
  Reg := TRegistry.Create;
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(AUTOSTART_KEY) then
    begin
      cbAutostart.Checked := Reg.ValueExists(AUTOSTART_VALUE_NAME);
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;

  TrayIcon1.Icon := Application.Icon;
  SetListeningUI(False);
  HandleLog('Приложение запущено. Пароль: ' + edPassword.Text);
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if cbTrayMinimize.Checked and not FReallyClose then
  begin
    CanClose := False;
    Hide;
    TrayIcon1.Visible := True;
  end
  else
    CanClose := True;
end;

procedure TfrmMain.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  StopListening;
end;

procedure TfrmMain.btnRegenClick(Sender: TObject);
begin
  edPassword.Text := GenerateClientPassword;
  HandleLog('Сгенерирован новый пароль: ' + edPassword.Text);
end;

procedure TfrmMain.btnStartStopClick(Sender: TObject);
begin
  if FListener = nil then
  begin
    try
      FListener := TRdpListenerThread.Create(Word(sePort.Value), edPassword.Text, @HandleLog);
      FListener.Start;
      SetListeningUI(True);
      HandleLog(Format('Прослушивание порта %d запущено', [sePort.Value]));
    except
      on E: Exception do
      begin
        FreeAndNil(FListener);
        HandleLog('Не удалось запустить сервер: ' + E.Message);
        MessageDlg('Не удалось запустить сервер', E.Message, mtError, [mbOK], 0);
      end;
    end;
  end
  else
    StopListening;
end;

procedure TfrmMain.StopListening;
begin
  if FListener <> nil then
  begin
    FListener.RequestStop;
    FListener.WaitFor;
    FreeAndNil(FListener);
    SetListeningUI(False);
    HandleLog('Прослушивание остановлено');
  end;
end;

procedure TfrmMain.SetListeningUI(AListening: Boolean);
begin
  if AListening then
  begin
    btnStartStop.Caption := 'Стоп';
    shpStatus.Brush.Color := clGreen;
    lblStatus.Caption := 'Прослушивание...';
    sePort.Enabled := False;
    btnRegen.Enabled := False;
  end
  else
  begin
    btnStartStop.Caption := 'Старт';
    shpStatus.Brush.Color := clRed;
    lblStatus.Caption := 'Остановлен';
    sePort.Enabled := True;
    btnRegen.Enabled := True;
  end;
end;

procedure TfrmMain.cbAutostartClick(Sender: TObject);
var
  Reg: TRegistry;
  ExePath: string;
begin
  Reg := TRegistry.Create;
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(AUTOSTART_KEY, True) then
    begin
      if cbAutostart.Checked then
      begin
        ExePath := '"' + ParamStr(0) + '"';
        Reg.WriteString(AUTOSTART_VALUE_NAME, ExePath);
        HandleLog('Автозапуск включён');
      end
      else
      begin
        if Reg.ValueExists(AUTOSTART_VALUE_NAME) then
          Reg.DeleteValue(AUTOSTART_VALUE_NAME);
        HandleLog('Автозапуск отключён');
      end;
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TfrmMain.TrayIcon1DblClick(Sender: TObject);
begin
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
end;

procedure TfrmMain.MenuShowClick(Sender: TObject);
begin
  TrayIcon1DblClick(Sender);
end;

procedure TfrmMain.MenuExitClick(Sender: TObject);
begin
  FReallyClose := True;
  Close;
end;

procedure TfrmMain.InitLogFile;
var
  Dir: string;
begin
  // Требование ТЗ: лог именно в %APPDATA%\RDPClient\log.txt.
  Dir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) + 'RDPClient';
  if not DirectoryExists(Dir) then
    ForceDirectories(Dir);
  FLogFilePath := IncludeTrailingPathDelimiter(Dir) + 'log.txt';
end;

procedure TfrmMain.WriteLogFile(const ALine: string);
var
  F: TextFile;
begin
  if FLogFilePath = '' then Exit;
  try
    AssignFile(F, FLogFilePath);
    if FileExists(FLogFilePath) then
      Append(F)
    else
      Rewrite(F);
    try
      WriteLn(F, ALine);
    finally
      CloseFile(F);
    end;
  except
    // ошибки логирования в файл не должны ронять приложение
  end;
end;

procedure TfrmMain.HandleLog(const AMsg: string);
var
  Line: string;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + AMsg;
  MemoLog.Lines.Add(Line);
  WriteLogFile(Line);
end;

end.
