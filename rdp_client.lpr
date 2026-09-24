program rdp_client;

{ Приложение клиента (запускается на управляемом компьютере): слушает порт,
  аутентифицирует администратора и (начиная с этапа 3) транслирует экран и
  принимает команды управления. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // подключает виджет-сет LCL, должен идти до модулей форм
  Forms, main_client;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'RDP Client';
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
